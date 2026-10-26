# 审计说明 · 打新（FairMintPad）、LaunchpadV3 税收接收地址、GangRouter

- 日期：2026-10-26 Asia/Shanghai，2026-10-27 按合并后的合约重写 §1–§9
- 读者：外部审计方
- 代码：`gangfun/gang-launchpad`，分支 `feat/swapback`，合约冻结在提交 `98cab5c`：含 §10、§11 两轮内部审计的修复，§12 的代币收紧与元数据 URI，§13 的外盘税合约加固，§14 的打新去掉截止时间与第三轮内部审计，§15 的合约合并（方案 A）与第四轮内部审计，§16 的外盘税改为卖出时自动小额换 + 按税产生时记账，§17 的第五轮内部审计修复。之前的冻结点依次是 `5854a35`、`36d8a7e`、`47a063b`、`cf96281`、`a15b704`、`13da13b`、`1bcc84f`、`ddce6b6`。此后若有提交改动 `src/`，我们会单独列出 diff。§10–§14 是当时的记录，里面提到的 TaxRouterV3、RecipientRegistry、PostGradTaxHandlerV3、每个核心一份的 DividendVault / MigratorV2、「keeper 一次卖光」都已被 §15、§16 取代。
- 链：BNB Chain（chainId 56），DEX 为 PancakeSwap V2。目前只部署在 BSC 测试网，部署脚本在审计前拒绝主网广播。
- 工具链：Foundry 1.8.6，Solidity 0.8.28，EVM cancun，optimizer 200 runs；OpenZeppelin 5.1.0。范围内的目录都用 via-ir 编译（`foundry.toml` 的 `compilation_restrictions`，含 `src/common`）。

---

## 1. 背景

gang.fun 是 BNB Chain 上的发币平台，内盘只对持有 .ai Agent ID（SPACE ID 发行的灵魂绑定 ERC-721）的钱包开放。主网在运行的是 LaunchpadV2（`src/launchpad-v2/`），已经过外部审计，不在本次范围内。

本次送审三块新合约：

| 模块 | 一句话 |
|---|---|
| 打新 FairMintPad | 没有价格曲线：所有人按同一价格一份一份打，打满 10,000 份就把 50% 代币和全部募集款加进 Pancake 池子开盘；没有截止时间和退款，打满前随时按同一价格卖回（扣撤出费，sale 7 天没有进展时免）。开盘后每笔池子交易收 1% 税，一半分给「打新时进来、而且一直没卖到出局线以下」的地址，一半给平台。 |
| LaunchpadV3 | 在 V2 曲线（Agent 专属、单地址 1% 上限、约 15 BNB 毕业）的基础上，发币时可设买 / 卖税（各 1%–5%）和一个白名单里的税收接收地址（合作方金库）。平台从税里固定拿成交额的 0.5%，剩下按设定比例分给持币人和接收地址，接收地址收报价币。 |
| GangRouter | 无状态、无 owner 的入口：把原生 BNB 换成 WBNB 后替调用者在两个核心上买入 / 打新，多付的部分退回。 |

两个核心共用五个合约（QuoteRegistry、PlatformFeeBucket、SharedDividendVault、SharedMigrator、TokenDeployer）。毕业 / 发射后的池子税：每笔卖出顺带把攒下的税卖掉一小块、当场分配，没有卖单时 keeper 分块补位；持有人的分红在交税那一刻就按当时的份额记账（§16）。

各自的产品规格：`docs/SPEC-FAIR-MINT-2026-10-26.md`、`docs/SPEC-V3-TAX-RECIPIENT-2026-10-26.md`、`docs/SPEC-CORE-ROUTER-2026-10-26.md`。

---

## 2. 范围

### 2.1 在范围内（约 2,600 nSLOC）

| 文件 | nSLOC | 职责 |
|---|---|---|
| `src/fair-mint/FairMintPad.sol` | 513 | 创建、打新、卖回（`withdraw(token, shares, minPayout)`）、补交撤出费、打满发射；每个 sale 创建时快照规则；持有全部托管本金 |
| `src/fair-mint/FairToken.sol` | 100 | 打新代币：发射前锁转账、发射台可收回；发射后池子买卖收 1% 税，卖出时调 handler 的 `swapBack`；税处理合约构造时写死，发射时一次性 `unlock(migrator)` + `setPair` |
| `src/fair-mint/HolderRewardHandler.sol` | 110 | 发射后的税：50% 给合格持有人（按交税时记账）/ 50% 平台；出局判断 |
| `src/launchpad-v3/LaunchpadV3.sol` | 544 | V2 曲线 + 买 / 卖税 + 接收地址；`buyFor` 路由入口 |
| `src/launchpad-v3/TaxHandlerV3.sol` | 255 | 接收地址白名单、每个币的路由、内盘 / 外盘分账、欠款与 `release`、外盘税（§15 合并自三个旧合约） |
| `src/launchpad-v3/TaxLaunchTokenV3.sol` | 110 | 带买、卖两个税率（immutable）的代币；卖出时调 `swapBack`；毕业时一次性 `unlock(migrator)` + `setPair` |
| `src/launchpad-v3/LaunchTokenV3.sol` | 31 | V3 无税币：`unlock` 只能一次，没有 `burn` |
| `src/launchpad-v3/TokenURI.sol` | 13 | 三种代币共用：构造时写入的 `_uri`，`contractURI()`（ERC-7572）/ `metaURI()` |
| `src/launchpad-v3/interfaces/*.sol` | 59 | V3 接口与共用常量（`V3_PLATFORM_TAX_BPS`） |
| `src/common/PostGradHandlerBase.sol` | 299 | 两个 handler 的基类：keeper / owner、换币路由时间锁、累计税、分块与 `swapBack`、`previewSell`、`flushHolders` / `flushPlatform`、带保护的写份额 |
| `src/common/SharedDividendVault.sol` | 288 | 共用分红合约：按币记登记核心、operator 每核心绑定一次、门槛按币快照、按税产生时记账（两批先进先出） |
| `src/common/SharedMigrator.sol` | 49 | 共用迁移合约：核心名单只加不减，池子已有 LP 时拒绝 |
| `src/common/TokenDeployer.sol` | 50 | 共用代币部署合约：只有名单里的核心能部署，记录 `isLaunchToken` |
| `src/router/GangRouter.sol` | 161 | 无状态路由 |

### 2.2 复用、不在范围内，但集成方式在范围内

以下 V2 合约的代码原样复用（已随 V2 审计）：`PoolCheck`、`QuoteRegistry`。平台手续费池改用 `src/common/SharedPlatformFeeBucket.sol`：V2 `PlatformFeeBucket` 去掉 `collectPlatformSmart`、按到账额记账、keeper 改为时间锁（§17 C-F2 / C-F6）。实例都是新部署的一份，V3 和打新共用，owner 是多签（`script/SharedPlatform.sol`）。请把它们当作已知行为的依赖，但新合约怎么调用它们（尤其是 bucket 的 `notifyAccrual` 拒收时、`PoolCheck` 用参考池换算毕业额 / 募集额）属于本次范围。V2 的 `DividendVault`、`MigratorV2` 不再被新合约使用。

### 2.3 不在范围内

`script/`（部署接线请看 §9）、`test/`、`src/**/mocks/`（含测试网用的 `TestnetAgentId`、`TestnetBlacklistQuote`）、`skill/`（CLI）、服务端和前端。`src/launchpad-v2/`、`src/stocks/` 目录。

---

## 3. 资金流

### 3.1 打新

```
mint / mintFor ── 本金 ──▶ FairMintPad（托管本金）      打新费 ──▶ 平台（PlatformFeeBucket，当笔）
                              │
       ┌──────────────────────┴───────────────────────┐
  withdraw(token, shares, minPayout)                打满（同一笔交易）
  本金 − 撤出费 → 本人（不足 minPayout 回滚）       5 亿枚 + 全部本金 → SharedMigrator
  撤出费 → 平台（bucket 拒收时记 owedFee，          → Pancake V2，LP → 0xdead
          任何人 flushFees 补交）
  sale 7 天没有进展：撤出费 = 0

发射后：池子买卖 1% 税（代币）→ HolderRewardHandler
        交税当场：持有人那一半按当时的合格份额记成税币单位（SharedDividendVault.accrueDividendUnits）
        卖出时：代币先调 swapBack，把攒下的税卖一块（≤ 这笔卖单 25%；和 keeper 共用每个币每区块一个额度：区块内第一次尝试时池子代币储备的 0.5%；价格比区块参考价低 2% 以上不卖）
        没有卖单时：keeper process(token, amount, minQuoteOut)，每次 ≤ maxChunk
        换回的报价币：50% 兑现给记了单位的持有人（convertDividend）/ 50% PlatformFeeBucket
        没有合格持有人时 100% 给平台
```

- 每个币总量 10 亿：5 亿分成 10,000 份打新（每份 5 万枚），5 亿进池子。开盘价等于打新价。
- dev 在平台上下限内设：募集额 5–50 BNB 等值、单地址上限 0.25%–0.5%、出局线 30%–80%、打新费 1%–3%、撤出费 1%–2%。创建时 dev 至少自己打 1 份。没有截止时间。
- 「进展」计时：创建者那一笔记 `progressAt`、`markSold = sold`；之后只有 `sold ≥ markSold + STALE_STEP`（10 份）的打新才重启计时。`block.timestamp ≥ progressAt + 7 天` 时撤出费为 0（`exitFeeBpsOf`）。
- 报价币：WBNB，或任意 18 位小数的 ERC-20（`_requireQuote`，低级 `staticcall` 读 `decimals`）；拒绝转账扣费的报价币（`_pullExact`）和本平台发射的币（`TokenDeployer.isLaunchToken` 或已在分红合约登记）。QuoteRegistry 里设了固定换算额的币按固定额锁定募集额，其它按发币人自选的参考池换算（Pancake V2 池读储备，V3 池读 30 分钟 TWAP、观测不够时读现价，非 WBNB 对手币经 owner 设的中转池到 WBNB，最小深度 1 BNB）。
- 合格持有人的权重 = `min(当前余额, 发射时基准)`；余额一旦低于 `基准 × 出局线` 就永久出局。分红在交税那一刻按交易前的份额记账：卖家按卖出前的份额分到自己这笔卖出的税（即使这笔让它出局），买家分不到自己这笔买入的税。

### 3.2 LaunchpadV3

```
内盘买入：quoteIn → 1% 平台手续费 + 买入税 → 剩余进曲线
          税（TaxHandlerV3.distribute）：平台 = 成交额 × 0.5%；剩余 × dividendBps → 分红合约（没有合格持有人时并入接收地址）；其余 → 接收地址
内盘卖出：同上，按卖出税率
毕业：剩余代币 + realQuote → SharedMigrator → Pancake V2，LP → 0xdead；代币开始在池子买卖时收税
外盘：税（代币）→ TaxHandlerV3，按每笔方向记平台部分；分红部分交税当场按当时份额记成税币单位
      卖出时 swapBack 卖一块 / 没有卖单时 keeper process(token, amount, minQuoteOut) 分块卖
      换回的报价币 → 平台 / 分红兑现 / 接收地址（合约内直接分账）
接收地址推送失败：owedOf[token] += 金额（owedTotalOf[quote] 同步）；任何人 release(token) 补发，仍失败则回滚、欠款保留
```

