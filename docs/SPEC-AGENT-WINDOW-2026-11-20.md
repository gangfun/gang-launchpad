# 规格 · Agent 专属窗口（GangLaunchpad 3.0 曲线币）

- 日期：2026-11-20
- 状态：**规则已定稿，待实现**；未正式审计，未写代码。已做两轮独立审阅：第一轮对照代码核对 gate 站点；第二轮对抗性审阅「合约当交易者」和「开放后取消 1% 上限」。意见都已并入。决定记录见 §10。
- 范围：GangLaunchpad 3.0 的曲线币（`KIND_CURVE`）。打新（`KIND_FAIR`）、铸币飞轮（`KIND_FLY`）、2.0 / 1.0 pad 不变。
- 相关源码：`src/gang/CurveLogic3.sol`、`src/gang/Pad3Module.sol`、`src/gang/GangLaunchpad3.sol`、`src/gang/GangPadRegistry.sol`、`src/gang/Pad3GradStore.sol`。

## 1. 一句话

dev 发币前可以给它定一个 **agent 专属窗口**：窗口内只有持 Agent ID 的钱包能在曲线上买卖，1% 钱包上限照旧，和现在一样。窗口结束后，**同一条曲线**对所有钱包开放（包括合约），1% 上限取消（带冲毕业奖励的币除外）。聚合器上的普通用户可以直接买（GangGateway、GangPadRegistry、pad3 自带的 four.meme 式入口）。

毕业规则不变，仍按创建时选的深度目标（6 / 9 / 12 / 15 BNB）开 PancakeSwap 池。

## 2. 为什么

- 曲线本身有虚拟流动性，第一天就能交易，缺的不是深度，是买家。
- agent 专属把买家限制在持 Agent ID 的钱包，需求少，深度目标难达到。
- 聚合器已经接入了我们的 pad（README 里的 GangPadRegistry、GangGateway），但 gate 检查的是交易者本人。没有 Agent ID 的用户在聚合器上能看到币，买不了，报价为 0。
- 现在的 gate 只有一个全局开关 `agentGateEnabled`（`PadCommon.isAgent`），不能按币、按时间放开。

窗口把「agent 先进场」变成一个有期限的优先权：agent 拿到的是时间上的先手和低价筹码，而不是永久的围墙。和「按时间强制毕业」比，这样不会产生浅池，「毕业」的含义也不变。

## 3. 规则

| 项 | 规则 |
|---|---|
| 默认 | 不设窗口 = 永远 agent 专属，和现在完全一样 |
| 什么时候定 | **发币前定，发币时写进这个币**。creator 先登记「下一个曲线币的窗口」，下一次曲线币创建时读出、写入、清空（§5.2）。买家进场前规则就是公开的，creator 不能先低价买够再临时宣布开放 |
| 谁来定 | 登记的人就是之后发币的 creator；发币本来就要求持 Agent ID |
| 定什么 | `windowMinutes`：从创建时刻起多少**分钟**后开放。`openAt = 创建区块时间 + windowMinutes × 60` |
| 时长范围 | 按分钟设，**1 – 1440 分钟**（1 分钟到 24 小时）之间的任意整数（`MIN_AGENT_WINDOW_MINUTES` / `MAX_AGENT_WINDOW_MINUTES`）。0 表示不设窗口 |
| 已有的币 | 不能补设，一直是 agent 专属 |
| 开放判定 | `openAt != 0 && block.timestamp >= openAt` |
| 只进不退 | 写入后谁都改不了、撤不了，包括 creator 和 owner。开放后一直开放，否则窗口后买入的普通钱包会卖不出去 |
| 开放后谁能交易 | 任何钱包，包括合约，在所有曲线入口买卖：`buy` / `sell`、`buyFor` / `sellFor`、`buyTokenAMAP`、两个 `sellToken`、`buyWithPromoter` |
| 不要求本人发交易 | 直接 `buy` / `sell` 的交易者是 `msg.sender`，开放后合约也能买，一个合约可以在一笔交易里买下剩余曲线。**有意不拦**，理由有三：<br>1. 窗口期 agent 已经拿到了低价筹码；<br>2. 开放后的大额买入是按曲线价真金白银买的，抬的是 agent 持仓的价格；<br>3. 毕业时池价和曲线末价连续，同一笔交易里买到毕业再砸进新池不赚钱 |
| 聚合器入口 | 仍然只替发起交易的钱包本人交易（`trader == tx.origin`，§23），不变 |
| 1% 钱包上限 | 窗口期照旧。开放后**对所有钱包取消**（agent 也一样，否则 agent 换个无 ID 钱包就绕过了）。例外：带冲毕业奖励的币上限一直保留（§4） |
| pad 级开关 | `agentGateEnabled`、`walletCapEnabled` 仍是总开关。owner 关掉 gate 时，所有币对所有人开放（现状）；关掉上限时，所有币都不限（现状）。总开关开着时，才按每个币判断 |
| 毕业 | 不变：募满创建时的目标即毕业，和窗口无关。没到 `openAt` 也照常毕业，毕业后在 PancakeSwap 本来就人人可交易 |

