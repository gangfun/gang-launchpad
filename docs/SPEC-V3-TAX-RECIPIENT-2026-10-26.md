# 规格 · LaunchpadV3 税收接收地址（合作方金库）

> **2026-10-27 下午更新（§19，以本条为准，下文已按此改写）**：**内盘不收税**。V3 税收币在联合曲线上买卖和 V2 一样只收 1% 手续费（全部进平台手续费池，80% 回购 / 20% 金库）；买卖税（1%–5%）只在毕业后的 Pancake 池子里收，外盘规则不变。发币参数照旧，只用于外盘。

> **2026-10-27 更新（以本条为准，下文已按此改写）**：
> - **合约合并（方案 A）**：TaxRouterV3（分账 / 欠款）、RecipientRegistry（白名单）、PostGradTaxHandlerV3（外盘税）合成一个 `TaxHandlerV3`，事件签名不变；分红合约、迁移合约、代币部署合约与打新共用一份（`SharedDividendVault`、`SharedMigrator`、`TokenDeployer`）。
> - **报价币**：WBNB 或任意 18 位 ERC-20（用户习惯 V2 的用法，不设白名单）；转账扣费的币和本平台发射的币拒收；毕业额按 QuoteRegistry 的固定换算额（可选）或发币人自选的参考池换算（V2 池读储备，V3 池读 30 分钟 TWAP）。主网 USDT 用 Pancake V3 USDT/WBNB 0.01% 池 `0x172f…f849`。参考池现价可被闪电贷拉偏的风险按产品决定接受（审计说明 K-1）。
> - **外盘税**：不再由 keeper 一次卖光。每笔卖出顺带把攒下的税卖一小块（≤ 这笔卖单的 25%；和 keeper 共用每个币每区块一个额度——池子代币储备的 0.5%；比区块参考价低 2% 以上不卖）并当场分账；没有卖单时 keeper 用 `process(token, amount, minQuoteOut)` 分块补位。分红那份在交税那一刻就按当时的份额记到持有人名下，这一批税卖完后兑现成报价币。
> - **owner 权限**：换币路由在构造时传入，之后改要提议后等 48 小时；分红合约的 operator 每个核心只能绑定一次；分红门槛在币登记时快照。
> - 见 `docs/AUDIT-BRIEF-2026-10-26.md` §15、§16。

> 2026-10-26 内部审计后（`docs/AUDIT-BRIEF-2026-10-26.md` §10、§11）：报价币当时只收 WBNB 和设了固定换算额的 18 位币（2026-10-27 已改，见上一条）；分红合约排除 migrator；代币的税处理合约构造时写死、毕业时一次性 `unlock(migrator)` + `setPair`，带 `contractURI` / `metaURI`，`create` 新增 `metaURI` 参数（元数据 JSON 地址，§12）；`buyFor` 只在准入开启时可用；内盘卖出先更新卖家份额再分账；QuoteRegistry 和 PlatformFeeBucket 改为与打新共用一份新部署、owner 为多签的实例，不复用 V2 那份。

> 2026-10-26 补充：这个合约是「核心」，用户也可以经无状态的 GangRouter 进入（用 BNB 直接买 / 打新）。路由只能替交易者付钱，卖出 / 卖回 / 领取仍只能本人直接调用。见 `docs/SPEC-CORE-ROUTER-2026-10-26.md`。

- 日期：2026-10-26 Asia/Shanghai
- 作者：Claude（本页为产品规格 + 合约设计；**非执行单**）
- 性质：**禁止主网广播**。合并后的版本在 `feat/swapback`（冻结点 `ddce6b6`），mock 单测与主网分叉测试通过，已过四轮内部审计（第五轮进行中；按决定不做外部审计），测试网记录见 `docs/TESTNET-CORE-ROUTER-2026-10-26.md`；送审说明见 `docs/AUDIT-BRIEF-2026-10-26.md`。
- 取代：`SPEC-V3-ECONOMIC-TEMPLATES-2026-10-26.md`（模版市场方案，已搁置）。本方案去掉模版工厂，只保留「接收地址」。
- 来源：合作方需求（2026-10-26，经用户转达）：
  1. 发币时填一个「税收接收地址」（合作方金库合约），发币后不能改。
  2. 税率可以自己设，内盘和外盘都收（合作方打算买卖各 2%）。**2026-10-27 用户改为只在外盘收，内盘不收（§19）。**
  3. 平台抽成按平台规则，持币分红比例可设（可为 0），剩下全部给接收地址。
  4. 给接收地址的那份用报价币结算（BNB 或 USDT），不给本币；外盘部分由平台卖成报价币后再转（2026-10-27 起：卖出时顺带分块卖，keeper 补位）。
  5. 直接转到接收地址；转账失败先记账，允许任何人调用补转。
  6. 每次往接收地址打款发一个事件（含币地址和金额），方便合作方统计收入。
  7. 其余规则不变：Agent 专属内盘、单地址 1% 上限、毕业规则照旧。