- 税率、分红比例、接收地址都在创建时写死（代币里的税率是 immutable，handler 里的 `routeOf` 只能登记一次）。
- 接收地址必须在 TaxHandlerV3 的白名单里；下架只影响之后新发的币。
- 无税币等同 V2 无税轨（只收 1% 内盘手续费）。
- 报价币规则与打新相同（§3.1）；毕业额按固定换算额或参考池在创建时锁定。V3 核心第一次拉报价币时按到账校验，转账扣费的报价币直接 `FeeOnTransferQuote`。
- 内盘买入先分账、再更新买家份额（奖励的是交易前的持有人）；卖出先更新卖家份额、再分账（卖家拿不回自己的卖出税）。外盘同样按交易前的份额记账。
- 分红合约拒收、bucket 拒收时外盘那一块照常卖出：持有人那份留在 handler（`pendingHolderUnits` / `pendingHolderQuote`），平台那份记 `owedPlatformOf`，任何人 `flushHolders` / `flushPlatform` 补上。

### 3.3 GangRouter

```
用户 ──BNB / 报价币──▶ GangRouter ──buyFor / mintFor（trader = 用户）──▶ 核心
                           ◀──────── 核心因上限 / 打满截断退回的部分 ─────┘
                       ──多余部分（BNB 或报价币）──▶ 用户
```

- 路由只按本次调用的余额变化结算，别人误转进来的币不会被下一个调用者拿走（也取不出来）。
- 代币、份额、分红权重、Agent 门槛、单地址上限全部记在 `trader` 名下。
- 卖出、打新的卖回、领取没有路由入口，只能本人直接调核心 / 分红合约（理由见 §4.2）。
- 路由入口只在准入开启时可用：V3 要求 `agentGateEnabled`，打新要求该 sale 创建时快照了准入（理由见 §10 A-2）。

---

## 4. 角色与权限

所有带 owner 的合约都是 `Ownable2Step`。主网 owner 是多签（地址待定），keeper 是一个热钱包。

### 4.1 每个角色能做什么

| 合约 | owner | keeper | 其他特权调用方 | 任何人 |
|---|---|---|---|---|
| FairMintPad | `setMigrator`（一次性，迁移合约须把本核心列入）、`setRouter`、`setAgentGate`、`setV3Factory`、`setTwapWindow`、`setBridgePool`。除 `setRouter` 外**都只影响之后创建的 sale** | — | 白名单路由：`mintFor`（只对有准入的 sale） | create、mint、withdraw、`flushFees` |
| FairToken | — | — | 只有发射台：`reclaim`（只在发射前）、`unlock(migrator)`（一次）、`setPair`（解锁后一次）；之后没有任何管理函数 | 转账（发射后）、`contractURI` / `metaURI` |
| HolderRewardHandler | `setPad`（一次性）、`setKeeper`（只能部署时设一次，之后 `proposeKeeper` → 48 小时 → `acceptKeeper`）、`proposeDexRouter` → 48 小时 → `acceptDexRouter` / `cancelDexRouter`；可代替 keeper 调 `process` | `process(token, amount, minQuoteOut)`（每次 ≤ `maxChunk`） | 代币：`notifyTax`、`swapBack` | `syncShares`、`flushHolders`、`flushPlatform` |
| LaunchpadV3 | `setMigrator`（一次性，迁移合约须把本核心列入）、`setPairFactory`（只用于创建时的参考池定价）、`setRouter`、`setAgentGate`、`setWalletCapEnabled`、`setV3Factory`、`setTwapWindow`、`setBridgePool` | — | 白名单路由：`buyFor`（只在准入开启时） | create、buy、sell |
| TaxLaunchTokenV3 / LaunchTokenV3 | — | — | 只有发射台：`unlock(migrator)`（一次）、`setPair`（有税币，解锁后一次）；之后没有任何管理函数 | 转账（毕业后）、`contractURI` / `metaURI` |
| TaxHandlerV3 | `setLaunchpad`（一次性）、`list` / `delist`（接收地址白名单）、keeper 与换币路由时间锁（同上）；可代替 keeper 调 `process` | `process(token, amount, minQuoteOut)` | 发射台：`register`（每个币一次）、`distribute`（只能付钱进来）；代币：`notifyTax`、`swapBack` | `release`、`syncShares`、`flushHolders`、`flushPlatform` |
| SharedDividendVault | `setLaunchpad(core, bool)`（移除只停新登记）、`setOperator(account, core)`（每个核心、每个地址只能绑定一次，不能解绑 / 更换）、`setExcluded`、`setMinimumShareBalance`（只影响之后登记的币） | — | 登记它的核心 / 绑定到该核心的 operator：`registerToken`（每个币一次）、`setShare`、`depositReward`、`accrueDividendUnits`、`convertDividend` | `claim`、`claimFor` |
| SharedMigrator | `addLaunchpad`（只加不减） | — | 名单里的核心：`migrate` | — |
| TokenDeployer | `setLaunchpad(core, bool)` | — | 名单里的核心：`deployPlain` / `deployTax` / `deployFair` | `isLaunchToken` 查询 |
| SharedPlatformFeeBucket（共用一份新实例） | `setLaunchpad`、`setOperator`、`setFeeVault`、`setBurner`、`setKeeper`（只能设一次，之后 48 小时时间锁）、`requestFlush` + 7 天后 `flushStuckQuoteToTreasury` | `collectPlatform`（固定路径：80% 回购销毁 / 20% 金库；没有 `collectPlatformSmart`） | operator：`notifyAccrual`（按到账额记账） | — |
| QuoteRegistry（复用代码，共用一份新实例） | `setQuote`：给报价币设固定换算额（15 BNB 合多少该币），设了就优先于参考池；只影响之后创建的币。不再决定哪些币能用 | — | — | 查询 |
| GangRouter | 无 | — | — | 全部函数 |

### 4.2 我们的信任假设（请验证或推翻）

1. **没有任何 owner 函数能拿走托管资金**：打新本金、曲线上的 `realQuote`、TaxHandlerV3 里的欠款和待卖的税、分红合约里的分红都没有提取 / 应急出口（bucket 的 7 天应急出口只针对平台自己的钱，K-9）。**owner 能冻结的地方**：
   - 撤掉核心在 PlatformFeeBucket 的 operator：V3 内盘买卖会 revert，V3 毕业前没有别的退出路径；打新的打新和打满发射会 revert，但卖回不受影响（撤出费记 `owedFee`，§14 R3-2）；外盘税照常卖出，平台那份记 `owedPlatformOf`（§16）。这是新部署 bucket 并交给多签的原因。
   - `TokenDeployer.setLaunchpad(core, false)`：该核心之后不能再发币；已有的币、曲线、sale 不受影响。
2. **owner 被信任的地方**（主网用多签的原因）：
   - 换币路由：keeper `process` / `swapBack` 时会把这一块的税币授权给它。改路由要提议后等 48 小时才生效，期间可取消；恶意路由每次最多吞掉一块（≤ 池子代币储备 0.5%）里 `minQuoteOut` 以上的部分。
   - 分红合约：operator 每个核心只能绑定一次，之后 owner 没法再给已有核心换 operator；`setLaunchpad` 加的新核心只能登记自己发的币（`AlreadyRegistered`），碰不到已有币（这一点关掉了 §10 的 I-1）。`setExcluded` 能让某个地址之后不再分红；`setMinimumShareBalance` 只影响之后登记的币（门槛按币快照）。
   - QuoteRegistry 的固定换算额：设一个离谱的值会让之后用这个报价币发的币毕业额 / 募集额离谱，已有币不受影响。
   - LaunchpadV3 的 `setAgentGate` / `setWalletCapEnabled` 是全局开关，会影响正在曲线上的币（与 V2 一致）；打新则在创建时快照，不受影响。
   - 核心的 `setRouter`：列入的路由能调 `buyFor` / `mintFor`。
3. **一个被列入白名单的恶意路由最坏只能「用自己的钱替别人买 / 打新」**——前提是准入开启。准入关闭时它能把代币打给未来的池子地址、分走发射流动性（§10 A-2），所以现在路由入口在准入关闭时直接 revert。核心对路由只开放 `buyFor` / `mintFor`，付款方是 `msg.sender`（路由）。测试 `test_v3_listedRouterOnlySpendsItsOwnQuote`、`test_fair_listedRouterOnlySpendsItsOwnQuote` 覆盖。
4. **keeper 被信任设 `minQuoteOut`**：它可以给一个很低的值然后自己夹，损失的是这一块的价值（≤ 池子代币储备 0.5%）。`process` 拒绝 `minQuoteOut == 0`。`swapBack` 的最低成交额由合约按同一调用里的储备算（下限 1%）。
5. **发射台只能付钱进 TaxHandlerV3**：`distribute` 从 `msg.sender`（只能是发射台）拉 `amount`，再按登记的路由拆分。

---

## 5. 我们认为必须成立的不变量

打新（FairMintPad）：

1. 对每个报价币：`balanceOf(pad) == Σ_未发射的 sale (sold × sharePrice) + owedFee[quote]`（invariant 测试按等号检查）。多个 sale 共用同一个报价币时，一个 sale 的卖回不能动到别的 sale 的钱。
2. 每个 sale：`sold == Σ positions.shares`、每个地址 `shares ≤ capShares`、`sold ≤ 10,000`；`markSold ≤` 历史最高 `sold`，`progressAt` 只在创建者那一笔或 `sold ≥ markSold + 10` 时前进。
3. 发射前：核心持有的该代币 = `总量 − sold × 50,000 枚`；发射后核心不再持有该代币。
4. 一个 sale 只有 Minting → Launched 一个方向；发射后不能再 mint / withdraw。打满前任何地址都能把自己的全部份额卖回（不依赖分红合约、bucket、准入）。
5. 发射时进池子的报价币 = `10,000 × sharePrice`，开盘价 = 打新价（池子已存在、有人提前打入报价币时除外，见 §6）。
6. 出局后不能恢复资格；权重永远不超过发射时基准；池子、handler、migrator、核心的基准为 0。

LaunchpadV3：

7. 对每个报价币：`balanceOf(pad) ≥ Σ_未毕业 realQuote`。
8. 每笔内盘交易：平台部分 = 成交额 × 0.5%（税率不对称时也一样），平台 + 分红 + 接收地址 = 税，没有多收或少分。
9. TaxHandlerV3：对每个报价币 `balanceOf(handler) ≥ owedTotalOf[quote]`，`owedTotalOf == Σ owedOf`；`release` 只付该币自己的欠款；`process` 卖的数量 ≤ 余额 − 欠款。
10. 税率、分红比例、接收地址在创建后不能被任何人改。

共用合约与外盘税：

11. 分红合约和 bucket 对每个报价币都付得起：分红合约余额 ≥ Σ 可领 `pending`；bucket 余额 ≥ `accruedQuote`。
12. 按税产生时记账：分红合约付得起「可领 + 正在卖的那一批已收到的报价币」；handler 持有累计的税币（`accruedTax`）；每个持有人未结算的单位之和 ≤ 未结算批次的单位之和；交税之后才买入的地址分不到这笔税，交税之后卖掉的地址照样能领；取整只对协议有利。

GangRouter：

13. 每次调用结束后，路由在本次调用涉及的报价币上的余额回到调用前（误转进来的除外），BNB 余额为 0。

---

## 6. 已知问题与设计取舍

以下是有意的选择或已知限制。如果您认为某条的风险比我们判断的高，请照常报告。

