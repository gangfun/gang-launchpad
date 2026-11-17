# 规格草稿 · 冲毕业奖励（内盘）

- 日期：2026-11-17 起草；同日第 2 版按独立审查意见修改，第 3 版按复审意见修补，第 4 版定稿并开始实现（§12、§13）
- 状态：**v1 已实现，测试网已上线，CLI 0.42.0 已完成**；没有外部审计，主网未升级
- 姊妹规格：`SPEC-COUNTDOWN-REWARD-2026-11-17.md`（倒计时奖励，外盘）。两个玩法互相独立，dev 发币时各自选
- 口径：dev 拿出自己的钱（种子钱，可选再加上 creator fee 的一部分），奖励把币推过毕业线的买家。用户本来就是来买币的，只付正常的价格和手续费

## 1. 做什么

GangLaunchpad 3.0 曲线币的一个可选玩法，要升级 3.0 pad 才能做。

- 曲线阶段，pad 记下**最后 N 笔**计入的买入（§3）。
- 币毕业时，奖励池按 §4 分给这些买入的买家。
- 两个玩法都开时，奖励池里约定的比例在毕业时转进这个币的倒计时奖励模块，作为它的起步资金。

现在的瓶颈是币毕业不了，这个玩法让买家有动力把币推过毕业线。毕业也是 dev 开始拿税收入的前提。

## 2. 奖励池的钱从哪来

| 来源 | 说明 |
|---|---|
| 种子钱 | 主要来源。dev 建币时一起付，用这个币的报价币，用 ERC-20 `pullExact` 拉取。WBNB 计价的币由 CLI 走现有的 wrap / approve 步骤，**不用 `msg.value`**（所有建币入口都不是 payable，包括 `createWithSalt`） |
| creator fee 的一部分（v1 建议不做） | `(creatorFee − 推广分成) × feeCutBps`。买和卖都会切（`_syncShareAndFee`，`CurveLogic3.sol:306-325`）。这样切永远不会超过 creator fee 的 100%，也不用跨入口校验 |

量级：曲线上一个币一共成交 6～20 BNB，creator fee 是成交额的 0.7%，全部切进来也只有 0.04～0.14 BNB。而切 creator fee 要改 `_syncShareAndFee`，还要改索引器算 dev 收入的口径（`TradeV1.creatorFee` 是毛额，`CreatorFeeAccrued` 是净额）。**所以 v1 建议只用种子钱，不切 creator fee**（决策 §11-2）。

平台的 0.3% 不受影响。

## 3. 哪些买入算数

- 所有曲线买入最后都走 `CurveLogic3.buy → _execBuy`，`_graduate` 也只从这里进，挂在这里不会漏。
- 名单记的是 `CurveLogic3.buy` 的 `trader` 参数，也就是收币地址：
  - 路由 `v3Buy` / `v3BuyBNB` 走 `buyFor`，`trader == tx.origin`（`GangLaunchpad3.sol:1019-1022`）；
  - `buyTokenAMAP` 要求 `to == tx.origin`（795）；
  - `buyWithPromoter` 要求 `msg.sender == tx.origin`（`Pad3Module.sol:345`）；
  - 直接 `buy` 用 `msg.sender`。
- Agent ID 是灵魂绑定的，不能转（`docs/SPEC-FAIR-MINT-2026-10-26.md:148`），所以借 ID 刷名额不成立。1% 钱包上限照旧。
- 前提：Agent 门槛是开着的。如果 owner 关掉门槛，直接 `buy` 用的是 `msg.sender`，合约钱包可以随意刷名额，所以**门槛关闭时不计入**。
- 计入条件：**实际花掉的** `quoteIn − refundGross ≥ minBuy`。被钱包上限截断、只成交了一点点的买入不算。毕业那一笔例外，一律计入。
- 名单是 ERC-7201 命名空间 `gang.pad3.gradreward` 里的环形数组，每格打包 `address + uint96 实际花费`（第 4 版改，原为代币数量），每笔买入大约 1 次 SSTORE。不按钱包去重，原因和倒计时奖励一样。
- 每笔买入多花的 gas 要实测。

## 4. 毕业时怎么分

**资格**：曲线阶段代币不能转账，但可以卖回曲线。

