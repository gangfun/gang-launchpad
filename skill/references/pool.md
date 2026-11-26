# Pool trades (graduated / launched tokens)

Once a token has its PancakeSwap pair (a V3 or V2 / Soft / U / S token that graduated, a 打新 sale that launched),
`gang buy` / `gang sell` build the PancakeSwap trade through GangRouter. The pool has **no Agent gate and no wallet
cap**; the token's pool tax applies (a V3 token's own buy / sell tax, 打新 1%, taxed V2 and all S-track tokens 1%,
untaxed tokens none). Tokens and proceeds go straight to the wallet.

```bash
gang buy --token <addr> --amount <n> [--slippage 1] [--use-quote | --pay-bnb] [--testnet]
gang sell --token <addr> (--amount <tokens> | --all) [--slippage 1] [--to-bnb] [--testnet]
```

- **Buy** (`--amount` = what you pay): a WBNB-quoted (or Soft) token takes native BNB by default; `--use-quote` pays
  from WBNB. Another quote (e.g. a stock token) is paid in that quote; `--pay-bnb` pays native BNB routed
  WBNB → quote → token (needs a WBNB / quote pool on Pancake). `minTokensOut` = Pancake `getAmountsOut` less the buy
  tax, less `--slippage` (default 1%); `expectTokensBeforeTax` / `expectTokens` show both.
- **Sell** (`--amount <tokens>` or `--all`): pays the quote; `--to-bnb` pays native BNB. On a taxed GangLaunchpad token
  the minimum comes from the tax handler's quote for the next block (sell tax and the held tax sold first included,
  `quotedWith`), less `--slippage`; elsewhere from `getAmountsOut` less the sell tax. If a taxed token's quote can't be
  read, the sell fails rather than guess a minimum; likewise a trade whose token tax rates can't be read fails instead
  of assuming 0%. With no wallet at all (none signed in, no `--from`) a sell only returns `poolQuote`.
- **Gas**: a sell of a taxed GangLaunchpad token also sells a chunk of the tax it holds, so it needs about **700k gas**:
  let the wallet estimate it, or give at least **750k**. Too little reverts with `SwapBackOutOfGas`; the output says so
  in `gas`.
- **Approvals cover only this trade's amount**: a sell first returns `step: approve` (the token → the router), a quote
  buy `step: approve-quote` (and `wrap-bnb` before it when WBNB is short). Execute, then run the same command again
  (`next` / `then` show what follows). With `--calldata` all txs come at once in `steps[]`; the trade there is not
  simulated, since it needs the approve mined first.
- **The router is checked before any step**, since an approve to the wrong address would hand it the tokens. `… is not
  a GangRouter (…)` or `… is an older version without PancakeSwap trades` means no step is built: tell the user, and
  approve nothing to that address (a stray `GANG_ROUTER` / `GANG_TESTNET_ROUTER` override is the usual cause). The router is an upgradeable proxy whose upgrades go through a public 48-hour timelock held by
  the platform Safe.
- **Simulated before the preview.** A revert returns `success: false` with the reason and a `hint`:
  `TooLittleReceived` (`args: [received, minimum]`: re-run to re-quote, or raise `--slippage`), `Expired` (the 30-min
  `deadline` passed: re-run), or a Pancake / token reason. Other failures: `RPC error while …` (retry later),
  `PancakeSwap has no usable pool on the path …`, `… rounds to 0` (amount too small for the decimals). With `--calldata` such a tx comes back only as
  `unsentTxForInspection` with `doNotSend: true`: **do not send it**.
- No `--note` on a pool trade (`agentNote.reason`), and `--follow` is refused. A 打新 minter still earning its reward
  can't sell past `sellableBeforeOut` without `--confirm-out` ([fair.md](fair.md)); a creator with a bond can't sell
  below it without `--break-bond` ([bond.md](bond.md#sell-protection)).
- Output: `step: 'pool-buy' | 'pool-sell'`, `via: 'router'`, `function`, `path`, `spend` / `payWith`, `expectTokens` /
  `minTokensOut` or `amount` / `receive` / `expectOut` / `minOut`, `slippagePct`, `deadline`. Read the amounts, the tax
  and the minimum to the user before they confirm.

## GangSwap pools

A graduated `gangswap` token (`kind`, `venue: gangswap`) trades on its GangSwap pair through GangSwapRouter only; the rest of
this page (GangRouter, PancakeSwap, taxes) is not about it. Never build, suggest or approve a PancakeSwap or GangRouter
pool trade of it: a PancakeSwap pool of such a token was made by someone else.

- The same `gang buy` / `gang sell`: a buy pays BNB (`--use-quote` WBNB), a sell pays WBNB (`--to-bnb` BNB). 1% pool fee
  (`poolFeePct`), no token tax. Approvals are for this trade's amount, to that router.
- v1 charges the 1% fee in WBNB on buys (70% creator, 30% platform) and burns the 1% token fee on sells. v2 charges
  1% in WBNB on buys and sells. During the v2 buy-back, the minute after its last step and the first collection after
  that, the platform receives all fees. Later collections split 70% to the creator and 30% to the platform.
- The v1 buy-back takes about 40 steps over about five minutes. v2 takes about 40 to 140 steps, each capped at 0.5%
  of the effective WBNB reserve. Read the v2 fee window and buy-back progress in `gang info` or `gang status`.
- `minTokensOut` / `minOut` come from the pair's **effective** reserves; only its **real** BNB (`liquidity.realBnb`) can be
  paid out. v2 takes its quote from the pair's `getAmountOut`. The liquidity needed for a v2 sell (`poolQuoteOut`)
  includes the WBNB fee on top of the seller's quoted output. Relay `warning` when a trade is large against real
  liquidity, and `priceImpactPct`.
- **Versions:** a token stays on the GangSwap version (`gangSwap.migrator`) of its create forever, with its own router, even
  when new tokens get a later version or creation is closed; `gang buy` / `gang sell` use that version's router only.
- **The router is checked before any step** (its version and its code). `… is not this token's GangSwapRouter (…)`, `this CLI
  version knows no GangSwapRouter of this token's GangSwap version` or `no GangSwapRouter
  address …`: nothing is built. Tell the user to update the CLI; never name a router for them or trade it elsewhere.
- No `--note` / `--follow` / `--promoter`, as on any pool trade.

## How the pool tax is paid (GangLaunchpad tokens)

The tax is collected in the token and sold for the quote in small chunks: right before a taxed sell into the pool (at
most 25% of that sell), or by the platform keeper when no sells come. All chunks of a token in one block share a
budget of 0.5% of the pool's token side, and none sells while the price is more than 2% below where the block
started. So a sell fills a little below a plain `getAmountsOut` quote, which is why the CLI prices sells with the tax
handler. Each chunk's quote is paid out at once (recipient, holders' dividend / 打新 reward, platform).

- `gang info` → `swapBack` (read at `latestBlock`): `unsoldTaxTokens` (tax held, not sold yet), `budgetPerBlockTokens`,
  `budgetLeftInLatestBlockTokens`, `nextChunkTokens` (the largest chunk the latest block still allows),
  `lastChunkBlock`.
- `gang status` → `poolSellAll`: what selling the whole balance into the pool pays now: `expectOut`, and `minOut` at
  `--slippage` (default 1%). `gang sell --all` builds that sell. Any wallet holding the token gets it, including one
  that only bought in the pool.
