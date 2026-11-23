# 规格草稿 · GangSwap：可选的自有外盘（`gangswap-v1`，fork Pancake V2，带虚拟储备，毕业回购销毁）

- 日期：2026-11-22 起草，同日按第一轮独立评审修订（第二版，§15），再按复审修订（第三版，§16）
- 状态：**已实现（PR #197），未上测试网**（2026-11-23，§17）。设计第一轮评审有 2 个高危，已改，第二版复审通过；实现经过两轮独立评审（核心合约、pad 集成），都没有严重、高危问题。之后的改动又复审了一轮（1 个中危、7 个低危，已处理）；这一轮的修复（主要是部署脚本的 `check` 和测试）没有再审（§17.2）
- 基础：GangLaunchpad 3.0 的曲线币。默认毕业路径（Pancake V2，LP 销毁）不变；GangSwap 是创建时可选的另一条毕业路径
- 用户 2026-11-22 定下的方向：可选自有 AMM；默认仍然毕业到 Pancake V2；释放出来的 20% 用来做毕业回购销毁；名字叫 GangSwap；GangSwap 直接 fork Pancake V2，不从头写

## 1. 一句话

创建代币时可以选择「毕业到 GangSwap」。毕业时，曲线募到的钱里有一部分任何交易都拿不到，GangSwap 在毕业那一刻把它取出来，在原位换成一笔等额的**虚拟储备**，池子的价格曲线保持不变。取出来的这部分用来回购代币并销毁（§7）。这样池子里不会留下一笔永远没人用得到的计价币。

## 2. 为什么这样做

### 2.1 现在的残值从哪来

曲线卖出 8 亿枚后毕业，剩下的 2 亿枚和募到的全部计价币 G 一起放进 Pancake V2，LP 打进 0xdead（`CurveLogic3._graduate` → `PadCommon.migrate` → `SharedMigrator.migrate`）。x·y=k 的池子卖不空：外面的 8 亿枚全部卖回池子后，池子里还剩

```
G × 2 亿 / 10 亿 = 0.2 G
```

6 / 9 / 12 / 15 BNB 四档分别剩 1.2 / 1.8 / 2.4 / 3.0 BNB，再加上 LP 手续费让 k 变大的部分。four、flap 的 V2 池子是同一个道理（four 的 3.6 BNB 约等于 18 × 0.2）。

### 2.2 这 0.2 G 本来就是死钱

0.2 G 是「所有代币都回到池子里时，池子里还剩的计价币」，任何一笔交易都碰不到它：卖家合计最多只能拿走 0.8 G（加上毕业后新买入的钱）。把它拿出来，只要在原位记上一笔等额的虚拟储备，在手续费率相同的前提下，每一笔买卖的价格都不变。

和毕业到 Pancake V2 相比，实际有两点差别：

- GangSwap 的手续费是 1%，Pancake V2 是 0.25%；
- Pancake V2 把手续费留在池子里，所以 k 会慢慢变大，GangSwap 的 k 不变。

### 2.3 pump 已经这样做了（链上核实，2026-11-22）

PumpSwap 的池子账户里有 `virtual_quote_reserves`，买卖按「真实储备 + 虚拟储备」定价。一次标准毕业的链上数字：

- 曲线交出 85.05 SOL 和 2.068 亿枚；
- 池子里真实 SOL 67.45，虚拟储备约 17.58；
- 17.5845 SOL 转到这个币专属的 BOOST 账户，约 5.3 分钟内分 29 笔买入并销毁，共销毁 5,185 万枚。

17.58 = 85 × 20.69%，正是 2.1 节里的死钱。我们用当时的真实成交验证了定价：一笔 0.466 SOL 的买入得到 1,235,297 枚，按「真实 63.67 + 虚拟 17.58」计算是 1.235M，吻合；只按真实储备算应是 1.57M。

我们照 pump 按固定时间表回购（用户 2026-11-22 选定）。第一轮评审算出，固定时间表会被提前埋伏的人吃掉一大部分（§7.3），用户知道这一点并接受。

### 2.4 为什么不走 Pancake V3 或 Infinity

- **Pancake V3**（`dd53903` 里搁置的设计记录，三轮评审）：任何人都能抢先建 V3 池并随意定价。four.meme 2025-02-11 就是这样被攻击的，之后改回了 V2。
- **Pancake Infinity 加自有 hook**（2026-11-22 可行性核查）：合约上能做。但 KyberSwap、Velora、OpenOcean 实测不路由自定义 hook 池；DexScreener 在 BSC 上看不到任何 Infinity 池；honeypot.is 返回 404。
- **GangSwap**：池子只有我们能建，不存在抢建的问题；接口和 Pancake V2 相同，聚合器和行情网站接入时**大部分可以复用 V2 分叉的代码**。但虚拟储备意味着计价币一侧 `balanceOf(pair) < reserve`，按余额差计算输入的路径要专门适配（§6.5）。所以每家都需要一次商务对接，不是改配置就能用。

### 2.5 要说清楚的事

- **同费率下价格曲线不变，卖家不会因此多拿钱。** dev 和持币人得到的好处，是那 0.2 G 拿来回购销毁：给价格托底，流通量也变少。
- **代价是毕业后不在 Pancake 上。** 现在 3.0 的曲线币在 DexScreener（`pairs: null`）和 GeckoTerminal（404）上都查不到。GangSwap 的币毕业后要等这些网站收录 GangSwap（§11）才能被看到。在那之前，只有 gang.fun、CLI、agent，以及专门接入了 GangSwap 的渠道能交易。毕业后任何人都可以拿自己的币去 Pancake 建一个第三方池子，它可能比 GangSwap 先被行情网站收录（§9）。
- **creator 的外盘手续费收入大约只有内盘的一半。** 手续费按输入的那种币收：买入收 BNB，分给 creator 和平台；卖出收代币，直接销毁（D5）。
- 创建时选了就不能改。

## 3. 关键决定

