# GangLaunchpad 3.0 聚合器接入文档

> **版本 2026-11-25**，取代 2026-11-04 版。BSC 主网、测试网均已上线。
>
> 3.0 的地址**永久不变**，新功能都通过升级这个地址背后的合约上线。已加白的 caller 不用重新加白，**原有函数签名和事件没有改过**。

| BSC 主网（chainId 56） | 地址 |
|---|---|
| **GangLaunchpad 3.0**（授权和调用都用它） | `0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29` |
| GangSwapRouter（当前版本） | `0xd685e3432472d0da34903888f96b0D0221bC779c` |
| GangSwapFactory（当前版本） | `0xd0C15eB66e08596F9F534d0051F691b86Bc584F5` |
| Agent ID（ERC-721） | `0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F` |
| GangPadRegistry | `0x4fF77D4d9ac080939a24E1B805206bA094C44e5C` |
| 飞轮税处理器（`protectionOf`） | `0x7De950738e3D0210be6871220f51708D316F3ba0` |
| WBNB | `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c` |
| GangGateway（旧入口，仍在运行） | `0x9dD16b73f624bdd8a210CBB2602FdF70f1B450B8` |

## 1. 已接入的先看：这次要改什么

| 变化 | 影响 | 要做什么 |
|---|---|---|
| **Agent 窗口**（11-21） | 有些曲线币到 `openAt` 后，任何钱包都能买卖，1% 上限取消 | **必改**：不要再写死“没有 Agent ID 就不能交易”或“单钱包最多 1%”。用 `canTradeCurve` 和 `tryBuy` 判断 |
| **GangSwap**（11-25） | 新类型 `kindOf == 4`，毕业后 `getTokenInfo` 返回**新的 `status == 4`** | **必改**：status 4 走 GangSwap，**不是 PancakeSwap**。不认识的 status 一律不路由 |
| GangGateway 不支持类型 4 | 网关对 GangSwap 曲线币返回 status 0、报价 0 | 要覆盖这类币，请改接 3.0 |
| 推广分成（11-07） | 推广人的份额从 creator 的手续费里出，不影响价格和用户成本 | 不用改 |
| abcd 地址（11-12） | 新币地址以 `abcd` 结尾 | 不用改。后缀**不能**作为真币依据，以 `kindOf` 或 registry `lookup` 为准 |
| 底仓金库（11-16） | 创建时可以有一笔金库买入 | 交易不用改。索引注意：第一笔 `Buy` 的 trader 可能是金库 |
| 冲毕业奖励（11-17） | 买卖时会多发几个事件 | 交易不用改。不要写死 gas limit，也不要按固定位置解析日志 |

## 2. 五分钟看懂

- 交易、报价、查询和事件都在**同一个地址**，接口沿用 four.meme（TokenManager2 + Helper3）的形状。
- **买入**：任何合约都能调用，不用加白。代币直接发给用户。
- **卖出**：用户把代币授权给 3.0，由你们的合约调用。**调用 3.0 的合约要先加白**。所得可以付给用户（路由费最多 5%），也可以付给你们的 router 做多跳。
- **一个地址几乎能交易所有 Gang 内盘币**：1.0、2.0、金库版、铸币飞轮 V1 / V2 的币由 3.0 自动转给老 pad 成交。
- 毕业前代币锁仓，**不能转进你们的 router**。
- 入口买卖的交易者必须是 `tx.origin`，所以不支持 relayer、AA 代付和 solver 代成交。**窗口开放后也是这样。**

```text
(status, quote, pair, feeBps, left) = pad.getTokenInfo(token)

status == 1 内盘
    买：tryBuy(token, 真实用户, 0, funds)，estimatedAmount == 0 → 现在不能买
        → buyTokenAMAP(token, 用户, funds, minAmount)
    卖：trySell(token, amount)，funds == 0 → 现在不能卖
        3.0 自己的曲线币（kindOf 1 / 4）再查 canTradeCurve(token, 用户)，false → 不能卖
        → 单跳：sellToken(0, token, 用户, amount, minFunds, feeRate, feeRecipient)
        → 多跳：sellToken(0, token, 用户, 你们的合约自己, amount, minFunds)
status == 2 已毕业 / 开池 → PancakeSwap V2，用返回的 pair
status == 4 已毕业       → GangSwap，用返回的 pair（第 6 节）
status == 3、0、其他值   → 不要经 3.0 路由
```

`quote == address(0)` 表示 BNB 计价，收付原生 BNB；否则是计价 ERC20。

## 3. 能交易哪些币

