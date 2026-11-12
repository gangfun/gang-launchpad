# 主网 · GangLaunchpad 3.0：abcd 地址部署与激活批次

状态：新合约已于 2026-11-10 部署，**代理升级与 abcd 激活已于 2026-11-12 完成**。

- 网络：BSC 主网，chainId 56。
- Pad 3.0 代理：[`0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29`](https://bscscan.com/address/0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29)。
- 源码：[gang-launchpad PR #151](https://github.com/gangfun/gang-launchpad/pull/151)，合并提交 `2629a15fa2d2301468bd4a409a692fbd57def76a`。
- CLI：[CLI PR #23](https://github.com/gangfun/cli/pull/23)，0.38.0 已通过既有 CI 发布至 npm 和 MCP Registry。npm 包内 44 个文件与已测试源码逐字节一致；integrity 为 `sha512-tqYc+7yKae5crViyXAHiI6zieVurNh+uarzHVcHMwF3M6maURiY1dmKwwryN1mXjjzwFSPxtrWFzC5XTmvCMkQ==`。

## 已部署合约

| 合约 | 地址（BscScan 源码已验证） | 部署交易 | 区块 |
|---|---|---|---|
| Pad3VanityDeployer | [`0x8e7691ed55e0c3268118019a68c62ea6d0a6f8de`](https://bscscan.com/address/0x8e7691ed55e0c3268118019a68c62ea6d0a6f8de#code) | [`0x6bbc7dd5…15cbe`](https://bscscan.com/tx/0x6bbc7dd597c989aee5ad74099708dc361a0be1bcc83b6310d41edacb23915cbe) | 132796362 |
| Pad3FlyModule | [`0x05a827db6aa38828b9c4a5a5f001a3f4be3a0661`](https://bscscan.com/address/0x05a827db6aa38828b9c4a5a5f001a3f4be3a0661#code) | [`0xeb491a48…a7649`](https://bscscan.com/tx/0xeb491a48c4753958c2f7fe4ccf5d039cd1261eeab5976d01596cf4072c2a7649) | 132796601 |
| Pad3Module | [`0x9f15202cf053a551ea93727ad0af4b22486483de`](https://bscscan.com/address/0x9f15202cf053a551ea93727ad0af4b22486483de#code) | [`0x84d87318…17be2`](https://bscscan.com/tx/0x84d8731862c1a7ab4b2703f2af80d0fa46b39f5a7712cf4ac3eddf7792817be2) | 132796603 |
| GangLaunchpad3 新实现 | [`0x3f97fd04b3be95ac03e414e3b1f4fb442b70e131`](https://bscscan.com/address/0x3f97fd04b3be95ac03e414e3b1f4fb442b70e131#code) | [`0x9919cb8a…1abc6`](https://bscscan.com/tx/0x9919cb8a2b76a586b4fd949c258ea13e12728453c84afb18081f4a062971abc6) | 132796605 |

四笔部署交易均成功，实际花费共 0.0008618906 BNB。编译器为 solc 0.8.28，via-IR，optimizer runs 200，EVM Cancun。沿用链上已有的 PoolCheck、CurveLogic3、FairLogic、LegacyRoute、FlywheelLogic 和 FlywheelPostLogic；地址完整记录在 Forge 部署记录的 `libraries` 字段中。

Forge 原始记录：

- `broadcast/DeployPad3Vanity.s.sol/56/run-1794322702958.json`
- `broadcast/UpgradeGangLaunchpad3.s.sol/56/run-1794322810618.json`

## Safe 批次（已执行）

归档文件：[MAINNET-GANG-LAUNCHPAD-3-UPGRADE-ABCD-SAFE-BATCH-2026-11-10.json](MAINNET-GANG-LAUNCHPAD-3-UPGRADE-ABCD-SAFE-BATCH-2026-11-10.json)。已执行交易：[`0xe1dc4016…42ed`](https://bscscan.com/tx/0xe1dc4016eb07910813f322926bbfe694cc4674ec293486f5cd38fe4c26ad42ed)，区块 133110602，gas 133,133，费用 0.00000665665 BNB。

- Safe：`0x2866369F7acEFC9760bdE7779362fae5cD68B41E`，需要两位持有者签名。
- 文件 SHA-256：`153240441ead4132facd359c3370a6c862c554d0878781f278ddf143e59b6a9a`。
- 以下两项调用已在同一 Safe 批次中按顺序执行，均未转入 BNB。

| 顺序 | 目标 | 调用 |
|---|---|---|
| 1 | ProxyAdmin `0xCe83Be827bf2B6bAFe0ca6d1320Dce965CE3df48` | `upgradeAndCall(0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29, 0x3f97fd04b3be95ac03e414e3b1f4fb442b70e131, 0x)` |
| 2 | Pad 3.0 代理 | `enableVanity(0x8e7691ed55e0c3268118019a68c62ea6d0a6f8de)` |

激活后，新创建代币地址最后四个十六进制数值固定为 `abcd`；EIP-55 显示的字母大小写可能不同。CLI 0.38.0 自动挖掘 salt，并以最终创建参数预测地址。已有代币继续使用原来的地址。

## 签名前验证

- Pad 3.0 历史回归 811 项通过；CLI 29 个测试文件通过。测试网七种创建路径、旧币买卖及 CLI 创建与交易记录见 [测试网验收](TESTNET-PAD3-ABCD-2026-11-10.md)。
- 对实际部署地址只读重跑 `UpgradeGangLaunchpad3`，校验新实现、模块、库和工厂代码及依赖，模拟升级与激活，对比最近 25 个历史代币的原始状态和交易视图。
- 2026-11-12 在主网区块 133109434 的 fork 上重跑 `test/fork/Pad3VanityUpgradeFork.t.sol::test_fork_signedBatchThenAcceptAllModes`，1 通过、0 失败、0 跳过。原样执行上述 JSON，检查链、Safe、两个目标、零转账金额和完整 calldata；与当天升级脚本重新生成的批次完全一致。
- 最终批次 fork 验收覆盖普通无税、有税、自定义毕业金额、fair、fly、vault、promoter 七种创建路径，以及新旧代币买卖、地址预测、工厂来源、授权清理和 owner 保持。fork 中模拟 Agent ID，没有广播验收交易。
- fork 记录代理写入，要求升级与激活恰好只写实现地址槽与新工厂槽。历史代币存储不得改写。

## 执行后验收与修复原则

执行后读回：代理实现为 `0x3f97fd04b3be95ac03e414e3b1f4fb442b70e131`，`vanityDeployer()` 为 `0x8e7691ed55e0c3268118019a68c62ea6d0a6f8de`；代理与 ProxyAdmin 的 owner 仍为上述 Safe。Safe nonce 从 48 增至 49，阈值仍为 2。

回执含 `ExecutionSuccess`、正确实现地址的 `Upgraded` 和正确工厂地址的 `VanityEnabled`。解码实际 Safe / MultiSend 调用后，两项 calldata、顺序和零转账金额与归档 JSON 完全一致；MultiSend 地址及运行时代码匹配 Safe 官方 v1.5.0 的 BSC 部署，Safe 交易哈希与 nonce 48 对应。

激活后，在主网区块 133111478 的最新状态 fork 上再次运行同一七路径验收 harness：1 通过、0 失败、0 跳过，包含真实历史曲线币买卖、七种创建模式和拒绝无 salt 创建。Agent ID 与测试资金仅在 fork 中模拟，没有在主网广播测试发币或买卖。

主网真实新币创建后的服务端索引与页面展示，尚未作为本次上线的端到端验收完成；此项不能由 fork 验收代替。

激活是单向配置。若激活后需要修复，应保留该工厂及已发币兼容性，发布兼容修复实现；不要直接切回不支持该工厂的旧实现。