| # | 决定 | 理由 |
|---|---|---|
| D1 | GangSwap 的 pair、factory、router **fork Pancake V2 主网的已验证源码**，改动越少越好（§6）。新写的只有接 pad 的迁移合约、回购合约和手续费合约（0.8.28） | 实战检验过的代码；审计只看 diff；对外接口和 Pancake V2 一样 |
| D2 | 新的币种类型号 **`kindOf = 4`**（下称 GS 曲线币）。曲线阶段的规则和类型 1 完全一样，只有毕业路径不同 | 评审核实：GangBond、GangCallBond 和 9 个税收模块都只认类型 1 / 2，在缴纳或绑定时就会拒绝。这样资金不会在毕业后因为读不到 Pancake V2 而卡死（§9） |
| D3 | 第一期只做：WBNB 计价、无税、不带任何模块（不含底仓、金库、推广分成、倒计时奖励、冲毕业奖励、一键模块发射） | 范围最小。带税和其他计价币见 Q5 |
| D4 | 虚拟储备 `V = floor(G × T_pool / TOTAL_SUPPLY)`。其中 G 是毕业时的 `realQuote`，T_pool 是毕业时进池的代币数（`TOTAL_SUPPLY − sold`）。真实放进池子 `G − V`，回购合约拿 `V` | 有效储备 = G，价格和曲线终点一致。向下取整保证 k₀ ≥ V × TOTAL_SUPPLY，真实储备永远不为负（§8 I1） |
| D5 | 手续费：**每笔 1%，按输入的那种币收，向下取整，从池子里拿走**，不留在池子里滚大 k。计价币部分 70% 给 creator、30% 进平台 bucket；代币部分转到 0xdead | 按输入收是 V2 router 的算法。向下取整是 I2 成立的条件（评审：向上取整会让 k 少 1 wei） |
| D6 | **池子只能注入一次流动性**：毕业时由迁移合约注入，LP 全部打进 0xdead。之后 `mint` 一律回滚，`burn` 也一律回滚 | 虚拟储备只对这一份流动性成立。LP 全在 0xdead，扫描工具看到的是「LP 已销毁 100%」 |
| D7 | 不支持闪电兑换（`swap` 的 `data` 必须为空） | 少一条攻击路径，主流路由也用不到 |
| D8 | **回购照 pump 按时间表执行**（§7，用户 2026-11-22 选定）：毕业后按 40 步、每步约 `V / 40` 买入，不看价格。每步不超过当前有效计价储备的 0.5%；两步至少隔 8 秒，从上一步算起。正常约 5.2 分钟买完 | 用户选择和 pump 一样的托底节奏，接受被埋伏的代价（评审 M3）。0.5% 上限让夹子无利可图（评审 M1，复审已验证），从上一步算间隔挡住追赶（M2），都不改变时间表的性质 |
| D9 | 毕业后池子对所有人开放：不检查 Agent 门槛，没有 1% 钱包上限 | 毕业后的池子应该是公开市场，和毕业到 Pancake 时一样 |
| D10 | GangSwap 的合约全部不可升级、没有暂停开关（照 Pancake：要改就部署新版，新老并存）。只有迁移合约有一个只能增加的 pad 名单。pad 的 `setGangSwapMigrator` 可以换成新版，只影响之后创建的币；每个币在创建时记下自己的迁移合约（`gangSwapMigratorOf`），之后不变；设成 0 就关闭创建（用户 2026-11-23 定） | 和 `SharedMigrator` 一样：池子和流动性永远不受我们控制 |
| D11 | 毕业后 `getTokenInfo` 报一个**新的状态码 `STATUS_GANGSWAP = 4`**，不报 `STATUS_POOL` | 第一轮评审 H2：现有接入方看到 `STATUS_POOL` 会去 Pancake V2 交易，要么回滚，要么进了攻击者建的第三方池子。新状态码只对显式判断「状态 == 2」的接入方有用；写成「状态 == 1 就走曲线，否则走 Pancake」的代码仍然会走错（复审 N5）。状态 4 时 `pair` 返回 GangSwap 的 pair，`protocolFeeBps` 返回 100：按 0.25% 去算的人会在 K 检查上回滚，至少不会成交错 |

## 4. 创建与曲线阶段

- 在 `Pad3Module` 里新增创建入口 `createGangSwap(name, symbol, logoURI, metaURI, gradBnb)`：
  - 计价币固定为 WBNB；税为 0；`gradBnb` 是现有的 6 / 9 / 12 / 15 档之一；
  - 写入 `kindOf[token] = 4`，其余和 `_createCurve` 一样（曲线参数、版本、logo、Agent 窗口）；
  - 加进 `createWithSalt` 的白名单（`Pad3Module.sol` 约 288–308 行，abcd 路径），也加进 `Pad3GradModule._isCurveCreate`（Agent 窗口，Q4）。
- `createWith{Vault,Promote,GradReward,Base}` 这几个入口直接调 `_createCurve`（类型 1），所以模块挂不到类型 4 上。新代码不能把它们嵌套进 `createGangSwap`。
- 曲线阶段的买卖、手续费、Agent 门槛、钱包上限和类型 1 完全一样。评审核实：`buyFor`、`sell` 等曲线入口本来就不看类型，类型 4 不用改就能交易。下面这些地方现在对类型 4 会走到别的分支，必须改：

| 位置 | 现在对类型 4 的行为 | 要改成 |
|---|---|---|
| `GangLaunchpad3.getTokenInfo` | 落到 `LegacyRoute.info`，因为 `pad == this` 返回 `STATUS_NONE` | 曲线阶段 `STATUS_CURVE`，毕业后 `STATUS_GANGSWAP`（D11） |
| `tryBuy` / `trySell` | 返回全 0；`tryBuy` 里还有 `kind == KIND_CURVE && agentGateEnabled` 的条件 | 和类型 1 一样 |
| `buyTokenAMAP` / `_entrySell`（aggregator 入口） | 回滚 `NotCurveToken` | 曲线阶段和类型 1 一样 |
| `buyWithPromoter` | 回滚 `NotCurveToken` | 第一期保持回滚 |
| `GangGateway.getTokenInfo` / `_curve` | 返回全 0 / 回滚 | 不改：pad3 自带聚合器入口，gateway 对类型 4 保持关闭（另行评估） |
| `GangPadRegistry._curve` | `live = false` | 升级 registry（代理） |
| pad 的 NatSpec | 只写了状态 0–3 | 加上状态 4 的说明 |
| CLI（`skill/gang-cli/src/gangpad.js` 的 `KINDS`） | 类型 4 映射成 null，已发布的 CLI 会报「RPC error, retry」，容易误导 | 加上类型 4；`creatorfee` 流程要同时覆盖 `GangSwapFees.claim`。`bond.js`、`callbond.js` 已经拒绝类型 4，正确 |

- 其余类型判断和写入逐一过一遍：`GangLaunchpad3`、`Pad3Module`、`Pad3FlyModule` 里共约 33 处（复审 N7 的数字），归到上面两类之一。
- 合约大小（复审按现有构建产物估计）：`GangLaunchpad3` 只剩约 2,792 字节，`Pad3Module` 约 10,239 字节。`getTokenInfo`、`tryBuy`、`trySell`、`buyTokenAMAP`、`_entrySell` 的分支都在 `GangLaunchpad3` 里，空间紧但够用；`createGangSwap` 放进 `Pad3Module`。