- 用**顺序**判断，不用「卖过没有」：每笔计入买入全局计数 `seq++`（第 i 格的序号可以从总计数和位置推出来，不用多存）；曲线卖出时写 `sellSeqOf[token][wallet] = 当前 seq`。某一格有效的条件是 `这一格的 seq > sellSeqOf[wallet]`。这样早先卖过、后来又买进最后 N 笔的钱包不会被误杀，「买入 → 卖出 → 再买入」的后一笔也照样有效。
- 毕业后曲线就关了（`_live` 会 revert），三条卖出路径 `sell`、`sellFor`、`sellToken` 都走 `CurveLogic.sell`，所以毕业时资格就定死了。
- 毕业时不逐个读 `balanceOf`。
- vault 币（`vaultLock` / `vaultRelease` 会改变余额）**v1 不开这个玩法**，见审查 B-1。

**毕业那一笔里只做最少的事**：
- 冻结名单，写下奖励池总额；
- 算出 `carry`：pad `approve` 给倒计时奖励模块，然后在 try 里调 `module.receiveCarry(amount)`。不能用普通转账，否则会被当成税按 `devBps` 分。失败就把授权清回 0、记成欠款，之后谁都能 `retryCarry`，**不能让毕业回滚**。
- 撤回已申请（公示期内）或已撤回时，`_graduate` 要正确处理：公示期内毕业，撤回作废、照常发放；已撤回，跳过发放和 carry。

**领取时再算份额**（惰性）：

```
pot   = 种子钱（+ 切出的 creator fee，如果做的话）
carry = pot × carryBps ÷ 10000                 （只在两个玩法都开时 > 0）
pay   = pot − carry
合格的笔数 = 名单里没有被取消资格的
毕业那一笔        拿 pay × lastBps ÷ 10000（门槛开着时，按顺序语义它不可能被取消资格）
所有合格的笔（含毕业那一笔）按各自实际花掉的金额分剩下的部分（第 4 版改，原为平分）
没有一笔合格      pay 全部并进 carry；没开倒计时奖励就退给 dev（只有门槛关闭过才可能出现）
毕业那一笔不计入  （门槛关闭期间毕业时）lastBps 那份给名单里最后一格有效的买入
```

- 买家自己 `claimGradReward(token)`：遍历 N 格（N ≤ 20），把这个钱包所有有效格的份额加起来，按 `(token, wallet)` 记已领，不能重复领。合格笔数第一次算出来后缓存。
- 毕业满 180 天后，`pay − Σ已领` 一次性回收（零头一起）：开了倒计时奖励就走 `receiveCarry` 并进去，否则退给 dev。回收后设关闭标记，不再接受领取。
- 分配完全由链上的固定规则确定。

## 5. 和倒计时奖励衔接

- 两个都开时，倒计时奖励模块在建币前就已经克隆好（它的工厂本来就要求先定 token 地址）。
- `carry` **只转给合约推导出的地址**：
  - `routeOf(token).recipient`，
  - 且 `handlerAdmin.moduleOf(recipient) == countdownFactory`，
  - 且模块的 token 等于这个币。
  
  不接受 dev 传入的地址（审查 B-3）。
- pad 目前只有 `taxHandler` 这一个外部地址，拿不到 `handlerAdmin` 和 `countdownFactory`。这两个地址做成 `Pad3Module` 的 immutable（或者存进新命名空间，由 owner 设一次）。
- 校验在**建币时**做：先部署代币，再核对 `moduleOf(recipient)` 和 `module.token()`，记下模块地址。并强制「`carryBps > 0` 时收款人必须是倒计时模块」。这样 `_graduate` 里不用再读外部合约来做校验。
- 只开冲毕业奖励时，`carryBps` 必须为 0。

## 6. 币不毕业怎么办

曲线没有截止时间，所以要有兜底，但不能让 dev 在快毕业时抢跑撤走（审查 B-2）：

- 建币满 `refundAfter` 天（建议 90 天）还没毕业，dev 可以**申请撤回**，进入 7 天公示期。
- 公示期内币毕业了，奖励照常发放，撤回作废。
- 公示期满还没毕业，dev 才能取回奖励池，这个玩法随之关闭。
- 公示期内 CLI、网站要显示「奖励即将撤回」。

## 7. 参数（建币时定，之后不能改）

| 参数 | 范围 | 建议默认 |
|---|---|---|
| 种子钱 | 建议设下限，比如 ≥ 0.1 BNB | 无默认 |
| `feeCutBps` | 0 – 10000（v1 建议不做） | 0 |
| `minBuy` | > 0，按实际花掉的金额 | 0.01 BNB |
| `N` | 1 – 20 | 10 |
| `lastBps` | 0 – 5000 | 3000 |
| `carryBps` | 0 – 5000（只在两个都开时） | 2000 |
| `refundAfter` | 30 – 180 天 | 90 天 |

