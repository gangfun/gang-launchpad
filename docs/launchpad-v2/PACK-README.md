# Gang LaunchpadV2 · Dual-Track (Taxed / Untaxed)

> Repo layout: sources are `src/launchpad-v2/` (not a nested Foundry project). Tests are `test/launchpad-v2/`. Unit tests: `forge test --match-path test/launchpad-v2/LaunchpadV2.t.sol`. Fork tests in `V2E2E.t.sol` run only when `BSC_RPC_URL` is set. Live addresses: [`../MAINNET-LAUNCHPAD-V2-ADDRESSES-2026-10-23.md`](../MAINNET-LAUNCHPAD-V2-ADDRESSES-2026-10-23.md). Do not broadcast.

一合约双模式发射垫（Lazy 2026-10-23 拍板）。**禁止主网广播。**

## 布局

```
src/LaunchpadV2.sol          # 主合约
src/LaunchToken.sol          # 无税轨代币
src/TaxLaunchToken.sol       # 有税轨（外盘 1% pair-only）
src/MigratorV2.sol
src/DividendVault.sol        # 门槛 >10_000 tokens
src/PostGradTaxHandler.sol
src/PlatformFeeBucket.sol
src/PoolCheck.sol
src/BuybackBurner.sol        # 源码；主网复用现网地址
src/QuoteRegistry.sol        # ops override only
test/LaunchpadV2.t.sol
docs/IMPLEMENTATION-ORDER.md
docs/DIFF-VS-LIVE.md
```

## 测试

```bash
export PATH="$HOME/.foundry/bin:$PATH"
forge test -vv
```

## 共享主网依赖（不新部署）

- BuybackBurner `0x2aC14C462901F990ae7647D6AcafEaf50Cc8f8dF`
- feeVault `0x3464aa1097Aa46502Db847E4c6d0A2D52a871Af4`
- GANG `0x0c6302401aa5325C2E36F170f52C00B1d220B405`

## REFPOOL (2026-10-23) — dev-supplied reference pool, V2 pair or V3 pool

`create(name, symbol, logoURI, taxed, quote, refPool)`:
- `quote == address(0)` → WBNB, target = 15 BNB, `refPool` ignored.
- `QuoteRegistry.graduationAmount(quote) > 0` → ops override, `refPool` optional (validated if given).
- otherwise `refPool` is REQUIRED: a canonical Pancake V2 pair or V3 pool containing `quote`.
  - V2: price from reserves. V3: TWAP over `twapWindow` (default 1800s) via `observe()`, spot fallback.
  - other side == WBNB → target = 15 BNB in that pool.
  - other side != WBNB (USDT, USD1, …) → owner must have `setBridgePool(asset, assetWbnbPool)`; 15 BNB is converted
    to the asset through the bridge, then to quote through the reference pool.
  - reference pool must hold ≥ `MIN_REF_DEPTH_BNB` (1 BNB) worth of the other side, else `ThinReferencePool`.
- Both tracks share the same input rules (untaxed no longer rejects pool input).

Owner wiring (in addition to the existing list): `setV3Factory(0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865)`;
`setBridgePool(USDT, <USDT/WBNB V3 0.05% pool>)` and the same for USD1 / other stables you want to accept.
FE preview: `graduationAmountOf(quote, refPool)` (reverts with the same errors as create).

Removed: `defaultGraduationQuoteAmount` / `setDefaultGraduationQuoteAmount`, `MIN_RESERVE_WBNB`,
`PoolCheck.resolveQuoteAndPair / resolveQuoteIdentity / spotGradAmt / hasReserves`.
New file: `src/libraries/TickMath.sol` (Uniswap V3 core, GPL-2.0-or-later).

Verified on BSC mainnet fork (`test/V2E2E.t.sol`, 8 tests): NVDAB via V3 NVDAB/USDT 0.25% → 52.50 NVDAB
(spot-derived 52.45); via V2 NVDAB/WBNB → 52.49; USDT quote → 11,222 USDT; fake pool / wrong quote / no pool revert;
full create → graduate → DEX tax → process → V2 + Smart Router buyback.