| 币 | `kindOf` | 毕业前 status | 毕业后 status | 毕业前规则 |
|---|---|---|---|---|
| 曲线币 | 1 | 1 | 2 | 任意数量，1% 费，Agent 规则见第 4 节 |
| **GangSwap 曲线币** | **4** | 1 | **4** | 和曲线币完全相同；只有 BNB 计价，毕业后无转账税 |
| 打新（有门槛） | 2 | 1 | 2 | 按整份，每份 **50,000** 枚，固定单价 |
| 铸币飞轮（有门槛） | 3 | 1 | 2 | 按整份，每份 **100,000** 枚，固定单价，有额度 |
| 打新 / 3.0 飞轮（无门槛） | 2 / 3 | 3 | 2 | 不能经 3.0 交易 |
| 1.0 / 2.0 / 金库版 / 飞轮 V1、V2 | 0（不是 3.0 的币） | 1 或 3 | 2 | 3.0 自动转发 |
| LaunchpadV2、Soft、U、S 及非 Gang 币 | 0 | 0 | 0 | 不能交易 |

- 老 pad 的币在 3.0 上 `kindOf` 是 0，**不要用它排除代币**，以 `getTokenInfo` 的 status 为准。类型可查 registry `lookup(token)`，返回 `(pad, kind)`。
- `status == 1` 只说明在内盘，**能不能交易以报价非 0 为准**（卖出再加 `canTradeCurve`）。
- 毕业币的税率读代币自己的 `buyTaxBps()` / `sellTaxBps()`（曲线币和打新币）。

## 4. Agent 窗口（新）

创建者可以给曲线币（类型 1 和 4）设一个 1–1440 分钟的窗口，只能在创建时设，之后不能改。

| | 没有窗口（`agentOpenAt == 0`） | 窗口内（`now < agentOpenAt`） | 已开放（`now >= agentOpenAt`） |
|---|---|---|---|
| 谁能买卖 | 只有 Agent ID 持有者 | 只有 Agent ID 持有者 | **任何钱包** |
| 1% 钱包上限 | 有 | 有 | **没有** |
| 3.0 入口要求 `tx.origin` | 是 | 是 | 是 |

开放由区块时间决定，**不发事件、不需要交易**。曲线还是同一条，没有迁移。

```solidity
function agentOpenAt(address token) external view returns (uint40);      // 0 = 永远只限 Agent
function agentWindowOpen(address token) external view returns (bool);
function canTradeCurve(address token, address account) external view returns (bool);
function walletCapOn(address token) external view returns (bool);
function walletRoom(address token, address buyer) external view returns (uint256); // 无上限时为 uint256 max
event AgentWindowSet(address indexed token, uint40 openAt);              // 创建交易里，在 Created 之后
```

要点：

- **`tryBuy` 一定要传真实用户。** 传 `address(0)` 会跳过 Agent 检查，给没有资格的用户报出非 0 的价格。
- `trySell` 不检查 Agent 资格、余额和授权。曲线币卖出前请加查 `canTradeCurve`。
- `canTradeCurve` 不判断是否已毕业，也只对 3.0 自己的曲线币有意义；`status == 1` 且 `kindOf` 是 1 或 4 才用它。
- 大部分币没有窗口，仍然只限 Agent ID 持有者。打新和飞轮没有窗口。
- 缓存报价或资格时，不要跨过 `agentOpenAt`。
- **AA 钱包、合约账户**不能走入口，但可以自己直接调用 3.0 的 `buy(token, quoteIn, minTokensOut)` / `sell(token, tokensIn, minQuoteOut)`，前提是资格检查通过。这两个函数只收付 ERC20（BNB 计价的币用 **WBNB**），买卖者都是 `msg.sender`。合约买到的代币在毕业前转不出去，所以**不能用这条路替用户买**。

## 5. 接口

### 5.1 Solidity

