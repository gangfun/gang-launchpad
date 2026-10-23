# LaunchpadV2 · 实现顺序

> 本仓库路径：`src/launchpad-v2/`、`test/launchpad-v2/`。已部署，见 [`../MAINNET-LAUNCHPAD-V2-ADDRESSES-2026-10-23.md`](../MAINNET-LAUNCHPAD-V2-ADDRESSES-2026-10-23.md)。不要再次广播。

- 日期：2026-10-23 Asia/Shanghai
- 规格：`/workspace/baw-real-check/SPEC-DUAL-TRACK-TAXED-UNTAXED-2026-10-23.md`
- **禁止主网/测试网广播**（本包仅源码+Forge 测试）

## P0 — 已冻结（Lazy 拍板）

1. 一合约双模式 `LaunchpadV2(taxed bool)`
2. 外盘分红门槛严格 `>` 1 万枚（`DividendVault.setShare` 用 `<= minimumShareBalance`；ensure=`10_000 ether`）
3. 外盘仅 pair 成交抽税（`TaxLaunchToken._shouldTax`）
4. 共用现网 BuybackBurner `0x2aC14C…f8dF` + feeVault `0x3464aa…1Af4`
5. 平台币 GANG `0x0c6302401aa5325C2E36F170f52C00B1d220B405`
6. 任意 quote 不白名单；PoolCheck 锁 `gradAmt≈15 BNB`；`MIN_RESERVE_WBNB=1e18`

## P1 — 本包已完成（无广播）

| 步 | 内容 | 路径 |
|---|---|---|
| 1 | LaunchpadV2：两轨内盘 1%→PlatformFeeBucket；TAXED_MIN_SHARE=10_000 ether | `src/LaunchpadV2.sol` |
| 2 | DividendVault（`<=` 门槛）+ PostGradTaxHandler + PlatformFeeBucket | `src/` |
| 3 | TaxLaunchToken / LaunchToken / MigratorV2 / PoolCheck / QuoteRegistry（ops override only） | `src/` |
| 4 | BuybackBurner 源码随包（主网部署时 **指向现网 Burner 地址**，勿新部署除非 Lazy 另批） | `src/BuybackBurner.sol` |
| 5 | Foundry 测试 15 绿 | `test/LaunchpadV2.t.sol` |
| 6 | 差异摘要 | `docs/DIFF-VS-LIVE.md` |

### 建议 Wire 顺序（主网时，等 Lazy 书面确认）

1. Deploy：DividendVault → PlatformFeeBucket(feeVault=现网) → PostGradTaxHandler → LaunchpadV2 → MigratorV2
2. `vault.setLaunchpad(pad)`；`vault.setOperator(taxHandler,true)`；`bucket.setLaunchpad/setOperator/setBurner(现网Burner)/setKeeper`
3. `pad.setMigrator`；`pad.setAgentGate(true, AgentIdRegistry)`；`pad.setWalletCapEnabled(true)`
4. `taxHandler.setKeeper`；可选 `setRouter(Pancake V2)`
5. **不**改 Soft/U/S；FE/indexer 另 tip

## P2 — 主网（未执行）

- Lazy 书面确认后才 Deploy+Wire+verify
- FE create 只留 V2 无税/有税；Soft/U/S create 下线
- indexer `lane=v2_untaxed|v2_taxed`；keeper 接 V2 graduate + PostGrad.process + Bucket.collect

## 自检

- [x] forge test 绿
- [x] 未广播
- [x] 未改 tip/FE/现网 Soft·U·S