- 用户已定（2026-10-26）：平台抽成固定占成交额 0.5%；内盘 1% 平台手续费保留、税另收（2026-10-27 改为内盘不收税，§19）；接收地址走平台白名单；买卖税率分开设，各 1%–5%。

---

## 1. 规则

### 1.1 发币参数（创建时定死，终身不可改）

| 参数 | 范围 | 说明 |
|---|---|---|
| `buyTaxBps` | 100–500（1%–5%） | 买入税，只在毕业后的池子买入收；内盘不收（§19） |
| `sellTaxBps` | 100–500（1%–5%） | 卖出税，只在毕业后的池子卖出收；内盘不收（§19） |
| `dividendBps` | 0–10000 | 税扣掉平台部分后，分给持币人（持仓 > 1 万枚）的比例 |
| `recipient` | 白名单地址 | 剩下的税全部给它，用报价币结算；为 0 时 `dividendBps` 必须是 10000（全部分红） |
| 无税币 | 买卖都为 0，其余为空 | 与 V2 无税轨相同 |

### 1.2 每笔税怎么分（只在外盘）

```
税 = 外盘成交额 × 买（或卖）税率
平台 = 成交额 × 0.5%                 （从税里出）
剩余 = 税 − 平台
分红 = 剩余 × dividendBps / 10000    （这个币当前没有合格持有人时并入接收地址）
接收地址 = 剩余 − 分红
```

| 例：合作方设买卖各 2%，分红 0 | 成交额占比 |
|---|---|
| 内盘每笔合计 | 1%（只有平台手续费，不收税，§19） |
| 外盘：税里的平台部分 | 0.5% |
| 外盘：接收地址 | 1.5% |
| 外盘每笔合计 | 2%（只有税） |

- 买和卖税率不同时（例如买 1% / 卖 3%），平台部分仍是每笔成交额的 0.5%：买入时占税的一半，卖出时占税的六分之一。外盘按每笔交易分别记账，卖出换成报价币后按同一比例拆分。
- 分红那份按交易前的份额记账：卖家拿不回自己这笔卖出的税，买家分不到自己这笔买入的税。分红在交税时记成税币单位，这一批卖完后按实际换回的报价币兑现。内盘不收税，但内盘买卖照样按余额写份额，毕业时的持有人从第一笔外盘税起就能分到。
- 平台部分进现有 PlatformFeeBucket（80% 回购 GANG / 20% 金库）。

### 1.3 打款给接收地址

- 内盘：不收税，接收地址在内盘拿不到任何钱（§19）。
- 外盘：税以本币累计在 TaxHandlerV3。每笔卖出前（池子未锁），代币让 handler 先卖一块攒下的税（≤ 这笔卖单的 25%；和 keeper 共用每个币每区块一个额度——池子代币储备的 0.5%；比区块参考价低 2% 以上不卖，最低成交额按同一调用里的储备算）；没有卖单时 keeper `process(token, amount, minQuoteOut)` 分块卖。换回的报价币在 handler 里直接拆分，接收地址那份当场转。**接收地址永远收报价币，不收本币。**
- 卖出那一块失败不影响用户这笔卖出（代币发 `SwapBackFailed`）；分红合约或手续费池拒收时这一块照常卖出，持有人那份 / 平台那份先留在 handler，任何人 `flushHolders` / `flushPlatform` 补上。
- 直接转账；失败（例如 USDT 黑名单、合约拒收）不影响交易，记入 `owedOf[token]`。**任何人**都可以调用 `release(token)` 补转；补转仍失败会回滚，欠款保留，不会丢。
- 事件：
  - `TaxPaid(token, recipient, quote, amount)`：每笔真正到账的打款（直接转账或补转）都会发出；合作方统计收入只看这一个事件即可。
  - `TaxOwed(token, recipient, quote, amount)`：转账失败、记为欠款。
  - `TaxDistributed(token, phase, amount, toPlatform, toDividend, toRecipient)`：每笔税的完整拆分。
  - `TaxConfigured(token, buyTaxBps, sellTaxBps, dividendBps, recipient)`：发币时的配置。

