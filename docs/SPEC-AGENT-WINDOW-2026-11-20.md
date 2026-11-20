# 规格 · Agent 专属窗口（GangLaunchpad 3.0 曲线币）

- 日期：2026-11-20（2026-11-21 按正式审计修订，见 §11）
- 状态：**已实现，正式审计的修复待独立复审**。上线前还要完成：独立复审、测试网验收、§6 的链下改动、主网批准。
- 范围：GangLaunchpad 3.0 的曲线币（`KIND_CURVE`）。打新（`KIND_FAIR`）、铸币飞轮（`KIND_FLY`）、2.0 / 1.0 pad 不变。
- 相关源码：
  - `src/gang/Pad3AgentWindowStore.sol`、`src/gang/interfaces/IGangAgentWindow.sol`
  - `src/gang/CurveLogic3.sol`、`src/gang/GangLaunchpad3.sol`、`src/gang/Pad3Module.sol`、`src/gang/Pad3GradModule.sol`、`src/gang/Pad3GradStore.sol`
  - `src/gang/GangPadRegistry.sol`
  - `script/UpgradeGangLaunchpad3.s.sol`
- 测试：`test/gang3/Pad3AgentWindow.t.sol`、`test/fork/Pad3AgentWindowFork.t.sol`。

## 1. 一句话

dev 发币时可以带一个 **agent 专属窗口**（分钟数）：

- **窗口内**：只有持 Agent ID 的钱包能在曲线上买卖，1% 钱包上限照旧，和现在一样。
- **窗口结束后**：**同一条曲线**对所有钱包开放（包括合约），1% 上限取消。聚合器上的普通用户可以直接买，入口包括 GangGateway、GangPadRegistry 和 pad3 自带的 four.meme 式入口。

毕业规则不变，仍按创建时选的深度目标（6 / 9 / 12 / 15 BNB）开 PancakeSwap 池。

## 2. 为什么

- 曲线本身有虚拟流动性，第一天就能交易。缺的不是深度，是买家。
- agent 专属把买家限制在持 Agent ID 的钱包，需求少，深度目标难达到。
- 聚合器已经接入了我们的 pad（README 里的 GangPadRegistry、GangGateway），但 gate 检查的是交易者本人：没有 Agent ID 的用户在聚合器上能看到币，买不了，报价为 0。
- 现在的 gate 只有一个全局开关 `agentGateEnabled`（`PadCommon.isAgent`），不能按币、按时间放开。

窗口把「agent 先进场」变成一个有期限的优先权：agent 拿到的是时间上的先手和低价筹码，不是永久的围墙。和「按时间强制毕业」比，这样不会产生浅池，「毕业」的含义也不变。

## 3. 规则

| 项 | 规则 |
|---|---|
| 默认 | 不带窗口 = 永远 agent 专属，和现在完全一样 |
| 怎么设 | **发币时作为参数带上**：`createWithAgentWindow(windowMinutes, 发币调用)`，一笔交易完成（§5.2）。买家进场前规则就是公开的，creator 不能先低价买够、再临时宣布开放 |
| 谁来设 | 发币的 creator 本人；发币本来就要求持 Agent ID |
| 设什么 | `windowMinutes`：从创建时刻起多少**分钟**后开放。`openAt = 创建区块时间 + windowMinutes × 60` |
| 时长范围 | 按分钟设，**1 – 1440 分钟**（1 分钟到 24 小时）之间的任意整数（`MIN_AGENT_WINDOW_MINUTES` / `MAX_AGENT_WINDOW_MINUTES`） |
| 已有的币 | 不能补设，一直是 agent 专属 |
| 开放判定 | `openAt != 0 && block.timestamp >= openAt` |
| 只进不退 | 写入后谁都改不了、撤不了，包括 creator 和 owner。开放后一直开放，否则窗口后买入的普通钱包会卖不出去 |
| 开放后谁能交易 | 任何钱包，包括合约，在所有曲线入口买卖：`buy` / `sell`、`buyFor` / `sellFor`、`buyTokenAMAP`、两个 `sellToken`、`buyWithPromoter`。只有这个币自己的 vault 仍不能交易它（`_checkCurveTrader`，不变） |
| 不要求本人发交易 | 直接 `buy` / `sell` 的交易者是 `msg.sender`，开放后合约也能买，一个合约可以在一笔交易里买下剩余曲线。**有意不拦**，理由有三：<br>1. 窗口期 agent 已经拿到了低价筹码；<br>2. 开放后的大额买入是按曲线价真金白银买的，抬的是 agent 持仓的价格；<br>3. 毕业时池价和曲线末价连续，同一笔交易里买到毕业再砸进新池不赚钱 |
| 聚合器入口 | 仍然只替发起交易的钱包本人交易（`trader == tx.origin`，§23），不变 |
| 1% 钱包上限 | 窗口期照旧。开放后**对所有钱包、所有币取消**，包括 agent 和带冲毕业奖励的币。原因：开放后上限只按地址算，而合约地址可以随便开，留着上限挡不住任何人，只会截断普通用户的大单（审计 B M-1，§11） |
| pad 级开关 | `agentGateEnabled`、`walletCapEnabled` 仍是总开关。owner 关掉 gate 时所有币对所有人开放（现状），关掉上限时所有币都不限（现状）。总开关开着时，才按每个币判断 |
| 毕业 | 不变：募满创建时的目标即毕业，和窗口无关。没到 `openAt` 也照常毕业；毕业后在 PancakeSwap 本来就人人可交易 |

