# 规格 · GangLaunchpad 3.0：固定地址的可升级 pad，内置聚合器入口

- 日期：2026-11-03
- 源码：`src/gang/GangLaunchpad3.sol`、`src/gang/Pad3Module.sol`、`src/gang/Pad3VaultStore.sol`、`src/gang/CurveLogic3.sol`、`src/gang/LegacyRoute.sol`、`src/gang/interfaces/IGangLaunchpad3.sol`
- 部署：`script/DeployGangLaunchpad3.s.sol`；升级：`script/UpgradeGangLaunchpad3.s.sol`；测试网验收：`script/GangLaunchpad3TestnetAcceptance.s.sol`

## 0. 为什么做

到 2.0 为止，每加一个功能就要部署一个新 pad，地址也跟着变。聚合器的下单适配和行情索引都写死了 pad 地址，每出一个新 pad 就要重新接一次，否则新 pad 上的币就显示不出来、交易不了。

3.0 的目标是：**一个以后不再变的地址**。交易、报价、查询、事件都在这个地址上；新功能通过升级这个地址背后的实现来上线，不再出新 pad。老 pad 上的币也可以通过这个地址交易（§3）。

## 1. 升级模型

- **代理**：OpenZeppelin 5.1 的 `TransparentUpgradeableProxy`。代理的构造函数里就执行 `initialize(owner, pairFactory)`，不存在别人抢先初始化的窗口。实现合约的构造函数调用 `_disableInitializers()`，实现本身永远不能被初始化。
- **权限**：
  - 升级权：代理创建的 `ProxyAdmin`，owner 是平台 Safe 多签。没有时间锁，升级立即生效。
  - pad 设置（router、聚合器白名单、Agent 门槛等）：pad 自己的 owner（`Ownable2Step`），也是平台 Safe。
  - `renounceOwnership` 被禁用（`RenounceDisabled`），否则 pad 没有 owner 之后，被攻破的 router 或白名单调用者就再也撤不掉了。
- **依赖地址**：报价币登记表、分红金库、平台费桶、税处理器、TokenDeployer、WBNB、GangPadRegistry，共 7 个，写在实现合约的 immutable 里，每笔交易的 gas 和 2.0 一样。每次升级，新实现必须带同样的 7 个地址；升级脚本会在打印 Safe 交易前逐个比对（§6）。
- **每个币的规则版本**：`tokenVersionOf(token)` 记录这个币创建时的 `TOKEN_VERSION`（3.0 首版为 1），并发 `TokenVersionSet`。**升级不改已有币的规则**：曲线参数、毕业门槛、费率都按币固定；新规则只给新版本号的币用。
- **存储**：只能在最后追加新变量，不能重排、改类型或删除，继承列表也不能改。`test/gang3/GangLaunchpad3Layout.t.sol` 锁定了每个槽位，以及 `Config`、`Curve`、`Sale`、`Position` 每个结构体成员的位置。`Config` 内联在槽位 3–6，布局测试不允许再给它加成员，新设置要放进新变量。以后新增的状态建议放进 ERC-7201 命名空间结构体。
- **事件只增不改**：2.0 的事件照发，签名不变；新信息用新事件（§4）。
- **需要初始化的新版本**：把常量 `INIT_VERSION` 改为 n，`reinitializer(INIT_VERSION)` 和 `initVersion()` 都用这个常量；初始化调用必须和升级放在同一笔 `ProxyAdmin.upgradeAndCall` 里，否则中间可能被抢先调用。升级脚本会强制执行这一条。
- **交易者检查**：`_checkCurveTrader` / `_lockedOf` 这两个钩子，本地买卖和入口都会走。金库模式（§9）用它们拒绝币自己的金库交易、把锁仓量算进 1% 上限；对 3.0 自己的币，`tryBuy` 对被拒绝的交易者报 0（老 pad 的币按老 pad 的规则成交，报价不看老 pad 的金库）。以后的版本再加拒绝规则，`tryBuy` 也必须同步。
- **模块**：实现合约超过 24 KB 限制之前，把一部分函数放进模块 `Pad3Module`。实现合约里没有的选择器，由 `fallback` 用 delegatecall 转给模块，模块地址是实现合约的 immutable（构造函数第 8 个参数）。所以模块运行在代理的存储、余额和 `msg.sender` 下，对外仍是同一个地址、同样的选择器。模块必须逐个声明和实现合约相同的存储变量（顺序、类型、结构体成员都相同，布局测试逐项比对），自己的新状态放在 ERC-7201 命名空间里。模块单独调用时，它自己的存储是空的，owner 是 `0xdEaD`，什么也改不了。升级时模块和实现合约一起换：新实现带新模块的地址。不允许再串一层：模块自己不设 fallback 转给第二个模块（脚本和布局测试只检查一层）。实现合约的 ABI 里没有模块的函数、事件和 error，BscScan「Read as Proxy」和按 ABI 生成接口的链下代码要用两者合并后的 ABI；金库事件由 3.0 代理地址发出。