### 1.4 接收地址白名单

- 在 `TaxHandlerV3` 上，owner = 平台多签；`list(address, label)` / `delist(address)` / `isListed` / `recipients()` / `entries(address)`。
- 发币时接收地址必须在白名单里；**下架只影响之后发的新币**，已经发的币照常打款给它。
- 理由：允许任意地址等于让任何 dev 把大部分税收进自己的钱包，有税币难以区分好坏。

### 1.5 不变的部分

Agent ID 专属内盘、单地址 1% 上限、≈15 BNB 毕业、毕业前代币锁定、LP 打到 0xdead、外盘税只对官方池子收。

---

## 2. 合约

| 合约 | 职责 |
|---|---|
| `src/launchpad-v3/LaunchpadV3.sol` | `create(…, TaxConfig{buyTaxBps, sellTaxBps, dividendBps, recipient})`；内盘只收 1% 手续费、不收税（§19），有分红的币照常写份额；校验规则见 §1.1；报价币规则见顶部更新说明 |
| `src/launchpad-v3/TaxLaunchTokenV3.sol` | 买、卖两个池子税率，immutable；从池子买入按买入税率、卖进池子按卖出税率；卖出时先调 `handler.swapBack`（失败吞掉、发 `SwapBackFailed`；调用方 gas 不够时整笔回滚 `SwapBackOutOfGas`，保证 gas 估算包含这一块） |
| `src/launchpad-v3/LaunchTokenV3.sol` | 无税币 |
| `src/launchpad-v3/TaxHandlerV3.sol` | 接收地址白名单；每个币的路由（`register` / `routeOf`，只能登记一次）；外盘分账（平台 → 分红 → 接收地址；§19 起没有内盘分账，`distribute` 已删），推送失败记 `owedOf`、任何人 `release`；外盘税：按每笔方向记平台部分、`swapBack` / `process` 分块卖出、`previewSell`、`maxChunk`；`TaxPaid` / `TaxOwed` / `TaxDistributed` 事件 |
| `src/common/PostGradHandlerBase.sol` | 与打新 handler 共用的基类：keeper / owner、换币路由时间锁（`proposeDexRouter` → 48 小时 → `acceptDexRouter`）、分块与 `swapBack`、`flushHolders` / `flushPlatform`、带保护的写份额 |
| `src/common/SharedDividendVault.sol` | 与打新共用的分红合约：按币记登记核心；operator 每核心绑定一次；门槛在登记时快照；按交税时记账（两批先进先出） |
| `src/common/SharedMigrator.sol`、`src/common/TokenDeployer.sol` | 与打新共用的迁移合约（核心名单只加不减）和代币部署合约 |
| `interfaces/ITaxHandlerV3.sol` | 平台抽成常量 `V3_PLATFORM_TAX_BPS = 50` 只在这里定义，发射台和 handler 共用 |
| 删除 | TaxRouterV3、RecipientRegistry、PostGradTaxHandlerV3、TaxTokenDeployerV3（并入上面的合约）；更早删除的 TemplateRegistry 和模版工厂 |

复用 V2 代码、新部署一份与打新共用：PlatformFeeBucket（把 LaunchpadV3 和 TaxHandlerV3 加为 operator）、QuoteRegistry、PoolCheck（按地址链接）。

### 2.1 部署接线（`script/DeployLaunchpadV3.s.sol`）

五个共用合约（QuoteRegistry、PlatformFeeBucket、SharedDividendVault、SharedMigrator、TokenDeployer）→ `TaxHandlerV3(owner, vault, bucket, dexRouter)` → `LaunchpadV3`，然后：

- 分红合约：`setLaunchpad(pad, true)`、门槛 10,000 枚、`setOperator(handler, pad)`（只能一次）；排除迁移合约、bucket（分红合约构造时已排除自己）
- 迁移合约 `addLaunchpad(pad)`；代币部署合约 `setLaunchpad(pad, true)`
- handler：`setLaunchpad(pad)`（一次性）、`setKeeper`、`list(<合作方金库>, "<名称>")`
- PlatformFeeBucket：operator：pad、handler
- pad：`setAgentGate`、`setV3Factory`、主网 `setBridgePool(USDT, USDT/WBNB V3)`，最后 `setMigrator`

