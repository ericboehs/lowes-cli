"""
Lowe's CLI Python worker.

Reads a single JSON request from stdin describing the action to perform,
then drives Playwright (using the persisted storage_state from `lowes login`)
to scrape the relevant pages on lowes.com.

Actions:
    sync_orders   — pull order history for given years
    sync_quotes   — pull saved quotes
    fetch_prices  — fetch current price for a list of items (URL/model/item_id)

Protocol (NDJSON over stdout):
    {"event":"otp_required","prompt":"..."}    # then read one line on stdin
    {"event":"prompt","prompt":"...","kind":"text"|"choice","choices":[...]}
    {"event":"log","level":"info","msg":"..."}
    {"event":"order","data":{...}}             # one per order
    {"event":"quote","data":{...}}             # one per quote
    {"event":"price","data":{...}}             # one per priced item
    {"event":"total","year":2025,"count":N}
    {"event":"progress","i":3,"n":42,...}
    {"event":"done","count":N}
    {"event":"error","msg":"..."}

Selectors on lowes.com change frequently. The constants near the top of this
file (ORDERS_URL, ORDER_CARD_SELECTOR, etc.) are the knobs to tune when the
site shifts. We extract via page.evaluate() in JS so a single broken
selector degrades gracefully (returns null fields) instead of crashing.
"""

from __future__ import annotations

import json
import os
import random
import re
import sys
import time
import traceback
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any

# Make sibling modules (stealth.py) importable when run directly.
sys.path.insert(0, str(Path(__file__).parent))


# ---------- URLs / selectors (tune these as the site shifts) ----------

ORDERS_URL_TEMPLATE = "https://www.lowes.com/account/orders?isOrg=false"
ORDERS_URL_DEFAULT = "https://www.lowes.com/account/orders?isOrg=false"
QUOTES_URL = "https://www.lowes.com/mylowes/quotes"
SEARCH_URL_TEMPLATE = "https://www.lowes.com/search?searchTerm={q}"
PRODUCT_URL_TEMPLATE = "https://www.lowes.com/pd/{item_id}"

HOME_URL = "https://www.lowes.com/"
SIGN_IN_BUTTON_SELECTORS = (
    'a[href*="signin" i], a[href*="login" i], '
    'button:has-text("Sign In"), a:has-text("Sign In")'
)

AUTH_COOKIE_NAMES = {"lowesauthcookie", "__Host-lsid", "L_SID", "al_sess"}


def emit(event: str, **fields: Any) -> None:
    sys.stdout.write(
        json.dumps({"event": event, **fields}, default=_json_default) + "\n"
    )
    sys.stdout.flush()


def _json_default(obj: Any) -> Any:
    if isinstance(obj, (date, datetime)):
        return obj.isoformat()
    raise TypeError(f"not serializable: {type(obj).__name__}")


def xdg_path(env: str, default_subpath: str) -> Path:
    base = os.environ.get(env)
    return Path(base) if base else Path.home() / default_subpath


def cache_dir() -> Path:
    d = xdg_path("XDG_DATA_HOME", ".local/share") / "lowes" / "cache"
    d.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(d, 0o700)
    except OSError:
        pass
    return d


# ---------- Browser context ----------

def open_context(p: Any, headed: bool = False):
    """Open the shared stealth persistent context.

    Returns the context (the persistent variant owns its own browser, so no
    separate browser handle is returned).
    """
    from stealth import open_stealth_context  # type: ignore[import-not-found]
    return open_stealth_context(p, user_data_dir=cache_dir() / "user_data", headed=headed)


def is_authenticated(context: Any, page: Any) -> bool:
    try:
        names = {c.get("name") for c in context.cookies()}
    except Exception:  # noqa: BLE001
        names = set()
    if not (AUTH_COOKIE_NAMES & names):
        return False
    url = page.url or ""
    return "/login" not in url and "/signin" not in url


def save_state(context: Any) -> None:
    try:
        context.storage_state(path=str(cache_dir() / "storage_state.json"))
    except Exception as e:  # noqa: BLE001
        emit("log", level="warn", msg=f"failed to persist storage_state: {e}")


# ---------- Scripted login fallback ----------