## 4. 开放后仍然只认 Agent ID 的地方

窗口只放开「谁能在曲线上买卖」和 1% 上限。下面这些防刷、防女巫的规则继续按 pad 级 `isAgent(account)` 判断，不看窗口：

| 位置 | 规则 | 为什么 |
|---|---|---|
| 创建（`CurveLogic3.create` 的 `_requireAgent(c, msg.sender)`） | creator 必须持 Agent ID | agent 专属发射台的定位 |
| 冲毕业奖励（`Pad3GradStore.onBuy`） | 只有**持 Agent ID 的钱包**的买入计入名单 | SPEC-GRAD-REWARD §2：gate 关闭时合约钱包能随意刷名额，所以不计入。窗口开放后同理 |
| 推广分成的绑定（`_bindable` / `canBind`） | 被绑定的钱包和推广人都必须持 Agent ID | 绑定是永久的，还要分走 creator fee；普通钱包可以开小号绑自己，变相返佣 |
| vault 锁仓 / 释放（`_vaultEntry`） | 用户必须持 Agent ID | 不在本期范围。vault 币开放后买入的普通钱包锁不进 partner vault，页面要写明。另外开放后上限取消，单个 agent 可以买超过 1% 再锁进 vault；合作方的 vault 如果按「每人最多 1%」设计奖励，上线前要和合作方确认 |
| 模块工厂（Split / Countdown / Floor / Capped / PromotePool / Combo / Buyback / LiquiditySplitter 的 `IGangPad(pad).isAgent(msg.sender)`） | 不变 | 管的是建模块的人，不是曲线交易 |
| 打新、铸币飞轮（`FairLogic`、`Pad3FlyModule.checkConfig`） | 不变 | 不在本期范围；`createWithAgentWindow` 不接受它们（§5.2） |
| base 币的 `buyBase` | 不变 | 本来就不过 gate |

注意：

- **冲毕业奖励的计入。** 原来 `onBuy` 传的是 `c.agentGateEnabled`；gate 开着时，交易者一定是 agent。现在改为在 `onBuy` 里、确认奖励是 `ACTIVE` 之后，只对已开放的币再判断 `isAgent(trader)`。没有冲毕业奖励的币，每笔买入不多一次外部调用；没设窗口的币，行为逐笔不变。
- **毕业那一笔是普通钱包买的。** 这一笔不计入名单，`lastBps` 给名单里最后一格有效的 agent 买入，沿用 SPEC-GRAD-REWARD 里「门槛关闭期间毕业」的语义。
- **冲毕业奖励可能被一个大户拿走（接受的经济机制，E-4）。** 开放后，一个人可以先用合约小号把曲线推到快毕业，再用自己的一个 Agent ID 连买几笔占满名单，然后拿下毕业那一笔。窗口期就进场的 agent 可能分不到奖池。
  - 对 dev 来说，这正是冲毕业奖励要的结果：有人真金白银把币推到毕业，种子钱照常花出去，creator fee 不少。
  - 一个人占满名单本来就可能（名单按买入计、不按人计，SPEC-GRAD-REWARD G-2）。开放后的区别只是：他可以自己推，不用等别人把币推到快毕业。
  - 因此不做互斥，也不对这类币保留上限：审计证明保留上限挡不住小号，只会截断普通用户的大单。页面要写明这一点。