| # | 内容 |
|---|---|
| K-1 | **报价币按参考池换算（产品决定接受的风险，原 §11 R2-1）**：非 WBNB 报价币没设固定换算额时，按发币人自选的参考池在创建时锁定毕业额 / 募集额。Pancake V2 池读储备现价；V3 池读 30 分钟 TWAP，观测不够时读现价。用 V2 池、或没有观测历史的 V3 池（例如刚开的新池）时，同一笔交易里可以用闪电贷拉偏，把 15 BNB 的毕业额锁成真实价值的很小一部分，一伙人低价打满 / 毕业后拿走大量筹码（第二轮审计 PoC：成本约 0.005 BNB）。影响限于这个币自己。产品决定沿用 V2 的用法（用户习惯），不设白名单；主网 USDT 用 Pancake V3 USDT/WBNB 0.01% 池（约 8,000 WBNB、观测容量 4,500，TWAP 可读）。 |
| K-2 | **税只对官方池子收**：别人另建交易对可以绕开税（同 V2）。 |
| K-3 | **打新的出局按余额判断**：转去另一个钱包、拿去加池子、放进别的合约，余额都会下降，跌破线就永久出局，哪怕同一笔交易里又转回来。网站和 CLI 会提前提示。 |
| K-4 | **提前建好的池子**：有人在发射 / 毕业前用同名代币建好 Pancake 池子并打入报价币时，SharedMigrator 沿用这个池子（要求池子里还没有 LP，`PairHasLiquidity`）。对方打入的报价币等于送给锁死的 LP，开盘价略高于打新价 / 毕业价。代币发射前锁转账，对方打不进代币。 |
| K-5 | **sale 可能永远打不满**：没有截止时间和退款，打新的人只能卖回退出（7 天没有进展后免撤出费，只损失打新费）。任何人都能打完剩下的份数，没有办法永久阻止发射（最后一笔超出剩余份数时自动截断）。 |
| K-6 | **打满那一笔要建池子**，gas 约 250 万–390 万，由最后一个打新的人付。 |
| K-7 | **转账钩子里写分红份额失败**：两个 handler 都带保护：分红合约真正拒绝时吞掉错误、发 `ShareWriteFailed`、不卡转账；调用方把 gas 卡到让这次调用耗尽时 revert（§10 A-5）。恢复后旧份额继续累计，直到有人为该地址 `syncShares`（keeper 处理）。分红合约的 operator 每个核心只能绑定一次、不能解绑，所以「owner 撤掉 operator 冻结 V3 转账」的路径已不存在。 |
| K-8 | **G-01 的剩余窗口**：owner 在分红合约排除一个地址后，在该地址下次转账前它仍会按旧份额累计。运维规定：排除操作必须和 `handler.syncShares(token, user, 0)` 放在同一批交易里。 |
| K-9 | **PlatformFeeBucket 的应急出口**（V2 审计 G-03）：owner 申请后 7 天可把卡住的报价币整笔转到金库，绕过 80/20 拆分。原样复用，知悉。 |
| K-10 | **V3 的分红部分在没有合格持有人时并入接收地址**；打新发射后的分红部分在没有合格持有人时并入平台。两者不同是因为 V3 里剩余的税本来就归接收地址。 |
| K-11 | **路由不提供 sweep**：误转进 GangRouter 的代币 / 报价币会永远留在那里。 |
| K-12 | **报价币不设白名单**：任意 18 位 ERC-20 都能做报价币；转账扣费的（入口与扣款时校验）和本平台发射的币（`isLaunchToken` / 已登记分红）被拒。会暂停、会拉黑、负 rebase 的报价币仍能进来：发行方暂停或拉黑核心 / handler / 分红合约 / bucket 时，用这个报价币的币可能无法交易、毕业或领取，打新本金可能取不出来。影响限于用这个报价币的币；网站和 CLI 只主推 WBNB / USDT。已毕业的 V2 发射币仍能做报价币（分红走 V2 的分红合约，影响很小）。 |
| K-13 | **非官方池子也会累计 V3 分红份额**（迁移合约、分红合约、bucket 已排除）：只有官方池子被设为 0。别人另建的交易对持有代币就有份额，任何人都能用 `claimFor` 把分红推进去。运维：发现这类池子后，owner 在分红合约排除它，并在同一批交易里 `handler.syncShares(token, pool, 0)`。打新不受影响：非打新地址的基准为 0。 |
| K-14 | **接收地址永久收不了款时，欠款会一直留在 TaxHandlerV3**：例如合作方金库被 USDT 拉黑。接收地址发币后不可改是产品承诺，没有改向出口。 |
| K-15 | **外盘税分块卖出**：每个币每区块一个额度（区块内第一次尝试时池子代币储备的 0.5%），`swapBack` 和 keeper 共用，按卖出数量扣；`swapBack` 另外 ≤ 卖单的 25%；价格比区块参考价（区块内第一次尝试时的储备）低 2% 以上就不卖（`swapBack` 跳过、`process` 回滚 `PriceBelowReference`）。一块仍可被夹，攻击者最多拿走约「2% × 这一块的卖出所得」；跨区块压价需要扛过一个区块的套利，且每块只有额度的量。keeper 补位时 `minQuoteOut` 容忍度 1.5%，建议经私有 RPC 发交易。只有买单的拉盘期里积压会增长，keeper 每 10 分钟每个币最多卖 20 块。`dexRouter` 只支持 Router02 的 fee-on-transfer 直连路径。 |
| K-16 | **毕业前卖出要求卖家当时仍持有 Agent ID**（与 V2 一致）。 |
| K-17 | **卖单前先卖一块会改变储备**：链下按旧储备预先算好输出、直接对池子先转账再 `swap` 的路由会失败；Pancake 的 `…SupportingFeeOnTransferTokens` 接口没问题（有税币本来也只能走它）。前端和 CLI 用 `previewSell` 报价。 |
| K-18 | **卖出 gas 变高**：一笔带一块的卖出约 57–60 万 gas（原 27.6 万），见 §16。 |
| K-19 | **持有人的分红要等这一批卖完才能领**：交税时就记了单位，但一批没卖完前它不会变成可领金额；长时间只有买单时早期持有人要等 keeper 把这批卖完。 |

### 6.1 V2 审计结论在新合约里的处理

| V2 发现 | 新合约 |
|---|---|
| G-01 被排除地址保留旧份额继续分红 | 受影响，已修：两个 handler 对被排除地址的目标份额一律为 0。测试 `test_auditG01_excludedHolderZeroedOnSync`。剩余窗口见 K-8。 |
| G-02 `totalShares == 0` 时存入的钱永远卡住 | 不受影响：没有合格持有人时不记分红单位，打新那一半给平台，V3 那份给接收地址（没有接收地址的币给平台）。 |
| G-03 `flushStuckQuoteToTreasury` 绕过 80/20 | 原样复用，见 K-9。 |

---

## 7. 测试与验证

```sh
forge build --sizes
forge test                    # 98cab5c：593 个通过（审计回归套件继承基础套件，基础用例会再跑一遍）
BSC_RPC_URL=https://rpc-bsc.48.club forge test --match-contract Fork   # 主网分叉 25 个（publicnode 会丢历史状态）
BSC_RPC_URL=https://rpc-bsc.48.club forge test --match-path 'test/fork/*'   # 12 个
```

| 测试文件 | 个数 | 覆盖 |
|---|---|---|
| `test/fair-mint/FairMint.t.sol` | 33 | 参数上下限、报价币换算、上限与最后一笔截断、卖回、打新费当笔进平台、7 天免撤出费、没有截止时间、本金托管恰好等于持仓、发射价格、池子被提前建好、奖励权重 / 出局 / 上限、分账、权限、G-01 |
| `test/fair-mint/FairMintAudit.t.sol` | 41（含继承） | 第一、三轮内部审计回归：路由入口须开准入、卖回不依赖分红合约 / bucket、计时要净增份数才重启、报价币规则、migrator 绑定检查、收币方卡 gas 不能留下过期份额 |
| `test/fair-mint/FairSwapBack.t.sol` | 43（含继承） | 打新的卖出时自动换、每区块额度、零头不触发、失败不影响卖出、只认本核心的币、`previewSell`、按交税时记账、bucket / 分红合约拒收、按估算 gas 执行 |
| `test/fair-mint/FlowReviewFixes.t.sol` | 37（含继承） | F3 `minPayout`、F4a operator 只能绑一次、F4c 门槛按币快照、F4b 换币路由时间锁 |
| `test/fair-mint/FairTokenAdmin.t.sol` | 35（含继承） | 代币收紧与元数据 URI（§12） |
| `test/launchpad-v3/LaunchpadV3.t.sol` | 14 | 创建规则、下架只拦新币、内盘买卖分账（含不对称税率）、没有持有人时分红并入接收地址、推送失败记欠款 / 补发、外盘按每笔方向记账、无税币、门槛与上限、G-01、权限 |
| `test/launchpad-v3/LaunchpadV3Audit.t.sol` | 24（含继承） | 内部审计回归：`buyFor` 须开准入、报价币规则、migrator 绑定、卖家拿不回自己的卖出税、伪造代币收税、pair 报价核对、欠款不会被 `process` 卖掉 |
| `test/launchpad-v3/SwapBack.t.sol` | 31（含继承） | V3 卖出时自动换：每区块额度、≤ 卖单 25%、零头不触发、池子未同步时（像加流动性加到一半）跳过、1 wei 捐款不跳过、`previewSell`、冲击上限、只认代币、失败不影响卖出、按估算 gas 执行、keeper 分块卖完只有买单的积压、按交税时记账、bucket / 分红合约拒收、写份额被拒 |
| `test/launchpad-v3/LaunchpadV3Fuzz.t.sol` | 17（含继承） | fuzz（各 1000 轮）：每笔买 / 卖恰好拆成曲线、1% 手续费、税，平台拿成交额 0.5% |
| `test/launchpad-v3/TokenAdmin.t.sol` | 17（含继承） | 代币收紧与元数据 URI（§12） |
| `test/common/TaxTimeDividends.t.sol` | 6 | 按交税时记账：归属交税时的持有人、两批先进先出、隔很多批才动的持有人、只认核心 / 其 operator、超卖被拒；含与逐批暴力模型对照的 fuzz（1000 轮） |
| `test/common/SharedInfra.t.sol` | 25（含继承） | 两个核心共用一套、各自毕业 / 发射分红不串、跨核心写入被拒、只认名单里的调用方、移除核心后已有币照常、门槛按核心 |
| `test/audit4/Audit4Regression.t.sol` | 27 + 19（含继承） | 第四轮内部审计回归（§15） |
| `test/router/GangRouter.t.sol` | 19 | BNB / 报价币两种路径、交易者拿币、门槛和上限按交易者、分红权重归交易者、截断退款、经路由毕业 / 发射、只有白名单路由能代买、流氓路由只能花自己的钱 |
| `test/invariant/CoreInvariants.t.sol` | 9 条不变量 | V3、打新、共用合约、GangRouter 放在一起随机操作（发币、直接 / 经路由买卖、打新、卖回、跳时间、打满、毕业、池子交易、keeper 分块处理、拉黑接收地址、补发、领取），每步后检查 §5 的不变量。CI 跑 24 × 50；`6b5e03f` 上压力跑 200 轮 × 80 步全过 |
| 主网分叉 | 25 + 12 | 真实 Pancake：打新整轮、USDT 按参考池换算、提前建池；V3 卖出时自动换（`V3SwapBackFork.t.sol`：`previewSell` 与实际到账一致、一块用完本区块额度、1 wei 不触发、单块冲击 ≤ 约 1%、估算 gas 下这一块会执行）；报价币按 V2 / V3 参考池换算与 LaunchpadV2 同口径（`QuoteRefPoolFork.t.sol`） |

