# 主网部署记录：合并版内盘（2026-10-27）

BSC 主网（chainId 56），代码 main `eb0e027`（合约与审查通过的 `52c2eef` 相同），`script/DeployGang.s.sol` 一次运行，38 笔交易全部成功。广播记录在 `broadcast/DeployGang.s.sol/56/run-latest.json`。

| 合约 | 地址 |
|---|---|
| GangLaunchpad（内盘，税收币和打新共用） | `0x15CFD2dc8278Fb87a1783ef42111618E20874365`，部署区块 130104322 |
| GangRouter（代理，用户授权这个地址） | `0xE040445690Aa56C8b68B7f7038C7b2562B5079C4` |
| GangRouter 实现 | `0x385bab8c3040c6b41251897AC1D6622e61601c58` |
| ProxyAdmin（owner = 时间锁） | `0xddeAB7A254e42D96D5863dAeF4E89BD426017bDa` |
| TimelockController（48 小时，提案 / 执行 / 取消都只给 Safe） | `0x3911996E2F6c5636d6b1b32f75cf94d0aF4604C5` |
| GangTaxHandler（外盘税处理；2026-10-28 起 owner = GangHandlerAdmin） | `0x6D8d3dE459629cBb7b552169a55D754db60cAe0c` |
| GangHandlerAdmin（GangTaxHandler 的 owner，owner = Safe；2026-10-28） | `0xF56AF7a7a004B9bB3515480A1409BC1DAD8FE985` |
| GangBuybackSplitterFactory（dev 税按比例回购，经 GangHandlerAdmin 加白；2026-10-28） | `0x6bcd79206da85Aa0643Db2164Ab887b468618546` |
| SharedDividendVault（外盘分红金库） | `0x1BDBDD73f51079c64BCA3917629c84c257921aCc` |
| SharedPlatformFeeBucket（内盘手续费） | `0xB8C4B68a62513240A5e44EFd78fFc35ac25bA21b` |
| SharedMigrator | `0xfE38fFce7f918cffC26575D125ed6D09864c3604` |
| TokenDeployer | `0x3A5432c562BcA145Faf21ef956C475c670d14558` |
| QuoteRegistry | `0x8b93919862830ea6A720B28C7D0C42fCbb849F17` |

- 部署钱包 `0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3`；owner 是 Safe `0x2866369F7acEFC9760bdE7779362fae5cD68B41E`，7 个合约已由多签批量 `acceptOwnership`（当晚链上核对 7/7）。
- keeper `0xB6f1F1BFb92476Abb0998B425dE0deC5F927cFc7`。
- 内盘手续费：80% 交给回购合约 `0x38120bf40F8F19E6cc60622Bc7C5B005dfe5363B` 回购销毁 GANG，20% 进 feeVault = Safe（部署时用 `FEE_VAULT` 覆盖了 V2 的收款钱包）。
- **2026-10-28 起 GangTaxHandler 的 owner 是 GangHandlerAdmin**（多签批量 [`0x3a976681…a41b`](https://bscscan.com/tx/0x3a97668130d5bc0fee3fe1367923eee6e94fac80363dae4c146a45982b0aa41b)），Safe 是 GangHandlerAdmin 的 owner。多签对 handler 的操作改成调 `GangHandlerAdmin.exec(<原来的 calldata>)`：加白合作方 `exec(list(addr, label))`、`exec(delist(addr))`、换 keeper `exec(proposeKeeper(k))` → 48 小时 → `exec(acceptKeeper())`、换 DEX router 同理。允许的工厂克隆的回购合约由 GangHandlerAdmin 自动加白。交回：`exec(transferOwnership(Safe))`，再由 Safe 调 `handler.acceptOwnership()`。见 `docs/MAINNET-BUYBACK-SPLITTER-2026-10-28.md`。
- 白名单路由只有 GangRouter。钱包聚合器的路由按审计说明 §23.9 的清单核对后，由多签 `setRouter` 添加。
- 索引和 keeper 的起始区块用 130104251（模拟时的区块，不晚于实际部署区块）。
- 服务端 v1.2.26 / v1.2.27、网站 v1.2.34 已发布，正式站已切换（切换前做了备份）。
- 测试网第 10 套：内盘 `0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1`（区块 139236749），路由 `0x6bB660f310a9644Dc173E7Cf2F73498716D9C9F6`；完整流程 904 笔交易全部成功，含聚合器 `buyFor` / `sellFor`。