```solidity
interface IGangLaunchpad3Entry {
    /// status: 0 不能交易 / 1 内盘 / 2 PancakeSwap V2 / 3 无门槛发售（不经 3.0）/ 4 GangSwap
    function getTokenInfo(address token) external view returns (
        uint8 status,
        address quote,           // address(0) = BNB
        address pair,            // status 2 = Pancake V2 pair；status 4 = GangSwap pair；否则 0
        uint256 protocolFeeBps,  // status 1：曲线 100；打新 / 飞轮为铸币费（只在买入收）
                                 // status 4：100（GangSwap 池子的费率）
        uint256 graduationLeft   // status 1：距毕业还差的计价币；
                                 // 打新 / 飞轮为剩余份数 × 单价，不含铸币费，有人退出会变大
    );

    /// amount 必须为 0（只支持按资金买）。会回滚的买入返回 estimatedAmount = 0。
    /// 飞轮必须传真实 trader；其他币也强烈建议传（见第 4 节）。
    function tryBuy(address token, address trader, uint256 amount, uint256 funds) external view returns (
        address tokenManager,    // 3.0 的地址
        address quote,
        uint256 estimatedAmount,
        uint256 estimatedCost,   // 实际花费，含费
        uint256 estimatedFee,
        uint256 amountMsgValue,  // BNB 计价时的 msg.value（曲线 = funds；打新 / 飞轮 = 整份花费）
        uint256 amountApproval,  // ERC20 计价时的授权额（同上）
        uint256 amountFunds      // = estimatedCost；用它作为 funds，买到同样数量且没有退款
    );

    /// funds：扣协议费 / 退出费后、扣路由费前。不检查用户的余额、授权和 Agent 资格。
    function trySell(address token, uint256 amount) external view returns (
        address tokenManager, address quote, uint256 funds, uint256 fee
    );

    /// to 必须等于 tx.origin。BNB 计价：msg.value == funds；
    /// ERC20 计价：msg.value == 0，从 msg.sender 拉取 funds（先授权给 3.0）。
    /// 没用完的资金退给 to（BNB 计价退 WBNB），不退给调用方。
    function buyTokenAMAP(address token, address to, uint256 funds, uint256 minAmount)
        external payable returns (uint256 amountOut, uint256 fundsUsed);

    /// 卖出 A：所得给用户。调用方已加白，或 from 本人直接调用。from 必须等于 tx.origin。
    /// minFunds：扣协议费和路由费后，用户到手的最低金额。feeRate：100 = 1%，最大 500。
    function sellToken(uint256 origin, address token, address from, uint256 amount,
        uint256 minFunds, uint256 feeRate, address feeRecipient)
        external returns (uint256 fundsToSeller);

    /// 卖出 B：所得给调用方合约。to 必须是 msg.sender 且已加白。from 必须等于 tx.origin。
    /// BNB 计价付原生 BNB，合约要能接收。没有路由费参数，请在后续跳里收。
    function sellToken(uint256 origin, address token, address from, address to,
        uint256 amount, uint256 minFunds)
        external returns (uint256 funds);

    // 辅助查询
    function kindOf(address token) external view returns (uint8);
    function shareSizeOf(address token) external view returns (uint256);  // 每份代币数
    function isCaller(address caller) external view returns (bool);       // 是否已加白
    function gangSwapMigratorOf(address token) external view returns (address); // 0 = 不是 GangSwap 币
}
```

`origin` 传 0（保留字段）。

### 5.2 Selector

| 函数 | selector |
|---|---|
| `getTokenInfo(address)` | `0x1f69565f` |
| `tryBuy(address,address,uint256,uint256)` | `0xdec05219` |
| `trySell(address,uint256)` | `0xc6f43e8c` |
| `buyTokenAMAP(address,address,uint256,uint256)` | `0x7f79f6df` |
| `sellToken(uint256,address,address,uint256,uint256,uint256,address)` | `0xe63aaf36` |
| `sellToken(uint256,address,address,address,uint256,uint256)` | `0x930cc050` |
| `canTradeCurve(address,address)` | `0x3a033eb8` |
| `agentOpenAt(address)` | `0xfa740b09` |
| `agentWindowOpen(address)` | `0xa88178c1` |
| `walletCapOn(address)` | `0x5ac1c848` |
| `walletRoom(address,address)` | `0x5a955a03` |
| `kindOf(address)` | `0xd3b441a8` |
| `shareSizeOf(address)` | `0xc2ed77eb` |
| `isCaller(address)` | `0x7ac07dcc` |
| `gangSwapMigratorOf(address)` | `0x1c5a4a70` |

### 5.3 最小 adapter 示例

```solidity
contract GangAdapter {
    IGangLaunchpad3Entry constant PAD = IGangLaunchpad3Entry(0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29);

    // BNB 计价的币
    function buy(address token, uint256 minAmount) external payable returns (uint256 out) {
        (out,) = PAD.buyTokenAMAP{value: msg.value}(token, msg.sender, msg.value, minAmount);
    }

    // 单跳卖出；用户已 approve(PAD, amount)；本合约已加白
    function sell(address token, uint256 amount, uint256 minFunds, uint256 feeRate, address feeTo)
        external returns (uint256)
    {
        return PAD.sellToken(0, token, msg.sender, amount, minFunds, feeRate, feeTo); // from 只能是 msg.sender
    }

    // 多跳的第一跳：所得到本合约。BNB 计价的币要有 receive()；
    // 后续跳必须在同一笔调用里，为 msg.sender 用掉 got
    function _sellToSelf(address token, uint256 amount, uint256 minFunds) internal returns (uint256 got) {
        got = PAD.sellToken(0, token, msg.sender, address(this), amount, minFunds);
    }

    receive() external payable {}
}
```

滑点建议：`minAmount = estimatedAmount × (1 − 滑点)`；单跳 `minFunds = (trySell.funds − trySell.funds × feeRate / 10000) × (1 − 滑点)`；多跳 `minFunds = trySell.funds × (1 − 滑点)`。

