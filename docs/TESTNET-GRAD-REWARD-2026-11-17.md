# 测试网记录 · 冲毕业奖励（内盘）

- 日期：2026-11-17 Asia/Shanghai
- 网络：BSC 测试网（97），GangLaunchpad 3.0 代理 `0x0508232833aE6849c03b28F7aA248BBd5cFCceE2`（abcd、底仓金库都已开启）
- 规格：`docs/SPEC-GRAD-REWARD-2026-11-17.md`（§13 是定下的决策和实现）
- 部署前做过的审查：一轮独立审查，每轮修复后都有独立复审（EIP-170 拆分、撤回过期、部署脚本代码校验、carry 的 gas 护栏、按花费分配）。最后一轮复审没有发现低危及以上的问题。没有外部审计
- 结论：升级和开启都已在测试网上执行，毕业前的规则在链上验收通过。毕业、领取和回收在测试网上做不了（见「没做」），由主网 fork 测试覆盖，结果通过

## 部署

用 `script/UpgradeGangLaunchpad3.s.sol` 升级，环境变量和 `docs/TESTNET-GANG-LAUNCHPAD-3-2026-11-03.md` 的升级演练相同，另加三项：
- `PAD3_GRAD_REWARD=true`；
- `PAD3_GRAD_HANDLER_ADMIN=0x0fb8280B88a4DF00e8654cfE9cBd544D104a9D23`（3.0 的 GangHandlerAdmin）；
- `PAD3_BASE_PROBES=0x275Cb24972Ce867C42787fB8B478CA7D32a7Abcd`。

倒计时奖励还没上线，所以 `PAD3_GRAD_COUNTDOWN_FACTORY` 不设，为 0。只链接测试网的 PoolCheck `0x76Ba…C00c`。没改动的库（FairLogic、LegacyRoute、飞轮的两个库），forge 直接复用了已部署的那份。

