# 测试网 · GangLaunchpad 2.0（内盘 creator 分成 + 可选毕业门槛）

- 日期：2026-10-31 Asia/Shanghai
- 网络：BSC 测试网（97），和第 10 套 GangLaunchpad（1.0，`0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1`）并列，共用它的共享合约
- 规格：`docs/SPEC-CURVE-CREATOR-FEE-2026-10-31.md`、`docs/SPEC-CURVE-GRAD-TARGET-2026-10-31.md`
- 部署钱包：`0xCa8e…00b6`（测试网上它拥有全部共享合约，阶段 1 直接完成登记并开放）

当天部署过两次：
- **当前（第二版）**：加入了可选毕业门槛（6 / 9 / 12 / 15 BNB，默认 9），源码是 `ccea84d`。这个改动先经过独立审计，修复后又做了独立复审。
- **第一版**：只有 creator 分成，记录在本文后半部分。第二版上线后，第一版已停止创建（`TokenDeployer.setLaunchpad(第一版, false)`，交易 [`0x1fa62a1c…fb4f`](https://testnet.bscscan.com/tx/0x1fa62a1c99c995a3a3d974acd1a96d2851f1b04af0c01177d1ade239f5b5fb4f)）。第一版上已有的币照常交易、领取。

## 第二版（当前）

### 地址

| 合约 | 地址 |
|---|---|
| **GangLaunchpad 2.0** | [`0xb14d415f70D7F99f0D93Bd3BF76e0D6b38b53B3E`](https://testnet.bscscan.com/address/0xb14d415f70D7F99f0D93Bd3BF76e0D6b38b53B3E)，起始区块 139940227 |
| GangTaxHandler | [`0x5d77FD790B019F86c2473f9CcaeB22609A574278`](https://testnet.bscscan.com/address/0x5d77FD790B019F86c2473f9CcaeB22609A574278) |
| GangRouter（代理：pad 列入、用户授权的地址） | [`0x5a4FA2D91638a305EdF027894753c943f095dDAA`](https://testnet.bscscan.com/address/0x5a4FA2D91638a305EdF027894753c943f095dDAA) |
| GangRouter 实现 / ProxyAdmin / Timelock | `0xb65d10F295a0E91643308caf22F325B58f8e5750` / `0x47e367808E7C9E42f5a9F3a5D436496Aeeb5fE3E` / `0x5264d34a05125438827c94467acbAdd318cfc356` |
| CurveLogic / FairLogic | `0x8c61E0D4fa2b3D2540452d545BA77ec65e147599` / `0xEf8A86a23919D66F5706665E9939E07aD21Aaa8a` |
| GangHandlerAdmin（handler 的 owner） | [`0xEbFD66D7959f345cbE8023Fa09bDe6f6C8D2eF38`](https://testnet.bscscan.com/address/0xEbFD66D7959f345cbE8023Fa09bDe6f6C8D2eF38) |
| GangBuybackSplitterFactory（`buyback-burn-v4`） | [`0xDC9EdA9a29F4Ff66E7dAb6E5A2142df5a7aC0f6e`](https://testnet.bscscan.com/address/0xDC9EdA9a29F4Ff66E7dAb6E5A2142df5a7aC0f6e) |
| GangSplitModuleFactory（`split-v1`） | [`0xb9ab949C717a4F7f05c7B003C612C437280C3513`](https://testnet.bscscan.com/address/0xb9ab949C717a4F7f05c7B003C612C437280C3513) |
| GangLiquiditySplitterFactory（`lp-burn-v1`） | [`0xAEec7e7948FfDb7a212E14c0b9cc1DA2922436E4`](https://testnet.bscscan.com/address/0xAEec7e7948FfDb7a212E14c0b9cc1DA2922436E4) |
| GangBond | [`0x39749B59066d9cd1c55E2Fc48B31a3978C9951F9`](https://testnet.bscscan.com/address/0x39749B59066d9cd1c55E2Fc48B31a3978C9951F9) |

### 部署

命令和第一版相同（见下文），结果：
- 24 笔交易，合计 gas 18,081,201，全部成功；
- 阶段 1 自检 `self-check ok`，再用 `GANG_PAD2` / `GANG_ROUTER2` / `GANG_PAD2_BLOCK` 只读重跑阶段 2，也是 `self-check ok`；
- 自检包括 `TARGET_GRAD_BNB = 9 BNB`，`graduationAmountFor(WBNB, 0, 6 BNB) = 6 WBNB`，以及 10 BNB 被 `BadGradTarget` 拒绝。

模块用现有的四个脚本部署，`GANG_PAD` 指向第二版，`HANDLER_ADMIN` 指向新的 admin。

链上核对：
- handler 的 owner 是 admin，`admin.handler()` 指回 handler；
- 三个 factory 的 `pad()` 都是第二版，`admin.isFactory` 都为真，LABEL 分别是 `buyback-burn-v4` / `split-v1` / `lp-burn-v1`；
- `GangBond.pad()` 是第二版；
- `GRAD_BNB_TIERS = [6, 9, 12, 15] BNB`，`CREATOR_FEE_SHARE_BPS = 7000`，migrator 是共享 migrator。

部署记录：`broadcast/<脚本>/97/` 下本次新增的带时间戳文件：
- `DeployGangLaunchpad2` `run-1793423929106`，它的 `run-latest.json` 指向这一次；
- Buyback `run-1793424031266`；
- Split `run-1793424058051`；
- LP `run-1793424074514`；
- Bond `run-1793424085838`。

### 验收（`script/GangLaunchpad2TestnetAcceptance.s.sol`）

| 步骤 | 结果 | 交易 |
|---|---|---|
| 用 `create` 建 WBNB 曲线币 A（无税，默认门槛） | [`0xf289cF3Cb4f9299a50425ce0eF0D90594b441F4D`](https://testnet.bscscan.com/address/0xf289cF3Cb4f9299a50425ce0eF0D90594b441F4D)：`gradTargetOf` = 9 BNB，`gradAmt` = 9 WBNB | [`0x7e0d3d93…d514`](https://testnet.bscscan.com/tx/0x7e0d3d9341c22ac7b0018a061c0e24806fd0d453cff4fa0c7c3441db97efd514) |
| 经 Router 用 0.002 BNB 买入 | creator 记 14,000,000,000,000 wei（1% 的 70%） | [`0x6a103067…bdf1`](https://testnet.bscscan.com/tx/0x6a103067688e6eb45588cb22e35d5c43b52dc341be460b92d5aa1f1d576dbdf1) |
| 在 pad 上直接卖出一半 | creator 累计 20,932,286,145,571 wei | [`0xc10e3935…f91f`](https://testnet.bscscan.com/tx/0xc10e393591f070aaf75de05696d0fb9de7ceac7b37387971258022ea1bf1f91f) |
| creator 领取 | 收到 20,932,286,145,571 wei WBNB | [`0x27d580bc…dda9`](https://testnet.bscscan.com/tx/0x27d580bc47f4d7d59aa3da60da6370ab2a4ed23cadac2f51a5ef382dcff0dda9) |
| 用 `createWithGradTarget(…, 6 BNB)` 建测试报价币曲线币 B（税 3%、分红 40%、接收地址 = creator） | [`0x5B8eB81078d3B94F66b01A97F5a06Ab0D9Dd6Be8`](https://testnet.bscscan.com/address/0x5B8eB81078d3B94F66b01A97F5a06Ab0D9Dd6Be8)：`gradTargetOf` = 6 BNB，`gradAmt` 等于 `graduationAmountFor` 的报价 | [`0x6673797f…02a7`](https://testnet.bscscan.com/tx/0x6673797f872fcf66ad83fec46cee8e4da93abaa459b80142a52ff7f6558502a7) |
| 临时关闭钱包上限，一笔买到毕业，再打开上限 | 经共享 migrator 毕业，交易对 [`0x073A5357828729bF90cBE6290924CBC510442096`](https://testnet.bscscan.com/address/0x073A5357828729bF90cBE6290924CBC510442096)；creator 记 42,424,242,424,242,424 wei | 关 [`0x25fe23bb…a9c5`](https://testnet.bscscan.com/tx/0x25fe23bbc2c9736d17097abc399b31e5d2fadd7362a6f8bd8e8503657cf2a9c5)，买 [`0x1dc5bff1…9964`](https://testnet.bscscan.com/tx/0x1dc5bff17b445d7fc63d6e3c50f1f78d3723dceb581ab0f4faf826c5562e9964)，开 [`0x2e8b9ca9…0d3d`](https://testnet.bscscan.com/tx/0x2e8b9ca9196b9eb999ee2bf65e4721512f5d2c903422bc8fb0e7618ab8df0d3d) |
| 毕业后领取 | 收到全部分成 | [`0xb5a6c4e2…a0a3`](https://testnet.bscscan.com/tx/0xb5a6c4e20a3d9b1a674ee2e5220af8c4e2abd718e9cdc6a0262dbf4d51c3a0a3) |

直接读链复核：
- A、B 的 `creatorFeeOf` 都已归零，钱包上限已重新打开；
- 第二版持有的 WBNB 为 989,673,407,775,435 wei，正好等于 A 的 `realQuote`，没有零头。

### 四档门槛（`script/GangLaunchpad2TierMatrixTestnet.s.sol`）

每档（6 / 9 / 12 / 15 BNB）建三个币，给后端、网站、CLI 做显示核对的样本：
- 一个 WBNB 币，经 2.0 Router 买 0.001 BNB；
- 一个测试报价币（与 BNB 1:1，所以毕业额等于门槛），买到毕业额的一半，不毕业；
- 一个带税的测试报价币（税 3%、分红 40%），买过毕业额，经共享 migrator 毕业，然后领取 creator 分成。

运行期间临时关闭钱包上限，结束时重新打开（[关](https://testnet.bscscan.com/tx/0x3087595f8d895d397b6b9437dc87e8731faf94dc4e7f58a156ce41cd0fafe22c) / [开](https://testnet.bscscan.com/tx/0xd4ee2da8cc38c35ca2a66889f238b4c7073de7165dd35b5f20edaf4261cdc435)）。部署记录：`broadcast/GangLaunchpad2TierMatrixTestnet.s.sol/97/run-1793442276804.json`。

| 门槛 | WBNB 币 | 一半（`realQuote` / 毕业额） | 已毕业（交易对） |
|---|---|---|---|
| 6 | [`0x70aaD0e5eF7ccE2b5512f01028D347FC6FcBe568`](https://testnet.bscscan.com/address/0x70aaD0e5eF7ccE2b5512f01028D347FC6FcBe568) | [`0x8f41028364F8825dCc3de3D8f0985C05738F952d`](https://testnet.bscscan.com/address/0x8f41028364F8825dCc3de3D8f0985C05738F952d)：2.97 / 6 | [`0x9dEBB83f07240Aec352577064F1bf87b54eb5737`](https://testnet.bscscan.com/address/0x9dEBB83f07240Aec352577064F1bf87b54eb5737)（[`0x1326…2892`](https://testnet.bscscan.com/address/0x1326772047087b794aABedefF16E947471FA2892)） |
| 9 | [`0xf17B6BaE39F2681C66D4580FC41F2ED6f43f1111`](https://testnet.bscscan.com/address/0xf17B6BaE39F2681C66D4580FC41F2ED6f43f1111) | [`0x6b7De715FbB37F23b138C76751487631F1895f30`](https://testnet.bscscan.com/address/0x6b7De715FbB37F23b138C76751487631F1895f30)：4.455 / 9 | [`0xD6f00B30ab103BD816988D2C58d21bf8FB585522`](https://testnet.bscscan.com/address/0xD6f00B30ab103BD816988D2C58d21bf8FB585522)（[`0xe87D…526e`](https://testnet.bscscan.com/address/0xe87D197D52aB020CdCAB68eB348A4757Eda4526e)） |
| 12 | [`0xfb9Cd64F6ea99755fb2F573EDA0B5b3590C84daC`](https://testnet.bscscan.com/address/0xfb9Cd64F6ea99755fb2F573EDA0B5b3590C84daC) | [`0x6a51cA4ab52c7A7e8c62f840E10a2D820ef83E1b`](https://testnet.bscscan.com/address/0x6a51cA4ab52c7A7e8c62f840E10a2D820ef83E1b)：5.94 / 12 | [`0x10174D125AeDfA0469cF5619d98346369b354E65`](https://testnet.bscscan.com/address/0x10174D125AeDfA0469cF5619d98346369b354E65)（[`0x278E…187C`](https://testnet.bscscan.com/address/0x278E3622A7E3CfB9b614d483b845e19C59Ca187C)） |
| 15 | [`0x61dDDd669b97516Fe0F14d582e0fDd2D022cf633`](https://testnet.bscscan.com/address/0x61dDDd669b97516Fe0F14d582e0fDd2D022cf633) | [`0x2700Fcd3f335Ffa0084997Abb481f874898EacE8`](https://testnet.bscscan.com/address/0x2700Fcd3f335Ffa0084997Abb481f874898EacE8)：7.425 / 15 | [`0xFCA1120e0AB74BC37981b8801A208a777Ad04C00`](https://testnet.bscscan.com/address/0xFCA1120e0AB74BC37981b8801A208a777Ad04C00)（[`0x0ab0…Ce8f`](https://testnet.bscscan.com/address/0x0ab00757B34C713f230f2B220aef44e496BdCe8f)） |

脚本在模拟里逐档检查：`gradTargetOf` 和 `gradAmtOf` 等于所选档位；买到一半的币没有毕业；毕业的币开池市值在门槛的 5 倍 ±3% 以内；毕业后领取到全部分成。

广播后直接读链复核：
- 12 个币的 `gradTargetOf`、`gradAmt`、`realQuote`、是否毕业都和上表一致；
- 钱包上限已重新打开；
- 第二版持有的 WBNB 为 6,971,673,407,775,435 wei，等于它所有 22 个曲线币的 WBNB `realQuote` 加上未领的 creator 分成，没有零头。
- 毕业后在 6 档已毕业币的池子里，经 PancakeSwap V2 用 0.1 测试报价币买入（[`0x3f8daeab…a34f`](https://testnet.bscscan.com/tx/0x3f8daeab054864a4ca3f2ea68f79664283ba311c165fec8929739102c86aa34f)），再卖出一半（[`0xeec5409c…31a2`](https://testnet.bscscan.com/tx/0xeec5409c2e4ba3f9667218f3c01183e82cdbab0a39a9dd4ddda30bbaf79e31a2)），拿回 0.0487，扣除了买卖各 3% 的税。

主网 fork 上（`test/fork/GangLaunchpad2DeployFork.t.sol`）用真实的共享合约把四档 WBNB 币（带税和不带税）、一个 6 BNB 的 USDT 币各走完一遍：买到毕业、开池约 5 倍、领取分成，WBNB 币毕业后还在 PancakeSwap 上买卖一次。

部署和验收合计约花 0.0056 tBNB。

## 第一版（已停止创建）

### 地址

| 合约 | 地址 |
|---|---|
| **GangLaunchpad 2.0** | [`0x6381707406eb7E8EF8EdaF2DedBfFcEFFC0b39be`](https://testnet.bscscan.com/address/0x6381707406eb7E8EF8EdaF2DedBfFcEFFC0b39be)，起始区块 139866088 |
| GangTaxHandler（2.0） | [`0x5A37E9f7e51Aea7C9138F235D60A96B392170f8c`](https://testnet.bscscan.com/address/0x5A37E9f7e51Aea7C9138F235D60A96B392170f8c) |
| GangRouter（2.0，代理：pad 列入、用户授权的地址） | [`0xb21828C49A526FA293C48990070a518e9ab9FC08`](https://testnet.bscscan.com/address/0xb21828C49A526FA293C48990070a518e9ab9FC08) |
| GangRouter 实现 / ProxyAdmin / Timelock | `0x2c038b514d6Ec106f052eDbb4F14EED26A251b97` / `0xABc3A821AcF5954fE821e35915800D0375F13a28` / `0x064569Ad6E6E3e291892F90F9175C0F319cADCEd` |
| CurveLogic（新部署，含 creator 分成） | `0x45c0517f961CCc89f6C2eA2FE43F79bDe0c0f049` |
| FairLogic | `0xbC3f4AB987C79D1B64c19D6b02eE34D1Bcd1BB73` |
| 共享（1.0 的）：QuoteRegistry / bucket / vault / migrator / TokenDeployer | `0xD56f…A35B` / `0x5338…C1aF` / `0xF692…1d69` / `0xaE31…2e20` / `0xF9E2…CDF6` |
| GangPadRegistry（已 `addPad(2.0)`） | `0xB11B…e56e` |
| GangGateway（已列入 2.0） | `0xb325…e091` |

部署记录：`broadcast/DeployGangLaunchpad2.s.sol/97/`（24 笔，合计 gas 17,828,329，全部成功）。

### 部署

```
GANG_PAD=0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1 GANG_GATEWAY=0xb325dde51129C592E443ecbEE1E219D14C66e091 \
  forge script script/DeployGangLaunchpad2.s.sol --rpc-url $BSC_TESTNET_RPC_URL --broadcast --legacy --with-gas-price 100000000 --slow
```

KEEPER 不设（默认部署钱包，等于共享 bucket 的 keeper）；路由 timelock 用默认 48 小时；TWAP 窗口沿用 1.0 的 1800 秒。一次运行完成：部署 CurveLogic / FairLogic / handler / pad / Router，handler `setLaunchpad` / `setKeeper` / 列入演示 treasury，pad 列入 Router 和 Gateway、Agent gate、V3 factory，共享合约 9 项登记，最后 `setMigrator` 开放，自检 `self-check ok`。

之后用 `GANG_PAD2` / `GANG_ROUTER2` / `GANG_PAD2_BLOCK` 只读重跑阶段 2：`self-check ok`。

### 验收

### 2.0 creator 分成（`script/GangLaunchpad2TestnetAcceptance.s.sol`）

| 步骤 | 结果 | 交易 |
|---|---|---|
| 建 WBNB 曲线币 A（无税） | [`0x8FE3…6a1a`](https://testnet.bscscan.com/address/0x8FE35F1256151F722b7055339eA4e3D237586a1a) | [`0x9ad1709b…f1dc`](https://testnet.bscscan.com/tx/0x9ad1709ba100c9921bc0cc2cf859bf5e52b6f90e00dc90975857398f6688f1dc) |
| 经 2.0 Router 用 0.002 BNB 买入 | creator 记 0.000014（1% 的 70%），bucket 记 0.000006 | [`0x4b364c9f…c9b4`](https://testnet.bscscan.com/tx/0x4b364c9f2944840b0be7ab8da74d39b3a86292347b389dd55e4a394c8a68c9b4) |
| 在 pad 上直接卖出一半 | 卖出手续费的 70% 也记给 creator，累计 20,931,371,868,369 wei | [`0x585b3fb0…91a0`](https://testnet.bscscan.com/tx/0x585b3fb03707930504486a7cac0d24512046a55d4fb121eae08116c68d0691a0) |
| creator 领取 | 收到 20,931,371,868,369 wei WBNB，`creatorFeeOf` 归零 | [`0x44ca2ff0…13e6`](https://testnet.bscscan.com/tx/0x44ca2ff0f3a6dde39089f3b7c414eaec56bb6b03d2f59c439157bf85e8f713e6) |
| 建测试报价币曲线币 B（买卖税 3%、分红 40%、接收地址 = creator 自己） | [`0x145d…e535`](https://testnet.bscscan.com/address/0x145d534015199Ce7b980FC597F7fC084E6cde535) | [`0x3d8ac214…a7bf`](https://testnet.bscscan.com/tx/0x3d8ac2140812b05c8583bcdca09506daf729bad99754e571cc3910fbe8aea7bf) |
| 临时关闭钱包上限，一笔买 16 枚到毕业，再打开上限 | 经线上 migrator 毕业，交易对 `0xD13e…B4D2`；creator 记 0.10606…（约 15 枚的 0.7%） | 关 [`0x34a739de…d09d`](https://testnet.bscscan.com/tx/0x34a739de721ae2aebd9c71d9c113de9c622774703f62675cef612b770c909d0d)，买 [`0xe6db199f…ee66`](https://testnet.bscscan.com/tx/0xe6db199f967bfed60ac2fa1c2487791af800143098ff6bbb862c40a7be93ee66)，开 [`0x9c0513b7…a5b1`](https://testnet.bscscan.com/tx/0x9c0513b7ed86beb279e2257f9834b4449467a6d742bb1e26f32ab469fca6a5b1) |
| 毕业后领取 | 收到全部分成；pad 剩 1 wei 测试报价币 | [`0x143a08f2…7217`](https://testnet.bscscan.com/tx/0x143a08f224cfceb2fdd8e3c78178e24a3e4c2b6c4c3a88b1678059f32d1f7217) |

### Gateway（`script/GatewayTestnetAcceptance.s.sol`，`GANG_PAD` 指向 2.0）

聚合器式适配器经 Gateway 买 0.002 BNB、带 1% 路由费卖一半，钱包直接经 Gateway 卖剩下一半，全部成功（建币 [`0x0cb57d80…dc9`](https://testnet.bscscan.com/tx/0x0cb57d80b3e906502f9f1012354a199aae75458ab22e62b99ce959a0f434edc9)，买 [`0xa3e0e266…8bd1`](https://testnet.bscscan.com/tx/0xa3e0e266cca79b2e430094fad206e1d0cd83deb8cf4b566f9ea30bdbe3a28bd1)，卖 [`0xdd08eb46…4982`](https://testnet.bscscan.com/tx/0xdd08eb46833abca7690a4d377605f72884c6ed63fc364ab60d0d9715fb854982) / [`0x1b221eac…20f2`](https://testnet.bscscan.com/tx/0x1b221eac72e23cd1c3dc4f2d3545cf98ccbf4d9367b6595f8436dda350e520f2)）。三笔交易给这个币的 creator 记了 27,859,999,999,998 wei。registry `padOf(该币)` 返回 2.0。

### 链上复核（验收脚本的检查跑在模拟里，这里直接读链）

- A、B 的 `creatorFeeOf` 为 0，Gateway 币为 27,859,999,999,998；钱包上限已打开；`CREATOR_FEE_SHARE_BPS = 7000`；migrator = 共享 migrator。
- 2.0 的 WBNB 余额 1,017,664,018,804,275 = A 的 `realQuote` 989,804,018,804,277 + Gateway 币的 creator 分成 27,859,999,999,998，零头 0。

### 模块

现有脚本，`GANG_PAD` 指向 2.0，`HANDLER_ADMIN` 为新 admin；测试网上部署钱包拥有 handler 和 admin，脚本直接执行接线。合约代码和 1.0 上用的完全相同。

| 合约 | 地址 | 交易 |
|---|---|---|
| GangHandlerAdmin（2.0 handler 的 owner；admin 的 owner = 部署钱包） | [`0xC4EEca9623726519Ccc9616D88be5a897E584918`](https://testnet.bscscan.com/address/0xC4EEca9623726519Ccc9616D88be5a897E584918) | 部署 [`0xd26b1371…af3b`](https://testnet.bscscan.com/tx/0xd26b137102f0abfdfb1c72e52f1a3dc624113a995b0ca374cc84577701a9af3b)，handler 转交 [`0xfa7ad9ba…6761`](https://testnet.bscscan.com/tx/0xfa7ad9ba75567099e01c38028cb85469f834a9f2ab6207ff8c54ab9bc7bf6761)，接受 [`0x70d3e043…0f72`](https://testnet.bscscan.com/tx/0x70d3e043551138faab6fca2d61f9bb7874129e70e0b94d0496cc3c19872b0f72) |
| GangBuybackSplitterFactory（克隆 `buyback-burn-v4`） | [`0xBc26A6585B3Dc2Cbf1522475fB5b18df6C1033AE`](https://testnet.bscscan.com/address/0xBc26A6585B3Dc2Cbf1522475fB5b18df6C1033AE) | 部署 [`0x6d233a72…0878`](https://testnet.bscscan.com/tx/0x6d233a7213edcff9d5c6afb93dfd3529d6c9f2c4a772183b99c39485b58e0878)，`setFactory` [`0x8cbf0118…f1bd`](https://testnet.bscscan.com/tx/0x8cbf0118bed9ea7f70e5fcd4de7e465896ae2ac8e06557f5f7ba0d5c434df1bd) |
| GangSplitModuleFactory | [`0x860D51808E9FBB4f887FC7d0Aa9e1F8E19E00879`](https://testnet.bscscan.com/address/0x860D51808E9FBB4f887FC7d0Aa9e1F8E19E00879) | 部署 [`0xc1f385b7…f720`](https://testnet.bscscan.com/tx/0xc1f385b7d44168416df8076b31f53ceaef920da05b1a866b39b48d8749ebf720)，`setFactory` [`0xf302ae7b…a573`](https://testnet.bscscan.com/tx/0xf302ae7b1a51ae0f5b9bf4f71e30cad78f129484267c55495b8d8056e507a573) |
| GangLiquiditySplitterFactory | [`0x4f1544e4e8853fC62088f0A4eCbEF409D2e11619`](https://testnet.bscscan.com/address/0x4f1544e4e8853fC62088f0A4eCbEF409D2e11619) | 部署 [`0x976002fd…c007`](https://testnet.bscscan.com/tx/0x976002fde4292256a0b71face394ffb66b0d9ab83cdce37310c9ab545687c007)，`setFactory` [`0x1d0f0de8…5dbb`](https://testnet.bscscan.com/tx/0x1d0f0de89d4a320dd38d8f384469a7f40472b5c728483fef49067e8c3e245dbb) |
| GangBond | [`0x913966122b9f8CC00C0d81000988A483c6B7F97f`](https://testnet.bscscan.com/address/0x913966122b9f8CC00C0d81000988A483c6B7F97f) | [`0xbb01b1a4…77b9`](https://testnet.bscscan.com/tx/0xbb01b1a451bb6c989a4c429443bc30803e503267c6350113c7964e8e222577b9) |

链上核对：handler 的 owner = admin，`admin.handler()` = 2.0 handler；三个 factory 的 `pad()` 都是 2.0，`admin.isFactory` 都为真；`GangBond.pad()` = 2.0。模块各自的端到端验收（克隆、收税、分账）留到 CLI 接入 2.0 后在测试网上跑。部署记录：上面四个脚本 `broadcast/<脚本>/97/` 下本次新增的带时间戳文件（这几个目录的 `run-latest.json` 仍是 1.0 那次的，没有改）。

### 还没做（写于第一版部署时）

- 模块的端到端验收（见上）。
- 后端（indexer / keeper）、网站、CLI 接入 2.0。
- 切换（1.0 停止创建）：等以上完成后，部署钱包调用 `TokenDeployer.setLaunchpad(1.0, false)`。
