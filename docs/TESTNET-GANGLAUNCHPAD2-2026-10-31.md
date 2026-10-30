# 测试网 · GangLaunchpad 2.0（内盘 creator 分成）

- 日期：2026-10-31 Asia/Shanghai
- 网络：BSC 测试网（97），和第 10 套 GangLaunchpad（1.0，`0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1`）并列，共用它的共享合约
- 规格：`docs/SPEC-CURVE-CREATOR-FEE-2026-10-31.md`
- 部署前的流程：合约两轮独立审计 → 修复 → 复审；部署脚本独立审查 → 修复 → 两轮复审；本地 anvil（fork 测试网）彩排两次；主网 fork 测试 `test/fork/GangLaunchpad2DeployFork.t.sol` 通过
- 部署钱包：`0xCa8e…00b6`（测试网上它拥有全部共享合约，阶段 1 直接完成登记并开放）

## 地址

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

## 部署

```
GANG_PAD=0xFebF58ba418ab4a3B3f054827eb11E99369C5BB1 GANG_GATEWAY=0xb325dde51129C592E443ecbEE1E219D14C66e091 \
  forge script script/DeployGangLaunchpad2.s.sol --rpc-url $BSC_TESTNET_RPC_URL --broadcast --legacy --with-gas-price 100000000 --slow
```

KEEPER 不设（默认部署钱包，等于共享 bucket 的 keeper）；路由 timelock 用默认 48 小时；TWAP 窗口沿用 1.0 的 1800 秒。一次运行完成：部署 CurveLogic / FairLogic / handler / pad / Router，handler `setLaunchpad` / `setKeeper` / 列入演示 treasury，pad 列入 Router 和 Gateway、Agent gate、V3 factory，共享合约 9 项登记，最后 `setMigrator` 开放，自检 `self-check ok`。

之后用 `GANG_PAD2` / `GANG_ROUTER2` / `GANG_PAD2_BLOCK` 只读重跑阶段 2：`self-check ok`。

## 验收

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

## 还没做

- 模块：为 2.0 部署 GangHandlerAdmin 和 Buyback / Split / LP 三个 factory、GangBond（现有脚本，`GANG_PAD` 指向 2.0）。
- 后端（indexer / keeper）、网站、CLI 接入 2.0。
- 切换（1.0 停止创建）：等以上完成后，部署钱包调用 `TokenDeployer.setLaunchpad(1.0, false)`。