## 4. 开放后仍然只认 Agent ID 的地方

窗口只放开「谁能在曲线上买卖」和（大多数币的）1% 上限。下面这些防刷、防女巫的规则继续按 pad 级 `isAgent(account)` 判断，不看窗口：

| 位置 | 规则 | 为什么 |
|---|---|---|
| 创建（`CurveLogic3.create` 的 `_requireAgent(c, msg.sender)`） | creator 必须持 Agent ID | agent 专属发射台的定位 |
| 冲毕业奖励（`Pad3GradStore.onBuy`） | 只有 **持 Agent ID 的钱包** 的买入计入名额 | SPEC-GRAD-REWARD §2：gate 关闭时合约钱包能随意刷名额，所以不计入。窗口开放后同理 |
| 冲毕业奖励的币的 1% 上限 | **开放后仍保留** | 奖池按每格花费加权、不按钱包去重（`Pad3GradStore.onBuy`），这个设计的前提是「1% 钱包上限照旧」（SPEC-GRAD-REWARD §2）。上限一取消，一个 agent 钱包一笔买到毕业就能拿走几乎整个奖池 |
| 推广分成的绑定（`_bindable` / `canBind`） | 被绑定的钱包和推广人都必须持 Agent ID | 绑定是永久的，还要分走 creator fee；普通钱包可以开小号绑自己，变相返佣 |
| vault 锁仓 / 释放（`_vaultEntry`） | 用户必须持 Agent ID | 不在本期范围。vault 币开放后买入的普通钱包锁不进 partner vault，页面要写明。另外开放后上限取消，单个 agent 可以买超过 1% 再锁进 vault；合作方的 vault 如果按「每人最多 1%」设计奖励，上线前要和合作方确认 |
| 模块工厂（Split / Countdown / Floor / Capped / PromotePool / Combo / Buyback / LiquiditySplitter 的 `IGangPad(pad).isAgent(msg.sender)`） | 不变 | 管的是建模块的人，不是曲线交易 |
| 打新、铸币飞轮（`FairLogic`、`Pad3FlyModule.checkConfig`） | 不变 | 不在本期范围；登记的窗口只在曲线币创建时读取 |
| base 币的 `buyBase` | 不变 | 本来就不过 gate |

注意：

- **冲毕业奖励的计入。** 今天 `onBuy` 传的是 `c.agentGateEnabled`，gate 开着时交易者一定是 agent。改成在 `onBuy` 里、确认奖励是 `ACTIVE` 之后再判断 `isAgent(trader)`，这样没有冲毕业奖励的币，每笔买入不多一次外部调用。没设窗口的币，行为逐笔不变。
- **毕业那一笔是普通钱包买的。** 这一笔不计入名单，`lastBps` 给名单里最后一格有效的 agent 买入，沿用 SPEC-GRAD-REWARD 里「门槛关闭期间毕业」的语义。agent 要和普通大户抢毕业。
- **推广绑定。**
  - `canBind` 已经检查了钱包本人是 agent。
  - 但 `buyWithPromoter` 用的 `_bindable` 只检查推广人。钱包本人是不是 agent，今天靠后面 `CurveLogic.buy` 的 gate 拦：不是 agent 就整笔回滚，绑定一起撤销。
  - 窗口开放后这层拦不住，所以 `_bindable` **必须**加上 `PadCommon.isAgent(_config, wallet)`。
  - 加上后，普通钱包走 `buyWithPromoter` 照常买入，只是不绑定，和「不合格的推广人」一样，交易不失败。