## 2. 交易接口

**2.0 原有的接口全部保留**：`create` / `createWithGradTarget` / `buy` / `sell` / `buyFor` / `sellFor` / `claimCreatorFee`、打新的 `create` / `mint` / `withdraw` / `mintFor` / `withdrawFor`，以及所有查询函数。曲线和打新的规则与 2.0 相同。

**新增的聚合器入口**（和 four.meme TokenManager2 / Helper3 以及现有 GangGateway 的接口形状一致，现成的适配器可以直接套用）：

| 函数 | 说明 |
|---|---|
| `getTokenInfo(token)` | `status`：0 = 不是 Gang 币；1 = 可经入口交易（曲线上、飞轮开盘前，或设了门槛的打新进行中）；2 = 已毕业 / 已开盘（返回 `pair`）；3 = 没设门槛的打新进行中（入口不交易）。WBNB 计价返回 `quote = address(0)`。打新和飞轮的 `protocolFeeBps` 是铸造费率，`graduationLeft` 是剩下的份数乘以单价 |
| `tryBuy(token, trader, 0, funds)` | 按金额报价，`amount` 必须是 0。会 revert 的情况一律返回全 0。`trader = address(0)` 表示新钱包，不查门槛 |
| `trySell(token, amount)` | 扣掉 pad 1% 手续费后能拿到的金额和这笔手续费；不卖得出时返回 0 |
| `buyTokenAMAP(token, to, funds, minAmount)` | `to` 必须是发起交易的钱包（`tx.origin`）。WBNB 计价：`msg.value == funds`，直接用原生 BNB；ERC-20 计价：`msg.value == 0`，从调用者扣 `funds`。因额度或毕业被截断的部分退给 `to`（WBNB 计价退 WBNB） |
| `sellToken(0, token, from, amount, minFunds, feeRate, feeRecipient)` | 卖 `from` 授权给本 pad 的币。调用者必须是 `from` 本人，或在白名单里（`isCaller`）。`from` 必须是 `tx.origin`。路由手续费 `feeRate ≤ 500`（5%）给 `feeRecipient`，其余给 `from`；WBNB 计价付原生 BNB。有手续费时，`feeRecipient` 不能是 0、本 pad 或 WBNB（手续费会被烧掉，或者留在 pad / WBNB 合约里，谁也取不出来） |
| `sellToken(0, token, from, to, amount, minFunds)` | 多跳卖出，签名和选择器（`0x930cc050`）与 four.meme TokenManager2 相同。卖 `from` 授权给本 pad 的币，扣掉 pad 1% 手续费后的全部所得付给 `to`：WBNB 计价付原生 BNB，其他计价付计价 ERC-20。聚合器的 router 拿这笔钱继续下一跳。`to` 必须就是调用它的合约本身，并且在白名单里（否则 `RecipientNotListed`）；`from` 必须是 `tx.origin`。这一点比 four.meme 严：four.meme 允许任何调用者把所得指给名单里的任意合约，这里用户直接调用、或者一个名单合约把钱指给另一个名单合约都不行，防止所得停在一个谁都能取走余额的合约上。没有路由手续费参数，`minFunds` 按 `to` 实际收到的净额计算 |

