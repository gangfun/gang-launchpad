# 审计说明 · 打新（FairMintPad）、LaunchpadV3 税收接收地址、GangRouter

- 日期：2026-10-26 Asia/Shanghai，2026-10-27 按合并后的合约重写 §1–§9；§19 记 V3 内盘不收税，§20 记把两个核心合并成一个内盘（GangLaunchpad）的改动，§1–§9 仍按合并前的两个核心写，以 §20 为准
- 读者：外部审计方
- **2026-10-27 晚 §21：GangRouter 改为可升级（TransparentUpgradeableProxy + 48 小时 TimelockController，Safe 是唯一的提案 / 执行 / 取消者）并新增 Pancake V2 外盘买卖入口**。分支 `feat/upgradeable-router`，改动列在 §21；§4.1 里 GangRouter「无 owner」一行以 §21 为准。
- **2026-10-27 下午 §19：V3 内盘不收税**（内盘只收 1% 手续费，税只在外盘收；内盘分红路径随之删除，分红合约只剩外盘分红）。分支 `feat/v3-no-curve-tax`，改动列在 §19。
- 代码：`gangfun/gang-launchpad`，分支 `feat/swapback`，合约冻结在 §18 的修复提交（父提交 `4857118`；`98cab5c` 之后到 `4857118` 没有改动 `src/`）：含 §10、§11 两轮内部审计的修复，§12 的代币收紧与元数据 URI，§13 的外盘税合约加固，§14 的打新去掉截止时间与第三轮内部审计，§15 的合约合并（方案 A）与第四轮内部审计，§16 的外盘税改为卖出时自动小额换 + 按税产生时记账，§17 的第五轮内部审计修复，§18 对第五轮修复的 review。之前的冻结点依次是 `5854a35`、`36d8a7e`、`47a063b`、`cf96281`、`a15b704`、`13da13b`、`1bcc84f`、`ddce6b6`、`98cab5c`。此后若有提交改动 `src/`，我们会单独列出 diff。§10–§14 是当时的记录，里面提到的 TaxRouterV3、RecipientRegistry、PostGradTaxHandlerV3、每个核心一份的 DividendVault / MigratorV2、「keeper 一次卖光」都已被 §15、§16 取代。
- 链：BNB Chain（chainId 56），DEX 为 PancakeSwap V2。目前只部署在 BSC 测试网，部署脚本在审计前拒绝主网广播。
- 工具链：Foundry 1.8.6，Solidity 0.8.28，EVM cancun，optimizer 200 runs；OpenZeppelin 5.1.0。范围内的目录都用 via-ir 编译（`foundry.toml` 的 `compilation_restrictions`，含 `src/common`）。

---

## 1. 背景

gang.fun 是 BNB Chain 上的发币平台，内盘只对持有 .ai Agent ID（SPACE ID 发行的灵魂绑定 ERC-721）的钱包开放。主网在运行的是 LaunchpadV2（`src/launchpad-v2/`），已经过外部审计，不在本次范围内。

本次送审三块新合约：