### 5.4 多跳

| 路线 | 做法 |
|---|---|
| 内盘 Gang 币 → BNB / 计价币 → 其他 | 卖出 B，所得进 router，接着做下一跳 |
| 其他 → BNB / 计价币 → 内盘 Gang 币 | 先换好，再 `buyTokenAMAP(token, 用户, …)`；代币直接到用户钱包 |
| 内盘 Gang 币在中间 | 不支持 |
| 已毕业（status 2 / 4） | 在 Pancake / GangSwap 上正常多跳，计入税和费 |

多跳买入请把 `tryBuy` 的 `amountFunds` 作为 `funds`，避免余款以 WBNB / 计价币退到用户钱包。

### 5.5 和 four.meme 的差异

| four.meme | GangLaunchpad 3.0 |
|---|---|
| `Helper3.getTokenInfo` | 同 selector，**返回结构不同**，不能用 four.meme 的解码 |
| `tryBuy(token, amount, funds)` | 多了 `trader` 参数，selector 不同；返回字段沿用 |
| `trySell`、`buyTokenAMAP`、两个 `sellToken` | 同签名 |
| `minFunds` 按扣费前比较 | 按**净到手**比较 |
| 多跳 `to` 可以是名单里任意地址 | 只能是调用方自己 |
| 有 `GW` 对齐要求 | 没有 |
| 支持按数量买 `buyToken` | 不支持 |

## 6. GangSwap 币（kindOf 4，新）

毕业前和普通曲线币完全一样。毕业后进入 GangSwap 交易对：**Pancake V2 式接口，1% 费率，计价币一侧带固定虚拟储备**。截至本文还没有正式版本的币毕业。合约做过多轮内部评审，没有外部审计，不可升级。

### 6.1 识别

- `getTokenInfo` 返回 `status == 4`、GangSwap `pair`、`protocolFeeBps == 100`。
- 任何人都能给这类币另建 PancakeSwap 池子，**那不是它的毕业池**。
- 校验：`pad.gangSwapMigratorOf(token)` → 该 migrator 的 `factory()` → `factory.getPair(token, WBNB) == pair`。
- **可能有多个版本**：每个币固定在创建时的版本。`gangSwapMigrator()` 只表示新币用哪个版本，不能拿来查老币。请维护 factory / router **列表**，不要只认一个。

| 主网当前版本 | 地址 |
|---|---|
| Migrator | `0x22e13298D48100420F2F386D70D18E498161B20b` |
| Factory | `0xd0C15eB66e08596F9F534d0051F691b86Bc584F5` |
| Router | `0xd685e3432472d0da34903888f96b0D0221bC779c` |
| Boost | `0x42A3dBcBb2339f52AE332cc480766003C43f1416` |
| Fees | `0xa9D9a67D724d487f843d37db92162F6728c58900` |
| Pair init code hash | `0x118a6e086410ad99bc0968c3a4afdce6653288e14174b6248da8a05b0693e13b` |

### 6.2 报价

```text
inWithFee = amountIn × 9900
amountOut = inWithFee × reserveOut / (reserveIn × 10000 + inWithFee)
```

储备用 `getReserves()`，它已包含虚拟储备。

- 费用**不留在池子里**：买入的计价币费另存，卖出的代币费销毁。成交后 `reserveIn` 只增加“输入 − 费”。在同一笔交易里对同一个池子成交两次时，要按这个建模。
- **不要用 Pancake 的 0.25% 费率。**

| 用途 | 用什么 |
|---|---|
| 价格、报价 | `getReserves()` / `Sync` |
| 流动性、TVL | `realQuoteReserve()` |
| 虚拟储备 | `virtualReserve()`（固定，等于募集额的 20%） |
| 未领手续费 | `feeAccrued()` |
| 计价币余额基线 | `quoteBalanceBase()` = 真实储备 + 未领手续费 |

### 6.3 成交

**方式一（推荐）**：GangSwapRouter，V2 router 的 swap 函数和 `getAmountsOut` 都有，支持原生 BNB，没有加减流动性的函数。

**方式二**：直接调 pair，先转入再 `swap(amount0Out, amount1Out, to, "")`。按余额算输入的执行器要改一处：

```solidity
// 计价币（WBNB）输入
amountIn = IERC20(wbnb).balanceOf(pair) - pair.quoteBalanceBase();   // 正确
// amountIn = balanceOf(pair) - reserve;                             // 错：小额下溢回滚，大额少收代币
```

代币输入照旧。不支持闪电兑换（`data` 非空会回滚 `GangSwap: NO_FLASH_SWAP`）。LP 已销毁，不能加减流动性。