打新的部署脚本复用这五个共用合约（运行手册 §1）。

### 2.2 运维

外盘税大部分在卖出时顺带卖掉；只有买单的时候税会攒着，要 keeper 分块 `process`（gangfun-server `keeper-tax-process.sh`，`V3_PADS` 填核心地址即可自动接线，每 10 分钟一次，每个币每次最多 20 块）。健康检查在未卖税超过池子代币储备 1%、欠款、兑现卡住、`SwapBackFailed` 时报警（运行手册 §5、§8）。

---

## 3. 测试（`test/launchpad-v3/LaunchpadV3.t.sol`，14 个；卖出时自动换另见 `test/launchpad-v3/SwapBack.t.sol`、`test/fork/V3SwapBackFork.t.sol`）

| 用例 | 覆盖 |
|---|---|
| `test_create_rules` | 税率越界、单边为 0、分红比例越界、无接收地址时分红须 10000、未上白名单、无税币带参数；配置读回、无税币 = LaunchTokenV3（2026-10-27 起，原为 V2 LaunchToken） |
| `test_delistedRecipient_onlyBlocksNewTokens` | 下架后新币不能用，老币毕业后照常从外盘税打款 |
| `test_curveBuy_onlyProtocolFee_noTax` | §19：买 5% / 卖 5%、分红 40% 的币内盘买入：只扣 1% 进手续费池，接收地址、分红合约、handler 都是 0，handler 不发任何事件，`Buy.tax` = 0，份额照常写 |
| `test_curveSell_onlyProtocolFee_holdersAndRecipientGetNothing` | §19：内盘卖出只扣 1%，其他持有人 `pending` 为 0，接收地址 / 分红合约为 0，`Sell.tax` = 0，卖家份额跟着余额变 |
| `test_curve_taxedPricesLikeUntaxed` | §19：5% / 5% 的税收币和无税币同样的买卖，拿到的代币和卖回的报价币完全一样 |
| `test_failedPush_isOwed_tradeStillWorks_anyoneReleases` | 接收地址被黑名单：内盘照常、毕业不受影响；外盘税换币后推送失败记欠款、`TaxOwed`；仍被拦时补转回滚、欠款保留；解除后任何人补转、`TaxPaid` |
| `test_postGrad_buySellRates_platformPerTrade_recipientInQuote` | 毕业后池子买 1% / 卖 3%：平台部分按每笔记账，换币后接收地址收到报价币、不收本币 |
| `test_untaxed_noTaxAnywhere` | 无税币只收 1% 内盘手续费 |
| `test_agentGateAndWalletCapUnchanged` | 非 Agent 不能买、1% 上限、15 BNB 毕业 |
| `test_auditG01_excludedHolderZeroedOnSync` | 审计 G-01：被排除的持有人同步后份额为 0 |
| `test_curveToGraduation_onlyFee_thenPoolTaxSplitsAsBefore` | §19：买家花的报价币 = 池子流动性 + 1% 手续费（+ ≤ 1 wei 截断零头），毕业前接收地址 / 分红合约 / handler 为 0；毕业后外盘买 2%、分红 50%：平台拿成交额 0.5%，持有人按内盘写的份额在交税时记账（买家自己分不到），剩下一半一半，持有人可领 |
| `test_router_accessControl` | 只有发射台能登记、同一个币只登记一次、owner 权限、发射台一次性（测试名沿用合并前的「router」；§19 起 `distribute` / `previewSplit` 已删） |
| `test_recipientRegistry_accessControl` | 只有 owner 能增删白名单（现在在 TaxHandlerV3 上）；重复上架、零地址、下架未上架的地址都拒绝；下架后重新上架不重复记录 |
| `test_handler_onlyTokenAndKeeper` | 只有代币能通知收税、只有 keeper / owner 能换币分账 |

当时全量 98 个测试通过（含 V2 原有用例）；`ddce6b6` 上全量 487 个通过。

---

## 4. 待做

1. 测试网第 6 套部署（合并后的合约）+ 公开整轮。
2. 第五轮内部审计结论处理（审计说明 §17）。
3. 主网部署：运行手册 `docs/MAINNET-RUNBOOK-V3-FAIR-2026-10-26.md`（多签地址、合作方金库地址待定）。