- **推广绑定。**
  - `canBind` 原本就检查钱包本人是 agent；`buyWithPromoter` 用的 `_bindable` 只检查推广人，钱包本人靠后面 `CurveLogic.buy` 的 gate 拦（不是 agent 就整笔回滚，绑定一起撤销）。
  - 窗口开放后这层拦不住了，所以 `_bindable` 加上了 `PadCommon.isAgent(_config, wallet)`（`canBind` 去掉重复的那次检查）。
  - 加上之后，普通钱包走 `buyWithPromoter` 照常买入，只是不绑定，和「不合格的推广人」一样，交易不失败。

## 5. 合约改动

### 5.1 存储

新增 ERC-7201 命名空间 `Pad3AgentWindowStore`（`gang.pad3.agentwindow`，`SLOT = 0xc114…d300`）。和其他 `Pad3*Store` 一样，成员只往末尾追加：

```solidity
struct Layout {
    mapping(address token => uint40) openAt;   // 0 = never (agent only); written once, at the token's create
}
```

正在创建的窗口不进存储，只放在 **transient 存储**里（`PENDING_TSLOT = keccak256("gang.pad3.agentwindow.pending")`，值为 `creator | minutes << 160`），只在这一次 `createWithAgentWindow` 调用内有效：

- 不会留到以后的发币上；
- 交易回滚时一起丢掉。

不动 `Curve` 结构体和 `_config`，所以 `curves()` 的布局，以及 indexer 和聚合器对 `curves` 的解码都不变。

### 5.2 发币入口和视图（由 `Pad3GradModule` 提供，经 `Pad3Module` 的 `_isAgentWindow` 转发）

```solidity
function createWithAgentWindow(uint16 windowMinutes, bytes calldata data) external payable returns (address token);

function agentOpenAt(address token) external view returns (uint40);       // 0 = never
function agentWindowOpen(address token) external view returns (bool);     // openAt != 0 && now >= openAt
function canTradeCurve(address token, address account) external view returns (bool);
// = account is not the token's vault &&
//   (!agentGateEnabled || agentWindowOpen(token) || (account != address(0) && isAgent(account)))
// account == address(0)（「一个新钱包」）: 只看 gate 和窗口，不对 0 地址调 isAgent
function walletCapOn(address token) external view returns (bool);         // walletCapEnabled && !agentWindowOpen

uint16 public constant MIN_AGENT_WINDOW_MINUTES = 1;
uint16 public constant MAX_AGENT_WINDOW_MINUTES = 1440;   // 24 hours

event AgentWindowSet(address indexed token, uint40 openAt);

error BadAgentWindow();        // windowMinutes not in 1..1440
error BadAgentWindowCall();    // data is not a curve create entry or createWithSalt
error AgentWindowNotUsed();    // the call made no curve token for the caller
```

`createWithAgentWindow` 和现有的 `createWithSalt` 是同一种写法：

1. 检查 `windowMinutes` 在 1 – 1440 内，否则回滚 `BadAgentWindow`。
2. 检查 `data` 的 selector 是 6 个曲线发币入口之一（`create`、`createWithGradTarget`、`createWithVault`、`createWithPromote`、`createWithBase`、`createWithGradReward`），或者是 `createWithSalt`，否则回滚 `BadAgentWindowCall`。打新、交易函数、`createWithAgentWindow` 自己、过短的 data 都会被拒。
3. 在 transient 存储里记下 `(msg.sender, windowMinutes)`。
4. 对 proxy 自己 `delegatecall(data)`：`msg.sender`、`msg.value` 不变。被调用入口的所有检查、重入锁和事件照常执行，失败就把原因原样抛出。
5. 两份 `_createCurve`（`GangLaunchpad3` 和 `Pad3Module`，两者逐行一致）建好币之后调用 `Pad3AgentWindowStore.consume(creator, token)`：transient 里记的 creator 就是这个币的 creator 时，取走窗口，写 `openAt[token]`，清空 transient，发 `AgentWindowSet`。
6. 调用结束后，transient 里还有没用掉的窗口，或者返回的 token 没有 `openAt`，就回滚 `AgentWindowNotUsed`。比如 `createWithSalt` 里面包的是打新或飞轮的发币调用，不会产出曲线币。

主网开了 vanity，直接发币会被拒，所以主网的用法是两层嵌套：`createWithAgentWindow(分钟数, createWithSalt(salt, 曲线发币调用))`。`createWithSalt` 本身也是 delegatecall，`msg.sender` 仍是 creator。

