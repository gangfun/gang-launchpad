# 主网 · GangLaunchpad 3.0 升级：金库模式（Pad3Module）

- 链：BSC 主网（chainId 56），2026-11-03
- 代理（地址不变）：[`0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29`](https://bscscan.com/address/0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29)
- 源码：gang-launchpad main `6863704`（PR #119，合并了 #118）。规格 `docs/SPEC-GANG-LAUNCHPAD-3-2026-11-03.md` §9；测试网是「第四次升级」一节（`docs/TESTNET-GANG-LAUNCHPAD-3-2026-11-03.md`）。
- 升级脚本：`script/UpgradeGangLaunchpad3.s.sol`，在 `6863704` 上运行，带 `--libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B159820749f178503E4faBCB18A7Ae4492bDb3`；部署钱包 `0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3`。

## 新部署

| 合约 | 地址 | 部署交易 / 区块 |
|---|---|---|
| Pad3Module（金库模式 + 挪过来的查询函数） | [`0xa712E8194aEE0291638bF1b6Cb440A07c40c409A`](https://bscscan.com/address/0xa712E8194aEE0291638bF1b6Cb440A07c40c409A) | [`0x572904ba…c7cb`](https://bscscan.com/tx/0x572904ba7fcec81b32d20e92d9d5e5e353753466fe2ce4022a4e7ba3206dc7cb)，131452137 |
| GangLaunchpad3 实现（`module()` = 上一行） | [`0x88A4C3e0AE30Ae47Cd4DE6d79da6Fe0dB95B028D`](https://bscscan.com/address/0x88A4C3e0AE30Ae47Cd4DE6d79da6Fe0dB95B028D) | [`0x93d6c17a…e1eb`](https://bscscan.com/tx/0x93d6c17a478785047d2d3ec1a142fd8949204345f5fb9e89c8a10478654ee1eb)，131452143 |

- 两个合约链接的库和当前实现相同，没有新部署库：CurveLogic3 `0x21DAC269a78BFF0d261783a191E9EbaAeF4e5913`、FairLogic `0x34E18563622aE05e92FdaCA81a40D83652067c9D`、LegacyRoute `0x30764D22EB16Bec685fB574f8ae17a6ecD45C7d1`、PoolCheck `0xd2B159820749f178503E4faBCB18A7Ae4492bDb3`。
- 7 个依赖地址和上一版实现相同；`initVersion()` = 1（不需要初始化调用），`TOKEN_VERSION` = 1。
- 部署花费约 0.00034 BNB（gas price 0.05 gwei，legacy）。记录：`broadcast/UpgradeGangLaunchpad3.s.sol/56/run-1793717554582.json`。
- BscScan 源码验证：实现合约和模块都已验证（solc 0.8.28，via-IR，按 `foundry.toml`，带上面四个库）。

## 多签批次（已执行）

`docs/MAINNET-GANG-LAUNCHPAD-3-UPGRADE-VAULT-MODE-SAFE-BATCH-2026-11-03.json`，一笔：ProxyAdmin `0xCe83Be827bf2B6bAFe0ca6d1320Dce965CE3df48` 的 `upgradeAndCall(代理, 0x88A4…028D, "")`。已执行 [`0x6e2b2f13…ab1c`](https://bscscan.com/tx/0x6e2b2f137463ac0567b93ce1ae7837ae863aa499a3c90ed54c7c264c8e0aab1c)，区块 131454282，立即生效。上一版实现是 `0x6e697106BD525AAB8fc0DdC076bd54Be09Ed6231`。

签名前：

- 升级脚本在模拟里以 Safe 身份执行这笔升级：新实现和模块的代码都和这次构建的参照逐字节一致，两边只链接列出的库；升级前后的设置、`CALLERS` 白名单状态和币的记录 / 计算结果一致（这是第一次升级到金库模式，升级前没有金库状态可比）；阶段 2 读回通过。带 `PAD3_IMPL` 对链上的新实现只读重跑，同样通过。
- 在主网 fork 上原样执行这份 JSON，然后：`test/fork/Pad3ModulesFork.t.sol` 线上模式（spec §6，3.0 的模块套装在新实现上跑一遍）通过；`test/fork/Pad3VaultUpgradeFork.t.sol` 在升级后的代理上再演练一次升级并走完金库流程，通过。

执行后：

- 读链：实现槽位 = `0x88A4…028D`，`module()` = `0xa712…409A`，`vaultOf(0)` 有应答（金库模式已上线），owner = 多签，Agent 门槛、migrator、币数不变。
- 只读重跑阶段 2（`script/DeployGangLaunchpad3.s.sol`）：`self-check ok`，多签没有剩余步骤。
- 在升级后的主网状态上重跑 `Pad3ModulesFork`（线上模式）和 `Pad3VaultUpgradeFork`：都通过。

## 现在主网 3.0 上多了什么

- 金库模式：多签 `setVault` / `setVaultCreator`，被指定的钱包 `createWithVault`，金库 `vaultLock` / `vaultRelease`。锁仓量计入 1% 上限，币自己的金库不能交易它，登记过的金库永远不能成为 router。规则和 GangVaultLaunchpad 相同；3.0 的其他创建入口照常开放。
- 13 个只给链下用的查询函数改由模块经 fallback 应答，选择器不变。

## 还没做

- 在 3.0 上登记实际的合作方金库（多签 `setVault`、handler `admin.exec(list)`、`setVaultCreator`），等合作方准备在 3.0 上发币时再做。
- 后端、网站、CLI 的 3.0 接入（各自的 PR）上线；之后才是切换批次（批次 5）。
