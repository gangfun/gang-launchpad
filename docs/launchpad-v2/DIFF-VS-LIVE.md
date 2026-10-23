# LaunchpadV2 vs 现网 Soft / U / S

> **已上主网。** 地址、startBlock `129311617`、复用的 Burner / feeVault / GANG 见 [`../MAINNET-LAUNCHPAD-V2-ADDRESSES-2026-10-23.md`](../MAINNET-LAUNCHPAD-V2-ADDRESSES-2026-10-23.md)。下面的地址表是源码包广播前的计划，不是现网清单。本仓库源码在 `src/launchpad-v2/`。

- 日期：2026-10-23 Asia/Shanghai
- 现网参考：Soft `0x4E6f…` / U `0xF81C…` / S `0x60ae…`；Burner `0x2aC1…f8dF`；feeVault `0x3464…1Af4`；GANG `0x0c63…B405`

## 核心差异（5–8 行）

1. **入口**：新产品唯一 `LaunchpadV2` 双模式；Soft/U/S **只读归档**，不作为新发射入口。
2. **内盘税**：两轨皆 **1%→PlatformFeeBucket→80% 回购 GANG / 20% feeVault**；有税轨内盘 **不再** 50/50 进 DividendVault（现网 U 有税内盘仍 50% 分红）。
3. **外盘**：无税 = `LaunchToken` 无税；有税 = `TaxLaunchToken` `OUTER_TAX_BPS=100`，**仅 pair** 成交抽税 → process 后 **50% DivVault / 40% 回购 / 10% 金库**。
4. **分红门槛**：V2 **`>` 1 万枚**（`minimumShareBalance=10_000 ether` + `setShare` 用 `<=`）；现网 U vault 仍 **100 万枚**（隔离，旧币不迁）。
5. **Quote**：任意有池（PoolCheck + `MIN_RESERVE_WBNB=1e18`）；**无** S 式 6 bStock 白名单；QuoteRegistry 仅 ops `graduationAmount` override。
6. **毕业**：create 锁定 `gradAmt≈15 BNB` 等值（同现 U）；Soft 的 20 BNB **不延续**。
7. **附属**：V2 新 DivVault / Bucket / PostGrad / Migrator；**复用**现网 Burner + feeVault + GANG。
8. **准入**：create + 内盘 buy/sell = BAW `isAgent`；钱包上限供应量 **1%**（同现网）。

## 地址（部署后填；本包未广播）

| 组件 | 计划 |
|---|---|
| LaunchpadV2 | 待 Deploy |
| MigratorV2 | 待 Deploy |
| DividendVault V2 | 待 Deploy（门槛 1 万） |
| PostGradTaxHandler V2 | 待 Deploy |
| PlatformFeeBucket V2 | 待 Deploy → feeVault 现网 |
| BuybackBurner | **复用** `0x2aC14C462901F990ae7647D6AcafEaf50Cc8f8dF` |
| GANG | `0x0c6302401aa5325C2E36F170f52C00B1d220B405` |
| feeVault | `0x3464aa1097Aa46502Db847E4c6d0A2D52a871Af4` |

## 链上 GANG 核验

- 规格 / MainnetAddresses / Burner.gang 口径一致：`0x0c6302401aa5325C2E36F170f52C00B1d220B405`
- 本包未对主网 `eth_call`；若 Wire 时发现 Burner.gang 不同，记入差异并以链上为准。