def scripted_login(page: Any, email: str, password: str, otp_secret: str | None) -> bool:
    """Best-effort scripted login. Returns True on success.

    If captcha or device-verification appears, we surface an OTP prompt to the
    parent and wait for the user to provide a code (otp_secret is reserved for
    a future TOTP-driven flow).
    """
    _ = otp_secret  # reserved for future TOTP auto-fill
    page.goto(HOME_URL, wait_until="domcontentloaded")
    try:
        page.locator(SIGN_IN_BUTTON_SELECTORS).first.click(timeout=8000)
    except Exception as e:  # noqa: BLE001
        emit("log", level="warn", msg=f"could not click Sign In ({e})")
    try:
        page.locator("input[type=email], #email-input, #email").first.fill(email, timeout=10000)
        page.locator("input[type=password], #password-input, #password").first.fill(password, timeout=10000)
        page.locator(
            "button[type=submit], button:has-text('Sign In'), button:has-text('Sign in')"
        ).first.click()
    except Exception as e:  # noqa: BLE001
        emit("log", level="warn", msg=f"scripted login filled with errors: {e}")

    deadline = time.time() + 60
    while time.time() < deadline:
        if "/login" not in (page.url or ""):
            return True
        try:
            otp_input = page.locator(
                "input[name=otp], input[name=verificationCode], input[autocomplete=one-time-code]"
            )
            if otp_input.count() > 0 and otp_input.first.is_visible():
                emit("otp_required", prompt="Lowe's verification code")
                code = sys.stdin.readline().strip()
                otp_input.first.fill(code)
                page.locator("button[type=submit]").first.click()
        except Exception:  # noqa: BLE001
            pass
        time.sleep(1.5)

    url = page.url or ""
    return ("/login" not in url) and ("/signin" not in url)


# ---------- Extractors (run in browser) ----------

