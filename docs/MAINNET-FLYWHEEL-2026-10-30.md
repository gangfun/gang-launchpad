# 主网 · 铸币飞轮发射台（Mint Flywheel，pad kind 3）

铸币飞轮模式（#75，原名「持续打新」）的三个合约已在 2026-10-30 部署到 BSC 主网。部署用的是合并 PR #78 之后的 `main`（`1270894`），在 `git archive` 导出的干净目录里运行，本地未提交的改动不会混进去。

部署前完成的流程：内部审计 → 修复 → 多轮复审 → 测试网部署验收 → 主网前三方审计 → 修复 → 独立复审 → 测试网用修复后的代码重新部署验收（见 `docs/TESTNET-FLYWHEEL-2026-10-30.md`）。

- 链：BSC 主网（chainId 56），区块 130634782–130634823（2026-10-30 16:40:55–16:41:14 +08:00）
- 当前状态：**已开放**（2026-10-30 20:09:41 +08:00，Safe 第 3 批 `setMigrator`）。三个合约的 owner 都是 Safe，部署钱包没有任何权限。
- **2026-10-31 起停止新建**：V2（`docs/MAINNET-FLYWHEEL-V2-2026-10-31.md`）开放后，Safe 执行了 `MintTokenDeployer.setLaunchpad(V1, false)`（[`0x289e8e95…939a`](https://bscscan.com/tx/0x289e8e956714a2303a244c60b3ffd8c76af8866ed1966f5ff391670ee80e939a)）。V1 发射台不能再创建新币；已经创建的币照常铸币、卖回、开盘、交易、处理税和领分红。

## 地址

| 项 | 值 |
|---|---|
| **GangFlywheelPad**（发射台：创建、铸币、卖回、开盘、开盘后铸币） | [`0x631e66560F4FAE4e486B65349edE48189E48B029`](https://bscscan.com/address/0x631e66560F4FAE4e486B65349edE48189E48B029) |
| **FlywheelTaxHandler**（税、开盘保护、价格参考） | [`0xa8329cD0512f1a9b7ee4Afb051c57a50899F84CF`](https://bscscan.com/address/0xa8329cD0512f1a9b7ee4Afb051c57a50899F84CF) |
| **MintTokenDeployer**（部署 GangMintToken） | [`0x2C95228AfA6eF211371A87f480aBa0f5c0Da072E`](https://bscscan.com/address/0x2C95228AfA6eF211371A87f480aBa0f5c0Da072E) |
| 库 FlywheelLogic | [`0x8b3ED4a096cdc9fDA75cB7832DAf0464e710f042`](https://bscscan.com/address/0x8b3ED4a096cdc9fDA75cB7832DAf0464e710f042) |
| 库 FlywheelPostLogic | [`0xe8e962732E1805B7DF016CAE9c34497C88C9bC2C`](https://bscscan.com/address/0xe8e962732E1805B7DF016CAE9c34497C88C9bC2C) |
| 库 PoolCheck（复用主网已有的） | `0xd2B159820749f178503E4faBCB18A7Ae4492bDb3` |
| 共用的合约（取自 GangLaunchpad `0x15CF…4365`） | 分红金库 `0x1BDBDD73f51079c64BCA3917629c84c257921aCc`、平台费桶 `0xB8C4B68a62513240A5e44EFd78fFc35ac25bA21b`、迁移器 `0xfE38fFce7f918cffC26575D125ed6D09864c3604` |
| 注册表 | GangPadRegistry `0x4fF77D4d9ac080939a24E1B805206bA094C44e5C` |
| handler 的 keeper | `0xB6f1F1BFb92476Abb0998B425dE0deC5F927cFc7`（`M.KEEPER`） |
| 最终 owner | Safe `0x2866369F7acEFC9760bdE7779362fae5cD68B41E` |
| 部署钱包 | `0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3`（Safe 接手（第 2 批）之后对三个合约没有任何权限） |
| 广播记录 | `broadcast/DeployFlywheel.s.sol/56/` |
| 源码验证 | 5 个合约都已在 BscScan 验证（2026-10-30，`forge verify-contract`，Etherscan v2 接口；solc 0.8.28，优化 200 runs，cancun，`src/flywheel/**` 用 via-ir） |

部署交易，gas 价格 0.05 gwei（legacy），合计 18,202,179 gas（约 0.00091 BNB）：

| 交易 | gas |
|---|---|
| 库 FlywheelLogic [`0xa7b6c6ef…1449`](https://bscscan.com/tx/0xa7b6c6efdfe6725f67410df9ca9a6f12311b8b5f8680f96af2ba6ac6a4991449) | 4,081,955 |
| 库 FlywheelPostLogic [`0xcef9590b…492b`](https://bscscan.com/tx/0xcef9590bbe31fc0f168fa02472b3400270efc7dfe40f860f720c6772f5f4492b) | 2,092,827 |
| MintTokenDeployer [`0xb0c9cffc…3f3f`](https://bscscan.com/tx/0xb0c9cffc1d32d1bc45225f10f00b0b938caaf4a53a5a4e448ebb7dcfc01f5f3f) | 2,420,376 |
| FlywheelTaxHandler [`0xf8500458…83cc`](https://bscscan.com/tx/0xf8500458acf7334f1da7adb15f553b5f7c3110ec9f3c591030379643af8383cc) | 5,300,475 |
| GangFlywheelPad [`0x7aa21f1b…712e`](https://bscscan.com/tx/0x7aa21f1babfb822b4a95b3ebb0bd83cf010926130f0cc785537ef45c7126712e) | 4,080,920 |
| `MintTokenDeployer.setLaunchpad(pad, true)` [`0xcdd0724c…ff77`](https://bscscan.com/tx/0xcdd0724c7e5dc7669137c070f6598d8d51181abaccb5e9cae21b905d9bc5ff77) | 47,641 |
| `handler.setLaunchpad(pad)` [`0x9109936c…cb3b`](https://bscscan.com/tx/0x9109936c392a79df8c8f5039fd7c488086cb5da8cbfe664215f04e111075cb3b) | 47,436 |
| `handler.setKeeper(keeper)` [`0x3d989d70…aea2`](https://bscscan.com/tx/0x3d989d7080fa2f1ac6a8116b33c69c1c0529d287a5b989442d8750333545aea2) | 69,893 |
| `pad.setAgentGate(true, Agent ID 注册表)` [`0x307c1756…3182`](https://bscscan.com/tx/0x307c1756248af693cef32604ee1f163e5969359f638e19503943c4b0bc1f3182) | 30,442 |
| `pad.setV3Factory(Pancake V3 factory)` [`0x214e7b71…bcf2`](https://bscscan.com/tx/0x214e7b71f33472fa60afe748b5f5c5e280645bd8834caf5ec2643084c812bcf2) | 30,214 |

部署命令（第一阶段）：`FLYWHEEL_MAINNET_OK=true GANG_PAD=0x15CF…4365 forge script script/DeployFlywheel.s.sol --rpc-url $BSC_RPC_URL --libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B1…bDb3 --broadcast --slow --legacy --with-gas-price 50000000`。`OWNER`、`KEEPER` 和 `GANG_PAD_REGISTRY` 都没有传，主网默认分别是 Safe、`M.KEEPER` 和主网 GangPadRegistry，脚本会拒绝别的值（审计 C-2）。广播前在同一份代码上模拟过，预测地址和实际一致。

## 部署后的检查

- **链上直接调用**：
  - 三个合约 `owner()` 都是部署钱包，`pendingOwner()` 都为 0（第二阶段才交给 Safe）。
  - pad 的 `migrator()` 为 0：发射台还没开放，`create` 会回滚 `MigratorNotSet`。
  - handler 的 `launchpad()` 是 pad，`keeper()` 是 `M.KEEPER`；pad 已列入 MintTokenDeployer（`launchpads(pad)` 为 true）。
  - 金库、费桶、迁移器、注册表的 owner 都是 Safe，所以把 pad 列进去要 Safe 执行（下面第 1 批）。
- **在主网 fork 上预演 Safe 第 1 批**：用 Safe 身份按顺序执行下面 7 笔，全部成功；之后带 `FLYWHEEL_PAD` / `FLYWHEEL_HANDLER` / `FLYWHEEL_DEPLOYER` 跑第二阶段（不广播），自检通过，并输出第 2 批（接手 owner 和开放发射台）。

## Safe 操作（上线步骤）

1. **把 pad 列入共用合约和注册表**（已执行：Safe 交易 [`0xd0086a81…d48c`](https://bscscan.com/tx/0xd0086a81d2a300b10cba6ab3fc0f7d88cddeb1bcc6e76c5bdfc29d350da3d48c)，区块 130639494，2026-10-30 17:16:15 +08:00）。Transaction Builder 文件：`docs/MAINNET-FLYWHEEL-SAFE-BATCH-1-2026-10-30.json`，7 笔：

   | # | to | 调用 |
   |---|---|---|
   | 1 | 分红金库 `0x1BDB…1aCc` | `setLaunchpad(pad, true)` |
   | 2 | 分红金库 | `setMinimumShareBalance(pad, 1000e18)` |
   | 3 | 分红金库 | `setOperator(handler, pad)`（handler 只能代这个 pad 操作，绑定后不能改） |
   | 4 | 迁移器 `0xfE38…3604` | `addLaunchpad(pad)` |
   | 5 | 平台费桶 `0xB8C4…A21b` | `setOperator(pad, true)` |
   | 6 | 平台费桶 | `setOperator(handler, true)` |
   | 7 | GangPadRegistry `0x4fF7…4e5C` | `addPad(pad)`：之后 `lookup(token)` 对这个 pad 的币返回 kind 3 |

   这一批执行后发射台仍然关着。
2. **第二阶段**（已执行，2026-10-30，区块 130640343–130640353，17:22:38–17:22:42 +08:00）：部署钱包带 `FLYWHEEL_PAD=0x631e…B029 FLYWHEEL_HANDLER=0xa832…84CF FLYWHEEL_DEPLOYER=0x2C95…072E` 重跑脚本，先模拟后广播。脚本检查了第 1 批的列入并自检通过，然后把三个合约的 owner 转给 Safe（Ownable2Step，Safe 接手前 owner 仍是部署钱包）：

   | 交易 | gas |
   |---|---|
   | `MintTokenDeployer.transferOwnership(Safe)` [`0x2da200f6…5fbc`](https://bscscan.com/tx/0x2da200f6f15c22a9aeae5d00653a8a6365f44a36521032398161c9d3b3ee5fbc) | 47,721 |
   | `handler.transferOwnership(Safe)` [`0xaa945733…adc7`](https://bscscan.com/tx/0xaa94573314e9a568baf2bef3d07316664e0a59a3b965d114ac129e11d784adc7) | 49,101 |
   | `pad.transferOwnership(Safe)` [`0x9395c8a5…73f0`](https://bscscan.com/tx/0x9395c8a577de1e92eefc82b99b3e34e3193146c4eca60ca1ba1721d7810f73f0) | 48,870 |

   脚本输出的 Safe 批次是「三笔 `acceptOwnership()` + `pad.setMigrator(迁移器)`」，这里拆成下面两批，接手和开放分开签。两批都在主网 fork 上用 Safe 身份按顺序预演过：执行后三个合约的 owner 是 Safe，`migrator()` 是迁移器。
3. **第 2 批：Safe 接手 owner**（已执行：Safe 交易 [`0x0c4b7cb2…e237`](https://bscscan.com/tx/0x0c4b7cb20538ffde5e7abe7574f54353a9152ed9486ef5e913a497369a84e237)，区块 130651873，18:49:08 +08:00；之后三个合约 `owner()` 都是 Safe，`pendingOwner()` 为 0）。`docs/MAINNET-FLYWHEEL-SAFE-BATCH-2-ACCEPT-2026-10-30.json`，3 笔：MintTokenDeployer、handler、pad 各一笔 `acceptOwnership()`。执行后部署钱包对三个合约没有任何权限，发射台仍然关着。
4. **第 3 批：开放发射台**（已执行：Safe 交易 [`0x14a32eba…85ac`](https://bscscan.com/tx/0x14a32eba02d30e8cf61934275ce54e23c699732791fd01bacc5bbc34a6a985ac)，区块 130662610，20:09:41 +08:00；`migrator()` 为 `0xfE38…3604`）。`docs/MAINNET-FLYWHEEL-SAFE-BATCH-3-OPEN-2026-10-30.json`，1 笔：pad `setMigrator(0xfE38fFce7f918cffC26575D125ed6D09864c3604)`，只能设一次。执行后任何人都能创建持续铸币的币，所以等 keeper、后端、网站和 CLI 都支持 kind 3 并在测试网验收之后才执行：CLI 0.18.0 已发布，正式环境的索引和 keeper 先上线（对外隐藏），开放后再打开接口和网站。必须在第 2 批之后执行（需要 Safe 是 pad 的 owner）。