- **白名单**：`setCaller(caller, allowed)` 只有 owner 能调；只接受合约，不接受 EOA 或 EIP-7702 委托的 EOA。`setRouter` 也一样，只接受合约。名单有两个用途：
  - 谁可以替卖家调用 `sellToken`；
  - 谁可以收多跳卖出的所得。

  每个加入名单的合约都要审查：
  - 卖家只能取它自己的 `msg.sender`；
  - 收到的卖出所得只能在同一笔调用里继续用于这位卖家的路由；
  - 不能有谁都能调用的 sweep，也不能有「按合约当前余额花钱」的路径。

  名单合约一旦出问题，用户的损失可能达到卖出所得的 100%；7 参数 `sellToken` 的所得总是回到卖家本人，路由手续费最多 5%（经误加白的合约强卖时，攻击者压价还会让损失更大，见 AUDIT-BRIEF §25 的 M-1）。
- **多跳**：
  - Gang 币做第一跳（卖出）：用多跳卖出，所得进聚合器的 router。
  - Gang 币做最后一跳（买入）：router 用前一跳换来的 BNB 或 ERC-20 调 `buyTokenAMAP`，`to` 填用户本人。
  - 毕业前代币锁仓，只有 pad 能转出，所以币本身不能进 router：卖出时由 pad 直接从用户钱包扣，买入时直接发到用户钱包。Gang 币不能做中间一跳。
- **Agent 门槛关闭时**：入口不接受买入（和 `buyFor` 的 A-2 规则一致），卖出不受影响。
- **报价和成交一致到 wei**：`tryBuy` 和 `buyTokenAMAP` 用同一套计算，`trySell` 和 `sellToken` 也一样。`trySell` 不检查卖家的 Agent 资格：门槛开启时，非 Agent 卖出会 revert，但报价不是 0。
- **毕业后**：入口不再交易这个币，`getTokenInfo` 返回池子地址，由聚合器自己去 DEX 路由。毕业后代币解锁，和普通代币一样可以多跳。
- **打新**（3.0 自己的，以及经 §3 转发的 1.0 / 2.0 的）：只有设了门槛（`Sale.gate`，创建时的 Agent 门槛快照）的发售经入口交易，买卖两边都是；没设门槛的（status 3）入口一律不交易（`RouterNeedsGate`，`tryBuy` / `trySell` 报 0），它的持有人照常直接在 pad 上 `withdraw`。规则和 `mintFor` / `withdrawFor` 相同（A-2）。看的是发售自己的门槛快照，不看 pad 当前的 `agentGateEnabled`：pad 关掉门槛后，设了门槛的发售仍经入口交易。
  - 买入：`funds` 能买的最多整份（单价加铸造费，费按向下取整），按发售的单钱包上限（0.25%–1%）和最后一份截断；`to` 必须是这个门槛的 Agent。`minAmount` 按整份的代币数量计（向上取整到整份）。`tryBuy`：`estimatedCost` 含铸造费；`amountMsgValue` / `amountApproval` / `amountFunds` 都是这些整份的实际花费（≤ `funds`），照它发送就分毫不差，多发的部分会以 WBNB / 计价币退给 `to`。`trader = address(0)` 时按新的 Agent 钱包报价，成交时再查 Agent。一份不到的钱 `FundsTooLow`。铸币飞轮的买入也一样按实际花费给出 `amountMsgValue`。按实际花费发送没有余量：打新和开池前的飞轮价格固定，不受影响；开池后的飞轮按阶梯定价，报价和成交之间有人先成交跨过阶梯时会少买一份或 `FundsTooLow`（`minAmount` 兜底），想留余量就多发，多出的部分以 WBNB / 计价币退回。
  - 卖出：只接受整份（`amount` 是 50,000 代币的整数倍，否则 `NotWholeShares`；开池前代币锁仓，余额一定是整份，按比例卖要先去掉零头），按单价退款，扣退出费（1%–2%，发售停滞 7 天后为 0；之后有人铸造满 10 份，退出费会恢复，卖出的 `minFunds` 要留出这个余量）。代币用卖家授权给 3.0 的额度拉回（和曲线币卖出一样），路由手续费和多跳卖出照常。`trySell` 和成交一致；它只看发售，不看卖家自己的持仓和授权。
  - `getTokenInfo`：`protocolFeeBps` 是铸造费率（只在买入时收），`graduationLeft` 是剩下的份数乘以单价，不含铸造费，有人撤出时会变大。
  - 卖满的最后一份在这笔入口买入里开池（这笔的 gas 明显更高）；开池后入口不再交易（`NotCurveToken`），`getTokenInfo` 返回池子。开池后的持有线、分红和 1% 税按打新的规则。
  - GangGateway（旧入口）对同一个打新币仍然报 3、不交易。