## 8. 攻击和防护

| 编号 | 攻击 | 结论 |
|---|---|---|
| G-1 | **抢毕业那一笔**：曲线进度是公开的 | 这本来就是这个玩法想鼓励的行为：把币推过毕业线。抢到的人拿着代币，要承担毕业后的价格风险。`lastBps` 上限 50% |
| G-2 | **多个 Agent ID 占名额** | Game Life 那次有 114 个不同的 Agent ID 在 11 秒内买满，Agent ID 门槛挡不住有准备的人。每格都要真实花掉 `minBuy` 并持有到毕业（曲线上不能转出，卖了就取消资格）。dev 用 `minBuy` 和种子钱大小来控制吸引力 |
| G-3 | **dev 抢跑撤回** | §6 的公示期 |
| G-4 | **carry 被导到 dev 自己的地址** | §5，地址由合约推导 |
| G-5 | **毕业那笔的 gas** | 毕业时只冻结和写总额，份额在领取时算 |
| G-6 | **creator fee 已被领走** | 如果做切 creator fee，切出的部分在买卖时直接记进奖励池，不进 `creatorFeeOf` |

## 9. 合约改动

- 3.0 pad 新实现：
  - 新函数放进 `Pad3Module`（通过 fallback 调用），不要放 pad 主体。主体和 `CurveLogic3` 都受 EIP-170 大小限制，要跑 `forge build --sizes`。
  - 建币入口：一个统一入口带可选参数，能和 promote、abcd 组合，并且**加进 `createWithSalt` 的 selector 白名单**（`Pad3Module.sol:226-244`）。v1 不支持和 `--vault` 组合。
  - `_execBuy` 记名单；卖出路径打取消标记；`_graduate` 冻结并转 carry。
  - `claimGradReward`、`requestRefund`、`refund`、`retryCarry`。
  - 新的 ERC-7201 命名空间，更新 `test/gang3/GangLaunchpad3Layout.t.sol`。
- 走多签升级（ProxyAdmin 由多签直接控制，没有 Timelock）。CurveLogic3 是库，跟着实现一起重新部署。
- 不变量：pad 的 quote 余额 ≥ Σ奖励池 + Σ未领 + 其他托管。现有账目（`realQuote`、`creatorFeeOf`、推广分成的 `feeOf`）都按 token 分账，独立的映射不会冲突。
- GangBond、GangCallBond 只看余额，不受影响。

**事件**：`GradRewardSet`、`GradEntry`、`GradDisqualified`、`GradRewardBooked`、`GradClaimed`、`RefundRequested`、`Refunded`、`CarrySent`、`CarryOwed`。

**查询**：`gradReward(token)`（奖励池、参数、状态）、`gradEntries(token)`、`gradClaimable(token, wallet)`。

## 10. CLI、服务端、网站

- CLI：
  - 发币：`gang create … --grad-reward --gr-seed <amount> [--gr-min-buy 0.01] [--gr-entries 10] [--gr-last 30] [--gr-carry 20]`，多出种子钱的 approve 步骤，vanity 流程照底价赎回模块复用；
  - `gang buy` 预览：这笔会不会计入、当前奖励池多大、离毕业还差多少；
  - `gang reward status / claim` 和倒计时奖励共用。
- 服务端和网站：显示奖励池、离毕业还差多少、当前名单，以及撤回公示状态。

## 11. 待定的决策

1. 要不要做（要升级 pad，比倒计时奖励重）。建议先做倒计时奖励，看有没有人玩，再做这个。
2. v1 要不要切 creator fee（建议不切，只用种子钱）。
3. 种子钱的下限。
4. §7 的默认值，`refundAfter` 和公示期的天数。
5. 替代方案（审查 C-2）：不升级 pad，单独部署一个「冲毕业买入入口」合约，由多签加进路由名单，只认通过它的买入。代价是不走这个入口的买入不计入，毕业那一笔也可能被绕开。建议不用，但列出来供选择。
6. 名称：「冲毕业奖励」是否就是对外的名字。

## 12. 第 1 版之后改了什么（2026-11-17 独立审查）