| 项 | 地址 / 交易 |
|---|---|
| CurveLogic3 | [`0xf8618e23b7cc4324bc23d013b37d75764a59b600`](https://testnet.bscscan.com/address/0xf8618e23b7cc4324bc23d013b37d75764a59b600) |
| Pad3FlyModule（代码不变，构建脚本连带部署） | [`0xecb384115f2bd6017421a85c982def10b5d82313`](https://testnet.bscscan.com/address/0xecb384115f2bd6017421a85c982def10b5d82313) |
| Pad3GradModule | [`0x94ca066492fe33ceb1f31c15aa4c2d74b3307f40`](https://testnet.bscscan.com/address/0x94ca066492fe33ceb1f31c15aa4c2d74b3307f40) |
| Pad3Module | [`0x7d8ee961eea1833fd12ea8ba6af6d9c8ea131648`](https://testnet.bscscan.com/address/0x7d8ee961eea1833fd12ea8ba6af6d9c8ea131648) |
| GangLaunchpad3 新实现 | [`0xebaa0f6b4d21834d8cc703e0dbef787a5b4418fc`](https://testnet.bscscan.com/address/0xebaa0f6b4d21834d8cc703e0dbef787a5b4418fc) |
| `upgradeAndCall` | 区块 143199548，[`0x5af1eeee…3a20`](https://testnet.bscscan.com/tx/0x5af1eeeea6f76c977e24e4da39caacf3a6652b752babc88ed13829037fcc3a20) |
| `setGradReward(true, admin, 0)` | 区块 143199553，[`0xedf6ad94…1fb9`](https://testnet.bscscan.com/tx/0xedf6ad94c3d59052bf201be14d9ea1304e90e53b6af71152f922e1059c931fb9) |

- 广播前的模拟：比对了最新 25 个币的记录和设置；以 ProxyAdmin owner 身份执行了升级和 `setGradReward`；阶段 2 读回通过。
- 7 笔交易全部成功。
- 读回：实现槽 = 新实现；`module().gradModule()` = 上面的 Pad3GradModule；`gradRewardDeps()` = (true, admin, 0)；`vanityDeployer`、`baseVaultImpl` 没变。
- 记录：`broadcast/UpgradeGangLaunchpad3.s.sol/97/run-1794893042733.json`。

## 验收（`script/GradRewardTestnetAcceptance.s.sol`）

- dev = 部署钱包（Agent）。
- 报价币是测试网已上架的 MockSPCXB `0x02B3…CF1c`：6 BNB 档对应 6 个，部署钱包有余额。
- 参数：种子钱 0.05，`minBuy` 0.003，名单 5 格，`lastBps` 30%，`refundAfter` 30 天，不带税，不开倒计时。

| 步骤 | 结果 | 交易 |
|---|---|---|
| 经 `createWithSalt` 调 `createWithGradReward` | 代币 [`0x42847132b3B49D5F83871A8AD04B85B57620ABCD`](https://testnet.bscscan.com/address/0x42847132b3B49D5F83871A8AD04B85B57620ABCD)，和事先算出的地址一致；种子钱从 dev 拉到 pad，金额正好 0.05；条款读回一致；gas 1,545,751 | [`0xd98ce7c7…fd15`](https://testnet.bscscan.com/tx/0xd98ce7c7d1ca22819a408b1d9479a43aa7e4fb8558a6d0e1275d743170eafd15) |
| 买 0.001（低于 `minBuy`） | 不计入 | [`0xe4859edb…c7b6`](https://testnet.bscscan.com/tx/0xe4859edb81c002d7ed7c121da2c88c7d1d638bd3196e312cfabebef96476c7b6) |
| 买 0.004 两次 | 计入，seq 1、2 | [`0xed489ae4…ac8`](https://testnet.bscscan.com/tx/0xed489ae420793020a91136308901667422ac27bc83bd5d776cfeb28bfb746ac8)、[`0x3997c50f…7d75`](https://testnet.bscscan.com/tx/0x3997c50fda4da641e8d691843fb0ecf02467a7c8bd48518c1367fc092a797d75) |
| 卖出四分之一 | seq 1、2 失效 | [`0x2eb81a5d…6c85`](https://testnet.bscscan.com/tx/0x2eb81a5d632f91069165d679c8f39e9bac4c303d9a2d9209d5dad2b97c3f6c85) |
| 再买 0.004 | 计入，seq 3 有效 | [`0x8b1b8d3f…beb5`](https://testnet.bscscan.com/tx/0x8b1b8d3f0d377d602ec93213208aa29d350bd2ae082788fe58ad659fbf75beb5) |
| 读回 `gradEntries` | 3 格都是 dev，seq [3, 2, 1]，花费都是 0.004，有效 [true, false, false]；`gradClaimable` = 0 | 无 |
| 毕业前申请撤回、毕业前领取（只模拟，不广播） | 分别回滚 `RefundNotDue` 和 `NotGradState` | 无 |

- 一共 9 笔交易，全部成功。
- 普通买入在多出的那次冷读之后，gas 约 18.3 万到 21.2 万。
- 记录：`broadcast/GradRewardTestnetAcceptance.s.sol/97/`。

## 升级后的回归

- 重跑 `script/Pad3VanityTestnetAcceptance.s.sol`：39 笔交易全部成功。7 个创建入口都通过 `createWithSalt` 建币，地址以 abcd 结尾；升级前的老币 `0x1695…85f7` 也完成了买卖。记录：`broadcast/Pad3VanityTestnetAcceptance.s.sol/97/run-1794893349799.json`。
- `script/GangLaunchpad3TestnetAcceptance.s.sol` 直接用 `create` 建币，abcd 开启后会回滚 `VanityContextRequired`。这次没跑它；abcd 开启后，一直用上面那份脚本代替。

## 主网 fork（`test/fork/Pad3GradRewardFork.t.sol`）

主网区块 134069591，公共归档节点：
1. 带 `PAD3_GRAD_REWARD` 运行升级脚本。检查和模拟都通过：handler admin 是本次构建的代码、owner 是 Safe、它持有 handler。
2. 带 `PAD3_IMPL` 只读重跑，取出脚本打印给 Safe 签名的批次。批次一共两笔：升级，然后 `setGradReward(true, 0xC833…Af76, 0)`。
3. 以 Safe 身份按批次执行：升级只写了实现槽，开启只写了命名空间的前两个字。
4. 开启之后再带 `PAD3_GRAD_REWARD` 跑升级脚本，被拒绝：`grad reward already set`。
5. 经 `createWithSalt` 建一个奖励币（WBNB，6 BNB 档，种子钱 0.5，名单 10 格）。
6. 在 1% 上限下用 80 多个模拟 Agent 钱包买到毕业，迁移到真实的 Pancake V2 交易对。期间名单末尾有一个买家卖出一部分。
7. 读回：有效 9 格，卖出的那位为 0。其余人逐个领取，到账等于 `gradClaimable`。总额不超过奖励池，只剩取整零头；毕业那笔拿到了 `lastBps` 的额外部分。
8. 180 天后回收，零头退给 dev，状态变为关闭。

Agent 身份只在 fork 里模拟，没有往主网广播任何交易。结果：1 / 1 通过。

升级脚本里这一步的规则（审查后加的）：
- 只能开一次：命名空间已有内容时拒绝；
- admin 必须持有 handler；
- 本次构建里还没有倒计时工厂的源码，可以拿来比对，所以 `PAD3_GRAD_COUNTDOWN_FACTORY` 必须为 0。carry 等倒计时工厂进了仓库，再单独走一个批次开启。
- 这些规则是测试网执行之后才加的，只在主网 fork 上跑过。测试网的状态都满足这些规则：handler 的 owner 就是这个 admin，没有待接收的 owner。
- 运维：紧急关闭时用 `setGradReward(false, <admin>, <factory>)`，不要把两个地址清零，脚本靠这两个值判断「已经设置过」，清零后它就判断不出来了。

## 没做

- **测试网上的毕业、领取和回收**：测试网开着 1% 钱包上限，要毕业需要大约 80 个不同的 Agent 钱包。这部分由上面的主网 fork 覆盖。
- **carry 转给倒计时模块**：倒计时奖励还没上线，这部分只有单元测试，用的是模拟模块。
- CLI、服务端、网站都还没有对接。

## 花费

部署钱包 tBNB 从 0.0837 降到 0.0711，全部是 gas；MockSPCXB 用了约 0.06（种子钱留在 pad 上）。
