# lowes-cli

A personal Lowe's archiver and price tracker. Logs you in via a real browser
(handles captcha + 2FA), pulls your order history and saved quotes down into
a local JSON store, and tracks current prices for a list of materials you
care about — fully offline once synced.

There is no public Lowe's API for any of this; everything is Playwright
scraping behind the authenticated session. This repo is the glue: a Ruby
CLI, a Python Playwright worker, and an XDG-friendly JSON store.

```
$ lowes list --year 2025 --limit 5
date        order_id      total     status
2025-12-19  WB12345678    $187.42   Delivered
2025-11-30  WB12345677    $42.18    Delivered
2025-10-04  WB12345676    $1,205.99 Delivered

$ lowes materials add 2x4-stud --model 1001234 --nickname "2x4 stud"
$ lowes prices
fetched_at           model     title                                    price    status
2026-05-03T17:21:09  1001234   2-in x 4-in x 8-ft Premium Stud          $4.18    In Stock
...

$ lowes price 1001234 --history
fetched_at           model     title                              price    status
2026-04-12T18:00:01  1001234   2-in x 4-in x 8-ft Premium Stud    $4.06    In Stock
2026-05-03T17:21:09  1001234   2-in x 4-in x 8-ft Premium Stud    $4.18    In Stock
```

## Features

- **Real-browser login** — Playwright opens Chrome, you finish password +
  2FA + any captcha. Storage state persists; subsequent syncs are silent.
- **Headless by default** — everything but `lowes login` runs without a
  window, so a sync doesn't steal focus mid-sentence.
- **Orders** — pull order history per year into a local JSON store. Skips
  orders already on disk; `--full` re-fetches everything.
- **Quotes** — pull saved Lowe's quotes the same way.
- **Price checks** — fetch current price for any product URL, model #, or
  item ID. Records every check to a per-item NDJSON history file so you
  can chart price drift over time.
- **Materials list** — keep a watchlist of products; `lowes prices`
  refreshes every entry in one run.
- **JSON-first storage** under XDG paths — easy to grep, jq, or back up.
- **Local web UI** (`lowes web`) — Sinatra app at `localhost:4567` with
  search across order IDs, item titles, and model numbers; year filter
  pills; compact / comfortable / gallery density modes; per-year stats
  with totals; and item-level pages with line totals, per-unit pricing,
  and price history sparklines for tracked materials.

## Architecture

```
bin/lowes               Ruby entrypoint (subcommand dispatch)
lib/lowes/
  cli.rb                arg parsing, dispatch
  commands/             one class per subcommand
  config.rb             XDG paths, config load
  store.rb              orders / quotes / materials / price history
  worker.rb             spawns Python worker, parses NDJSON over stdout
  formatter.rb          tables, --json, color
  chrome.rb             headless/headed policy, CDP reachability, UA string
pyworker/
  stealth.py            attaches to that Chrome over CDP; the one seam
  fetch.py              one-shot worker; drives Playwright; emits NDJSON
  login.py              Playwright headed login; persists storage state
  pyproject.toml        deps: playwright
```

Two-process design: Ruby owns the CLI/UX/storage; Python owns the scraping.
The worker is a one-shot subprocess — no daemon. Communication is NDJSON
over stdout; OTP prompts round-trip through the worker's stdin.

## Storage layout (XDG)

```
~/.config/lowes/config.json                          # email + 1Password ref
~/.local/share/lowes/index.json                      # order_id / quote_id → file map
~/.local/share/lowes/orders/<year>/<id>.json         # one file per order
~/.local/share/lowes/quotes/<year>/<id>.json         # one file per quote
~/.local/share/lowes/materials.json                  # tracked materials list
~/.local/share/lowes/prices/<key>.ndjson             # price history per item
~/.local/share/lowes/cache/cookies.json              # session reuse (mode 600)
~/.local/share/lowes/cache/storage_state.json        # full Playwright state
~/.local/state/lowes/sync.log                        # sync history
```

## Setup

```bash
git clone https://github.com/ericboehs/lowes-cli ~/Code/ericboehs/lowes-cli
cd ~/Code/ericboehs/lowes-cli

# 1) Install Python deps
cd pyworker
uv venv && uv pip install -e .
uv run playwright install chromium

# 2) Symlink the entrypoint
chmod +x ../bin/lowes
ln -sf "$PWD/../bin/lowes" ~/bin/lowes

# 3) Create config
lowes config edit
```