### 6.4 索引

- V2 的 `PairCreated`、`Swap`、`Sync`（有效储备），另有 `FeeTaken(uint256 feeQuote, uint256 feeTokenBurned)`。
- 毕业后会有一轮定时回购销毁（通常约 40 步，每步至少间隔 8 秒），表现为 `to = 0x…dEaD` 的普通 `Swap`，另在 Boost 上发 `BoostStep`。
- `balanceOf(pair)` 与储备不等是正常的，不要当异常池处理。

### 6.5 联调用的池子

主网隔离环境，代码相同、真实 WBNB，池子很小，**只用于联调，请不要上架**：

| | 地址 |
|---|---|
| Pad | `0xa5Ed346AfB5cD8D7CdDce8a02d0D55b51EC0198B` |
| Migrator | `0x4F53325AD55536d70Bd68131FFE27C807D27497c` |
| Factory | `0x0053eb9B66DB1d5D2fE5dDF84f9CB3E487c83121` |
| Router | `0x71310eAf34584389408D8847a3ef86482B9998Db` |
| Token（token0） | `0xb532b2374B820a74916311d46B8AcF02804E791f` |
| Pair（token1 = WBNB） | `0x52c9843cfCdeC52363BB5B8027478C172581b40D` |

## 7. 各类币的规则

### 7.1 曲线币（kindOf 1、4）

- 总量 10 亿，曲线卖出约 8 亿后毕业；毕业目标有 6 / 9 / 12 / 15 BNB 四档（其他计价币按创建时换算）。以 `graduationLeft` 为准。
- 协议费 1%，毕业前没有转账税。有上限时单钱包最多 1%，锁在绑定金库里的也计入；`tryBuy` 已按上限和毕业线截断，余款退给用户。
- 跨过毕业线的那笔买入会在同一笔交易里迁移，**gas 明显更高**。请按模拟结果估算并留余量。
- 毕业后 3.0 上的买卖回滚 `NotCurveToken`，请立即重查 status。
- 极小额卖出 `trySell.funds` 可能为 0，这时不要卖：会拿走代币但付 0。
- 经 3.0 入口的买入不会绑定推广人。`buyWithPromoter` 只允许用户钱包直接调用。

### 7.2 打新（kindOf 2，及老 pad 的打新）

- 整份买卖，每份 50,000 枚。买入加 1%–3% 铸币费，卖出扣 1%–2% 退出费（7 天没有进展后为 0，之后可能恢复，`minFunds` 请留余量）。
- 一份都买不起回滚 `FundsTooLow`；卖出不是整份回滚 `NotWholeShares`。
- 每个发售有自己的单钱包上限（总量的 0.25%–1%）。
- 卖满最后一份的买入**在同一笔交易里开池**。

### 7.3 铸币飞轮（kindOf 3，及 V1 / V2）

- 整份买卖，每份 100,000 枚。有钱包额度，单笔最多 10 份。买入加 1%–3% 铸币费，开池前卖出扣 1%–2% 退出费。
- **不要用 3.0 的 `TOKENS_PER_SHARE()` 取整**，那是打新的 50,000。3.0 的币查 `shareSizeOf(token)`。
- 售满后要等单独的开池交易，期间 status 仍是 1，但报价为 0（超过 7 天没开池可以卖回）。
- 开池后走 PancakeSwap。**保护期（5–30 分钟）内**从池子买入，收币钱包必须有 Agent ID，且有累计上限，否则回滚。3.0 飞轮币查飞轮税处理器的 `protectionOf(token)`，返回 `(until, gate, cap)`。
- 开着“开池后继续铸造”的币，`buyTokenAMAP` 仍能买，可能回滚 `PriceBelowAverage` / `PriceAbovePool` / `PaceExceeded`；不必走这条路。

打新和飞轮都按 `amountMsgValue`（BNB）或 `amountFunds`（ERC20）作为实际金额发送，没有退款。

### 7.4 毕业后的有税币（PancakeSwap V2）

- 用 `…SupportingFeeOnTransferTokens` 系列方法，报价计入 `buyTaxBps()` / `sellTaxBps()`。
- 卖出可能先触发一次税费兑换，最多用约 60 万 gas。gas limit 太紧会回滚 `SwapBackOutOfGas`。
- 不要用闪电兑换的方式卖出，会回滚 `SellDuringFlashSwap`。
- 倒计时奖励模块（`countdown-v1`）的币，经聚合器买入是普通买入，**不计入倒计时奖励**，建议前端提示。

## 8. 错误码