## 3. 老 pad 的币也经 3.0 交易

- **怎么做到**：Safe 在每个支持路由的老 pad 上执行 `setRouter(3.0, true)`。之后，3.0 的入口收到老币时，按 GangPadRegistry 查到它所在的 pad，转去调用那个 pad 的 `buyFor` / `sellFor`（打新：`mintFor` / `withdrawFor`；铸币飞轮：`mintFor` / `mintPostFor` / `withdrawFor`）。曲线币和飞轮币的逻辑和现在的 GangGateway V2 相同；打新按 §2 的规则，报价用老 pad 自己的 `previewMint`，另外检查买家是该发售门槛的 Agent。
- **能转发的 pad**：GangLaunchpad 1.0、2.0、金库版、铸币飞轮 V1 / V2 上的曲线币和飞轮币，以及 1.0、2.0 上设了门槛的打新（开池前）。
- **不转发的**：
  - LaunchpadV2 / Soft / U / S 这几个更早的 pad，没有 `buyFor` 和 router 列表，只能在它们自己的 pad 上交易；
  - 没设门槛的打新（`status = 3`）：老 pad 的 `mintFor` 拒绝它（A-2）；
  - 金库版的 `vaultLock` / `vaultRelease`，只能由金库调用，本来就不是交易。
- **规则沿用 Gateway**：trader 必须是 `tx.origin`；卖出只接受卖家本人或白名单合约；路由手续费 ≤ 5%；买到的币由老 pad 直接打给用户。卖老币时，用户授权给 3.0。多跳卖出同样适用于老币：老 pad 把卖出所得付给 3.0（它的 router），3.0 再把全部所得转给 `to`。
- **储备保护**：转发前后，3.0 自己持有的该计价币余额必须完全相同，否则回滚（`EscrowMoved`）。3.0 只对受信 pad 授权本次的 `funds`，用完立刻归零。
- **行情**：老币的 `Buy` / `Sell` 仍由老 pad 自己发出，应以老 pad 的事件为准，因为也有交易直接打到老 pad，不经过 3.0。3.0 转发时另外发一个 `Routed`，用于归因。
- **GangGateway**：保持运行，已经接入的聚合器不受影响。3.0 也把 Gateway 列为 router，所以经 Gateway 也能交易 3.0 的币。

## 4. 事件

- **2.0 的事件全部照发、签名不变**：`Created`（曲线 / 打新两个重载）、`TaxConfigured`、`Buy`、`Sell`、`CreatorFeeAccrued`、`Graduated`、`Minted`、`Withdrawn`、`Launched` 等。原来按 2.0 解析的索引器不用改。
- **`TokenVersionSet(token, version)`**：每次创建时发。
- **`TradeV1(token, trader, isBuy, quoteAmount, tokenAmount, protocolFee, creatorFee, postPrice, realQuote, sold)`**：每笔曲线交易都发，紧跟在 `Buy` / `Sell` 之后。
  - `quoteAmount`：买入是 pad 实际收下的金额（含手续费、不含退款，等于 `GatewayBuy.fundsUsed`）；卖出是曲线扣手续费前付出的金额；
  - `protocolFee`：1% 手续费；`creatorFee`：其中归 creator 的部分，平台部分 = `protocolFee - creatorFee`；
  - `postPrice`：成交后的边际价格（每 1e18 代币多少 quote wei）；`realQuote`、`sold`：成交后的曲线状态（触发毕业那笔记的是毕业前的值）；
  - 路由手续费不在这里，在 `GatewaySell.routerFee` 里。