- 种子钱改用 ERC-20 拉取，不用 `msg.value`；新入口要进 `createWithSalt` 的白名单（B-4）。
- 切 creator fee 的算法改成 `(creatorFee − 推广分成) × feeCutBps`，并建议 v1 不做（B-5）。
- 资格从「毕业时读余额」改成「卖出时打取消标记」，v1 不支持 vault 币（B-1）。
- 撤回改成「申请 + 7 天公示」（B-2）。
- carry 只转给合约推导出的模块地址（B-3）。
- `minBuy` 按实际花掉的金额算（B-7）；名单改成「最后 N 笔」；份额在领取时算（B-8）。
- 修正 `trader` 的说法（B-6）。
- 第 3 版（复审）：取消资格改用顺序判断；领取时遍历并防重复领；回收后关闭；carry 走模块的 `receiveCarry`；`handlerAdmin` 和 `countdownFactory` 作为 `Pad3Module` 的 immutable，建币时校验；门槛关闭时不计入；`_graduate` 正确处理撤回状态。

## 13. 第 4 版：定下的决策和实现（2026-11-17）

定下的决策：

- **v1 只用 dev 的种子钱**，不切 creator fee（§11-2）。`_syncShareAndFee` 和索引器的收入口径都不动。
- **卖回曲线就失去资格**，按顺序判断（§4）。
- **撤回先申请，公示 7 天**；公示期内毕业照常发放（§6）。dev 也可以撤销申请。
- **carry 的地址由合约推导**（§5）：读这个币的税收款人，要求它是 owner 设定的倒计时工厂部署的模块（`GangHandlerAdmin.moduleOf`），并且模块的 `rewardToken()`、`rewardQuote()` 就是这个币和它的报价币。dev 传不进地址。

实现（`src/gang/`）：

- `Pad3GradStore.sol`：命名空间 `gang.pad3.gradreward` 的存储，以及曲线调用的三个钩子：
  - `onBuy`：门槛开着，并且实际花掉 ≥ `minBuy`（或者这笔让币毕业），就记进环形名单；
  - `onSell`：写 `sellSeqOf`；
  - `onGraduate`：记账，作废进行中的撤回申请，发 carry。
  
  每笔买卖对没开这个玩法的币多读一个槽。
- `CurveLogic3.sol`：在 `_execBuy`、`sell`、`_graduate` 里各调用一个钩子。价格、手续费、退款都不变。
- `Pad3Module.sol`：
  - 建币入口 `createWithGradReward`，可以带推广分成，已经加进 `createWithSalt` 白名单；
  - owner 开关 `setGradReward(open, handlerAdmin, countdownFactory)`。
- `Pad3GradModule.sol`：把下面这些函数从 `Pad3Module` 拆出来，否则 `Pad3Module` 会超过 EIP-170 的 24KB 上限（审查 H-1）：
  - `claimGradReward`、`settleGradReward`、`sweepGradReward`、`retryCarry`；
  - `requestGradRefund`、`cancelGradRefund`、`gradRefund`；
  - 查询：`gradReward`、`gradEntries`、`gradClaimable`、`gradRewardDeps`。
  
  它的地址作为 `Pad3Module` 的构造参数（immutable `gradModule`），由 `script/Pad3Impl.sol` 先部署再传入。`Pad3Module` 的 fallback 按固定的 selector 表把调用转给它，其余照旧转给铸币飞轮模块。它的存储布局和 pad 一致，有布局测试。
  
  它没有 immutable。部署和升级脚本按逐字节比对它的代码，并检查它没有链接库（复审 N-1）。全新部署时预测 proxy 地址的 nonce 偏移从 +4 改成了 +5。
  
  大小：`Pad3Module` 21,854 B，`Pad3GradModule` 7,374 B，`CurveLogic3` 17,457 B，pad 21,784 B。
- carry 调用倒计时模块的 `receiveCarry(amount)`：pad 先授权，限 30 万 gas，用 try 包住。调用前如果剩余 gas 不够 30 万 ×64/63 再加 10 万，整笔交易 revert（`CarryGasLow`）。这样估 gas 不会落在「carry 因 gas 不够失败」的那条便宜路径上（复审 L-1）。模块没拉走的部分记成欠款，授权每次都清回 0，毕业不会因此回滚。
- 名单里最新的一格有效买入拿 `lastBps`。门槛开着时，这一格就是毕业那一笔；门槛关着毕业时，就是最后一格有效的买入。名单里只有一格有效时，它拿全部。
- 剩下的部分由**所有有效格子（包括最新那一格）按各自实际花掉的报价币金额分**，不再平分：`restPay × spent_i ÷ Σspent`，Σspent 在结算时缓存。最新那一格在此之外再拿 `lastBps`。
  - 这样一个人用多个 Agent ID 刷一堆 `minBuy` 小额格子，拿到的不会比一笔大额买入多。
  - 最新那一格也按花费参与分配。这样把推毕业拆成「一大笔 + 一小笔」拿不到更多；`lastBps` 设成 0 时，毕业那一笔也照样有份（审查 L-1 / L-2）。
  - 名单每格存「钱包 + 实际花费」：花费按 uint96 存，超出就封顶，只有单位数极大的报价币才可能碰到。原来存的是代币数量，现在不存了。
  - 用花费而不用代币数量做权重：曲线越往后越贵，同样的钱买到的代币越少；按代币数量算，会亏待临近毕业才买的人。
  - 例：同一个名单里，一笔 2 BNB 的买入和五笔 0.1 BNB 的买入，剩下部分按 80% / 20% 分；平分的话，五笔小额会拿走 5/6。没有一格有效时，`settleGradReward` 把奖励池交给倒计时模块；没开倒计时就退给 dev。
