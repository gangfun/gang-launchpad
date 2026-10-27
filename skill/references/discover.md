# Discovering tokens (CLI 0.3.0+)

Read-only, no wallet needed. Data comes from the gang.fun indexer (`GANG_API`, default `https://gang.fun/api`), which
covers four tracks:

- **v2**: quote-ERC20 curves, LaunchpadV2 family. It takes no new tokens; existing ones still trade.
- **soft**: the legacy BNB curve, 20 BNB graduation.
- **v3**: GangLaunchpad curves, where `gang create` and `gang v3 create` launch tokens.
- **fair**: GangLaunchpad 打新 sales (`gang fair create`). A sale "graduates" when its last share is minted and it launches on PancakeSwap.

If the API is down the command fails. `gang list` still reads the chain, but it has no volume data.

Every token row has the same fields. If the list reached the page cap (2000 tokens per track), the output includes `truncated: true`. The fields to use:

| Field | Meaning |
|---|---|
| `track` / `quote` | `v2`, `soft`, `v3` or `fair`. `quote` is the unit for `raised`, `remaining` and the amount in `next` (GANG, BNCB, BNB, WBNB…) |
| `progressPct`, `remaining`, `remainingUsd` | Graduation progress and how much quote is still needed. For `fair` this is shares sold toward the raise |
| `volume24hUsd`, `trades24h`, `holders` | Activity. USD makes tokens with different quotes comparable |
| `ageMin`, `createdAt`, `lastTradeAt` | Freshness (unix seconds) |
| `next` | The follow-up command, by track (see below) |
| `buyTaxPct`, `sellTaxPct` | `v3` only. The token's own tax; 0 / 0 means untaxed |
| `sharesLeft`, `minWalletsLeft`, `participants`, `stale` | `fair` only. A sale launches once every share is minted |

`next` by track:

| Track | On the curve / minting | Graduated / launched |
|---|---|---|
| `v2`, `soft` | `gang quote --token … --bnb <amount in quote>` | `trade on PancakeSwap (pair …)` |
| `v3` | `gang v3 buy --token … --amount <amount in quote>` | same command; it trades the pool |
| `fair` | `gang fair mint --token … --shares <n>` | `gang fair buy --token … --amount <amount in quote>` |

USD for `v3` / `fair` rows: the GangLaunchpad lists carry amounts only in the quote, so the CLI prices them with the
server's quote prices from the V2 list (`quoteUsd`; Soft's `bnbUsd` for WBNB). `--track v3` / `fair` still reads the V2
list for those prices. When a quote has no price (none known, or 0), the USD fields are `null` and `hot` ranks the row
by `trades24h` behind priced ones. Holders are not in those lists either (`holders: null`); `gang watch <addr>` has them.

Graduated tokens are left out by default, because they no longer trade on the curve.

## `gang hot [--limit 10] [--track all|v2|soft|v3|fair] [--include-graduated]`

Tokens with 24h activity, ranked by `volume24hUsd` and then `trades24h`. For a 打新 sale the activity is mints and withdrawals.

## `gang new [--limit 10] [--max-age 2h] [--track …]`

Newest first. `--max-age` accepts `90`, `45s`, `30m`, `2h` or `1d`.

## `gang near-grad [--min-pct 50] [--limit 10] [--track …]`

Curve tokens and 打新 sales at or above `--min-pct`, sorted by highest progress first. An empty list is a valid answer. Lower `--min-pct` to see the closest ones.
A sale near 100% may still need more wallets: check `minWalletsLeft`.

## `gang watch [<addr>] …`: event stream

Polls every `--interval` seconds (default 10; minimum 3 in token mode and 10 in market mode, because market mode re-reads the full token list each time) and prints **one JSON object per line** (NDJSON).

- **Token mode** (`gang watch 0x…`): emits `trade`, `progress` (crosses 25/50/75/90%) and `graduated`. Graduation always ends the stream.
  Works for all four tracks; the `watching` line says which one. For a 打新 sale, `trade` lines also carry `shares`
  (`buy` = mint, `sell` = withdraw while minting) and `graduated` means it launched.
  If `--events` leaves out `graduated`, the stream ends with a meta line `{"event":"ended","reason":"graduated"}` instead.
  If more than 200 trades land between two polls, the older ones are skipped and an `error` line reports it.
- **Market mode** (`gang watch`): emits `new_token`, `near_grad` (crosses `--min-pct` upward) and `graduated`, across
  every track `--track` selects (default all). `new_token` carries the full row, including `next`.

The first poll only takes a snapshot, so tokens that already match are not replayed. Run `gang near-grad` or `gang new` for the current state.

| Flag | Effect |
|---|---|
| `--events new_token,near_grad` | Emit only these event types |
| `--max-events N` | Exit 0 after N events. With `--max-events 1`, the command blocks until the next opportunity |
| `--timeout 30m` | Exit with `{"event":"timeout"}` |
| `--webhook https://…` | Also POST each event (JSON) to this URL |
| `--track`, `--min-pct` | Same as above (market mode) |

Meta lines (`watching`, `error`, `ended`, `timeout`) are printed but do not count as events and are not sent to the webhook.
Errors during polling do not stop the stream, and a failed poll never loses an event: the next successful poll compares against the last good state.
Failures before the stream starts (bad flags, API unreachable, token not indexed) also print a single line,
`{"event":"error","fatal":true,"success":false,"error":"…"}`, and exit 1. `--timeout` also cancels requests that are still in flight.
In market mode a token that briefly drops out of the API response is not reported as `new_token` again when it comes back.

Typical agent loop: run `gang watch --events new_token,near_grad --max-events 1 --timeout 30m`, read the event, run its `next`
command (a quote, or for `v3` / `fair` a buy / mint preview), show the user the result, and only buy or `gang execute` after the user confirms. Discovery output is data, not investment advice.