- **`GatewayBuy` / `GatewaySell`**：入口的每笔交易都发，签名和 GangGateway 相同（同一个 topic）。
- **`Routed(token, pad, trader, isBuy, quoteAmount, tokenAmount)`**：入口转发老币时发，带上目标 pad。
- **`GatewaySellTo(token, trader, to, caller, amount, funds)`**：多跳卖出，`funds` 付给了 `to`。这一版 `caller` 恒等于 `to`，字段留着，以后放宽规则时不用改事件。
- **`CallerSet(caller, allowed)`**：白名单变更。

## 5. 部署和 Safe 批次

`script/DeployGangLaunchpad3.s.sol` 沿用 2.0 的两阶段流程：

1. **阶段 1**：部署 3.0 自己的 GangTaxHandler、实现合约、代理（`ProxyAdmin` 归 OWNER）和 GangRouter，并完成部署钱包自己能做的设置。
   - 主网上必须带 `PAD3_NEW=true`；Registry 里已经有一个 3.0 时拒绝部署，防止重复部署。
   - 只链接线上的 PoolCheck（`--libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B1…bDb3`），其他库由脚本新部署。
   - 结束时打印 `GANG_PAD3_DEPLOYER_NONCE`，阶段 2 要用。
2. **Safe 批次 1**：在共享合约上登记 3.0（分红金库、迁移器、TokenDeployer、平台费桶、GangPadRegistry），共 9 笔。
3. **阶段 2**：从链上读回全部配置并核对，开始移交 owner。在 Safe 接手之前，还要确认部署钱包没有私下加过东西：
   - 部署钱包的 nonce 必须等于阶段 1 结束时的值，加上阶段 2 自己发出的移交交易。多发了任何一笔交易都拒绝。
   - handler 的税收接收方列表为空。
   - 如果有能完整返回日志的 RPC，可以再加 `PAD3_LOG_SCAN=true`，扫描 pad 的 `RouterSet` / `CallerSet` 事件。

   **签批次 2 之前，立刻再只读跑一次阶段 2。**
4. **Safe 批次 2**：接受 handler 和 pad 的所有权，`setMigrator` 开放 3.0。
5. **Safe 批次 3**：老 pad 执行 `setRouter(3.0, true)`。批次 3–5 要等 OWNER 真正拿到 pad 和 handler 之后才会打印：光开放了还不够，pending owner 也必须为空。
6. **Safe 批次 4**（有 `CALLERS` 时）：给聚合器合约加白名单。
   - 主网上必须提供 `CALLER_CODEHASHES`，和审核时记录的 codehash 逐个比对。
   - 可升级代理默认拒绝，因为代理的 codehash 说明不了背后的逻辑；确实要加时设 `CALLERS_PROXY_OK=true`，脚本会打印代理背后的实现地址。
7. **Safe 批次 5**（只在带 `CUTOVER=true` 时打印）：1.0、2.0 停止发币。等后端、网站、CLI 和模块都切到 3.0 再执行。金库版和铸币飞轮继续发币。

**运行规则**：
- 阶段 1 和阶段 2 必须用同一份代码和编译设置运行。构建一旦变了，参照合约对不上，forge 还会在模拟里补部署新的库，阶段 2 会因此拒绝。
- 从阶段 1 结束到 Safe 执行批次 2，部署钱包不能发任何交易，失败的交易也算。否则 nonce 检查会拒绝，只能人工逐笔核对后再改 `GANG_PAD3_DEPLOYER_NONCE`。
- 只允许用 `--libraries` 指定 PoolCheck。CurveLogic3、FairLogic、LegacyRoute 必须交给 forge 从本次构建部署，被显式指定会直接拒绝。
- 3.0 升级之后，再跑阶段 2（比如打印批次 4、批次 5，或做复查）时，要用当前线上实现对应的那次提交来跑。否则参照合约对不上，会报 `pad implementation code`。