到 `openAt` 那一刻没有事件（没有交易触发）。indexer 和网站按 `AgentWindowSet` 里的 `openAt` 自己按时间判断。

### 5.3 交易路径（`CurveLogic3`）

把「交易者必须是 agent」改成按币判断：

```solidity
function canTrade(IGangLaunchpad.Config storage c, address token, address trader) internal view returns (bool) {
    if (!c.agentGateEnabled || Pad3AgentWindowStore.isOpen(token)) return true;   // open: any wallet, no external call
    return PadCommon.isAgent(c, trader);                                           // in the window / never open: as today
}
```

| 位置 | 改前 | 改后 |
|---|---|---|
| `buy`（`_requireAgent(c, trader)`） | pad 级判断 | `_requireTrader` → `canTrade(c, token, trader)`，不通过回滚 `NotAgent` |
| `sell`（`_requireAgent(c, trader)`） | pad 级判断 | 同上 |
| `quoteBuy`（`trader != address(0) && …`，不合格返回 0） | pad 级判断 | **保留 `trader != address(0)` 的短路**（0 地址 = 新钱包，不检查），其余换成 `canTrade` |
| `create`（`_requireAgent(c, msg.sender)`） | pad 级判断 | **不变** |
| `Pad3GradStore.onBuy(..., c.agentGateEnabled)` | gate 开关 | 改为传入 `c`，只对已开放的币、在 `ACTIVE` 之后判断 `isAgent(trader)`（§4） |

`PadCommon` 是 2.0 和 3.0 共用的库，不往里加读 3.0 存储的函数。`canTrade` 和 `walletCapOn` 只放在 `CurveLogic3`（internal，内联进 pad 和模块）。

### 5.4 1% 上限按币判断

```solidity
function walletCapOn(IGangLaunchpad.Config storage c, address token) internal view returns (bool) {
    return c.walletCapEnabled && !Pad3AgentWindowStore.isOpen(token);
}
```

所有读上限的地方都只用这一份定义：

| 位置 | 用途 |
|---|---|
| `CurveLogic3._prepBuy` | 实际买入的上限和截断 |
| `CurveLogic3.quoteBuy` | pad3 自己的报价（pad3 的 `tryBuy` 走这里） |
| `GangLaunchpad3.walletRoom(token, buyer)` 视图 | 对外的剩余额度 |
| `walletCapOn(token)` 视图 | 对外说明这个币当前有没有上限 |

GangPadRegistry 读的是 pad 的 `walletCapEnabled()` 和 `walletRoom()`。pad 的 `walletRoom` 对不限的币返回 `type(uint256).max`，所以 registry 的上限逻辑不用改。

### 5.5 不改的检查

- `RouterNeedsGate`（`buyFor`、`buyTokenAMAP`、`buyWithPromoter`、`setRouter`）仍要求 pad 级 gate 开着。审计 A-2 担心的是 gate 关闭时 router 能替任意地址买入，比如替未来的 pair 买。现在 gate 一直开着，窗口只放开交易者的身份，router 仍然只能替 `tx.origin` 交易，A-2 的前提不变。
- `GangGateway._buyOpen` 只看 pad 级 gate 和 router 名单，不用改。
- TWAP 价格保护、毕业逻辑、`_checkCurveTrader`（vault 不能交易自己的币）都不变。
- 曲线上的代币在毕业前不能转出（`GangToken` 的 `locked`），开放后合约钱包也没法往未来的 pair 里塞币。

### 5.6 GangPadRegistry（代理，需要升级）

registry 的 `_curve` 被 `previewBuy` 和 `previewSell` 共用，原来用 pad 级 `p.isAgent(trader)` 判断。改成：

- 保留 `trader != address(0)` 的短路；
- 其余情况调用 `_passesGate`：用底层 `staticcall` 问 pad 的 `canTradeCurve`。返回值是一个 0 或 1 的 word 就用它；否则（pad 没有这个函数而回滚，或者返回值不合规）回退到 `isAgent`。用底层调用而不用 try/catch，是因为返回值解码失败时 try/catch 会让整个报价回滚。

已登记的各代 pad 都会正确回退：2.0 `GangLaunchpad` 和 `GangVaultLaunchpad` 没有 fallback；`GangFlywheelPad` 只有 `receive`；升级前的 pad3 会经过 `Pad3Module` → `Pad3FlyModule` 回滚。所以 pad3 和 registry 谁先升级都可以。推荐放在同一个 Safe 批次里，先 pad 后 registry（§9）。