| 错误 | 含义 / 处理 |
|---|---|
| `NotAgent` | 还没开放或没有窗口的币，交易者没有 Agent ID |
| `WalletCapReached` | 已到单钱包上限 |
| `NotCurveToken` / `AlreadyGraduated` | 不在内盘或已毕业；重查 status |
| `TraderNotOrigin` | `to` / `from` 不是 `tx.origin` |
| `NotWhitelisted` | 卖出的调用方没加白 |
| `RecipientNotListed` | 多跳卖出 `to` 不是调用方自己，或没加白 |
| `Slippage` | 低于 `minAmount` / `minFunds` |
| `BadMsgValue` | BNB 计价 `msg.value != funds`，或 ERC20 计价带了 value |
| `ZeroAmount` | 数量为 0 |
| `AmountNotSupported` | `tryBuy` 的 `amount` 不是 0 |
| `FundsTooLow` / `NotWholeShares` | 打新 / 飞轮不够一份 / 不是整份 |
| `FeeRateTooHigh` / `ZeroFeeRecipient` | 路由费超过 5% / 收款地址无效（0 地址、3.0、WBNB） |
| `RouterNeedsGate` | 无门槛发售；或 pad 的 Agent 门槛总开关被关闭时，入口不接受曲线币买入 |
| `VaultCannotTrade` | 币自己的金库不能交易它 |
| `FeeOnTransferQuote` | 计价币转账少到账 |
| `BnbTransferFailed` | 收款方拒收 BNB |
| `TransfersLocked` | 毕业前试图转移代币（代币合约发出） |
| `ProtectionNotAgent` / `ProtectionCapExceeded` | 飞轮开池保护期内的池子买入 |
| `ERC20InsufficientAllowance` | 用户没有把代币授权给 3.0 |

## 9. 行情和索引

除注明外，事件都从 3.0 地址发出。

- `Created`、`Minted`、`Withdrawn`、`Launched` 在不同类型上签名不同，**按 topic0 区分**。
- 发现新币：订阅三种 `Created`。类型 4 的 `Created` 与类型 1 相同，另发 `GangSwapCreated`。
- 曲线成交：`TradeV1` 紧跟 `Buy` / `Sell`，带完整费用和成交后价格。**不要把它和 `Buy` / `Sell` / `GatewayBuy` / `GatewaySell` / `GatewaySellTo` 重复计量。**
- `Buy` / `Sell` 里的 `tax` 恒为 0（曲线不收税）。
- 打新和飞轮没有 `TradeV1`，看 `Minted` / `Withdrawn` / `PostMinted`。
- 老 pad 的币**行情以老 pad 自己的事件为准**；`Routed` 只用于归因，日志里排在 `GatewayBuy` / `GatewaySell` / `GatewaySellTo` 前面，请按交易哈希和 token 配对。
- 底仓金库：`BaseCreated` 之后的第一笔 `Buy` / `TradeV1` 的 trader 是金库；底仓计入 `sold`，报价已自动反映。
- 毕业：`Graduated` 的 `pair` 可能是 Pancake 或 GangSwap，用 `kindOf` 或 status 区分。
- 分叉点：`kindOf == 4` 的池子成交去 GangSwap pair 上索引。

```solidity
event TradeV1(address indexed token, address indexed trader, bool isBuy,
    uint256 quoteAmount,  // 买：pad 收下的金额（含费、不含退款）；卖：扣费前曲线付出
    uint256 tokenAmount,
    uint256 protocolFee,  // 1%
    uint256 creatorFee,   // 其中归 creator 的部分（含推广人份额）
    uint256 postPrice,    // 成交后边际价格：每 1e18 代币的计价币 wei
    uint256 realQuote,    // 成交后曲线里的计价币（若触发毕业，为迁移前的值）
    uint256 sold);
event GatewayBuy(address indexed token, address indexed trader, address indexed caller,
    uint256 fundsUsed, uint256 amountOut);
event GatewaySell(address indexed token, address indexed trader, address indexed caller,
    uint256 amount, uint256 funds, uint256 fundsToSeller, uint256 routerFee, address feeRecipient);
event GatewaySellTo(address indexed token, address indexed trader, address indexed to,
    address caller, uint256 amount, uint256 funds);
event Routed(address indexed token, address indexed pad, address indexed trader,
    bool isBuy, uint256 quoteAmount, uint256 tokenAmount);
event GangSwapCreated(address indexed token, address indexed migrator);
```