## 5. 毕业

`CurveLogic3._graduate` 现在拿不到类型号。最省的做法是在新的命名空间存储里给每个 GS 币记一个标记，由库直接读，这样不用改 `buy` 的签名（复审 N8）。对类型 4 走另一个迁移合约，其余步骤不变：

1. `cv.graduated = true`；`tokenAmount = TOTAL_SUPPLY − cv.sold`；`quoteAmount = cv.realQuote`；`cv.realQuote = 0`。
2. `token.unlock(gangSwapMigrator)`，然后把代币和 WBNB 转给 `gangSwapMigrator`。无税，所以不调用 `setPair`。
3. `gangSwapMigrator.migrate(token, WBNB, tokenAmount, quoteAmount)`：
   1. 只有名单里的 pad 能调用；参数检查照 `SharedMigrator`。
   2. `V = quoteAmount × tokenAmount / TOTAL_SUPPLY`（向下取整）；`seed = quoteAmount − V`。
   3. `pair = factory.createPair(token, WBNB, WBNB, V)`。factory 只接受迁移合约调用，所以这个 pair 别人不可能先建（§6.2）。
   4. 把 `tokenAmount` 枚代币和 `seed` 的 WBNB 转进 pair，再 `pair.mint(0xdead)`。`mint` 按 `_balances()` 计算（§6.1 P2）；如果毕业前有人往这个可预测的地址转过 WBNB，也会算进初始储备，起始价因此略高于曲线终点。这是捐款人自己的损失，I1 仍然成立（评审 L7）。
   5. 把 `V` 的 WBNB 转给 `GangSwapBoost`，调用 `boost.register(token, pair, V)`；同时记下 `padOf[pair] = msg.sender`（手续费合约按它找 creator，§6.4）。
   6. 发 `GangSwapMigrated(token, pair, pad, tokenAmount, seed, V, lp)`。
4. `cv.pair = pair`；发 `Graduated` 事件。

迁移合约的地址放进一个新的命名空间存储（照 `Pad3BaseStore` 的做法），**不能放进 `Config`**：`Config` 由几个 pad 共用，每个模块都会重新声明它。

毕业这一步不做任何 swap，gas 是常数，和其他人的状态无关。

迁移合约的 pad 名单只能增加（照 `SharedMigrator`）。名单上的任何 pad 都能迁移任何代币，所以只能把我们自己的 pad 加进去：如果误加了一个，它可以抢先给一个还在曲线上的 GS 币建 pair，这个币真正毕业时就会因为 `PAIR_EXISTS` 永远回滚（实现评审 L4）。另外，`addLaunchpad` 要求 factory、回购、手续费三个合约和迁移合约互相指对（`wired()`，实现评审 M2）。

## 6. GangSwap 合约（fork Pancake V2）

基准源码：BSC 主网 PancakeFactory `0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73`（内含 `PancakePair`，`pragma solidity =0.5.16`）和 PancakeRouter `0x10ED43C718714eb63d5aA57B78B54704E256024E`（`=0.6.6`），取自 Sourcify 的已验证源码。原文件放在 `gangswap/upstream/`（只把换行符归一成 LF），改动后的文件放在 `gangswap/src/`；`gangswap/check-diff.sh` 列出全部改动（供人工核对，不会自动拦截）。

**许可证**：Pancake V2 fork 自 Uniswap V2（GPL-3.0）。fork 出来的文件保留 GPL-3.0，和仓库里其他 MIT 文件分开标注。

### 6.1 `GangSwapPair`（改自 `PancakePair`）

| # | 改动 | 说明 |
|---|---|---|
| P1 | 新增 `quoteIs0`（WBNB 是不是 token0）和 `virtualReserve`（V），在 `initialize(token0, token1, V)` 里写入，之后不变 | V 走 initialize 而不是 constructor，所以 init code hash 是常数，router 照常用 CREATE2 算 pair 地址 |
| P2 | 新增 `_balances()`：两种币的 `balanceOf(this)`，计价币一侧再加 `V`、减去 `feeAccrued`。`mint`、`swap`、`sync` 原来读余额的地方都改读 `_balances()`；`skim` 转走 `_balances() − reserve` | 这样 `reserve0/1` 和 `getReserves()` 一律是**有效储备**（计价币一侧含 V）。router 用 getReserves 算价，结果正确 |
| P3 | `swap` 里的 K 检查：`mul(25)` 改为 `mul(100)`（1%）。K 检查通过后、`_update` 之前，把向下取整的 1% 从池子里拿走：计价币部分 `feeAccrued += fee`；代币部分 `_safeTransfer(token, 0xdead, fee)`。`_update` 用拿走之后的余额 | 和 V2 用同一条 K 不等式，但手续费不留在池子里，所以 k 只在取整时变大（§8 I2） |
| P4 | `swap` 里 `data.length > 0` 改为回滚；删掉 `pancakeCall` | D7 |
| P5 | `mint` 只允许 factory 记下的迁移合约调用，并且只在 `totalSupply == 0` 时可以调用。`MINIMUM_LIQUIDITY` 照旧锁给 0 地址，其余 LP 打给 0xdead | D6 |
| P6 | `burn` 改为直接回滚 | 现在本来就调不到（没人有 LP），但原代码按原始 `balanceOf` 付款，和虚拟储备不一致。回滚只多一行 diff（评审 L5） |
| P7 | 删掉 `_mintFee` 以及 `kLast` 的维护 | 没有 feeTo |
| P8 | 新增 `claimFees()`：只有 `GangSwapFees` 能调用，把 `feeAccrued` 的 WBNB 转给它并清零 | 手续费按 pair 分开记账 |
| P9 | `price0CumulativeLast` / `price1CumulativeLast` 保留，按有效储备累计 | 和 V2 一样，以后的模块和外部工具可以读 TWAP |
| P10 | 事件保留 V2 原样的 `Mint` / `Burn` / `Swap` / `Sync`（`Sync` 报的是有效储备）；新增 `FeeTaken(feeQuote, feeTokenBurned)` | 按 V2 事件建索引的工具直接能用；真实流动性要另外读（P11） |
| P11 | 公开视图：`quoteIs0()`、`virtualReserve()`、`feeAccrued()`、`realQuoteReserve()`（= 有效储备 − V）、`quoteBalanceBase()`（= 有效储备 − V + `feeAccrued`，也就是「计价币余额里不算输入的那部分」） | 给接入方和我们自己的 router 用（§6.3、§6.5） |

### 6.2 `GangSwapFactory`（改自 `PancakeFactory`）

