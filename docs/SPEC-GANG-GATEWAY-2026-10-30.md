# 规格 · 聚合器用的内盘网关（GangGateway）

- 日期：2026-10-30 Asia/Shanghai
- 作者：Claude（按和聚合器沟通后的「GangGateway 接口草案」实现，接入方式对齐 four.meme 内盘；卖出调用方白名单是 2026-10-30 用户决定加的）
- 性质：**测试网已部署带卖出调用方白名单的版本 `0xb325dde51129C592E443ecbEE1E219D14C66e091`（列入第 10 套 pad，验收通过；没有白名单的第一版 `0x5020…635c` 已下架），见 `docs/TESTNET-GANG-GATEWAY-2026-10-30.md`**；**主网已部署 `0x9dD16b73f624bdd8a210CBB2602FdF70f1B450B8`（owner、时间锁 = Safe），待 Safe 在 pad 上 `setRouter` 列入，见 `docs/MAINNET-GANG-GATEWAY-2026-10-30.md`**。合约 `src/router/GangGateway.sol`，接口 `src/router/interfaces/IGangGateway.sol`，测试 `test/router/GangGateway.t.sol`、`test/router/GangGatewayLayout.t.sol`、`test/fork/GatewayMainnetFork.t.sol`，部署脚本 `script/DeployGangGateway.s.sol`（自检 `script/GangGatewayDeployLib.sol`）。审计说明见 `docs/AUDIT-BRIEF-2026-10-26.md` §25。

## 一句话

聚合器像接 four.meme 内盘（TokenManager2 + Helper3）一样接 Gang 内盘：用户把代币授权给网关一次，聚合器的合约直接调网关，不需要签名；pad 检查卖家 / 买家等于 `tx.origin`，卖出所得付给用户本人，聚合器可以按 `feeRate`（最多 5%）收路由手续费。**卖出**要求调用方是用户自己（`from == msg.sender`），或是 Safe 加进白名单的聚合器合约；买入不限调用方。

## 为什么要有网关

§23 的 `buyFor` / `sellFor` 要求调用者是 Safe 列入的路由，卖出时花用户给**这个路由**的授权。聚合器反馈：

- 它们的路由合约任何人都能调，让用户把代币授权给它们不安全，它们也不想让用户的授权落在自己合约上；
- 它们没法给调用者加白名单（有客户直接调它们的路由），也不接受每笔卖出再签一次名；
- four.meme 的做法是用户授权给 four.meme 自己的合约，聚合器直接调它。

网关就是这个「自己的合约」：它是 pad 列入的路由，用户的授权给它，聚合器调它。V3 pad 不可升级，所以这是不改 pad 的唯一做法。

## 接口

| 函数 | 对应 four.meme | 说明 |
|---|---|---|
| `getTokenInfo(token)` → `(status, quote, pair, protocolFeeBps, graduationLeft)` | Helper3.getTokenInfo（同 selector，返回结构不同：按 four.meme 解码会回滚） | `status`：0 不是 Gang 币，1 在内盘，2 已毕业 / 已发射（走 Pancake V2 的 `pair`），3 打新还在进行（不能经网关交易）。status 1 只说明币在内盘，**能不能经网关交易以 `tryBuy` / `trySell` 不为 0 为准**（pad 可能还没列入网关，或关了准入）。`quote` 为 0 表示 BNB 计价。`protocolFeeBps` 只在 status 1 时为 100。`graduationLeft` 是扣 1% 手续费后的净额，实际要付约 `graduationLeft × 10000 / 9900` |
| `tryBuy(token, trader, 0, funds)` | Helper3.tryBuy（Helper3 是 `tryBuy(token, amount, funds)`，这里多了 trader，selector 不同） | 返回结构同 Helper3；只支持按资金买（`amount` 必须为 0，否则 `AmountNotSupported`）。会回滚的情况返回全 0：不是内盘币、pad 没列入网关、准入关闭、trader 没有 Agent ID、钱包已满、`funds` 为 0。`trader` 传 0 地址按新钱包报价 |
| `trySell(token, amount)` → `(tokenManager, quote, funds, fee)` | Helper3.trySell | `funds` 是扣 pad 1% 手续费后、扣路由手续费前的所得。会回滚的情况（含 pad 没列入网关）返回 0；dust 也返回 0，这时 `sellToken` 会拿走代币却付 0，**`funds == 0` 就不要卖** |
| `buyTokenAMAP(token, to, funds, minAmount)` payable → `(amountOut, fundsUsed)` | TokenManager2.buyTokenAMAP | `to` 必须是 `tx.origin`。BNB 计价：`msg.value == funds`；ERC-20 计价：从 `msg.sender` 拉 `funds` |
| `sellToken(origin, token, from, amount, minFunds, feeRate, feeRecipient)` → `fundsToSeller` | TokenManager2.sellToken | 调用方必须是 `from` 本人，或白名单里的合约（`isCaller`），否则 `NotWhitelisted`。`from` 必须是 `tx.origin`，事先 `approve(网关)`；`minFunds` 是用户最终到手的金额；`feeRate ≤ 500` |
| `setCaller(caller, allowed)` / `isCaller(caller)` | 无 | 卖出调用方白名单，只有 owner（主网：Safe）能改，即时生效。`transferOwnership` / `acceptOwnership` 两步转移 owner |