另外：

- 本地 anvil（BSC 测试网 fork）上用 `ddce6b6` 之前的 `6b5e03f` 部署脚本部署过整套，keeper（gangfun-server `feat/keeper-ops`）实测：只填核心地址就自动接线；只有买单时 V3 8 块、打新 3 块卖完，每块约池子代币储备 0.5%、冲击约 0.75%；分红合约和 bucket 同时拒收时这一块照常卖出、恢复后 keeper 自动补兑现补交；真实卖出时 `previewSell` 与实际到账相差 0.05%。
- 运行时字节码（98cab5c，§17）：TaxHandlerV3 20,465 B，TokenDeployer 20,044 B，LaunchpadV3 18,819 B，FairMintPad 16,803 B，HolderRewardHandler 16,474 B，SharedDividendVault 9,588 B，SharedPlatformFeeBucket 4,299 B，TaxLaunchTokenV3 4,309 B，FairToken 4,209 B，GangRouter 4,135 B，SharedMigrator 2,001 B，都 < 24,576 B。

**测试的不足**：invariant 测试用的是仓库里简化的 MockPair（不检查 K、不收 0.25% 手续费）；池子相关的经济攻击（夹子、闪电贷）由第二轮审计员用仿真的 Pancake V2 池子验证过（§11），卖出时自动换在真实 Pancake 上有分叉测试，但没有系统的 MEV 仿真。

---

## 8. 希望重点看的地方

1. **按税产生时记账**（`SharedDividendVault`）：两批先进先出的状态转换（`open` → `selling`、一批没卖完时又有新税）、持有人跨很多批次后的结算、1e36 放大与 `uint128` 打包的取整与溢出、可领 + 未结算是否始终有足额支撑、交税前后买卖的归属。
2. **卖出时自动换**：每区块额度与区块参考价、`swapBack` 失败与 `SwapBackOutOfGas` 的边界（gas 估算是否总包含这一块）、池子余额与储备的同步判断、`previewSell` 的准确性、和 Pancake Router02 各种接口（含加 / 减流动性）的兼容、能否被夹、能否用零头卖单或捐款耗掉 / 绕开额度（§17）。
3. **共用合约的隔离**：两个核心、两个 handler、各自 operator 之间能否互相写份额 / 存奖励 / 登记代币；同一报价币的不同币之间的资金隔离。
4. **任意报价币**：会回调、会暂停 / 拉黑、负 rebase、`decimals` 会变的报价币对核心、handler、分红合约、bucket、迁移合约的影响；参考池换算（K-1 已接受的部分之外）。
5. **FairMintPad 的记账**：多个 sale 共用同一个报价币时的隔离（§5 #1，含 `owedFee`）；卖回取整；7 天计时边界和 `markSold`；`minPayout`。
6. **最后一笔打满即发射**：`_mint` 里在同一笔交易中调用 `_launch` → SharedMigrator → Pancake。有没有办法让发射失败从而卡住 sale，或者在建池时重入。
7. **LaunchpadV3 的费用计算**：`_prepBuy` / `_applyFees` / `_recomputeFee` 在单地址上限或毕业截断时重新算费用和退款，平台部分按成交额。
8. **TaxHandlerV3 的欠款与待卖的税**：`owedOf` / `owedTotalOf` / `release` 的隔离；报价币本身是被收税的币时 `process` 不会卖掉欠款；接收地址是会回调的合约时的重入。
9. **GangRouter 与 `buyFor` / `mintFor` 的身份**：门槛、上限、分红权重、事件里的买家都用 `trader`，付款和退款用 `msg.sender`。

---

## 9. 主网部署计划

- 部署脚本：`script/DeployLaunchpadV3.s.sol`、`script/DeployFairMint.s.sol`、`script/DeployGangRouter.s.sol`。主网广播分别需要 `LAUNCHPAD_V3_MAINNET_OK=true`、`FAIR_MINT_MAINNET_OK=true`、`GANG_ROUTER_MAINNET_OK=true`，审计通过前不会设置。
- 环境变量：`OWNER`（多签，主网必填）；可选 `KEEPER`、`FEE_VAULT`、`RECIPIENT` / `RECIPIENT_LABEL`；第二个脚本复用五个共用合约：`QUOTE_REGISTRY`、`PLATFORM_BUCKET`、`DIVIDEND_VAULT`、`MIGRATOR`、`TOKEN_DEPLOYER`。不再有 `USDT_PER_15_BNB`。
- 部署前：核对主网上链接的 PoolCheck 库（`0xd2B1…bDb3`，按地址链接、delegatecall 调用）的字节码与本仓库源码一致；核对 USDT 参考池 `0x172f…f849` 就是 Pancake V3 工厂登记的 USDT/WBNB 0.01% 池。
- 顺序：`DeployLaunchpadV3`（部署五个共用合约）→ `DeployFairMint`（复用五个共用合约）→ `DeployGangRouter`。复用时脚本要求部署钱包仍是这些合约的 owner，所以第二、三个脚本必须在多签 accept 之前跑。
- 接线：核心加进分红合约 / 迁移合约 / 代币部署合约的名单；分红合约给每个核心绑定唯一的 operator（它的 handler），排除自己、迁移合约、bucket；门槛 10,000 枚；bucket 的 operator 是两个核心和两个 handler；换币路由（Router02）在构造 handler 时传入；准入开启；主网设中转池（USDT → WBNB）。最后一步才 `setMigrator`，核心从这一刻起才能发币。脚本结束时做接线自检。
- owner：所有 9 个带 owner 的合约（两个核心、两个 handler、五个共用合约）进入待接受状态，多签逐个 `acceptOwnership()`（`Ownable2Step`）。之后部署钱包没有任何角色。
- keeper：独立热钱包，只有 `process` 和 bucket 的 `collectPlatform` 权限。服务端 keeper 以核心地址为配置、每 10 分钟分块补位、每 30 分钟健康检查并报警（运行手册 §5）。
- 主网 QuoteRegistry 上线时不登记任何报价币：USDT 用参考池换算（K-1）。
- 接收地址白名单：上线时只列合作方的主网金库（地址待定），在 TaxHandlerV3 上 `list`。
- V2 自己的 bucket / registry / 分红合约 / 发射台目前 owner 是普通钱包 `0x4EEd…`，同样能冻结 V2 内盘。建议多签建好后由它发起 `transferOwnership`、多签接受；不挡这次上线。

审计报告里的问题修复后，我们会在同一个 PR 上提交修复，并在这份文档里逐条记录处理结果。

---

## 10. 内部审计（2026-10-26）

外部审计前，我们让三个互相独立的审计员各审一块（打新、V3、路由与部署接线），只给代码和本文档，要求把文档里的说法当作待推翻的假设，每个发现都用 Foundry PoC 实测。审计对象是 `5854a35`，修复在 `36d8a7e`。没有发现能直接偷钱的严重 / 高危问题。

| ID | 来源 | 严重度 | 问题 | 处理 | 回归测试 |
|---|---|---|---|---|---|
| A-1 | 路由 / 接线 | 中 | 主网计划复用 V2 的 PlatformFeeBucket，owner 是普通钱包。核心在 V3 内盘每笔买卖、打新撤出和发射时都要调它，没接好 operator 或被撤掉就 revert。部署脚本在接好之前就开放了核心，打新的人会被锁到截止。 | 新部署一份 bucket（和 QuoteRegistry），V3 与打新共用，owner 为多签；主网必须设 `OWNER`；所有接线做完后最后 `setMigrator` | 测试网 fork 与主网模拟部署 |
| A-2 | 打新 / 路由 | 中（有条件） | 准入关闭时，白名单路由能以 `trader = 未来池子地址` 打新 / 买入，把代币送进池子；攻击者再打入报价币先拿第一份 LP，发射时分走约一半流动性（PoC：250,024,999 枚）。GangRouter 总用 `msg.sender`，当前部署不可利用。 | `mintFor` 要求该 sale 有准入，`buyFor` 要求准入开启 | `test_audit_mintForNeedsGate`、`test_audit_buyForNeedsGate` |
| A-3 | 打新 / V3 | 中 | 报价币不限：6 位小数的报价币让每股分红取整为 0，钱进了分红合约却没人能领；转账扣费 / 回调型报价币也能进来。 | `create` 只收 WBNB 或 QuoteRegistry 已启用的 18 位币（2026-10-27 起白名单取消、保留 18 位限制并拒收转账扣费币，§15、K-12） | `test_audit_quoteWhitelist`（两套；现为 `test_audit_quoteRules`） |
| A-4 | 打新 | 低 | 分红合约 owner 改 `setLaunchpad` 后，`refund` 里的 `setShare` revert，失败退款被卡。 | `refund` 不再调分红合约（失败的币没有分红） | `test_audit_refundIndependentOfVault` |
| A-5 | 打新 | 低 | `try/catch` 卡 gas：收币方一侧，发送方能选 gas 让收币方的份额停在旧值（实测 1,000 个 gas 值成功）；卖家一侧实测不能利用，余量约 500 gas。 | `catch` 里判断剩余 gas，调用方卡 gas 导致的失败直接 revert | `test_audit_receiverGasCannotLeaveStaleShare`（修复前失败、修复后通过）、`test_audit_vaultFailureStillSwallowed` |
| A-6 | V3 | 低 | 内盘卖出先分账再更新份额，卖家按比例拿回自己的卖出税（独家持有人 5% 卖税、100% 分红时返还 4.5%）。 | 卖出先更新卖家份额再分账 | `test_audit_sellerEarnsNothingOfOwnSellTax`（修复前失败、修复后通过）、`test_audit_sellTaxStillPaysOtherHolders` |
| A-7 | V3 / 打新 | 低 | `setMigrator` 一次性且不检查 migrator 绑定的核心，绑错会让毕业 / 发射永久失败。 | 检查 `migrator.launchpad() == address(this)` | `test_audit_setMigratorChecksPad`（两套） |
| A-8 | 路由 | 提示 | 仓库的 MockWBNB 用 `call` 退款，真实 WBNB 用 `transfer`（2300 gas），以后改 `receive` 时测试发现不了。 | MockWBNB 改成 `transfer` | GangRouter 套件 |
| A-9 | 路由 / 接线 | 提示 | 主网不设 `OWNER` 时所有合约会留在部署钱包；`DeployGangRouter` 不校验核心。 | 主网必须设 `OWNER`；校验核心的 WBNB | 主网模拟部署 |
| A-10 | V3 | 低 | 非官方池子累计分红份额。 | 运维处理，见 K-13 | — |
| A-11 | V3 | 提示 | DividendVault `setLaunchpad` 能转走已存入的分红；欠款在接收地址永久不可收时卡住；`process` 一次卖光。 | 写入 §4.2、K-14、K-15 | — |
| A-12 | 打新 | 提示 | `refund` 不减 `sold`。 | 不改，§5 #2 改为只对未失败的 sale | — |
| K-16（新增已知问题） | V3 | 低 | 毕业前卖出要求卖家当时仍持有 Agent ID（与 V2 一致）。Agent ID 是灵魂绑定的，正常不会失去；如果注册表收回某个 ID，这个持有人毕业前就卖不掉（代币锁转账）。 | 不改，与 V2 一致 | — |

