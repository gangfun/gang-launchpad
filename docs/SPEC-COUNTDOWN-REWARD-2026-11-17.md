# 规格草稿 · 倒计时奖励（外盘）

- 日期：2026-11-17 起草；同日第 2 版按独立审查意见重写，第 3 版按复审意见修补（§13）
- 状态：**草稿，只在本地，不提交**。没有实现，没有审计。§12 的决策没定之前不开发
- 姊妹规格：`SPEC-GRAD-REWARD-2026-11-17.md`（冲毕业奖励，内盘）。两个玩法互相独立，dev 发币时各自选
- 口径：这是 dev 把自己那份税拿出来，在用户买币时附带的奖励玩法。用户本来就是来买币的，没有任何额外付费、门票或下注环节。文案里用「奖励池」「发放奖励」，不用「下注」「开奖」「奖金」

## 1. 做什么

一个 3.0 V3 有税币的收款模块（`countdown-v1`），和底价赎回模块一样每个币一个克隆。**这个模块同时也是买入入口**：通过它买入的池子买单才计入（§3）。

- 毕业后，池子税里原本给 dev 的那份进**奖励池**。
- 每笔计入的买入，把这一轮的截止时间重置为 `window` 之后。
- 截止时间一过，这一轮的**最后 N 笔**计入买入按 §4 分这一轮的奖励（奖励池的 `payoutBps`，不超过 `maxPayout`）。剩下的留在奖励池，进入下一轮。

对外可以这样说：**dev 把他那份税变成了买家的奖励。倒计时结束时，最后几笔买入按规则分走这一轮的奖励。**

## 2. 奖励池的钱从哪来

| 来源 | 说明 |
|---|---|
| 池子税里收款人的部分 | 主要来源。由税处理合约照常推送（普通转账，没有回调）。**只在税被卖掉时到账**：每次池子卖出前的 `swapBack`，或者 keeper 的 `process`（每个区块最多卖池子代币侧的 0.5%）。所以只有买单、没有卖单的阶段，奖励池只能靠 keeper 慢慢长 |
| dev 的份额（可选） | `devBps` ∈ [0, 5000]：**只作用在税的推送上**，这个比例记给 dev（拉取式），其余进奖励池。默认 0 |
| 种子钱（可选） | 任何人都能 `fund(amount)` 往奖励池里加报价币，dev 在建币并 bind 之后加。这部分全部进奖励池，**不按 `devBps` 分**。**只有 bind 之后才能加**（之前 revert，避免钱进了永远绑不上的模块） |
| 冲毕业奖励转入（可选） | 两个玩法都开时，冲毕业奖励在毕业时转进来的部分（姊妹规格 §5），同样全部进奖励池。pad 先 `approve`，再调模块的 `receiveCarry(amount)`，**不是普通转账**，否则会被当成税按 `devBps` 分 |

到账照底价赎回模块的 `unsplit` 来记：`余额 − 已记账` 就是新到账。区分「税的推送」和「`fund` / 转入」的办法是：`fund` 和 `receiveCarry` 走函数调用，自己记账；其余的新到账都当作税。

**`_book()`**：把「余额 − 已记账」按 `devBps` 记账。每个会读 `available` 或会动余额的入口（`buy`、`buyWithQuote`、`fund`、`receiveCarry`、`settle`、`finalize`、`claimDev`）**第一步都先调 `_book()`**。`claim` 不用：它减少的余额和账目是同一笔。`fund` 和 `receiveCarry` 的顺序是：先 `_book()`，再拉钱，再把这笔记进已记账。

平台不出钱。平台照常从税里拿成交额的 0.5%，分红部分照常给持币人。

## 3. 哪些买入算数：模块自己当买入入口

```
countdown.buy(minTokensOut, deadline) payable              // 报价币是 WBNB 时：付 BNB
countdown.buyWithQuote(quoteIn, minTokensOut, deadline)    // 其他报价币：先 approve 给模块
```

