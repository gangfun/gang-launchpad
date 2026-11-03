# 主网 · GangLaunchpad 3.0 的模块套装（GangBond、回购 / 分账 / 加池 / 组合工厂、GangHandlerAdmin）

- 链：BSC 主网（chainId 56），2026-11-03
- 这些合约每个都永久绑定一个 pad。1.0、2.0 各有一套；这一套绑定 3.0 代理 [`0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29`](https://bscscan.com/address/0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29)。合约源码和 2.0 那套相同，没有改动；只改了部署脚本选 pad 的方式（`script/GangModulePadScript.sol`，见下）。
- 部署钱包 `0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3`，花费约 0.0008 BNB（gas price 0.05 gwei，legacy）。
- 测试网：`docs/TESTNET-GANG-LAUNCHPAD-3-2026-11-03.md` 的「模块套装」一节。

## 地址

| 合约 | 地址 | 部署交易 / 区块 |
|---|---|---|
| GangHandlerAdmin（3.0 税处理器的 admin） | [`0xC833CEC2B283759003945C0Bf8C048aB1949Af76`](https://bscscan.com/address/0xC833CEC2B283759003945C0Bf8C048aB1949Af76) | [`0xe3746709…d527`](https://bscscan.com/tx/0xe37467091df2e21f8f331236573bc9bb9d8edd4ffb15508b3578ade68336d527)，131436669 |
| GangBuybackSplitterFactory | [`0xc1282e7Fd3DFa5e00e74E9EbF8c54fFfB5763194`](https://bscscan.com/address/0xc1282e7Fd3DFa5e00e74E9EbF8c54fFfB5763194)，实现 [`0xdc3b8C06b378Ece6814C3aC13075ABa56fc9BECb`](https://bscscan.com/address/0xdc3b8C06b378Ece6814C3aC13075ABa56fc9BECb) | [`0x543ef923…6d9d`](https://bscscan.com/tx/0x543ef923996fb827d43092389a951845df6d14db4b1d100d93d98b1904af6d9d)，131436674 |
| GangBond | [`0x830b38F695Ca1bCbdD313CD5AA5943e2125Be9D6`](https://bscscan.com/address/0x830b38F695Ca1bCbdD313CD5AA5943e2125Be9D6) | [`0x7aac7214…aaea`](https://bscscan.com/tx/0x7aac721428fbdba001205cdc6c088cc633c99787593b975cb56a1cf2b5faaaea)，131436706 |
| GangSplitModuleFactory | [`0x904D4498a9257E4d7638afEbB95A1162cB2171f2`](https://bscscan.com/address/0x904D4498a9257E4d7638afEbB95A1162cB2171f2)，实现 [`0x43db02Fd9FeCb9E0D47d2665C2BA45512d8764Ac`](https://bscscan.com/address/0x43db02Fd9FeCb9E0D47d2665C2BA45512d8764Ac) | [`0x4e36d7af…39c1`](https://bscscan.com/tx/0x4e36d7af135a1c45881683ecc018778ba3fe8caf942d448dccddf5523df139c1)，131438697 |
| GangLiquiditySplitterFactory | [`0x98C506F0F4762F9d1Ec96C27499CE8B7e5981752`](https://bscscan.com/address/0x98C506F0F4762F9d1Ec96C27499CE8B7e5981752)，实现 [`0x5Bd642131aA05805717B76143122867B9E3A0BAc`](https://bscscan.com/address/0x5Bd642131aA05805717B76143122867B9E3A0BAc) | [`0xe148f112…516d`](https://bscscan.com/tx/0xe148f112e36e4d931a222a4d84e64edcb3b2ae0f2ae9a9cf48ce909e7df6516d)，131438735 |
| GangComboSplitterFactory | [`0x20188054dE31De844df205712768852BdeD3eA39`](https://bscscan.com/address/0x20188054dE31De844df205712768852BdeD3eA39)，实现 [`0xD872F602e33d1142370A647e8244996b8A4a7fe0`](https://bscscan.com/address/0xD872F602e33d1142370A647e8244996b8A4a7fe0) | [`0xcc4153e1…8f30`](https://bscscan.com/tx/0xcc4153e14299962183ec564fb32f6332a2a8bdc499d6e1d2ea1589d708038f30)，131438771 |

- 四个工厂和 GangBond 的 `pad()` 都是 3.0；工厂的 `admin()` 都是上面的 GangHandlerAdmin。Split 和 Combo 的 `gangQuote` 是 GANG `0x0c6302401aa5325C2E36F170f52C00B1d220B405`。
- 10 个合约在 BscScan 上都已验证（solc 0.8.28，via-IR，按 `foundry.toml`）。
- 部署记录：`broadcast/DeployGang{BuybackSplitterFactory,Bond,SplitModuleFactory,LiquiditySplitterFactory,ComboSplitterFactory}.s.sol/56/`。

## 多签批次（都已执行）

和 2.0 上线时的模块批次相同，分两批：Split / LP / Combo 三个脚本要求 admin 已经持有 handler，所以只能在批次 1 之后部署。

1. **批次 1（5 笔）**，`docs/MAINNET-GANG-LAUNCHPAD-3-MODULES-SAFE-BATCH-1-2026-11-03.json`，已执行 [`0xc92f43a9…b402`](https://bscscan.com/tx/0xc92f43a92f1f7547f757ac59ed9aef3cfc5814849d6b4c2fa8559400b463b402)，区块 131438345：
   - 3.0 税处理器 `0x99E882a21847012329351B598ceB93B135691b3B` 的 `transferOwnership(admin)`，以及 `admin.exec(acceptOwnership())`；
   - `admin.setFactory(回购工厂, true)`；
   - `admin.exec(list(…))` ×2：把 2.0 上登记的两个合作方 recipient 照原标签登记到 3.0。2.0 handler 上其余的 recipient 都是 2.0 工厂的克隆，绑定 2.0，不迁。
2. **批次 2（3 笔）**，`docs/MAINNET-GANG-LAUNCHPAD-3-MODULES-SAFE-BATCH-2-2026-11-03.json`，已执行 [`0xbc484d19…6407`](https://bscscan.com/tx/0xbc484d190a4ff37f9135cb889b05c382eff38cd7a6f9714fa2e92b16dde06407)，区块 131440052：`admin.setFactory(true)` 给 Split、LP、Combo 三个工厂。

每批签名前都在主网 fork 上原样执行过这份 JSON：批次 1 之后模拟了后面三个工厂的部署；批次 2 之后用 `test/fork/Pad3ModulesFork.t.sol` 的线上模式（`PAD3_FORK_LIVE=true`，传入上面的地址）把这套模块完整跑了一遍：四个工厂各克隆一个模块并绑定 3.0 的税币，GangBond 发押金，组合模块的币在 3.0 上毕业、池子卖出收税、keeper 处理、回购销毁、加池、分账。

执行后读链核对：3.0 税处理器的 owner 是 GangHandlerAdmin，没有待接收的 owner；admin 的 owner 是多签；`factories()` 列出四个工厂，`isFactory` 都为真；两个合作方 `isListed` 为真。批次 1 之后在主网上只读重跑 3.0 的阶段 2（`script/DeployGangLaunchpad3.s.sol`，带 `--libraries` 指定线上 PoolCheck）：`self-check ok`，Safe 没有剩余步骤（admin 持有 handler 被认作多签持有）。

## 部署脚本的改动（`script/GangModulePadScript.sol`）

主网上，模块脚本原来只接受 `GANG_PAD2`（2.0）。现在：

- `GANG_PAD3` 必须等于 3.0 代理地址（写死）；
- `GANG_PAD2` 拒绝 1.0、3.0 和金库版 pad（金库版 pad 也登记在 Registry、归多签、creator 分成也是 7000，原来的检查拦不住它）；
- 两个都设置时直接拒绝。

## 3.0 升级时要注意

这套模块和 GangBond 永久依赖 3.0 的地址，而 3.0 可以升级。升级不能改动模块读的接口：`kindOf` 的取值、`curves` 的前 12 个字段、`sales` 的前 14 个字段、`isAgent`、`taxHandler()`、`wbnb()`、`quoteRegistry()`。每次升级前，按 spec §6 在新实现上用线上模式重跑 `test/fork/Pad3ModulesFork.t.sol`（`PAD3_FORK_IMPL` + `PAD3_FORK_LIVE=true`，不带 `--libraries`）。

## 还没做

- 后端索引和 keeper 加上这套地址（GangBond、四个工厂的克隆）；CLI 在 3.0 这一代里填上 `comboFactory` 等工厂地址和 bond。
- 3.0 的切换批次（批次 5）仍等后端、网站、CLI 都切到 3.0。