受影响的是 GangGateway 的 `tryBuy`（曲线分支走 `registry.previewBuy`）和直接调 registry 的聚合器。pad3 自己的币在 pad3 的 `tryBuy` 里走 `quoteBuy`，不经过 registry；`LegacyRoute.tryBuy` 只报其他 pad 的币。币自己的 vault 由 `canTradeCurve` 返回 false，registry 不会给它报价（审计 B L-1）。

### 5.7 实现注意

- **合约大小。** 新增的入口和视图如果放在 `Pad3Module`，`Pad3Module` 会只剩 359 字节余量，所以放在了 `Pad3GradModule`（它本来就是为 24KB 限制拆出来的）。实测大小见 §11。
- **外部库。** `CurveLogic3` 是外部库，pad3 impl 链接的是它部署后的地址。`UpgradeGangLaunchpad3` 每次运行都用本次编译的代码重新部署库，`_checkImplCode` / `_checkLibs` 逐字节比对 impl 和它链接的库。签名前还要人工确认新库已经在链上（§9）。
- **两份 `_createCurve`。** `GangLaunchpad3` 和 `Pad3Module` 的 `_createCurve` 都调用 `consume`，并且保持逐行一致（`test/gang3/Pad3Vault.t.sol` 比对两者的记录）。
- **TOKEN_VERSION 仍是 1。** 没设窗口的币行为不变，带窗口是创建时的一个选项（和 vault、推广分成一样）。indexer 靠 `AgentWindowSet` 区分。

## 6. 链下规则必须补 Agent ID 检查

今天曲线上的每个交易者都持 Agent ID，不少链下规则默认了这一点。开放后这个默认不再成立。凡是按「曲线买入」计数、发奖或结算的规则，都要在**买入所在区块**检查 `isAgent(trader)`，否则可以用无成本的小号刷：

| 规则 | 不补的后果 |
|---|---|
| 喊单保证金的跟单赔付（`docs/SPEC-AGENT-CALLS-2026-11-09.md` §「跟单买入」，现在只要求 `trader == tx.from`） | 喊单者开一批新钱包跟单，然后自己砸盘违约。小号的亏损是真的，但这些钱已经通过砸盘回到喊单者手里，小号还能再领走最多 49% 的赔付池，违约成本大约减半 |
| 喊单本身（`GangCallBond.post` 只检查持仓，不检查喊单人是不是 agent，审计 B L-2） | 开放后没有 Agent ID 的合约也能押喊单保证金。喊单区收录和结算时要检查喊单人本人是 agent |
| 所有按曲线买入计名额或计分的活动（入帮、钱包合作活动、发射日等） | 小号刷名额、刷奖励 |
| 热榜、成交排行、徽章、持有人数 | 刷量、刷持有人数。开放后的币，「持有人数」应分开显示 agent 和非 agent |

这些规则的改动在各自的仓库和规格里做。本 spec 上线前，要逐个确认已经补上，或者确认它们不会把开放后的币计进去。

## 7. 风险

### 7.1 合约层面

| # | 风险 | 处理 |
|---|---|---|
| R-1 | **合约当交易者是新输入面。** 主网 gate 从没关过，开放后是合约第一次能在曲线上买卖 | 正式审计 A / B 已查（§11）：<br>• 所有入口都有 `nonReentrant`；<br>• 退款和卖出所得只用报价币 ERC-20 结算；<br>• 五种上架报价币没有转账钩子；<br>• 分红是持有人自己领取（pull）；<br>• TWAP 同一笔交易里凑不出来 |
| R-2 | **上限漏改导致报价不一致** | §5.4 一份定义；§8 有逐 wei 对齐测试 |
| R-3 | **`_bindable` 漏补导致普通钱包被永久绑定** | 已补，§8 有测试 |
| R-4 | **升级。** pad3 impl（连同 `CurveLogic3` 库）和 registry 都要升级 | 新命名空间、SLOT 和成员位置由测试固定；不需要 reinitializer，新存储默认 0 = 不开放；registry 和 pad 在同一个批次里，由脚本自检（§9） |
| R-5 | **回滚会困住普通钱包**（审计 C M-2） | 见 §9.4：只前滚修复，不回滚 |

### 7.2 要在页面上讲清楚的经济机制（不算漏洞）