ORDER_DETAIL_EXTRACT_JS = r"""
() => {
  // Each item on a Lowe's order detail page is anchored by an <a> to /pd/.
  // Walk up to the smallest container that holds qty/price/image and
  // extract from there.
  const moneyOf = (s) => {
    if (!s) return null;
    const m = s.match(/\$\s*([0-9,]+(?:\.\d{2})?)/);
    return m ? parseFloat(m[1].replace(/,/g, '')) : null;
  };

  // Real order items have a row that includes /ea. AND QTY \d (Lowe's
  // shows "$3.50 /ea. QTY 1"). Recommendation carousels lack both. Walk
  // up each /pd/ anchor and drop ones whose ancestor doesn't carry both
  // markers — that filters out "Previously Viewed" / "Trending Now"
  // entries that otherwise leak into the items list. We also keep walking
  // until the ancestor includes a sibling <img>, since Lowe's renders
  // the product image in a separate grid column from the title/price.
  // Skip anchors inside any recommendation/carousel section — those have
  // a /pd/ href but aren't part of the order.
  const isRecAnchor = (a) => !!a.closest(
    '[class*="carousel" i], .scaf-rec, [class*="recommend" i], ' +
    '[class*="trending" i], [class*="previously" i], ' +
    '[class*="ProductCarousel" i], [class*="BYCarousel" i], ' +
    '[class*="fabrik_recs" i]'
  );

  const anchors = Array.from(document.querySelectorAll('a[href*="/pd/"]'))
    .filter(a => !isRecAnchor(a));
  // Dedupe by row element, not by href. A row holds two anchors for the same
  // product (image column and title column) and those must collapse — but an
  // order that bought the same item twice gets two separate rows with the
  // same href, and those are two real lines. Keying on href dropped the
  // second one and made the order read as cheaper than it was.
  const seen = new Set();
  const items = [];
  for (const a of anchors) {
    const href = a.href;

    let row = null, el = a, hops = 0, foundQty = false;
    while (el && el.parentElement && hops < 14) {
      el = el.parentElement;
      const t = el.innerText || '';
      if (/\/ea\.?/i.test(t) && /\bQTY\s+\d+/i.test(t)) {
        foundQty = true;
        // Prefer the smallest ancestor that has both the qty markers AND
        // contains an <img> — the image is in a sibling grid column.
        if (el.querySelector('img')) { row = el; break; }
        // Otherwise keep walking; remember we've passed the qty test
      }
      hops++;
    }
    if (!row && foundQty) {
      // Couldn't find an ancestor with both markers + img — fall back to
      // the qty-bearing ancestor we already passed (image will be null).
      el = a;
      for (let i = 0; i < 14 && el && el.parentElement; i++) {
        el = el.parentElement;
        const t = el.innerText || '';
        if (/\/ea\.?/i.test(t) && /\bQTY\s+\d+/i.test(t)) { row = el; break; }
      }
    }
    if (!row) continue;
    if (seen.has(row)) continue;
    seen.add(row);

    const text = row ? (row.innerText || '') : '';
    const titleEl = a.querySelector('img[alt]');
    const title =
      (a.getAttribute('aria-label') || '').trim() ||
      (titleEl ? (titleEl.getAttribute('alt') || '').trim() : '') ||
      (a.textContent || '').trim();

    const img = a.querySelector('img') || (row ? row.querySelector('img') : null);
    let image_link = img ? img.getAttribute('src') : null;
    if (image_link) {
      if (image_link.startsWith('//')) image_link = 'https:' + image_link;
      else if (image_link.startsWith('/')) image_link = 'https://www.lowes.com' + image_link;
    }

    // Collect every "$X.XX /ea" occurrence (per-unit prices) and every
    // standalone "$X.XX" not followed by /ea (line totals). Lowe's by-
    // the-foot rows show both: "$0.97/ea $0.92/ea" plus "$87.30 $82.80".
    const eaPrices = (text.match(/\$\s*[0-9,]+(?:\.\d{2})?\s*\/\s*ea/gi) || [])
      .map(s => parseFloat(s.replace(/[^0-9.]/g, '')))
      .filter(n => !isNaN(n));
    const linePrices = [];
    {
      // "Saved $12.34" sits in the same row text and is not a price anything
      // was ever sold for. It only matters when the savings exceed what was
      // paid: line_was takes the smallest amount above line_total, so a big
      // enough Saved figure outranks the real strikethrough and gets stored
      // as the pre-discount line total.
      const savingsLabel = /sav(?:ings|ed|e)\b[\s:]*$/i;
      // (?![0-9.]) stops the amount backtracking to a shorter number so the
      // /ea guard can be satisfied: without it "$5.00 /ea" matches as "5.0"
      // and a per-unit was-price lands in the line-total pool.
      const re = /\$\s*([0-9,]+(?:\.\d{2})?)(?![0-9.])(?!\s*\/\s*ea)/gi;
      let m; while ((m = re.exec(text)) !== null) {
        if (savingsLabel.test(text.slice(Math.max(0, m.index - 24), m.index))) continue;
        const v = parseFloat(m[1].replace(/,/g, ''));
        if (!isNaN(v)) linePrices.push(v);
      }
    }

    const qm = text.match(/\bQTY\s+(\d+)/i);
    const qty = qm ? parseInt(qm[1], 10) : null;
    // Item id from row text first ("Item #876261"), then URL slug as backup
    const itemRowM = text.match(/Item\s*#\s*(\d{4,})/i);
    const itemUrlM = href.match(/\/(\d{6,})(?:[\/?#]|$)/);
    const modelm = text.match(/Model\s*#\s*([A-Za-z0-9.\-\/]+)/i);

    // Per-unit price = smallest /ea; per-unit was = largest /ea
    // (only when 2+ different /ea values appear, indicating a sale).
    let price = null, was_price = null;
    if (eaPrices.length) {
      const sortedEa = [...new Set(eaPrices)].sort((a, b) => a - b);
      price = sortedEa[0];
      if (sortedEa.length > 1) was_price = sortedEa[sortedEa.length - 1];
    }

    if (price === null && !qm) continue;  // skip non-item links

    const q = qty || 1;
    let line_total = null, line_was = null;
    if (price !== null) {
      const expected = price * q;
      // Pick the standalone $ amount closest to price*qty (within 5%
      // or 10c) as the line total — handles tax/rounding wobble.
      const lineCandidate = linePrices
        .filter(v => v >= price * 0.5)
        .map(v => ({v, d: Math.abs(v - expected)}))
        .sort((a, b) => a.d - b.d)[0];
      if (lineCandidate && lineCandidate.d <= Math.max(0.10, expected * 0.05)) {
        line_total = lineCandidate.v;
      } else {
        line_total = +(expected).toFixed(2);
      }
      // Line was: smallest standalone $ amount strictly greater than
      // line_total. Falls back to per-unit was * qty when no DOM hit.
      const wasCandidate = linePrices
        .filter(v => v > line_total + 0.01)
        .sort((a, b) => a - b)[0];
      if (wasCandidate) line_was = wasCandidate;
      else if (was_price !== null) line_was = +(was_price * q).toFixed(2);
    }

    items.push({
      title: title || null,
      link: href,
      item_id: (itemRowM && itemRowM[1]) || (itemUrlM && itemUrlM[1]) || null,
      model: modelm ? modelm[1] : null,
      quantity: qty,
      price,        // per-unit, post-discount
      was_price,    // per-unit, pre-discount (null when not on sale)
      line_total,   // line total, post-discount
      line_was,     // line total, pre-discount (null when not on sale)
      image_link,
    });
  }

  // Status / payment / store from page-level text
  const body = document.body ? (document.body.innerText || '') : '';
  const status = (body.match(/(Delivered|Shipped|Processing|Picked\s+Up|Ready\s+for\s+Pickup|Cancell?ed|Returned|In\s+Transit)/i) || [])[1] || null;
  const subtotal = moneyOf((body.match(/Subtotal[^$]*(\$\s*[0-9,]+(?:\.\d{2})?)/i) || [])[1]);
  const tax = moneyOf((body.match(/Tax[^$]*(\$\s*[0-9,]+(?:\.\d{2})?)/i) || [])[1]);
  const total_paid = moneyOf((body.match(/(?:Total|Grand\s+Total)[^$]*(\$\s*[0-9,]+(?:\.\d{2})?)/i) || [])[1]);
  const ship_to_m = body.match(/Ship\s+to[\s:]*([A-Za-z][A-Za-z\s.\-]{1,40})/);
  const ship_to = ship_to_m ? ship_to_m[1].trim() : null;
  const last4_m = body.match(/(?:ending\s+in|•{2,}\s*)\s*(\d{4})/i);
  const payment_last4 = last4_m ? last4_m[1] : null;

  return { items, status, subtotal, estimated_tax: tax, total_paid, ship_to, payment_method_last_4: payment_last4 };
}
"""


