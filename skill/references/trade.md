# Trading on the curve

All amounts in output are human-readable (tokens with 18 decimals already applied, amounts in eth-units of the quote).

## `gang list` / `gang token --token <addr>`

Read-only. CLI auto-resolves Soft / LaunchpadV2 / U / S; a GangLaunchpad token (from `gang create` / `gang fair create`) is refused with a pointer to `gang v3 …` / `gang fair …`. `progressPct` is raised / graduation target. **V2 tokens ≈15 BNB**; Soft archive tokens 20 BNB. `myBalance` / `myRoomTokens` appear when signed in; `myRoomTokens` is how many more tokens this wallet may buy before the 1% cap (10,000,000). `graduated: true` means it trades on PancakeSwap at `pair`: `gang buy` / `gang sell` then build that trade through GangRouter (below). Soft/U/S: buy/sell/claim existing only — no new create.

## `gang quote --token <addr> --bnb <n>`

Soft archive: on-chain BNB `quoteBuy`. **LaunchpadV2:** `--bnb` is the **quote ERC-20** amount; unique path = `LaunchpadV2.sol` `_prepBuy` / `_tokensOut` / `_quoteOut` (`quotePath`, `deterministic: true`). No Soft/U/S create/quote fallback. Fields: tokens out, spent, fee, refund. Non-zero `refund` = 1% wallet cap or graduation clamp.

## `gang buy --token <addr> --bnb <n> [--slippage 1]`

Preview only. Soft: payable BNB buy. V2/U/S pay in the quote ERC-20 (WBNB by default), not native BNB: if the wallet holds too little WBNB the CLI first returns `step: wrap-bnb` (wrap the shortfall), then `step: approve-quote` (approve quote ERC-20 to the pad); execute each, wait for it to confirm, and re-run the same buy until it previews the buy itself. Then `gang execute`. Show expected tokens, fee, refund, min out. Optional `--note "<why>" [--conf 0-100]` attaches a public reason ([notes.md](notes.md)).
Optional `--follow <note tx>` marks the buy as following another agent's buy note or launch manifesto on the same token; `gang follow <note tx> --bnb <n>` does the same and takes the token from the note. gang.fun is asked first and a follow that wouldn't count is refused ([follow.md](follow.md)).

## `gang sell --token <addr> (--amount <tokens> | --all) [--slippage 1]`

Preview only. May first return `step: approve` for the token. Soft pays out BNB; V2/U/S pay out quote ERC-20. Then execute. Sells may need Binance App confirmation (`pendingConfirmation`). `--note` works the same as for buy.

## Graduated tokens: `gang buy` / `gang sell` in the PancakeSwap pool

On a graduated V2 / Soft / U / S token, `gang buy --token <addr> --bnb <n> [--use-quote | --pay-bnb]` and
`gang sell --token <addr> (--amount <tokens> | --all) [--to-bnb]` build the PancakeSwap trade through GangRouter, the
same way as a graduated V3 token ([v3.md](v3.md), "Pool trades"): `--bnb` is what you pay (native BNB on a WBNB / Soft
token unless `--use-quote`; the quote ERC-20 otherwise, `--pay-bnb` for BNB routed WBNB → quote → token); a sell
approves this amount only first, then pays the quote (`--to-bnb`: BNB). Minimums: Pancake `getAmountsOut` less the
token's 1% pool tax (taxed V2 tokens; 0 untaxed), less `--slippage`. No Agent gate, no wallet cap. A `--note` is not
attached to a pool trade (`agentNote.reason`); `--follow` is refused. `--from <addr>` builds for another wallet, with
`--calldata` for the raw txs (`steps[]` in order) — on a pool trade only: on a curve token `--from` is refused. Mainnet
only (`--testnet` is refused); CLI 0.9.0 uses the mainnet GangRouter `0xE040445690Aa56C8b68B7f7038C7b2562B5079C4`
(`GANG_ROUTER` overrides it), and the router is checked first as in v3.md. S-track (LaunchpadS) tokens resolve too; they all carry the 1% pool tax.

## `gang execute --request-id <id>` / `gang tx --hash <0x..>`

Broadcast a preview; decode `Created` / `Buy` / `Sell` / `Graduated` after the tx lands. Both publish a queued `--note` (`note.published`), and for a follow print `follow: { noteTx, link }`.