批次 3–5 打印之前，脚本会先以 owner 身份在模拟里执行一遍，确认结果正确再回滚。脚本读回时会核对：

- 代理的代码；
- ProxyAdmin 是代理自己创建的那个，代码就是 OpenZeppelin 原版，owner 正确；
- 实现合约已锁定，代理已初始化；
- 实现合约的代码，和脚本在模拟里用本次构建、相同依赖现场部署的参照合约逐字节一致（只有 metadata 不比）。链接的库地址也必须相同：forge 用 CREATE2 部署库，地址由代码决定，所以库也是本次构建的。主网上，PoolCheck 还必须是线上那一个；
- 7 个依赖地址；
- handler 如果归一个 GangHandlerAdmin 管，这个 admin 的代码也必须是本次构建的，而且没有待接收的 owner；
- 实现合约指向的模块，代码和本次构建、相同依赖现场部署的参照模块逐字节一致（依赖是模块的 immutable，代码相同即依赖相同），`TOKEN_VERSION` 和实现合约相同。模块只经 CurveLogic3 用到 PoolCheck，而 CurveLogic3 由本次运行部署，链接的库已由实现合约那一项钉在线上的 PoolCheck 上。

## 6. 升级流程

`script/UpgradeGangLaunchpad3.s.sol`：

1. 新实现由 `PAD3_IMPL` 指定，或者由脚本按当前实现的依赖地址现场部署。脚本先确认：
   - 新实现的 7 个依赖和当前实现完全一致；
   - 新实现已锁定，不是当前实现，带有入口函数；
   - 新实现的代码，和脚本在模拟里用本次构建现场部署的一份参照合约（`_newImplWith`，依赖地址相同，指向新实现自己的模块）逐字节一致，链接的库地址也必须相同；它的模块也按 §5 比对。所以把 `PAD3_IMPL` 换成一个外观相同但另有代码的合约，或者链接了别的库、指向别的模块，检查都不会通过。以后的版本改写 `_newImplWith` 即可；
   - 它的 `TOKEN_VERSION` 不低于当前实现；
   - 它的 `initVersion()` 不低于代理当前的初始化版本。如果更高（新版本带 reinitializer），必须提供 `PAD3_INIT_CALL`，和升级放在同一笔交易里；如果相等，不允许带初始化调用。
2. 以 ProxyAdmin owner 的身份在模拟里执行 `upgradeAndCall(proxy, impl, PAD3_INIT_CALL)`，然后检查：
   - 初始化版本等于新实现的 `initVersion()`；
   - pad 的设置（owner、待接收的 owner、工厂、门槛、上限、router、`CALLERS` 的白名单状态等）和升级前相同；
   - 最新 25 个币的原始记录，以及由它们算出的结果（状态、计价币、交易对、毕业金额和剩余、税配置、固定金额的买卖报价、钱包剩余额度、打新的铸币预览、退出费和持有线），和升级前相同。这样变量挪了位置、结构体成员被读错，都能查出来。同类型的两个成员互换时，原始记录看不出差别，要靠这些计算结果和布局测试来发现；
   - 3.0 自身的读回检查通过：代理、实现、库、ProxyAdmin、Registry、入口探针。部署时的固定值（TWAP、keeper、门槛开关等）不再要求，Safe 之后可能正常改过它们。设置有没有被升级改动，由上面的升级前后对比来查。
3. 全部通过后，测试网上如果部署钱包就是 ProxyAdmin owner，直接执行；否则打印 Safe 交易。

每次升级前还要做这几件事：

