# 主网 · GangLaunchpad 2.0（内盘 creator 分成 + 可选毕业门槛）

BSC 主网（chainId 56），2026-10-31 部署，代码为 `main` 的 `2fb8ed5`（PR #97 合并）。按 `docs/MAINNET-RUNBOOK-GANGLAUNCHPAD2.md` 执行。

- 2.0 和 1.0 共用分红金库、平台手续费池、毕业迁移合约、TokenDeployer、报价登记和 pad 登记表。
- 2.0 有自己的 tax handler、pad、Router，以及一套模块：GangHandlerAdmin、四个 factory、GangBond。
- 1.0（`0x15CF…4365`）不动。

**状态：**
- 2.0 已开放；
- 切换（Safe batch 3：`TokenDeployer.setLaunchpad(1.0, false)`）**还没做**，1.0 仍可创建。

## 地址

| 合约 | 地址 |
|---|---|
| GangLaunchpad 2.0（pad，部署区块 130874052） | [`0x770331a9accdb53ACb4a45B6c5B7D151fADCe557`](https://bscscan.com/address/0x770331a9accdb53ACb4a45B6c5B7D151fADCe557) |
| GangTaxHandler 2.0 | [`0x1E85834A1fe6258b0cA04f883284A28B59412112`](https://bscscan.com/address/0x1E85834A1fe6258b0cA04f883284A28B59412112) |
| CurveLogic（2.0 链接的库） | [`0xA5d02A11076DfbA15423913ACa3D54909c207a0B`](https://bscscan.com/address/0xA5d02A11076DfbA15423913ACa3D54909c207a0B) |
| FairLogic | [`0x34E18563622aE05e92FdaCA81a40D83652067c9D`](https://bscscan.com/address/0x34E18563622aE05e92FdaCA81a40D83652067c9D) |
| GangRouter 2.0（proxy，用户授权这个地址） | [`0xa83209d6bfC2B220cD86410cCDDC71FEb354844a`](https://bscscan.com/address/0xa83209d6bfC2B220cD86410cCDDC71FEb354844a) |
| GangRouter 实现 | [`0x02DA4E6718D82515A9B24c967Bc6A307Ddc89e5D`](https://bscscan.com/address/0x02DA4E6718D82515A9B24c967Bc6A307Ddc89e5D) |
| ProxyAdmin（owner = timelock） | [`0xbA531236aFb9138d756CC628c5cF6E1176bC456E`](https://bscscan.com/address/0xbA531236aFb9138d756CC628c5cF6E1176bC456E) |
| TimelockController（48 小时；proposer / executor / canceller = 平台 Safe） | [`0xB48BF93f51d45ebc96121e5b9c0DAB2A7D9E3De3`](https://bscscan.com/address/0xB48BF93f51d45ebc96121e5b9c0DAB2A7D9E3De3) |
| GangHandlerAdmin 2（handler 的 owner；admin 的 owner = 平台 Safe） | [`0x2e994cdF2c8aC41c6aF26874e4F989773aD8Bd18`](https://bscscan.com/address/0x2e994cdF2c8aC41c6aF26874e4F989773aD8Bd18) |
| GangBuybackSplitterFactory（`buyback-burn-v4`） | [`0x77e499c892e5E6B3eEe1721e6821e9DA1293803C`](https://bscscan.com/address/0x77e499c892e5E6B3eEe1721e6821e9DA1293803C) |
| GangSplitModuleFactory（`split-v1`） | [`0xa73dC3d63AAf72E70b1cb012e5f3A541360Bec59`](https://bscscan.com/address/0xa73dC3d63AAf72E70b1cb012e5f3A541360Bec59) |
| GangLiquiditySplitterFactory（`lp-burn-v1`） | [`0x8ac85f150f87B536fb05eA163908b1077D95c0E4`](https://bscscan.com/address/0x8ac85f150f87B536fb05eA163908b1077D95c0E4) |
| GangComboSplitterFactory（`combo-v1`，gangQuote = GANG） | [`0xcCeA388DbC0Edb206eC25C9715546d57029198Be`](https://bscscan.com/address/0xcCeA388DbC0Edb206eC25C9715546d57029198Be) |
| GangBond（2.0） | [`0x231339463d04A2127E6dD5756756Dd56853AE0D8`](https://bscscan.com/address/0x231339463d04A2127E6dD5756756Dd56853AE0D8) |

参数：
- `CREATOR_FEE_SHARE_BPS` = 7000；
- `TARGET_GRAD_BNB` = 9 BNB；
- `GRAD_BNB_TIERS` = 6 / 9 / 12 / 15 BNB；
- keeper、TWAP 窗口、Agent gate、V3 factory、USDT 桥接池与 1.0 相同。

## 部署（部署钱包）

1. **阶段 1**：14 笔交易全部成功。
   - 部署 CurveLogic / FairLogic / handler / pad / Router；
   - handler `setLaunchpad` / `setKeeper`；
   - pad 列入 Router 和 GangGateway，设置 Agent gate、V3 factory 和 USDT 桥接池。
   - 交易：
     - pad [`0xa03c564d…c7479`](https://bscscan.com/tx/0xa03c564dadd7531deaef81c0b18900eea5f4a6f6e0f17f68a933da79f33c7479)
     - handler [`0xc261cae8…50da8`](https://bscscan.com/tx/0xc261cae8129e2dee7a6f9317d00e1fab15b200755343d8f0a8717ef314950da8)
     - Router proxy [`0x6044f17b…d191a`](https://bscscan.com/tx/0x6044f17b521766cb0345a3792fea6e7d5e9b20cac2d4bbcfdd3c42e1ed1d191a)
   - 广播前先模拟，batch 1 之前的检查全部通过。广播后只读重跑，用链上状态重新生成的 batch 1 与广播时的输出逐字节一致。
2. **阶段 2**：自检 `self-check ok`；发起 handler 和 pad 向 Safe 的交接（[`0x1bd777a4…a3f22`](https://bscscan.com/tx/0x1bd777a4fd1f6fa8ab8858e1c112646973f6a10e63f774b468d470c2cfea3f22)、[`0x721468f2…1f80c`](https://bscscan.com/tx/0x721468f27a134ea4caad3bde2c625d9bff26aa52c6105f7a03cef1c9d971f80c)）。
3. **模块**：
   - GangHandlerAdmin 2 [`0xedb0ae2c…9af3a`](https://bscscan.com/tx/0xedb0ae2c500a932bccde8b99a65a1374926bca304e738042b2e0f65d4379af3a)
   - Buyback factory [`0xd07d36e6…856c8`](https://bscscan.com/tx/0xd07d36e627136c2ee94fd5dbdec2e42a22b964c60028576340109590dfe856c8)
   - GangBond [`0x891aa092…95985`](https://bscscan.com/tx/0x891aa092897fdd8732806f85e6565b90c8d62e97c0ad5145de9a16fa5be95985)
   - Split factory [`0xedbf8627…478e3`](https://bscscan.com/tx/0xedbf8627cb016c796e29bca3e815a45975940c2b08483b2059d268d0b46478e3)
   - LP factory [`0x8f2a8030…4b74b0`](https://bscscan.com/tx/0x8f2a80307877333c0f1e4cb7d4edccf6e6591092ea7fc2d59de79494824b74b0)
   - Combo factory [`0xf7f6cd66…162f35`](https://bscscan.com/tx/0xf7f6cd66db3b7ab71233e85efc968e2a0286e91d779db4e36dd773d2ac162f35)

   每个脚本都先模拟再广播，脚本里的接线和运行时代码比对全部通过。

部署记录（forge 生成）：`broadcast/<脚本>/56/` 下本次新增的带时间戳文件，以及 `broadcast/DeployGangLaunchpad2.s.sol/56/run-latest.json`。其余脚本目录的 `run-latest.json` 仍是 1.0 那次的，没有改。

## Safe 批次（平台 Safe）

每批签名前都核对过逐条解码的调用；执行后在链上逐项读回。

1. **batch 1（9 笔，登记到共享合约）**：
   - 分红金库：`setLaunchpad` / `setMinimumShareBalance`（10,000 枚，与 1.0 相同）/ `setOperator(handler, pad)` / `setExcluded(router)`；
   - 迁移合约：`addLaunchpad`；
   - TokenDeployer：`setLaunchpad`；
   - 平台手续费池：`setOperator` ×2（pad、handler）；
   - pad 登记表：`addPad`。

   读回 9 项全部生效。
2. **batch 2（3 笔）**：handler、pad `acceptOwnership`，pad `setMigrator(共享迁移合约)`，2.0 开放。读回：pad、handler 的 owner = Safe，没有待交接；migrator = 共享迁移合约。
3. **模块 batch 1（5 笔）**：
   - `handler.transferOwnership(admin2)`；
   - `admin2.exec(acceptOwnership())`；
   - `admin2.setFactory(buyback, true)`；
   - `admin2.exec(list(…))` ×2：把 1.0 上登记的两个合作方 recipient 重新登记到 2.0。1.0 上其余 24 个 recipient 是模块 factory 的克隆，绑定 1.0，不迁。

   签名前在本地主网 fork 上执行过这一批，并在执行后的状态上模拟了后面三个 factory 的部署。
4. **模块 batch 2（3 笔）**：`admin2.setFactory` 给 Split / LP / Combo。读回：`admin2.factories()` 列出四个，`isFactory` 都为真，四个 factory 和 GangBond 的 `pad()` 都是 2.0。

全部执行后只读重跑阶段 2：`self-check ok`，Safe 没有剩余步骤，batch 3 已打印、保存。Combo 脚本带 `COMBO_FACTORY` 重跑：nothing to do。

## 还没做

- 后端、网站、CLI 的主网 2.0 接入验证，以及主网实测：小额创建、买卖、领取 creator 分成。
- CLI 0.23.0 发布（PR #98）和网站发版。
- 切换（batch 3）：建议在 CLI 0.23.0 发布约 24 小时后执行，让旧版 CLI 用户有时间升级。