审计员核对后认为没问题的部分（摘要）：多个 sale / 曲线共用报价币时的资金隔离；部分撤出的手续费取整；截止那一秒的边界；类型截断；发射 / 毕业不能被提前建池、打入、`sync` 阻止；V3 买卖记账（fuzz 1000 轮：平台恰好拿到 1% + 0.5%，核心最多留 1 wei）；TaxRouterV3 的欠款隔离与重入；税的方向判断；`fairMintBNB` 付款额与核心扣款完全一致（fuzz）；路由的余额差结算、重入、2300 gas 退款、转账扣费报价币不留余额 / 授权；部署脚本的一次性设置不能被抢跑。

---

## 11. 第二轮内部审计（2026-10-26）

审计对象 `7ec80dd`（含第一轮修复），修复在 `47a063b`。这一轮按攻击目标分三组：拿走不属于自己的钱、让别人的钱卡住 / 系统停摆、白拿收益或少交费用。每组跨所有模块审，换了一个模型，只给代码和规格，不给本文档和第一轮结论；池子相关的攻击用仿真 Pancake V2 池子（K 检查、0.25% 手续费、skim、sync、MINIMUM_LIQUIDITY）实测。没有发现严重 / 高危问题；「拿钱」和「卡钱」两组都没有找到可行路径。

| ID | 来源 | 严重度 | 问题 | 处理 | 回归测试 |
|---|---|---|---|---|---|
| R2-1 | 白拿收益 | 中 | 白名单里没设固定换算额的报价币按 dev 自选参考池的**现价**锁定募集额 / 毕业额。同一笔交易里闪电贷拉偏浅池子，15 BNB 的募集可以锁成真实价值的万分之一（PoC：成本约 0.005 BNB），一伙人低价打满、拿走 50% 筹码后砸给后来的买家。主网计划里 USDT 正是按池子换算，可以被利用。 | 非 WBNB 报价币必须有固定换算额（`graduationAmount > 0`），主网 USDT 由当时的 `USDT_PER_15_BNB` 设定、多签维护。**2026-10-27 起按产品决定改回参考池换算、重新接受这个风险，见 K-1、§15** | `test_create_refPoolAgainstWbnb`、`test_audit_quoteWhitelist`（两套）、主网分叉 `test_fork_usdt_raiseTracksBnbPrice` |
| R2-2 | 白拿收益 | 中（金额小） | keeper 的外盘税一次性卖出可以被夹：在 keeper 的 `minQuoteOut` 容忍范围内先卖后买。15 BNB 池子、1% 税时，容忍 3% 赚 0.008 BNB，10% 赚 0.23 BNB；容忍度大时前置卖单还能让 keeper 的交易 revert。 | 运维：高频小额、容忍度 ≤ 1–2%、私有 RPC（K-15） | — |
| R2-3 | 白拿收益 | 低（有条件） | 如果 V3 和打新共用同一个 DividendVault，V3 handler 的 `syncShares` 能给打新代币写份额，绕过出局规则。 | 当时不可达：每个核心一个 DividendVault。2026-10-27 起两个核心共用 SharedDividendVault，改为按币记登记核心、只有该核心绑定的 operator 能写（§15，`test_shared_handlerCannotTouchOtherCoresToken`） | — |
| R2-4 | 拿钱 / 卡钱 | 低 | migrator 免税、不能领取，有人把 V3 代币转给它，它会累计永远领不走的分红，稀释其他持有人；非官方池子的分红可被 `claimFor` + `skim` 拿走（K-13）。 | 部署时 V3 的 DividendVault 排除 migrator（测试网已补发这笔交易）；其他池子按 K-13 运维处理 | 部署接线检查 |
| R2-5 | 卡钱 | 低 | V3 毕业前卖出要求卖家当时持有 Agent ID。 | 不改，与 V2 一致（K-16） | — |
| R2-6 | 拿钱 | 提示 | 主网按地址链接已部署的 PoolCheck 库，核心经 delegatecall 执行它。 | 部署前核对字节码（§9） | — |

审计员试过但失败的攻击（摘要）：打满前抢建池子并打入报价币 / `sync`（只让开盘价略高、捐赠者亏钱）；经路由把代币塞进池子（准入开启时不可能）；让 keeper `process`、`distribute`、`release`、毕业 / 发射、转账钩子永久 revert；用会 revert 或耗 gas 的接收地址卡交易（只是记欠款）；抢在 keeper 前买入吃分红（三组分别实测都亏钱，keeper 自己卖出的冲击大于分到的分红）；夹内盘买卖（两边各付 1% 手续费加税）；曲线取整、上限 / 毕业截断、手续费 / 税规避（fuzz 1000 轮无利可图）；刷单赚分红或接收地址那份；女巫地址绕过出局线；部分撤出的取整；GangRouter 误转余额、重入、残留授权；部署脚本的抢跑窗口。

---

## 12. 代币合约收紧发射台权限 + 元数据 URI（2026-10-27）

来自内部评审的三个问题，改动在 `cf96281`。

**1. 发射台对代币的权限是否过大。** 原先代币上 `setTaxHandler`、`setPair`、`exclude` 都能反复调用，地址不受限制；`burn` 发射台根本不用。实际只有发射台合约在毕业 / 发射那一笔里各调一次，没有 owner 路径能触发，但代币本身不设任何限制。现在改为：
- 税处理合约在构造时写死（`immutable`），并且从一开始就免税；
- 毕业 / 发射时 `unlock(migrator)` 一次性解锁并排除 migrator，再调一次就 revert；
- `setPair` 只能在解锁之后、并且只能调一次；
- 删掉 `setTaxHandler`、`exclude`、`burn`。
- 毕业 / 发射之后，代币上没有任何管理函数。打新的 `reclaim` 只在发射前有效，这一点不变。
- V3 无税币改用新的 `LaunchTokenV3`（V2 源码不动）：`unlock` 只能一次，没有 `burn`。

**2. pair 和税处理合约是否应在部署时确定。** 税处理合约在发币时就已知，所以改为构造时写死。pair 不在发币时创建：那样每次发币要多花约 250 万 gas，大多数币永远不会毕业。也不在发币时用 CREATE2 推算：各条链的 init code hash 不同，复杂度高，而毕业前代币本来就锁着。现在是毕业时由 migrator 建好池子后设定一次，之后不能再改。池子税和分红同步从 `setPair` 开始生效，和原来「迁移完成后再接上 handler」的行为一致。

**3. 转账钩子（`notifyTax` / `syncShares`）的 gas、重入、revert。** 不改，理由：
- gas：实测（测试环境、首次写入）没有分红的币，钱包转钱包约 5.5 万、卖进池子约 14 万；有分红的币分别约 17 万、18 万。
- 重入：钩子只调用固定的 handler 和 DividendVault，余额在调钩子之前已经更新，`notifyTax` 带 `nonReentrant` 且只记账，`setShare` 只记账、不转账。
- revert：`notifyTax` 只在调用方不是代币或税额为 0 时 revert，这两种情况代码已经排除；`syncShares` 只在 handler 被撤掉分红合约 operator 时 revert（owner 操作，可恢复，K-7）。第二轮「卡钱」组专门试过，没能让它们 revert。
- 不改成低级 `call` 加 gas 上限再吞掉失败：吞掉 `notifyTax` 会让已经转进 handler 的税没有入账，拆分全错；吞掉 `syncShares` 会留下过期份额（第一轮 A-5 就是这一类问题）；调用方能用 63/64 规则卡住子调用的 gas，固定上限防不住；而上限设低了，又会在分红合约 gas 变化时被静默误判为失败。

**元数据 URI。** 三种代币共用 `TokenURI`：`string private _uri` 在构造时写入，没有 setter，`contractURI()`（ERC-7572）和 `metaURI()` 都返回它。两个核心的 `create` 为此新增参数 `metaURI`，放在 `logoURI` 之后：`metaURI` 是元数据 JSON 的地址（name、symbol、description、image、external_link、twitter，由 CLI 生成并上传），写进代币；`logoURI` 仍是图标地址，照旧存进发射台的 `logoURIOf`、发出 `Created` 事件，服务端和网站不受影响。合约不校验 `metaURI` 的内容。

回归测试：`test/launchpad-v3/TokenAdmin.t.sol`（V3 有税 / 无税）、`test/fair-mint/FairTokenAdmin.t.sol`，覆盖：
- URI 等于发币时传入的值；
- 税处理合约在构造时设定；
- 解锁前不能 `setPair`，非发射台不能调用；
- 毕业 / 发射后 `unlock`、`setPair`、`reclaim` 都 revert；
- `setTaxHandler`、`exclude`、`burn` 不存在。

全量 278 个测试和主网分叉测试通过，本地测试网 fork 上的 V3 和打新整轮也通过。

---

## 13. PostGradTaxHandlerV3 加固（2026-10-27）

来自内部评审的四个问题，改动在 `13da13b`。

**1. 平台部分会不会大于税额。** 正规币不会：买卖税率在发币时限定 100–500 bps，平台部分 `tax × 50 / rate` 最多占税的一半。但 `notifyTax` 原先只校验 `msg.sender == token`，而 `TaxTokenDeployerV3` 谁都能调用：有人可以部署一个发射台指向自己、handler 指向我们、税率为 1 bps 的代币，记下 50 倍于税额的平台部分。这个币没有在 TaxRouterV3 登记，`process` 会 revert，动不到任何资金；但它会刷 `TaxAccrued` 事件，让 keeper 白跑。现在 `notifyTax` 先查 `routeOf(token)`，没登记就 `UnknownToken`（登记只能由发射台在发币时做一次），平台部分另外加上限 `min(…, tax)`。代价：每笔收税的池子交易多约 5.6k gas（卖出转账 140,080 → 145,676）。

**2. `notifyTax` 是否应改用余额差。** 不改。代币在同一个 `_update` 里先把恰好 `taxAmount` 转给 handler（handler 免税，代币也不扣转账费），再调 `notifyTax`，到账数严格等于 `taxAmount`。改用「余额 − accruedTax」反而会把别人直接打给 handler 的币算进下一笔交易的税。记账大于余额的情况，`process` 已经按实际余额等比缩小。

**3. 为什么从 route 取报价币而不是从 pair 取。** 分账按 `routeOf[token].quote` 拉币付款，route 是唯一的依据：只有发射台能登记、每个币只能登记一次，router 在 handler 里是 immutable；毕业时 migrator 用同一个报价币建池子，两者天然一致。缺口在于原先只有直连池子那条路径校验池子的另一边，走 `dexRouter` 时没校验。现在 `process` 在两条路径分支之前都校验池子恰好是 token / route 报价币，不符就 `PairQuoteMismatch`。

**4. 分账是否应直接在 handler 里做。** 不改。内盘（发射台）和外盘（handler）的税都由 TaxRouterV3 按同一套规则拆分；推送失败的欠款、`release`、`TaxPaid` 事件也只在这一处，合作方统计收入、keeper 补发都只看它。多一次外部调用加一次 approve / transferFrom，约 3–4 万 gas，只发生在 keeper 每批 `process` 时。

TaxRouterV3 不可升级：没有代理，LaunchpadV3 和 handler 里都是 immutable 引用。owner 只能 `setSource`（只能往里付钱的来源）和一次性的 `setLaunchpad`，规则和已登记的 route 都改不了。

回归测试（`test/launchpad-v3/LaunchpadV3Audit.t.sol`）：伪造代币的收税转账 revert 且不记账；pair 被换成另一报价币的池子时，两条路径都 revert、累计的税不被消耗；正常池子照常处理。