## 5. 合约改动

### 5.1 存储

新增 ERC-7201 命名空间 `Pad3AgentWindowStore`（`gang.pad3.agentwindow`）。和其他 `Pad3*Store` 一样，成员只往末尾追加：

```solidity
struct Layout {
    mapping(address token => uint40) openAt;            // 0 = never (agent only)
    mapping(address creator => uint16) pendingMinutes;  // the next curve create's window, minutes; 0 = none
}
```

不动 `Curve` 结构体和 `_config`，所以 `curves()` 的布局，以及 indexer 和聚合器对 `curves` 的解码都不变。

### 5.2 登记和写入（入口和视图由 `Pad3GradModule` 提供，经 `Pad3Module` 转发）

```solidity
/// the caller's next curve create gets this window, in minutes; 0 clears it. 1..1440, or 0
function setNextAgentWindow(uint16 windowMinutes) external;
function nextAgentWindowOf(address creator) external view returns (uint16); // minutes

function agentOpenAt(address token) external view returns (uint40);       // 0 = never
function agentWindowOpen(address token) external view returns (bool);     // openAt != 0 && now >= openAt
function canTradeCurve(address token, address account) external view returns (bool);
// = !agentGateEnabled || agentWindowOpen(token) || (account != address(0) && isAgent(account))
// account == address(0)（「一个新钱包」）: 只看前两项，不对 0 地址调 isAgent
function walletCapOn(address token) external view returns (bool);         // §5.4

uint16 public constant MIN_AGENT_WINDOW_MINUTES = 1;
uint16 public constant MAX_AGENT_WINDOW_MINUTES = 1440;   // 24 hours

event NextAgentWindowSet(address indexed creator, uint16 windowMinutes);
event AgentWindowSet(address indexed token, uint40 openAt);

error BadAgentWindow();
```

规则：

- `setNextAgentWindow`：
  - 任何人都能调，只影响自己（`msg.sender`）的下一个曲线币；
  - `windowMinutes` 不是 0、也不在 1 – 1440 内时，回滚 `BadAgentWindow`；
  - 不检查 Agent ID：发币时自然会检查。
- **写入。** 两份 `_createCurve`（`GangLaunchpad3` 和 `Pad3Module`，两者逐行一致）在建好币之后执行：
  - 读 `pendingMinutes[msg.sender]`；
  - 非 0 时写 `openAt[token] = block.timestamp + windowMinutes * 60`，发 `AgentWindowSet`；
  - 然后删掉 `pendingMinutes[msg.sender]`。

  6 个曲线创建入口（普通、目标、vault、推广、冲毕业奖励、base），以及套在外面的 `createWithSalt`，都经过 `_createCurve`，所以一个入口都不用加。`createWithSalt` 委托调用时 `msg.sender` 不变，仍是 creator。
- **只在曲线币创建时消耗。** 打新、铸币飞轮的创建不读也不清 `pendingMinutes`。
- **防止误用到下一个币。** 登记一直有效，直到下一个曲线币创建或被清空。所以 CLI 每次创建曲线币前都写一次：要窗口就写分钟数，不要就写 0（当前值已经是 0 时省掉这笔交易）。不经过 CLI 直接调合约的 creator，要自己清空：登记没有过期时间，忘了清空，之后发的曲线币就会带上这个窗口，而且改不了。打新、飞轮的创建不会清空它。

到 `openAt` 那一刻没有事件，因为没有交易触发。indexer 和网站按 `AgentWindowSet` 里的 `openAt` 自己按时间判断。

### 5.3 交易路径（`CurveLogic3`）

把「交易者必须是 agent」改成按币判断，新增一个内部函数：

```solidity
function _canTrade(IGangLaunchpad.Config storage c, address token, address trader) private view returns (bool) {
    if (!c.agentGateEnabled) return true;
    uint40 t = Pad3AgentWindowStore.layout().openAt[token];
    if (t != 0 && block.timestamp >= t) return true;   // open: any wallet (no external call)
    return PadCommon.isAgent(c, trader);               // in the window / never open: as today
}
```

