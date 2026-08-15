"""
Shared Playwright setup for the lowes worker.

Two modes:

1. **CDP attach** (preferred, and what every command actually uses) — connect
   to the Chrome that `lowes chrome-start` launched with
   `--remote-debugging-port=9222`. That Chrome is the real binary with a real
   user-data-dir, started directly rather than through Playwright's launcher,
   so it was never in automation mode: `navigator.webdriver` is false without
   any patching. Headless or headed is decided on *that* command line, not
   here — see `lib/lowes/commands/chrome_start.rb`. This module attaches to
   whatever is on the port.

2. **Persistent context fallback** — vanilla Playwright + a persistent
   user-data-dir under the cache directory. Weaker, because Playwright turns
   automation mode on over the debugger (`Emulation.setAutomationOverride`)
   where no command-line filtering can reach it; the blink flag below switches
   the feature off outright, which is the part that does reach it.

Selection: if `LOWES_CDP_URL` is set (or the default debugging port is
listening), we attach. Otherwise we launch our own.

Whichever path runs, a headless Chrome has to be told what to call itself.
Left alone it advertises `HeadlessChrome/<version>` in its own User-Agent and
Akamai answers 403 Access Denied at the edge, before the sensor runs and
before any fingerprint could matter. Measured on lowes.com, cold profile:
`--headless` alone gets "Access Denied" and no `_abck` at all; `--headless`
plus a User-Agent naming the version the binary actually is gets the real
homepage and a validated `_abck` in about three seconds.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

DEFAULT_CDP_URL = "http://127.0.0.1:9222"

CHROME_BINARIES = (
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium",
)

PLATFORMS = {"darwin": "Macintosh; Intel Mac OS X 10_15_7", "linux": "X11; Linux x86_64"}

# Last resort only. A UA naming a Chrome older than the engine behind it is a
# worse tell than `HeadlessChrome` was — that mismatch is the thing a sensor is
# built to notice — so this is used only when the binary refuses to say.
FALLBACK_VERSION = "151"


def sync_playwright_module():
    from playwright.sync_api import sync_playwright as _spw
    return _spw()


def cdp_endpoint() -> str | None:
    """Return a reachable CDP endpoint, or None.

    Honors `LOWES_CDP_URL` env var. Falls back to probing
    http://127.0.0.1:9222/json/version (the default for `lowes chrome-start`).
    """
    candidates = []
    if (env := os.environ.get("LOWES_CDP_URL")):
        candidates.append(env)
    candidates.append(DEFAULT_CDP_URL)
    for url in candidates:
        try:
            with urllib.request.urlopen(url.rstrip("/") + "/json/version", timeout=1.5) as r:
                if r.status == 200:
                    return url
        except (urllib.error.URLError, OSError, ValueError):
            continue
    return None


def chrome_binary() -> str | None:
    if (env := os.environ.get("LOWES_CHROME_BINARY")):
        return env if os.access(env, os.X_OK) else None
    for path in CHROME_BINARIES:
        if os.access(path, os.X_OK):
            return path
    return None


def installed_version(binary: str | None = None) -> str:
    """The major version the Chrome binary reports about itself.

    Asked of the binary rather than hardcoded, so the string stays true across
    Chrome updates instead of quietly becoming a lie.
    """
    binary = binary or chrome_binary()
    if not binary:
        return FALLBACK_VERSION
    try:
        out = subprocess.run(
            [binary, "--version"], capture_output=True, text=True, timeout=10, check=False
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return FALLBACK_VERSION
    match = re.search(r"(\d+)", out)
    return match.group(1) if match else FALLBACK_VERSION


def user_agent() -> str:
    if (env := os.environ.get("LOWES_USER_AGENT")):
        return env
    platform = PLATFORMS.get("darwin" if sys.platform == "darwin" else "linux")
    return (
        f"Mozilla/5.0 ({platform}) AppleWebKit/537.36 (KHTML, like Gecko) "
        f"Chrome/{installed_version()}.0.0.0 Safari/537.36"
    )


def open_stealth_context(
    p: Any,
    user_data_dir: Path,
    headed: bool = False,
    viewport: dict[str, int] | None = None,
    locale: str = "en-US",
    timezone_id: str = "America/Chicago",
):
    """Open a Chromium context.

    Tries CDP attach first (the Chrome `lowes chrome-start` launched). Falls
    back to a persistent Chromium context. Caller closes via `context.close()`.
    """
    cdp = cdp_endpoint()
    if cdp:
        browser = p.chromium.connect_over_cdp(cdp)
        # connect_over_cdp returns a Browser; the existing user context is
        # browser.contexts[0] (the default one). Reuse it so we share
        # cookies and storage with the real Chrome session.
        if browser.contexts:
            return browser.contexts[0]
        return browser.new_context()

    user_data_dir.mkdir(parents=True, exist_ok=True)
    # `--user-agent` rather than the `user_agent=` context option on purpose:
    # the option is a CDP-level override that leaves `sec-ch-ua` reporting
    # whatever the binary is, contradicting the header. Set at launch, the
    # client hints follow the flag.
    args = ["--disable-blink-features=AutomationControlled"]
    if not headed:
        args.append(f"--user-agent={user_agent()}")
    options: dict[str, Any] = {
        "user_data_dir": str(user_data_dir),
        "headless": not headed,
        "viewport": viewport or {"width": 1366, "height": 900},
        "locale": locale,
        "timezone_id": timezone_id,
        "args": args,
    }
    # The real binary, not Playwright's bundled "Chrome for Testing" — a
    # different build than the one measured to pass, and testing the wrong
    # binary answers the wrong question.
    from playwright.sync_api import Error as PlaywrightError

    try:
        return p.chromium.launch_persistent_context(channel="chrome", **options)
    except PlaywrightError as e:
        # Only "there is no Chrome here" belongs in the fallback — Playwright
        # phrases both of those as "Chromium distribution 'chrome' is not
        # found/supported". Anything else (a locked profile, a bad arg) would
        # relaunch and fail the same way, with the first message thrown away.
        if "chromium distribution" not in str(e).lower():
            raise
        # Bundled Chromium answering to a UA that names the *system* Chrome's
        # version is exactly the mismatch this module exists to avoid, so say
        # so rather than quietly shipping it.
        print(
            "lowes: Chrome not installed — falling back to Playwright's bundled "
            "Chromium, whose engine won't match the User-Agent it sends",
            file=sys.stderr,
        )
        return p.chromium.launch_persistent_context(**options)