ORDERS_EXTRACT_JS = r"""
() => {
  // Lowe's lists each order as <a href="...account/orders/details?oi=...">
  // whose visible text is the numeric order id. The surrounding row
  // contains the order date (MM/DD/YYYY) and total ($X.XX). We walk up
  // from each anchor until we find that row.
  const moneyOf = (s) => {
    if (!s) return null;
    const m = s.match(/\$\s*([0-9,]+(?:\.\d{2})?)/);
    return m ? parseFloat(m[1].replace(/,/g, '')) : null;
  };
  const isoDate = (mdy) => {
    if (!mdy) return null;
    const [m, d, y] = mdy.split('/');
    return `${y}-${m.padStart(2, '0')}-${d.padStart(2, '0')}`;
  };

  const anchors = Array.from(document.querySelectorAll('a[href*="account/orders/details"]'));
  const map = new Map();
  for (const a of anchors) {
    const id = (a.textContent || '').trim();
    // Skip nav/help links — order ids are pure digits
    if (!/^\d{6,}$/.test(id)) continue;

    // Walk up looking for the row with both a $ and an MM/DD/YYYY date
    let row = a, hops = 0;
    while (row && row.parentElement && hops < 8) {
      row = row.parentElement;
      const t = row.innerText || '';
      if (/\$\s*\d/.test(t) && /\d{1,2}\/\d{1,2}\/\d{4}/.test(t)) break;
      hops++;
    }
    const text = row ? (row.innerText || '') : '';
    const dm = text.match(/(\d{1,2}\/\d{1,2}\/\d{4})/);
    const tm = text.match(/\$\s*[0-9,]+(?:\.\d{2})?/);

    map.set(id, {
      order_id: id,
      order_placed: isoDate(dm ? dm[1] : null),
      status: null,
      grand_total: moneyOf(tm ? tm[0] : null),
      items: [],
      order_details_link: a.href,
    });
  }
  return Array.from(map.values());
}
"""


QUOTES_EXTRACT_JS = r"""
() => {
  const cards = Array.from(document.querySelectorAll(
    '[data-testid*="quote"], [class*="QuoteCard"], [class*="quote-card"], section, article'
  )).filter(el => /quote\s*#?\s*[\w-]+/i.test(el.textContent || ''));

  const money = (s) => {
    if (!s) return null;
    const m = String(s).replace(/[^0-9.\-]/g, '');
    return m ? parseFloat(m) : null;
  };

  const out = [];
  for (const c of cards) {
    const t = c.textContent || '';
    const idMatch = t.match(/quote\s*#?\s*([\w-]+)/i);
    if (!idMatch) continue;
    const quote_id = idMatch[1];

    let created = null;
    const dm =
      t.match(/([A-Z][a-z]{2,8}\s+\d{1,2},\s*\d{4})/) ||
      t.match(/(\d{4}-\d{2}-\d{2})/);
    if (dm) created = dm[1];

    const tm = t.match(/\$\s?([0-9,]+\.\d{2})/);
    const total = tm ? money(tm[0]) : null;

    const nameEl = c.querySelector('h2, h3, [class*="title"], [class*="name"]');
    const name = nameEl ? (nameEl.textContent || '').trim() : null;

    const linkEl = c.querySelector('a[href*="quote"]');
    const link = linkEl ? linkEl.href : null;

    let status = null;
    const sm = t.match(/(Active|Expired|Converted|Draft|Pending)/i);
    if (sm) status = sm[1];

    out.push({ quote_id, created, name, total, status, link, items: [] });
  }
  const map = new Map();
  for (const o of out) map.set(o.quote_id, o);
  return Array.from(map.values());
}
"""