| 模块 | 一句话 |
|---|---|
| 打新 FairMintPad | 没有价格曲线：所有人按同一价格一份一份打，打满 10,000 份就把 50% 代币和全部募集款加进 Pancake 池子开盘；没有截止时间和退款，打满前随时按同一价格卖回（扣撤出费，sale 7 天没有进展时免）。开盘后每笔池子交易收 1% 税，一半分给「打新时进来、而且一直没卖到出局线以下」的地址，一半给平台。 |
| LaunchpadV3 | 在 V2 曲线（Agent 专属、单地址 1% 上限、约 15 BNB 毕业）的基础上，发币时可设买 / 卖税（各 1%–5%）和一个白名单里的税收接收地址（合作方金库）。税只在毕业后的池子里收（§19：内盘和 V2 一样只收 1% 手续费，不收税）；平台从税里固定拿成交额的 0.5%，剩下按设定比例分给持币人和接收地址，接收地址收报价币。 |
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
| `src/launchpad-v3/TaxHandlerV3.sol` | 255 | 接收地址白名单、每个币的路由、外盘分账（§19 起没有内盘分账）、欠款与 `release`、外盘税（§15 合并自三个旧合约） |
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
内盘买入：quoteIn → 1% 平台手续费（→ PlatformFeeBucket）→ 剩余 99% 进曲线；不收税（§19），有分红的币同步买家份额
内盘卖出：曲线付出 quoteOut → 1% 平台手续费 → 其余给卖家；不收税，有分红的币同步卖家份额
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
- 内盘不收税（§19），只按成交后的余额写份额，毕业后外盘交税时按这些份额记账。外盘按交易前的份额记账：卖家拿不回自己的卖出税，买家分不到自己的买入税。
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
| HolderRewardHandler | `setPad`（一次性）、`setKeeper`（合约一生只能调一次，之后 `proposeKeeper` → 48 小时 → `acceptKeeper`）、`proposeDexRouter` → 48 小时 → `acceptDexRouter` / `cancelDexRouter`；可代替 keeper 调 `process` | `process(token, amount, minQuoteOut)`（每次 ≤ `maxChunk`） | 代币：`notifyTax`、`swapBack` | `syncShares`、`flushHolders`、`flushPlatform` |
| LaunchpadV3 | `setMigrator`（一次性，迁移合约须把本核心列入）、`setPairFactory`（只用于创建时的参考池定价）、`setRouter`、`setAgentGate`、`setWalletCapEnabled`、`setV3Factory`、`setTwapWindow`、`setBridgePool` | — | 白名单路由：`buyFor`（只在准入开启时） | create、buy、sell |
| TaxLaunchTokenV3 / LaunchTokenV3 | — | — | 只有发射台：`unlock(migrator)`（一次）、`setPair`（有税币，解锁后一次）；之后没有任何管理函数 | 转账（毕业后）、`contractURI` / `metaURI` |
| TaxHandlerV3 | `setLaunchpad`（一次性）、`list` / `delist`（接收地址白名单）、keeper 与换币路由时间锁（同上）；可代替 keeper 调 `process` | `process(token, amount, minQuoteOut)` | 发射台：`register`（每个币一次）、`distribute`（只能付钱进来）；代币：`notifyTax`、`swapBack` | `release`、`syncShares`、`flushHolders`、`flushPlatform` |
| SharedDividendVault | `setLaunchpad(core, bool)`（移除只停新登记）、`setOperator(account, core)`（每个核心、每个地址只能绑定一次，不能解绑 / 更换）、`setExcluded`、`setMinimumShareBalance`（只影响之后登记的币） | — | 登记它的核心 / 绑定到该核心的 operator：`registerToken`（每个币一次）、`setShare`、`accrueDividendUnits`、`convertDividend` | `claim`、`claimFor` |
| SharedMigrator | `addLaunchpad`（只加不减） | — | 名单里的核心：`migrate` | — |
| TokenDeployer | `setLaunchpad(core, bool)` | — | 名单里的核心：`deployPlain` / `deployTax` / `deployFair` | `isLaunchToken` 查询 |
| SharedPlatformFeeBucket（共用一份新实例） | `setLaunchpad`、`setOperator`、`setFeeVault`、`setBurner`、`setKeeper`（合约一生只能调一次，之后 48 小时时间锁）、`requestFlush` + 7 天后 `flushStuckQuoteToTreasury` | `collectPlatform`（固定路径：80% 回购销毁 / 20% 金库；没有 `collectPlatformSmart`） | operator：`notifyAccrual`（按到账额记账） | — |
| QuoteRegistry（复用代码，共用一份新实例） | `setQuote`：给报价币设固定换算额（15 BNB 合多少该币），设了就优先于参考池；只影响之后创建的币。不再决定哪些币能用 | — | — | 查询 |
| GangRouter | 无（§21 起是代理：升级权在 48 小时时间锁，时间锁只听 Safe） | — | — | 全部函数 |

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
4. **keeper 被信任设 `minQuoteOut` 和 `minGangOut`**：它可以给一个很低的值然后自己夹，损失的是这一块的价值（≤ 池子代币储备 0.5%）。`process` 拒绝 `minQuoteOut == 0`。`swapBack` 的最低成交额由合约按同一调用里的储备算（下限 1%）。手续费池 `collectPlatform` 的回购最低成交额 `minGangOut` 也由 keeper 给，合约不设下限（K-20）。keeper 的 48 小时时间锁约束的是**换 keeper**，不约束 owner：owner 本来就能直接调 `process` / `collectPlatform`。
5. **发射台只能付钱进 TaxHandlerV3**：`distribute` 从 `msg.sender`（只能是发射台）拉 `amount`，再按登记的路由拆分。（§19 起 `distribute` 已删，发射台不再付钱给 handler；这一条只对 §19 之前的代码成立。）

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
8. 每笔内盘交易（§19）：只收成交额的 1% 进 PlatformFeeBucket，接收地址、分红合约、TaxHandlerV3 都收不到任何报价币（税率多少都一样）。外盘每笔税：平台部分 = 成交额 × 0.5%（税率不对称时也一样），平台 + 分红 + 接收地址 = 税。
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
| K-10 | **V3 的分红部分在没有合格持有人时并入接收地址**（只在外盘，内盘不收税，§19）；打新发射后的分红部分在没有合格持有人时并入平台。两者不同是因为 V3 里剩余的税本来就归接收地址。 |
| K-11 | **路由不提供 sweep**：误转进 GangRouter 的代币 / 报价币会永远留在那里。 |
| K-12 | **报价币不设白名单**：任意 18 位 ERC-20 都能做报价币；转账扣费的（入口与扣款时校验）和本平台发射的币（`isLaunchToken` / 已登记分红）被拒。会暂停、会拉黑、负 rebase 的报价币仍能进来：发行方暂停或拉黑核心 / handler / 分红合约 / bucket 时，用这个报价币的币可能无法交易、毕业或领取，打新本金可能取不出来。影响限于用这个报价币的币；网站和 CLI 只主推 WBNB / USDT。已毕业的 V2 发射币仍能做报价币（分红走 V2 的分红合约，影响很小）。 |
| K-13 | **非官方池子也会累计 V3 分红份额**（迁移合约、分红合约、bucket 已排除）：只有官方池子被设为 0。别人另建的交易对持有代币就有份额，任何人都能用 `claimFor` 把分红推进去。运维：发现这类池子后，owner 在分红合约排除它，并在同一批交易里 `handler.syncShares(token, pool, 0)`。打新不受影响：非打新地址的基准为 0。 |
| K-14 | **接收地址永久收不了款时，欠款会一直留在 TaxHandlerV3**：例如合作方金库被 USDT 拉黑。接收地址发币后不可改是产品承诺，没有改向出口。 |
| K-15 | **外盘税分块卖出**：每个币每区块一个额度（区块内第一次尝试时池子代币储备的 0.5%），`swapBack` 和 keeper 共用，按卖出数量扣；`swapBack` 另外 ≤ 卖单的 25%；价格比区块参考价（区块内第一次尝试时的储备）低 2% 以上就不卖（`swapBack` 跳过、`process` 回滚 `PriceBelowReference`）。一块仍可被夹，攻击者最多拿走约「2% × 这一块的卖出所得」；跨区块压价需要扛过一个区块的套利，且每块只有额度的量。keeper 补位时 `minQuoteOut` 容忍度 1.5%，建议经私有 RPC 发交易。只有买单的拉盘期里积压会增长，keeper 每 10 分钟每个币最多卖 20 块。`dexRouter` 只支持 Router02 的 fee-on-transfer 直连路径。 |
| K-16 | **毕业前卖出要求卖家当时仍持有 Agent ID**（与 V2 一致）。 |
| K-17 | **卖单前先卖一块会改变储备**：链下按旧储备预先算好输出、直接对池子先转账再 `swap` 的路由会失败；Pancake 的 `…SupportingFeeOnTransferTokens` 接口没问题（有税币本来也只能走它）。前端和 CLI 用 `previewSell` 报价。 |
| K-18 | **卖出 gas 变高**：一笔带一块的卖出约 57–60 万 gas（原 27.6 万），见 §16。 |
| K-19 | **持有人的分红要等这一批卖完才能领**：交税时就记了单位，但一批没卖完前它不会变成可领金额；长时间只有买单时早期持有人要等 keeper 把这批卖完。 |
| K-20 | **回购的最低成交额由 keeper 给**（§17 C-F2 的残留，用户决定这次只关自定义路由）：`collectPlatform(quote, minGangOut)` 的 `minGangOut` 合约不设下限，keeper 可以填一个很小的值；keeper 热钱包被盗时，攻击者能在 `collectPlatform` 前后夹这一笔回购（80% 那部分），拿走的是这次回购的滑点。路径固定（回购合约的路由），钱不能被换到攻击者地址。缓解：keeper 按链上报价设 `minGangOut`、经私有 RPC 发交易；发现被盗后多签 `proposeKeeper` 换人，期间 owner 可以自己 `collectPlatform`。 |
| K-21 | **闪电兑换写法的卖出被拒**（§18）：在 Pancake `pancakeCall` 回调里把税币付进池子的卖出（先取走报价币、后付代币）整笔回滚 `SellDuringFlashSwap`，不管这一刻有没有要卖的税。用这种写法的套利合约不能卖有税的 V3 / 打新币；经 Router02 的卖出、多跳路径、加流动性不受影响。只有「报价币余额低于储备」算闪电兑换：余额**高于**储备（加到一半的流动性、捐款）不回滚也不跳过，`swapBack` 把多出的部分先收走、卖完这一块再原样退回（§18 R5-O1）。会负 rebase 的报价币如果让池子的报价币余额低于储备，在有人 `sync` 之前所有收税的卖出都会回滚（K-12 的一种）。 |

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
forge test                    # §18：641 个通过（审计回归套件继承基础套件，基础用例会再跑一遍；不设 BSC_RPC_URL 时分叉用例直接返回）
BSC_RPC_URL=https://rpc-bsc.48.club forge test --match-contract Fork   # 主网分叉（publicnode 会丢历史状态）
BSC_RPC_URL=https://rpc-bsc.48.club forge test --match-path 'test/fork/*'   # 12 个
BSC_RPC_URL=https://rpc-bsc.48.club forge test --match-path 'test/audit5/**' --threads 1   # 150 个（部署脚本测试改进程环境变量，要单线程）
```

| 测试文件 | 个数 | 覆盖 |
|---|---|---|
| `test/fair-mint/FairMint.t.sol` | 33 | 参数上下限、报价币换算、上限与最后一笔截断、卖回、打新费当笔进平台、7 天免撤出费、没有截止时间、本金托管恰好等于持仓、发射价格、池子被提前建好、奖励权重 / 出局 / 上限、分账、权限、G-01 |
| `test/fair-mint/FairMintAudit.t.sol` | 41（含继承） | 第一、三轮内部审计回归：路由入口须开准入、卖回不依赖分红合约 / bucket、计时要净增份数才重启、报价币规则、migrator 绑定检查、收币方卡 gas 不能留下过期份额 |
| `test/fair-mint/FairSwapBack.t.sol` | 43（含继承） | 打新的卖出时自动换、每区块额度、零头不触发、失败不影响卖出、只认本核心的币、`previewSell`、按交税时记账、bucket / 分红合约拒收、按估算 gas 执行 |
| `test/fair-mint/FlowReviewFixes.t.sol` | 37（含继承） | F3 `minPayout`、F4a operator 只能绑一次、F4c 门槛按币快照、F4b 换币路由时间锁 |
| `test/fair-mint/FairTokenAdmin.t.sol` | 35（含继承） | 代币收紧与元数据 URI（§12） |
| `test/launchpad-v3/LaunchpadV3.t.sol` | 14 | 创建规则、下架只拦新币、内盘只收 1% 不收税（买 / 卖、有税币与无税币同价、一路到毕业的对账，§19）、推送失败记欠款 / 补发（外盘）、外盘按每笔方向记账与分账、无税币、门槛与上限、G-01、权限 |
| `test/launchpad-v3/LaunchpadV3Audit.t.sol` | 24（含继承） | 内部审计回归：`buyFor` 须开准入、报价币规则、migrator 绑定、卖家拿不回自己的卖出税、伪造代币收税、pair 报价核对、欠款不会被 `process` 卖掉 |
| `test/launchpad-v3/SwapBack.t.sol` | 36（含继承） | V3 卖出时自动换：每区块额度、≤ 卖单 25%、零头不触发、池子里未同步的报价币 / 代币在这一块前后收走再原样退回（§18，etch 一个带 `skim` 的 MockPair）、没有 `skim` 的交易对不影响卖出、1 wei 捐款 + 零头卖单不占额度、`previewSell`、冲击上限、只认代币、失败不影响卖出、按估算 gas 执行、keeper 分块卖完只有买单的积压、按交税时记账、bucket / 分红合约拒收、写份额被拒 |
| `test/launchpad-v3/LaunchpadV3Fuzz.t.sol` | 17（含继承） | fuzz（各 1000 轮）：每笔买 / 卖恰好拆成曲线和 1% 手续费，接收地址 / 分红合约 / handler 收不到报价币（§19） |
| `test/launchpad-v3/TokenAdmin.t.sol` | 17（含继承） | 代币收紧与元数据 URI（§12） |
| `test/common/TaxTimeDividends.t.sol` | 6 | 按交税时记账：归属交税时的持有人、两批先进先出、隔很多批才动的持有人、只认核心 / 其 operator、超卖被拒；含与逐批暴力模型对照的 fuzz（1000 轮） |
| `test/common/SharedInfra.t.sol` | 25（含继承） | 两个核心共用一套、各自毕业 / 发射分红不串、跨核心写入被拒、只认名单里的调用方、移除核心后已有币照常、门槛按核心 |
| `test/audit4/Audit4Regression.t.sol` | 27 + 19（含继承） | 第四轮内部审计回归（§15） |
| `test/router/GangRouter.t.sol` | 19 | BNB / 报价币两种路径、交易者拿币、门槛和上限按交易者、分红权重归交易者、截断退款、经路由毕业 / 发射、只有白名单路由能代买、流氓路由只能花自己的钱 |
| `test/invariant/CoreInvariants.t.sol` | 10 条不变量（§19 新增 `invariant_v3CurveNoTax`） | V3、打新、共用合约、GangRouter 放在一起随机操作（发币、直接 / 经路由买卖、打新、卖回、跳时间、打满、毕业、池子交易、keeper 分块处理、拉黑接收地址、补发、领取），每步后检查 §5 的不变量。CI 跑 24 × 50；`6b5e03f` 上压力跑 200 轮 × 80 步全过 |
| `test/audit5/review/` | 8 + 15 + 2 + 4（分叉用例另含继承的基础用例） | §18 review 的回归：keeper 只能 `setKeeper` 一次、EIP-7702 委托钱包不能排除（`ReviewUnit`）；闪电兑换写法的卖出被拒、零头 + 1 wei 不再占额度、未同步的余额收走再退回、捐款当场拿回也跳不过这一块（R5-O1）、有未同步余额时的 gas 扫描、Router02 普通卖出 / 多跳 / `addLiquidity` 两种顺序与 `addLiquidityETH` 各 5 种金额（`ReviewFork`，真实 Pancake）；打新币的闪电兑换卖出与未同步余额（`ReviewFairFork`）；部署脚本核对 `PEER_CORE` 的报价币登记合约和手续费池、`BURNER` / `FEE_VAULT` 部署时生效（`DeployReview`，`--threads 1`） |
| 主网分叉 | 25 + 12 | 真实 Pancake：打新整轮、USDT 按参考池换算、提前建池；V3 卖出时自动换（`V3SwapBackFork.t.sol`：`previewSell` 与实际到账一致、一块用完本区块额度、1 wei 不触发、单块冲击 ≤ 约 1%、估算 gas 下这一块会执行）；报价币按 V2 / V3 参考池换算与 LaunchpadV2 同口径（`QuoteRefPoolFork.t.sol`） |

另外：

- 本地 anvil（BSC 测试网 fork）上用 `ddce6b6` 之前的 `6b5e03f` 部署脚本部署过整套，keeper（gangfun-server `feat/keeper-ops`）实测：只填核心地址就自动接线；只有买单时 V3 8 块、打新 3 块卖完，每块约池子代币储备 0.5%、冲击约 0.75%；分红合约和 bucket 同时拒收时这一块照常卖出、恢复后 keeper 自动补兑现补交；真实卖出时 `previewSell` 与实际到账相差 0.05%。
- 运行时字节码（§18 的修复提交，`forge build --sizes` 实测）：TaxHandlerV3 21,130 B，TokenDeployer 20,688 B，LaunchpadV3 18,819 B，HolderRewardHandler 18,041 B，FairMintPad 16,803 B，SharedDividendVault 9,799 B，TaxLaunchTokenV3 4,472 B，FairToken 4,372 B，SharedPlatformFeeBucket 4,365 B，GangRouter 4,135 B，SharedMigrator 2,001 B，都 < 24,576 B（最大的 TaxHandlerV3 余 3,446 B）。`98cab5c` 实测：TaxHandlerV3 20,508 B（§17 原写 20,465 B 有误），其余与 §17 所列一致。

**测试的不足**：invariant 测试用的是仓库里简化的 MockPair（不检查 K、不收 0.25% 手续费）；池子相关的经济攻击（夹子、闪电贷）由第二轮审计员用仿真的 Pancake V2 池子验证过（§11），卖出时自动换在真实 Pancake 上有分叉测试，但没有系统的 MEV 仿真。

---

## 8. 希望重点看的地方

1. **按税产生时记账**（`SharedDividendVault`）：两批先进先出的状态转换（`open` → `selling`、一批没卖完时又有新税）、持有人跨很多批次后的结算、1e36 放大与 `uint128` 打包的取整与溢出、可领 + 未结算是否始终有足额支撑、交税前后买卖的归属。
2. **卖出时自动换**：每区块额度与区块参考价、`swapBack` 失败与 `SwapBackOutOfGas` 的边界（gas 估算是否总包含这一块）、池子余额与储备的同步判断、`previewSell` 的准确性、和 Pancake Router02 各种接口（含加 / 减流动性）的兼容、能否被夹、能否用零头卖单或捐款耗掉 / 绕开额度（§17）。
3. **共用合约的隔离**：两个核心、两个 handler、各自 operator 之间能否互相写份额 / 存奖励 / 登记代币；同一报价币的不同币之间的资金隔离。
4. **任意报价币**：会回调、会暂停 / 拉黑、负 rebase、`decimals` 会变的报价币对核心、handler、分红合约、bucket、迁移合约的影响；参考池换算（K-1 已接受的部分之外）。
5. **FairMintPad 的记账**：多个 sale 共用同一个报价币时的隔离（§5 #1，含 `owedFee`）；卖回取整；7 天计时边界和 `markSold`；`minPayout`。
6. **最后一笔打满即发射**：`_mint` 里在同一笔交易中调用 `_launch` → SharedMigrator → Pancake。有没有办法让发射失败从而卡住 sale，或者在建池时重入。
7. **LaunchpadV3 的费用计算**：`_prepBuy` / `_applyFee` / `_recomputeFee` 在单地址上限或毕业截断时重新算 1% 手续费和退款（§19 起内盘没有税）。
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

- **卖出时自动换（`swapBack`）**：一笔收了税的卖单进池子前（池子未锁），代币调 `handler.swapBack(token, sellAmount)`，处理合约把攒下的税卖一块直接进池子，按同一调用里的储备计价（下限 1%）。单块 ≤ 池子代币侧 0.5%（`CHUNK_MAX_BPS = 50`）且 ≤ 这笔卖单的 25%（`SWAP_BACK_SELL_BPS = 2500`）；每个币每个区块最多一次（`lastSwapBackBlock`）；这笔转账不产生税（零头、被排除地址）时不触发；池子余额与储备不一致（有人加流动性到一半）时跳过（§18 改为先收走、卖完再退回）。买入时池子已锁，只累计；钱包间转账不触发。
- **失败不影响交易**：这一块自己失败被吞掉、代币发 `SwapBackFailed`；只有「调用方给的 gas 不够导致这一块耗尽」时整笔回滚（`SwapBackOutOfGas`），这样 `eth_estimateGas` 二分出的 gas 一定包含这一块（之前「gas 不够就跳过」会让钱包按估算发的交易永远跳过这一块）。
- **keeper 补位**：`process(token, amount, minQuoteOut)`，数量截到 `maxChunk(token)`（只会少卖），同一区块可多次（§17 起改为每个币每区块一个额度，见 V3 D）；只有买单时 keeper 分块卖完。`previewSell(token, amountIn)` 返回卖单含这一块之后实际能拿到的报价币。
- **按税产生时记账**（`SharedDividendVault`）：持有人那份在 `notifyTax` 当场按当时份额记成税币单位（`accrueDividendUnits`）；卖出后按这一批实际换回的报价币兑现（`convertDividend`）。分批先进先出，同一个币最多两批未结算（`open` 在攒、`selling` 在卖），一批卖完才按它的报价币结算；每个持有人最多记两批未结算单位，跨很多已结算批次用累计指数一步算完；放大系数 1e36，单位字段两个 `uint128` 打包；取整一律向下。选分批先进先出而不选 Liquity 稳定池式的 epoch / scale：每卖一块几乎都会把一整批卖完，只需一个累计指数，状态少、好审计。两个 handler 共用同一套（打新仍是 `min(持仓, 打到的数量)` + 出局线，V3 仍是持仓 + 门槛）。
- **下游拒收不卡住**：分红合约拒绝兑现时这批单位和报价币留在 handler（`pendingHolderUnits` / `pendingHolderQuote`，`HolderConversionDeferred`），下一块或任何人 `flushHolders` 补兑现；bucket 拒收时平台那份记 `owedPlatformOf`（`PlatformOwed`），任何人 `flushPlatform` 补交；分红合约拒绝记账时那份归接收地址 / 平台；V3 写份额也改为带保护（`ShareWriteFailed`）。

**两路流程审查对新代码的设计意见及处理**

| 来源 | 意见 | 处理 |
|---|---|---|
| 打新 D1（高） | 上限是「每次调用」：往池子转 1 wei 再 `skim` 就触发一整块，可循环，一笔交易砸光积压并夹子 | 每区块一次；单块 ≤ 这笔卖单的 25%；不产生税的转账不触发 |
| V3 A（严重） | 「剩余 gas 不到 65 万就跳过」会让 gas 估算落在跳过这一块的路径上，真实使用中几乎从不执行 | 改为 gas 不够整笔回滚（`SwapBackOutOfGas`）；测试用二分法模拟 `eth_estimateGas`，在估出的最低 gas 下这一块会执行（V3 一笔卖出转账约 41–48 万 gas） |
| 打新 D2 | 换币会吞掉池子里未同步的余额（加流动性到一半的人会失败或亏） | 余额与储备不一致时跳过（§18 改为：先 skim 收走、卖完这一块再原样退回，不再跳过） |
| 打新 D3 / V3 B | 每个卖家前面先卖一块，链下预先算好的金额不含这块，滑点紧的单会失败 | 单块 ≤ 卖单 25%（卖 50 份时成交约为普通报价的 98.19%，已含 1% 卖出税）；新增 `previewSell` |
| 打新 D4 / F2 | bucket 拒收或兑现失败时整块失败，持有人那份被平台那份连累 | `owedPlatformOf` / `pendingHolder*` + `flushPlatform` / `flushHolders`，这一块照常完成 |
| 打新 D5 | 先记账再同步份额：卖家按卖出前份额分到自己这笔卖出的税 | 保留并写入注释（§3.2） |
| V3 C | V3 写份额没有保护（K-7）；兑现失败会让 `process` revert、keeper 卡住 | 写份额带保护；`process` 遇兑现失败也能继续 |
| V3 D | keeper 每次一块，10 分钟一次可能跟不上只有买单的拉盘 | keeper 每次运行对每个币循环到卖完或 20 块。（§16 当时合约允许同一区块多次 `process`；§17 B-F4 起每个币每区块只有一个额度，`swapBack` 和 `process` 共用，额度用完后同一区块的 `process` 回滚 `ZeroAmount`，所以 keeper 实际每个区块最多卖一块，20 块要跨 20 个区块） |

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
| B-F2 / A L-1b | 低到中 | 卖出前往池子转 1 wei 报价币，余额与储备对不上，这一块就被跳过（卖家多拿 0.96%、省约 30 万 gas）；还能「捐 1 wei → 先砸 → 后换」 | 只有多出的余额相当于这笔卖单价值一半以上（像加流动性加到一半）才跳过，并且跳过会用掉这一区块的额度；零头被吸收；余额低于储备（闪电兑换回调中）不卖；再加上区块参考价，先砸后换不成立 | `audit5b`：`test_F2_oneWeiQuoteDonationNoLongerSkipsChunk`；`audit5a`：`test_donationNoLongerLetsTheChunkRunAfterADump`；`SwapBack.t.sol`：`test_swapBack_skippedWhilePairUnsynced`、`test_swapBack_dustDonationDoesNotSkip`（这一处理在 §18 被 review 推翻并重做） |
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
- C-F9（产品决定：允许）：已毕业的 V2 发射币可以当报价币，按普通 18 位币处理。我们的核心、交易对、处理合约、分红合约、手续费池持有它时分到的 V2 分红领不出来，留在 V2 分红合约里；V2 分红已按用户决定不再处理，且不碰用户资金，所以不拦。没毕业的 V2 币没有 Pancake 池子，过不了参考池深度检查；带转账扣税的会被 `FeeOnTransferQuote` 拒绝。以后若恢复 V2 分红，可由多签在 V2 分红合约 `setExcluded` 排除这些合约，不用改新合约。
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

**结果**：`forge test` 593 个通过（含 `test/audit5/` 的回归，审计回归套件继承基础套件会再跑一遍基础用例）；主网分叉（48.club）`test/fork/*` 12 个通过，`--match-contract Fork` 31 个里 26 个一次通过，其余 5 个中 4 个单独重跑通过（节点偶发 `not supported`），`V2E2E.test_e2e_nvdab_taxed_v3ref` 在改动前的 `ddce6b6` 上同样失败（V2 代码、依赖当前链上状态，与本轮无关）；invariant：`CoreInvariants` 9 条与 `audit5a/VaultUnitsInvariant` 3 条在 200 × 80 下全过（各 200 runs × 80 depth、16,000 次调用）；两个部署脚本在 BSC 测试网与主网（带 OWNER、链接线上 PoolCheck）不广播模拟通过，链式复用由 `audit5c/DeployScriptsFork.t.sol` 覆盖。运行时字节码：TaxHandlerV3 20,508 B（原写 20,465 B，按实际编译改正，§18），TokenDeployer 20,044 B，LaunchpadV3 18,819 B，FairMintPad 16,803 B，HolderRewardHandler 16,474 B，SharedDividendVault 9,588 B，SharedPlatformFeeBucket 4,299 B，TaxLaunchTokenV3 4,309 B，FairToken 4,209 B，SharedMigrator 2,001 B，GangRouter 4,135 B，都 < 24,576 B。一笔带换币的路由卖出约 65.7 万 gas（之前 61 万：多了区块额度 / 参考价两个存储位和卖家同步），不带换币约 33 万。

---

## 18. 第五轮修复的 review（2026-10-27）

对 §17 修复（`98cab5c`，冻结点之后到 `4857118` 没有改动 `src/`）做了一轮 review，在主网分叉上给出了 PoC（`ReviewPoC` / `DeployPoC`）。第一版修复在 `b287577`；修完后又发现 R5-O1（B-F2 仍可绕过），按用户决定改为「先 skim、卖完转回」，在其后的提交里。PoC 改成回归测试放在 `test/audit5/review/`；review 给的 6 个 PoC 和 R5-O1 的 PoC 在修复后全部失败（被挡住）。

**发现与处理**

| 编号 | 级别 | 问题 | 处理 | 回归测试 |
|---|---|---|---|---|
| R5-1a（B-F2） | 低到中 | 闪电兑换写法的卖出：先从池子取走报价币，在 `pancakeCall` 回调里把税币付进池子。这时池子的报价币余额低于储备，`swapBack` 按「交易中途」跳过，这一块被白白跳过（PoC：卖家多拿约 0.96%，不花任何成本） | 卖出转账时池子的报价币余额低于储备就整笔回滚 `SellDuringFlashSwap`：处理合约的 `swapBack` 先检查并 revert，代币在 try/catch 里只把这一个错误原样抛出（其余失败照旧吞掉、发 `SwapBackFailed`），不管这一刻有没有要卖的税（不能择时绕过）。代币一侧余额低于储备（只借代币）仍然只是跳过：池子在回调里是锁着的，这种卖出拿不到报价币 | `ReviewFork`：`test_review_flashSwapSellRefused`、`test_review_flashSwapSellRefusedWithoutBacklog`；`ReviewFairFork`：`test_review_fair_flashSwapSellRefused` |
| R5-1b（B-F2） | 低到中 | 「池子有未同步的报价币」跳过时把本区块额度设成 `uint96.max`：1 wei 报价币 + 100 wei 代币的零头卖单就能让这个区块里所有卖单和 keeper 都不换（PoC `dustPlusOneWeiSpendsWholeBlock`），再接一笔真卖单就是白拿（PoC `BF2BypassViaSpend`） | 不再有「跳过」（见 R5-1c / R5-O1），也就不再动额度。区块内「先砸后换」由 2% 区块参考价兜住（§17 B-F4） | `ReviewFork`：`test_review_spendTrickNoLongerSkipsTheChunk`、`test_review_dustPlusOneWeiNoLongerSpendsTheBlock`、`test_review_keeperUnaffectedByDust`；`SwapBack.t.sol`：`test_swapBack_dustSellPlusOneWeiSpendsNothing` |
| R5-1c（B-F2） | 低 | 「多出的余额算不算有人在加流动性」和这笔卖单比：卖单越小越容易成立，零头卖单 + 1 wei 就算 | 第一版（`b287577`）改成和池子的报价币储备比、至少 0.1% 才跳过；这一版被 R5-O1 绕过，改为不再按多出的余额跳过（见 R5-O1），门槛 `LP_ADD_MIN_BPS` 去掉 | `SwapBack.t.sol`：`test_swapBack_unsyncedQuoteSetAsideAndReturned`、`test_swapBack_dustDonationDoesNotSkip`；`ReviewFork`：`test_review_unsyncedQuoteSetAsideAndReturned` |
| R5-O1（B-F2，review 之后发现） | 低到中 | 0.1% 的门槛挡得住零头，挡不住「当场拿回」的捐款：合约卖家先往池子转 ≥ 0.1% 储备的报价币（可闪电借来），再把税币直接转进池子（这一块被当成加流动性跳过），然后自己调 `pair.swap`，取出量里把那笔报价币一并取回（池子把它算作输入，只收 0.25%）。主网分叉实测：储备 45 BNB 的池子捐 0.045 BNB、成本约 0.0001 BNB，卖家比老实卖出多拿 96 bps | **已修**：不再按多出的余额跳过。`swapBack` 定好这一块之后，池子任何一边有多出的余额，就先 `pair.skim(handler)` 把两边多出的部分收到处理合约（按实际到账记），按储备卖这一块，再把收来的两边原样转回池子。处理合约对两种代币都是免税地址：收和退都不收税、不触发 `swapBack`；收着的这段时间里，这一块的数量在 skim 之前就定好了，`_sellChunk` 不读处理合约的余额（`accruedTax`、`_sellable`、`owedTotalOf`、待兑现 / 平台欠款都只按记账走），所以临时拿到的币不会被算成可卖的税或报价币。结果：卖家跳不过这一块（捐款拿回来也没用）；加到一半的流动性（两种顺序、任何金额）原样留在池子里，mint 拿到两边。「报价币余额低于储备」仍然回滚 `SellDuringFlashSwap`（R5-1a） | `ReviewFork`：`test_review_recoveredDonationNoLongerSkips`（PoC 改成的回归：卖家净到手 ≤ 老实卖出）、`test_review_unsyncedQuoteSetAsideAndReturned`、`test_review_unsyncedTokensSetAsideAndReturned`、`test_review_gasSweep_unsyncedQuote`；`ReviewFairFork`：`test_review_fair_unsyncedSetAsideAndReturned`；`SwapBack.t.sol`：`test_swapBack_unsyncedTokensSetAsideAndReturned` |
| R5-2（C-F5） | 低（owner） | EIP-7702 委托过的普通钱包有 23 字节的代码（`0xef0100` ‖ 地址），`setExcluded` 把它当合约放行，owner 又能排除普通钱包 | 代码恰好 23 字节且以 `0xef0100` 开头的按普通钱包处理，回滚 `NotAContract`（`0xef` 开头的代码不能被部署，EIP-3541，所以这个形状只可能是委托标记） | `ReviewUnit`：`test_review_eip7702DelegatedWalletCantBeExcluded`、`test_review_plainWalletStillRefused_contractsStillAllowed` |
| R5-3（C-F1） | 低（部署） | 复用共用合约时只核对了 `PEER_CORE` 挂在同一套分红 / 迁移 / 部署合约上，换一个 `QUOTE_REGISTRY` + `PLATFORM_BUCKET` 所有检查照过（PoC `peerCoreDoesNotPinRegistryAndBucket`） | `_checkCore` 再核对 `PEER_CORE.quoteRegistry() == QUOTE_REGISTRY`、`PEER_CORE.platformBucket() == PLATFORM_BUCKET`、`bucket.operators(PEER_CORE)` 为真 | `DeployReview`：`test_review_deploy_peerRegistryMismatchRefused`、`test_review_deploy_peerBucketMismatchRefused` |
| R5-4（C-F6） | 低（owner） | keeper 时间锁可以绕过：`setKeeper` 只在 `keeper == 0` 时可用，owner 先 `proposeKeeper(0)`，48 小时后 `acceptKeeper`，再 `setKeeper(任意地址)` 立即生效，观察者 48 小时里只看到「改成 0」 | 两个处理合约（基类）和 `SharedPlatformFeeBucket` 加 `keeperSet` 标记：`setKeeper` 一生只能调一次（设成 0 也算），`acceptKeeper` 也会置位；之后只能 `proposeKeeper` → 48 小时 → `acceptKeeper`。这个时间锁约束的是 keeper 的更换，不约束 owner：owner 本来就能直接 `process` / `collectPlatform` | `ReviewUnit`：`test_review_handlerKeeperZeroNoLongerReopensSetKeeper`、`test_review_handlerAcceptedKeeperClosesSetKeeper`、`test_review_handlerSetKeeperZeroUsesItUp`、`test_review_bucketKeeperZeroNoLongerReopensSetKeeper`、`test_review_bucketAcceptedKeeperClosesSetKeeper` |
| R5-5（C-F8） | Info（脚本） | `BURNER` 覆盖项只在检查里用，部署时总是接 V2 手续费池的回购合约，设了 `BURNER` 的部署会被自己的检查打回（PoC `burnerEnvNotHonouredByDeploy`） | 部署和检查共用 `_burner` / `_feeVault`：`BURNER` / `FEE_VAULT` 设了（非 0）就用它，否则主网用 V2 手续费池的；测试网只在设了 `BURNER` 时接回购合约并核对 | `DeployReview`：`test_review_deploy_burnerAndFeeVaultOverridesUsed`、`test_review_deploy_defaultsAndKeeperFlags` |
| R5-6 | Info（文档） | §16 的 V3 D 行写「合约允许同一区块多次 `process`」，与 §17 的每区块额度矛盾；§7 / §17 的 TaxHandlerV3 大小与实际编译不符（`98cab5c` 实际 20,508 B） | 改正，见 §16、§7 | — |

**不能破坏的路径**（真实 Pancake，`ReviewFork`）：Router02 的普通卖出（到手 = `previewSell`，这一块照常执行）；多跳卖出 `token → WBNB → USDT` 与买入 `USDT → WBNB → token`；`addLiquidity` 代币在前与报价币在前、`addLiquidityETH`，每种都按池子代币储备的 0.01% / 0.05% / 0.2% / 1% / 5% 各加一次。报价币在前时，代币的转账钩子看到池子里多出的报价币，先收走、卖完这一块再退回，mint 拿到两边——`b287577` 里「报价币在前、不到 0.1% 的小额加池会回滚」的限制已经没有了。每次加池都核对：LP 数量恰好等于 Pancake `mint` 按实际到账的两边算出的值（没有任何一边被吸收）；和「不收税、不卖块」的同一笔加池相比，只差两样：转进池子的代币被收了 3% 卖出税（只有这一项时为 97.03%），以及这一块先卖进池子、把代币储备抬高了最多 0.5%（实测：小额 97.03%，加池额 5% 时 96.55%）。三种加法的结果完全相同。

**已知风险（不改）**

- C-F2 的残留（K-20）：keeper 可以给 `collectPlatform` 的回购填很小的 `minGangOut`，热钱包被盗时这一笔回购可被夹。用户已决定这次只关自定义路由。
- 闪电兑换写法的卖出一律回滚（K-21）。
- 收走再退回的是池子里「多出的」余额，退回后仍是多出的：下一个调 `swap` 的人照 Pancake 的规则把它算作自己的输入（原来不 skim 时，它会被这一块吸收、归 LP）。这是 Pancake V2 对任何未同步余额的固有行为。
- 转账扣费的报价币（入口已拒收，K-12；发行方事后开启时）在收走、退回两次转账里各被扣一次，加到一半的流动性会少一点报价币。
- 不支持 `skim` 的交易对上，有多出余额时这一块会失败（被吞掉、发 `SwapBackFailed`，卖出照常）；官方交易对是 Pancake V2，有 `skim`。
- `process`（keeper）不做 skim：keeper 的交易单独成笔，不会和一笔加到一半的流动性同处一个交易；池子里的捐款照旧被 keeper 这一块吸收（直接对池子卖）或计入它的输入（经路由卖），只会对持有人有利。

**对外接口变化**（服务端 / CLI / 网站）

- 处理合约（TaxHandlerV3、HolderRewardHandler）：新错误 `SellDuringFlashSwap`；新 getter `keeperSet()`；`setKeeper` 在 `keeperSet` 后回滚 `KeeperAlreadySet`（包括 keeper 已被改成 0 的情况）。`b287577` 里的常量 `LP_ADD_MIN_BPS` 已去掉。`swapBack` 在池子有多出余额时调 `pair.skim(handler)`，并在同一调用里转回（链上会看到池子与处理合约之间成对的 `Transfer`）。
- 代币（TaxLaunchTokenV3、FairToken）：新错误 `SellDuringFlashSwap`（闪电兑换写法的卖出）。
- 手续费池 `SharedPlatformFeeBucket`：新 getter `keeperSet()`；`setKeeper` 同上。
- 分红合约：`setExcluded(EIP-7702 委托钱包, true)` 回滚 `NotAContract`。
- `windowOf` / `maxChunk` / `previewSell` / `previewSellNextBlock` 的签名不变；池子有未同步余额时不再跳过，`previewSell` 照常含这一块。
- 部署脚本：复用时 `PEER_CORE` 的报价币登记合约、手续费池必须和传入的一致（新的 `WiringCheck("peer core registry" / "peer core bucket" / "peer core on bucket")`）；`BURNER` / `FEE_VAULT` 在部署时就生效，填 0 等于不填。
- 服务端 keeper、CLI、网站：不需要改。keeper 只调 `process` / `collectPlatform`，错误处理不变；CLI 的报价用 `previewSellNextBlock` / `previewSell`，签名不变；网站不读这些字段。CLI 若要给出更清楚的报错，可以识别 `SellDuringFlashSwap`。索引器若按处理合约的 `Transfer` 统计税币流水，要忽略 `swapBack` 里与池子之间成对的收走 / 退回。

**结果**（skim 版）：`forge test` 645 个通过（不设 `BSC_RPC_URL`）；主网分叉（48.club）`test/fork/*` 12 个通过，`test/audit5/**`（`--threads 1`）153 个里 150 个一次通过，另 3 个都在 `ReviewFairForkTest`（继承的 `test_fork_usdt_raiseTracksBnbPrice` 与两条 `test_review_fair_*`），节点返回 `not supported`，单独重跑这个套件 7 个全过；review 的 6 个原始 PoC 全部失败（被挡住）；invariant：`CoreInvariants` 9 条与 `audit5a/VaultUnitsInvariant` 3 条在 200 × 80 下全过（各 200 runs、16,000 次调用）；两个部署脚本在 BSC 测试网与主网的本地分叉（anvil）上顺序跑通（第二个复用第一个的五个共用合约 + `PEER_CORE`；主网带 OWNER、链接线上 PoolCheck），没有往任何链广播。运行时字节码见 §7，都 < 24,576 B。

gas（主网分叉、真实 Pancake）：

| 情况 | `4857118` | `b287577`（门槛版） | skim 版 |
|---|---|---|---|
| 路由卖出带一块（`test_gas_typical`） | 656,956 | 658,102 | 658,231 |
| 路由卖出不带一块 | 329,553 | 330,795 | 330,803 |
| 直接转进池子带一块 | 387,083 | 388,229 | 388,358 |
| 路由买入 / keeper `process` | 296,766 / 313,790 | 296,788 / 313,856 | 296,788 / 313,856 |

池子有多出余额时（`test_review_gas_unsynced`，同一笔路由卖出、存储先 `vm.cool`、分红批次状态相同）：池子已同步 561,693；多出报价币（储备 0.1%）595,588（+33,895：一次 `skim` 和一次退回）；多出报价币和代币 606,681（+44,988）。有多出余额时，代币给 `swapBack` 的 60 万 gas 上限仍然够：gas 扫描里任何能成功的 gas 都会卖出这一块（直接转账最低 557,000，经路由 596,000）。

---

## 19. V3 内盘不收税（2026-10-27 用户决定）

**决定**：V3 税收币在内盘（联合曲线）买卖不收税，和 V2 一样只收 1% 手续费（`PROTOCOL_FEE_BPS`，全部进 SharedPlatformFeeBucket，80% 回购 / 20% 金库）。买卖税（1%–5%）只在毕业后的 Pancake 池子里收，外盘规则完全不变：平台拿成交额的 0.5%，剩下按分红比例分给持有人，其余给白名单接收地址；卖出时自动小额换；交税时记账；卖家分不到自己这笔卖出的税。

**为什么**：和 V2 有税轨保持一致，内盘价格对有税币和无税币一样，用户在内盘只认 1% 手续费；税是外盘（毕业后）的事。分支 `feat/v3-no-curve-tax`（基于 `main` `bad3142`）。

**改了什么**

| 合约 | 改动 |
|---|---|
| `LaunchpadV3` | `buy` / `buyFor` / `sell` 只扣 1% 手续费，不再算税、不再调 `TaxHandlerV3.distribute`。`BuyVars` 去掉 `tax` / `platformTax` / `feeBps`；`_feeBps`、`_platformPart` 删掉，`_applyFees` 改为 `_applyFee`（只算 1%），`_recomputeFee` 按 `BPS − PROTOCOL_FEE_BPS` 反推实付；`_syncShareAndTax` 改为 `_syncShareAndFee`：有分红的币照常按成交后的余额 `setShare`（毕业后外盘交税按这些份额记账），然后把 1% 交给手续费池。`Buy` / `Sell` 事件签名不变，`tax` 字段恒为 0。`PLATFORM_TAX_BPS` 常量保留（CLI 和服务端索引器从核心读它，现在表示外盘税里平台那份）。`create` 的参数和校验不变（税率、分红比例、接收地址照旧写进代币和 handler，只用于外盘）。 |
| `TaxHandlerV3` | 删掉只给内盘用的 `distribute`、`_payOut`、`_split`、`previewSplit` 和错误 `BadPlatformAmount`。`TaxDistributed` 事件签名不变：`phase` 仍是 `ITaxHandlerV3.Phase`，只会发 `PostGrad`（1）；`Bonding`（0）留在枚举里，不再出现。`register`、白名单、欠款、外盘税（`notifyTax` / `swapBack` / `process` / `release`）不变。 |
| `ITaxHandlerV3` | 删 `distribute`、`previewSplit`；其余与注释更新。 |
| `TaxLaunchTokenV3`、`ILaunchpadV3`、`GangRouter` | 只改注释（字节码只有元数据哈希变化）。GangRouter 不自己算报价，`minTokensOut` 由调用方给（CLI 用 `eth_call` 模拟核心），不用改逻辑。 |
| `SharedDividendVault` | **内盘分红路径整条删除，分红合约只剩外盘分红**（用户同意）。内盘不收税后，「按当下份额直接分报价币」这条路（V2 DividendVault 沿用来的 `depositReward` → `accRewardPerShare` / `rewardDebt` → `_harvest`）没有任何调用方：V3 的唯一调用点 `TaxHandlerV3._payOut` 已随 `distribute` 删掉；打新（`FairMintPad` / `HolderRewardHandler` / `PostGradHandlerBase`）和 `GangRouter` 从来没有调用它（逐个 grep 核对过）。删掉 `depositReward`、`accRewardPerShare`、`rewardDebt`、`_harvest` 和事件 `RewardDeposited`。保留的只有按交税时记账：`setShare`、`accrueDividendUnits`、`convertDividend`、批次（`pipeOf` / `batchOf` / `positionOf`）、`pending`、`pendingUnits`、`unsoldUnits`、`pendingCredit`、`claim` / `claimFor`。顺序：`setShare` 在改份额之前仍先 `_harvestUnits(旧份额)`，把旧份额到此为止的单位结清（已结算批次的报价币进 `pendingCredit`，未结算的记到持仓的两个批次里），再写新份额；`claimFor` 先 `_harvestUnits` 再付 `pendingCredit`；`pending` = `pendingCredit` + 自上次结算后已结算批次的那份。这些逻辑都没动，删掉的只是与之并列的 `_harvest` / `rewardDebt` 两行。新增 `test_shareChangeSettlesOldUnitsFirst_claimBetween`（份额缩小、中途领取、再加仓，每一笔税都按交税那一刻的份额精确到 wei）。 |

**对外接口**

- 事件：`Buy` / `Sell` / `TaxPaid` / `TaxOwed` / `TaxDistributed` / `TaxConfigured` / `Created` 签名都不变。变化只在取值：`Buy.tax` / `Sell.tax` 恒为 0；`TaxDistributed` 不再有 `phase = 0`；`TaxPaid` / `TaxOwed` 只来自外盘税（`swapBack` / `process`）和 `release`。
- 函数：`TaxHandlerV3.distribute`、`TaxHandlerV3.previewSplit` 删除（CLI、服务端、网站都没有调用）；错误 `BadPlatformAmount` 删除。`SharedDividendVault.depositReward`、getter `accRewardPerShare(token)`、`rewardDebt(token, user)` 删除，事件 `RewardDeposited` 删除；`pending` / `pendingUnits` / `unsoldUnits` / `pendingCredit` / `shares` / `totalShares` / `claim` 签名不变。核心的 view（`curves`、`taxConfigOf`、`checkTaxConfig`、`PROTOCOL_FEE_BPS`、`PLATFORM_TAX_BPS`、`MIN_TAX_BPS`、`MAX_TAX_BPS`）不变。
- 内盘价格：同样的买卖，有税币和无税币拿到的代币 / 报价币完全一样（`test_curve_taxedPricesLikeUntaxed`）。

**不变量变化（§5）**：#8 改为「每笔内盘交易只收 1% 进手续费池，接收地址、分红合约、TaxHandlerV3 收不到任何报价币」；CoreInvariants 新增 `invariant_v3CurveNoTax`（直接买、经路由用报价币 / BNB 买、卖出，每笔都核对手续费恰好 1%、三个去处余额不变，并且没毕业的 V3 币在分红合约里没有任何记账单位）。分红合约的偿付和对账不变量（#11 `invariant_sinksSolvent`、#12 `invariant_taxTimeDividendsBacked`，以及 `VaultUnitsInvariant` 的精确性 / 偿付 / 清空三条）原样保留并通过：`pending` 现在只由交税时记账构成。#7 仍是 `≥`：毕业截断可能在核心留下 ≤ 1 wei。

**审计修复的影响**

- §10 A-6（内盘卖出先更新卖家份额再分账）：内盘没有税了，这条在内盘上不再适用；外盘的同一条（§17 C-F7）不变。
- 审计 4 F-2（`depositReward` 按到账差额记账）：函数已删，问题随之消失。
- 不变量 §5 #8 改为「内盘每笔只收 1% 进 bucket，接收地址、分红合约、handler 收不到任何报价币」；#5「发射台只能付钱进 TaxHandlerV3」不再适用（发射台不再付钱给 handler）。
- K-10 只剩外盘：没有合格持有人时，分红那份并入接收地址。

**测试**

| 文件 | 改动 |
|---|---|
| `test/launchpad-v3/LaunchpadV3.t.sol` | 删掉断言内盘收税的 `test_bondingBuy_split_*`、`test_bondingSell_split_withDividends`、`test_firstBuy_noHolders_*`、`test_bondingAsymmetricRates_*`；新增 `test_curveBuy_onlyProtocolFee_noTax`、`test_curveSell_onlyProtocolFee_holdersAndRecipientGetNothing`、`test_curve_taxedPricesLikeUntaxed`、`test_curveToGraduation_onlyFee_thenPoolTaxSplitsAsBefore`；`test_delistedRecipient_*`、`test_failedPush_*` 改为在外盘验证（毕业后外盘税换币推送失败记欠款）；`test_router_accessControl` 去掉 `distribute` / `previewSplit` |
| `test/launchpad-v3/LaunchpadV3Fuzz.t.sol` | 买：实付 = 进曲线 + 1%（+ ≤ 1 wei），手续费池恰好 + 1%，接收地址 / 分红合约 / handler 为 0；卖：卖家到手 = quoteOut − 1% |
| `test/launchpad-v3/LaunchpadV3Audit.t.sol` | `test_audit_sellTaxStillPaysOtherHolders` 改为 `test_audit_curveSellPaysNoHolder`；`test_merge_owedQuoteNeverSoldByProcess` 的欠款改由 Y 毕业后的外盘税产生 |
| `test/common/SharedInfra.t.sol` | 内盘买入不再产生分红；「移除核心后已有币照常分红」改为毕业后外盘税 → keeper 卖出 → 可领；跨核心写入被拒改为核对 `accrueDividendUnits` / `convertDividend`（原 `depositReward`），`accRewardPerShare` 断言改为 `unsoldUnits` / `pending` |
| `test/common/TaxTimeDividends.t.sol` | 新增 `test_shareChangeSettlesOldUnitsFirst_claimBetween` |
| `test/fair-mint/FairMint.t.sol`、`FairMintAudit.t.sol`、`FairSwapBack.t.sol`、`test/launchpad-v3/SwapBack.t.sol` | 「分红合约拒绝所有 operator 写入」的 mock 列表里去掉已不存在的 `depositReward` |
| `test/invariant/CoreInvariants.t.sol` | 新增 `invariant_v3CurveNoTax`（见上） |
| `test/audit5/audit5a/VaultUnitsInvariant.t.sol` | 不用改代码：它本来就只驱动 `setShare` / `accrueDividendUnits` / `convertDividend` / `claim`，模型里没有 `depositReward`；删掉那条路之后它覆盖的正是分红合约的全部记账 |
| `script/LaunchpadV3TestnetE2E.s.sol` | 测试网整轮脚本：A 的内盘买卖改为核对接收地址**收不到**钱；B（拉黑接收地址）的内盘买入改为核对**没有**欠款 |

**结果**：`forge fmt --check` 通过；`forge test` 646 个全过（不设 `BSC_RPC_URL`）；主网分叉（48.club）`test/fork/*` 12 个全过；`test/audit5/**`（`--threads 1`）153 个里 152 个一次通过，剩下 1 个（`ReviewFairForkTest.test_review_fair_unsyncedSetAsideAndReturned`）是 48.club 返回 `not supported`（节点只留最近约 100 个区块的状态），单独重跑这个套件 7 个全过（改用 blastapi 重跑时被限流 429，不算结果）；invariant：`CoreInvariants` 10 条（新增 `invariant_v3CurveNoTax`）与 `audit5a/VaultUnitsInvariant` 3 条在 200 × 80 下全过（各 200 runs、16,000 次调用；跑完已把 inline 配置还原为 24 × 50 / 48 × 120）；两个部署脚本（加上路由脚本）在 BSC 测试网与主网的本地 anvil 分叉上顺序跑通（打新复用 V3 的五个共用合约 + `PEER_CORE`；主网 `OWNER` = 部署地址、`MAINNET_OWNER_IS_DEPLOYER=true`、链接线上 PoolCheck），部署出的 TaxHandlerV3 字节码里没有 `distribute` 的选择器、分红合约里没有 `depositReward` / `accRewardPerShare`，没有往任何链广播（本地分叉写出的 `broadcast/` 文件已还原）。

**运行时字节码**（`forge build --sizes`）：LaunchpadV3 16,948 B（原 18,819）、TaxHandlerV3 19,941 B（原 21,130）、SharedDividendVault 8,752 B（原 9,799），其余不变：TokenDeployer 20,688 B、HolderRewardHandler 18,041 B、FairMintPad 16,803 B、TaxLaunchTokenV3 4,472 B、FairToken 4,372 B、SharedPlatformFeeBucket 4,365 B、GangRouter 4,135 B、LaunchTokenV3 2,297 B、SharedMigrator 2,001 B，都 < 24,576 B（最大的 TokenDeployer 余 3,888 B）。

**需要跟着改的地方**（服务端、网站、CLI；合约事件不变，所以没有会报错的地方）

- CLI（本仓库 `skill/`，已改）：`v3 buy` / `v3 sell` 的提示和输出（`curveTaxPct: 0`，`poolBuyTaxPct` / `poolSellTaxPct` 表示外盘税），`v3 info` 新增 `taxNote`，`v3 create` 的 `split` / `note`，help、`references/v3.md`、`SKILL.md`、README。CLI 的报价本来就是对核心 `eth_call` 模拟，不用改算法。
- 服务端（gangfun-server）：`feesIndexer.js` 会订阅主网 V3 / 打新核心的分红合约上的 `RewardDeposited`（以后不会再有这个事件，不报错，只是一直没有记录）；`burn.js` 的 `accRewardPerShare` 只对 V2 / S / U 的股票币读，读不到共用分红合约（股票币在共用分红合约里 `quoteOf` 为 0），不受影响。其余要点： `trackMarket.js` 里按 `phase='curve'` 连 `TaxDistributed` 的分账以后恒为空，`tax` 字段恒为 0，注释与 README 里「内盘收税」的说法过时；收入面板（`v3.js` income 汇总）和 `TaxPaid` 统计不受影响。
- 网站（gang-web-legacy）：税率旁「内外盘都收」、交易步骤「已含 X% 买入税」、内盘交易表的「税」列（恒为 0）、`v3_lead` / `v3_tips` / `v3_rec_tips` 等文案要改成「内盘只收 1% 手续费，税只在外盘收」。

---

## 20. 合约合并：一个内盘、一个外盘处理合约、一种代币（2026-10-27）

> 本节按合并方案 `MERGE-PLAN`（2026-10-27）和四个实现分支（`feat/merge-token`、`feat/merge-handler`、`feat/merge-pad`、`feat/merge-scripts`）写成。实测数据取自整合分支 `feat/gang-merged`（四个实现分支 + `feat/merge-tests` + `feat/merge-cli-docs` 合在一起，再加三路审查的修改）。合并以 §19 之后的代码为基础。

### 20.1 为什么合并、合并成什么

V3 和打新原来各有一个核心、一个外盘处理合约、各自的代币，靠五个共用合约（QuoteRegistry、bucket、vault、migrator、TokenDeployer）连在一起。两个核心共用金库后，金库里两种币的 `launchpadOf` 不再能区分来源，部署也要两个脚本、靠 `PEER_CORE` 互相核对（§17 C-F1、§18 R5-3）。合并后只剩一个内盘地址、一个外盘处理合约、一种代币；币的种类由内盘在创建时写一次 `kindOf`，外盘处理合约在登记时写一次 `routeOf.kind`。

不可升级，没有代理，也没有 diamond。内盘超过 24 KB 的部分拆进两个外部库，用 delegatecall 调用。

### 20.2 合并后的合约清单

| # | 合约 / 库 | 类型 | 由谁合并而来 | 职责 | 运行时字节 |
|---|---|---|---|---|---|
| 1 | `GangToken` | 代币（每个币一份） | TaxLaunchTokenV3 + FairToken + LaunchTokenV3 | 三种币一份代码：V3 有税（买 / 卖各 1–5%）、V3 无税（0 / 0）、打新（1% / 1%，`reclaimable`）。毕业前锁转账；`unlock(migrator)`、`setPair` 各一次；外盘收税、卖出时 `swapBack` | 4,795 |
| 2 | `GangLaunchpad` | 内盘核心 | LaunchpadV3 + FairMintPad 的外壳、存储、管理函数、共用部分 | 唯一地址、唯一状态：`curves`、`sales`、`positions`、`kindOf`、`owedFee`；准入、路由白名单、`nonReentrant` 都在这里；视图 `baselineOf` / `holdBpsOf` 直接读存储 | 13,494 |
| 3 | `CurveLogic` | 外部库（delegatecall） | LaunchpadV3 的创建、买卖、毕业 | V3 曲线：`create` / `buy` / `sell` / 毕业；只收 1% 手续费（§19） | 11,140 |
| 4 | `FairLogic` | 外部库（delegatecall） | FairMintPad 的创建、打新、卖回、发射 | 打新：`create` / `mint` / `withdraw` / `flushFees` / 发射；计时、撤出费、`owedFee` | 11,015 |
| 5 | `PadCommon` | internal 库（编译进调用方） | 两个核心的重复代码 | `requireQuote`、`toQuote`、`pullExact`、`toPlatform`、`migrate` | — |
| 6 | `GangTaxHandler` | 外盘税处理（继承 `PostGradHandlerBase`） | TaxHandlerV3 + HolderRewardHandler | 两种币按 `routeOf.kind` 分派：V3 平台拿成交额 0.5%、分红比例自设、接收地址白名单和欠款；打新平台部分为 0、一半给合格持有人、出局线 | 22,214 |
| 7 | `PostGradHandlerBase` | 抽象基类 | 不变，只改两个钩子的默认实现 | keeper / dexRouter 时间锁、每区块额度、`swapBack` / `process`、skim 后退回、`flushHolders` / `flushPlatform`、带保护的写份额 | — |
| 8 | `GangRouter` | 无状态路由 | GangRouter（构造参数改成一个 pad） | `v3Buy` / `v3BuyBNB` / `fairMint` / `fairMintBNB` 不变；`v3()`、`fair()` 都返回同一个 pad | 4,041 |
| 9 | `SharedDividendVault` | 外盘分红 | 不变（§19 版） | 按交税时记账，两批先进先出；一个 pad 只绑一个 operator（这个 handler） | 8,752（不变） |
| 10 | `SharedPlatformFeeBucket` | 内盘手续费池 | 不变 | operator：pad、handler | 4,365（不变） |
| 11 | `SharedMigrator` | 迁移、LP 销毁 | 不变，只登记一个 pad | | 2,001（不变） |
| 12 | `QuoteRegistry` | 固定换算额 | 不变 | | 1,537（不变） |
| 13 | `TokenDeployer` | 部署代币 | 缩成一个 `deploy(name, symbol, uri, handler, buy, sell, reclaimable)`（保留合约，没有改成 `TokenFactory` 库） | 只有登记过的 pad 能部署 | 9,361 |
| 14 | `PoolCheck` | 外部库，主网已部署 `0xd2B1…bDb3` | 不变，按地址链接（`CurveLogic` / `FairLogic` 都要链接） | 参考池检查 | 5,345（不变） |

带 owner 的合约从 9 个减到 7 个：pad、handler、vault、bucket、migrator、registry、TokenDeployer。主网 owner 是 Safe `0x2866…B41E`（2/3）：部署后 7 个合约 owner = 部署钱包、pendingOwner = Safe，Safe 批量 `acceptOwnership()`（运行手册 §3）。

### 20.3 库的 delegatecall 语义和风险

语义：
- 库的 external 函数由 pad 用 delegatecall 调用，在 pad 的上下文里执行：`msg.sender` 仍是调 pad 的人（用户或路由），`address(this)` 是 pad，余额、存储、事件发出地址都是 pad 的。所以 `pullExact` 从 `msg.sender` 拉钱、退款给 `msg.sender` 的行为和合并前一样。
- 库内部调 `PoolCheck` 是嵌套的 delegatecall，仍在 pad 的上下文里。
- 可变配置放在一个 `Config` 存储结构里，以 storage 指针传给库；不可变量（registry、vault、bucket、handler、deployer、wbnb）在 pad 的字节码里，库读不到，由 pad 每次组一个 `Deps memory` 传进去。
- `nonReentrant`、路由白名单、A-2 的准入检查都写在 pad 的包装函数里，不放进库。审计员只看 pad 就能确认每个入口的门槛。
- 事件：每个库只声明自己那一版（`CurveLogic` 是 V3 的 `Created`，`FairLogic` 是打新的 `Created`）；pad 继承的接口 `IGangLaunchpad` 声明两版重载，只用来生成 ABI。两版参数不同，topic0 和合并前完全一样。

风险（请重点看）：
1. **storage 指针传错 mapping**：库的签名里有多个同类型的 mapping（`curves` / `sales`、`logoURIOf`、`kindOf`），传错位置时编译器不会报错。`test_merge_getterLayout` 和两种币交替的端到端测试兜底。
2. **库被直接调用**：库的非 view 函数如果被直接 call（不经 delegatecall），会在库自己的上下文里执行。Solidity 的 external 库函数默认带「只能 delegatecall」检查，非 view 函数直接 call 会回滚；`test_merge_libsNotDirectlyCallable` 锁住这一点。库没有存储、也不持有资金。
3. **链接地址**：部署时 `CurveLogic`、`FairLogic` 链接 PoolCheck，pad 链接两个库；地址错了 pad 会 delegatecall 到错的代码。部署脚本要核对 pad 字节码里链接的库地址的 `extcodehash`。部署脚本不读 extcodehash，改用经 pad 调用两个库的 view 来证明链接可用：`graduationAmountOf(WBNB)` / `previewCreate(WBNB, 15 BNB)`，主网再走 USDT 参考池路径（`graduationAmountOf(USDT, USDT_REF_POOL) > 0`、`previewCreate(USDT, USDT_REF_POOL, 5 BNB)` 不回滚，覆盖库里链接的 PoolCheck）；另查只有真 pad 才有的 `CURVE_SUPPLY` / `MINT_SUPPLY` / `checkTaxConfig`（旧的部署用 stub 过不了，`test_fork_deploy_checkRefusesTheStub`）。两个库由 forge 经 CREATE2 部署，地址在 `broadcast/…/run-latest.json` 的 `libraries` 字段。
4. **不可变量只能靠 `Deps` 传**：如果库里漏用 `Deps` 字段、写死了地址，测试网和主网会不同。
5. **ABI 漂移**：indexed 位置、getter 字段顺序、事件参数名变了时，topic0 不变但解码会错。`test_merge_eventTopics` / `test_merge_selectors` / `test_merge_getterLayout` 兜底。
6. **gas**：路由卖出多一次 delegatecall，约多 3–5k gas；`swapBack` 在 handler 里，不受影响。如果 handler 为了大小降了 optimizer runs，要重跑 §18 的 gas 扫描（`SWAP_BACK_GAS = 600_000`）。实测（主网分叉、真实 Pancake，handler 没有降 runs）：V3 毕业后第一块（handler 第一次 approve 路由、接收地址第一次收 WBNB，存储全部 `vm.cool`）在 `SWAP_BACK_GAS = 600_000` 的上限内用 399,510 gas 卖出；同一笔路由卖出 635,619。gas 扫描：路由卖出最低 610,000、直接转进池子最低 571,000，任何能成功的 gas 都卖出了这一块（没有静默跳过、没有延后）；有未同步余额时最低 602,000 / 640,000。`test_gas_typical`：路由卖出带一块 703,782（§18 skim 版 658,231），不带一块 318,255，直接转账带一块 376,608，路由买入 285,435，keeper `process` 312,625。`test_review_gas_unsynced`：池子已同步 527,510、多出报价币 560,168、多出报价币和代币 570,024。

### 20.4 旧函数到新位置

**内盘：LaunchpadV3 / FairMintPad → GangLaunchpad + 两个库**

| 合并前 | 合并后 | 说明 |
|---|---|---|
| V3 `create(name, symbol, logoURI, metaURI, quote, refPool, TaxConfig)` | pad `create` 重载 → `CurveLogic.create` | selector 不变；合并后加了 `nonReentrant` |
| 打新 `create(…, MintConfig, devShares)` | pad `create` 重载 → `FairLogic.create` | selector 不变；保留 `nonReentrant` |
| V3 `buy` / `buyFor` / `sell` | pad → `CurveLogic` | `buyFor` 的路由白名单和 `agentGateEnabled` 检查留在 pad |
| 打新 `mint` / `mintFor` / `withdraw` / `flushFees` | pad → `FairLogic` | `mintFor` 的路由白名单和 `s.gate != 0` 检查留在 pad |
| 两边都有的 `setMigrator` / `setRouter` / `setAgentGate` / `setV3Factory` / `setTwapWindow` / `setBridgePool` | pad 各一份 | 事件签名本来就一样，合成一份 |
| V3 `setPairFactory` / `setWalletCapEnabled` | pad | 打新原来的 `pairFactory` 是不可变量，合并后可以设置，只影响之后创建的币。保留可设置（V3 原有行为，审查同意）；构造时 `pairFactory_ == 0` 回滚 `ZeroAddress`（和旧 FairMintPad 一致） |
| `checkTaxConfig` / `taxConfigOf` / `walletRoom` / `gradAmtOf` / `graduationRemaining` / `graduationAmountOf` | pad 视图 | 不变 |
| `checkConfig` / `previewCreate` / `previewMint` / `previewWithdraw` / `exitFeeBpsOf` / `status` / `baselineOf` / `holdBpsOf` | pad 视图 | `baselineOf` / `holdBpsOf` 每笔池子交易都被 handler 调用，留在 pad 直接读存储 |
| `isAgent`、`tokenCount` / `allTokens` / `logoURIOf` | pad 一份，两种币混在一起 | 新增 `kindOf(token)`：0 不是本 pad 的币 / 1 V3 曲线 / 2 打新 |
| `owedFee` | pad | 只有打新用 |
| 事件 V3 `Created`（8 个参数）/ 打新 `Created`（13 个参数） | 重载，topic0 都不变 | |
| `Buy` / `Sell` / `VirtualQuoteLocked` / `Graduated` / `TaxConfigured` | `CurveLogic` 发出（发出地址是 pad） | `tax` 恒为 0（§19） |
| `Minted` / `Withdrawn` / `Launched` / `ShareWriteFailed` / `FeeOwed` / `FeesFlushed` | `FairLogic` 发出（发出地址是 pad） | 不变 |
| 错误 | 同名的合成一份，各自独有的保留 | 名字和参数不变，CLI 按 selector 解码。没有加 `WrongKind()`：用错种类的币调用报 `UnknownToken`（CLI 按 `kindOf` 提示改用另一个命令）。库里发生的 `ThinReferencePool`、`GradAmtZero`（PoolCheck）和 OZ 的 `SafeCastOverflowedUintDowncast`、`SafeERC20FailedOperation` 也声明在 `IGangLaunchpad` 里，pad 的 ABI 能解码（`test_merge_libraryErrorsInPadAbi`） |

**外盘：TaxHandlerV3 / HolderRewardHandler → GangTaxHandler**

| 合并前 | 合并后 | 说明 |
|---|---|---|
| V3 `setLaunchpad` / 打新 `setPad` | `setLaunchpad`（一次性） | 删掉 `PadSet` / `PadAlreadySet`；打新的 `pad()` getter 改为 `launchpad()` |
| V3 `register(token, quote, recipient, dividendBps)` | `register(token, quote, recipient, dividendBps, kind)` | 只有 pad 能调，同一个币只能登记一次（`AlreadyRegistered`）；kind 不对回滚 `BadKind`。打新登记成 `(quote, 0, 5000, Fair)` |
| V3 `notifyTax`（5 个参数）/ 打新 `notifyTax`（4 个参数） | 只留 5 个参数的版本 | 打新分支忽略 `rateBps` |
| `syncShares` / `process` / `swapBack` | 一份，按 `kind` 分派（§20.5） | |
| `release` / `list` / `delist` / `isListed` / `recipients` / `entries` / `owedOf` / `owedTotalOf` / `accruedPlatformTax` | 一份 | 只对 V3 有意义 |
| `eligibleShare` / `isOut` | 一份 | 只对打新；V3 币返回 0 / false |
| `OuterTaxProcessed`（V3 5 个字段、打新 6 个字段） | 两版重载，按 kind 发 | topic0 都不变 |
| `TaxDistributed` / `TaxPaid` / `TaxOwed` / `RouteRegistered` / `Listed` / `Delisted` / `Disqualified` | 不变 | `RouteRegistered` 对打新币也发 |
| 基类事件（`TaxAccrued`、`TaxChunkSold`、`HolderConversionDeferred`、`PlatformOwed` / `PlatformFlushed`、`ShareWriteFailed`、keeper / dexRouter 系列） | 不变 | 两种币从同一个地址发出，下游要按币分轨道 |

**代币、路由**

| 合并前 | 合并后 |
|---|---|
| `TaxLaunchTokenV3` / `FairToken` / `LaunchTokenV3` | `GangToken`，不可变量 `buyTaxBps`、`sellTaxBps`、`reclaimable`。事件不变；新错误 `Untaxed`、`NotReclaimable`，`NotLocked` 原来只有打新币有 |
| `LaunchTokenV3.unlock()`（无参数） | `GangToken.unlock(migrator)` |
| `TokenDeployer.deployPlain` / `deployTax` / `deployFair` | 一个 `TokenDeployer.deploy(name, symbol, uri, handler, buyTaxBps, sellTaxBps, reclaimable)` |
| `GangRouter(v3_, fair_, wbnb_)` | `GangRouter(pad_, wbnb_)`，`v3()` 和 `fair()` 都返回 pad |
| 三个部署脚本 + `SharedPlatform` 的复用逻辑 | 一个部署脚本（见运行手册 §1，由 `feat/merge-scripts` 改）；`PEER_CORE` / `PartialShared` 没有了 |

### 20.5 外盘按 kind 分派

打新币可以看成一种特殊的路由：平台部分为 0，`dividendBps = 5000`，没有接收地址（剩下的归平台）。这样只有三处要分支：

| 地方 | V3（kind 1） | 打新（kind 2） |
|---|---|---|
| `notifyTax` 平台那份 | 成交额 × 0.5%（`tax × 50 / rate`，不超过税额） | 0 |
| 写份额 | `_syncShare`：余额、10,000 枚门槛、被排除地址和 pair 为 0 | `_sync`：`min(余额, 基准)`、出局线、`isOut` 只能变 true |
| `_onProceeds` 的事件 | `TaxDistributed(PostGrad)` + 5 个字段的 `OuterTaxProcessed` | 6 个字段的 `OuterTaxProcessed` |

- `notifyTax` / `swapBack`：`routeOf[token].kind == 0` 回滚 `UnknownToken`，只认 pad 登记过的币。
- `syncShares`（任何人都能调，永远不回滚）：kind 0 直接返回；V3 在 `dividendBps == 0` 时返回；打新在 `token.locked()` 时返回。
- **不能再用 `vault.launchpadOf(token) == pad` 判断是不是打新币**：两种币的 `launchpadOf` 都是同一个 pad。合并前 HolderRewardHandler 就是这样判断的。

### 20.6 审计修复的落点

【易丢】是我们认为合并时最容易丢的，请重点看。

| 来源 | 修复 | 合并后的位置 | 风险 |
|---|---|---|---|
| §10 A-1 | 新 bucket 和 registry；所有接线做完、最后才 `setMigrator` | 合并后的部署脚本：最后一步 `pad.setMigrator` | 中：脚本合并时顺序容易乱 |
| §10 A-2 | `buyFor` 要求 `agentGateEnabled`；`mintFor` 要求 `s.gate != 0` | pad 的两个包装函数，分开写 | 【易丢】容易被「统一」成一个检查 |
| §10 A-3 / §15 | 18 位小数、拒收转账扣费、第一次拉钱时校验 | `PadCommon.requireQuote` / `pullExact` | 低 |
| §10 A-5 | catch 里的 63/64 gas 检查 | `FairLogic` 卖回写份额；基类 `_setShareGuarded` / `_creditHolders` | 中：库里重写时可能漏 |
| §10 A-6 / §17 C-F7 | 卖家拿不到自己这笔卖出税的分红 | handler `notifyTax`：两种币卖出时都先同步卖家份额 | 【易丢】打新分支漏写 `_sync(from)` |
| §10 A-7 | `setMigrator` 检查 `launchpads(this)` | pad | 低 |
| §10 A-9 / §17 C-F8 | owner 检查；路由核对核心 | 部署脚本；路由在同一个脚本里部署，核对 `pad.wbnb()` 和 `curves` / `sales` 可调 | 低 |
| §11 R2-3 | 一个核心的 handler 不能给另一个核心的币写份额 | 变成「kind 隔离」：`syncShares` / `notifyTax` 按 `routeOf.kind` 分派（§20.5） | 【易丢】**最容易出错的一条** |
| §11 R2-4 / 审计 4 | 金库排除 migrator、bucket、自己 | 部署脚本 + 金库构造函数 | 低 |
| §12 | handler 构造时写死；`unlock`、`setPair` 各一次；没有 `setTaxHandler` / `exclude` / `burn`；`reclaim` 只在发射前；metaURI | `GangToken` | 【易丢】`reclaim` 只给打新币：靠不可变的 `reclaimable`，V3 币上永远回滚 `NotReclaimable`。V3 币原来根本没有 `reclaim`，否则「发射台能拿走持有人的代币」这条信任假设对 V3 币就不成立了 |
| §13 #1 | `notifyTax` 只认登记过的币；平台部分不超过税额 | handler：kind 判断 + `min(…, tax)` | 中 |
| §13 #3 | 两条换币路径都核对池子的报价币 | 基类 `_tokenIs0` | 低（不动） |
| §14 R3-1 | 计时规则 `markSold` / `STALE_STEP` | `FairLogic` 打新 | 中：搬家时条件容易写反 |
| §14 R3-2 | 撤出费不阻塞、`owedFee`、`flushFees` | `FairLogic` 撤出费 | 【易丢】被「统一」成阻塞的 `toPlatform` |
| §14 R3-3 | 卖回时写份额失败发 `ShareWriteFailed` | `FairLogic` | 中 |
| §15 | `owedTotalOf`，`_sellable` 减欠款 | handler 两种币统一减 | 【易丢】打新以前不减 |
| 审计 4 F-1 | 第一次拉钱拒收转账扣费 | `PadCommon.pullExact` | 低 |
| 审计 4 F-2 | `depositReward` 按到账差额记 | 函数已在 §19 删掉 | — |
| 审计 4 F-3 | 本平台的币不能当报价币 | `isLaunchToken`，或者去掉 TokenDeployer 后的 `kindOf != 0`，再加 `vault.launchpadOf == 0` | 中：去掉 TokenDeployer 时必须换成 `kindOf` |
| 审计 4 A-F3 / §17 C-F10 | handler 只认本 pad 的币；pad 设置之前什么都不认 | `routeOf.kind != 0`（只有 pad 能登记） | 【易丢】 |
| 审计 4 A-F4 | migrator 的 `PairHasLiquidity` | SharedMigrator（不动） | 低 |
| 审计 4 B-Info | 直连池子路径按到账再查 `Slippage` | 基类 | 低 |
| §16 swapBack 设计；F3 `minPayout`；F4a operator 只绑一次；F4c 门槛按币快照；F4b 路由时间锁；V3 C 写份额带保护 | | 基类 / `FairLogic.withdraw` / 金库 / 基类 | 低（基本不动） |
| §17 B-F1 / B-F3 / B-F4 / C-F6 | 额度按卖出数量扣；`previewSellNextBlock`；每区块额度、参考价 2%；keeper 一次 | 基类、bucket | 低 |
| §17 C-F1 / §18 R5-3 | 复用共用合约时对 `PEER_CORE` 的核对 | 只剩一个脚本，复用模式没有了；`_checkCore` 保留对 registry / bucket / vault / migrator / deployer 的核对 | 低：问题随合并消失 |
| §17 C-F2 | bucket 只有固定路径 | 不动 | — |
| §17 C-F4 | V3 创建时检查 `VaultFloorTooHigh` | `CurveLogic` 创建（只在有分红时查） | 中：打新是每次创建都查，V3 只在有分红时查，两处不一样 |
| §17 C-F5 / §18 R5-2 | `setExcluded` 只能排合约，7702 钱包除外 | 金库 | — |
| §18 R5-1a / R5-O1 | `SellDuringFlashSwap`；skim 后退回 | 基类 + `GangToken` 的 try/catch 按 selector 原样抛出 | 【易丢】合并代币时漏掉 catch 里的原样抛出 |
| §18 R5-4 | `keeperSet` | 基类、bucket | 低 |
| §18 R5-5 | `BURNER` / `FEE_VAULT` 部署时生效 | 部署脚本 `_burner` / `_feeVault` | 中：脚本合并时要保留 |
| §19 | 内盘不收税；事件 `tax` 恒为 0 | `CurveLogic` | 中：要以 §19 版为准，不能拿 main 版搬 |

两种语义不对称、合并后必须都保留的地方（容易被「统一」坏）：
- 准入：V3 按当前设置检查；打新按创建时快照的 `Sale.gate` 检查。
- 手续费进 bucket：V3 内盘手续费和打新费阻塞（失败整笔回滚）；撤出费不阻塞（失败记 `owedFee`）。
- 写份额：V3 内盘阻塞写；打新卖回带保护写。
- `VaultFloorTooHigh`：打新每次创建都查，V3 只在有分红时查。

### 20.7 新增的不变量

原来 §5 的 #1（打新托管 `==`）和 #7（V3 `≥`）合成一条，因为曲线和 sale 的钱现在都在 pad 一个地址里：

```
对每个报价币 q：
balanceOf(pad, q) == Σ_未发射 sale (sold × sharePrice) + owedFee[q] + Σ_未毕业曲线 realQuote + dust[q]
其中 dust[q] ≥ 0，只会增长
```

要证明的是：打新卖回或发射动不到 V3 曲线的 `realQuote`，V3 卖出或毕业也动不到打新托管的本金。

其它新增的不变量：
- `kindOf[token]` 写入后不变；`routeOf[token].kind` 写入后不变，且等于 `kindOf[token]`。
- `kindOf == 1` 的币只出现在 `curves`，`kindOf == 2` 的只出现在 `sales`。
- `GangToken.reclaimable == (kindOf == 2)`；V3 币上 `reclaim` 永远回滚。
- 无税币（0 / 0）的 `pair` 永远是 0，转账永远不调用 handler。
- 打新币的份额 ≤ 基准，出局后为 0（原 #6，挪到合并后的 handler 上）。
- handler：对每个报价币 `balanceOf(handler, q) ≥ owedTotalOf[q] + owedPlatformOf[q] + Σ 该报价币的 pendingHolderQuote`（原 #9 扩展）。
- 金库门槛只有一个：`TAXED_MIN_SHARE == MIN_SHARE_BALANCE == 10_000 ether`（测试断言两者相等）。

### 20.8 大小（EIP-170 上限 24,576 B）

方案的估算：pad 10–13 KB，两个库各 9–11 KB，handler 21.5–23 KB（不拆库），代币 4.6–4.9 KB。下面是整合分支 `feat/gang-merged` 上 `forge build --sizes` 的实测运行时字节（FairLogic 不在 `--sizes` 的表里，用 `forge inspect FairLogic deployedBytecode` 量）。

| 合约 | 合并前（§19 版） | 合并后实测 | 余量 |
|---|---|---|---|
| GangLaunchpad | LaunchpadV3 16,948 / FairMintPad 16,803 | 13,494 | 11,082 |
| CurveLogic | — | 11,140 | 13,436 |
| FairLogic | — | 11,015 | 13,561 |
| GangTaxHandler | TaxHandlerV3 19,941 / HolderRewardHandler 18,041 | 22,214 | 2,362 |
| GangToken | TaxLaunchTokenV3 4,472 / FairToken 4,372 / LaunchTokenV3 2,297 | 4,795 | 19,781 |
| GangRouter | 4,135 | 4,041 | 20,535 |
| TokenDeployer | 20,688 | 9,361 | 15,215 |
| SharedDividendVault | 9,799（§19 之前） | 8,752 | 15,824 |
| SharedPlatformFeeBucket | 4,365 | 4,365 | 20,211 |
| SharedMigrator | 2,001 | 2,001 | 22,575 |
| QuoteRegistry | 1,537 | 1,537 | 23,039 |

- 新目录 `src/gang/` 已在 `foundry.toml` 的 via-ir 列表里（`{ paths = "src/gang/**", via_ir = true }`，已确认）；不加会用非 IR 编译，可能 stack too deep，体积也会变大。
- handler 实测 22,214 B（< 23,500 B），不需要降 optimizer runs，也没有把视图挪进库；§18 的 gas 扫描照样重跑并通过（见 §20.3 第 6 条）。最大的合约是 handler，余 2,362 B。
- 测试 `test_sizes` 断言每个合约 < 24,064 B（留 512 B 余量）。

### 20.9 测试

- 新增 `test/merge/MergeGuards.t.sol`：`test_merge_eventTopics`（topic0 等于服务端和 CLI 里的签名）、`test_merge_selectors`、`test_merge_getterLayout`、`test_merge_kindIsolation_syncShares` / `_notifyTax` / `_swapBack`、`test_merge_reclaimOnlyFair`、`test_merge_untaxedNeverHooks`、`test_merge_sameQuoteIsolation_wbnb`、`test_merge_libsNotDirectlyCallable`、`test_sizes`、`test_merge_floorConstantsEqual`。
- 另有 `test/merge/PadMergeGuards.t.sol`（pad 侧的事件 topic、selector、getter 布局、同一报价币的托管隔离、库调用保护、大小、门槛）、`test/merge/HandlerKindIsolation.t.sol`、`test/merge/FairMixedIsolation.t.sol`（打新与同报价币隔离审查的回归：两种报价币交替 + owedFee、随机交替 fuzz、跨种类入口）、`test_merge_libraryErrorsInPadAbi`、`test_merge_constructorNeedsPairFactory`、`test_fork_v3_firstChunkAfterGraduation_coldFitsTheCap`，部署脚本的 `test_fork_deploy_checkRefusesTheStub` / `_mainnetSafeOwner` / `_keeperPinnedAndTwapFloor` 等。
- 原有套件改用共用夹具 `GangFixture`，断言不变；`SharedInfra` 改写成「一个核心、两种 kind」；`Audit4Regression` 跨核心的用例改成跨 kind；`CoreInvariants` 改用 §20.7 的等式。
- 结果：`forge fmt --check` 通过；`forge test`（不设 RPC）767 个全过；主网分叉（48.club）`test/fork/*` 13 个全过；`test/audit5/**`（`--threads 1`）163 个全过（`ReviewFairForkTest` 7 个在一次跑里因 48.club 只留近期状态报 `not supported`，单独重跑 5 个过，余下 2 个改用 blastapi 重跑通过）；部署脚本测试（带 PoolCheck `--libraries`，测试网 publicnode）`DeployScriptsFork` 16 + `DeployReview` 20 + `KeeperSmartCollectFork` 1 全过；不变量 200 × 80：`CoreInvariants` 10 条（16,000 次调用）、`VaultUnitsInvariant` 3 条全过，跑完 inline 配置已还原（24 × 50 / 48 × 120）；`DeployGang` 在主网分叉（OWNER = Safe，35 笔、约 2,814 万 gas）和测试网分叉（31 笔、约 3,025 万 gas）上模拟成功；本地 anvil（测试网分叉）真实广播 `DeployGang` 31 / 31 笔、`GangTestnetE2E` 1,178 / 1,178 笔成功，没有往任何真实链广播。gas 见 §20.3 第 6 条。

### 20.10 对外接口变化

- **地址**：V3 和打新只有一个 pad、一个 handler、一个 GangRouter。服务端的 `GANG_V3_PAD` 和 `GANG_FAIR_PAD` 填同一个地址；keeper 的 `V3_PADS`、`FAIR_PADS` 各写一条，指向同一个 pad。
- **事件和 selector**：全部不变（两个 `create`、两个 `Created`、两个 `OuterTaxProcessed` 都是重载）。pad 上的事件按 topic0 分轨道；handler 上的基类事件（`TaxChunkSold`、`HolderConversionDeferred`、`ShareWriteFailed` 等）两种币共用，索引器要按币过滤到各自的轨道；`postgrad_events` 的唯一键要加上轨道。
- **新视图**：pad 的 `kindOf(address) → uint8`；handler 的 `routeOf` 多一个返回值 `kind`（按 3 个返回值解码的旧调用方不受影响）。
- **keeper**：V3 的份额补写循环要加 `kindOf(t) == 1`，打新的加 `kindOf(t) == 2`，否则会按 V3 规则判断打新币。
- **CLI**：新环境变量 `GANG_PAD` / `GANG_TESTNET_PAD`，旧的 `GANG_V3_PAD` / `GANG_FAIR_PAD` 等仍可用；`gang v3 …` 拿到打新币时（或反过来）按 `kindOf` 提示用另一个命令；识别 `Untaxed`、`NotReclaimable`、`NotLocked`、`WrongKind`。
- **网站**：不用改代码，只通过索引器拿配置。

---

## 21. 可升级路由 + 外盘买卖入口（2026-10-27）

分支 `feat/upgradeable-router`（基于 `main` `36d55df`）。改动只在 `src/router/GangRouter.sol`、部署脚本、测试和文档；内盘、处理合约、分红合约等全部不动、不可升级。§4.1 表里「GangRouter：owner 无」一行由本节取代。

### 21.1 设计

- **只有路由可升级，地址固定**。`GangRouter` 现在是 `TransparentUpgradeableProxy`（OZ 5.1）背后的实现合约。内盘 `setRouter(代理, true)` 只登记代理；用户授权的也是代理。以后升级换的是实现，代理地址不变，内盘不用重新登记，用户不用重新授权。
- **实现合约**：原来的 immutable `pad` / `wbnb` 改为存储变量，另加 `pancakeRouter`，三者只在 `initialize(pad, wbnb, pancakeRouter)` 里设一次（`initializer`，任何一个为 0 回滚 `NotDeployed`）。实现合约的构造函数调 `_disableInitializers()`，实现合约自身永远不能被初始化（初始化槽 = `type(uint64).max`）。代理在自己的构造函数里带 `initData` 调用 `initialize`，同一笔交易完成，没有抢跑窗口。
- **存储布局**（代理存储；升级规则：新变量从 `__gap` 里取槽位（声明在 gap 前面），gap 长度相应减少，gap 之后的一切不动；不能重排、改类型、删除变量，也不能改继承列表）：slot 0 `ReentrancyGuard._status`，slot 1 `pad`，slot 2 `wbnb`，slot 3 `pancakeRouter`，slot 4–50 `uint256[47] __gap`。`Initializable` 的标记在 ERC-7201 槽 `0xf0c5…6a00`。新版本需要初始化时用 `reinitializer(2)`，经 `ProxyAdmin.upgradeAndCall` 的 `data` 调用。测试逐槽读代理存储核对布局；`test/router/GangRouterLayout.t.sol` 读编译器输出的 storageLayout（`foundry.toml` 的 `extra_output`，与 `forge inspect GangRouter storageLayout` 同源）锁定 slot 0 `_status`、1–3 `pad` / `wbnb` / `pancakeRouter`、4 起 `__gap[47]`；按规则写的 V2（`test/mocks/GangRouterV2Next.sol`：新变量占 slot 4，gap 47 → 46）升级后 slot 0–3 不动、新变量在 slot 4、其余 gap 仍为空。
- **防重入**：8 个对外入口都加了 OZ 5.1 `ReentrancyGuard.nonReentrant`（放在修饰符第一位）。OZ 5.1 的 `_status` 是普通存储槽，判断条件是 `_status == ENTERED(2)`，所以代理存储里的初始值 0 被当作「未进入」，第一次调用后变成 `NOT_ENTERED(1)`；实现合约构造时写的 1 只在实现合约自己的存储里，与代理无关。测试直接读 slot 0 证明这一点，并验证 BNB 退款回调、恶意代币在 `transferFrom` 里回调、跨入口回调（BNB 回调里调 ERC-20 入口）、升级后都会被 `ReentrancyGuardReentrantCall` 拦下。`receive` 不加锁（只有 WBNB 能打 BNB 进来）。
- **路由不留钱**：每笔调用按本次调用前后的余额差结算，多出的部分（内盘截断退款、多付的 BNB、意外剩下的代币）全部退回调用者；调用开始时路由是空的，结束时就是空的。没有 sweep（K-11 不变）。
- **2300 gas 的 WBNB 退款**：WBNB 用 `transfer` 付 BNB。经代理时多一次（已热的）实现槽读取和一次 delegatecall，`receive` 里读一次（已热的）`wbnb`，仍在 2300 以内。单元测试的 MockWBNB 同样用 `transfer`，fork 测试用真实 WBNB 走了内盘截断退款和 `poolSellForBNB` 两条退款路径。

### 21.2 权限

| 角色 | 地址 | 能做什么 |
|---|---|---|
| 代理 | `GANG_ROUTER` | 用户调用的地址；内盘登记的就是它 |
| ProxyAdmin | 代理构造时自动部署（代理的第一个 CREATE，地址 = `computeCreateAddress(代理, 1)`） | 只有它能让代理 `upgradeToAndCall`；它自己只能被 owner 调用。它调用代理的其它函数一律 `ProxyDeniedAdminAccess` |
| ProxyAdmin 的 owner | `TimelockController` | 升级、转移 / 放弃 ProxyAdmin 的所有权都只能由时间锁执行 |
| 时间锁 | `GANG_ROUTER_TIMELOCK`；`minDelay` 主网固定 48 小时 | proposer = executor = canceller = Safe `0x2866…B41E`（OZ 5.1 里 proposer 自动带 canceller）；admin = `address(0)`：`DEFAULT_ADMIN_ROLE` 只有时间锁自己，角色和延迟只能经时间锁自己的提案（同样等 48 小时）修改 |
| 部署钱包 | `0x4EEd…19d3` | 无任何角色 |

升级流程：Safe 调 `timelock.schedule(ProxyAdmin, 0, upgradeAndCall(代理, 新实现, data), 0, salt, 172800)`（链上公示 `CallScheduled`）→ 等 48 小时 → Safe 调 `timelock.execute(...)`；48 小时内 Safe 可 `cancel`。时间锁和 ProxyAdmin 都不需要 `acceptOwnership`：时间锁没有 owner，ProxyAdmin 构造时 owner 就是时间锁。

部署脚本自检（`GangRouterDeployLib.check`，任何一项不对回滚 `WiringCheck("<项>")`）：代理地址上的 runtime code 就是 OZ 5.1 的 `TransparentUpgradeableProxy`（取本次构建的产物，把 immutable `_admin` 那 32 字节填成 ProxyAdmin 地址后比对 keccak，仿冒的「代理」过不了，review PoC-2），ERC-1967 实现槽 = 实现合约，实现合约的代码 = 本仓库这一版 `GangRouter`（codehash），实现合约已锁死、没有 pad；管理员槽 = 代理自己创建的 ProxyAdmin，代码是标准 OZ ProxyAdmin，owner = 时间锁；代理已初始化且不在初始化中，`pad()` / `v3()` / `fair()` / `wbnb()` / `pancakeRouter()` 正确，Pancake 路由的 `factory()` 是 Pancake V2 工厂（主网 `0xcA14…0c73`）、`WETH()` 是 WBNB；时间锁代码是标准 OZ TimelockController，`minDelay` ≥ 48 小时（主网），**主网上时间锁的角色持有者必须是 Safe 常量 `0x2866…B41E`**（不论 `OWNER` 是谁，`MAINNET_OWNER_IS_DEPLOYER=true` 时也一样；库在主网上拒绝给别人部署时间锁，`MainnetTimelockNotSafe`；只部署路由的脚本在主网上 `OWNER` 不是 Safe 直接回滚 `OwnerNotSafe`，review PoC-1），Safe 有三个角色，`address(0)` 没有任何角色（否则任何人都能执行），三个角色的管理角色都是 `DEFAULT_ADMIN_ROLE`，`DEFAULT_ADMIN_ROLE` 只在时间锁自己手里（Safe、部署钱包、`address(0)`、ProxyAdmin 都没有），部署钱包没有任何角色（主网上无论它是不是 `OWNER`；测试网只有部署钱包本身就是 `OWNER` 时例外，用来演练升级）；内盘登记了代理，没有登记实现合约 / ProxyAdmin / 时间锁；分红合约排除了代理。测试对每一项各造一个错误接线（时间锁延迟 48 小时 − 1 秒、部署钱包留着 proposer 或 executor、admin 是部署钱包或 Safe、executor 含 `address(0)`、Safe 不是 proposer、Pancake 路由不对、实现不是本版 `GangRouter`、实现槽不一致、实现合约未锁、ProxyAdmin 被转走、ProxyAdmin 不是代理创建的、内盘登记了实现、内盘没登记代理、分红合约没排除代理），自检都报出对应的项。

### 21.3 外盘买卖入口（新增，原有函数不变）

V2、V3、打新三种币只要有 Pancake V2 交易对都能用。`quote` 由调用者传入，合约不校验 token 和 quote 的关系：交易对不存在时 Pancake 回滚，用的是调用者自己的钱。deadline 与原有入口一样（`block.timestamp > deadline` 回滚 `Expired`）。

| 函数 | 路径 | 资金流 | 返回值（按实际到账算，必须 ≥ 最低值） |
|---|---|---|---|
| `poolBuyBNB(token, quote, minTokensOut, deadline)` payable | quote = WBNB：`[WBNB, token]`；否则 `[WBNB, quote, token]` | BNB 包成 WBNB 在路由里，Pancake 把代币直接打给调用者 | 调用者代币余额的增量 |
| `poolBuy(token, quote, quoteIn, minTokensOut, deadline)` | `[quote, token]` | 从调用者 `transferFrom` 拉 `quoteIn`，按实际到账额换；代币直接到调用者 | 调用者代币余额的增量 |
| `poolSell(token, quote, amountIn, minQuoteOut, deadline)` | `[token, quote]` | 从调用者拉 `amountIn` 枚代币到路由，Pancake 把报价币直接打给调用者 | 调用者报价币余额的增量 |
| `poolSellForBNB(token, quote, amountIn, minBnbOut, deadline)` | quote = WBNB：`[token, WBNB]`；否则 `[token, quote, WBNB]` | 代币到路由；WBNB 到路由后 unwrap，BNB 转给调用者 | 转给调用者的 BNB |

- 全部用 `swapExactTokensForTokensSupportingFeeOnTransferTokens`，给 Pancake 的 `amountOutMin` 是 0，最低值由路由按调用者实际到账（扣过买卖税）检查，不满足回滚 `TooLittleReceived(received, minimum)`；金额为 0（`msg.value` 为 0、`amountIn` / `quoteIn` 为 0、或实际到账为 0）回滚 `ZeroAmount`。
- 给 Pancake 路由的授权恰好是这一笔的数量，换完立即 `forceApprove` 回 0。每笔调用后路由的 BNB、WBNB、quote、token 余额和对 Pancake 的授权都是 0（单元测试用 1:1 的假 Pancake，fork 测试用真实 Pancake，每一步都检查）。
- **卖出时代币会短暂停留在路由**。`GangToken` 每次转账都同步双方份额，所以用户转给路由时用户的份额已按转后余额同步；路由转进池子时，处理合约的 `notifyTax` 先把卖家（路由）的份额同步成卖后持仓（0）再记这笔税（审计 5 C-F7），所以路由拿不到这笔卖出税。这一笔 swap-back 卖出的是之前已经记账的单位（`convertDividend` 只换已记账的单位，不按此刻的份额重新分配），路由此刻持有的份额也分不到。此外部署脚本把代理加进了分红合约的排除名单（`vault.setExcluded(代理, true)`），分红合约从不为它写份额，每笔经路由的卖出省约 9 万 gas。fork 测试在**不排除**路由的情况下证明：路由在分红合约里的份额、待结算单位、可领都为 0；同一笔卖出经路由和直接在 Pancake 上卖，用户到手、用户份额与单位、其他持有人的单位、总份额、未卖单位、攒下的税、平台部分、接收地址到账全部相等（V3 WBNB 币、V3 USDT 币、打新币的 minter 各一组，打新另比出局状态）。
- **gas**（主网 fork，真实 Pancake，一笔带一块 swap-back 的 V3 有税币卖出，`poolSell` 调用本身）：路由被分红合约排除（部署后的状态）698,176；不排除 788,478（USDT 报价币 793,813；打新币 minter 的一笔卖出 709,905）；同一笔直接在 Pancake Router02 上卖 619,570（USDT 624,911）。swap-back 的 600k gas 上限经路由多出的几层调用仍然够用：fork 测试 `test_fork_pool_v3_chunkRunsThroughRouter` 用 `previewSell` 的结果作 `minQuoteOut`，精确成交且这一块确实卖掉了（没有被当作 gas 不够吞掉）。钱包估 gas 时要按这个量级给（建议上限 ≥ 90 万）。
- 主网真实 V2 币只在 fork 上测：AGI（`0x4000…177A`，LaunchpadV2 `allTokens[224]`，有税，报价币 GANG），BNB 进出走三跳路径；只做 swap，不调用线上 V2 处理合约的 `process`，并确认线上 V2 分红合约里路由的份额为 0。

### 21.4 风险

1. **恶意升级可以动用户对路由的授权**。代理地址固定，用户对它的 ERC-20 授权在升级后仍然有效；一个恶意实现可以 `transferFrom` 走用户授权过、且钱包里还有的代币（测试 `test_upgrade_maliciousNeeds48h_exactApprovalLimitsIt` 演示）。缓解：(a) 升级必须经 48 小时时间锁，提案在链上公示（`CallScheduled`），期间用户可以撤销授权，Safe 可以 `cancel`；(b) 只授权本次用量——CLI 的 `v3 buy` / `fair mint` 给路由发原生 BNB；`poolBuy` / `poolSell` 先按这一笔的精确数量授权给路由，从不做无限授权；网页 / 第三方集成同样按单笔数量授权（`poolSell` / `poolBuy` / `v3Buy` / `fairMint` 都只拉本次的数量）；(c) 监控时间锁的 `CallScheduled` 事件并报警。内盘里的资金不受影响：内盘对路由只开放 `buyFor` / `mintFor`，而且付款方是路由自己（§4.2 第 3 条）。
2. **Safe 就是升级权**。2/3 的 Safe 签名被拿到后，攻击者仍要等 48 小时，期间公开可见；Safe 另外两把钥匙可以 `cancel`（canceller 也是 Safe 本身，所以取消也要 2/3）。时间锁本身的角色 / 延迟只能经时间锁提案修改，同样 48 小时。
3. **存储布局错误**会让升级后读错 `pad` / `wbnb` / `pancakeRouter` 或破坏重入标记。规则写在合约注释里；升级前用 `forge inspect GangRouter storageLayout` 对比新旧布局。
4. **外盘入口不校验 quote**：调用者传错 quote 只会让 Pancake 回滚或按错误路径成交，损失的是调用者自己（有最低值保护）。路由不持有任何人的资金，传错参数影响不到别人。

### 21.5 测试

- `test/router/GangRouter.t.sol`（20）：原有用例全部改为经代理调用，另加 `initialize` 三个参数为 0 都回滚。
- `test/router/GangRouterUpgrade.t.sol`（18）：部署形态与布局、实现不能初始化、代理不能重复初始化、ProxyAdmin 只听时间锁、只有 Safe 能提案且不能缩短延迟、48 小时差 1 秒回滚 / 到点能执行 / 只有 Safe 能执行 / 只能执行一次、Safe 取消、角色只能经时间锁自身修改、升级后 `pad` / `wbnb` / `pancakeRouter` 保留且新逻辑和追加变量生效、恶意升级演示、每次调用后路由为空（含 fuzz）、重入（初值 0、BNB 回调、打新回调、跨入口、升级后）、`receive` 只收 WBNB。
- `test/router/GangRouterPool.t.sol`（4）：四个外盘入口的路径与按到账计量、拒绝情况（`Expired` / `ZeroAmount` / `TooLittleReceived`）、授权归零与余额为 0、恶意代币和 BNB 回调的重入。
- `test/fork/RouterPoolFork.t.sol`（10，主网 fork、真实 Pancake）：V3 WBNB 有税币、V3 USDT 有税币、打新币、真实主网 V2 币（AGI / GANG）各跑 BNB 买、quote 买、卖成 quote、卖成 BNB，最低值多 1 wei 回滚，路由余额与授权为 0；三组「经路由卖 = 直接卖」记账对比；经路由的 swap-back 块确实执行；分红合约排除路由后的 gas；升级后外盘入口照常。
- `test/router/GangRouterReviewPoC.t.sol`（2）：严格审查的两个 PoC 作为回归——部署钱包持有时间锁角色在主网规则下被拒（库拒绝部署、自检报错、部署钱包另留一个角色也报错），仿冒代理被「router proxy code」拦下。`test/router/GangRouterLayout.t.sol`（2）：存储布局快照。
- 没有 RPC 时 fork 用例用 `vm.skip(true)` 显示为跳过（不再显示 PASS）。
- 部署脚本（`test/audit5/audit5c/DeployScriptsFork.t.sol`，`--threads 1`）：主网 `MAINNET_OWNER_IS_DEPLOYER=true` 时路由时间锁仍只给 Safe、部署钱包无角色；只部署路由的脚本在主网上 `OWNER` 不是 Safe（含部署钱包）回滚；整套部署里路由的形态、21.2 列出的每一种错误接线被自检抓出、主网 `ROUTER_TIMELOCK_DELAY` 只能是 48 小时（测试网可缩短）、重跑时从代理读回实现 / ProxyAdmin / 时间锁再核对、真实 WBNB 的退款经代理、`DeployGangRouterUpgradeable` 给已有内盘挂新路由及其重跑。