---

## 14. 打新去掉截止时间 + 第三轮内部审计（2026-10-27）

用户：「打新的逻辑有点问题，不要设置到期时间，这样就不涉及到退款，打新的币可以卖掉，只是价格曲线是固定价格。」改动在 `0a934ae`（合约）和 `1bcc84f`（第三轮审计修复），规格见 `docs/SPEC-FAIR-MINT-2026-10-26.md` 开头的重设计说明。V3 和 GangRouter 的逻辑不变；路由只跟着 `sales()` 返回的字段数改了解码（13 → 14 个字段）。

**规则变化**

| 项 | 之前 | 现在 |
|---|---|---|
| 截止时间 | 1–72 小时，到期没打满 → Failed | 没有；一直开着直到打满 |
| 退款 | `refund`：本金 + 打新费全额 | 删除（`Failed`、`Refunded`、`NotFailed`、`NothingToRefund` 一并删除） |
| 退出 | 截止前 `withdraw` | 打满前任何时候 `withdraw`：按打新价卖回，扣撤出费 |
| 打新费 | 1%–5%，托管到发射，失败全退 | 1%–3%，打的那一笔直接进 bucket，不退 |
| 撤出费 | 1%–5% | 1%–2%；sale 7 天没有进展时为 0 |
| 单地址上限 | 0.1%–0.5% | 0.25%–0.5%（最多需要 200 个地址） |
| 托管 | 本金 + `escrowedFee` | 只有本金（+ bucket 拒收时的 `owedFee`） |
| 分红合约写入（卖回时） | 阻塞 | 不阻塞：真拒绝时保留旧份额、发 `ShareWriteFailed`；卡 gas 造成的失败仍 revert（`OutOfGas`） |
| HolderRewardHandler | 基准为 0 的地址直接跳过 | 基准为 0 的地址目标份额为 0：全部卖回、但分红合约当时拒绝清零的地址，发射后第一次同步就被清掉 |

去掉退款后，卖回成了未打满时唯一的退出方式，所以卖回路径上的两个外部依赖（分红合约、bucket）都改成了不阻塞：owner 无法通过它们冻结打新的人的本金。打新本身仍然依赖 bucket（拒收时 revert），这是有意的：打新可以停，退出不能停。

**第三轮内部审计**

审计对象 `0a934ae`，一个独立审计员，只给代码和规格，PoC 全部用 Foundry 实测（`Audit3.t.sol`，未并入仓库，修复后的回归测试在 `test/fair-mint/FairMintAudit.t.sol`）。没有发现严重 / 高危问题；资金守恒成立，唯一影响资金的弱点是低危。

| ID | 严重度 | 问题 | 处理（`1bcc84f`） | 回归测试 |
|---|---|---|---|---|
| R3-1 | 低 | 每一笔打新都会重启 7 天计时。任何持 Agent ID 的地址每 6 天 23 小时打 1 份（每次成本约 0.0005–0.005 BNB），就能让所有人一直付 1%–2% 撤出费；撤出费归平台，攻击者自己没有收益（PoC：15 BNB 的 sale，4 周花 0.0046 BNB）。 | 只有进展才重启：创建者那一笔起算，之后 `sold ≥ markSold + STALE_STEP`（10 份，0.1%）的打新才重启并更新 `markSold`。卖回不算；打 1 份、撤了再打回来都不算。想让计时一直不到期，就得不断净增份数并持有，每个地址最多 5–10 次。`Sale` 末尾加 `uint16 markSold`（和 `refPool` 同一个槽），`lastMintAt` 改名 `progressAt` | `test_audit_staleClockNeedsProgress`、`test_withdraw_exitFeeWaivedWhenStale` |
| R3-2 | 低 | 卖回里撤出费进 bucket 是阻塞的：bucket owner 撤掉核心的 operator，所有没停滞的 sale 卖回都会 revert（打新也会），直到 7 天后撤出费变 0。需要多签作恶或误操作，而且有 7 天上限。 | 撤出费改为不阻塞：`try notifyAccrual`，失败时清掉授权、记 `owedFee[quote]`、发 `FeeOwed`；任何人 `flushFees(quote)` 补交（发 `FeesFlushed`）。用户到手金额不变，所以故意卡 gas 让它失败得不到好处，不需要 gas 检查 | `test_audit_withdrawIndependentOfFeeSink` |
| R3-3 | 低 | 分红合约拒绝卖回时的份额写入（只有分红合约 owner 能造成）：全部卖回的地址（0 枚、基准 0）保留旧份额，发射后按旧份额分到奖励，直到有人为它 `syncShares`；这个地址不会再转账，没人有动机去同步。 | 写入失败时发 `ShareWriteFailed(token, user, share)`；keeper（`keeper-tax-process.sh` 的 `FAIR_PADS`）扫这个事件，代币发射后对份额高于基准的地址调 `syncShares(token, user, 0)` | `test_audit_withdrawIndependentOfVault`（检查事件） |
| R3-4 | 提示 | 最后一笔被抢跑：有人在「恰好打剩下全部、`minShares` 等于剩余份数」的交易前撤出 1 份，那笔交易会少打 1 份、sale 停在 9,999 不发射。 | 不改：下单份数大于剩余份数的人不受影响（自动截断）；每次拖延攻击者都要付撤出费；任何人随后打完最后 1 份就发射 | — |
| R3-5 | 提示 | 提前建好池子并打入报价币，开盘价高于打新价。 | 不改，同 K-4：只让持有人受益、捐赠者亏钱，不会让发射 revert（该 PoC 用 MockPair，`test_launch_withPreCreatedPair` 覆盖了提前建池不捐赠的情况） | — |
| R3-6 | 提示 | 基准为 0 的新分支让每笔池子交易多一次读分红合约份额（约 2.7k gas，估算未实测）。 | 不改，无正确性影响 | — |

审计员试过但失败的攻击（摘要）：
- 资金守恒（fuzz 1000 轮：两个 sale 共用 WBNB、不同手续费和上限，随机打新 / 卖回 / 跳时间）：发射台余额始终等于 Σ sold × 价格，到手 + 撤出费 = 本金，取整漏不了钱。
- 卡 gas 让卖回的份额写入失败：`setShare` 没有嵌套调用，被卡 gas 时调用方剩下的不到 `gasBefore / 63`，一定按 `OutOfGas` revert。
- 创建时计时：创建者那一笔就设了 `progressAt`，sale 不会一创建就是停滞的。
- 刷打新 / 卖回获利：每一轮都付打新费，只会亏。
- 永久阻止发射、或让钱卡死：最后一笔截断到剩余份数，任何大单都能打满；发射台持有本金时，持有人总能卖回；女巫地址挡不住别人打最后一份。
- 发射前代币离开「发射台—打新地址」：`_update` 锁转账加 `reclaim`，余额始终 = 份数 × 50,000 枚。
- 路由：14 字段的 `sales()` 与路由解码一致；`need` 等于核心实际扣款，余下的由 `_settle` 退回；`mintFor` 要求准入，路由不能给未来池子地址打新。
- 用基准为 0 的新分支偷奖励：它只会把份额清零；被排除 / 已出局的地址目标仍为 0。
- 不托管打新费后的发射记账：发射时发射台恰好持有 10,000 × 价格的报价币和 LP_SUPPLY 枚代币。
- owner 冻结卖回：分红合约已不阻塞，卖回不读 registry 和准入；bucket 这条路见 R3-2，已修。

**结果**：全量 286 个测试通过，主网分叉 14 个通过（`BSC_RPC_URL`），FairMintPad 16,533 B。本地 anvil（BSC 测试网 fork）上跑过：建 sale、打新、卖回、跳 7 天 + 1 小时后打 1 份（计时不重启、撤出费为 0、卖回全额）、新 sale 照收撤出费；分红合约拒写和 bucket 拒收各触发一次，100 个地址打满发射后，keeper 干跑列出 `syncShares` 和 `flushFees`，广播后份额清零、欠费进 bucket，再跑一次无事可做。


---

## 15. 合约合并（方案 A）+ 第四轮内部审计（2026-10-27）

用户：「你写的这几个合约过于复杂了，互相调用来调用去，非常不利于后期的维护」。按方案 A 合并重复的部分，同一天的产品决定一并做进来。

**改动**

| 项 | 之前 | 现在 | 提交 |
|---|---|---|---|
| V3 的税 | TaxRouterV3（分账 / 欠款）+ RecipientRegistry（白名单）+ PostGradTaxHandlerV3（外盘税），三个合约互相调用 | 一个 `TaxHandlerV3`；事件签名不变（`Listed` / `Delisted` / `RouteRegistered` / `TaxDistributed` / `TaxPaid` / `TaxOwed` / `TaxAccrued` / `OuterTaxProcessed` …），只是发出者变了；`setSource` 删除，`distribute` 只有发射台能调；外盘税换成报价币后在合约内直接分账 | `ee5fb28` |
| 两个外盘税处理合约 | 各写一份 | 共用 `src/common/PostGradHandlerBase.sol`（keeper / owner、累计税、换币与 pair 报价核对、带保护的写份额） | `ee5fb28` |
| 分红 / 迁移 / 代币部署 | 每个核心各一份 V2 的 DividendVault、MigratorV2、各自的代币部署合约 | 共用 `SharedDividendVault`（按币记登记核心 `launchpadOf`，只有该核心和绑定到它的 operator 能写；门槛按核心）、`SharedMigrator`（核心名单只加不减）、`TokenDeployer`（三种代币；LaunchTokenV3 也挪出核心，LaunchpadV3 22,317 → 18,642 B） | `693df3e`、`883c111` |
| 报价币 | 只收 WBNB 和 QuoteRegistry 里设了固定换算额的 18 位币 | 用户决定沿用 V2 的用法：任意 18 位 ERC-20，发币人自选参考池换算（V2 池 / V3 池，V3 用 TWAP），固定换算额仍优先。等于重新接受 R2-1（K-1） | `b733933` |
| 主网 USDT | `USDT_PER_15_BNB` 固定换算额，多签维护 | 不设固定额，用 Pancake V3 USDT/WBNB 0.01% 池 `0x172f…f849` 换算 | `076b3dc` |
| 合约数（一套部署） | 15 个 | 10 个（两个核心、两个 handler、五个共用合约、GangRouter） | — |

合并里新加的一处保护：欠接收地址的报价币和待卖的税币现在在同一个合约里，而报价币放开后，报价币本身可能就是这个 handler 收税的币。新增 `owedTotalOf[quote]`，`process` 能卖的数量 = 余额 − 欠款（`test_merge_owedQuoteNeverSoldByProcess`，invariant #9）。

**第四轮内部审计**（审计对象 `076b3dc`，三个互相独立的审计员：共用层隔离、合并后的税路径、任意报价币；只给代码和关注范围，PoC 全部用 Foundry 实测）。没有严重 / 高危问题；跨核心读写、跨报价币取钱都没有找到可行路径。修复在 `906f5aa`，回归测试 `test/audit4/Audit4Regression.t.sol`。

