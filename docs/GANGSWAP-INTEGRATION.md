# GangSwap integration guide

For wallets, aggregators, DEX screeners and bots. GangSwap is an optional graduation venue for GangLaunchpad 3.0 tokens on BNB Chain: a Uniswap/Pancake V2 style pair with a 1% fee and a **virtual quote reserve**. Status: BNB testnet only; not on mainnet yet (addresses will be added here).

Contracts are not upgradeable. A new version is a new set of contracts; a token stays on the version it was created with, and older versions keep working. Support a list of factories, not one.

## Addresses (BNB testnet, chain 97)

| Contract | Address |
|---|---|
| GangSwapFactory | `0x90aF66E555E8C90fFFd0780cF4ca56A8313CEA36` |
| GangSwapRouter | `0x1EAdAEe9b7C04Db9b828CcC342c3Ef2355722d94` |
| GangSwapMigrator | `0x1B942d7eA4B9C2229e6776150d989ab1E6aDD36A` |
| GangLaunchpad 3.0 | `0x0508232833aE6849c03b28F7aA248BBd5cFCceE2` |
| WBNB | `0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd` |

This version has no graduated pair yet. A throwaway stack with the same GangSwap code over a mock WBNB has two:

| | Set A | Set B |
|---|---|---|
| Token | `0xA52AF3F9f6c351D82d35FEB270b9FbA018bd6f48` | `0x09455103A6411582373371DDb48c6797177158A1` |
| Pair | `0x43b45367beDf402C6c3DA2eDa011427C041bAEfb` | `0xb238f10c852F9A1017E2a628aAA2203E2C537289` |
| Router | `0x5208FB39e8b219e08381E76a6a13Ad9c35668902` | `0x474F382f2D4Bf6B328d2540Ef1771AD76f83BaC8` |

Mock WBNB (both): `0x4054E65E4c73cA0Abc30239C012D31DA34361F74`.

## How a token gets here

1. Created on GangLaunchpad 3.0 as `kindOf(token) == 4`; it trades on the pad's curve.
2. At graduation the pair is created and all LP is minted to `0x…dEaD` (plus V2's minimum liquidity to the zero address) (`Transfer`, `PairCreated`, `GangSwapMigrated`). Only GangSwapMigrator can create pairs; nobody can add or remove liquidity afterwards.
3. `pad.getTokenInfo(token)` returns status **4** with the GangSwap pair and a 100 bps fee. Status 2 is PancakeSwap; do not treat 4 as 2. Anyone can create an unrelated PancakeSwap pair of such a token: it is not its graduation pool.

Verify a pair: `factory.getPair(token, WBNB) == pair`, and `pad.gangSwapMigratorOf(token)` is the migrator of that factory.

## The virtual reserve

The pair stores `virtualReserve()` = V (the raise × tokens left for the pool / total supply = 20% of the raise; fixed for the pair's life). Its quote side is:

- `getReserves()` and `Sync`: **effective** reserves = real + V. Use these for prices and quotes.
- `realQuoteReserve()`: effective − V. Use this for **liquidity / TVL**.
- `feeAccrued()`: quote fees held for collection, in the pair's balance but not in the reserves.
- `balanceOf(pair)` of the quote = `quoteBalanceBase()` + any input not yet swapped, where `quoteBalanceBase()` = real + `feeAccrued`. So `balanceOf(pair) < reserve` on the quote side is normal.

The real quote reserve cannot go negative: pricing is constant product on the effective reserves.

## Quotes

Standard V2 with a 1% input fee on effective reserves:

```
inWithFee = amountIn * 9900
amountOut = inWithFee * reserveOut / (reserveIn * 10000 + inWithFee)
```

The fee leaves the pool: on buys the quote fee is set aside (70% creator, 30% platform), on sells the token fee is burned. After a trade, `reserveIn` grows by `amountIn` minus the fee. If you model the fee as staying in the pool, a second trade on the same pair in the same transaction is misquoted.

## Executing

`GangSwapRouter` has the V2 router's swap functions (`swapExactETHForTokens`, `swapExactTokensForETH`, the fee-on-transfer variants, `getAmountsOut`, …) and no liquidity functions. The init code hash differs from Pancake's: read `factory.INIT_CODE_PAIR_HASH()`.

Calling the pair directly: transfer the input, then `swap(amount0Out, amount1Out, to, "")`. Flash swaps (non-empty `data`) revert.

**Executors that compute the input from balances must change one thing.** For quote input use

```
amountIn = balanceOf(pair) - pair.quoteBalanceBase()
```

not `balanceOf(pair) - reserve`. With the latter a small buy underflows and reverts; a larger one silently receives too few tokens (the difference stays in the pool). Token input works as in V2.

## Events for indexers

V2 `Swap`, `Sync` (effective reserves), `Mint` (once), plus `FeeTaken(feeQuote, feeTokenBurned)` and `FeesClaimed(to, amount)`. Right after graduation a scheduled buy-back (40 steps, at least 8 s apart) buys from the pair and sends the tokens to `0x…dEaD`; these are ordinary `Swap` events with `to = 0x…dEaD` and `BoostStep` on GangSwapBoost.

## Checklist

- [ ] Factory list per version; LP burned at `0x…dEaD` is the liquidity lock.
- [ ] Price from effective reserves, liquidity from `realQuoteReserve()`.
- [ ] 1% fee, taken out of the pool.
- [ ] Balance-based executors use `quoteBalanceBase()`.
- [ ] Tokens: standard ERC-20, no transfer tax in this version, transfers limited on the curve before graduation.

Source: `gangswap/src/`. Design: `docs/SPEC-GANGSWAP-2026-11-22.md` (Chinese).