- 写清这次改了什么；
- 确认所有 `reinitializer` 都用 `INIT_VERSION`，`initVersion()` 也返回它（脚本靠这两处是否一致，来判断要不要带初始化调用）；
- 用新版本那次提交运行升级脚本：参照合约由 `_newImpl` 部署；
- 对新实现跑一遍存储布局测试；
- 在主网 fork 上演练这笔 Safe 交易。
- 把打新开放给入口的那次升级（第一次带打新入口的实现）：升级前仍报 status 3 的、设了门槛的 3.0 打新发售，`getTokenInfo` 和 `tryBuy` 这两项会按设计改变，脚本在前后两次快照里都不比较这两项（它们的原始记录和其余计算结果照常比较），升级后再确认它们报 status 1。之后的升级里它们已经是 1，不再例外。
- 确认模块依赖的接口没变，并在新实现上重跑 `test/fork/Pad3ModulesFork.t.sol`：在新版本那次提交上运行，`PAD3_FORK_IMPL` 填已部署的新实现（fork 上先以 Safe 身份升级），`PAD3_FORK_LIVE=true` 并通过 `HANDLER_ADMIN`、`SPLITTER_FACTORY`、`SPLIT_FACTORY`、`LP_FACTORY`、`COMBO_FACTORY`、`GANG_BOND` 传入线上那套模块，测试会让线上工厂的新克隆和 bond 在新实现上跑一遍。这个模式不带 `--libraries` 运行：工厂脚本比对的是整段运行时代码（含 metadata），`--libraries` 会改变它；阶段 2 读回由升级脚本自己做。GangBond、GangHandlerAdmin 和四个模块工厂及其克隆永久绑定 3.0 的地址，克隆初始化时还缓存了 `taxHandler`、`wbnb`、`quoteRegistry`，所以升级不能改动：`kindOf` 的取值、`curves` 的前 12 个字段、`sales` 的前 14 个字段（顺序和含义）、`isAgent`、`taxHandler()`、`wbnb()`、`quoteRegistry()`。改了它们，已部署的模块和押在 GangBond 里的 BNB 会出错或卡住。2.0 不可升级，所以没有这层依赖；发 bond 的用户也要知道这层信任关系。

## 7. 已知行为和风险说明

- **毕业截断的 1 wei**：触发毕业的那笔买入被截断时，手续费按向上取整重算，pad 收下的会比账面多 1 wei。只会多，不会少，不影响偿付能力。这个行为 2.0 就有。
- **授权**：用户对 3.0 的授权，在本地卖出、入口卖出、卖老币三种场景下都会用到。白名单里的合约可以在用户本人发起的交易里（`from == tx.origin`）使用这份授权。所以每次 `setCaller` 都要按 Gateway 的白名单评审流程审查。CLI 只授权单笔金额。
- **升级权的影响范围**：3.0 没有时间锁，平台 Safe 的升级权立即生效。如果升级出错或 Safe 被攻破，以下资产会立即受影响：
  - 用户授权给 3.0 的额度；
  - 3.0 自己托管的资金：曲线储备、creator 费、打新托管款；
  - 授权过 3.0 的用户，下一次经 3.0 交易时动用的老 pad 资产。

  老 pad 自己的储备不会受影响：老 pad 不可升级，而且只按 `trader == tx.origin` 成交。紧急止损手段是在老 pad 上执行 `setRouter(3.0, false)`。所以每次升级都必须按 §6 演练，并对代理的 `Upgraded` 事件和 ProxyAdmin 的 owner 变更做实时监控。

## 8. 测试

- `test/gang3/Pad3Vault.t.sol`：金库版 pad（GangVaultLaunchpad）的整套测试在 3.0 代理上重跑（3.0 的其他创建入口保持开放，这一条单独改写）；另有入口买卖、金库经入口交易被拒、创建记录和 `createWithGradTarget` 逐项一致、fallback 和模块直接调用的测试。`GangLaunchpad3Layout.t.sol` 比对模块和实现合约的存储布局。
- `test/fork/Pad3VaultUpgradeFork.t.sol`：在 BSC 主网 fork 上用 `UpgradeGangLaunchpad3` 检查并升级线上 3.0 代理，执行打印出的 Safe 交易，然后在同一地址上跑金库币的创建、入口买入、锁仓（计入上限、金库不能交易）、释放、卖出，并确认线上已有的 3.0 币仍可交易。

