# 规格 · 核心与无状态路由（LaunchpadV3 / 打新）

- 日期：2026-10-26 Asia/Shanghai
- 范围：`src/launchpad-v3/LaunchpadV3.sol`、`src/fair-mint/FairMintPad.sol`（两个核心）、`src/router/GangRouter.sol`（路由）。V2 已在主网运行，不动。
- 背景：讨论过把发射合约改成 UUPS 可升级合约，没有采纳。可升级意味着握有升级权限的人能换掉逻辑、拿走全部储备，也会让「税率和接收地址发币后不能改」只剩口头保证。改为 Uniswap 式的「核心 + 外围」：资金和规则留在不可升级的核心里，能换的只有不碰资金的路由。

## 分工

| | 核心（LaunchpadV3 / FairMintPad） | 路由（GangRouter） |
|---|---|---|
| 可升级 | 否，不用代理 | 否；新版本 = 新部署，核心 owner 用 `setRouter` 列入白名单 |
| 状态 | 全部：曲线 / 打新进度、储备、托管手续费、持仓 | 无：没有 storage、没有 owner |
| 规则 | 全部：定价、毕业 / 发射、1% 手续费、买卖税与分账、单地址上限、Agent 门槛 | 无经济规则 |
| 做什么 | 发币、买、卖、打新、撤出、退款、发射 | 原生 BNB 进出（自动换 WBNB）、截止时间、把核心退回的多余部分原样退给调用者 |

## 路由能做什么、不能做什么

核心新增两个入口，只有白名单里的路由能调：

- `LaunchpadV3.buyFor(trader, token, quoteIn, minTokensOut)`：路由付钱（报价币从路由扣）；代币、分红权重、Agent 门槛和单地址上限都按 `trader` 算；上限 / 毕业截断时多付的退回给付款的路由，路由再退给用户。
- `FairMintPad.mintFor(trader, token, shares, minShares)`：路由付成本 + 打新手续费；份额、代币、手续费托管都记在 `trader` 名下，之后的撤出 / 退款只付给 `trader`。
- 两个入口都**只在准入开启时可用**（V3 看 `agentGateEnabled`，打新看该 sale 创建时快照的准入），否则 `RouterNeedsGate`。准入关闭时路由能把 `trader` 指定成未来的池子地址，在发射 / 毕业前往池子里塞代币、分走流动性（内部审计 A-2，`docs/AUDIT-BRIEF-2026-10-26.md` §10）。直接买 / 打新不受影响。

没有对应的「代卖」「代撤出」「代退款」「代领取」：

- 毕业 / 发射前代币是锁定的，只有核心能转（`TransfersLocked`），用户的币进不了路由；如果核心替路由去扣用户的币，一个有问题的路由就能强卖任何人的持仓。所以卖出、撤出、退款、领取都只能由本人直接调用核心。
- 因此在准入开启时，一个被列入白名单的路由最坏也只能「用自己的钱替别人买」：拿不走任何人的储备、代币或份额。测试 `test_v3_listedRouterOnlySpendsItsOwnQuote` / `test_fair_listedRouterOnlySpendsItsOwnQuote` 用一个列入白名单的流氓路由验证：交易者已为卖出给核心授权了代币和报价币，流氓路由也只能自掏腰包替交易者买 / 打新，交易者的报价币、代币、份额都没少；核心上不存在代卖 / 代撤出 / 代退款之类的入口。
- 用户要给每个版本的路由单独授权（ERC-20 路径），或者直接发 BNB（BNB 路径，无需授权）；用不用新路由由用户决定。

`routers` 名单由核心 owner 管理（`setRouter`，有 `RouterSet` 事件）。主网 owner 应是多签。

## GangRouter 接口

| 函数 | 说明 |
|---|---|
| `v3Buy(token, quoteIn, minTokensOut, deadline)` | 用该币的报价币买（先授权给路由）；退回的部分退报价币 |
| `v3BuyBNB(token, minTokensOut, deadline)` payable | WBNB 报价的币，用原生 BNB 买；退回的部分退 BNB |
| `fairMint(token, shares, minShares, deadline)` | 打新，付该 sale 的报价币（成本 + 打新手续费） |
| `fairMintBNB(token, shares, minShares, deadline)` payable | WBNB 报价的 sale 用原生 BNB 打新；`msg.value` 要够，多的退 BNB |

- 每次调用只按自己的余额变化结算；别人误转进路由的币不会被下一个人拿走（也取不出来）。
- 只接受 WBNB 合约解包时发来的 BNB（`OnlyWbnb`）。
- 链上没有某个核心时构造参数传 `address(0)`，对应函数返回 `NotDeployed`。

## 事件与索引

核心的事件没有变：`Buy` 的 `buyer`、`Minted` 的 `user` 都是交易者本人，不是路由。服务端索引、合作方收入统计不用改，只换核心地址。Agent 附言照常附在交易 calldata 末尾（路由的 ABI 解码忽略多出的字节）。

## 验证

- 单元测试 `test/router/GangRouter.t.sol` 19 个：BNB / 报价币两种路径、交易者拿币、门槛和上限按交易者、分红权重归交易者、截断退款、经路由毕业 / 发射、截止时间、只有白名单路由能代买、流氓路由只能花自己的钱、失败后退款给交易者本人。全仓 209 个通过（含内部审计回归）。
- BSC 测试网 fork 上：部署两个核心 + 路由、路由冒烟、V3 整轮（毕业 + 外盘税）和打新整轮（打满 + 发射 + 分账 + 领取）全部通过，打新的关键数字和第一次测试网整轮一致。
- BSC 测试网：部署与冒烟见 `docs/TESTNET-CORE-ROUTER-2026-10-26.md`。

## 体积

| 合约 | 运行时字节码 |
|---|---|
| LaunchpadV3 | 22,065 B |
| FairMintPad | 16,695 B |
| GangRouter | 4,142 B |
