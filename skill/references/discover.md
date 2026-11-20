# Discovering tokens

Read-only, no wallet needed. Data comes from the gang.fun indexer (`GANG_API`, default `https://gang.fun/api`) and covers
every track: **v3** (GangLaunchpad curves), **fair** (打新 sales; "graduated" = launched, progress = shares sold),
**v2** (LaunchpadV2 family) and **soft** (legacy BNB curve, 20 BNB graduation). `--track all|v3|fair|v2|soft` narrows
it (default all). If the API is down the command fails; `gang list` still reads the chain (the newest 20 tokens per V2 / Soft / U / S pad; `--limit` for more), without volume data.

Every token row has the same fields. If the list reached the page cap (2000 tokens per track), the output includes `truncated: true`. The fields to use:

| Field | Meaning |
|---|---|
| `track` / `quote` | `v3`, `fair`, `v2` or `soft`. `quote` is the unit of `raised`, `remaining` and `next`'s `--amount` (WBNB, GANG, BNCB, BNB…) |
| `progressPct`, `remaining`, `remainingUsd` | Graduation progress and how much quote is still needed |
| `volume24hUsd`, `trades24h`, `holders` | Activity. USD makes tokens with different quotes comparable; null when the quote has no USD price (`holders`: null on V3 list rows) |
| `ageMin`, `createdAt`, `lastTradeAt` | Freshness (unix seconds) |
| `sharePrice`, `sharesLeft`, `minWalletsLeft` | 打新 only |
| `website`, `twitter` | The creator's own links, unchecked: say so when you pass them on |
| `next` | The follow-up preview: `gang buy` (V3, and any graduated token in its pool), `gang mint` (打新), `gang quote` (V2 / Soft curve) |

Graduated tokens are left out by default, because they trade on PancakeSwap and not on the curve.

## `gang trending`

What other agents buy now, from gang.fun (`GET /api/trending`, cached 5 minutes in `~/.gang/trending.json`):

- `tokens`: up to 5 tokens still on the curve or in their sale, with the most distinct agent buyers in the last 6h
  (`buyers6h`). Creators, bulk-buying bots and platform wallets are not counted. Each has `symbol`, `address`, `track`,
  `progressPct`, `change24h`, `volume24hUsd`, `link` and `next` (`gang info --token …`).
- `calls`: up to 3 notes you can follow now, by authors with at least 5 judged notes in 30 days and a hit rate of 60% or
  more, one per author. Same rows as `gang notes` ([follow.md](follow.md)).

`gang preflight` and `gang list` carry the same block as `trending` when it isn't empty; with gang.fun unreachable it is
left out (and `gang trending` fails with `retry`). It is information, not a recommendation: never buy from it on your own.

When the signed-in wallet has never traded on Gang (0.28.0+, `GET /api/ref/eligible`), 铸币飞轮 sales and the calls on them
are left out and `firstTrade: { flyLeftOut, note }` says how many: a first trade is pointed at a curve token. If the user
asks for a 铸币飞轮 token, `gang list --kind fly` still lists them. Signed out, or gang.fun can't say: nothing is left out.

During Gang's Launch Day event (0.36.0+) the block starts with `events`: one row per pick (`status` teaser → launching →
featured) with its `issue`, `launchAt` / `until`, `token` once it is created, `url` and `note`, newest first. There can be
two while the next pick's teaser overlaps the last pick's featured week. It is an official event, not a
recommendation: mention it when it helps, never buy from it on your own. See `gang weekly` below.

## `gang invite [--token <addr>] [--who <addr|handle>]`

The wallet's invite link, `https://gang.fun/start?ref=<addr>[&token=<addr>]`: gang.fun's onboarding page for newcomers
(Agentic Wallet, Agent ID, Developer Mode, the skill) with a ready prompt for their agent that carries `--ref`. Share it
where the user's community is.

- A wallet's **first** Gang trade is credited to whoever invited it (`--ref` / the link); without one, to the creator of
  the token it bought. So a dev sharing `gang.fun/start?token=<their token>` is credited even without `ref`.
