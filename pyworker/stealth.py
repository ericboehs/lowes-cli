"""
Shared Playwright setup for the lowes worker.

Two modes:

1. **CDP attach** (preferred when Lowe's bot-detection is active) — connect
   to a real Chrome.app the user launched with `--remote-debugging-port=9222`.
   This uses their actual Chrome binary and a real user-data-dir, which
   passes Lowe's "We're unable to sign you in right now" check that vanilla
   automated Chromium fails. Use `lowes chrome-start` to launch.

2. **Persistent context fallback** — vanilla Playwright + a persistent
   user-data-dir under the cache directory. Fine for sites that don't fight
   automation.

Selection: if `LOWES_CDP_URL` is set (or the default debugging port is
listening), we attach. Otherwise we launch our own.
"""

from __future__ import annotations

import os
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
)

DEFAULT_CDP_URL = "http://127.0.0.1:9222"


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


def open_stealth_context(
    p: Any,
    user_data_dir: Path,
    headed: bool = False,
    viewport: dict[str, int] | None = None,
    locale: str = "en-US",
    timezone_id: str = "America/Chicago",
):
    """Open a Chromium context.

    Tries CDP attach first (real user Chrome). Falls back to a persistent
    Chromium context. Caller closes via `context.close()`.
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
    return p.chromium.launch_persistent_context(
        user_data_dir=str(user_data_dir),
        headless=not headed,
        viewport=viewport or {"width": 1366, "height": 900},
        locale=locale,
        timezone_id=timezone_id,
        user_agent=USER_AGENT,
    )
