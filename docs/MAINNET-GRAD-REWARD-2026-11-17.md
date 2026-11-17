# 主网 · 冲毕业奖励（GangLaunchpad 3.0）

- 链：BSC 主网（chainId 56），2026-11-17
- 规格：`docs/SPEC-GRAD-REWARD-2026-11-17.md`；测试网记录：`docs/TESTNET-GRAD-REWARD-2026-11-17.md`
- 源码：PR #164（已合并，合并提交 `ac4a212`）；部署记录里的 `commit` 字段就是 `ac4a212`
- 部署钱包 `0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3`；gas price 0.05 gwei
- 状态：**主网已开放（2026-11-17 19:39 UTC+8）**。Safe 批次已执行，`createWithGradReward` 在主网可用（只开单独玩法，carry 未开）。CLI 0.42.0 已发布；服务端 v1.2.103 已上线（PR gangfun/gangfun-server#63）；网站 PR gangfun/gang-web-legacy#54 待合并。还没有真实的冲毕业奖励币

## 3.0 新实现

用 `script/UpgradeGangLaunchpad3.s.sol` 部署，带 `PAD3_GRAD_REWARD=true` 和 `PAD3_GRAD_HANDLER_ADMIN=0xC833CEC2B283759003945C0Bf8C048aB1949Af76`（3.0 的 GangHandlerAdmin）；`PAD3_GRAD_COUNTDOWN_FACTORY` 为 0，主网先不开 carry。只链接线上的 PoolCheck，没改动的库（FairLogic、LegacyRoute、FlywheelLogic、FlywheelPostLogic）沿用链上已有的 CREATE2 地址。记录：`broadcast/UpgradeGangLaunchpad3.s.sol/56/run-1794905223752.json`。