- `createPair(tokenA, tokenB, quote, V)` 只允许 `migrator`（构造时写死）调用。没有 `feeTo` 和 `feeToSetter`。
- `getPair`、`allPairs`、`allPairsLength`、`INIT_CODE_PAIR_HASH` 和 `PairCreated` 事件保持原样。
- 因为只有迁移合约能建 pair，而迁移合约只在毕业时被 pad 调用，所以一个代币在 GangSwap 上**只可能有一个池子，而且一定是毕业时建的**。

### 6.3 `GangSwapRouter`（改自 `PancakeRouter`）

- 改：factory 地址、`WETH` = WBNB、`PancakeLibrary.pairFor` 里的 init code hash（solc 0.5.16 会把源码的元数据哈希编进 pair 的字节码，pair 改动任何一个字，连注释在内，这个哈希都会变。改完 pair 要跑 `gangswap/sync-init-hash.sh`，测试和部署脚本都会核对）、`getAmountOut` / `getAmountIn` 里的 `9975` 改为 `9900`。
- **改 `_swapSupportingFeeOnTransferTokens`**（第一轮评审 H1，复审确认所有路径都正确）：输入侧是计价币时（用 `pair.quoteIs0()` 判断，不要用 `input == WETH`，第二期换计价币时才不用改），`amountInput = balanceOf(pair) − pair.quoteBalanceBase()`，不能用 `balanceOf(pair) − reserveInput`。原写法下计价币余额总是比有效储备小 V 左右：6 档的币买 0.1 或 1 BNB 会下溢回滚；买 2 BNB 只按 0.815 BNB 记账，少拿 53% 的币，多付的部分白送给下一个卖家。
- 删：所有加池和撤池函数（`addLiquidity*`、`removeLiquidity*`，它们都会回滚）。
- 保留：所有 `swap*` 函数，以及 `quote`、`getAmountsOut`、`getAmountsIn`。
- **不在 swap 前顺带执行回购**（第一版的想法，评审 M4 证明它会让正常滑点下的买入回滚、报价不准，而且挡不住夹子）。

### 6.4 `GangSwapFees`（新写，0.8.28）

- 谁都可以调用 `collect(pair)`：
  1. 检查 `factory.getPair(pair.token0(), pair.token1()) == pair`，不认就回滚（评审 M5：否则一个伪造的 `claimFees` 可以凭空给任意 creator 记账）；
  2. 调 `pair.claimFees()`，**按本合约 WBNB 余额的实际增加量**记账；
  3. 70% 记到 creator 名下。creator 从迁移合约记下的 `padOf[pair]` 这个 pad 的 `curves[token].creator` 读；
  4. 30% 进平台 bucket：bucket 是 `SharedPlatformFeeBucket`，它的 `notifyAccrual` 用 `transferFrom` 拉款，所以本合约先 `approve` bucket，再调用 `notifyAccrual(WBNB, amount)`。这一步放在 try 里：bucket 拒收（例如 Safe 撤了 operator 或者换了 bucket）时，平台那份记成待转，以后任何人都可以调 `flushPlatform()` 重试。**creator 那份不受影响**（复审 N4：本合约没有 owner，两边绑在一起会把 creator 的钱也卡住）。
- creator 通过 `claim(token, to)` 领取，`claim` 会先对这个币的 pair 调一次 `collect`。照内盘的做法，用领取而不是直接转账，这样 creator 那边转账失败也不会卡住别人。
- 部署时 bucket 的 owner 要执行 `setOperator(GangSwapFees, true)`。

### 6.5 给接入方的说明（必须随合约一起发布）

- `getReserves()` 和 `Sync` 报的是**有效储备**。计价币一侧比真实可取的多 V，所以全部卖完之后，行情网站上仍会显示约 V（1.2～3 BNB）的流动性，实际是 0（评审 L3）。真实流动性看 `realQuoteReserve()`。
- 计价币一侧 `balanceOf(pair) < reserve` 是设计如此。按余额差算输入的执行器（1inch、Kyber、0x 那类）必须改用 `balanceOf(pair) − quoteBalanceBase()`。
- **不适配时不一定会失败**（复审 N2）：
  - 输入小于「V − 未领手续费」时下溢，会回滚；
  - 输入更大时，pair 照实际收到的数记账，K 检查宽松通过，**少给的币会悄悄留在池子里**（6 档的币买 2 BNB 少拿 53%），只有执行器自己最后的最小输出检查能挡住；
  - 未领手续费比 V 还多时方向反过来，执行器多记输入，K 检查回滚；
  - 未领手续费刚好接近 V 时，不适配的执行器碰巧能用，所以接入方的测试可能凑巧通过。
- 手续费 1%，按输入收，**不留在池子里**。按「手续费留在池子里」建模的聚合器，在同一笔交易里对同一个池子下第二笔时会报错价（评审 L4，影响有限）。
- 卖出时的手续费是代币，会被销毁。

## 7. 回购（`GangSwapBoost`，新写，0.8.28）

### 7.1 规则

- `register(token, pair, V)`：只允许迁移合约调用，每个 token 只能调用一次。记下 `V`、`left = V`、`lastStepAt = 0`（毕业之后马上就可以执行第一步）。
- `step(token)`：谁都可以调用。下面的条件全部满足才执行，否则回滚：
  1. `left > 0`；
  2. `now ≥ lastStepAt + 8 秒`（从上一步算起，不追赶，评审 M2。`block.timestamp` 以整秒计，写不出 7.5 秒，复审 N7）。
- 不看价格（D8），也**不看同一区块里有没有别的交易**。第二版有这一条，复审 N1 指出它可以被一个免费的 `sync()` 每秒挡住，在交易频繁的新池子上也会一直卡住，而防夹子已经由 0.5% 上限做到了，所以删掉。
- 每步花 `b = min(left, V / 40, 当前有效计价储备 × 0.5%)`；如果花完之后 `left − b < V / 400`，这一步把剩下的一起花掉，免得多出一步只买几 wei（复审 N6）。把 WBNB 转进 pair，按 V2 公式（1% 手续费）算出能拿到的代币，调用 `pair.swap`，`to` 设为 0xdead。发 `BoostStep(token, quoteIn, tokensBurned, left)`。
  - 毕业时有效储备 = G，`V / 40 = 0.5% G`，两个上限正好相等。
  - 池子卖下去之后，0.5% 上限会让每步变小、步数变多。
- 节奏：keeper 正常的话 40 步约 5.2 分钟。没有期限，用完为止。

### 7.2 keeper