- quote 在克隆初始化时写死，`bind` 时和 `routeOf(token).quote` 核对。**对子不能在克隆时写死**：那时代币还没部署，`token.pair()` 要到毕业时才设置。所以每次买入时读 `IGangToken(token).pair()`（只写一次，可信），为 0（还没毕业）就 revert。
- 成交走这个官方对子，代币直接给 `msg.sender`。
- WBNB 路径（`buy`，付 BNB）：先 `_book()`，再 `deposit`，然后直接 `WBNB.transfer(pair, value)` 并调 `pair.swap`，中间不读余额。输出按 Pancake V2 的 0.25% 手续费公式算：输入量 = `balanceOf(pair) − reserveIn`，再按代币排序决定 `amount0Out` / `amount1Out`。否则用户的买入款会在模块里和奖励池混在一起，被当成税记账。
- `buyWithQuote`：直接 `transferFrom(user, pair)`，钱完全不经过模块。
- `quoteIn` 按**官方对子 quote 余额的增量**计，`tokensOut` 按买家余额的增量计（扣过买入税之后）。
- 算数的条件：
  - `quoteIn ≥ minBuy`；
  - 奖励池可用余额 ≥ `minPot`（太少就不计时，避免空跑）。
- 买入满足 `minBuy` 但没被计入（奖励池低于 `minPot`，或者落块时状态变了）时，交易默认照常成交。买家可以传 `mustCount = true`，这时没计入就整笔 revert（`NotCounted`）。CLI 和网站默认传 `true`。
- 对子的另一个币必须是 `rewardQuote`，否则 revert。
- 通过 Pancake 路由、聚合器或者 GangRouter 的普通买入都**不计入**。CLI 和网站对开了这个玩法的币，默认走模块入口，并在预览里写明「这笔买入会计入倒计时奖励」。

为什么不改 GangRouter（第 1 版的做法，已放弃）：路由不检查 quote 和对子，可以用自建的假对子零成本刷名额（审查 A-1）；其他币可以把收款人设成这个模块，借用它的轮次（A-2）；限 gas 的通知会被钱包的 gas 估算吞掉（A-3）；路由还要扩存储、走 48 小时 Timelock（A-4）。模块自己当入口时，token、quote、对子都是写死的，这些问题都不存在。

## 4. 轮次、截止和分配

**名单**：每轮一个长度为 N 的环形数组，记**最后 N 笔**计入买入，每格打包 `address + uint96 tokensOut`。同一个钱包可以占多格。外盘没有任何身份门槛，按钱包去重挡不住什么，还会多花很多 gas（审查 A-9）。

**截止**：每笔计入的买入把 `deadline` 设成 `now + window`，但**不超过这一轮的上限**：本轮第一笔计入买入的时间 + `maxRound`。一直有人买时，倒计时一直刷新，但到了上限这一轮就结束。

**到上限结束的轮次，所有份额平分**，最后一笔没有额外的 `lastBps`：这种轮次的结束时间是公开、固定的，最后那个区块里的交易顺序由出块方决定，而不是买家。

**惰性滚动**：截止后的第一笔计入买入先冻结上一轮的名单，再开新一轮（两个缓冲区轮换），所以不存在「截止后、结算前」的断档。`settle(round)` 谁都能调，keeper 兜底。

- **冻结时就算定份额**：`reserved[r] = min(available × payoutBps ÷ 10000, maxPayout)`，从 `available` 里预留出来。`settle(r)` 把它变成各钱包的 claimable，只扣一次。
- **不覆盖未结算的轮次**：要开新一轮、而轮换回来的那个缓冲区里还有未结算的轮次时，这笔买入先就地结算那一轮（最多 N 次写入，买家多付一点 gas，要实测）。

