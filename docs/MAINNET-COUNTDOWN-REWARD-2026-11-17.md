# 主网 · 倒计时奖励工厂（GangCountdownRewardFactory，`countdown-v1`）

- 链：BSC 主网（chainId 56），2026-11-17
- 规格：`docs/SPEC-COUNTDOWN-REWARD-2026-11-17.md`；测试网记录：`docs/TESTNET-COUNTDOWN-REWARD-2026-11-17.md`
- 源码：合约来自 PR #163（main `35a9564`）。部署时在分支 `cli/countdown-reward` 的 `9517f7c` 上执行，这个分支上 `src/` 和 main 完全相同，部署记录里的 `commit` 字段就是它
- 部署钱包 `0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3`；gas price 0.05 gwei，legacy
- 状态：**工厂已部署，等多签放行**（下面的批次 JSON）。放行之前谁都克隆不了模块

只部署一个新工厂。不改 3.0 pad、税处理器、GangHandlerAdmin、GangRouter 和 abcd 部署器；已有的币和模块不受影响。

## 部署

部署脚本 `script/DeployGangCountdownRewardFactory.s.sol`。主网上只接受 GangLaunchpad 3.0 和它的 GangHandlerAdmin，并要求 pad 已启用 abcd 部署器。记录：`broadcast/DeployGangCountdownRewardFactory.s.sol/56/`。

| 项 | 地址 / 交易 |
|---|---|
| GangCountdownRewardFactory | [`0xa1e3117a59104de7D97667cF22f9AB886a5f2957`](https://bscscan.com/address/0xa1e3117a59104de7D97667cF22f9AB886a5f2957)，部署 [`0xfe1e9f3d…cddd`](https://bscscan.com/tx/0xfe1e9f3d5d0599111f3f6cf0570417a9f434343cadf1622422bf95d6bb40cddd)，区块 134102359，gas 3,406,667 |
| GangCountdownReward（实现合约，工厂部署） | [`0x4bDC318bDB338a5d2DC9DcDd07831a943E5fD35E`](https://bscscan.com/address/0x4bDC318bDB338a5d2DC9DcDd07831a943E5fD35E)，同一笔交易 |
| 源码验证 | Sourcify：两个都是 exact match（创建和运行时字节码都完全一致），[工厂](https://repo.sourcify.dev/56/0xa1e3117a59104de7D97667cF22f9AB886a5f2957)、[实现合约](https://repo.sourcify.dev/56/0x4bDC318bDB338a5d2DC9DcDd07831a943E5fD35E)。BscScan：需要 API key，未提交 |

部署花费约 0.00017 BNB。

接线（脚本模拟和 fork 测试里的 `check` / `checkCode` 都通过）：

| 项 | 值 |
|---|---|
| pad | GangLaunchpad 3.0 `0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29`，abcd 部署器已启用 |
| tax handler | `0x99E882a21847012329351B598ceB93B135691b3B`，owner = GangHandlerAdmin |
| GangHandlerAdmin | `0xC833CEC2B283759003945C0Bf8C048aB1949Af76`，owner = 多签 `0x2866369F7acEFC9760bdE7779362fae5cD68B41E` |
| gangQuote | GANG `0x0c6302401aa5325C2E36F170f52C00B1d220B405` |

链上读回：工厂 `pad()`、`admin()`、`implementation()` 如上，`vanityEnabled()` = true，`count()` = 0；实现合约 `factory()` = 工厂，`taxHandler()` 和 `gangQuote()` 如上；`admin.isFactory(工厂)` = false（等多签）。

工厂没有 owner，不可升级。每个模块的代币、报价币和全部参数都在 dev 克隆时写死，平台不能改。

## 多签批次

文件：`docs/MAINNET-COUNTDOWN-SET-FACTORY-SAFE-BATCH-2026-11-17.json`。只有一笔：

| to | value | data |
|---|---|---|
| GangHandlerAdmin `0xC833CEC2B283759003945C0Bf8C048aB1949Af76` | 0 | `setFactory(0xa1e3117a59104de7D97667cF22f9AB886a5f2957, true)`，即 `0x71013c10…a1e3117a…f2957` + `…01` |

和部署脚本打印的调用一字不差。

## 部署后的验证（主网 fork）

`test/fork/CountdownMainnetFork.t.sol`，对**线上这个工厂**：

- 用部署脚本的 `check` 和 `checkCode` 核对接线、主网规则和运行时字节码；
- 以多签身份原样执行上面的批次 JSON（检查它只有一笔、发给 GangHandlerAdmin、data 和脚本打印的一致），执行后放行；
- 然后走完一整轮：先算代币地址、为它克隆模块、`createWithSalt` 建币、绑定、注入种子钱；曲线毕业进真实的 PancakeSwap 交易对；通过真实路由来回交易产生税，线上 keeper 角色卖税进模块，dev 的 25% 正确记账；3 笔通过模块的计入买入（WBNB 币用 BNB 的 `buy`，USDT 币用 `buyWithQuote`），买入的钱没有留在模块；截止后 `work(0)` 结算，每个买家的份额逐 wei 一致；`claim` 和 `claimDev` 到账一致；每一步之后账目都被余额覆盖。

| 测试 | 结果 |
|---|---|
| `test_liveFactory_wbnb_fullRound` | 通过 |
| `test_liveFactory_usdt_fullRound` | 通过 |

## 之后

1. 多签执行批次，放行工厂。
2. 服务端：主网 env 设 `GANG_COUNTDOWN_FACTORY=0xa1e3117a59104de7D97667cF22f9AB886a5f2957@134102359`，并把内置的主网工厂补上。
3. CLI：写入主网工厂地址，发 0.43.2。
4. 网站：CLI 发布后打开「怎么参与」的命令。