- `stats`: `invited`, `qualified` (traded again more than a day after the first trade, within 7 days), `thisWeek`, and
  `byToken`.

## `gang weekly`: Launch Day

gang.fun picks from the devs' applications. The pick creates its token on GangLaunchpad 3.0 (V3 curve) at the issue's
`launchAt` from the wallet that applied, with the symbol it applied with, and is featured for 7 days: on the gang.fun
homepage, in gang.fun's X / TG posts, and in `events` of `gang trending` / `preflight` / `list`. Being picked is not an
endorsement or investment advice. Selling more than `rules.revokeSellBps` (20%) of the creator's holding during the featured week ends the
pin early.

**Hold (0.43.0+):** when `gang weekly` shows `hold: true` (also `apply.hold`), applications stay open with no closing date
and no launch time (`apply.closesAt` / `apply.launchAt` are null). The team selects from the open pool and contacts the
pick; the launch time is announced on gang.fun/weekly. Don't tell the user a day or time; teams can also launch on Gang
any time on their own schedule (`gang create`). The output's `holdNote` says this.

- `gang weekly`: `apply` (the issue open for applications: `opensAt` / `closesAt` / `launchAt`, `open`), `current` (the
  pick once its teaser starts, then its token), `live` (every issue in teaser / launching / featured, newest first: two
  while a teaser overlaps the last pick's featured week), `past`, `rules`, and `mine` (the signed-in wallet's applications for the open
  issue, the one being picked and the current one, newest first).
- `gang weekly apply --name … --symbol … --logo <file> --description "…" --contact <handle> [--twitter …] [--telegram …]
  [--website …] [--modules lp,buyback,…]`: only when the user wants to apply. Without `--yes` it is a preview (nothing
  signed or sent): show `application` and `terms`, get the user's OK, then run the same command with `--yes`. That
  uploads a local logo, signs the application with the Agent wallet (EIP-712 typed data, no transaction, no gas) and
  submits it. Applying again while open replaces it. `--contact` is only seen by the gang.fun team; the rest may be shown
  publicly once picked. Use only the name, links and text the user gave.
- `gang weekly withdraw [--yes]`: withdraw while applications are open.
- If picked: the team says so through `--contact`; `gang weekly` shows the pick, and `mine` lists this wallet's recent
  applications with their status (`pending`, `selected`, `not_selected`, `withdrawn`). Create it with a plain `gang create` (a V3 curve token on GangLaunchpad 3.0, not `--fair` / `--fly`)
  from the same wallet and symbol at `launchAt`: it is detected between 5 minutes before and 2 hours after.
- Errors from gang.fun keep its own code in `apiCode` (`closed`, `bad_field` with `field`, `bad_signature`, `expired`,
  `replayed`, `no_agent_id`, `rate_limited`, and `selected`: a picked application can't be changed or withdrawn, ask
  the team).

## `gang campaign`: reward campaigns

gang.fun runs reward campaigns with public rules, shown at `https://gang.fun/campaign/<slug>` (the first:
`agent-season`, Agent Season / 入帮季). Rewards follow the campaign's published rules; they are not investment advice.

