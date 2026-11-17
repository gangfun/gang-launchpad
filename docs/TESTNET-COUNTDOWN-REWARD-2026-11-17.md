# 测试网记录 · GangCountdownReward（倒计时奖励，`countdown-v1`）

- 日期：2026-11-17 Asia/Shanghai
- 网络：BSC 测试网（97），GangLaunchpad 3.0 代理 `0x0508232833aE6849c03b28F7aA248BBd5cFCceE2`，3.0 的 GangHandlerAdmin `0x0fb8280B88a4DF00e8654cfE9cBd544D104a9D23`
- 规格：`docs/SPEC-COUNTDOWN-REWARD-2026-11-17.md`
- 部署前：一轮内部独立审计（没有 Critical / High / Medium，Low 已全部处理）和对修复的独立复审；之后加了「每轮最长时长」`maxRound`，也经过独立复审（一个 Medium 级设计问题：到上限结束的轮次，结束时刻可预测。处理办法是这种轮次平分）。没有外部审计
- 结论：两个版本的工厂各自跑完一整轮合约验收，全部通过。金额和合约规则逐 wei 一致，每一步之后账目都被余额覆盖
- 没做：CLI、keeper、服务端、网站都还没对接，本次只验收合约。`finalize` 和到 `maxRound` 上限结束的轮次只有单元测试，没有在测试网上跑（前者要等 7 天，后者要等 6 小时）

## 部署