先判断窗口、再查 Agent ID，结果和反过来一样。好处是开放后的币每笔交易省一次外部调用；没开放的币多一次 SLOAD（冷读约 2.1k gas）。

| 位置 | 现在 | 改成 |
|---|---|---|
| `buy`（`_requireAgent(c, trader)`） | pad 级 | `_canTrade(c, token, trader)`，不通过回滚 `NotAgent` |
| `sell`（`_requireAgent(c, trader)`） | pad 级 | `_canTrade(c, token, trader)`，不通过回滚 `NotAgent` |
| `quoteBuy`（`trader != address(0) && …` 不合格返回 0） | pad 级 | **保留 `trader != address(0)` 的短路**（0 地址 = 新钱包，不检查），其余换成 `_canTrade` |
| `create`（`_requireAgent(c, msg.sender)`） | pad 级 | **不变** |
| `Pad3GradStore.onBuy(..., c.agentGateEnabled)` | gate 开关 | 在 `onBuy` 里 `ACTIVE` 之后再判断 `isAgent(trader)`（§4） |

`PadCommon` 是 2.0 和 3.0 共用的库，不往里加读 3.0 存储的函数。`_canTrade` 和 §5.4 的 `_capped` 只放在 `CurveLogic3`。

### 5.4 1% 上限按币判断

```solidity
function _capped(IGangLaunchpad.Config storage c, address token) private view returns (bool) {
    if (!c.walletCapEnabled) return false;
    uint40 t = Pad3AgentWindowStore.layout().openAt[token];
    if (t == 0 || block.timestamp < t) return true;               // in the window / never open
    return Pad3GradStore.layout().rewardOf[token].state != Pad3GradStore.NONE; // grad reward: keep the cap
}
```

今天这几处都直接读 `c.walletCapEnabled`，要**全部**换成 `_capped(c, token)`。漏改一处，聚合器的报价就会和成交对不上：持仓 ≥1% 的钱包拿到 0 或偏少的报价，路由失败（不丢钱）。

| 位置 | 用途 |
|---|---|
| `CurveLogic3._prepBuy` | 实际买入的上限和截断 |
| `CurveLogic3.quoteBuy` | pad3 自己的报价（pad3 的 `tryBuy` 走这里） |
| `GangLaunchpad3.walletRoom(token, buyer)` 视图 | 对外的剩余额度 |
| 新视图 `walletCapOn(token)` | 对外说明这个币当前有没有上限 |

`GangLaunchpad3.walletRoom` 视图在 pad 合约里，调不到 `CurveLogic3` 的私有函数。所以 `_capped` 要么做成 `CurveLogic3` 的 external view，供 pad 视图调用；要么像 `walletRoom` 一样写成 internal，内联进 pad。两种都只能有一份逻辑来源，由对齐测试保证一致。

GangPadRegistry 读的是 pad 的 `walletCapEnabled()` 和 `walletRoom()`。只要 pad 的 `walletRoom` 对不限的币返回 `type(uint256).max`（`CurveLogic3.walletRoom(capped = false)` 本来就这样），registry 的上限逻辑就不用改。pad 级的 `walletCapEnabled()` 视图保留原义，是总开关。

### 5.5 不改的检查

- `RouterNeedsGate`（`buyFor`、`buyTokenAMAP`、`buyWithPromoter`、`setRouter`）仍要求 pad 级 gate 开着。审计 A-2 担心的是 gate 关闭时 router 能替任意地址（比如未来的 pair）买入。现在 gate 一直开着，窗口只放开交易者的身份，router 仍然只能替 `tx.origin` 交易，A-2 的前提不变。
- `GangGateway._buyOpen` 只看 pad 级 gate 和 router 名单，不用改。
- TWAP 价格保护、毕业逻辑、`_checkCurveTrader`（vault 不能交易自己的币）不变。
- 曲线上的代币在毕业前不能转出（`GangToken` 的 `locked`），开放后合约钱包也没法往未来的 pair 里塞币。

### 5.6 GangPadRegistry（代理，需要升级）

registry 的 `_curve` 被 `previewBuy` 和 `previewSell` 共用，现在用 pad 级 `p.isAgent(trader)` 判断（`GangPadRegistry.sol:251`）。不改的话，开放后的币对普通钱包仍报「不可交易」，聚合器拿到 0 报价。改成：