**分配**：份额在**冻结时**算定（下面的 `payout` 就是 `reserved[r]`），`settle(r)` 只按 `reserved[r]` 分，记成拉取式的 `claimableOf`，不再重新计算。

```
冻结第 r 轮时（以及 finalize 时），先 _book()：
available = 余额 − Σ未领 claimable − dev 未领 − Σreserved（已冻结未结算的轮次）
payout    = reserved[r] = min(available × payoutBps ÷ 10000, maxPayout)

settle(r) 时按 reserved[r] 分（k = 实际笔数，最多 N）：
extra            = payout × lastBps ÷ 10000（只有 1 笔时为 0）
每一笔（含最后一笔）  平分 payout − extra
最后一笔         再额外拿 extra
零头             留在奖励池
```

- 不用随机数。分配是确定的，没有可被出块方操控的随机源，也不用接 VRF。
- **不做持有检查**。第 1 版写了「结算时还持有才算」，审查指出它很容易绕过：可以从别的池子闪电借代币来满足余额，同一笔长期持仓还能在每一轮重复通过（A-5）。防护只靠经济成本，见 §6。
- 截止之后一直没有新的买入时，`settle(当前轮)` 先冻结、再结算。`finalize` 之前也先结算所有还在预留状态的轮次。
- **收尾的前提**：奖励池 ≥ `minPot`。低于 `minPot` 时既不开新轮，也不 `finalize`，等税把奖励池补回来，不会一遍遍发给最后一轮的老名单（审计 L-3）。
- **收尾**：连续 `idleDays` 天（建议 30）没有计入买入时，任何人可以调 `finalize()`，按最后一轮的名单再发一次，**同样受 `maxPayout` 限制**；之后每过 `idleDays` 可以再调一次。有新的计入买入时，玩法照常重新开始，不会永久关闭。这样不会让人在没人交易的币上用几笔小额买入拿走整个奖励池。奖励池低于 `minPot` 时，等新的税进来，或者有人 `fund` 补足；币彻底没人交易也没人补钱时，最多 `minPot` 那么多会一直留在模块里。
- **没人领**：v1 不做过期回收，claimable 一直可以领。跨轮合并的 `claimableOf[wallet]` 分不清哪笔过期，要做回收就得按轮次记账，不值得。

## 5. 参数（建币时定，之后不能改）

| 参数 | 范围 | 建议默认 |
|---|---|---|
| `window` | 30 分钟 – 24 小时 | 60 分钟 |
| `maxRound` | 1 – 24 小时，且 ≥ `window` | 6 小时 |
| `minBuy` | > 0，报价币计 | 0.05 BNB |
| `minPot` | ≥ 0 | 0.1 BNB |
| `payoutBps` | 1000 – 5000 | 3000 |
| `maxPayout` | **必填**，> 0，报价币计 | 1 BNB |
| `N` | 1 – 20 | 10 |
| `lastBps` | 0 – 2000 | 2000 |
| `devBps` | 0 – 5000 | 0 |
| `idleDays` | 7 – 90 | 30 |

dev 不能提走奖励池，也不能改参数。

## 6. 攻击和防护

**成本模型**：占一个名额 = 通过模块真实买入至少 `minBuy`，并付买入税，还要承担价格冲击和持仓风险。买入税里收款人那部分又会回流进奖励池。所以一轮能被一个人拿走的最多是 `maxPayout`，代价大约是 `名额数 × minBuy × (买入税 + 冲击)`。dev 主要用 `minBuy`、`maxPayout`、`lastBps` 来控制这个比例。CLI 发币预览里要算给 dev 看。