| # | 机制 | 怎么披露 |
|---|---|---|
| E-1 | **开放那一刻是可以预期的卖点。** 窗口期的 agent 拿着低价筹码，等普通用户进来时卖给他们。这就是「agent 先进场」的设计 | 币详情页显示开放时间，以及窗口期买入的持仓占多少（按 `AgentWindowSet` 和交易事件计算） |
| E-2 | **开放那个区块可能被一笔买光。** 上限取消后，一个合约可以在 `openAt` 当个区块买下剩下的整条曲线 | 「至少 80 个钱包才能毕业」对开放后的币不成立，网站和文案不要再这么说 |
| E-3 | **creator 自己推毕业更便宜。** creator 的交易里，有 70% 的手续费会作为 creator fee 返回给 creator 自己，净费率约 0.3%。这一点现在就成立，取消上限后一个人推到毕业更容易 | 页面标出 creator 的持仓和买入 |
| E-4 | **冲毕业奖励可能被一个大户拿走**（§4）。普通钱包推毕业时，`lastBps` 给最后一格有效的 agent；一个人也可以用合约小号推到快毕业，再用一个 Agent ID 占满名单 | CLI 和网站的冲毕业奖励说明写上：「开放后，奖池可能被一个大户推到毕业拿走」 |
| E-5 | **vault 币开放后买入的普通钱包不能锁仓** | vault 币页面写明 |

## 8. 测试

- `test/gang3/Pad3AgentWindow.t.sol`（单元测试）：
  - **存储**：SLOT 等于 ERC-7201 的计算结果；`openAt` 是命名空间的第一个成员（`vm.load` 读原始槽）。
  - **`createWithAgentWindow`**：
    - 时长 1 和 1440 通过，0、1441、`type(uint16).max` 回滚；
    - 只接受曲线发币入口和 `createWithSalt`：打新、交易函数、自身、过短的 data 都回滚 `BadAgentWindowCall`；
    - 入口自身的检查照常执行（非 agent creator 被拒）；
    - 写入一次之后，同一交易里后面的发币（creator 自己的或别人的）都不带窗口；
    - `createWithGradTarget`、`createWithPromote`、`createWithGradReward`、`createWithVault` 都能带窗口；
    - 开了 vanity 时，套 `createWithSalt` 的曲线币能拿到窗口；套 `createWithSalt` 的打新币回滚 `AgentWindowNotUsed`（不套时同样的调用能成功）。
  - **gate**：
    - 不带窗口的币永远 agent 专属；
    - `openAt` 前一秒仍拒绝，当秒起放行，买入后能卖出；
    - 开放后所有入口放行（`buyTokenAMAP`、`sellToken`、router `buyFor`）；
    - 窗口期内所有入口拒绝普通钱包（`sell`、`buyTokenAMAP`、`buyFor`、`sellFor`、`sellToken`、`buyWithPromoter`）；
    - 合约钱包开放后能买卖；
    - pad 级 gate 关闭时人人可交易。
  - **上限**：
    - 窗口期内生效，开放后取消；
    - pad 级开关关闭时都不限；
    - 一个钱包、或一笔交易里一批合约，都能买到毕业，毕业和池子正确；
    - 实际成交、pad 报价、`walletRoom`、registry 报价逐 wei 一致；
    - 带冲毕业奖励的币开放后同样取消。
  - **0 地址**：`quoteBuy`、`canTradeCurve`、registry 的 `previewBuy` 都不对 0 地址调 `isAgent`（`vm.expectCall` 次数为 0）。
  - **vault**：开放后，`canTradeCurve(token, vault)` 为 false，registry 和 pad 都不给 vault 报价，vault 买入回滚 `VaultCannotTrade`。
  - **冲毕业奖励**：开放后只有 agent 的买入计入名单；普通钱包推到毕业时，名单里唯一的 agent 拿到整个奖池并能领取。
  - **推广分成**：开放后普通钱包能买入、不会被绑定，`canBind` 为 false；agent 照常绑定。
  - **升级脚本的 `_checkAgentWindow`**（harness）：第一次升级时老币没有窗口；以后升级时比较前后状态，状态不同就拒绝。
