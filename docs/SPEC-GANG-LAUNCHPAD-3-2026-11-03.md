# 规格 · GangLaunchpad 3.0：固定地址的可升级 pad，内置聚合器入口

- 日期：2026-11-03
- 源码：`src/gang/GangLaunchpad3.sol`、`src/gang/CurveLogic3.sol`、`src/gang/LegacyRoute.sol`、`src/gang/interfaces/IGangLaunchpad3.sol`
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
- **交易者检查**：`_checkCurveTrader` / `_lockedOf` 这两个钩子，本地买卖和入口都会走（这一版里都是空的）。以后的版本如果让钩子拒绝某些交易者，`tryBuy` 也必须对这些交易者报 0。

## 2. 交易接口

**2.0 原有的接口全部保留**：`create` / `createWithGradTarget` / `buy` / `sell` / `buyFor` / `sellFor` / `claimCreatorFee`、打新的 `create` / `mint` / `withdraw` / `mintFor` / `withdrawFor`，以及所有查询函数。曲线和打新的规则与 2.0 相同。

**新增的聚合器入口**（和 four.meme TokenManager2 / Helper3 以及现有 GangGateway 的接口形状一致，现成的适配器可以直接套用）：

| 函数 | 说明 |
|---|---|
| `getTokenInfo(token)` | `status`：0 = 不是 Gang 币；1 = 在曲线上（或飞轮开盘前）；2 = 已毕业 / 已开盘（返回 `pair`）；3 = 打新进行中（入口不交易）。WBNB 计价返回 `quote = address(0)` |
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

## 3. 老 pad 的币也经 3.0 交易

- **怎么做到**：Safe 在每个支持路由的老 pad 上执行 `setRouter(3.0, true)`。之后，3.0 的入口收到老币时，按 GangPadRegistry 查到它所在的 pad，转去调用那个 pad 的 `buyFor` / `sellFor`（铸币飞轮：`mintFor` / `mintPostFor` / `withdrawFor`）。逻辑和现在的 GangGateway V2 相同。
- **能转发的 pad**：GangLaunchpad 1.0、2.0、金库版、铸币飞轮 V1 / V2 上的曲线币和飞轮币。
- **不转发的**：
  - LaunchpadV2 / Soft / U / S 这几个更早的 pad，没有 `buyFor` 和 router 列表，只能在它们自己的 pad 上交易；
  - 老 pad 上的打新（`status = 3`），这一版不转发，和 Gateway 一致；
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
- handler 如果归一个 GangHandlerAdmin 管，这个 admin 的代码也必须是本次构建的，而且没有待接收的 owner。

## 6. 升级流程

`script/UpgradeGangLaunchpad3.s.sol`：

1. 新实现由 `PAD3_IMPL` 指定，或者由脚本按当前实现的依赖地址现场部署。脚本先确认：
   - 新实现的 7 个依赖和当前实现完全一致；
   - 新实现已锁定，不是当前实现，带有入口函数；
   - 新实现的代码，和脚本在模拟里用本次构建现场部署的一份参照合约（`_newImpl`，依赖地址相同）逐字节一致，链接的库地址也必须相同。所以把 `PAD3_IMPL` 换成一个外观相同但另有代码的合约，或者链接了别的库，检查都不会通过。以后的版本改写 `_newImpl` 即可；
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