| 编号 | 攻击 | 结论 |
|---|---|---|
| K-1 | **塞块 / 排除竞争者**：最后一笔是自己的，然后让后面别人的买入进不了块，直到截止 | BSC 现在出块约 0.75 秒（2025 年 Maxwell 升级后，**待核实**），30 分钟约 2400 个区块，靠塞满区块来做成本很高。更现实的是 builder 或私有通道排除特定交易，这在区块层面无法完全防住。有先例：FOMO3D 第一轮就是被塞块拿走的。所以 `window` 下限定 30 分钟、`maxPayout` 必填、`lastBps` 上限 20%，让一轮能被拿走的上限可控。**到 `maxRound` 上限结束的轮次例外**：结束时间是公开的，结尾的名额天然偏向能控制交易顺序的人（builder、私有通道、捆绑交易）。为此这种轮次不发 `lastBps` 的额外部分（平分），一轮最多被拿走的仍受 `maxPayout` 限制。CLI 和网站要如实提示这一点 |
| K-2 | **多钱包占名额** | 公开规则下的正常参与，按成本模型控制。dev 用小号也能这么做（A-10），CLI 和网站要如实提示：奖励池可能被任何人用多个钱包拿走，包括 dev 本人 |
| K-3 | **假对子 / 跨币借用** | 模块写死 token、quote、官方对子，不接受外部传入 |
| K-4 | **闪电贷**：借钱买入、马上卖掉 | 买入要付真实的买入税。税里收款人那部分会回流进奖励池，攻击者有可能赢回一部分，但平台的 0.5%、分红和价格冲击是实打实的成本。不做持有检查，见 §4 |
| K-5 | **奖励池超发** | §4 的 `available` 先扣掉所有已记账未领的部分。不变量：余额 ≥ Σ未领 claimable + dev 未领 + Σreserved |
| K-6 | **只有买单时奖励池不增长** | keeper 的 `process` 频率要配合，文案里写「奖励池余额」，不写「本轮成交产生的税」 |

## 7. 合约

- `GangCountdownReward`：每个币一个克隆，不可升级，没有 owner。同时是收款人和买入入口。
- `GangCountdownRewardFactory`：照底价赎回模块的工厂来做。要求走 abcd 地址部署器，克隆时就要定下 token 地址；克隆后在同一笔交易里 `listModule`；`bind(token)` 检查 creator、quote、`dividendBps < 10000`，以及 `routeOf(token).recipient == address(this)`。
- 不改 GangRouter，不改税处理合约。
- GangHandlerAdmin：工厂需要列表权限，由多签 `setFactory`，和底价赎回一样。
- 对子自己的闪电贷回调里，对子处于锁定状态，再调 `swap` 本来就会 revert，所以 `buy` 不需要额外的闪电贷检查。

**事件**：`Funded`、`TaxBooked(toPot, toDev)`、`Counted(round, buyer, quoteIn, tokensOut, deadline)`、`RoundFrozen(round)`、`Settled(round, payout, entries)`、`Claimed`、`DevClaimed`、`Finalized`。

**查询**：`currentRound()`、`deadline()`、`potAvailable()`、`entries(round)`、`previewSettle(round)`、`claimableOf(wallet)`、`wouldCount(quoteIn)`。

**不变量**：
- 余额 ≥ Σ未领 claimable + dev 未领 + Σreserved；
- 每轮发放 ≤ `maxPayout`；
- 奖励池只会流向买家、dev（`devBps`，仅限税的部分）。

## 8. 和其他模块的关系

- 一个币只有一个税收款人位置，所以 v1 和底价赎回、回购、加池、组合、封顶、分账、`--recipient` 都不能同时用。
- 可以和分红一起用（`dividend < 100`），也可以和推广分成一起用（推广分成在曲线上）。
- 可以和冲毕业奖励一起用（姊妹规格）。

## 9. Keeper

- 新类型 `countdown-v1`：截止时间过了就调 `settle`，空闲到期了就调 `finalize`。
- 按 `admin.modules()` 自动发现，不要再靠手工列表。

## 10. CLI、服务端、网站

