# Creator bonds (押金承诺, GangBond)

A creator of a GangLaunchpad token can back a promise with money: **"my creating address keeps at least X tokens
until N days after the token reaches PancakeSwap."** The bond is paid in the token's quote (WBNB tokens: the CLI pays
native BNB). Whether the promise holds is read from the chain alone (`balanceOf(creator)`): no oracle, no platform
decision.

- **When**: any time after create — on the V3 curve (buy first: X can't exceed what the creator holds), during a 打新
  sale, or after graduation / launch. One bond per token at a time; after it ends (settled, refunded, or slashed and
  fully bought back) the creator may post a new one.
- **The clock**: the promise binds from the post. T = the moment the token reaches its pair (V3 graduation / 打新 launch)
  + N days (7–90); posted after that, T = post + N days. GangBond can't be told about a graduation, so anyone starts the
  clock with `gang bond start` (the keeper does it at once; any other bond write does it too).
- **Who**: only the token's creator posts, tops up, raises X or extends. Start, report, settle, refund and burn are open
  to anyone.
- **Endings**:
  - **settle** — at or after T, while the creator still holds ≥ X: the whole bond goes back to the creator (whoever sends
    it; the platform keeper does it at T). The time after T and before settle still counts.
  - **report** — any time before settle (on the curve too), once the creator holds < X: the reporter gets **1%** of the
    bond (none when the creator reports itself); the rest buys the token back from its pair in chunks and sends it to
    0xdead. Slashed before the pair, the buy-back waits for it; if there is still no pair 30 days after the post, the
    rest goes to 0xdead as quote.
  - **refund** — posted before the pair, still no pair 30 days after the post, X still held: the whole bond goes back to
    the creator (not counted as honored).
  There is **no other early withdrawal**. Selling on the curve, selling 打新 shares back, or moving tokens to another own
  wallet all count as a breach.
- **Buy-back** (`gang bond burn`, also the keeper every 10 minutes): one chunk per block, at most 0.5% of the pair's
  quote side. The first call after a slash only records a price observation; buying starts 10 minutes later and pauses
  while the price is more than 2% above its 10-minute average; after 20 minutes without a call the observation starts
  over. The token's buy tax applies to the buy-back as usual.
- **The record is not a reputation score**: `posted / honored / slashed` counts bonds of any size, and a tiny bond is
  cheap to honor. Read it next to the bond amounts.

## Coverage

`coverage = bond ÷ dumpValue`, where dumpValue is what selling X into the pair fetches now (after the sell tax, the
0.25% DEX fee and price impact). ≥ 100%: dumping X loses money. It falls when the price rises; `toFullCover` says how
much quote would bring it back to 100%. Tiers on gang.fun: ≥ 100% "押金全覆盖", 50–100% "押金", < 50% no badge.
Coverage is for display and screening only; it never decides where a bond goes. Before the pair there is no market
to price X: no coverage, no badge — show the bond amount and X (% of supply) instead, and `--cover` is not available.

## Commands

| Command | Who | What |
|---|---|---|
| `gang bond post --token <addr> --hold <tokens\|N%> --days <7-90> (--amount <quote> \| --cover <%>)` | creator | `--hold 1%` = 1% of the 1B supply; `--days` counts from graduation / launch (from now if already there); `--cover 100` posts exactly what dumping X fetches now (only once on the pair) |
| `gang bond topup --token <addr> (--amount <quote> \| --cover <%>)` | creator | add to the bond (`--cover` = target coverage, once running) |
| `gang bond raise-hold --token <addr> --hold <tokens\|N%>` | creator | raise X, up to the current balance |
| `gang bond extend --token <addr> --days <n>` | creator | lengthen the commitment: before the pair 90 days in all at most, after it a deadline at most 90 days from now |
| `gang bond status --token <addr>` | anyone | state, phase (pending / running), X vs balance (headroom), coverage + tier once on the pair, time left or refund date, buy-back progress, the creator's record |
| `gang bond start --token <addr>` | anyone | the token graduated / launched: start the clock (deadline = now + N days) |
| `gang bond report --token <addr>` | anyone | simulated first; nothing is built when the creator still holds ≥ X |
| `gang bond settle --token <addr>` | anyone | after T while X is held |
| `gang bond refund --token <addr>` | anyone | posted before the pair, no pair 30 days after the post, X held |
| `gang bond burn --token <addr> [--slippage 1]` | anyone | one buy-back chunk (or the observation / a skip, see above); slashed before the pair and still none 30 days after the post: the rest to 0xdead as quote |
| `gang bond tx --hash <0x..>` | anyone | decode GangBond events |

All take `--testnet`, `--calldata` (raw tx) and `--from <addr>` like `gang v3`. Writes print a preview → `gang execute`.
`post` / `topup` of a WBNB-quoted token pay native BNB; `--use-wbnb` pays WBNB instead (approve first, then re-run).
A `burn` preview made while no chunk is ready sends the maximum minimum: if a chunk has become buyable by the time it
lands, it reverts instead of buying unpriced; re-run for a priced preview.
GangBond is built in on BSC testnet (`--testnet`, `0x587f563749A321624b5710d6D77010F183a65d7E`); it is not on mainnet
yet, so without `--testnet` every `gang bond` command says it is not deployed (`GANG_BOND` / `GANG_TESTNET_BOND`
override).

## Sell protection

`gang v3 sell` (on the curve or in the pool), `gang fair sell` and `gang fair withdraw` (shares back while minting, each
share = 50,000 tokens) from the creator of a bonded token check the bond first:

1. The sell leaves less than X before T → refused (`error`, `maxSellKeepingBond`); `--break-bond` sends it anyway.
2. Past T (the clock running), not settled, and the sell leaves less than X → refused; `--settle-first` returns the settle tx first, then
   re-run the sell.
3. The sell leaves at least X → goes on; the preview carries `bondCheck.headroomAfter`.

This only covers the CLI. A sell on the PancakeSwap site or from another wallet is not stopped and loses the bond.