| 事件 | topic0 |
|---|---|
| `Created`（曲线 / GangSwap 曲线） | `0x416fe98c8f1ea2977674a1a4ee6252eb72597a8392fc2d7d0599a2bf5d8fdb63` |
| `Created`（打新） | `0xd46f0c9c36ad8c7839cf830c7cb08aa3a24392965d09cf84e5c8d3bf098d6a4f` |
| `Created`（飞轮） | `0xfe0b41338e533cc3b4890a435f738eda2fb765a33b47305867fdd3e1c42d5e67` |
| **`AgentWindowSet`**（新） | `0xdf694fa963ddb0544e30072990450e7d7b4682a8e1da7f7955d9ce4fd0e51265` |
| **`GangSwapCreated`**（新） | `0x322a9fd6ec82e6eaf934d0c151acf2c2a65c4a8011168cb75a6e6a2c64982662` |
| **`BaseCreated`**（新） | `0x4e7a313a697136c9bed9e94504e03032cc826b52e3a7ed76c8d72bed426df1bc` |
| **`PromoteSet`**（新） | `0x47b56b56471827ce6a44e27d133e26db9e08a73e77665c69ae341eeaa9bacb1e` |
| **`GradRewardSet`**（新） | `0x9599916e1ec89bc4cc6bb6fd4d484a3e048ed79c0f5b0066d634bc48b3756322` |
| `TaxConfigured` | `0x3bc87c2d96d2f8e962c46d6bd7625cc3ad910dc67e7a994e662f083016553837` |
| `GradTargetSet` | `0x618fb44f46e66a976e8e5385a2544dc738337d56845a811ee562221ade51276e` |
| `TokenVersionSet` | `0x37502bf23c59a12e1036e7580a8dc056803623dbcd0885abb882adfa069ac89e` |
| `Buy` | `0x6e59ac1e0b7a4b5c385ffff3601e05644c2ed9d875089895ed1b88e9cf8c632a` |
| `Sell` | `0x00055e00ae56ca9d108326c7fd1ab1e6380614100b19bf3e4d1411240a726d86` |
| `TradeV1` | `0x8fe08cbd837b8f1fe65dcf0a55911afb50504bac0d010a771cf6517c1b788e44` |
| `Graduated` | `0x6da2ac486174425e3bbc9aab3a6fd9ee8fb4d1c1e769a02af4a159b37c52eea9` |
| `Minted`（打新） | `0xff1b99c8afce899f46662ffc7045877162dd660b4cacca896efb18ce5e64c3fa` |
| `Withdrawn`（打新） | `0xbe561b8cf046c475f2977c8807c6f56b597c01a3f3fea4002eb4cb6f09abe092` |
| `Launched`（打新） | `0xec774f0683e9ac48e8d835f412f9f877a8a5dee9af3170d78cf3ef33149d15e7` |
| `Minted`（飞轮） | `0x8f9cc53f42d35118d48a1cb6cff6d69109ae0898e83402061ffe1e4d05748be0` |
| `Withdrawn`（飞轮） | `0x3cae9923fd3c2f468aa25a8ef687923e37f957459557c0380fd06526c0b8cdbc` |
| `Filled`（飞轮） | `0x85cf40d84d6e23927a3b507902262cb6e829d476d0e46722518785897ed1a2da` |
| `Launched`（飞轮） | `0xd113672859919fb75607f9e7df716114585bc03e2c4cb89ca2b2a7e8220c90bc` |
| `PostMinted`（飞轮） | `0x81ad74bc574632fc220e6fbdd5c4da7c2cee7ed5de54044aac67b20bd6e80bc9` |
| `VaultBound` | `0x3474868d5e2db3028627dab0ff7345d4aac8d6dc5eeb6b5f35f46b9b5a39787a` |
| `GatewayBuy` | `0x9828eaefd7a1f02e78ee10125bca3eeca7ad1b87907d03057742fac8f520dfe7` |
| `GatewaySell` | `0x42deea76096e7a38fdb0ec58b62beb5ea839582f8b756772fd8fc90427f9befd` |
| `GatewaySellTo` | `0x92fe42d6ca4817042eeebf0516fe66e786725dadbd6f4806d861888cbf404212` |
| `Routed` | `0xfff339d8a0da977cfdcb957089b28d2fc1d040f6071147cce851c9f3babb4c94` |
| `CallerSet` | `0xa49dcb99ff1593e316d0955614d970424bf97f34f406b6b75297ddb7e315b7db` |
| `GangSwapMigrated`（migrator 发出，新） | `0x00b731c769d2b83001ed9ce65228cf08a36967b087536cca6fff4e19f9c5cc02` |
| `FeeTaken`（GangSwap pair 发出，新） | `0xb4d6a97bdd3b0279677829534375db2695a0fb46143b58f29faeead6ccf6f9cd` |
| `BoostStep`（Boost 发出，新） | `0x7271ee4121d280b1822a2b08137bbaddfbaee594fdefb2f54505505abf227875` |

## 10. 安全要求和加白