PRICE_EXTRACT_JS = r"""
() => {
  // Title: PDP h1 is reliable
  const titleEl = document.querySelector('h1');
  const title = titleEl ? (titleEl.textContent || '').trim() : null;

  // Primary product image. Lowe's uses og:image meta + a hero <img> in the
  // gallery; either is good. og:image is the most stable.
  const ogImg = document.querySelector('meta[property="og:image"], meta[name="og:image"]');
  let image_url = ogImg ? ogImg.getAttribute('content') : null;
  if (!image_url) {
    const heroImg = document.querySelector('[class*="hero" i] img, [class*="gallery" i] img, main img');
    if (heroImg) image_url = heroImg.getAttribute('src');
  }
  // Normalize protocol-relative ("//..."), site-relative ("/..."), and
  // ensure we always store a full URL.
  if (image_url) {
    if (image_url.startsWith('//')) image_url = 'https:' + image_url;
    else if (image_url.startsWith('/')) image_url = 'https://www.lowes.com' + image_url;
  }

  // Price: Lowe's renders $/dollars/cents in separate spans, so DOM
  // textContent has whitespace. innerText collapses it. We scan innerText
  // of any element marked as price-related, falling back to the first
  // $X.XX in the body.
  let price = null;
  const priceCandidates = [
    document.querySelector('[aria-label*="price" i]'),
    document.querySelector('[class*="finalPrice" i]'),
    document.querySelector('[class*="price" i]'),
  ];
  for (const el of priceCandidates) {
    if (!el) continue;
    const txt = (el.innerText || el.textContent || '');
    const m = txt.match(/\$\s*([0-9,]+(?:\.\d{2})?)/);
    if (m) { price = parseFloat(m[1].replace(/,/g, '')); break; }
  }
  if (price === null) {
    const m = (document.body.innerText || '').match(/\$\s*([0-9,]+(?:\.\d{2})?)/);
    if (m) price = parseFloat(m[1].replace(/,/g, ''));
  }

  // Was-price: second $X.XX inside the price block, when on sale
  let was_price = null;
  const priceBlock = document.querySelector('[aria-label*="price" i]');
  if (priceBlock) {
    const matches = (priceBlock.innerText || '').match(/\$\s*[0-9,]+(?:\.\d{2})?/g) || [];
    if (matches.length > 1) {
      const m = matches[1].match(/([0-9,]+(?:\.\d{2})?)/);
      if (m) was_price = parseFloat(m[1].replace(/,/g, ''));
    }
  }

  // Availability — scan body for common Lowe's phrases. "Out of Stock"
  // first so it wins over a hidden "In Stock" elsewhere on the page.
  const body = document.body ? (document.body.innerText || '') : '';
  let availability = null;
  for (const m of [
    'Out of Stock', 'In Stock', 'Limited Stock',
    'Available for Delivery', 'Available for Pickup',
    'Ship to Home', 'Pickup Only', 'Free Delivery',
  ]) {
    if (body.includes(m)) { availability = m; break; }
  }

  const modelMatch = body.match(/Model\s*#?\s*([A-Za-z0-9.\-\/]+)/);
  const itemMatch = body.match(/Item\s*#?\s*(\d{6,})/);

  return {
    title,
    price,
    was_price,
    availability,
    image_url,
    model: modelMatch ? modelMatch[1] : null,
    item_id: itemMatch ? itemMatch[1] : null,
    url: location.href,
  };
}
"""


# ---------- Action: sync_orders ----------