- 保留 `trader != address(0)` 的短路；
- 其余情况，pad 支持 `canTradeCurve` 时用它（`try` 静态调用），否则沿用 `isAgent`。

受影响的是 GangGateway 的 `tryBuy`（曲线分支走 `registry.previewBuy`）和直接调 registry 的聚合器。pad3 自己的币在 pad3 的 `tryBuy` 里走 `quoteBuy`（§5.3），不经过 registry。`LegacyRoute.tryBuy` 只报其他 pad 的币，和本改动无关。

用 `try` 判断，所以 pad3 和 registry 谁先升级都可以：

- pad3 碰到未知 selector 会回滚，2.0 pad 没有 fallback，registry 都能在 catch 里回退到 `isAgent`；
- pad3 先升级时，registry 暂时对开放后的币给普通钱包报 0。这只影响报价，交易本身由 pad 判断。

### 5.7 实现注意

- **合约大小。** 新增的入口和视图如果放在 `Pad3Module`，运行时代码会到 24,217 字节，离 24,576 字节的上限只剩 359 字节。所以挪到了 `Pad3GradModule`（它本来就是为 24KB 限制拆出来的），由 `Pad3Module` 的 `_isAgentWindow` 转发。挪完后的运行时大小（2026-11-20 实测，上限 24,576 字节）：`Pad3Module` 22,557（余 2,019），`GangLaunchpad3` 22,420（余 2,156），`Pad3FlyModule` 21,777（余 2,799），`CurveLogic3` 17,680（余 6,896），`Pad3GradModule` 8,429（余 16,147）。`CurveLogic3` 新增的 `canTrade` / `walletCapOn` 是 internal，会内联进 pad 和模块。
- **外部库。** `CurveLogic3` 是外部库，pad3 impl 链接的是它部署后的地址。升级时要重新部署 `CurveLogic3`，并用新地址重新链接 pad impl。`UpgradeGangLaunchpad3` 每次运行都用本次编译的代码重新部署库，`_checkImplCode` / `_checkLibs` 逐字节比对 impl 和它链接的库，由它们保证链接的是新库。新增的 `_checkAgentWindow` 只检查窗口本身：第一次升级到这个版本时，最新 25 个老币都没有窗口、上限照旧；以后再升级时，比较升级前后每个币的窗口和上限是否一致（否则有币设了窗口之后，以后的升级会被误拦）。
- **两份 `_createCurve`。** `GangLaunchpad3` 和 `Pad3Module` 的 `_createCurve` 都要加写入逻辑，并且保持逐行一致（`test/gang3/Pad3Vault.t.sol` 比对两者的记录）。

## 6. 链下规则必须补 Agent ID 检查

今天曲线上的每个交易者都持 Agent ID，不少链下规则默认了这一点。开放后这个默认不再成立。凡是按「曲线买入」计数、发奖或结算的规则，都要在**买入所在区块**检查 `isAgent(trader)`，否则可以用无成本的小号刷：

| 规则 | 不补的后果 |
|---|---|
| 喊单保证金的跟单赔付（`docs/SPEC-AGENT-CALLS-2026-11-09.md` §「跟单买入」，现在只要求 `trader == tx.from`） | 喊单者开一批新钱包跟单，然后自己砸盘违约。小号的亏损是真的，但这些钱已经通过砸盘回到喊单者手里，小号还能再领走最多 49% 的赔付池，违约成本大约减半 |
| 所有按曲线买入计名额或计分的活动（入帮、钱包合作活动、发射日等） | 小号刷名额、刷奖励 |
| 热榜、成交排行、徽章、持有人数 | 刷量、刷持有人数。开放后的币，「持有人数」应分开显示 agent 和非 agent |

这些规则的改动在各自的仓库和规格里做。本 spec 上线前要逐个确认已经补上，或者确认它们不会把开放后的币计进去。

## 7. 风险

### 7.1 合约层面