- 撤回：建币满 `refundAfter` 后 dev 申请，公示 7 天，之后有 3 天可以执行。3 天内没执行，申请就失效，要重新申请、重新公示。这样 dev 没法一直挂着一个随时能执行的申请，等到快毕业时抢跑（审查 M-1）。事件 `RefundRequested` 带可执行时间和过期时间，查询有 `refundPending`。

  剩余风险（复审 L-2，接受）：dev 可以在申请过期后马上重新申请，循环下去，每 10 天里有 3 天握着一个能立刻执行的撤回。每次申请都公开发事件，CLI 和网站要显示。
- 毕业满 180 天后，任何人都可以 `sweepGradReward`，把没领的部分（连同零头）转给倒计时模块，没开倒计时就退给 dev。之后不再接受领取。

已知限制（审查后决定接受）：

- carry 的欠款只能重试，没有别的去处。倒计时模块的 `receiveCarry` 只在模块还没 `bind` 时 revert，而 `bind` 谁都能调，所以能救回来。依赖：倒计时模块以后的版本不新增拒收条件。
- 按花费分配只在名单没满时完全挡住刷单。名单满了以后，每多一笔 ≥ `minBuy` 的计入买入都会把最老的一格挤出去。所以推毕业的钱如果 ≥ N × `minBuy`，拆成 N 笔就能占满名单、拿走全部奖励（挤掉别人不用额外花钱）。v1 接受；要根治得按钱包去重或提高 `minBuy`（dev 可以把 `minBuy` 设高、N 设大）。平分方案下这个问题更严重。
- 没开倒计时奖励的稳定币币种，dev 地址如果被稳定币拉黑，回收给 dev 会一直 revert。钱会卡住，但别人也拿不走。

实测 gas：
- 毕业那一笔（名单 20 格，含迁移），约 95 万；
- 第一次领取（顺带结算），约 27 万；
- 没开这个玩法的币，每笔买卖多读一个冷槽，约 2,100。

给 CLI 和网站：
- 公示 7 天、执行窗口 3 天、领取期 180 天都是常量（`Pad3GradModule.GRAD_REFUND_NOTICE`、`GRAD_REFUND_WINDOW`、`GRAD_CLAIM_WINDOW`），通过 pad 地址读不到，要写死在客户端里。
- 开了 carry 的币，毕业那一笔要多预留约 40 万 gas。

默认值（2026-11-17 定，由 CLI 0.42.0 执行；合约只检查 §7 的范围）：

- 种子钱下限 0.1 BNB；
- `minBuy` 默认 0.01 BNB；
- 名单 10 格；
- `lastBps` 30%；
- `refundAfter` 90 天。

以上金额都按这个币的报价币换算，汇率取毕业额 ÷ 毕业目标。

上线时：多签升级批次用升级脚本的 `PAD3_GRAD_REWARD` 一步加上 `setGradReward(true, handlerAdmin, 0)`，先只开单独玩法；carry 用 `script/SetGradRewardCountdown.s.sol` 单独开：一笔 `setGradReward(true, handlerAdmin, countdownFactory)`，脚本先逐字节比对工厂和它的实现（构建不带 `--libraries`），再在模拟里执行并读回。测试网 2026-11-17 已开；主网等多签。

CLI（0.44.0）：`--countdown-reward` 发射里可以加 `--grad-reward`，带 carry 时默认 `--gr-carry 20`（0–50）。pad 设的倒计时工厂必须是 CLI 用的那个，否则带 carry 的发射被拒（`--gr-carry 0` 照常）。