prod keeper 加一个常驻循环：盯 `GangSwapMigrated` 事件，对每个还有 `left` 的币，每 8 秒用 `eth_call` 试一次 `step`，能执行才发交易。现有的 5 分钟 cron 精度不够，需要单独起一个进程。gas 由平台出：实测每步约 20 万 gas（冷存储），每个币通常 40 步。另外，毕业那一笔（最后一笔曲线买入）因为要建 pair、注入流动性、登记回购，会多花约 222 万 gas。

### 7.3 夹子和抢跑

- **夹子**（先买，回购执行，再卖；在同一笔交易里或跨区块都一样）：每步不超过当前有效计价储备的 0.5%，回购把价格推高约 1%，而一买一卖要付约 2% 的手续费，没有利润。复审对四个档位、池子从满到卖掉 99%、抢跑金额从 0.001 倍到 10 倍有效储备做了网格计算，攻击者最好的结果是 −1.2e-5 BNB（把攻击者自己抢跑抬高上限的情况也算进去了）。去掉上限的话，在有效储备接近 V 时一次能赚 0.0056 BNB，所以起作用的是这个上限。第一版只看「b 相对 G」，评审指出池子卖下去之后有效储备会降到接近 V，那时 b/Q 可以到 2.5%；现在按当前储备的比例来定 b，这个问题就没有了。
- **追赶**（评审 M2）：间隔从上一步算起，keeper 停了再恢复，也只能一次一步。
- **按时间表埋伏（评审 M3，用户接受）**：回购的金额和节奏是公开的。没有别人交易时，40 步会在约 5 分钟内把价格推高约 44%；毕业时买入、等回购完再卖，最多能拿走约 75% 的 V（6 档约 0.90 BNB，15 档约 2.25 BNB），代价是扛 5 分钟的市场风险。pump 链上也有这种情况：抽查的 8 笔标准毕业里，有 5 笔在迁移的同一笔交易中被同一个地址用 2 SOL 买入。这笔钱最终付给了毕业后 5 分钟里卖出的人，等于给他们提供了买盘，这正是定时回购的设计目的。另一个选项是「价格不高于毕业价才买」，它能挡住埋伏，但毕业后一直涨的币就迟迟用不到这笔钱。用户 2026-11-22 选了照 pump 定时买。

### 7.4 数字（模拟，`test/proto/gangswap_sim.py`）

没有其他交易，40 步回购全部执行完（每步照付 1% 手续费），然后外面所有人全部卖出：

| 档位 G | V（回购总额） | 回购销毁 | 全部卖完后真实 BNB 剩余 | Pancake V2 的残值 |
|---|---|---|---|---|
| 6 | 1.2 | 约 3,306 万枚 | 0.051 | 1.2 |
| 9 | 1.8 | 约 3,306 万枚 | 0.077 | 1.8 |
| 12 | 2.4 | 约 3,306 万枚 | 0.103 | 2.4 |
| 15 | 3.0 | 约 3,306 万枚 | 0.128 | 3.0 |

另外，最后那笔 8 亿枚卖出的 1% 手续费（800 万枚）也会被销毁。剩余约为 V2 残值的 4%；加上随机交易噪声的模拟，剩余更少（9 档约 0.03 BNB）。评审用整数模型复算了这些数字。

## 8. 不变量

评审写了整数模型，跑了 3,000 条随机序列（买、卖、回购、捐 WBNB、`sync`、`skim`，最后全部卖出），I1、I2、I6 都没有违反。用 `getAmountIn`（9900）对 K 检查跑了 20,000 次 exact-out 报价，没有一次失败。

- **I1 真实储备不为负；所有代币回到池子时，真实储备接近 0。** 设毕业时的有效 k₀ = G × T_pool。因为 V 向下取整，k₀ ≥ V × TOTAL_SUPPLY。只要 k 不变小（I2），而且池子里的代币数 X 不超过总量，有效计价储备就 `≥ k₀ / TOTAL_SUPPLY ≥ V`，所以真实储备 `= 有效 − V ≥ 0`。当所有代币都回到池子、而且没有任何代币被销毁时，真实储备等于 0 加取整误差。
  - **注意（评审）**：如果有人要求的输出落在「真实储备」和「有效储备」之间，转账本身可能成功（会从 `feeAccrued` 里付出去），最后是 K 检查让整笔回滚。所以池子的安全**依赖 K 检查**，不依赖转账失败。
- **I2 k 只增不减。** K 检查和 V2 相同（输入扣掉 1% 之后的乘积 ≥ 原来的 k）。手续费向下取整后拿走，余额正好就是 K 检查里用的那个数，所以 k 只在取整时变大。
- **I3 一个代币只有一个 GangSwap 池子，而且是毕业时建的。** 只有迁移合约能建 pair，只有 pad 能调用迁移合约，而 pad 只在毕业时调用。
- **I4 流动性永远撤不出来。** LP 全在 0xdead 和 0 地址；`mint` 只能调用一次；`burn` 回滚；没有 owner，不可升级。
- **I5 回购最多花 V。** `left` 只减不增；回购合约持有的 WBNB ≥ 所有 token 的 `left` 之和。
- **I6 pair 的 WBNB 余额 = 真实储备 + `feeAccrued`（+ 别人捐的钱，可以 `skim` 走）。** `skim` 和 `sync` 都碰不到 `feeAccrued`。

## 9. 对现有功能的影响

| 合约 | 对类型 4 的币 |
|---|---|
| GangBond（主网，不可升级） | `_padView` 对类型 1 / 2 以外一律回滚 `UnknownToken`，`post` 会调它。这正是我们要的：它的买回销毁按 Pancake V2 的 0.25% 手续费算，在 GangSwap 的 1% 下过不了 K 检查 |
| GangCallBond | `_checkToken` 要求类型 1，缴纳时回滚 |
| 9 个税收模块 | 绑定时都检查 `kindOf != KIND_CURVE`，回滚 |
| GangRouter | 曲线阶段的 `buyFor` / `sellFor` 照常可用。毕业后的 `pool*` 走 Pancake router，**会去成交别人在 Pancake 上建的第三方池子**（复审 N3：它不检查是哪个 pair），也就是 H2 的情况。**已实现**：GangRouter 的四个 `pool*` 在代币或中间那一跳是类型 4 时回滚（`GangSwapToken`），升级是可选的（48 小时时间锁），不是上线前提。**只对 3.0 的 router 有效**：其他 pad 的 router 查的是自己的 pad，不认识类型 4，拦不住；web 和 CLI 也不对类型 4 调用 `pool*`，改走 GangSwapRouter |
| GangPadRegistry、aggregator 入口 | 见 §4 的表；registry 是代理，要升级 |
| GangGateway（线上） | 不认识类型 4：状态 0、报价 0、交易回滚，不会错误路由。它是旧入口，不在上线步骤里 |
| 现有的类型 1 币 | 不受影响。实现时要有回归测试 |
| **第三方池子** | 毕业后代币是普通 ERC-20，任何人都可以拿自己的币去 Pancake 建一个薄池子，LP 不锁。这样的池子可能先被 DexScreener 和 GoPlus 收录（GoPlus 会标「LP 未锁」），把买单引过去；建池的人可以和 GangSwap 套利，或者撤走 LP。合约挡不住这件事，只能通过展示和对外说明处理：我们的 web 和 CLI 只显示 GangSwap 的池子；对行情网站的收录申请里写明 GangSwap 才是官方池子 |