- CLI：
  - 发币：`gang create … --countdown-reward --cd-max-payout <amount> [--cd-window 60m] [--cd-min-buy 0.05] [--cd-payout 30] [--cd-entries 10] [--cd-last 20] [--cd-dev 0] [--cd-seed <amount>]`。预览里算出「一轮最多被拿走多少，占满名额要花多少」；
  - `gang buy`：对开了这个玩法的币默认走模块入口，预览里写明会不会计入；
  - 查询和操作：`gang reward status / claim / settle`。
- 服务端：索引上面的事件，提供当前轮次、截止时间、可用奖励池和名单。
- 网站：代币页上显示倒计时、奖励池和最近计入的买入。买入按钮走模块入口。文案按开头的口径写。

## 11. 上线顺序和测试网验收

规格定稿 → 合约和测试 → 内部审计 → 修复 → 独立复审 → BSC 测试网 → 主网工厂部署 + 多签 `setFactory` → keeper、服务端、网站、CLI。

测试网要逐条测：
- 第 N+1 笔把最早一笔挤出名单；同一钱包连续买入；
- 截止后第一笔买入冻结上一轮并开新一轮；
- 不足 N 笔、只有 1 笔时的分配；
- `maxPayout` 封顶；`available` 扣除未领之后不超发；
- 只有买单时奖励池不增长，keeper 处理之后才增长；
- `finalize` 受 `maxPayout` 限制、可重复，之后有新买入时重新开始；
- 两轮都没结算时开第三轮（就地结算，不覆盖）；
- WBNB 路径上用户的钱不会被当成税；`receiveCarry` 不按 `devBps` 分；
- vanity（abcd）建币的完整流程。

## 12. 待定的决策

1. §5 的默认值和范围，特别是 `window` 下限、`maxPayout` 默认值和 `lastBps` 上限。
2. 要不要开放 `devBps`，也就是 dev 自己留一部分。
3. `idleDays` 的天数。
4. 名称：「倒计时奖励」是否就是对外的名字。

## 13. 第 1 版之后改了什么（2026-11-17 独立审查）

- 计入方式从「升级 GangRouter，买完通知模块」改成「模块自己当买入入口」。原因：A-1 假对子刷名额、A-2 跨币借用、A-3 gas 估算吞掉通知、A-4 路由扩存储和走 Timelock。
- 去掉「持有检查」（A-5）。
- 名单从「最后 N 个不同钱包」改成「最后 N 笔」（A-9）。
- 加惰性滚动（A-8）、`available` 口径（A-7）、`finalize` 收尾。
- `window` 下限 30 分钟、`maxPayout` 必填、`lastBps` 上限 20%（A-6）。
- `devBps` 只作用在税上（A-11）；如实提示 dev 也能用小号拿走奖励（A-10）。
- 第 3 版（复审）：对子改为使用时读取；WBNB 路径不在模块里混钱；所有入口先 `_book()`；冻结时预留份额；不覆盖未结算轮次；carry 走 `receiveCarry`；`finalize` 受 `maxPayout` 限制、可重复；去掉过期回收；份额在冻结时算定，`settle` 只按预留的份额分。
- 实现后内部审计（2026-11-17）：没有 Critical / High / Medium。按 Low 修改：分配公式以代码为准（L-1）；加 `mustCount`（L-2）；`finalize` 要求奖励池 ≥ `minPot`（L-3）；`fund` 要求已 bind（L-4）；测试改用带 K 检查和锁的对子（L-6）；加 `distribute`，把其他资产打到 0xdead（I-3）；核对对子的另一个币（I-4）。代码里实际的接口是 `settle()`（结算所有到期的轮次）和 `round(buffer)`，不是 `settle(round)` / `entries(round)`（I-5）；历史轮次看事件。
- 加「每轮最长时长」`maxRound`（2026-11-17，用户决定，默认 6 小时）：截止不超过本轮第一笔 + `maxRound`；到上限结束的轮次平分、不发最后一笔的额外份额（复审 Medium：结束时刻可预测）。