| # | 风险 | 处理 |
|---|---|---|
| R-1 | **合约当交易者是新输入面。** 主网 gate 从没关过，开放后是合约第一次能在曲线上买卖 | 已审阅，没发现问题：<br>• 所有入口都有 `nonReentrant`；<br>• 退款和卖出所得只用报价币 ERC-20 结算，不发原生 BNB；<br>• 五种上架报价币（WBNB、USDT、USDC、USD1、ANTB）没有转账钩子，手续费型报价币在 `pullExact` / `_payIn` 就被拒绝；<br>• 分红由持有人自己领，不会推给合约；<br>• 回购和交易模块的 TWAP 需要多分钟的观测，同一笔交易里凑不出来。<br>正式审计时仍要把这一点列为重点 |
| R-2 | **上限漏改导致报价不一致** | §5.4 列出所有位置；§8 加逐 wei 对齐测试 |
| R-3 | **`_bindable` 漏补导致普通钱包被永久绑定** | §4 标为必须，§8 有测试 |
| R-4 | **升级。** pad3 impl（连同 `CurveLogic3` 库）和 registry 都要升级 | 按现有流程：新命名空间、布局测试固定 SLOT；不需要 reinitializer，新存储默认 0 = 不开放；自检确认链接了新库 |

### 7.2 要在页面上讲清楚的经济机制（不算漏洞）

| # | 机制 | 怎么披露 |
|---|---|---|
| E-1 | **开放那一刻是可以预期的卖点。** 窗口期的 agent 拿着低价筹码，等普通用户进来时卖给他们。这就是「agent 先进场」的设计 | 币详情页显示开放时间，以及窗口期买入的持仓占多少（按 `AgentWindowSet` 和交易事件计算） |
| E-2 | **开放那个区块可能被一笔买光。** 上限取消后，一个合约可以在 `openAt` 当个区块买下剩下的整条曲线 | 「至少 80 个钱包才能毕业」对开放后的币不成立，网站和文案不要再这么说 |
| E-3 | **creator 自己推毕业更便宜。** creator 的交易有 70% 的手续费会作为 creator fee 返给自己，净费率约 0.3%。这一点现在就成立，取消上限后一个人推到毕业更容易 | 页面标出 creator 的持仓和买入 |
| E-4 | **毕业那一笔的奖金可能落到别人头上**（带冲毕业奖励的币）：普通钱包推毕业时，`lastBps` 给最后一格有效的 agent | CLI 和网站的冲毕业奖励说明写上 |
| E-5 | **vault 币开放后买入的普通钱包不能锁仓** | vault 币页面写明 |

## 8. 测试

- `test/gang3/Pad3AgentWindow.t.sol`：
  - 默认不开放：普通钱包调 `buy` / `sell` / `buyFor` / `buyTokenAMAP` / `sellToken` 都回滚 `NotAgent`，`quoteBuy` 为 0。
  - 登记：
    - `setNextAgentWindow`：1 和 1440 通过，1441 回滚，0 表示清空；`openAt` = 创建时间 + 分钟数 × 60；
    - 下一个曲线币创建时写入 `openAt` 并清空登记；
    - 6 个创建入口和 `createWithSalt` 都能写入；
    - 打新、飞轮的创建不消耗登记；
    - 别人的登记不影响我发的币；
    - 写入后没有任何函数能改 `openAt`。
  - `openAt` 前一秒仍拒绝，`openAt` 当秒起所有入口放行，买入后能卖出。
  - 开放后 agent 照常交易。
  - pad 级 gate 关闭时，有没有窗口都对所有人开放，和现状一致。
  - 上限：
    - 窗口期内对 agent 生效；
    - 开放后对所有钱包取消，一个钱包能一笔买到毕业，毕业和池子正确；
    - 带冲毕业奖励的币开放后仍限 1%；
    - pad 级 `walletCapEnabled` 关闭时都不限。
  - 上限对齐：开放前后，带奖励和不带奖励的币，各种持仓下，`_prepBuy` 的实际成交、`quoteBuy`、pad 的 `walletRoom` 视图、registry 的 `previewBuy` 逐 wei 一致。
  - 合约钱包：
    - 开放后能直接 `buy` / `sell`；
    - 一个工厂合约在一笔交易里买到毕业，毕业正常、池子正确，同一笔交易里砸进新池不盈利。
  - 开放后 `quoteBuy(token, address(0), …)`、`canTradeCurve(token, address(0))`、registry 的 `previewBuy(token, address(0), …)` 都不 revert，也不对 0 地址调 `isAgent`。