## 10. 安全检查清单

1. fork 出来的文件和 upstream 的 diff 只包含 §6.1 / §6.2 / §6.3 列出的改动。`check-diff.sh` 打印出来由人核对，目前没有自动拦截。
2. `_balances()` 在每一个读余额的地方都用对了：`mint`、`swap`、`skim`、`sync`，以及 `swap` 里的 `INSUFFICIENT_LIQUIDITY` 检查。
3. 输出落在真实储备和有效储备之间时，K 检查必须让整笔回滚（§8 I1 的注意）。
4. 有人往 pair 里直接捐 WBNB 或代币，然后 `sync`：只会改变价格，不能让任何人获利；`skim` 不能转走 `feeAccrued`。
5. 回购：重入（pair 在 `lock` 之下）；间隔从上一步算起；0.5% 上限（用有效储备）；零头并进最后一步；`V` 很小的边界情况（每步至少 `min(left, 0.5% × V)`，最多约 200 步，不会卡住）。
6. 迁移：`V` 的取整方向、`quoteAmount × tokenAmount` 不溢出、`createPair` 不可能被别人抢先、毕业前捐款对初始储备的影响。
7. 手续费合约：伪造 pair 回滚；按余额增加量记账；approve 加 `notifyAccrual` 的流程；bucket 拒收时 creator 那份照常可领。
8. 代币：类型 4 一定无税，`pair` 永远是 0（不调用 `setPair`），所以 GangToken 不会对 GangSwap 的转账收税，也不会做份额同步。
9. 和 pad 里约 33 处类型判断逐条对照（§4）；新的状态码；EIP-170 的大小余量。

## 11. 链下

- **CLI**：`gang create --venue gangswap`；GS 币毕业后的 buy / sell / quote 改走 GangSwapRouter；`gang info` 显示「GangSwap，不在 Pancake 上」、真实流动性，以及回购余额（`left`）。
- **server / 索引**：索引 `GangSwapMigrated`、`Swap`、`Sync`、`FeeTaken`、`BoostStep`；价格用有效储备算，流动性用真实储备算；回购 keeper（§7.2）。
- **web**：币种标签；创建说明和代币页都要提示「毕业到 GangSwap：毕业后约 5 分钟内定时回购销毁；不在 Pancake 上，DexScreener 等网站可能看不到；只认 GangSwap 的池子」。
- **对外对接（上线前要做的商务工作）**：
  - DexScreener、GeckoTerminal：按 V2 分叉提交收录（factory 地址、init code hash、手续费 1%），附上 §6.5 的说明，特别是「流动性看 `realQuoteReserve()`」。
  - KyberSwap、OpenOcean、OKX DEX、Binance Wallet、GMGN：提交接入，附上 §6.5 的说明。
  - GoPlus、honeypot.is：确认它们能识别 GangSwap 的 pair（LP 在 0xdead），以及 `balanceOf < reserve` 会不会被判成异常。

## 12. 测试

- **数学**：
  - 四个档位都跑：毕业 → 回购 → 外面所有人全部卖出，剩余和 §7.4 同一量级；
  - 模糊测试随机交易序列：I1、I2、I5、I6 每一步都成立；
  - 浮点模型在 `test/proto/gangswap_sim.py`，还是第一版的回购规则（固定 `V / 40`、没有上限）。在没有其他交易时，结果和现行规则相同（复审核实）。实现时改写成 forge 测试，并补上 0.5% 上限和零头规则。
- **V2 兼容**：
  - 用 GangSwapRouter，以及一个照 Uniswap V2 Library 写、手续费参数改成 1% 的通用路由，做 exact-in / exact-out 买卖，结果要和 `getAmountsOut` / `getAmountsIn` 一致；
  - `SupportingFeeOnTransferTokens` 的每个函数都测，计价币作为输入的情况尤其要测（H1）；
  - 写几个模仿 1inch、Kyber、0x 执行器的测试（按余额差算输入）：确认按 §6.5 适配后结果分毫不差；不适配时，要靠执行器端到端的最小输出检查回滚。测试要覆盖未领手续费为 0、约等于 V、大于 V 三种情况（复审 N2）。
- **回购**：间隔从上一步算起，停过之后不追赶；0.5% 上限；零头并进最后一步；有人频繁 `sync` 或刷单时回购照常执行；夹子没有利润（按 1% 手续费、几个有效储备水平各算一次）；没有别人交易时 40 步按时买完。
- **diff 测试**：§10 第 1 项。
- **pad 集成**：`createGangSwap`（直接调用和 `createWithSalt` 包装）→ 曲线买卖（包括 aggregator 入口）→ 毕业 → 回购 → 毕业后交易 → 领手续费。所有模块、底仓、金库、保证金对类型 4 都回滚；`getTokenInfo` 报新的状态码。
- **主网 fork**：在主网 fork 上模拟升级 pad 和 registry（线上的 GangRouter、GangGateway 不动），然后跑一个 GS 币的完整流程；同时确认类型 1 的现有币不受影响。
- **测试网**：完整流程，包括 keeper 实际执行回购。

## 13. 部署与上线

1. `forge clean` 之后，用 `gangswap/script/DeployGangSwap.s.sol` 部署：按 nonce 预先算出迁移合约、回购、手续费、factory 四个地址，依次部署，再部署 router。脚本里的检查只在发交易之前的模拟里执行，看不到广播中途失败或 nonce 错位。**广播之后必须对链上地址再跑一次 `check(migrator, router)`**，它直接读链上合约：owner、计价币、`wired()`、手续费合约的 bucket、router 的指向，以及 router 字节码里的 init code hash。然后在 BscScan 和 Sourcify 上验证。
2. 升级 GangPadRegistry（可以和第 3 步同一批）。GangRouter 3.0 的升级（48 小时时间锁）是可选的，不是打开创建的前提；GangGateway 不升级。
3. 升级 pad3 实现：CurveLogic3 是外部链接库，先部署新库，再部署链接它的 GangLaunchpad3、Pad3Module、Pad3GradModule。**这个批次不含 `setGangSwapMigrator`**，`createGangSwap` 此时仍关闭。
4. Safe：迁移合约 `addLaunchpad(pad3)`；`fees.bucket()` 读出来的那个 bucket 执行 `setOperator(GangSwapFees, true)`。
5. 上线 server（索引、keeper）→ web → CLI。
6. **最后单独一个批次 `setGangSwapMigrator`**：设完 `createGangSwap` 就打开了；以后换新版也用它，老币不受影响。
7. 每一步都走「审计 → 修复 → 复审 → 测试网」；主网要用户明确同意。