- `test/gang3/`：
  - 2.0 的曲线、模块和打新测试在 3.0 代理上重跑；
  - 3.0 自己的初始化、升级、权限、存储布局（包括结构体成员）测试；
  - GangGateway 的三套测试把 3.0 当入口重跑，分转发和本地两种；
  - 入口专项测试；
  - 报价与成交的差分 fuzz，以及多曲线、多计价币混合操作下的偿付不变量 fuzz。
- `test/fork/GangLaunchpad3DeployFork.t.sol`：在 BSC 主网 fork 上：
  - 跑完整个部署和全部 Safe 批次；
  - 经 3.0 交易 1.0、2.0、金库版、飞轮 V2 的币，以及 3.0 自己的币，并经线上 Gateway 交易 3.0 的币；
  - 演练升级脚本和一次 Safe 升级；
  - 触发部署脚本的各项拦截检查。

## 9. 金库模式（模块）

规则和金库版 pad（GangVaultLaunchpad）相同，放在 3.0 的同一个地址上，代码在 `Pad3Module`，状态在 ERC-7201 命名空间 `gang.pad3.vault`（`Pad3VaultStore`）。

- **管理**（owner）：`setVault(vault, enabled)` 登记或下架金库：只接受合约，不能是 router；下架时清掉它的指定创建人。曾经登记过的地址（`everVault`）永远不能再被设为 router。`setVaultCreator(vault, creator)` 指定下一个可以用这个金库创建代币的钱包，一次有效。
- **创建**：`createWithVault(..., gradBnb, vault)` 只有被指定的钱包能调，创建后指定作废（创建失败则保留）。代币的曲线、毕业门槛、规则版本、记录和事件与 `createWithGradTarget` 完全一致，另外把这个币和金库永久绑定（`vaultOf`），发 `VaultBound`。3.0 的其他创建入口保持开放，那些币没有金库。
- **锁仓 / 释放**：只能由这个币自己的金库调用，毕业前，`user` 必须是 `tx.origin` 且是 Agent。
  - `vaultLock(token, user, amount)`：金库仍在登记中才能锁。币从用户经 pad 进入金库，记入 `lockedOf`。
  - `vaultRelease(token, user, amount)`：金库下架后也能释放，币不会被困住。币从金库到用户，不受 1% 上限限制；`lockedOf` 最多减到 0。
  - 分红币：两边的分红份额都按余额同步。
- **对交易的影响**（本地买卖和聚合器入口相同）：
  - 用户的锁仓量和钱包余额一起计入 1% 上限，`tryBuy` 的报价也按这个算；
  - 币自己的金库不能买卖这个币（`VaultCannotTrade`），`tryBuy` 对它报 0。
- **查询**：`isVault`、`vaultOf`、`lockedOf`、`everVault`、`vaultCreator`。

同一个模块里还放着几个只给链下用的查询函数（税配置检查、毕业金额、打新的预览和配置检查、退出费等），从实现合约挪过来是为了大小。选择器不变，经 fallback 调用，结果与原来相同；链上只有 GangRouter 的打新 `mintFor` 会调 `previewMint`，经 fallback 照常可用，多一次 delegatecall。升级脚本的前后对比覆盖其中的毕业金额 / 剩余、税配置、退出费和铸币预览，其余几个靠模块代码逐字节比对。

**金库状态的升级规则**：`Pad3VaultStore.Layout` 只能在末尾追加成员，`SLOT` 永远不变。编译器的存储布局不包含命名空间，所以 `test/gang3/Pad3Vault.t.sol` 用 `vm.load` 钉住 `SLOT` 和每个成员的位置；升级脚本在当前实现已有金库模式时，对抽样的币比对金库状态（`vaultOf`、金库的登记 / 历史 / 指定创建人、创建人的 `lockedOf`）。部署和升级脚本要求实现合约和模块各自只链接列出的库（PoolCheck 除外），以后给任一方新增库，要先加进 `_checkNotPreLinked` 的名单。

