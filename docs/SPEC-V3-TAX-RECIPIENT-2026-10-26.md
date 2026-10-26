# 规格 · LaunchpadV3 税收接收地址（合作方金库）

- 日期：2026-10-26 Asia/Shanghai
- 作者：Claude（本页为产品规格 + 合约设计；**非执行单**）
- 性质：**禁止主网广播**。合约已在 `feat/v3-tax-recipient` 分支实现，mock 单测通过，**未审计、未上测试网**。
- 取代：`SPEC-V3-ECONOMIC-TEMPLATES-2026-10-26.md`（模版市场方案，已搁置）。本方案去掉模版工厂，只保留「接收地址」。
- 来源：合作方需求（2026-10-26，经用户转达）：
  1. 发币时填一个「税收接收地址」（合作方金库合约），发币后不能改。
  2. 税率可以自己设，内盘和外盘都收（合作方打算买卖各 2%）。
  3. 平台抽成按平台规则，持币分红比例可设（可为 0），剩下全部给接收地址。
  4. 给接收地址的那份用报价币结算（BNB 或 USDT），不给本币；外盘部分由平台 keeper 卖成报价币后再转。
  5. 直接转到接收地址；转账失败先记账，允许任何人调用补转。
  6. 每次往接收地址打款发一个事件（含币地址和金额），方便合作方统计收入。
  7. 其余规则不变：Agent 专属内盘、单地址 1% 上限、毕业规则照旧。
- 用户已定（2026-10-26）：平台抽成固定占成交额 0.5%；内盘 1% 平台手续费保留、税另收；接收地址走平台白名单；买卖税率分开设，各 1%–5%。

---

## 1. 规则

### 1.1 发币参数（创建时定死，终身不可改）

| 参数 | 范围 | 说明 |
|---|---|---|
| `buyTaxBps` | 100–500（1%–5%） | 买入税，内盘买入和池子买入都收 |
| `sellTaxBps` | 100–500（1%–5%） | 卖出税，内盘卖出和池子卖出都收 |
| `dividendBps` | 0–10000 | 税扣掉平台部分后，分给持币人（持仓 > 1 万枚）的比例 |
| `recipient` | 白名单地址 | 剩下的税全部给它，用报价币结算；为 0 时 `dividendBps` 必须是 10000（全部分红） |
| 无税币 | 买卖都为 0，其余为空 | 与 V2 无税轨相同 |

### 1.2 每笔税怎么分

```
税 = 成交额 × 买（或卖）税率
平台 = 成交额 × 0.5%                 （从税里出）
剩余 = 税 − 平台
分红 = 剩余 × dividendBps / 10000    （这个币当前没有合格持有人时并入接收地址）
接收地址 = 剩余 − 分红
```

| 例：合作方设买卖各 2%，分红 0 | 成交额占比 |
|---|---|
| 内盘平台手续费（原有，另收） | 1% |
| 税里的平台部分 | 0.5% |
| 接收地址 | 1.5% |
| 内盘每笔合计 | 3%（1% 手续费 + 2% 税） |
| 外盘每笔合计 | 2%（只有税） |

- 买和卖税率不同时（例如买 1% / 卖 3%），平台部分仍是每笔成交额的 0.5%：买入时占税的一半，卖出时占税的六分之一。外盘按每笔交易分别记账，keeper 换币后按同一比例拆分报价币。
- 平台部分进现有 PlatformFeeBucket（80% 回购 GANG / 20% 金库）。

### 1.3 打款给接收地址

- 内盘：发射台收到的就是报价币，当笔直接转给接收地址。
- 外盘：税以本币累计在 PostGradTaxHandlerV3，keeper 带最低成交额换成报价币后交给分账合约，再转给接收地址。**接收地址永远收报价币，不收本币。**
- 直接转账；失败（例如 USDT 黑名单、合约拒收）不影响交易，记入 `owedOf[token]`。**任何人**都可以调用 `release(token)` 补转；补转仍失败会回滚，欠款保留，不会丢。
- 事件：
  - `TaxPaid(token, recipient, quote, amount)`：每笔真正到账的打款（直接转账或补转）都会发出；合作方统计收入只看这一个事件即可。
  - `TaxOwed(token, recipient, quote, amount)`：转账失败、记为欠款。
  - `TaxDistributed(token, phase, amount, toPlatform, toDividend, toRecipient)`：每笔税的完整拆分。
  - `TaxConfigured(token, buyTaxBps, sellTaxBps, dividendBps, recipient)`：发币时的配置。

### 1.4 接收地址白名单

- `RecipientRegistry`，owner = 平台多签；`list(address, label)` / `delist(address)`。
- 发币时接收地址必须在白名单里；**下架只影响之后发的新币**，已经发的币照常打款给它。
- 理由：允许任意地址等于让任何 dev 把大部分税收进自己的钱包，有税币难以区分好坏。

### 1.5 不变的部分

