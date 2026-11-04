# 主网 · GangLaunchpad 3.0 升级：打新经入口交易 + 铸币飞轮模式

- 链：BSC 主网（chainId 56），2026-11-04
- 代理（地址不变）：[`0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29`](https://bscscan.com/address/0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29)
- 源码：gang-launchpad main `8e43fe4`（PR #121、#123）。规格 `docs/SPEC-GANG-LAUNCHPAD-3-2026-11-03.md` §2、§3、§10；测试网是「第五次升级」「第六次升级」两节（`docs/TESTNET-GANG-LAUNCHPAD-3-2026-11-03.md`）。
- 升级脚本：`script/UpgradeGangLaunchpad3.s.sol`，带 `--libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B159820749f178503E4faBCB18A7Ae4492bDb3`；部署钱包 `0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3`。

## 新部署

| 合约 | 地址 | 部署交易 / 区块 |
|---|---|---|
| GangLaunchpad3 实现（`module()` = Pad3Module） | [`0xC18eA63d3D44E3Abb78Be7AF984C9825308F0Ab4`](https://bscscan.com/address/0xC18eA63d3D44E3Abb78Be7AF984C9825308F0Ab4) | [`0xfa6454b6…4edb`](https://bscscan.com/tx/0xfa6454b6bae7e894a2ee65f9b2206ad6b0dbc1c07f0dcf8e28b86b83896c4edb) / 131578117 |
| Pad3Module（`flyModule()` = Pad3FlyModule） | [`0x0d11EF6938F3d572eb5f01c4e4df13fD86269F56`](https://bscscan.com/address/0x0d11EF6938F3d572eb5f01c4e4df13fD86269F56) | [`0x0ba48fcf…8690`](https://bscscan.com/tx/0x0ba48fcf5a900e0dec49a3a269c2e8b6efa85754f928d6805c05b46106858690) / 131578112 |
| Pad3FlyModule | [`0x11E857d3D744CBF83acDe64aF4AcF15D3438a05d`](https://bscscan.com/address/0x11E857d3D744CBF83acDe64aF4AcF15D3438a05d) | [`0x1831ac5a…96d5`](https://bscscan.com/tx/0x1831ac5a610b8a7a562d630074cfce6144a75ac50e7a88aedca000845cd496d5) / 131578108 |
| Pad3FlyVaultCore（飞轮币在共享金库里的 core） | [`0x9d90F5412EE7E5Af2868F2D887d836ac7a46767E`](https://bscscan.com/address/0x9d90F5412EE7E5Af2868F2D887d836ac7a46767E) | [`0x1134ad6e…50f5`](https://bscscan.com/tx/0x1134ad6ee144fe4d297022e333bec80e121b564213e89881226a1683b52c50f5) / 131578104 |
| FlywheelTaxHandler（owner 从部署起就是多签） | [`0x7De950738e3D0210be6871220f51708D316F3ba0`](https://bscscan.com/address/0x7De950738e3D0210be6871220f51708D316F3ba0) | [`0x9e977a64…d72f`](https://bscscan.com/tx/0x9e977a647f82b4c4b141544e81801d14084b17204467e274897ecc717dc6d72f) / 131578099 |
| CurveLogic3 | [`0x67352d5349C6D624894cbcFdC4cC669cb3d11665`](https://bscscan.com/address/0x67352d5349C6D624894cbcFdC4cC669cb3d11665) | [`0x76481941…afd4`](https://bscscan.com/tx/0x76481941483d8deb868dfcf1591792ecfe1c3024c91a43d97ddb7d107d86afd4) / 131578077 |
| FairLogic | [`0xC7695064298d526aAa0840cB399d1BE9dD74d3E0`](https://bscscan.com/address/0xC7695064298d526aAa0840cB399d1BE9dD74d3E0) | [`0xa4efd344…9791`](https://bscscan.com/tx/0xa4efd34461b3c1e44a853a8f06927eaabd10899a8d891f65a54ad2a3c05d9791) / 131578095 |
| LegacyRoute | [`0x6B983b80c667ad3391CB2866b55a6c8413e72822`](https://bscscan.com/address/0x6B983b80c667ad3391CB2866b55a6c8413e72822) | [`0xec571ce4…db1a`](https://bscscan.com/tx/0xec571ce49071641cb2521810a4ec977b2ddd536bd8d1b9ffebae98ec4365db1a) / 131578082 |
| FlywheelLogic | [`0x866AC3c06b19De7f73e1fa066d269Ae1F92C3bea`](https://bscscan.com/address/0x866AC3c06b19De7f73e1fa066d269Ae1F92C3bea) | [`0x307fd97d…7625`](https://bscscan.com/tx/0x307fd97d4edc8a517a9f5607b945822698e7493c9fe88ec50cbf995bc6037625) / 131578091 |
| FlywheelPostLogic | [`0xBf2166d27FffDf1217B0cCac9Bc623aa88200434`](https://bscscan.com/address/0xBf2166d27FffDf1217B0cCac9Bc623aa88200434) | [`0x1cd225f0…bde2`](https://bscscan.com/tx/0x1cd225f0c11c4cb985d1c14742bdfb9de13006f884152647d63e28e8ad45bde2) / 131578087 |

- 实现合约的 7 个共用依赖和上一版相同；`initVersion()` = 1（不需要初始化调用），`TOKEN_VERSION` = 1。
- 飞轮的代币部署器沿用飞轮 V2 的 MintTokenDeployer [`0x2C95228AfA6eF211371A87f480aBa0f5c0Da072E`](https://bscscan.com/address/0x2C95228AfA6eF211371A87f480aBa0f5c0Da072E)。
- 部署花费约 0.0016 BNB（gas price 0.05 gwei，legacy）。记录：`broadcast/UpgradeGangLaunchpad3.s.sol/56/run-1793774236772.json`。
- BscScan 源码验证：10 个合约都已验证（solc 0.8.28，via-IR，按 `foundry.toml`，带记录里的 6 个库）。

## 多签批次（已执行）

`docs/MAINNET-GANG-LAUNCHPAD-3-UPGRADE-FLY-SAFE-BATCH-2026-11-04.json`，7 笔，已执行 [`0x021b818f…84b9`](https://bscscan.com/tx/0x021b818ff47ca261d58961b7faf251d34a2a697ce214216c47e8efc9285f84b9)（区块 131582959）：

1. 税处理器 `setLaunchpad(3.0)`
2. 税处理器 `setKeeper(0xB6f1F1BFb92476Abb0998B425dE0deC5F927cFc7)`
3. MintTokenDeployer `setLaunchpad(3.0, true)`
4. 平台费桶 `setOperator(税处理器, true)`
5. 共享金库 `setLaunchpad(core, true)`
6. 共享金库 `setOperator(税处理器, core)`
7. ProxyAdmin `upgradeAndCall(代理, 0xC18e…0Ab4, "")`

签名前：

- 升级脚本只读重跑（`PAD3_IMPL`、`PAD3_FLY_HANDLER`、`PAD3_FLY_VAULT_CORE`）：在模拟里以 Safe 身份执行这 7 笔，代码逐字节比对、升级前后的快照、阶段 2 读回都通过；打印的批次和这份文件逐笔相同。
- 主网 fork 上以 Safe 身份原样执行这份文件（`PAD3_FORK_BATCH`，spec §6），然后这些测试都通过：`Pad3ModulesFork`（线上模块套装）、`Pad3FlyUpgradeFork` 的 `test_fork_signedBatchThenSale`（飞轮发售、入口买卖、开池、分红）、`Pad3FairEntryFork`、`Pad3VaultUpgradeFork`、`Pad3LegacyForwardFork`（线上 1.0、2.0 的曲线币，飞轮 V1、V2 的发售）。

执行后：

- 读链：实现槽位 = `0xC18e…0Ab4`，`module()` = `0x0d11…9F56`，`flyModule()` = `0x11E8…a05d`，`flyTaxHandler()` = `0x7De9…3ba0`，`flyVaultCore()` = `0x9d90…767E`；owner = 多签，Agent 门槛开启，币数不变。
- 读链：税处理器的 owner = 多签，`launchpad` = 代理，keeper 已设；MintTokenDeployer 列着代理；费桶的 operator 列着税处理器；金库 `operatorOf(税处理器)` = core，`operatorFor(core)` = 税处理器，税处理器已排除出份额；`flyRouters(GangGateway)` = false。
- 只读重跑阶段 2（`script/DeployGangLaunchpad3.s.sol`）：`self-check ok`，多签没有剩余步骤。
- 在升级后的主网状态上重跑上面 5 组 fork 测试：都通过。

## 现在主网 3.0 上多了什么

- 打新经入口交易：设了门槛的打新发售（3.0 自己的，以及经 3.0 转发的 1.0、2.0）可以经 `getTokenInfo` / `tryBuy` / `buyTokenAMAP` / `sellToken` 交易。
- 铸币飞轮模式（`kindOf` = 3）：规则和飞轮 V2 相同，门槛 1,000 代币，飞轮 router 名单默认为空（所以 GangGateway 不能交易 3.0 的飞轮币，3.0 自己的入口可以）。

## 还没做

- 后端、网站、CLI 的接入更新：飞轮的 `flyTaxHandler()`、`registry.lookup`、`shareSizeOf`（spec §10）。在 keeper 接上新税处理器之前，3.0 飞轮币开池后的税只累积、不处理。
- 在 3.0 上登记实际的合作方金库，要在切换批次之前做。
- 切换批次（批次 5）：1.0、2.0、金库版、铸币飞轮 V2 停止发币。