## 14. 已定事项

用户 2026-11-22 定下：Q1 照 pump 定时买；Q2–Q5 按下表的建议。

| # | 事项 | 决定 |
|---|---|---|
| Q1 | 回购规则（D8） | **已定（用户 2026-11-22）**：照 pump 定时买，40 步、间隔 8 秒、约 5.2 分钟；保留 0.5% 上限、不追赶（同区块限制按复审 N1 删掉） |
| Q2 | 回购要不要付 1% 手续费 | **已定**：付（pair 不用为回购改代码）；代价是 V 的 1% 会作为手续费分给 creator 和平台 |
| Q3 | 毕业后的手续费 | **已定**：1%。买入的 BNB 手续费 70 / 30；卖出的代币手续费销毁。creator 的外盘收入大约是内盘的一半（§2.5） |
| Q4 | 第一期是否允许 Agent 窗口 | **已定**：允许（它只影响毕业前），并加进 `_isCurveCreate`，实现时确认没有交叉影响 |
| Q5 | 其他计价币和带税币 | **已定**：第一期不做，第二期再评估。**其他计价币**（USDT、USDC、USD1、bStocks、ANTB）：这些合规代币大多有黑名单和暂停功能，而 GangSwap 下 pair、回购合约、手续费合约都持有计价币，每个合约都要有被拉黑时的退路，每种币单独检查；web 上「用 BNB 买」要支持先走 Pancake 再走 GangSwap 的两段路由。**带税币**：沿用 `GangToken` 转账收税，`setPair` 指向 GangSwap 的 pair；需要新写一个税处理器（现有的把 Pancake 的 0.25% 写死了，`PostGradHandlerBase.DEX_FEE_NUM = 9975`，在 1% 下切块卖出会一直失败）；税币的代币手续费转进 0xdead 时会被收买入税，要处理；还要考虑税加 1% 手续费的叠加 |

## 15. 第一轮独立评审（2026-11-22）

一份独立评审，对照 Pancake V2 主网源码和仓库代码，写了整数模型和脚本验证。核心数学（I1、I2）成立。

| # | 级别 | 问题 | 处理 |
|---|---|---|---|
| H1 | 高 | 保留下来的 `SupportingFeeOnTransfer` 路由路径，在计价币作为输入时按 `balanceOf − reserve` 算输入，而计价币余额总比有效储备小约 V：小额买入下溢回滚，大额买入少拿币、多付的钱送给下一个卖家（已跑脚本） | §6.3 改用 `quoteBalanceBase()`；§6.5 写明给接入方；§12 加执行器测试；§2.4 不再说「只要配置就能接入」 |
| H2 | 高 | 毕业后报 `STATUS_POOL` 会让现有接入方去 Pancake 交易：要么回滚，要么进了攻击者建的第三方池子 | D11 新状态码；§9 写明第三方池子的风险 |
| M1 | 中 | 「Q ≥ G」不成立，池子卖下去之后 b/Q 可达 2.5%；`step` 谁都能调，同一笔交易里就能夹（已跑脚本） | 按当前储备 0.5% 定步长（第二版另加的同区块限制在第三版删掉，§16 N1） |
| M2 | 中 | 间隔按开始时间算，keeper 停过之后可以每块追一步，埋伏的人能吃掉 37–71% 的追赶金额（已跑脚本） | 间隔从上一步算起 |
| M3 | 中 | 公开的固定时间表：没有别人交易时 5 分钟内价格上涨 44%，毕业时买入、等回购完卖出，能拿走约 75% 的 V（已跑脚本） | 第二版曾改成按价格触发；用户选择照 pump 定时买，接受这一点（§7.3） |
| M4 | 中 | router 在 swap 前顺带回购：正常滑点下的买入会回滚，报价不准，有顺序陷阱，而且挡不住 M1 | 删掉 |
| M5 | 中 | `collect(pair)` 没写要核对 pair，伪造的 pair 可以凭空记账；bucket 是用 `transferFrom` 拉款，不是转给它；引用的 bucket 文件也写错了 | §6.4 |
| L1 | 低 | §7.4 的销毁数字把最后卖出的手续费算进了回购（应为 3,306 万枚） | 已改 |
| L2 | 低 | 「价格和深度与 Pancake V2 完全一样」「手续费和内盘 70 / 30 一致」「每步约占池子 0.5%」都不准确 | §2.2、§2.5、§7.1 已改 |
| L3 | 低 | `Sync` / `getReserves` 显示的流动性比真实的多约 V；`balanceOf < reserve` 可能被某些工具判成异常 | §6.5、§11 |
| L4 | 低 | 假设手续费留在池子里的聚合器，在同一笔交易里对同一个池子下第二笔会报错价 | §6.5 |
| L5 | 低 | `burn` 保留原样会留下一条按原始余额付款的路径；第二期税币的代币手续费转出会被收税 | P6 改为回滚；Q5 |
| L6 | 低 | pad 集成的细节：几处会落到别的分支、两份创建白名单、存储位置 | §4、§5 |
| L7 | 提示 | 毕业前可以往可预测的 pair 地址转 WBNB，会算进初始储备 | §5 第 3.4 步，无害 |

第二版没有复审。§2.3 的 pump 链上数字评审没有复核。

## 16. 第二版复审（2026-11-22）

另一份独立评审，复用并扩展了第一轮的整数模型（夹子网格 `sand2.py`、执行器 `exec.py`）。**结论：第二版通过，没有未解决的高危、严重问题。** H1 的修复在所有 router 路径上都对，0.5% 上限确实让夹子无利可图。修复带出一个中危：

