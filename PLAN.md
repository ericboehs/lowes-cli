# PLAN — Quote CRUD against lowes.com

`lowes-cli` mirrors the lowes.com Pro Quotes feature directly. There are no
local drafts; every read and mutation hits the reverse-engineered
`/digitalpro/api/quote/*` REST API. Cookies come from a running Chrome
instance and auto-refresh on 403 (Akamai bot cookies rotate every few
minutes).

## Architecture

| Concern | File | What it does |
|---|---|---|
| API client | `lib/lowes/client.rb` | Net::HTTP wrapper around `/digitalpro/api/quote/*`. Reads cookies from `storage_state.json`; on 403 calls `Client.refresh_cookies!` (CDP `Storage.getCookies`) and retries once. Stdlib-only WebSocket implementation for the CDP call. |
| CLI dispatch | `lib/lowes/commands/quotes.rb` | All subcommands fan out to `Lowes::Client`. No local quote storage. |
| Login flow | `lib/lowes/commands/login.rb` | Drives Chrome via Playwright to authenticate and dump initial cookies. After that, `Client.refresh_cookies!` keeps the session warm. |
| Config | `lib/lowes/config.rb` | XDG paths; `storage_state.json` lives at `cache_dir/storage_state.json`. |

### Subcommands

| Subcommand | Calls |
|---|---|
| `quotes list [--status ...] [--limit N] [--json]` | `client.search` |
| `quotes show <id>` | `client.get_quote` |
| `quotes new --name NAME [--note ...] [--po ...]` | `client.create_quote` |
| `quotes delete <id> [-y]` | `client.delete_quote` |
| `quotes clone <id> [--name NAME]` | `client.duplicate_quote` |
| `quotes add <id> <url\|item-id> [--qty N]` | `client.add_items` |
| `quotes remove <id> <line-id> [-y]` | `client.remove_item` |
| `quotes set <id> [--name ...] [--note ...] [--po ...] [--qty LINE_ID=N ...]` | `client.update_quote` + `client.update_item_quantity` |
| `quotes refresh <id>` | `client.refresh_quote` |
| `quotes refresh-cookies` | `Client.refresh_cookies!` |

`add` accepts either a numeric omniItemId or a Lowe's product URL whose path
ends in `/<digits>`. The trailing-digits segment of a `/pd/<slug>/<digits>`
URL **is** the omniItemId — no scraping or model lookup needed. The
resolver also handles bare hosts (`lowes.com/pd/...`), strips query/fragment,
and unwraps `lowes.com/redir?u=<encoded>` share links.

## API endpoints used (relative to `https://www.lowes.com/digitalpro/api/quote`)

- `POST /search` — body `{}`. Header `x-support-store-quotes: true`.
- `GET /<quoteId>` — full `quoteDetail` with `cartItems`, `cartSummary`. Headers `x-support-store-quotes`, `x-enable-quote-services`.
- `POST /create` — body `{quoteDescription, poNumber, comment, emptyQuote, address}`.
- `PATCH /<quoteId>` — body subset of `{quoteDescription, poNumber, comment}`.
- `DELETE /<quoteId>`.
- `POST /<quoteId>/refresh` — re-prices the quote.
- `POST /<quoteId>/duplicate` — body `{quoteDescription, poNumber, comment}`.
- `POST /<quoteId>/items[?retainQuotePrice=true]` — body `{items:[{productInfo:{omniItemId},quantity}, ...]}` (set `bulkUpdate:true` for bulk).
- `DELETE /<quoteId>/items/<lineId>[?retainQuotePrice=true]`.
- `PATCH /<quoteId>/items/<lineId>/quantity[?retainQuotePrice=true]` — body `{itemQty}`.
- `PATCH /<quoteId>/items/<lineId>/store[?retainQuotePrice=true]` — body `{storeId}` (not yet wired).
- `PATCH /<quoteId>/shippingaddress` (not yet wired).

## Auth — Akamai cookies are the gate

lowes.com sits behind Akamai Bot Manager. The bot cookies (`_abck`, `bm_sz`,
`bm_mi`, `bm_so`, `bm_lso`, `bm_sv`, `BTProtect`, `al_sess`) rotate every
few minutes. A `storage_state.json` more than ~10–30 minutes old → 403 on
every call. `Client.refresh_cookies!` dumps fresh cookies from the live
Chrome session via CDP `Storage.getCookies` and rewrites the file.

The CLI registers `auto_refresh: true` on its `Lowes::Client` instance, so
the first 403 of a session triggers one transparent retry. If that retry
also fails the user gets a `Lowes::Client::Error` with status code.

## Tests

- `test/lowes/client_test.rb` — every URL/method/body shape, cookie filtering, 403/error mapping. Stubs `Net::HTTP.start` so no live HTTP fires.
- `test/lowes/commands/quotes_crud_test.rb` — every subcommand against an injected `StubOnlineClient` that records calls.

## Reverse-engineering recipe (preserved for future endpoint mapping)

1. Drive a UI action via React fiber: `el[Object.keys(el).find(k=>k.startsWith('__reactProps'))].onClick(mockEvent)` — synthetic CDP `Input.dispatchMouseEvent` doesn't fire React onClick.
2. Capture via page-side `fetch` hook installed with `Page.addScriptToEvaluateOnNewDocument` (survives reloads). For redirect-prone actions (delete), also use CDP `Network.enable`.
3. For mutations whose XHR you can't easily trigger, walk the React fiber from the trigger button up via `.return`, call `.toString()` on each ancestor `type`/`render` whose source mentions the action keyword. The minified saga source includes the relative URL string literal.
4. Bundle URL pattern: `https://www.lowescdn.com/digital-quotes/<hash>/client.<hash>.js`. Save to `/tmp/quotes-bundle.js` and grep for `axios.delete|method:"DELETE"|.post(|.patch(` plus the saga config name `PURCHASE_ONLINE_QUOTE`.

## Open

- Web UI (`web.rb`) still references the old local-quote shape; it should be refactored to call the same `Lowes::Client`.
- `add` does **not** translate the human-facing "Item #" (`itemNumber`, e.g. `28828201`) to an `omniItemId`. If a user pastes an item-number, the API returns `Missing product details for OmniItemId <n>`. A lookup step (likely `GET /digitalpro/api/product/search/items?searchTerms=<n>`) would close this gap, but the canonical PDP URL workflow already gets the right id from path-tail extraction.

## Pricing model (cartItems[*].priceInfo.prices)

Each line carries a `priceInfo.prices[]` array of records keyed by `priceType`:

| priceType | Meaning |
|---|---|
| `BASE`, `RETAIL`, `FINAL` | List/regular unit price (typically all equal) |
| `LAST_UNLOCK_PRICE` | Effective unit price after discounts |

`cartSummary` carries the rolled-up totals:

- `subtotal` = post-discount subtotal
- `subTotalWithOutDiscount` = list-price subtotal
- `totalDiscount` / `totalSaving` = dollar savings
- `savingsPercentage` = pre-rounded savings %
- `totalSavingSummary` = labels for active discount sources (e.g. `["Member Volume Discount"]`)
- `vspApplied` (top-level) = whether the Pro VSP / Member Volume Discount tier applied