| 合约 | 地址 | 部署交易 | 区块 | gas |
|---|---|---|---|---|
| CurveLogic3（库，CREATE2） | [`0x25597F0bcfD339006F657546adCAdc91765dC2c6`](https://bscscan.com/address/0x25597F0bcfD339006F657546adCAdc91765dC2c6) | [`0xd9095677…50da`](https://bscscan.com/tx/0xd90956772888ff207d816060fc216e3750d0e1549ad6c943821de1fa8dda50da) | 134090049 | 3,835,076 |
| Pad3FlyModule（代码不变，构建脚本连带部署） | [`0xd6e96ADeE0423F9838502092f30469C9A99E36c6`](https://bscscan.com/address/0xd6e96ADeE0423F9838502092f30469C9A99E36c6) | [`0xbb36a55d…5cae`](https://bscscan.com/tx/0xbb36a55d2468d073a42d8d44b812f4c124bd235aece0d4d8a137488374225cae) | 134090051 | 4,816,115 |
| Pad3GradModule | [`0xED1E927826802cd2C098E70e63445Af17237Cf2D`](https://bscscan.com/address/0xED1E927826802cd2C098E70e63445Af17237Cf2D) | [`0x21453263…ef78`](https://bscscan.com/tx/0x21453263a43f0b455a85e074e249619224bc601fececddfe224d938e4257ef78) | 134090053 | 1,697,139 |
| Pad3Module | [`0x36D39b3693262b066b6b138766B64653290809aA`](https://bscscan.com/address/0x36D39b3693262b066b6b138766B64653290809aA) | [`0x15140af6…edaef`](https://bscscan.com/tx/0x15140af6d3b97fce7c40ce28a2f7d8aefab85dcb1d6deefdb1f102f3bfdedaef) | 134090055 | 4,834,864 |
| GangLaunchpad3 新实现 | [`0x0D4C5b2e4dbDD42DA3fEBfb38514B5504649B25b`](https://bscscan.com/address/0x0D4C5b2e4dbDD42DA3fEBfb38514B5504649B25b) | [`0x65bb9459…b1b`](https://bscscan.com/tx/0x65bb9459c0e99c8bc92859113d7179717ace30a453fa4cc21f126cdde075fb1b) | 134090058 | 4,843,883 |

- 5 笔全部成功，共 20,027,077 gas，花费 0.00100135 BNB。
- 读回：新 Pad3Module 的 `gradModule()` = 上面的 Pad3GradModule；`flyModule()` = 上面的 Pad3FlyModule，它的 handler `0x7De9…3ba0` 和 vault core `0x9d90…767E` 沿用线上的。
- 脚本先在模拟里以 Safe 身份执行升级和 `setGradReward`，再读回比对：最新 25 个币的记录和视图、pad 设置、阶段 2 的全部读回，都和升级前一致。然后带 `PAD3_IMPL`、`PAD3_FLY_HANDLER`、`PAD3_FLY_VAULT_CORE` 只读重跑，逐字节核对新实现、Pad3Module、Pad3FlyModule、Pad3GradModule 都是本次构建的代码，打印出下面的批次。
- 没有设 `PAD3_PROMOTE_PROBES` 和 `PAD3_BASE_PROBES`，原因和上一次升级相同：部署用的 RPC 拿不到完整的日志。推广分成和底仓的命名空间由各自的测试固定；样本里有带分成或底仓的币时，它们的条款也会比对。
- 源码验证：还没在 BscScan 提交。需要 BscScan API key，上次是用户提供的。

## Safe 批次（已执行）

归档文件：[MAINNET-GANG-LAUNCHPAD-3-UPGRADE-GRAD-SAFE-BATCH-2026-11-17.json](MAINNET-GANG-LAUNCHPAD-3-UPGRADE-GRAD-SAFE-BATCH-2026-11-17.json)，SHA-256 `285495c83005d53c5fdf46142e00053b41a6a01ef871fbe6f22319f88ccffb87`。已执行交易：[`0x3dd41d46…d2aa`](https://bscscan.com/tx/0x3dd41d46b156af454df2089d1c7e2d8460bde81a777db70c31449843a14ed2aa)，区块 134113012（2026-11-17 19:39 UTC+8），gas 128,727，费用 0.0000064364 BNB。Safe `0x2866369F7acEFC9760bdE7779362fae5cD68B41E`，两位持有者签名，nonce 54，safeTxHash `0x6a2bf4ba…15f5`；经 MultiSendCallOnly `0xA83c336B20401Af773B6219BA5027174338D1836` 执行。两笔，都不转 BNB：

| 顺序 | 目标 | 调用 |
|---|---|---|
| 1 | ProxyAdmin `0xCe83Be827bf2B6bAFe0ca6d1320Dce965CE3df48` | `upgradeAndCall(0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29, 0x0D4C5b2e4dbDD42DA3fEBfb38514B5504649B25b, 0x)` |
| 2 | GangLaunchpad 3.0 `0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29` | `setGradReward(true, 0xC833CEC2B283759003945C0Bf8C048aB1949Af76, 0x0000000000000000000000000000000000000000)` |

第二笔执行后，`createWithGradReward` 开放（只开单独玩法；倒计时工厂上主网后，carry 另走一个批次）。

签名前的 fork 演练（`test/fork/Pad3GradRewardFork.t.sol`，2026-11-17，主网区块 134090404，公共归档节点；Agent ID 只在 fork 里模拟，没有广播）：2 通过、0 失败。

- `test_fork_signedBatchThenGrad`（`PAD3_FORK_BATCH` = 上面的 JSON）：
  1. 检查批次：链、Safe、正好两笔、目标、都不转 BNB；第一笔是升级到已部署的新实现、不带初始化调用，第二笔是 `setGradReward(true, admin, 0)`。
  2. 以 Safe 身份原样执行：升级只写了实现槽；开启后 `gradRewardDeps` = (true, admin, 0)；owner 和 abcd 部署器不变。
  3. 经 `createWithSalt` 建奖励币，80 多个模拟 Agent 钱包在 1% 上限下买到毕业，迁移到真实的 Pancake V2 交易对。期间一个买家卖出，他的格子失效。其余人领取，总额不超过奖励池。180 天后回收，零头退给 dev。
- `test_fork_upgradeOpenCreateGraduateClaim`：在 fork 里从头跑一遍升级脚本，执行它打印的批次，之后再跑脚本会被拒绝；同样的建币、毕业、领取流程通过。

## 执行后核对（2026-11-17）

- Safe 交易服务里 nonce 54 是一笔 multiSend（`operation` = 1，指向 MultiSendCallOnly），里面两笔调用的 `to`、`value`、`data` 和归档 JSON 逐字节一致，每笔的 `operation` 都是 0。
- 回执：状态成功。代理发出 `Upgraded(0x0D4C…B25b)` 和 `GradRewardDepsSet(true, 0xC833…Af76, 0)`，Safe 发出 `ExecutionSuccess`。
- 读回：实现槽 = `0x0D4C5b2e4dbDD42DA3fEBfb38514B5504649B25b`；`module()` = `0x36D3…09aA`，它的 `gradModule()` = `0xED1E…Cf2D`；`gradRewardDeps()` = (true, `0xC833…Af76`, 0)；pad 和 ProxyAdmin 的 owner 仍是 Safe；`vanityDeployer()` 仍是 `0x8e76…F8DE`，`baseVaultImpl()` 仍是 `0x6ff4…0F3b`。
- 在执行后的主网状态（区块 134113351）上重跑 `test_fork_signedBatchThenGrad`：1 通过、0 失败。批次在已升级的代理上再执行一次，只是写回同一个实现地址和同样的设置；之后建奖励币、买到毕业、领取、回收都通过。Agent ID 只在 fork 里模拟，没有在主网发测试币或做测试交易。
- 下一个 nonce 55（`setFactory(0xa1e3…2957, true)`，GangHandlerAdmin）不在这个批次里。

## 链下上线

- CLI 0.42.0：已发布（gangfun/cli `3f6158a`，npm 和 MCP Registry）。文案修改 0.43.1 在 PR #168。
- 服务端 v1.2.103：已上线（gangfun/gangfun-server#63，merge `473a7a9`）。`/v3/tokens/:token/grad-reward` 可用。上线早于 Safe 执行，主网不需要补扫。
- 网站：gangfun/gang-web-legacy#54（奖励面板、`llms.txt`、指南版本号）和 #52（`capabilities.json`）待合并部署。
- 源码验证：还没在 BscScan 提交，需要 BscScan API key。