- 冲毕业奖励：
  - 开放后普通钱包的买入不占名额，agent 的买入照常计入；
  - 普通钱包推毕业时，`lastBps` 给最后一格有效的 agent；
  - 没设窗口的币，行为和改之前逐笔一致。
- 推广分成：
  - 开放后普通钱包走 `buyWithPromoter` 能买入、不绑定，`canBind` 返回 false；
  - agent 钱包照常绑定。
- 聚合器：开放前，pad3 自带的 `tryBuy` / `buyTokenAMAP`、GangGateway、registry 的 `previewBuy` 给普通钱包的报价为 0；开放后正常报价，并且能成交。
- 升级：
  - `GangLaunchpad3Layout.t.sol` 加新命名空间的 SLOT；
  - `Pad3Upgrade.t.sol` 验证升级后老币全部不开放、上限照旧，行为不变；
  - 升级自检确认链接了新 `CurveLogic3`。
- 不变式：
  - `openAt` 一旦非 0 就不再改变；
  - 开放后任何钱包都能卖出自己持有的曲线币；
  - 上限只在「开放、没有冲毕业奖励、总开关开着」时取消。
- 现有的 `Pad3Parity` / `Pad3EntryParity` / `Pad3PromoteParity` / `Pad3GradReward` 全部照过。

## 9. 上线

1. 本 spec 定稿（§10）→ 实现 → 独立审计 → 修复复审。
2. 测试网：升级 pad3 impl（连同 `CurveLogic3`）和 registry，跑一遍验收脚本：
   - 登记窗口、发币；
   - 开放前后用普通钱包从聚合器入口买卖；
   - 开放后用一个钱包大额买到毕业；
   - 带冲毕业奖励的币，开放后仍受上限限制。
3. 主网：Safe 升级 pad3 impl（走现有 `UpgradeGangLaunchpad3` 脚本）和 registry，需要明确批准。
4. 链下规则（§6）逐个补上 Agent ID 检查，**在主网升级之前**完成。
5. CLI：
   - 创建时加 `--agent-window <分钟>`（1 – 1440）；
   - 每次创建曲线币前先写 `setNextAgentWindow`（有窗口写时长，没有写 0，已经是 0 就跳过）；
   - `gang info` 显示 `openAt`、剩余时间、当前有没有上限。
6. 网站：
   - 币详情页显示「agent 专属，X 后对所有人开放」或「agent 专属」，以及 §7.2 要披露的内容；
   - 列表可按「即将开放」排序。
7. indexer：记录 `AgentWindowSet`；需要时用 `agentOpenAt` 补数。
8. 通知已接入的聚合器：开放后的币普通钱包可以交易，按 `canTradeCurve` 判断；剩余额度按 `walletRoom` 判断，开放后大多数币不限。

## 10. 决定记录

| # | 问题 | 状态 |
|---|---|---|
| Q1 | creator 什么时候能定窗口 | **已定**：发币前登记，发币时写入（§3、§5.2）；已有的币不能补设 |
| Q2 | 时长范围 / 档位 | **已定**：按分钟设，1 – 1440 分钟之间任意整数 |
| Q3 | 冲毕业奖励在开放后 | 采用草稿默认：只认 Agent ID，且这类币开放后保留 1% 上限（后者是审阅结论） |
| Q4 | 推广绑定在开放后 | 采用草稿默认：只绑 Agent ID 钱包 |
| Q5 | 1% 钱包上限在开放后 | **已定**：对所有钱包取消，带冲毕业奖励的币除外 |
| Q6 | 平台能不能统一设置 | **已定**：不做平台默认，只有 creator 能定。creator 不设就永远 agent 专属，和现在一样；合约里不给 owner 加任何窗口相关的权限 |
| Q7 | creator 能不能承诺「永远 agent 专属」 | 窗口改成发币时写入以后，不登记就是永远 agent 专属，而且之后谁都改不了，所以**不需要单独的放弃函数** |

不在本期：毕业门槛随时间下降、按时间强制毕业。窗口上线后，看到开放后的成交和毕业率，再决定要不要做。