报价通过 GangPadRegistry 的 `previewBuy` / `previewSell` 计算，和成交逐 wei 一致（fuzz 测试核对）。

## 与 four.meme 的差异

1. **`minFunds` 是净额**：比较的是扣 pad 手续费和路由手续费之后用户到手的金额；four.meme 比较的是扣费前的曲线总额。按 four.meme 方式算出的值在网关上只会更严，不会更松。
2. **买入的 `to` 必须是 `tx.origin`**（pad 的 `TraderNotOrigin`）：不支持 AA 钱包、代付。
3. **截断退款给用户**：碰到 1% 钱包上限或毕业线时，pad 把没用完的资金直接以计价 ERC-20 退给 `to`（BNB 计价的币退 **WBNB**，不是 BNB），不退给调用者；`fundsUsed` 告诉调用者实际用掉了多少。用 `tryBuy` 返回的 `amountFunds` 作为 `funds` 可以避免退款。
4. **不需要 GWEI 对齐**。
5. **只支持按资金买入**，没有 four.meme 的 `buyToken(token, to, amount, maxFunds)`。
6. **没有「所得付给 `to`」的卖出路径**（four.meme 的 `sellToken(origin, token, from, to, amount, minFunds)`）：没有实现。需要时升级加上（48 小时时间锁）。
7. **卖出要求调用方在白名单里**（或用户自己直接调）；four.meme 的开放卖出路径谁都能调。

## Gang 自身的规则（照旧由 pad 执行）

- Agent 准入：`to` / `from` 必须持有 Agent ID，否则 `NotAgent`。
- 1% 钱包上限：`tryBuy` 已计入，超出部分退款。
- 毕业：跨过毕业线的那笔买入在同一笔交易里迁移到 Pancake，gas 明显更高；毕业后网关的买卖回滚 `NotCurveToken`。
- 打新代币不能经网关交易。

## 代币和资金怎么走

- 买：调用者的资金 → 网关 → pad；代币 pad → `to`；截断退款 pad → `to`（ERC-20）。
- 卖：代币 `from` → pad（`GangToken.pullFor`，花 `from` 给网关的授权，只在锁定期可用）；所得 pad → 网关 → 解包成 BNB（BNB 计价时）→ `feeRecipient`（手续费）和 `from`（其余）。
- 网关不经手代币，也不留任何余额：每笔调用按自己的余额变化结算。

## 安全模型

