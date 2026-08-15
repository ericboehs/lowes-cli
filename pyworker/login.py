"""
Interactive Lowe's login via Playwright.

Opens a real (headed) Chromium window pointed at lowes.com sign-in. The user
logs in themselves — including any captcha, 2FA, or "verify it's you" prompts.

Once authenticated (we see a logged-in account indicator), we persist:
    - storage_state.json (Playwright full state — used by every subsequent fetch)
    - cookies.json       (simple {name: value} dict — easy to inspect/grep)

Output format on stdout (NDJSON):
    {"event":"log","msg":"..."}
    {"event":"navigate","url":"..."}
    {"event":"done","cookies_path":"...","count":N}
    {"event":"error","msg":"..."}
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path
from typing import Any

# Make sibling modules (stealth.py) importable when this file is run directly.
sys.path.insert(0, str(Path(__file__).parent))


def emit(event: str, **fields: Any) -> None:
    sys.stdout.write(json.dumps({"event": event, **fields}) + "\n")
    sys.stdout.flush()


def xdg_data_home() -> Path:
    base = os.environ.get("XDG_DATA_HOME")
    return Path(base) if base else Path.home() / ".local/share"


def xdg_config_home() -> Path:
    base = os.environ.get("XDG_CONFIG_HOME")
    return Path(base) if base else Path.home() / ".config"


def load_email() -> str | None:
    cfg = xdg_config_home() / "lowes" / "config.json"
    if not cfg.exists():
        return None
    try:
        data = json.loads(cfg.read_text())
        email = data.get("email")
        return email if email and email != "you@example.com" else None
    except Exception:  # noqa: BLE001
        return None


HOME_URL = "https://www.lowes.com/"
# Lowe's doesn't have a stable /login URL — the Sign In button in the nav
# opens an auth flow (modal or redirect). We start at the homepage and click it.
SIGN_IN_BUTTON_SELECTORS = (
    'a[href*="signin" i], a[href*="login" i], '
    'button:has-text("Sign In"), a:has-text("Sign In")'
)

# Cookies that indicate an authenticated Lowe's session. Confirmed by
# inspecting a signed-in session over CDP. `lowesauthcookie` is the
# strongest signal; the others are present once you've been through auth.
AUTH_COOKIE_NAMES = {"lowesauthcookie", "__Host-lsid", "L_SID", "al_sess"}


def main() -> int:
    try:
        from stealth import (  # type: ignore[import-not-found]
            cdp_endpoint,
            open_stealth_context,
            sync_playwright_module,
        )
    except ImportError as e:
        emit("error", msg=f"stealth helper missing: {e}")
        return 2

    cache_dir = xdg_data_home() / "lowes" / "cache"
    cache_dir.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(cache_dir, 0o700)
    except OSError:
        pass
    cookies_path = cache_dir / "cookies.json"
    storage_state_path = cache_dir / "storage_state.json"
    user_data_dir = cache_dir / "user_data"

    cdp = cdp_endpoint()
    if cdp:
        emit("log", msg=f"attaching to running Chrome over CDP ({cdp})")
        emit("log", msg="sign in to Lowe's in that Chrome window — cookies persist in its profile")
    else:
        emit("log", msg=f"no CDP endpoint found — launching automated browser ({user_data_dir})")
        emit("log", msg="if Lowe's blocks you with 'unable to sign you in right now', run `lowes chrome-start` instead and rerun this command.")

    with sync_playwright_module() as p:
        try:
            context = open_stealth_context(p, user_data_dir=user_data_dir, headed=True)
        except Exception as e:  # noqa: BLE001
            emit(
                "error",
                msg=(
                    f"failed to launch browser: {e}. "
                    "Run: cd pyworker && .venv/bin/python -m playwright install chromium"
                ),
            )
            return 1

        page = context.pages[0] if context.pages else context.new_page()
        # Only drive the page when we're running our own browser. When attached
        # over CDP to a real Chrome the user already has open, leave their
        # navigation alone.
        if not cdp:
            emit("navigate", url=HOME_URL)
            page.goto(HOME_URL, wait_until="domcontentloaded")
            try:
                btn = page.locator(SIGN_IN_BUTTON_SELECTORS).first
                btn.wait_for(state="visible", timeout=8000)
                btn.click()
                emit("log", msg="clicked Sign In in top nav")
            except Exception as e:  # noqa: BLE001
                emit("log", msg=f"could not auto-click Sign In ({e}); do it manually")

            email = load_email()
            if email:
                try:
                    email_input = page.locator(
                        "input[type=email], input[name=email], #email-input, #email"
                    ).first
                    email_input.wait_for(state="visible", timeout=8000)
                    email_input.fill(email)
                    emit("log", msg=f"pre-filled email: {email}")
                except Exception as e:  # noqa: BLE001
                    emit("log", msg=f"could not pre-fill email ({e}); continue manually")

        emit(
            "log",
            msg=(
                "Sign in to Lowe's in the browser window. Solve any captcha or 2FA. "
                "When the page settles on a signed-in URL, this script will detect it "
                "and save cookies."
            ),
        )

        deadline = time.time() + 600
        authenticated = False
        poll_warned = False
        while time.time() < deadline:
            try:
                cookies = context.cookies()
                names = {c.get("name") for c in cookies}
                if AUTH_COOKIE_NAMES & names:
                    url = page.url or ""
                    if "/login" not in url and "/signin" not in url:
                        authenticated = True
                        break
            except Exception as e:  # noqa: BLE001
                # Transient while the page navigates, so this keeps polling —
                # but if it is not transient the alternative is ten minutes of
                # silence ending in "timed out waiting for sign-in", with the
                # actual reason never mentioned. Reported once.
                if not poll_warned:
                    poll_warned = True
                    emit("log", level="warn", msg=f"could not read cookies while waiting: {e}")
            time.sleep(2)

        if not authenticated:
            emit("error", msg="timed out waiting for sign-in (10 min). Cookies not saved.")
            if not cdp:
                context.close()
            return 1

        cookies = context.cookies()
        simple = {
            c.get("name", ""): c.get("value", "")
            for c in cookies
            if "lowes" in (c.get("domain", "") or "")
        }
        cookies_path.write_text(json.dumps(simple))
        os.chmod(cookies_path, 0o600)

        try:
            context.storage_state(path=str(storage_state_path))
            os.chmod(storage_state_path, 0o600)
        except Exception as e:  # noqa: BLE001
            emit("log", msg=f"storage_state dump skipped ({e}); persistent profile is the source of truth")

        emit("done", cookies_path=str(cookies_path), count=len(simple))

        # When attached over CDP, leave the user's Chrome window alone.
        if not cdp:
            context.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