`~/.config/lowes/config.json`:

```json
{
  "email":           "you@example.com",
  "password_op_ref": "op://Personal/Lowes/password",
  "otp_op_ref":       null,
  "default_year_window": 5,
  "store_zip":        null,
  "browser":          { "headless": true },
  "output": { "color": true }
}
```

`browser` also takes `binary` (path to Chrome) and `user_agent` (override the
string built from the binary's version — needed on a platform other than
macOS or Linux). Both are passed through to the Python worker as
`LOWES_CHROME_BINARY` / `LOWES_USER_AGENT`, so its fallback launcher names the
same browser the CLI does. Whatever you set, it must not contain
`HeadlessChrome`; that is the one token Akamai refuses outright.

The `op://` references use the [1Password CLI](https://developer.1password.com/docs/cli/);
swap in your own password manager or just hardcode a value if you must.
The Python worker never logs the password.

## Use

Lowe's actively blocks vanilla automated browsers ("We're unable to sign you
in right now"). The reliable workaround is to attach to your real Chrome.app
over Chrome DevTools Protocol — `lowes chrome-start` launches Chrome with
remote-debugging enabled, you sign in once like a human, and every other
`lowes` command auto-detects the running Chrome and reuses it. Started this
way, directly rather than through Playwright's launcher, Chrome was never in
automation mode, which is the whole reason the attach design exists.

```bash
# 1) Sign in once. This one needs a window — you're typing in it.
lowes login
#    Cookies persist in ~/.local/share/lowes/cache/chrome-profile,
#    so this is a one-time step.

# 2) From any other terminal, run lowes commands as normal
lowes sync
lowes price 1001234
```

Everything but `lowes login` runs **headless** — commands start Chrome on
demand and no window appears. Put the window back with any of:

```bash
lowes chrome-start --headed     # this launch
LOWES_HEADLESS=0 lowes sync     # this invocation
# or "browser": { "headless": false } in config.json, permanently
```

These decide how Chrome is *launched*, so they only bite when there is no
Chrome on port 9222 yet. A command that finds one already running attaches to
it as-is; to swap a headless Chrome for a windowed one, quit it first (or run
`lowes login`, which does that for you).

Headless costs one extra flag and it is not optional: Chrome names itself
`HeadlessChrome/<version>` in its own User-Agent, and Akamai answers **403
Access Denied** on that token before a byte of the page arrives — no `_abck`
cookie is ever issued, so no amount of fingerprint patching downstream can
help. `chrome-start` pairs `--headless` with a `--user-agent` built from the
version the binary reports about itself, and with it a cold profile gets the
real homepage and a validated `_abck` in about three seconds. The string is
built rather than hardcoded on purpose — a UA naming a Chrome older than the
engine behind it is a worse tell than `HeadlessChrome` was.

That leaves one gap the flag cannot close: a Chrome someone started by hand,
headless and without the override, looks exactly like a correct one until
lowes.com refuses it. So before any command uses the browser, `lowes` asks it
what it is going to say — `GET /json/version` on the debugging port returns the
User-Agent verbatim — and if the token is in there, says so up front instead of
letting it surface seconds later as a session error naming the wrong cause.
Only the positive answer means anything: a headless Chrome started the way this
tool starts one is overriding that string on purpose, so its absence is not
evidence of a window.

`lowes login` is always headed, and restarts a headless Chrome with a window
first if it finds one, because signing in to a browser you cannot see is a
ten-minute wait ending in a timeout.

If no Chrome is reachable and none can be started, commands stop with the
error rather than falling back — the Python worker can launch its own
persistent Chromium context (`pyworker/stealth.py`), but nothing in the CLI
reaches that path, and Lowe's tends to refuse a login through it anyway.

```bash
lowes login                    # one-time browser-based login (handles captcha + 2FA)

# Orders
lowes sync                     # default window (last 2 years)
lowes sync --year 2024
lowes sync --years 2023,2024,2025
lowes sync --full              # re-fetch everything

lowes list --year 2025 --limit 25
lowes show WB12345678
lowes search "treated lumber"
```

Lowe's order-detail pages sometimes render short, and for some older orders
they render no line content at all — a bare "Order Details" shell. The scraper
can't tell either from an order that genuinely had fewer items, so `sync`
handles it from both ends:

- **It looks twice.** A detail page that comes back with no line items gets
  reloaded once. Measured on a full re-sync, the reload recovered nothing — 0
  of 29 — so treat a warning as a page that is genuinely empty rather than a
  read worth retrying by hand. What the second look buys is that certainty.
- **It won't shrink an order.** A placed order does not lose line items after
  the fact, so the longer list wins and the sync names the orders it
  protected. Items still get corrected in place; only removal is refused.

If an order really did change, delete
`~/.local/share/lowes/orders/<year>/<id>.json` and sync again.

```bash
# Quotes
lowes quotes sync
lowes quotes list
lowes quotes show <quote-id>

# Price tracking
lowes materials add 1001234 --nickname "2x4 stud"
lowes materials add https://www.lowes.com/pd/.../1009876 --nickname "deck screw"
lowes materials list

lowes price 1001234            # one-off check (also records to history)
lowes price 1001234 --history  # show local history without hitting network

lowes prices                   # refresh every tracked material
lowes prices --only "2x4 stud" # just one

# Web UI
lowes web                      # http://127.0.0.1:4567
```

## Web UI

`lowes web` boots a local Sinatra app for browsing the synced data:

- `/`                — order list with search, year filter, density toggle, pagination
- `/?q=<query>`      — substring search over titles, models, item IDs; results
                       surface the matched item per order (not just `items[0]`)
- `/orders/:id`      — order detail with hero image, line totals, per-unit
                       breakdown for by-the-foot/roll items, ship-to, payment
- `/stats`           — yearly orders/totals/avg/largest with bar viz
- `/quotes`          — saved Lowe's quotes
- `/materials`       — tracked materials with sparklines
- `/prices/:key`     — full price history for one tracked item

Images route through a same-origin proxy (`/img?u=...`) that falls back to a
generic SVG placeholder when Lowe's returns 404 or its `no_image_available`
GIF for delisted products.

## Pricing schema

Items in saved order JSON normalize Lowe's quirky display:

| field         | meaning                                       |
|---------------|-----------------------------------------------|
| `price`       | per-unit, post-discount (e.g. `$0.92/ft`)     |
| `was_price`   | per-unit, pre-discount (null when not on sale)|
| `line_total`  | line total post-discount (`price × qty`, or DOM-extracted) |
| `line_was`    | line total pre-discount (DOM-extracted, else `was_price × qty`) |
| `quantity`    | qty as shown in `QTY N`                       |

Lowe's by-the-foot / by-the-roll products mix per-unit and line-total
strikethroughs; the worker picks both apart and stores them in canonical
fields, so the web UI doesn't need a heuristic.

## Tuning rate limits

Lowe's is more permissive than Amazon, but their bot detection is real.
Defaults are conservative; tune via `config.json`:

```json
{
  "rate_limit": {
    "detail_delay":  0.5,
    "detail_jitter": 0.25,
    "retry_backoff": [30, 60, 120]
  }
}
```

## Selectors and site drift

Lowe's HTML structure changes regularly. The extractors live near the top
of `pyworker/fetch.py` (`ORDERS_EXTRACT_JS`, `ORDER_DETAIL_EXTRACT_JS`,
`PRICE_EXTRACT_JS`) as JS strings that run in the page. Each extractor is
defensive — missing fields return `null` rather than crashing the run, so a
single broken selector won't kill a whole year of orders. When something
stops parsing, that's where to look first.

`sync` iterates years in quarterly date-range chunks
(`?startDate=YYYY-MM-DD&endDate=YYYY-MM-DD`), because the `?show=YYYY` view
silently caps at 50 orders per year — quarters dodge the cap.

Each chunk is checked against the store: orders don't leave a date range once
they're in it, so a quarter that returns fewer than the store already holds
means the page didn't load, the selector moved, or the list rendered short.
`sync` warns and names the range. Without that check the failure is invisible
— every step succeeds, and the run reports a clean finish over a quarter it
never read. (Measured: a full sync returned 313 of 323 orders and dropped all
of 2026 Q1 without printing anything.) Orders in a short quarter keep their
existing files; nothing is deleted.

## License

MIT. See [LICENSE](./LICENSE).