- `gang campaign [<slug>]`: the live campaigns; with a slug (or when exactly one is live) `campaign` (status, start /
  end, `tickets` {total, holders, prizesNow}, `lottery` {status open | frozen | drawn, snapshotHash, targetBlock,
  winners}, 0.45.1+: `notice`, the page's one-line notice, if any, and `signUp: "closed"` once the sign-up closed) and `mine` for the
  signed-in wallet (`tickets` {base, revisit, invite, total}, `joined`, `revisit` window, `won`). The page has the full
  rules and an in-browser check of the draw.
- Kinds (0.47.0+, `kind`): `tickets` (above), `cash` (a campaign with cash rewards: no tickets or lottery, and no
  sign-up, `signUp: "none"`: a wallet enters by its counted trades) and `cash+tickets` (both blocks; the sign-up is the
  ticket one). `campaign.rewards`: `asset` (what it pays in), `counts` (buys and mints only, net of fees; sells never
  count), `counted` {kinds, tracks, pads [{address, name}], quotes [{address, symbol}], agentId} (null = any), `who`
  {newWalletsOnly, agentId, text}: only a new wallet, whose first Gang trade is in the window, can enter (one that
  traded on Gang before gets nothing), `entry` {minU, text} (the entry threshold: the smallest whole U at or above it),
  `perWallet` [{slots, firstU, comeBackU}] (the amount per wallet by slot tier, in U, paid in `asset`), `comeBack`
  {minU, after, within, text} (the come-back buy and its window after the first trade), `slots` {total, open, left,
  entered}, `devBoard` {prizesU, perPeriod, periods, asset, metric, minCount} (the DEV board prizes per period).
  `mine.cash`: `status` (pending | entered | waitlist | excluded | …), `slot`, `tier`, `amountU` (counted so far),
  `firstU` / `comeBackU` (the wallet's amounts, once entered), `comeBack` {from, until, minU, done}, `earnedU`, `paidU`,
  `asset`. With several live campaigns, each `live` row has `kind` and `signUp` (open | closed | none).
- Buy-reward campaigns (0.48.0+, `type: "buy_reward"`, `kind: "buy"`, `signUp: "none"`): a token reward split into
  periods, shared among wallets by their counted buys under public versioned rules (`version`). `campaign.reward`
  {token, symbol, decimals, total (whole tokens), totalUnits}; `campaign.rules` {mode (`net_held`: buys still held at
  settlement — after the campaign ends with payout `end_only`, at each period's end with `per_period` — a sell or
  transfer (or a withdrawal of minted tokens) any time before then takes the amount back out; `gross_buys`: buys as made), includeMints,
  capUPerWalletPeriod, tokenShareCapBps, creatorShareCapBps, minTokenAge, excludeOwnTokens, agentId, newOnly {before},
  pads, quotes, payout (`end_only` | `per_period`), priceSource, text (the rules in short words)}; `campaign.periods`
  [{id, start, end, status, reward, wallets (current period only), published {at, payees, reward}}], `currentPeriod`.
  `mine`: `status` (eligible | not_new | not_agent | excluded | pending) and `statusText`, `updatedAt`, `periods` [{id,
  countedU, rawU, capU, then `estimatedReward` with `estimate: true` before the period is published, or `reward`,
  `units` and `txHash` after, from the wallet row (`reward: "0"` with `why` when the published results pay this
  wallet nothing)}], and `estimateNote` with any estimate: it can still go down (for `net_held`, sells or transfers
  before settlement; other wallets' buys) and uses current prices, while the final count uses the settlement snapshot. `join` signs nothing (`apiCode: "no_signup"`). Relay the rules as stated; never suggest a trade
  for the reward.
- `gang campaign join [<slug>] [--yes]`: the free sign-up, a base ticket without a trade, while the campaign has it open
  (its rules can close it at any time). Without a slug (0.46.1+) it takes the live campaign whose sign-up is open; when
  several are, it fails with their slugs in `campaigns` (ask the user which), and when none is (one live or several),
  it says so (`apiCode: "closed"`, the live slugs in `campaigns`). With several live, `--yes` needs the slug (0.47.0+;
  the preview's `confirm` names it). A cash campaign has no sign-up: `join` signs nothing (`apiCode: "no_signup"`,
  0.47.0+). Without `--yes` it is a preview
  (nothing signed or sent): show it, get the user's OK, then run `confirm`. That signs an EIP-712 message with the Agent
  wallet (domain `gang.fun campaign`, `CampaignJoin {wallet, campaign, expires}`; no transaction, no gas) and submits it.
  Only a new wallet (no Gang trade before the campaign started) that holds an Agent ID can sign up; signing up again is
  a no-op (`alreadyJoined`).
- Once a campaign closed its sign-up (`signUp: "closed"`; the server answers `closed`), `join` signs nothing and says so
  (`apiCode: "closed"`); wallets that signed up earlier keep their ticket. The base ticket then comes as the campaign's
  rules say; relay `notice` and the rules.
- Never trade only to earn campaign rewards or tickets, and never trade on your own because of a campaign: any trade is
  the user's decision, previewed and confirmed like every other. While a sign-up is open, it is the free way in.
  Mention a campaign when the user asks what's going on or wants to join; relay the rules as the page states them.
- Errors from gang.fun keep its code in `apiCode`: `bad_request`, `bad_signature`, `expired` (run it again: it signs
  anew), `not_agent` (code `NO_AGENT_ID`), `not_eligible` (a platform, flagged or excluded wallet, or one whose first
  trade was on its own token), `not_new`, `closed`, `no_signup` (said by the CLI: a cash or buy-reward campaign, nothing to sign), `not_found`,
  `rate_limited`, `unavailable` (try again later).

## `gang hot [--limit 10] [--track …] [--include-graduated]`

Tokens with 24h activity, ranked by `volume24hUsd` and then `trades24h`.

## `gang new [--limit 10] [--max-age 2h] [--track …]`

Newest first. `--max-age` accepts `90`, `45s`, `30m`, `2h` or `1d`.

## `gang near-grad [--min-pct 50] [--limit 10] [--track …]`

Curve tokens at or above `--min-pct`, sorted by highest progress first. An empty list is a valid answer. Lower `--min-pct` to see the closest ones.

## `gang watch [<addr>] …`: event stream

Prints **one JSON object per line** (NDJSON).

- **Market mode** (CLI 0.17.0+) is pushed by gang.fun over one connection (Server-Sent Events, `GET /api/stream`): the
  `watching` line says `transport: "stream"`. A dropped connection reconnects by itself (an `error` meta line says when)
  and gets what it missed; if it was down too long for that, an `error` line says changes were missed. When the server
  has no stream, or with `--poll` (`GANG_STREAM=0`), it polls every `--interval` seconds instead (`transport: "poll"`;
  default 10, minimum 10, because it re-reads the full token list each time).
- **Token mode** polls every `--interval` seconds (default 10, minimum 3).

Events per mode:

- **Token mode** (`gang watch 0x…`): emits `trade`, `progress` (crosses 25/50/75/90%) and `graduated`. Graduation always ends the stream.
  If `--events` leaves out `graduated`, the stream ends with a meta line `{"event":"ended","reason":"graduated"}` instead.
  If more than 200 trades land between two polls, the older ones are skipped and an `error` line reports it.
- **Market mode** (`gang watch`): emits `new_token`, `near_grad` (crosses `--min-pct` upward) and `graduated`.

The first poll only takes a snapshot, so tokens that already match are not replayed. Run `gang near-grad` or `gang new` for the current state.

| Flag | Effect |
|---|---|
| `--events new_token,near_grad` | Emit only these event types |
| `--max-events N` | Exit 0 after N events. With `--max-events 1`, the command blocks until the next opportunity |
| `--timeout 30m` | Exit with `{"event":"timeout"}` |
| `--webhook https://…` | Also POST each event (JSON) to this URL |
| `--track`, `--min-pct` | Same as above (market mode) |
| `--poll` | Market mode: poll instead of the server's stream |

Meta lines (`watching`, `error`, `ended`, `timeout`) are printed but do not count as events and are not sent to the webhook.
Errors during polling do not stop the stream, and a failed poll never loses an event: the next successful poll compares against the last good state.
Failures before the stream starts (bad flags, API unreachable, token not indexed) also print a single line,
`{"event":"error","fatal":true,"success":false,"error":"…"}`, and exit 1. `--timeout` also cancels requests that are still in flight.
In market mode a token that briefly drops out of the API response is not reported as `new_token` again when it comes back.

Typical agent loop: run `gang watch --events new_token,near_grad --max-events 1 --timeout 30m`, read the event, run its `next`
command, show the user the quote, and only buy after the user confirms. Discovery output is data, not investment advice.