- 只有用户自己发起的交易能动用他对网关的授权（pad 的 `trader == tx.origin`）。
- 卖出所得只付给 `from` 本人；路由手续费最多 5%。
- **卖出调用方白名单（防钓鱼，审计 M-1）**：没有白名单时，用户被骗调用的恶意合约可以在用户自己的交易里、不设最低价，把他已授权给网关的内盘代币卖掉，还能同时用自己的库存压价再买回，用户损失审计 PoC 测得 9%～54%。现在 `sellToken` 只接受 `from` 本人直接调用，或 Safe 加白的聚合器合约，钓鱼合约直接 `NotWhitelisted`。
- **只能加白合约**：EOA 和 EIP-7702 委托的账户会回滚 `NotAContract`（加白的 EOA 之后可能挂上中继代码）。
- **加白即时生效，不经时间锁**（接受的风险）：加白一个调用方，它马上就能用用户现存的网关授权替用户卖。Safe 被盗或误操作时，加白恶意合约会复现钓鱼风险；移除同样即时生效。
- **剩余风险在加白审核上**：被加白的合约必须把 `from` 设为**调用它的那个用户**（它的路由的 `msg.sender`，多层调用时一路传下去），不能用 `tx.origin`，也不能让任意调用者自己填 `from`；它的 adapter 也不能被任意合约直接调用。加白等同于 §23.9 的 `setRouter`，按审计说明 §25.10 的五项清单审核（不能有开放的 execute / multicall、Permit2 payer、ERC-2771、从 storage 读回用户；可升级的要监控升级）。如果误加了一个“谁都能填 `from`”的合约，M-1 的攻击会经由它复现（`test/router/GangGatewayPhishing.t.sol` 测了这一点）。
- **仍建议每笔精确授权**（`approve(网关, 本次卖出数量)`，卖完授权归 0）：即使某个加白合约有问题，也没有残留授权可卖。
- 毕业后代币解锁，但网关的代码里没有任何对代币的 `transferFrom`：用户残留的授权只能被 pad 的 `pullFor` 用到，而 `pullFor` 毕业后永远回滚。升级可以改变这一点，所以升级要经 48 小时时间锁。
- 撤销对网关的授权，或者 Safe `setRouter(网关, false)`，都能立即停止经网关的交易。

## 权限与升级

| 项 | 主网 | 测试网 |
|---|---|---|
| 部署形态 | `TransparentUpgradeableProxy`，代理地址永久不变 | 同左 |
| ProxyAdmin 的 owner | 新部署的 TimelockController（48 小时；提案 / 执行 / 取消都只有 Safe `0x2866…B41E`，没有 admin） | `OWNER` 环境变量（默认部署钱包），延迟由 `ROUTER_TIMELOCK_DELAY` 决定 |
| 网关自身的 owner（只管卖出调用方白名单，动不了资金和授权） | Safe 本身，不经时间锁，加白 / 移除即时生效 | 同 `OWNER` |
| 列入 pad | Safe 在每个 pad 上 `setRouter(网关代理, true)`（部署脚本打印 calldata） | 部署钱包是 pad owner 时脚本直接列入 |

pad 的查找走 GangPadRegistry（Safe 直接控制、没有时间锁）。registry 被盗用最多影响**调用者在那一笔调用里自己付的钱**：网关只会从 `msg.sender` 拉资金，从不 `transferFrom` 用户的代币，所以一个假 pad 碰不到用户对网关的授权。买入的 `amountOut` 按 `to` 的代币余额变化计算：真 Gang 币在锁定期只有它自己的 pad 能转出，所以 registry 被改成把真币指向假 pad 时，假 pad 伪造不了成交（`minAmount > 0` 时回滚）。但误登记的 pad 可以为**它自己发的币**伪造成交，这只能靠 Safe 审核 `addPad`。登记新一代 pad 前还要确认它和现有 pad 一样，精确拉取 `funds`，截断退款退给 trader；否则余额会留在网关，`fundsUsed` 也会多报。

## 存储布局

slot 0 `ReentrancyGuard._status`、1 `registry`、2 `wbnb`、3 `owner`、4 `pendingOwner`、5 `isCaller`、6–49 `__gap`（44 个）；`Initializable` 用 ERC-7201 槽。升级规则与 GangRouter 相同。

## 部署

```bash
# 测试网（部署钱包是 pad owner 时会直接 setRouter；GANG_PAD 只列入这一个 pad）
DEPLOYER_PRIVATE_KEY=… GANG_PAD_REGISTRY=<registry 代理> GANG_PAD=<pad> \
  forge script script/DeployGangGateway.s.sol --rpc-url $BSC_TESTNET_RPC_URL --broadcast --legacy --with-gas-price 100000000
# 主网：OWNER 只能是 Safe；之后 Safe 执行脚本打印的 setRouter 和 setCaller（GATEWAY_CALLERS 给出要加白的聚合器合约）
GANG_MAINNET_OK=true DEPLOYER_PRIVATE_KEY=… GANG_PAD_REGISTRY=0x4fF77D4d9ac080939a24E1B805206bA094C44e5C GATEWAY_CALLERS=0x…,0x… \
  forge script script/DeployGangGateway.s.sol --rpc-url $BSC_RPC_URL --broadcast
# 重跑自检：OWNER、ROUTER_TIMELOCK_DELAY 要和首次部署时一样，否则时间锁的检查会报错
GANG_GATEWAY=<网关代理> … forge script script/DeployGangGateway.s.sol --rpc-url …
```