| 项 | 地址 / 交易 |
|---|---|
| GangCountdownRewardFactory（当前版本，带 `maxRound`） | [`0x0f83ABC7d39C0d043d3f5612E304D9395B5fe582`](https://testnet.bscscan.com/address/0x0f83ABC7d39C0d043d3f5612E304D9395B5fe582)，区块 143183058，部署 [`0x4d62d242…8890`](https://testnet.bscscan.com/tx/0x4d62d2425c40380c6298106735bc10f9e803c4ad477137e971f9e2138d958890) |
| 实现合约 | [`0xed491948cfa53fBE514E0FBa0EE335234738D9De`](https://testnet.bscscan.com/address/0xed491948cfa53fBE514E0FBa0EE335234738D9De)，`gangQuote` = 0（测试网没有 GANG） |
| `admin.setFactory(factory, true)` | 区块 143183063，[`0x2c602a1c…0240`](https://testnet.bscscan.com/tx/0x2c602a1ce5a2d13e63265bfcf595d849346a7bfd438693a1837ccb9960690240)。测试网由 owner 钱包直接执行，主网是多签 |
| 上一个版本的工厂（没有 `maxRound`，已被取代） | [`0x2Be971808c18901AdAB7a3bC2F643eC38CB2aCdE`](https://testnet.bscscan.com/address/0x2Be971808c18901AdAB7a3bC2F643eC38CB2aCdE)，实现 `0x8d4Edee865BDEa2358DC309e946BDE547347A06b`，区块 143179461。测试网上仍是放行状态，主网只会部署当前版本 |
| 部署脚本检查 | 接线检查和运行时字节码比对在模拟阶段通过；部署后 `isFactory` = true |

记录：`broadcast/DeployGangCountdownRewardFactory.s.sol/97/`。

## 验收（`script/CountdownTestnetAcceptance.s.sol`，当前版本用 `CD_RUN=2`）

dev = 部署钱包。报价币 MockSPCXB `0x02B3…F1c`（QuoteRegistry 里有，`keeperServes` = true）。币的买卖税 3%，分红 20%。模块设置：倒计时 30 分钟，每轮最长 6 小时，每轮发 30%，最后一笔多拿 20%，3 个名额，dev 拿税的 25%，最低买入 0.01，最低奖励池 0.05，每轮上限 1。

毕业用的一次性钱包和买家 B 都沿用封顶模块和底价赎回模块验收时的那一批（同一个派生标签），没有新钱包。

| 步骤 | 结果 | 交易 |
|---|---|---|
| 发币前算出代币地址，为它克隆模块 | 模块 [`0x98A79dB361466993ef3b415462987dc400f84D24`](https://testnet.bscscan.com/address/0x98A79dB361466993ef3b415462987dc400f84D24) 等于 `predict`；`rewardToken` 是预先算出的地址，`token()` 为 0；设置写入正确 | [`0x3b4ff49d…affb`](https://testnet.bscscan.com/tx/0x3b4ff49db3878ac6506b15c06ed6cbb786adae75af5b0a32840d1279b9f8affb) |
| `createWithSalt` 建币 CDR2（收款 = 模块） | [`0xBC6E981950D6831FBED51eA433b955398D93AbCD`](https://testnet.bscscan.com/address/0xBC6E981950D6831FBED51eA433b955398D93AbCD)，和预先算出的地址一致 | [`0x1467a3aa…522e`](https://testnet.bscscan.com/tx/0x1467a3aa051e40be035a8711b99ab223cae3c56ea4584d8de92809b4294c522e) |
| `bind` | `token` / `quote` 写入 | [`0xaaf175e5…878f`](https://testnet.bscscan.com/tx/0xaaf175e5b96cd2e3d6444464b97d869f34a779f70d3fd0350c9d62c2f8f1878f) |
| `fund` 种子钱 0.2 | 全部进奖励池，dev 不拿 | [`0xa80d4ad0…0a4d`](https://testnet.bscscan.com/tx/0xa80d4ad0808bb918e0a5d8fe2b764b993e858e67eb7ebcb1a995878445940a4d) |
| 毕业、池子卖出交税 | 一次性 Agent 买到毕业；部署钱包在池子里一买两卖，卖出时的 swap-back 付给模块 0.006165992723413878 | 区块 143183354–143184724 |
| `settle()` 记账 | dev 记 25%，其余进奖励池，和 `potAvailable` 的预测一致 | [`0x2f4e339b…b741`](https://testnet.bscscan.com/tx/0x2f4e339b5368b6535e5c67cd8cc23441c26d9f0ffd323dc483d95649226ab741) |
| 通过模块买入 3 笔（`buyWithQuote`，`mustCount` = true，真实的 Pancake 交易对）：部署钱包、B、部署钱包 | 每笔买家收到代币（扣过买入税），模块余额不变（买入的钱一分都没留在模块），截止时间 = 当时 + 30 分钟；第 1 轮 3 个名额。gas 31.3 万 / 35.0 万 / 27.2 万 | [`0x57d24640…357b`](https://testnet.bscscan.com/tx/0x57d246403c02929205ca87f13f7efa596a2aaf8020616abb5ef7a3848949357b)、[`0x8d9f40b8…6777`](https://testnet.bscscan.com/tx/0x8d9f40b822bbfd42def923abda1099ced5e19ece470784b872655915877e6777)、[`0xe3fe85d8…eba8`](https://testnet.bscscan.com/tx/0xe3fe85d81fac22e3ef42a31b4abd98fbef370d7dc50cafa3f6f5ce29eb32bea8) |
| 读回 | `roundEndsBy` = 第一笔 + 6 小时 | 无 |
| 截止后 `work(0)`（`--sig "finish()"`） | 冻结并结算：本轮发 0.062226570538308009（奖励池的 30%），每格 0.016593752143548802，最后一笔多拿 0.012445314107661601。部署钱包（两格加额外）、B（一格）逐 wei 一致；零头回奖励池；`reservedTotal` = 0 | [`0x8cc4e76f…a5c`](https://testnet.bscscan.com/tx/0x8cc4e76f498a67f8ae67e798cb104cdad3cb11f04c229d076b932bf9359b3a5c) |
| 领取 | 部署钱包 `claim` 和 `claimDev`、B `claim`，到账逐 wei 一致；`claimTotal` = `devOwed` = 0 | [`0x1dbd34da…776b`](https://testnet.bscscan.com/tx/0x1dbd34dae5dc7ae275c464412112fcc469c1660f241dd03362ba5c540124776b)、[`0x36203b27…d644`](https://testnet.bscscan.com/tx/0x36203b27398f7b3601bc07467114372959f6be907b094ac5251fa3ecd81cd644)、[`0x5e8ab0dd…0427`](https://testnet.bscscan.com/tx/0x5e8ab0dd0b6f5e262b4e085995141c59c74284e4534bfc802038d376d7e70427) |
| 第 2 轮 | 下一笔计入买入开启第 2 轮 | [`0xf845bb57…ec33`](https://testnet.bscscan.com/tx/0xf845bb5772ab1e86e553976b6d9f191859a312d937ce2c781532af674e26ec33) |
| 收回一次性钱包剩下的 gas | 0.0063007252 tBNB 回到部署钱包 | `--sig "sweep()"` |

上一个版本的工厂也跑完了同样一整轮（模块 [`0x54c7…CBBf`](https://testnet.bscscan.com/address/0x54c7453749C4C1113ee8564f73FB317d0034CBBf)，代币 CDRT [`0x1734…aBCD`](https://testnet.bscscan.com/address/0x173402A811885f71057421Dd05B54c31Aa8faBCD)，结算 [`0x3367abac…e67c`](https://testnet.bscscan.com/tx/0x3367abacc20ea4bcc2c8da2898d6d771f514a71391eef296a3e1a0a46151e67c)），金额完全相同。

记录：`broadcast/CountdownTestnetAcceptance.s.sol/97/`。

## gas

| 操作 | gas |
|---|---|
| 克隆模块 | 约 45 万 |
| 计入的买入（`buyWithQuote`） | 27 万 – 35 万（第一笔开轮最贵） |
| `work` 结算 3 个名额 | 约 15.5 万 |
| `claim` / `claimDev` | 约 5 万 |
| `receiveCarry`（单元测试） | 约 12.3 万，冲毕业奖励那边的上限是 30 万 |

## 下一步（还没做）

- CLI：发币参数 `--countdown-reward …`，`gang buy` 对开了这个玩法的币走模块入口（默认 `mustCount`），`gang reward status / claim / settle`。
- keeper：新类型 `countdown-v1`，截止后调 `settle`，空闲到期后调 `finalize`。
- 服务端和网站：索引事件，代币页显示倒计时、奖励池和名单，买入按钮走模块入口。
- 主网：部署工厂和多签 `setFactory`，需要你明确同意。