| # | 级别 | 问题 | 处理（第三版） |
|---|---|---|---|
| N1 | 中 | 回购的同区块限制可以被一个免费的 `sync()` 每秒挡住（每天约 0.2–0.4 BNB 就能一直拖住），刷单 bot 也会让它卡住，而且它什么也没多防住 | 删掉（§7.1） |
| N2 | 低 | 「不适配的执行器会失败而不是少给币」不对：输入够大时会悄悄少给 | §6.5、§12 改写 |
| N3 | 低 | GangRouter 的 `pool*` 能交易 GS 币，会去成交第三方 Pancake 池 | §9：web、CLI 不对类型 4 调用 `pool*`；可选升级 GangRouter |
| N4 | 低 | 手续费合约两边绑在一起，bucket 拒收会卡住 creator 那份；没写怎么找到 pad | §6.4：平台那份放 try 里、记待转；迁移时记 `padOf[pair]`；`claim` 先 `collect` |
| N5 | 低 | 状态 4 只对显式判断的接入方起作用；已发布的 CLI 会把类型 4 报成 RPC 错误 | D11 补充；§4 表加 CLI |
| N6 | 低 | 回购最后会多出一步只买几 wei | §7.1 零头规则 |
| N7 | 提示 | `register` 参数前后不一致、7.5 秒写不出、类型判断的数量、P9 的理由、模型版本等措辞问题 | 已逐条改 |
| N8 | 提示 | §4、§5 的集成细节和合约大小余量 | §4、§5 补上 |

复审还确认：

- 每笔都把计价币手续费推出去可以去掉 I1 的那条注意，但接入方仍然要适配虚拟储备，所以不是必须的，保持现在「先记账、后领取」的做法；
- 回购不会卡住资金（最多约 200 步）；
- §7.4 的表在现行规则下不变；
- §6.4 和 bucket 的实际代码一致。

第三版没有再审。

## 17. 实现（2026-11-23）

### 17.1 代码在哪里

- **GangSwap 核心**放在单独的 Foundry 子项目 `gangswap/`。主项目把编译器锁在 0.8.28，而 fork 要保留原版编译器：pair 和 factory 用 `=0.5.16`，router 用 `=0.6.6`。
  - 构建：`forge build --root gangswap`；测试：`forge test --root gangswap`。
  - 原版源码在 `gangswap/upstream/`；改动后的在 `gangswap/src/`；`gangswap/check-diff.sh` 列出相对原版的全部改动（已把重命名归一掉）；`gangswap/sync-init-hash.sh` 重新同步 router 里写死的 init code hash。
  - 部署脚本是 `gangswap/script/DeployGangSwap.s.sol`（§13 第 1 步）。
- **pad 一侧**在主项目里：
  - 新增 `Pad3GangSwapStore`（ERC-7201，`gang.pad3.gangswap`）和 `IGangSwapPad`；
  - `Pad3Module.createGangSwap` / `setGangSwapMigrator` / `gangSwapMigrator`；
  - `CurveLogic3.createGangSwap`，以及 `_graduate` 里的分流；
  - GangLaunchpad3、GangPadRegistry 认类型 4，毕业后报状态 4；
  - GangRouter 的 `pool*` 拒绝类型 4；
  - 新增事件 `GangSwapCreated(token)`，索引方据此区分类型 4。

### 17.2 实现评审

- **核心合约**（一轮）：没有严重、高危问题。
  - M1：router 写死的 init code hash 会因构建环境不同而变。处理：hash 只在仓库自带的配置下生成，由 `sync-init-hash.sh` 同步；测试核对，部署脚本的 `check` 核对链上 router 的字节码。
  - M2：四个合约互相指向的地址没人检查。处理：加了 `wired()`，`addLaunchpad` 和 `setGangSwapMigrator` 都要求它为真。
  - 测试缺口（K 检查、多跳、另一种代币排序、很小的 V、毕业前捐款）都已补上。
- **pad 集成**（一轮）：没有严重、高危、中危问题，现有币的行为不变，存储布局不变。三个低危都已修：
  - `setGangSwapMigrator` 加上 `wired()` 检查；
  - router 在中间那一跳是 GangSwap 币时也拒绝；
  - 新增 `GangSwapCreated` 事件。

  评审补的入口测试已经并入 `test/gang3/Pad3GangSwapEntries.t.sol`。
- **自查**后的优化：
  - 带税的类型 1 币毕业时不再读 GangSwap 存储；
  - `setGangSwapMigrator` 的三项检查合成一个辅助函数；
  - router 的中间跳是 WBNB 时不再调 `kindOf`；
  - 回购合约的类型转换改用 SafeCast；
  - 测试改名、去掉调试日志。

  有一项没有做：把卖出时的代币手续费改成先记账、以后再统一销毁。这样做会让代币一侧也出现「余额 ≠ 储备」，按余额差计算输入的卖出路径又会踩 H1 那类问题；现在每笔卖出多一次转账，几千 gas，换来的是和 V2 一样的余额语义。

- **实现评审之后的改动**（一轮，2026-11-23）：没有严重、高危问题，1 个中危、7 个低危。
  - 中危：部署脚本核对 init code hash 时读的是 router 源码，不能证明部署出来的 router 是对的。改成读链上字节码的 `check`，广播之后再跑一次。在本地链上验证过：篡改的 router 会被拒绝。
  - 低危：脚本检查的时机、手续费 bucket、上线顺序、三处测试缺口、命令写法，都已处理。GangRouter 的拦截只对 3.0 的 router 有效，这一条只写明范围，没有改代码。
  - 没做：`check-diff.sh` 不会自动拦截；`evm_version` 没有固定。

### 17.3 测试

- `gangswap/`：140 / 140 通过（含部署脚本测试；几个套件继承同一组用例，所以其中有重复）。
- 主项目：从干净构建跑的全量（提交 `8384760`）：2,421 通过、0 失败、197 跳过（fork 和需要 RPC 的测试，没跑）。
  - 一次增量编译后，布局测试 `test_layout_flyModuleMirrorsPad` 报过失败：它比对的类型字符串带编译时的节点编号，而 pad 和 Pad3FlyModule 不是同一次编译出来的。`forge build --force` 之后通过（6 / 6）。所以上线前的检查要从干净构建开始跑。

- 主网 fork（`test/fork/Pad3GangSwapFork.t.sol`，6 BNB 档，区块 135213478）：1 通过、0 失败。线上的 GangRouter 和 GangGateway 不升级；覆盖升级 pad 和 registry、打开、曲线买卖、毕业、40 步回购、GangSwapRouter 买卖、手续费进真实 bucket、全部卖回（剩约 0.052 BNB），以及类型 1 旧币照常交易和毕业。部署脚本用真实 WBNB 和 bucket 模拟通过（没有广播）。`8384760` 之后撤掉了 gateway 的改动，主项目全量没有重跑。

### 17.4 还没做

CLI（`KINDS` 加类型 4、`--venue gangswap`、毕业后走 GangSwapRouter、`creatorfee` 覆盖 `GangSwapFees.claim`）、pad3 升级脚本（`UpgradeGangLaunchpad3` 加上 GangSwap 的步骤）、测试网、keeper 的回购循环、server 和 web、对外对接。

