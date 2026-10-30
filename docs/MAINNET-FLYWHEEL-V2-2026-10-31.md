# 主网 · 铸币飞轮 V2（GangFlywheelPad V2，kind 3）

铸币飞轮（#75）的第二版发射台已在 2026-10-31 部署到 BSC 主网，并于 02:56:50（+08:00）开放。之后 V1 发射台 `0x631e…B029` 停止新建（03:02:28），V1 上已经创建的币照常运行。

- 代码：PR #93（main `304f167`）。合约源码与测试网验收的 `afb3dc6` 完全一致，部署在 `git archive` 导出的干净目录里进行。
- 流程：三路内部审计 → 修复 → 独立复审 → 测试网部署验收（`docs/TESTNET-FLYWHEEL-V2-2026-10-31.md`）→ 主网。
- V2 只改了开盘后铸币的定价和暂停规则，以及开盘后铸币时的配置上限，对照表见测试网记录。

## 地址

| 项 | 值 |
|---|---|
| **GangFlywheelPad V2** | [`0x281889ad915c1A95ffc4922235c6314b3Cbd8a5a`](https://bscscan.com/address/0x281889ad915c1A95ffc4922235c6314b3Cbd8a5a) |
| **FlywheelTaxHandler**（新实例，代码与 V1 handler 相同，code hash `0x9c88…fd42`） | [`0x95269a407Cfe93e745810114c5BAeCE3606BfFAA`](https://bscscan.com/address/0x95269a407Cfe93e745810114c5BAeCE3606BfFAA) |
| 库 FlywheelLogic | [`0x43BF3609d49c45FdF5aE8acc536ee5B0Eb942bEF`](https://bscscan.com/address/0x43BF3609d49c45FdF5aE8acc536ee5B0Eb942bEF) |
| 库 FlywheelPostLogic | [`0xd9BB7A7044c96f8Afa83781f07a64bAd13C673Eb`](https://bscscan.com/address/0xd9BB7A7044c96f8Afa83781f07a64bAd13C673Eb) |
| 库 PoolCheck（复用） | `0xd2B159820749f178503E4faBCB18A7Ae4492bDb3` |
| 复用 | MintTokenDeployer `0x2C95228AfA6eF211371A87f480aBa0f5c0Da072E`，分红金库 `0x1BDB…1aCc`，平台费桶 `0xB8C4…A21b`，迁移器 `0xfE38…3604`，注册表 `0x4fF7…4e5C` |
| handler 的 keeper | `0xB6f1F1BFb92476Abb0998B425dE0deC5F927cFc7`（`M.KEEPER`） |
| owner | Safe `0x2866369F7acEFC9760bdE7779362fae5cD68B41E`（部署钱包已没有任何权限） |
| 广播记录 | `broadcast/DeployFlywheelV2.s.sol/56/` |
| 源码验证 | 4 个新合约都已在 BscScan 验证（solc 0.8.28，优化 200 runs，cancun，`src/flywheel/**` via-ir；handler 与 V1 handler 字节码相同，自动匹配） |

## 交易

部署钱包 `0x4EEd…19d3`，gas 价格 0.05 gwei（legacy）：

| 交易 | gas |
|---|---|
| 库 FlywheelLogic [`0x7771f818…fc3d`](https://bscscan.com/tx/0x7771f8186ac84c19cd62cb44a2c5103d05f8f0b7ea6337a4f9f9637e9872fc3d) | 4,325,364 |
| 库 FlywheelPostLogic [`0xc08b80ae…83f9`](https://bscscan.com/tx/0xc08b80aea658191a0231a70e66f5e7a33440b9195d94837c497344e850dc83f9) | 1,981,891 |
| FlywheelTaxHandler [`0xbfb561ed…060b`](https://bscscan.com/tx/0xbfb561ed92ce9fbf1dd18e6bd8c9e8b7b204dc2252384d0a641dcd99a8ab060b) | 5,300,475 |
| GangFlywheelPad V2 [`0x9c1bc207…f218`](https://bscscan.com/tx/0x9c1bc2071112229b183e1b4031654798f9f5f65b9f7a49da9e2c607ec7c1f218) | 4,412,798 |
| `handler.setLaunchpad(pad)` / `setKeeper(keeper)` / `pad.setAgentGate` / `pad.setV3Factory` | 47,436 / 69,893 / 30,464 / 30,258 |
| 第二阶段：`handler.transferOwnership(Safe)` [`0x6cc32a50…49c0`](https://bscscan.com/tx/0x6cc32a500e518a94379da68b50592bd7ea9c7af1c6c68c08e43969d5dc0f49c0)、`pad.transferOwnership(Safe)` [`0x9b150a71…183c`](https://bscscan.com/tx/0x9b150a71ff9de5892e3715762083a43a7eb8c2e9b3f6f0e502788e74d6ec183c) | 49,101 / 48,914 |

第一阶段区块 130,710,046–130,710,077（02:05:33–02:05:47），合计 16,198,579 gas。广播前在同一份代码上模拟，脚本在打印登记批次之前检查了新 pad 和 handler（包括 pad 链接的是 V2 库），并打印了给签名人核对的指纹。

Safe 执行（每批都先在主网 fork 上用 Safe 身份预演）：

| 批次 | 文件 | Safe 交易 | 时间（+08:00） |
|---|---|---|---|
| 1 登记（8 笔：金库 setLaunchpad / setMinimumShareBalance / setOperator(handler, pad)，迁移器 addLaunchpad，费桶 setOperator ×2，注册表 addPad，MintTokenDeployer.setLaunchpad(V2, true)） | `docs/MAINNET-FLYWHEEL-V2-SAFE-BATCH-1-2026-10-31.json` | [`0xba40d79a…4419`](https://bscscan.com/tx/0xba40d79a8fce8e3235b0322499659f4f729896e626fcfeb167d73555c6614419) | 02:21:24 |
| 2 接手 owner（handler、pad 各一笔 `acceptOwnership`） | `docs/MAINNET-FLYWHEEL-V2-SAFE-BATCH-2-ACCEPT-2026-10-31.json` | [`0xe7f70891…3807`](https://bscscan.com/tx/0xe7f70891f79a31cdafa7b49bb0891182ad7588b8100de703416cf2d228ac3807) | 02:29:29 |
| 3 开放（`pad.setMigrator(迁移器)`） | `docs/MAINNET-FLYWHEEL-V2-SAFE-BATCH-3-OPEN-2026-10-31.json` | [`0xa76d244d…101a`](https://bscscan.com/tx/0xa76d244d87eb53cbbd587c38ef6a89012c6c46355bb7b7a571b7ce7b32d6101a) | 02:56:50 |
| 4 停止 V1 新建（`MintTokenDeployer.setLaunchpad(V1, false)`） | `docs/MAINNET-FLYWHEEL-V2-SAFE-BATCH-4-STOP-V1-2026-10-31.json` | [`0x289e8e95…939a`](https://bscscan.com/tx/0x289e8e956714a2303a244c60b3ffd8c76af8866ed1966f5ff391670ee80e939a) | 03:02:28 |

开放前，后端在正式环境先接好了 V2 的索引和 keeper（自动开盘、税处理、源码自动验证），CLI 0.21.0 已发布（`gang create --fly` 发到 V2），网站已上线 V2 的展示。

## 部署后的检查

- pad 与 handler 的 owner 都是 Safe，`pendingOwner` 为 0；pad 的 `migrator()` 是迁移器；handler 的 `launchpad()` 是 V2 pad，`keeper()` 是 `M.KEEPER`。
- 金库 `launchpads(V2)` 为 true、`operatorFor(V2)` 是 V2 handler；费桶对 pad 和 handler 都是 operator；迁移器和注册表都登记了 V2；`lookup(token)` 对 V2 的币返回 kind 3。
- MintTokenDeployer：`launchpads(V2)` 为 true，`launchpads(V1)` 为 false。
- 停止 V1 新建后，在主网 fork 上确认：V1 的 `create` 被拒绝；V1 已有的币照常转账、交易和处理税（审计 C 还在 fork 上验证了铸币、卖回、开盘、开盘后铸币和领分红）。
- 以后要恢复 V1 新建，Safe 签 `MintTokenDeployer.setLaunchpad(V1, true)` 即可。
