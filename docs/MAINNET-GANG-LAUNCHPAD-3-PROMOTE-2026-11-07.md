# 主网 · GangLaunchpad 3.0 升级：推广分成（内盘 + 外盘池子）

- 链：BSC 主网（chainId 56），2026-11-07
- 代理（地址不变）：[`0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29`](https://bscscan.com/address/0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29)
- 需求：[#113](https://github.com/gangfun/gang-launchpad/issues/113)。规格：`docs/SPEC-PROMOTER-SHARE-2026-11-04.md`（内盘）、`docs/SPEC-PROMOTER-POOL-SHARE-2026-11-05.md`（外盘池子）。
- 源码：gang-launchpad main `6698e62`（推广分成在 #129、#133、#134，合并于 `2cb3e41`；之后到 `6698e62` 的提交没有改 `src/`、`script/`）。
- 部署钱包 `0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3`；gas price 0.05 gwei，legacy。

上线顺序：先升级 3.0（第一部分），再部署推广分成池的工厂并由多签允许（第二部分）。只有升级之后、带推广分成条款创建的币才有推广分成；已有的币照常交易，没有推广分成。

## 一、3.0 升级

升级脚本 `script/UpgradeGangLaunchpad3.s.sol`，带 `--libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B159820749f178503E4faBCB18A7Ae4492bDb3`。记录：`broadcast/UpgradeGangLaunchpad3.s.sol/56/run-1794055577076.json`。

### 新部署

| 合约 | 地址 | 部署交易 / 区块 |
|---|---|---|
| CurveLogic3（库） | [`0xE3D75A8DF9E9c4ea2990daB12E9624a1FCe67deC`](https://bscscan.com/address/0xE3D75A8DF9E9c4ea2990daB12E9624a1FCe67deC) | [`0xec720908…bcb1`](https://bscscan.com/tx/0xec72090822704a563eb0d4a647cfc6470f3b1b5723a9f2064108224e1225bcb1)，132203078 |
| LegacyRoute（库） | [`0xa71EC02f193cAA81A864aaE2AC0e0bDf63bDc4dD`](https://bscscan.com/address/0xa71EC02f193cAA81A864aaE2AC0e0bDf63bDc4dD) | [`0xd9614a53…6986`](https://bscscan.com/tx/0xd9614a533938dd00e9b4ea28b57b9c781c4471390722bc020e1c78928f076986)，132203082 |
| FairLogic（库） | [`0x74cFb8ea3d0f20D767617C2cdF4DD643E801ee02`](https://bscscan.com/address/0x74cFb8ea3d0f20D767617C2cdF4DD643E801ee02) | [`0x90bb32cc…52dd`](https://bscscan.com/tx/0x90bb32cca8bd921b95789bdd5fbeff58b223a2ede9498db7ee252d59b51e52dd)，132203084 |
| Pad3FlyModule | [`0x0B51F398491F534933d5223590f50D86e361c241`](https://bscscan.com/address/0x0B51F398491F534933d5223590f50D86e361c241) | [`0x5c6b3bf6…3123`](https://bscscan.com/tx/0x5c6b3bf622c6780f9aaad07aed04eeba6467a03a6a4b8bae150e7bc37a343123)，132203087 |
| Pad3Module（含推广分成入口） | [`0x4E7E327621F2FD9A8fea832D9160d7A88344bd6c`](https://bscscan.com/address/0x4E7E327621F2FD9A8fea832D9160d7A88344bd6c) | [`0x45a2b907…4909`](https://bscscan.com/tx/0x45a2b9072650ecab6a25c7e48bc03e4fbb764b7b7123e789fb25edcec5944909)，132203090 |
| GangLaunchpad3 实现（`module()` = 上一行） | [`0xB06DB29008E8569f813e09991B7f76702856F7a4`](https://bscscan.com/address/0xB06DB29008E8569f813e09991B7f76702856F7a4) | [`0xc0a1217d…dd3e`](https://bscscan.com/tx/0xc0a1217d63e7c4d3e672c2153c8ec3fae58a5d5391185dbd758c3faea9d1dd3e)，132203094 |

- 链接的库：上面三个新库，加上沿用的 PoolCheck `0xd2B1…bDb3`、FlywheelLogic `0x866A…3bea`、FlywheelPostLogic `0xBf21…0434`。
- 部署花费约 0.00108 BNB。
- BscScan 源码验证：6 个都已验证（solc 0.8.28，via-IR，按 `foundry.toml`，带上面的库）。
- `initVersion()` = 1，不需要初始化调用。

### 多签批次（已执行）

`docs/MAINNET-GANG-LAUNCHPAD-3-UPGRADE-PROMOTE-SAFE-BATCH-2026-11-07.json`，一笔：ProxyAdmin `0xCe83Be827bf2B6bAFe0ca6d1320Dce965CE3df48` 的 `upgradeAndCall(代理, 0xB06D…F7a4, "")`。已执行 [`0x12e0090f…de9b`](https://bscscan.com/tx/0x12e0090f92ef4ac3e020c1849024a59b9b98d108f5f3288a791b77b8f40bde9b)，区块 132216700，立即生效。上一版实现是 `0xC18eA63d3D44E3Abb78Be7AF984C9825308F0Ab4`。

签名前：

- 升级脚本在模拟里以多签身份执行这笔升级，读回通过（抽查 25 个币，升级前后记录一致）。带 `PAD3_IMPL` 对链上的新实现只读重跑，同样通过，打印的就是这份批次。
- 在主网 fork 上以多签身份原样执行这份 JSON（`PAD3_FORK_BATCH`），然后逐个跑，12 个全过：`Pad3ModulesFork`；`Pad3PromoteUpgradeFork` 7 个（BNB、真实 Agent 门槛、真实 Agent 持有人、线上 router、毕业、USDT、有税分红币）；`Pad3VaultUpgradeFork`；`Pad3LegacyForwardFork`；`Pad3FairEntryFork`；`Pad3FlyUpgradeFork` 的 `signedBatchThenSale`。

执行后读链：实现槽位 = `0xB06D…F7a4`，`module()` = `0x4E7E…bd6c`，代理和 ProxyAdmin 的 owner 仍是多签，Agent 门槛开着，币数不变（138）。用一个真实 Agent 钱包静态调用 `buyWithPromoter`（一个升级前创建的内盘币，0.001 BNB）：成功，买到的数量和普通 `buyTokenAMAP` 相同，估算 gas 246,254；这个币没有推广分成条款，`canBind` 为 false，符合预期。

## 二、推广分成池工厂（`promote-pool-v1`）

部署脚本 `script/DeployGangPromotePoolModuleFactory.s.sol`。记录：`broadcast/DeployGangPromotePoolModuleFactory.s.sol/56/run-1794062506095.json`。

| 项 | 地址 / 交易 |
|---|---|
| GangPromotePoolModuleFactory | [`0xA633e499ADcD69A4F91dc83587096b2c1903167A`](https://bscscan.com/address/0xA633e499ADcD69A4F91dc83587096b2c1903167A)，部署 [`0x1d7c6c77…5202`](https://bscscan.com/tx/0x1d7c6c777d0f02b6246e0b95ccdfb75636ce86e48f50325c53ebe7b12a235202)，区块 132218466，gas 2,597,334 |
| GangPromotePoolModule（实现合约，工厂部署） | [`0x57C1Fd1bDCcf7e4F5884cD72A9c30BD1C38F9b84`](https://bscscan.com/address/0x57C1Fd1bDCcf7e4F5884cD72A9c30BD1C38F9b84)，同一笔交易 |
| BscScan 源码验证 | 两个都已验证 |

部署花费约 0.00013 BNB。

接线（脚本检查模式 `PROMOTE_POOL_FACTORY` 已设，通过；包括运行时字节码比对 `checkCode`）：

| 项 | 值 |
|---|---|
| pad | GangLaunchpad 3.0 `0x2bEb…AB29` |
| tax handler | `0x99E882a21847012329351B598ceB93B135691b3B`，owner = GangHandlerAdmin |
| GangHandlerAdmin | `0xC833CEC2B283759003945C0Bf8C048aB1949Af76`，owner = 多签 |
| 工厂 owner | 多签 `0x2866369F7acEFC9760bdE7779362fae5cD68B41E`（可以 `veto` 争议期内的 root、`setSettler`） |
| settler | `0xFca95021059c9665ef1024C7dDDAe5Fa7e8bEc03`，专用钱包，不是多签、部署钱包或 keeper |
| gangQuote | GANG `0x0c6302401aa5325C2E36F170f52C00B1d220B405` |

签名前：`test/fork/PromotePoolMainnetFork.t.sol` 在升级后的主网状态上逐个跑，8 个全过（WBNB、USDT、USDC、USD1 四种报价币的完整流程，部署脚本，绑定拒绝，`reclaim` 后全部归 dev，托管期结束）。

### 多签批次（已执行）

`docs/MAINNET-PROMOTE-POOL-SET-FACTORY-SAFE-BATCH-2026-11-07.json`，一笔：

| to | 调用 | calldata |
|---|---|---|
| GangHandlerAdmin `0xC833…Af76` | `setFactory(0xA633…167A, true)` | `0x71013c10…a633e499…01`，与部署脚本打印的一致 |

已执行 [`0x033de8c4…cad6`](https://bscscan.com/tx/0x033de8c4ecbdcac3b40d5b328ba65002f74ad6ef5582948c76e17b0cb5b9cad6)，区块 132219892。执行后 `isFactory(0xA633…167A)` = true；链下结算服务按工厂地址开始运行（每个模块默认每周发一次 root，争议期 2 天）。

## 还没做

1. CLI 0.34.0：`GANG_GENS.mainnet` 加上工厂地址后发版（`gang promote …`、`gang create … --promote`）。
2. 网站推广分成页面（gang-web-legacy #29）上线。
3. 主网上的一次小额真实买入和领取。