- 用户授权给的是 3.0，你们的合约不持有授权。只有用户本人发起的交易才能用到（`from == tx.origin`）。建议按卖出数量精确授权。
- 卖出加白前我们会看代码：
  1. `from` 必须是**调用你们路由的用户**（路由的 `msg.sender`，逐层传下去），不能用 `tx.origin` 或调用方可填的参数。
  2. 直接调 3.0 的 adapter / executor 只接受你们自己路由的调用。
  3. 不能有开放的任意调用入口；不能用 Permit2 / 签名订单的 payer、ERC-2771 `_msgSender` 或 storage 里的“当前用户”作 `from`。
  4. 多跳所得只能在同一笔调用里用于这位用户；没有公开 sweep，没有“按合约余额花钱”的路径。
  5. 只能加白合约。可升级的请说明升级权限归谁。
- 3.0 是可升级代理，升级权限在 Gang 的 2-of-3 多签，升级立即生效、没有时间锁。可监听 `Upgraded(address)`（topic0 `0xbc7cd75a20ee27fd9adebab32041f755214dbc6bffa90cc0225b39da2e5c2d3b`）。

**请提供**：① 主网和测试网上**直接调用 3.0** 的合约地址，以及 `from` 的来源；② 多跳是否能收原生 BNB；③ 测试网联调钱包。

## 11. 从 GangGateway 迁移

报价、买入和单跳卖出的 ABI 相同：把调用地址和用户授权对象换成 3.0，并申请在 3.0 上加白。另外注意：3.0 对有门槛的打新返回 status 1（网关是 3）；GangSwap 币（类型 4）和多跳卖出只在 3.0 上有。网关上已开放窗口的普通曲线币可以给没有 Agent ID 的用户报价。

## 12. 测试网（chainId 97）

| 项 | 地址 |
|---|---|
| **GangLaunchpad 3.0** | `0x0508232833aE6849c03b28F7aA248BBd5cFCceE2` |
| GangPadRegistry | `0xB11B83C83DEd269B040faecC1D61B4885BA8e56e` |
| 飞轮税处理器 | `0x2d03F8638F8D1Bcb6836670C20edE0e47d65231f` |
| WBNB | `0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd` |
| Agent ID | `0x24D0A2106AC3Ebf7d770d19f4aF0a5149ebe5B2a`（测试网可直接调 `register()` 领取） |
| GangSwapMigrator | `0x1B942d7eA4B9C2229e6776150d989ab1E6aDD36A` |
| GangSwapFactory | `0x90aF66E555E8C90fFFd0780cF4ca56A8313CEA36` |
| GangSwapRouter | `0x1EAdAEe9b7C04Db9b828CcC342c3Ef2355722d94` |

飞轮联调币：`0x58fDC010FCaE18fB1E8D277BA23D8eA6c3114dd4`（内盘中）。已毕业的窗口币（Pancake）：`0x858093c2bBBB7a140F4c7C43d3Ce01f9c6b1AbCD`。

## 13. 上线前自测清单

- [ ] 未知 status 不路由；status 2 和 4 走不同场所。
- [ ] `tryBuy` 传真实用户；曲线币卖出前查 `canTradeCurve`。
- [ ] 没有 Agent ID 的钱包：未开放的币不给路由，已开放的币能买能卖，且能超过 1%。
- [ ] 买到毕业的那笔：gas 足够、余款（WBNB / 计价币）归用户、随后重查 status。
- [ ] 打新 / 飞轮按整份发金额；飞轮每份 100,000。
- [ ] 卖出 A 和 B 在加白后成功；`minFunds` 按净额。
- [ ] GangSwap：1% 费率、有效储备报价、TVL 用 `realQuoteReserve()`、按余额执行用 `quoteBalanceBase()`。
- [ ] 有税币用 SupportingFeeOnTransfer，gas 不要卡太紧。
- [ ] 成交量不重复计 `TradeV1` 和 `Gateway*`。

主网可用来只读测试的币（状态会变，以链上为准）：

| 场景 | 代币 | 2026-11-25 状态 |
|---|---|---|
| 窗口已开放，ANTB 计价 | `0xe5274b78b457de979d3789e0b7f0205174beabcd` | kind 1，status 1 |
| 窗口已开放，BNB 计价 | `0x1ab62f36a9107cb8a0850fe3e3015a9e28e5abcd` | kind 1，status 1 |
| GangSwap，窗口已开放 | `0xc9a9e601a546de595ca305f8b82650432c2fabcd` | kind 4，status 1 |
| GangSwap，只限 Agent | `0x853fef3517117829c238936b9029df07837fabcd` | kind 4，status 1 |
| 打新 | `0x216d66e196f760b3cb16a3991636db03579cabcd` | kind 2，status 1 |
| 铸币飞轮 | `0xa3857930e397a8232448abe731852b12d76fabcd` | kind 3，status 1 |
| 已毕业（Pancake） | `0x05b3bd953161dd4d952405a8736ef4885a3fabcd` | kind 1，status 2 |

这些代币由用户创建，仅用于接口测试，不构成推荐。