| 来源 | 严重度 | 问题 | 处理（`906f5aa`） |
|---|---|---|---|
| 共用层 F-1 / 税路径 F2 / 任意报价币 F-2 | 中 | 转账扣费的报价币：分红合约和 bucket 按名义金额记账、实际到账更少，同一报价币的其他币的持有人后领的领不到 | V3 核心第一次拉报价币时按到账校验，不等就 `FeeOnTransferQuote`（同打新的 `_pullExact`）；`depositReward` 改为按余额差记账（覆盖事后才开手续费的报价币） |
| 任意报价币 F-1 / 税路径 F3 | 中 | 转账扣费的报价币永远毕业不了：发射台按名义金额转给迁移合约，迁移合约再转进池子时不够 | 同上，入口就拒收 |
| 任意报价币 F-3 | 中 | 同一核心里还没毕业的兄弟币可以当另一个币的报价币，把币「停」进曲线后重新获得上限额度，单个钱包在毕业前持有 5.9 倍上限（主网分叉 PoC） | `TokenDeployer` 记录部署过的每个币（`isLaunchToken`），两个核心拒绝它们和已在分红合约登记的币做报价币 |
| 税路径 F1 / 共用层 F-2 / 任意报价币 F-4 | 中 / 低 | 用一个分红币当报价币时，分红合约、bucket、新池子都拿到这个分红币的份额，分到的钱永远领不出来 | 同上拒收；分红合约构造时排除自己，部署脚本排除 bucket，`_checkCore` 校验 |
| 共用层 F-3 | 提示 | 打新的 handler 接受任意合约报来的税（只会刷事件，动不了钱） | `notifyTax` / `syncShares` 要求 `launchpadOf(token) == pad`，否则 `UnknownToken` |
| 共用层 F-4 | 提示 | `migrate` 不检查池子里是否已有 LP：恶意报价币的转账回调可以抢先 `mint`，让 0xdead 只拿到一点 LP | mint 前要求池子 `totalSupply == 0`（`PairHasLiquidity`）；预先建好的空池子仍可用 |
| 税路径 Info | 提示 | `distribute` 的 `OnlySource` 已名不副实；直连池子换币路径不按实际到账再核对 `minQuoteOut` | 改为 `OnlyLaunchpad`；按实际到账再核对（`Slippage`） |

已知未改：已毕业的 V2 发射币仍能做报价币（它的分红走 V2 自己的分红合约，影响很小）。

审计员试过但失败的攻击（摘要）：跨核心写份额 / 存奖励 / 重新登记代币（`AlreadyRegistered`，这一点同时关掉了 §10 的 I-1）；陌生人调用共用合约的特权函数；两个核心嵌套迁移混用金额；恶意报价币回调重入同一核心 / 另一核心 / 路由 / handler；用 `balanceOf` 撒谎的报价币碰别的报价币的钱；用正在创建的币（预先算地址）当报价币；`process` 卖掉欠款或别的币的税；共用重入锁导致的卡死；`_sellable` 下溢；夹 `process`（`minQuoteOut` 必填）。

---

## 16. 外盘税改为卖出时自动小额换 + 按税产生时记账（2026-10-27）

**起因**：正式站 V2 有三个有税币的外盘税从来没有被 `process` 过，攒成了池子代币储备的 21%–45%，一次卖出价格要跌 17%–31%；就算卖了，分红也会按卖出那一刻的持有人分，而不是交税时的持有人。V3 和打新的旧处理合约和 V2 一样：依赖 keeper、只能一次卖光、按卖出时的份额分。两路流程审查（V3、打新）在 `906f5aa` 上用主网分叉复现了同样的问题（打新：keeper 停 4 周后一次卖出跌 34%，全程持有的地址在卖出前跌破出局线就一分拿不到；V3：一周后跌 48%，前一天卖掉的地址分 0、卖出前一个区块买入的地址分到 0.066 BNB）。用户选定方案：卖出时自动小额换 + 按税产生时记账，交易对仍是 Pancake V2。（另调研过 PancakeSwap Infinity 带 hook 的池子直接按报价币收税：技术可行，但路由要 Pancake 人工审核白名单、聚合器支持不明、Pancake 可暂停全部池子、hook 部署后不可改，留作下一版。）

**设计**（`6b5e03f`）

- **卖出时自动换（`swapBack`）**：一笔收了税的卖单进池子前（池子未锁），代币调 `handler.swapBack(token, sellAmount)`，处理合约把攒下的税卖一块直接进池子，按同一调用里的储备计价（下限 1%）。单块 ≤ 池子代币侧 0.5%（`CHUNK_MAX_BPS = 50`）且 ≤ 这笔卖单的 25%（`SWAP_BACK_SELL_BPS = 2500`）；每个币每个区块最多一次（`lastSwapBackBlock`）；这笔转账不产生税（零头、被排除地址）时不触发；池子余额与储备不一致（有人加流动性到一半）时跳过。买入时池子已锁，只累计；钱包间转账不触发。
- **失败不影响交易**：这一块自己失败被吞掉、代币发 `SwapBackFailed`；只有「调用方给的 gas 不够导致这一块耗尽」时整笔回滚（`SwapBackOutOfGas`），这样 `eth_estimateGas` 二分出的 gas 一定包含这一块（之前「gas 不够就跳过」会让钱包按估算发的交易永远跳过这一块）。
- **keeper 补位**：`process(token, amount, minQuoteOut)`，数量截到 `maxChunk(token)`（只会少卖），同一区块可多次；只有买单时 keeper 分块卖完。`previewSell(token, amountIn)` 返回卖单含这一块之后实际能拿到的报价币。
- **按税产生时记账**（`SharedDividendVault`）：持有人那份在 `notifyTax` 当场按当时份额记成税币单位（`accrueDividendUnits`）；卖出后按这一批实际换回的报价币兑现（`convertDividend`）。分批先进先出，同一个币最多两批未结算（`open` 在攒、`selling` 在卖），一批卖完才按它的报价币结算；每个持有人最多记两批未结算单位，跨很多已结算批次用累计指数一步算完；放大系数 1e36，单位字段两个 `uint128` 打包；取整一律向下。选分批先进先出而不选 Liquity 稳定池式的 epoch / scale：每卖一块几乎都会把一整批卖完，只需一个累计指数，状态少、好审计。两个 handler 共用同一套（打新仍是 `min(持仓, 打到的数量)` + 出局线，V3 仍是持仓 + 门槛）。
- **下游拒收不卡住**：分红合约拒绝兑现时这批单位和报价币留在 handler（`pendingHolderUnits` / `pendingHolderQuote`，`HolderConversionDeferred`），下一块或任何人 `flushHolders` 补兑现；bucket 拒收时平台那份记 `owedPlatformOf`（`PlatformOwed`），任何人 `flushPlatform` 补交；分红合约拒绝记账时那份归接收地址 / 平台；V3 写份额也改为带保护（`ShareWriteFailed`）。

**两路流程审查对新代码的设计意见及处理**

| 来源 | 意见 | 处理 |
|---|---|---|
| 打新 D1（高） | 上限是「每次调用」：往池子转 1 wei 再 `skim` 就触发一整块，可循环，一笔交易砸光积压并夹子 | 每区块一次；单块 ≤ 这笔卖单的 25%；不产生税的转账不触发 |
| V3 A（严重） | 「剩余 gas 不到 65 万就跳过」会让 gas 估算落在跳过这一块的路径上，真实使用中几乎从不执行 | 改为 gas 不够整笔回滚（`SwapBackOutOfGas`）；测试用二分法模拟 `eth_estimateGas`，在估出的最低 gas 下这一块会执行（V3 一笔卖出转账约 41–48 万 gas） |
| 打新 D2 | 换币会吞掉池子里未同步的余额（加流动性到一半的人会失败或亏） | 余额与储备不一致时跳过 |
| 打新 D3 / V3 B | 每个卖家前面先卖一块，链下预先算好的金额不含这块，滑点紧的单会失败 | 单块 ≤ 卖单 25%（卖 50 份时成交约为普通报价的 98.19%，已含 1% 卖出税）；新增 `previewSell` |
| 打新 D4 / F2 | bucket 拒收或兑现失败时整块失败，持有人那份被平台那份连累 | `owedPlatformOf` / `pendingHolder*` + `flushPlatform` / `flushHolders`，这一块照常完成 |
| 打新 D5 | 先记账再同步份额：卖家按卖出前份额分到自己这笔卖出的税 | 保留并写入注释（§3.2） |
| V3 C | V3 写份额没有保护（K-7）；兑现失败会让 `process` revert、keeper 卡住 | 写份额带保护；`process` 遇兑现失败也能继续 |
| V3 D | keeper 每次一块，10 分钟一次可能跟不上只有买单的拉盘 | keeper 每次运行对每个币循环到卖完或 20 块；合约允许同一区块多次 `process` |

**owner 权限收紧与卖回保护**（`f1c00b3`，来自打新流程审查 F3 / F4）

| ID | 问题 | 处理 |
|---|---|---|
| F3（低） | 卖回没有最少到手：看到撤出费 0% 去卖回的人，可能被抢先一笔 10 份的打新重启计时、被收 1% | `withdraw(token, shares, minPayout)`，不足报 `Slippage`；CLI 用 `previewWithdraw` 减 0.1% |
| F4a（中） | 分红合约 owner 能给核心绑一个新 operator，写任意份额，拿走持有人那一半的 99.9% | `setOperator` 每个核心、每个地址只能绑定一次，不能解绑 / 更换（`OperatorAlreadyBound`，`operatorFor(core)` 可查）；处理合约代码不可变、写份额有保护，不留应急解绑 |
| F4c（中） | 发币后还能调高分红门槛，把所有人的份额清零 | `registerToken` 时把核心门槛快照到 `tokenMinimumShareBalance[token]`，之后改门槛只影响新币 |
| F4b（中，含 Low #3） | 换掉换币路由再配合 keeper 用 1 wei 的 `minQuoteOut`，能拿走全部攒下的税；路由不能改回直连池子 | 去掉 `setDexRouter`：路由在构造时传入（0 = 直接对池子卖），之后 `proposeDexRouter` → `DEX_ROUTER_DELAY`（48 小时）→ `acceptDexRouter`，可 `cancelDexRouter`，可改回 0；加上分块，单次最多一块 |
| F5（中） | 放开任意报价币后，事后开手续费的报价币会让 sale 永远发射不了；暂停 / 拉黑型报价币可能让本金取不出来 | FOT 在入口和扣款时拒收（§15）；暂停 / 拉黑型属于不设白名单的已知代价（K-12） |

**链下**（gangfun-server `feat/keeper-ops`，运维审查的结论）：keeper 以核心地址为主配置（`V3_PADS` / `FAIR_PADS`，从链上读 handler 和 bucket 自动接线），全空时报错；分块路径按 `maxChunk` 卖、每块单独算 `minOut`、每次运行最多 20 块；启动时探测日志 RPC；`cron-run.sh` 让任何非零退出都报警；健康检查每 30 分钟检查接线、keeper 最近运行、未卖税 > 池子代币储备 1%、欠款、卡住的兑现 / 平台欠款、`SwapBackFailed`、keeper 余额、索引器落后。

**gas**（主网分叉、真实 Pancake）

| 情况 | gas |
|---|---|
| 改动前的一笔卖出（同一全流程测试） | 27.6 万 |
| 卖出 + 自动换一块 | 60.4 万 |
| 同一地址再卖，带一小块，存储已热（最常见） | 57.6 万 |
| 没有可换的税，但这个地址第一次按新规则结算 | 47.0 万 |
| 经 Router02 的一笔 V3 卖出（含一块） | 约 56.3 万 |

**结果**：`ddce6b6` 上 `forge test` 487 个通过；主网分叉 `--match-contract Fork` 25 个、`test/fork/*` 12 个通过（48.club）；invariant 新增 #12（§5 #11–#12），`6b5e03f` 上 200 × 80 压力跑全过；所有合约 < 24,576 B（§7）。