Agent ID 专属内盘、单地址 1% 上限、≈15 BNB 毕业、毕业前代币锁定、LP 打到 0xdead、外盘税只对官方池子收。

---

## 2. 合约（`src/launchpad-v3/`）

| 合约 | 改动 |
|---|---|
| `LaunchpadV3.sol` | `create(…, TaxConfig{buyTaxBps, sellTaxBps, dividendBps, recipient})`；内盘按买 / 卖税率收税，平台部分按成交额 0.5% 算；校验规则见 §1.1。19.9 KB |
| `TaxLaunchTokenV3.sol` | 买、卖两个池子税率，immutable；从池子买入按买入税率、卖进池子按卖出税率 |
| `PostGradTaxHandlerV3.sol` | 按每笔交易的方向记平台部分（`accruedPlatformTax`）；换币后按比例拆给分账合约；修复审计 G-01（被排除地址的分红份额清零） |
| `TaxRouterV3.sol` | 平台 → 分红 → 接收地址；直接转账、失败记 `owedOf`、任何人 `release`；`TaxPaid` / `TaxOwed` 事件 |
| `RecipientRegistry.sol` | 新增：接收地址白名单 |
| 删除 | TemplateRegistry、模版工厂（Agent 自养 / 回购销毁）、金库回调接口、模版作者分成 |

复用 V2 原样：DividendVault（需新部署一份，V2 那份的 launchpad 是 V2）、PlatformFeeBucket（把 LaunchpadV3 和 TaxRouterV3 加为 operator）、MigratorV2、PoolCheck、QuoteRegistry。

### 2.1 部署接线

DividendVault（新）→ TaxRouterV3 → RecipientRegistry → PostGradTaxHandlerV3 → TaxTokenDeployerV3 → LaunchpadV3 → MigratorV2(factory, pad)，然后：

- `router.setLaunchpad(pad)`、`router.setSource(handler, true)`
- DividendVault：`setLaunchpad(pad)`，operator：router、handler
- PlatformFeeBucket：operator：pad、router
- handler：`setKeeper`、`setDexRouter`
- pad：`setMigrator`、`setAgentGate`、`setV3Factory` / `setBridgePool`（非 BNB 报价币）
- `recipients.list(<合作方金库>, "<名称>")`

### 2.2 运维

外盘税要 keeper 调 `handler.process(token, minQuoteOut)` 才会换币、分账、打款给接收地址。现有 keeper 任务对 V2 毕业币也只做只读巡检、不自动广播；接入合作方前要加自动任务，否则外盘那部分收入会一直停在 handler 里。

---

## 3. 测试（`test/launchpad-v3/LaunchpadV3.t.sol`，10 个）

| 用例 | 覆盖 |
|---|---|
| `test_create_rules` | 税率越界、单边为 0、分红比例越界、无接收地址时分红须 10000、未上白名单、无税币带参数；配置读回、无税币 = V2 LaunchToken |
| `test_delistedRecipient_onlyBlocksNewTokens` | 下架后新币不能用，老币照常打款 |
| `test_bondingBuy_split_platformHalfPercent_restToRecipient` | 买 2%：平台 1% + 0.5%，接收地址 1.5%，`TaxPaid` 事件 |
| `test_bondingSell_split_withDividends` | 卖 3%、分红 40%：平台 0.5%，持币人 1%，接收地址 1.5% |
| `test_firstBuy_noHolders_dividendLegGoesToRecipient` | 没有合格持有人时分红那份给接收地址 |
| `test_failedPush_isOwed_tradeStillWorks_anyoneReleases` | 接收地址被黑名单：交易照常、记欠款、`TaxOwed`；仍被拦时补转回滚、欠款保留；解除后任何人补转、`TaxPaid` |
| `test_postGrad_buySellRates_platformPerTrade_recipientInQuote` | 毕业后池子买 1% / 卖 3%：平台部分按每笔记账，keeper 换币后接收地址收到报价币、不收本币 |
| `test_untaxed_noTaxAnywhere` | 无税币只收 1% 内盘手续费 |
| `test_agentGateAndWalletCapUnchanged` | 非 Agent 不能买、1% 上限、15 BNB 毕业 |
| `test_auditG01_excludedHolderZeroedOnSync` | 审计 G-01：被排除的持有人同步后份额为 0 |

全量 94 个测试通过（含 V2 原有用例）。

---

## 4. 待做

1. 测试网部署 + 全流程（含一个白名单金库、黑名单报价币的补转演示）。
2. keeper 自动任务：定时 `process`（§2.2）。
3. gangfun-server：索引 `TaxConfigured` / `TaxPaid` / `TaxOwed`，合作方收入统计接口；Buy / Sell 事件第四个字段改叫 `tax`。
4. gang.fun：代币页显示买卖税率、分红比例、接收地址（白名单里的名称）、累计打款。
5. CLI：`gang create --buy-tax 2 --sell-tax 2 --dividend 0 --recipient <地址>`，preflight 调 `checkTaxConfig`。
6. 外部审计后才能上主网。