- `test/fork/Pad3AgentWindowFork.t.sol`（主网 fork，需要归档 RPC 和 `--libraries` 链接主网 PoolCheck）：
  1. 带 `PAD3_REGISTRY_UPGRADE` 跑升级脚本：部署 pad 和 registry 的新实现，并完成自检和模拟。
  2. 用部署好的地址只读重跑一次，取出它打印的 Safe 批次：只有两笔，先 pad 升级，后 registry 升级。
  3. 以 Safe 身份原样执行这个批次：pad 只改动 implementation 槽；registry 已登记的每个 pad 的最新币，普通钱包和 agent 拿到的报价都和升级前一样。
  4. `createWithAgentWindow(createWithSalt(...))` 发一个币：窗口期内普通钱包被拒、agent 受 1% 上限；开放后普通钱包能买超过 1%，成交和 registry 报价一致；一笔推到毕业，进入真实的 Pancake 池子。
- 现有测试：`Pad3Parity`、`Pad3EntryParity`、`Pad3PromoteParity`、`Pad3GradReward`、`GangLaunchpad3Layout` 等全部照过。

## 9. 上线

### 9.1 顺序

1. 正式审计的修复 → 独立复审（§11）。
2. 测试网：
   - 用 `UpgradeGangLaunchpad3` 带 `PAD3_REGISTRY_UPGRADE=true` 升级 pad3 impl（连同 `CurveLogic3`）和 registry；
   - 跑验收：带窗口发币；开放前后用普通钱包从聚合器入口买卖；开放后一个钱包大额买到毕业；带冲毕业奖励的币开放后只计 agent。
3. 链下规则（§6）逐个补上 Agent ID 检查，**在主网升级之前**完成。
4. 主网：Safe 签一个批次（先 pad 升级，后 registry 升级），需要明确批准。
5. CLI、网站、indexer、聚合器通知（§9.3）。

### 9.2 主网签名前后要核对的

- **签名前**：
  - 用部署好的地址（`PAD3_IMPL`、`PAD_REGISTRY_IMPL`、飞轮依赖）只读重跑脚本，拿到批次 JSON，记下它的 SHA-256 并归档到 `docs/`；
  - `cast code` 确认新 `CurveLogic3`（以及地址变了的 `FairLogic`、`LegacyRoute`）在链上有代码，并且和 artifact 一致（metadata 除外）；
  - 在 BscScan 验证所有新合约：pad impl、`Pad3Module`、`Pad3GradModule`、`Pad3FlyModule`（若有新部署）、`CurveLogic3`、registry impl；
  - 用这个 JSON 跑一遍 fork 演练。
- **执行后**：
  - 读回 pad 和 registry 的 implementation 槽、`module()`、`gradModule()`；
  - 确认最新的老币 `agentOpenAt == 0`，并且 `walletCapOn` 和总开关一致；
  - 发一个测试窗口币，或者等第一个真实的窗口币，核对报价和交易。

### 9.3 配套

- **CLI**：
  - 创建时加 `--agent-window <分钟>`（1 – 1440）。带这个参数时，把原来的发币调用（主网是 `createWithSalt(...)`）包进 `createWithAgentWindow(分钟数, …)`，一笔交易发出；
  - `gang info` 显示 `openAt`、剩余时间、当前有没有上限。
- **网站**：
  - 币详情页显示「agent 专属，X 后对所有人开放」或「agent 专属」，以及 §7.2 要披露的内容；
  - 列表可按「即将开放」排序。
- **indexer**：记录 `AgentWindowSet`；需要时用 `agentOpenAt` 补数。
- **聚合器**：通知已接入的聚合器。开放后的币普通钱包可以交易，按 `canTradeCurve` 判断；剩余额度按 `walletRoom` 判断，开放后不限。

### 9.4 回滚：只前滚修复，不回滚（审计 C M-2）

- **后果**：如果把 pad 回滚到升级前的实现，旧代码不认 `openAt`，已经开放的币会重新变成只有 agent 能交易。开放后买入的普通钱包在曲线上卖不出去；毕业前代币又是 `locked` 的，转不走，资金就被困住了。
- **做法**：出问题时，修好后**前滚**升级到修复版，不回滚。新命名空间里的 `openAt` 在前滚后继续生效。
- **registry 单独回滚**：只影响报价（普通钱包在开放后的币上拿到 0 报价），不影响 pad 上的交易，也不困住资金。

## 10. 决定记录