---

## 17. 第五轮内部审计（2026-10-27）

审计对象 `ddce6b6`，三路独立审计并行：A 按税产生时记账（分红合约的批次记账），B 卖出时自动换、夹子、gas 与 keeper 分块（真实 Pancake 的主网分叉），C 全系统回归、owner 权限与部署脚本。没有 Critical / High。修复在 `98cab5c`，三路的 PoC 都改成了回归测试，放在 `test/audit5/`（audit5a / audit5b / audit5c）。

**用户的决定**

- C-F2（keeper 热钱包能经 `collectPlatformSmart` 把 80% 回购换给自己）：暂时只关掉自定义路由。回购合约和金库地址先沿用现在的配置。
- C-F7（外盘卖家分到自己这笔卖出税的分红）：不分给卖家，和内盘 A-6 一致。
- C-F5（`setExcluded` 可以把除指定钱包外的所有持有人排除）：只能排除合约地址。

**发现与处理**

| 编号 | 级别 | 问题 | 处理 | 回归测试 |
|---|---|---|---|---|
| B-F4 / C-F6 | 中 / 低 | keeper（或 owner；`setKeeper` 当时立即生效）同一区块连调 `process`、最低成交额 1 wei，一口气卖光积压再夹子（PoC：同伙多拿 17.2% 的币），48 小时换路由时间锁挡不住直接对池子卖 | 每个币每区块一个额度（区块内第一次尝试时池子代币储备的 0.5%），`swapBack` 和 `process` 共用、按卖出数量扣；任何一块都不在比区块参考价低 2% 以上的价格卖（`swapBack` 跳过、`process` 回滚 `PriceBelowReference`）；`setKeeper` 只能部署时设一次，之后 `proposeKeeper` → 48 小时 → `acceptKeeper` / `cancelKeeper`（两个处理合约和新手续费池都是） | `audit5b`：`test_F4_keeperDumpSandwichNoLongerPays`、`test_I1_keeperCanSellOneBudgetPerBlock` |
| B-F1 / A L-1a | 低 | 一笔零头卖单抢在区块最前面，占掉「每区块一次」的名额，后面正常卖单都不换 | 额度按卖出数量扣，零头只用掉零头 | `audit5b`：`test_F1_dustSellNoLongerBurnsTheBlock`；`audit5a`：`test_dustSellNoLongerTakesTheBlocksSwapBack`；`SwapBack.t.sol`：`test_swapBack_blockBudgetSharedBySells` |
| B-F2 / A L-1b | 低到中 | 卖出前往池子转 1 wei 报价币，余额与储备对不上，这一块就被跳过（卖家多拿 0.96%、省约 30 万 gas）；还能「捐 1 wei → 先砸 → 后换」 | 只有多出的余额相当于这笔卖单价值一半以上（像加流动性加到一半）才跳过，并且跳过会用掉这一区块的额度；零头被吸收；余额低于储备（闪电兑换回调中）不卖；再加上区块参考价，先砸后换不成立 | `audit5b`：`test_F2_oneWeiQuoteDonationNoLongerSkipsChunk`；`audit5a`：`test_donationNoLongerLetsTheChunkRunAfterADump`；`SwapBack.t.sol`：`test_swapBack_skippedWhilePairUnsynced`、`test_swapBack_dustDonationDoesNotSkip` |
| B-F3 | 低 | `previewSell` 按当前区块算，钱包交易落在下一区块，实际到手比预览少约 1%，拿预览当最低到手会失败 | 新增 `previewSellNextBlock(token, amountIn)`（按新区块的满额度、当前储备算），前端 / CLI 用它算最低到手 | `audit5b`：`test_F3_previewSellNextBlockMatchesTheNextBlock` |
| C-F1 | 中（部署） | 旧手册第二个脚本只传两个共用合约地址，脚本悄悄另建一套分红 / 迁移 / 部署合约，所有检查照过；「本平台发的币不能当报价币」随之失效 | 五个共用合约地址要么全传要么全不传（否则 `PartialShared`）；复用时必须给 `PEER_CORE`（第一个核心），并核对它挂在同一套分红 / 迁移 / 部署合约上 | `audit5c`：`test_fork_deploy_partialSharedEnvRefused`、`test_fork_deploy_shared_refusesCrossCoreQuote` |
| C-F2 | 中（热钱包） | keeper 经 `collectPlatformSmart` 自拼路由，把回购那 80% 换给自己（PoC：8 WBNB 手续费变成 keeper 手里 5,927 USDT） | 新的 `src/common/SharedPlatformFeeBucket.sol`：V2 版去掉 `collectPlatformSmart`，只保留固定路径的 `collectPlatform`；`notifyAccrual` 按到账额记账；两个核心、两个处理合约和部署脚本改用它（V2 源码不动） | `audit5c`：`test_fork_keeperCanNoLongerStealBuybackLeg` |
| C-F4 | 低（owner） | 分红合约 owner 把 V3 门槛调得很高，新发的 V3 分红币没人有份额，持有人那份税全部流走 | V3 `create` 在核心门槛 > `TAXED_MIN_SHARE` 时回滚 `VaultFloorTooHigh`（打新原本就有） | `audit5c`：`test_audit5c_v3FloorAboveMaxRefusesCreate`；`SharedInfra.t.sol`：`test_shared_floorsArePerCore` |
| C-F5 | 低（owner） | `setExcluded` 没有限制，可以排除所有持有人只留指定钱包 | 只能排除有代码的地址（`NotAContract`），取消排除不受限 | `audit5c`：`test_audit5c_excludeOnlyContracts` |
| C-F7 | 低 / Info | 外盘按交易前的份额记账，卖家拿回自己这笔卖出税里属于持有人的部分（A-6 在外盘反过来了） | 卖出（`to == pair`）时，处理合约先把卖家份额同步成卖出后的持仓，再给持有人记账（V3 和打新都是）；买家本来就分不到自己这笔买入税 | `SwapBack.t.sol`：`test_dividends_creditedAtTaxTime`；`FairMint.t.sol`：`test_rewards_processSplitsHalfToEligibleHolders` |
| C-F8 | Info（脚本） | 路由脚本 V3_PAD / FAIR_PAD 填反查不出；没核对 pendingOwner、回购合约、金库；第二次运行换了 OWNER 会覆盖 pendingOwner | 路由脚本按各自独有的 getter 核对核心类型；`_check` 核对每个合约 owner 或 pendingOwner 是 OWNER、手续费池的回购合约和金库（主网默认等于 V2 手续费池的，可用 BURNER / FEE_VAULT 覆盖）；已有 pendingOwner 且不是这次的 OWNER 时回滚 `PendingOwnerMismatch` | `audit5c`：`test_fork_routerScript_swappedCoresRefused`、`test_fork_deploy_sharedSequence`、`test_fork_deploy_checksCatch` |
| C-F10 | Info | 注释过时（FOT 报价币、「退款」、DividendVault）；HolderRewardHandler 在 `setPad` 之前会接受未登记币的 `notifyTax` | 注释改正；`notifyTax` / `syncShares` / `swapBack` 要求 pad 已设置 | 现有测试覆盖 |

**没改、按已知风险记录的**

- C-F3：参考池现价可被闪电贷拉偏（R2-1）按产品决定接受；另外，一个带回调的报价币可以在迁移时抢先往池子 mint LP，触发 `PairHasLiquidity`，这个币就永远毕业 / 发射不了。影响只在这一个币上，用户仍可卖出或卖回。
- C-F9：已毕业的 V2 发射币仍能当报价币，我们的核心、分红合约、手续费池会收到那个币的 V2 分红但不会转出。没有低成本的识别方式（V2 币分散在三代发射台、每天还在新增，要识别就得给两个核心加构造参数或加 owner 名单）；影响只是这些 V2 分红留在我们的合约里，不碰用户资金，且 V2 分红按用户决定不再处理。
- C-F2 的其余部分：新手续费池接的回购合约仍是 V2 的（owner 是普通钱包），金库地址也是普通钱包。用户决定这次只关自定义路由。
- C-F8 (d)：多签 `acceptOwnership` 之前，部署热钱包仍握有 9 个合约的全部 owner 权限（Ownable2Step 的固有性质），运行手册要求部署完立即接收。
- A Info：每块里持有人的单位向上取整（最多偏向持有人 1 wei / 块，分红合约始终够付）；一批税要全部卖完才兑现，长时间只有买单时持有人的待兑现会等。
- B I2：Pancake `addLiquidityETH` 先转代币，会触发一块换币，加流动性的人少拿约 0.5% 的 LP。

**对外接口变化**（服务端 / CLI / 网站）

- 处理合约：去掉 `lastSwapBackBlock(token)`；新增 `windowOf(token)` → `(blockNumber, used)`、`refOf(token)` → `(refT, refQ)`、`previewSellNextBlock(token, amountIn)`、`proposeKeeper` / `acceptKeeper` / `cancelKeeper`、`pendingKeeper`、`keeperEta`、常量 `KEEPER_DELAY`、`MAX_PRICE_DROP_BPS`；错误 `PriceBelowReference`、`KeeperAlreadySet`；`maxChunk(token)` 现在返回本区块额度内还能卖多少（额度用完返回 0）。
- `process`：同一区块额度用完回滚 `ZeroAmount`，价格比区块参考价低 2% 以上回滚 `PriceBelowReference`——keeper 遇到这两个应停下、等下一个区块，不当作故障。
- 手续费池：`SharedPlatformFeeBucket`，没有 `collectPlatformSmart`；`setKeeper` 只能设一次，之后时间锁。
- 分红合约：`setExcluded(account, true)` 对没有代码的地址回滚 `NotAContract`。
- V3 核心：新错误 `VaultFloorTooHigh`。
- 部署脚本：复用时五个共用合约地址必须全给，外加 `PEER_CORE`；新错误 `PartialShared`、`PendingOwnerMismatch`；可选 `BURNER` / `FEE_VAULT` 覆盖。

**结果**：`forge test` 593 个通过（含 `test/audit5/` 的回归，审计回归套件继承基础套件会再跑一遍基础用例）；主网分叉（48.club）`test/fork/*` 12 个通过，`--match-contract Fork` 31 个里 26 个一次通过，其余 5 个中 4 个单独重跑通过（节点偶发 `not supported`），`V2E2E.test_e2e_nvdab_taxed_v3ref` 在改动前的 `ddce6b6` 上同样失败（V2 代码、依赖当前链上状态，与本轮无关）；invariant：`CoreInvariants` 9 条与 `audit5a/VaultUnitsInvariant` 3 条在 200 × 80 下全过（各 200 runs × 80 depth、16,000 次调用）；两个部署脚本在 BSC 测试网与主网（带 OWNER、链接线上 PoolCheck）不广播模拟通过，链式复用由 `audit5c/DeployScriptsFork.t.sol` 覆盖。运行时字节码：TaxHandlerV3 20,465 B，TokenDeployer 20,044 B，LaunchpadV3 18,819 B，FairMintPad 16,803 B，HolderRewardHandler 16,474 B，SharedDividendVault 9,588 B，SharedPlatformFeeBucket 4,299 B，TaxLaunchTokenV3 4,309 B，FairToken 4,209 B，SharedMigrator 2,001 B，GangRouter 4,135 B，都 < 24,576 B。一笔带换币的路由卖出约 65.7 万 gas（之前 61 万：多了区块额度 / 参考价两个存储位和卖家同步），不带换币约 33 万。