def sync_orders(context: Any, req: dict[str, Any]) -> int:
    page = context.new_page()
    years = [int(y) for y in (req.get("years") or [date.today().year])]
    known = set(req.get("known_order_ids") or [])
    full_details = bool(req.get("full_details", True))
    detail_delay = float(req.get("detail_delay", 0.5))
    detail_jitter = float(req.get("detail_jitter", 0.25))

    if not is_authenticated(context, page):
        if not _ensure_login(page, req):
            emit("error", msg="not authenticated; run `lowes login`")
            return 1

    total_count = 0
    # Lowe's `/account/orders` caps each view at 50 orders, even when
    # filtered to a single year via `?show=YYYY`. To get the full
    # history we iterate quarterly date-range chunks via
    # `?startDate=YYYY-MM-DD&endDate=YYYY-MM-DD`. Dedupe by order id
    # since chunks may overlap at boundaries.
    year_set = sorted({int(y) for y in years}, reverse=True)
    seen_ids: set[str] = set()
    orders: list[dict[str, Any]] = []
    today = date.today()
    quarters = [(1, 1, 3, 31), (4, 1, 6, 30), (7, 1, 9, 30), (10, 1, 12, 31)]
    for y in year_set:
        for sm, sd, em, ed in quarters:
            start = date(y, sm, sd)
            end = date(y, em, ed)
            if start > today:
                continue
            if end > today:
                end = today
            url = (f"https://www.lowes.com/account/orders?isOrg=false"
                   f"&startDate={start.isoformat()}&endDate={end.isoformat()}")
            emit("log", level="info", msg=f"fetching {url}")
            try:
                page.goto(url, wait_until="domcontentloaded")
            except Exception as e:  # noqa: BLE001
                emit("log", level="warn",
                     msg=f"goto failed for {start}..{end}: {e}")
                continue

            try:
                page.wait_for_selector('a[href*="account/orders/details"]', timeout=8000)
                page.wait_for_timeout(800)
            except Exception:  # noqa: BLE001
                # Empty quarter is normal — Lowe's renders an empty list.
                continue

            _scroll_to_bottom(page)
            try:
                chunk_orders = page.evaluate(ORDERS_EXTRACT_JS) or []
            except Exception as e:  # noqa: BLE001
                emit("log", level="warn",
                     msg=f"orders extract failed for {start}..{end}: {e}")
                continue

            for o in chunk_orders:
                oid = o.get("order_id")
                if not oid or oid in seen_ids:
                    continue
                seen_ids.add(oid)
                orders.append(o)

    # Post-filter: keep orders whose placed-year is in the requested set.
    if year_set:
        ys = set(year_set)
        orders = [o for o in orders
                  if o.get("order_placed") and int(o["order_placed"][:4]) in ys]

    new_orders = [o for o in orders if o.get("order_id") not in known]
    emit("total", year=min(year_set) if year_set else 0,
         count=len(new_orders), new=len(new_orders),
         cached=len(orders) - len(new_orders))

    progress_year = min(year_set) if year_set else 0
    for i, o in enumerate(new_orders, start=1):
        o["_synced_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        # Follow the order-details link to scrape items + summary from
        # the live DOM. Lowe's HTML structure changes constantly, but
        # the JSON we capture here is the canonical local archive.
        if full_details and o.get("order_details_link"):
            try:
                page.goto(o["order_details_link"], wait_until="domcontentloaded")
                page.wait_for_timeout(2500)

                # Lowe's hides the actual order items behind an "Expand
                # Items" toggle; click every "Expand" / "Show details"
                # toggle we can find so the items are in the DOM.
                try:
                    page.evaluate(r"""() => {
                        const targets = Array.from(document.querySelectorAll('button, a'))
                            .filter(e => /expand|show\s+(details|items)|view\s+items/i.test((e.textContent||'').trim()));
                        for (const t of targets) {
                            try { t.click(); } catch (e) {}
                        }
                    }""")
                    page.wait_for_timeout(1500)
                except Exception:  # noqa: BLE001
                    pass

                detail = page.evaluate(ORDER_DETAIL_EXTRACT_JS) or {}
                if detail.get("items"):
                    o["items"] = detail["items"]
                for k in ("status", "subtotal", "estimated_tax", "total_paid", "ship_to", "payment_method_last_4"):
                    if detail.get(k) is not None:
                        o[k] = detail[k]
            except Exception as e:  # noqa: BLE001
                emit("log", level="warn",
                     msg=f"detail fetch failed for {o.get('order_id')}: {e}")

        emit("progress", year=int(progress_year), i=i, n=len(new_orders),
             order_id=o.get("order_id"), date=o.get("order_placed"),
             grand_total=o.get("grand_total"),
             title=(o.get("items") or [{}])[0].get("title", "")[:60] if o.get("items") else "")
        emit("order", data=o)
        total_count += 1
        if detail_delay > 0:
            time.sleep(max(0.0, detail_delay + random.uniform(-detail_jitter, detail_jitter)))

    save_state(context)
    emit("done", count=total_count, skipped=0)
    return 0


# ---------- Action: sync_quotes ----------

def sync_quotes(context: Any, req: dict[str, Any]) -> int:
    page = context.new_page()
    if not is_authenticated(context, page):
        if not _ensure_login(page, req):
            emit("error", msg="not authenticated; run `lowes login`")
            return 1

    emit("log", level="info", msg=f"fetching {QUOTES_URL}")
    page.goto(QUOTES_URL, wait_until="domcontentloaded")
    _scroll_to_bottom(page)

    try:
        quotes = page.evaluate(QUOTES_EXTRACT_JS) or []
    except Exception as e:  # noqa: BLE001
        emit("error", msg=f"quotes extract failed: {e}")
        return 1

    emit("total", label="quotes", count=len(quotes))
    for i, q in enumerate(quotes, start=1):
        q["_synced_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        emit("progress", i=i, n=len(quotes),
             order_id=q.get("quote_id"), date=q.get("created"),
             grand_total=q.get("total"), title=q.get("name", ""))
        emit("quote", data=q)

    save_state(context)
    emit("done", count=len(quotes))
    return 0


# ---------- Action: fetch_prices ----------

def fetch_prices(context: Any, req: dict[str, Any]) -> int:
    items = req.get("items") or []
    if not items:
        emit("error", msg="no items provided")
        return 2

    page = context.new_page()
    n = len(items)
    emit("total", label="prices", count=n)

    for i, item in enumerate(items, start=1):
        url = _resolve_product_url(page, item)
        if not url:
            emit("log", level="warn",
                 msg=f"could not resolve URL for {item}")
            continue

        try:
            page.goto(url, wait_until="domcontentloaded")
        except Exception as e:  # noqa: BLE001
            emit("log", level="warn", msg=f"goto failed for {url}: {e}")
            continue

        # Lowe's PDP is heavily client-rendered. Wait for price/title to
        # appear, with a short ceiling so we don't hang on a 404 or empty page.
        try:
            page.wait_for_selector(
                'h1, [aria-label*="price" i], [class*="price" i]',
                timeout=8000,
            )
            # Extra settle for the price spans, which lazy-load after the h1
            page.wait_for_timeout(800)
        except Exception:  # noqa: BLE001
            pass

        try:
            data = page.evaluate(PRICE_EXTRACT_JS) or {}
        except Exception as e:  # noqa: BLE001
            emit("log", level="warn", msg=f"price extract failed for {url}: {e}")
            data = {}

        result = {
            "fetched_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "nickname": item.get("nickname"),
            "model": data.get("model") or item.get("model"),
            "item_id": data.get("item_id") or item.get("item_id"),
            "url": data.get("url") or url,
            "title": data.get("title"),
            "price": data.get("price"),
            "was_price": data.get("was_price"),
            "availability": data.get("availability"),
            "image_url": data.get("image_url"),
        }
        emit("progress", i=i, n=n,
             item_id=result["item_id"] or "",
             title=(result["title"] or "")[:60],
             grand_total=result["price"])
        emit("price", data=result)

    save_state(context)
    emit("done", count=n)
    return 0


def _resolve_product_url(page: Any, item: dict[str, Any]) -> str | None:
    if item.get("url"):
        return item["url"]
    if item.get("item_id"):
        return PRODUCT_URL_TEMPLATE.format(item_id=item["item_id"])
    if item.get("model"):
        # Search by model number; click the first result.
        q = re.sub(r"\s+", "+", str(item["model"]))
        try:
            page.goto(SEARCH_URL_TEMPLATE.format(q=q), wait_until="domcontentloaded")
            link = page.locator('a[href*="/pd/"]').first
            link.wait_for(state="visible", timeout=10000)
            href = link.get_attribute("href")
            if href and href.startswith("/"):
                href = "https://www.lowes.com" + href
            return href
        except Exception:  # noqa: BLE001
            return None
    return None


# ---------- Action: set_store / show_store ----------

STORE_FINDER_URL = "https://www.lowes.com/store/?zip={zip}"
SET_STORE_BUTTON_SELECTORS = (
    'button:has-text("Set as My Store"), '
    'a:has-text("Set as My Store"), '
    'button:has-text("Make My Store"), '
    'a:has-text("Make My Store")'
)
STORE_COOKIE_NAMES = ("sn", "nearbyid", "regionNumber", "region", "zipcode", "zipstate")


def _read_store_cookies(context: Any) -> dict[str, str]:
    out = {}
    try:
        for c in context.cookies():
            if c.get("name") in STORE_COOKIE_NAMES:
                out[c["name"]] = c.get("value", "")
    except Exception:  # noqa: BLE001
        pass
    return out


def show_store(context: Any, _req: dict[str, Any]) -> int:
    cookies = _read_store_cookies(context)
    if not cookies:
        emit("log", level="info", msg="no Lowe's store cookies set yet")
    else:
        for k in STORE_COOKIE_NAMES:
            if k in cookies:
                emit("log", level="info", msg=f"  {k}: {cookies[k]}")
    emit("done", count=len(cookies))
    return 0


def set_store(context: Any, req: dict[str, Any]) -> int:
    zip_code = (req.get("zip") or "").strip()
    if not zip_code:
        emit("error", msg="set_store: zip is required")
        return 2

    before = _read_store_cookies(context)
    page = context.new_page()
    url = "https://www.lowes.com/store/"
    emit("log", level="info", msg=f"navigating to {url}")
    try:
        page.goto(url, wait_until="domcontentloaded")
    except Exception as e:  # noqa: BLE001
        emit("error", msg=f"goto failed: {e}")
        return 1

    # `?zip=` query param is silently ignored if existing cookies have a
    # different zip — Lowe's prioritizes the cookie. Drive the on-page
    # input ("ZIP Code, City, State or Store #") which forces a search.
    try:
        zip_input = page.locator(
            'input[placeholder*="ZIP Code, City" i], input[placeholder*="Store #" i]'
        ).first
        zip_input.wait_for(state="visible", timeout=8000)
        zip_input.fill(zip_code)
        zip_input.press("Enter")
        page.wait_for_timeout(2500)
    except Exception as e:  # noqa: BLE001
        emit("log", level="warn", msg=f"could not drive zip input ({e}); falling back to query string")
        try:
            page.goto(STORE_FINDER_URL.format(zip=zip_code), wait_until="domcontentloaded")
            page.wait_for_timeout(2000)
        except Exception:  # noqa: BLE001
            pass

    try:
        btn = page.locator(SET_STORE_BUTTON_SELECTORS).first
        btn.wait_for(state="visible", timeout=10000)
        # Pull a label from the button's surrounding card so the user can
        # confirm we clicked the right store (Lowe's sometimes lists nearby
        # stores in non-distance order).
        try:
            label = page.evaluate("""(btn) => {
                let el = btn, hops = 0;
                while (el && el.parentElement && hops < 8) {
                    el = el.parentElement;
                    const t = el.innerText || '';
                    if (/\\d+\\s*mi(?:les)?/i.test(t) && /(?:Lowe|Store)/i.test(t)) break;
                    hops++;
                }
                return el ? (el.innerText || '').slice(0, 200).replace(/\\n+/g, ' | ') : null;
            }""", btn.element_handle())
            if label:
                emit("log", level="info", msg=f"clicking: {label}")
        except Exception:  # noqa: BLE001
            pass
        btn.click()
        page.wait_for_timeout(1500)
    except Exception as e:  # noqa: BLE001
        emit("error", msg=f"could not find/click 'Set as My Store' for zip {zip_code}: {e}")
        page.close()
        return 1

    # Lowe's updates `sn` immediately on the click, but `nearbyid`, `region`,
    # `zipcode`, etc. only refresh on the next navigation. Hit the homepage
    # so the rest of the cookies hydrate before we report.
    try:
        page.goto("https://www.lowes.com/", wait_until="domcontentloaded")
        page.wait_for_timeout(1500)
    except Exception:  # noqa: BLE001
        pass

    after = _read_store_cookies(context)
    changed = {k: (before.get(k), after.get(k)) for k in STORE_COOKIE_NAMES if before.get(k) != after.get(k)}
    if not changed:
        emit("log", level="warn",
             msg="no store cookies changed — Lowe's may not have updated yet. Reload lowes.com to confirm.")
    else:
        for k, (b, a) in changed.items():
            emit("log", level="info", msg=f"  {k}: {b!r} -> {a!r}")
    page.close()
    emit("done", count=1)
    return 0


# ---------- Helpers ----------

def _scroll_to_bottom(page: Any, max_steps: int = 25, settle_ms: int = 400) -> None:
    """Trigger lazy-loaded content by scrolling. Stops when scroll height stops growing."""
    try:
        last = 0
        for _ in range(max_steps):
            h = page.evaluate("() => document.body.scrollHeight")
            if h == last:
                break
            page.evaluate(f"() => window.scrollTo(0, {h})")
            page.wait_for_timeout(settle_ms)
            last = h
    except Exception:  # noqa: BLE001
        pass


def _ensure_login(page: Any, req: dict[str, Any]) -> bool:
    email = req.get("email")
    password = req.get("password")
    if not email or not password or password == "unused-have-cookies":
        return False
    return scripted_login(page, email, password, req.get("otp_secret"))


# ---------- Entry point ----------

def main() -> int:
    raw = sys.stdin.readline()
    if not raw:
        emit("error", msg="empty stdin; expected request JSON on first line")
        return 2
    try:
        req = json.loads(raw)
    except json.JSONDecodeError as e:
        emit("error", msg=f"invalid request JSON: {e}")
        return 2

    action = req.get("action")
    try:
        from stealth import sync_playwright_module  # type: ignore[import-not-found]
    except ImportError as e:
        emit("error", msg=f"stealth helper missing: {e}")
        return 2

    headed = bool(req.get("headed"))
    try:
        with sync_playwright_module() as p:
            context = open_context(p, headed=headed)
            try:
                if action == "sync_orders":
                    return sync_orders(context, req)
                elif action == "sync_quotes":
                    return sync_quotes(context, req)
                elif action == "fetch_prices":
                    return fetch_prices(context, req)
                elif action == "set_store":
                    return set_store(context, req)
                elif action == "show_store":
                    return show_store(context, req)
                else:
                    emit("error", msg=f"unsupported action: {action!r}")
                    return 2
            finally:
                # If attached over CDP, leave the user's Chrome window open.
                from stealth import cdp_endpoint  # type: ignore[import-not-found]
                if not cdp_endpoint():
                    try:
                        context.close()
                    except Exception:  # noqa: BLE001
                        pass
    except Exception as e:  # noqa: BLE001
        emit("error", msg=f"{type(e).__name__}: {e}", trace=traceback.format_exc())
        return 1


if __name__ == "__main__":
    sys.exit(main())