| # | 问题 | 状态 |
|---|---|---|
| Q1 | creator 怎么设窗口 | **已定**：发币时作为参数，`createWithAgentWindow(分钟数, 发币调用)` 一笔交易完成；不设就永远 agent 专属。已有的币不能补设。（原来是「先登记、下一次发币时写入」，审计 A 指出登记会留到以后的币上，2026-11-21 改为参数，§11） |
| Q2 | 时长范围 / 档位 | **已定**：按分钟设，1 – 1440 分钟之间任意整数 |
| Q3 | 冲毕业奖励在开放后 | **已定**：名单只认 Agent ID；上限和其他币一样取消；接受「奖池可能被一个大户拿走」这个经济机制（§4、E-4）。不做互斥 |
| Q4 | 推广绑定在开放后 | 采用草稿默认：只绑 Agent ID 钱包 |
| Q5 | 1% 钱包上限在开放后 | **已定**：对所有钱包、所有币取消 |
| Q6 | 平台能不能统一设置 | **已定**：不做平台默认，只有 creator 能设；合约里不给 owner 加任何窗口相关的权限 |
| Q7 | creator 能不能承诺「永远 agent 专属」 | 不带窗口就是永远 agent 专属，之后谁都改不了，**不需要单独的放弃函数** |

不在本期：毕业门槛随时间下降、按时间强制毕业。窗口上线后，看开放后的成交和毕业率，再决定要不要做。

## 11. 审计记录

### 11.1 实现前后的审阅（2026-11-20）

- spec 两轮独立审阅：第一轮对照代码核对 gate 站点；第二轮对抗性审阅「合约当交易者」和「开放后取消 1% 上限」。
- 实现后一轮代码审阅，加一轮修复复审。复审新发现一个 low：升级自检在有币设了窗口之后，会挡住以后的升级。已改为比较升级前后的状态。

### 11.2 正式审计（2026-11-21，三个独立审计，各管一个范围）

| 范围 | 结论 | 发现 | 处理 |
|---|---|---|---|
| A：曲线核心（gate、上限、写入、存储、路由） | 无 critical / high / medium | L：登记的窗口没有有效期，会被 creator 的下一个曲线币（含 vault、base 币）带上 | **改设计**：去掉登记，改为一笔交易的 `createWithAgentWindow`，窗口只放在 transient 存储里（§5.2） |
| B：集成（冲毕业奖励、推广、vault、registry、gateway、模块） | 无 critical / high | **M-1**：带冲毕业奖励的币开放后，保留 1% 上限挡不住合约小号，一个 Agent ID 加一批合约就能拿走奖池（PoC 已复现） | 经讨论，奖池被大户拿走对 dev 无害，接受为经济机制；同时去掉这类币「保留上限」的特例（§4、E-4、Q3、Q5） |
| | | L-1：开放后 registry 会给币自己的 vault 报价，pad 实际会拒绝 | `canTradeCurve` 对币自己的 vault 返回 false；有测试 |
| | | L-2：`GangCallBond.post` 不检查喊单人是 agent | 链下处理，写进 §6 |
| C：升级和部署路径 | 无 critical / high | **M-1**：registry 升级没有脚本，也没有代码校验 | `UpgradeGangLaunchpad3` 加 `PAD3_REGISTRY_UPGRADE`：部署或校验 registry impl（本次编译、已锁死、ProxyAdmin 属于同一个 Safe），模拟升级后跑 `GangPadRegistryDeployLib.check`，比较每个已登记 pad 最新币的 `padOf` 和新钱包报价，并把升级放进同一个批次的最后 |
| | | **M-2**：spec 没写回滚，回滚会困住普通钱包 | §9.4 |
| | | **M-3**：fork 测试没覆盖打印的批次和老 pad 的报价 | fork 测试改为取脚本打印的批次原样执行，并比较每个 pad 最新币的报价（§8） |
| | | L：签名前要确认新库在链上；命名空间成员顺序没被测试固定；spec §8 列了没做的升级测试 | §9.2；新增 `test_slot_openAtIsTheFirstMember`；§8 改为实际的测试 |

另外三份审计都核实为没问题的部分：

- 开放前无法绕过 gate；
- `openAt` 写入后不能改，也不能替别人设；
- 没设窗口的币行为和 main 一致；
- 不受上限时记账正确（1000 轮 fuzz）；
- 没有新的重入或回调风险；
- selector 没有冲突；
- 存储槽正确；
- 直接调用模块实现合约无害；
- registry 对每一代 pad 都能正确回退。

这次修复改了合约逻辑（发币入口、上限规则、vault 报价），需要再做一轮独立复审，之后才能上测试网。
