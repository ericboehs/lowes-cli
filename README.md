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
- **Orders** — pull order history per year into a local JSON store. Skips
  orders already on disk; `--full` re-fetches everything.
- **Quotes** — pull saved Lowe's quotes the same way.
- **Price checks** — fetch current price for any product URL, model #, or
  item ID. Records every check to a per-item NDJSON history file so you
  can chart price drift over time.
- **Materials list** — keep a watchlist of products; `lowes prices`
  refreshes every entry in one run.
- **JSON-first storage** under XDG paths — easy to grep, jq, or back up.

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
pyworker/
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
  "default_year_window": 2,
  "store_zip":        null,
  "output": { "color": true }
}
```

The `op://` references use the [1Password CLI](https://developer.1password.com/docs/cli/);
swap in your own password manager or just hardcode a value if you must.
The Python worker never logs the password.

## Use

Lowe's actively blocks vanilla automated browsers ("We're unable to sign you
in right now"). The reliable workaround is to attach to your real Chrome.app
over Chrome DevTools Protocol — `lowes chrome-start` launches Chrome with
remote-debugging enabled, you sign in once like a human, and every other
`lowes` command auto-detects the running Chrome and reuses it.

```bash
# 1) Launch a dedicated Chrome window with debugging on
lowes chrome-start
#    Sign in to Lowe's in this window once. Cookies persist in
#    ~/.local/share/lowes/cache/chrome-profile so this is a one-time step.

# 2) From any other terminal, run lowes commands as normal
lowes sync
lowes price 1001234
```

If you don't run `chrome-start`, lowes falls back to a plain automated
Chromium — fine for opening pages but Lowe's may refuse the login.

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
```

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
of `pyworker/fetch.py` (`ORDERS_EXTRACT_JS`, `QUOTES_EXTRACT_JS`,
`PRICE_EXTRACT_JS`) as JS strings that run in the page. Each extractor is
defensive — missing fields return `null` rather than crashing the run, so a
single broken selector won't kill a whole year of orders. When something
stops parsing, that's where to look first.

## License

MIT. See [LICENSE](./LICENSE).
