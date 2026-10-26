# 审计说明 · 打新（FairMintPad）、LaunchpadV3 税收接收地址、GangRouter

- 日期：2026-10-26 Asia/Shanghai
- 读者：外部审计方
- 代码：`gangfun/gang-launchpad`，打新重设计在分支 `feat/fair-no-deadline`（§14），合约冻结在提交 `1bcc84f`（含 §10、§11 两轮内部审计的修复，§12 的代币收紧与元数据 URI，§13 的外盘税合约加固，§14 的打新去掉截止时间与第三轮内部审计修复；之前的冻结点依次是 `5854a35`、`36d8a7e`、`47a063b`、`cf96281`、`a15b704`、`13da13b`）。此后若有提交改动 `src/`，我们会单独列出 diff。
- 链：BNB Chain（chainId 56），DEX 为 PancakeSwap V2。目前只部署在 BSC 测试网，部署脚本在审计前拒绝主网广播。
- 工具链：Foundry 1.8.6，Solidity 0.8.28，EVM cancun，optimizer 200 runs；OpenZeppelin 5.1.0。范围内的目录都用 via-ir 编译（`foundry.toml` 的 `compilation_restrictions`）。

---

## 1. 背景

gang.fun 是 BNB Chain 上的发币平台，内盘只对持有 .ai Agent ID（SPACE ID 发行的灵魂绑定 ERC-721）的钱包开放。主网在运行的是 LaunchpadV2（`src/launchpad-v2/`），已经过外部审计，不在本次范围内。

本次送审三块新合约：

| 模块 | 一句话 |
|---|---|
| 打新 FairMintPad | 没有价格曲线：所有人按同一价格一份一份打，打满 10,000 份就把 50% 代币和全部募集款加进 Pancake 池子开盘；没有截止时间和退款，打满前随时按同一价格卖回（扣撤出费，sale 7 天没有进展时免）。开盘后每笔池子交易收 1% 税，一半分给「打新时进来、而且一直没卖到出局线以下」的地址，一半给平台。 |
| LaunchpadV3 | 在 V2 曲线（Agent 专属、单地址 1% 上限、约 15 BNB 毕业）的基础上，发币时可设买 / 卖税（各 1%–5%）和一个白名单里的税收接收地址（合作方金库）。平台从税里固定拿成交额的 0.5%，剩下按设定比例分给持币人和接收地址，接收地址收报价币。 |
| GangRouter | 无状态、无 owner 的入口：把原生 BNB 换成 WBNB 后替调用者在两个核心上买入 / 打新，多付的部分退回。 |

各自的产品规格：`docs/SPEC-FAIR-MINT-2026-10-26.md`、`docs/SPEC-V3-TAX-RECIPIENT-2026-10-26.md`、`docs/SPEC-CORE-ROUTER-2026-10-26.md`。

---

## 2. 范围

### 2.1 在范围内（约 2,040 nSLOC）

| 文件 | nSLOC | 职责 |
|---|---|---|
| `src/fair-mint/FairMintPad.sol` | 510 | 创建、打新、卖回（撤出）、补交撤出费、打满发射；每个 sale 创建时快照规则；持有全部托管本金 |
| `src/fair-mint/FairToken.sol` | 96 | 打新代币 + `FairTokenDeployer`：发射前锁转账、发射台可收回；发射后池子买卖收 1% 税；税处理合约构造时写死，发射时一次性 `unlock(migrator)` + `setPair` |
| `src/fair-mint/HolderRewardHandler.sol` | 185 | 发射后的税：keeper 换成报价币，50% 给合格持有人 / 50% 平台；出局判断 |
| `src/launchpad-v3/LaunchpadV3.sol` | 563 | V2 曲线 + 买 / 卖税 + 接收地址；`buyFor` 路由入口 |
| `src/launchpad-v3/TaxLaunchTokenV3.sol` | 110 | 带买、卖两个税率（immutable）的代币 + `TaxTokenDeployerV3`；税处理合约构造时写死，毕业时一次性 `unlock(migrator)` + `setPair` |
| `src/launchpad-v3/LaunchTokenV3.sol` | 26 | V3 无税币：V2 LaunchToken 加元数据 URI，`unlock` 只能一次，去掉 `burn` |
| `src/launchpad-v3/TokenURI.sol` | 13 | 三种代币共用：构造时写入的 `_uri`，`contractURI()`（ERC-7572）/ `metaURI()` |
| `src/launchpad-v3/PostGradTaxHandlerV3.sol` | 153 | 毕业后的税：按每笔方向记平台部分，keeper 换币后交给 TaxRouterV3 |
| `src/launchpad-v3/TaxRouterV3.sol` | 140 | 分账：平台 → 分红 → 接收地址；推送失败记欠款，任何人可补发 |
| `src/launchpad-v3/RecipientRegistry.sol` | 38 | 接收地址白名单 |
| `src/launchpad-v3/interfaces/*.sol` | 56 | V3 接口与共用常量 |
| `src/router/GangRouter.sol` | 162 | 无状态路由 |

### 2.2 复用、不在范围内，但集成方式在范围内

以下 V2 合约的代码原样复用（已随 V2 审计）：`DividendVault`、`PlatformFeeBucket`、`MigratorV2`、`PoolCheck`、`QuoteRegistry`。V3 无税币不再用 V2 的 `LaunchToken`，改用 `LaunchTokenV3`（在范围内）。实例都是新部署的，不用主网 V2 那几份：DividendVault 和 MigratorV2 每个核心各一份；QuoteRegistry 和 PlatformFeeBucket 由 V3 和打新共用一份，owner 是多签（`script/SharedPlatform.sol`）。请把它们当作已知行为的依赖，但新合约怎么调用它们（尤其是 `DividendVault.setShare` / `depositReward`、`MigratorV2.migrate` 在池子已存在时的行为）属于本次范围。

### 2.3 不在范围内

`script/`（部署接线请看 §9）、`test/`、`src/**/mocks/`（含测试网用的 `TestnetAgentId`、`TestnetBlacklistQuote`）、`skill/`（CLI）、服务端和前端。`src/launchpad-v3/LaunchpadV3.sol` 之外的 V2 / stocks 目录。

---

## 3. 资金流

### 3.1 打新

```
mint / mintFor ── 本金 ──▶ FairMintPad（托管本金）      打新费 ──▶ 平台（PlatformFeeBucket，当笔）
                              │
       ┌──────────────────────┴───────────────────────┐
  withdraw（打满前任何时候，没有截止）            打满（同一笔交易）
  本金 − 撤出费 → 本人                            5 亿枚 + 全部本金 → MigratorV2
  撤出费 → 平台（bucket 拒收时记 owedFee，         → Pancake V2，LP → 0xdead
          任何人 flushFees 补交）
  sale 7 天没有进展：撤出费 = 0

发射后：池子买卖 1% 税（代币）→ HolderRewardHandler
        keeper process(minQuoteOut) 换成报价币 → 50% DividendVault（合格持有人）/ 50% PlatformFeeBucket
        没有合格持有人时 100% 给平台
```

- 每个币总量 10 亿：5 亿分成 10,000 份打新（每份 5 万枚），5 亿进池子。开盘价等于打新价。
- dev 在平台上下限内设：募集额 5–50 BNB 等值、单地址上限 0.25%–0.5%、出局线 30%–80%、打新费 1%–3%、撤出费 1%–2%。创建时 dev 至少自己打 1 份。没有截止时间。
- 「进展」计时：创建者那一笔记 `progressAt`、`markSold = sold`；之后只有 `sold ≥ markSold + STALE_STEP`（10 份）的打新才重启计时。`block.timestamp ≥ progressAt + 7 天` 时撤出费为 0（`exitFeeBpsOf`）。
- 报价币只收 WBNB，或 QuoteRegistry 里设了固定换算额、且 18 位小数的币（`_requireQuote`）；创建时按这个换算额锁定募集额，不再按参考池换算（§11 R2-1）。
- 只收 ERC-20 报价币（BNB 用 WBNB）；`_pullExact` 另外拒绝转账扣费的报价币。
- 合格持有人的权重 = `min(当前余额, 发射时基准)`；余额一旦低于 `基准 × 出局线` 就永久出局。

### 3.2 LaunchpadV3

```
内盘买入：quoteIn → 1% 平台手续费 + 买入税 → 剩余进曲线
          税：平台 = 成交额 × 0.5%；剩余 × dividendBps → DividendVault（没有合格持有人时并入接收地址）；其余 → 接收地址
内盘卖出：同上，按卖出税率
毕业：剩余代币 + realQuote → MigratorV2 → Pancake V2，LP → 0xdead；代币开始在池子买卖时收税
外盘：税（代币）→ PostGradTaxHandlerV3，按每笔方向累计平台部分
      keeper process(minQuoteOut) 换成报价币 → TaxRouterV3.distribute → 平台 / 分红 / 接收地址
接收地址推送失败：TaxRouterV3.owedOf[token] += 金额；任何人 release(token) 补发，仍失败则回滚、欠款保留
```

- 税率、分红比例、接收地址都在创建时写死（代币里的税率是 immutable，路由里的 `routeOf` 只能登记一次）。
- 接收地址必须在 RecipientRegistry 白名单里；下架只影响之后新发的币。
- 无税币等同 V2 无税轨（只收 1% 内盘手续费）。
- 报价币规则与打新相同：只收 WBNB 或 QuoteRegistry 里设了固定换算额的 18 位币，毕业额按这个换算额锁定。
- 内盘买入先分账、再更新买家份额（奖励的是交易前的持有人）；卖出先更新卖家份额、再分账（卖家拿不回自己的卖出税）。

### 3.3 GangRouter

```
用户 ──BNB / 报价币──▶ GangRouter ──buyFor / mintFor（trader = 用户）──▶ 核心
                           ◀──────── 核心因上限 / 打满截断退回的部分 ─────┘
                       ──多余部分（BNB 或报价币）──▶ 用户
```

- 路由只按本次调用的余额变化结算，别人误转进来的币不会被下一个调用者拿走（也取不出来）。
- 代币、份额、分红权重、Agent 门槛、单地址上限全部记在 `trader` 名下。
- 卖出、打新的卖回（撤出）、领取没有路由入口，只能本人直接调核心（理由见 §4.2）。
- 路由入口只在准入开启时可用：V3 要求 `agentGateEnabled`，打新要求该 sale 创建时快照了准入（理由见 §10 A-2）。

---

## 4. 角色与权限

所有带 owner 的合约都是 `Ownable2Step`。主网 owner 计划用多签（地址待定），keeper 是一个热钱包。

### 4.1 每个角色能做什么

| 合约 | owner | keeper | 其他特权调用方 | 任何人 |
|---|---|---|---|---|
| FairMintPad | `setMigrator`（一次性，且 migrator 必须绑定本核心）、`setRouter`、`setAgentGate`、`setV3Factory`、`setTwapWindow`、`setBridgePool`。除 `setRouter` 外**都只影响之后创建的 sale**：上限、门槛、手续费、出局线在创建时快照；列入的路由对所有打新中的 sale 都能 `mintFor` | — | 白名单路由：`mintFor`（只对有准入的 sale） | create、mint、withdraw；任何人：`flushFees` |
| FairToken | — | — | 只有发射台：`reclaim`（只在发射前）、`unlock(migrator)`（一次）、`setPair`（解锁后一次）；之后没有任何管理函数 | 转账（发射后）、`contractURI` / `metaURI` |
| HolderRewardHandler | `setPad`（一次性）、`setRouter`（DEX 路由）、`setKeeper`；可代替 keeper 调 `process` | `process(token, minQuoteOut)` | 代币：`notifyTax` | `syncShares` |
| LaunchpadV3 | `setMigrator`（一次性，且 migrator 必须绑定本核心）、`setPairFactory`（只用于创建时的参考池定价）、`setRouter`、`setAgentGate`、`setWalletCapEnabled`、`setV3Factory`、`setTwapWindow`、`setBridgePool` | — | 白名单路由：`buyFor`（只在准入开启时） | create、buy、sell |
| TaxLaunchTokenV3 | — | — | 只有发射台：`unlock(migrator)`（一次）、`setPair`（解锁后一次）；之后没有任何管理函数 | 转账（毕业后）、`contractURI` / `metaURI` |
| LaunchTokenV3（无税） | — | — | 只有发射台：`unlock`（一次） | 转账（毕业后）、`contractURI` / `metaURI` |
| PostGradTaxHandlerV3 | `setDexRouter`、`setKeeper`；可代替 keeper 调 `process` | `process(token, minQuoteOut)` | 代币：`notifyTax` | `syncShares` |
| TaxRouterV3 | `setLaunchpad`（一次性，同时设为 source）、`setSource` | — | 发射台：`register`（每个币一次）；source：`distribute`（只能付钱进来） | `release` |
| RecipientRegistry | `list`、`delist` | — | — | 查询 |
| GangRouter | 无 | — | — | 全部函数 |
| DividendVault（复用） | `setLaunchpad`、`setOperator`、`setExcluded`、`setMinimumShareBalance` | — | 发射台 / operator：`setShare`、`depositReward` 等 | `claim` |
| PlatformFeeBucket（复用代码，V3 / 打新共用一份新实例） | `setLaunchpad`、`setOperator`、`setFeeVault`、`setBurner`、`setKeeper`、`requestFlush` + 7 天后 `flushStuckQuoteToTreasury` | `collectPlatform`（80% 回购销毁 / 20% 金库） | operator：`notifyAccrual` | — |
| QuoteRegistry（复用代码，V3 / 打新共用一份新实例） | `setQuote`：启用 / 停用报价币、设固定换算额（15 BNB 合多少该币；只影响之后创建的币，换算额为 0 的币不能用来发币） | — | — | 查询 |

### 4.2 我们的信任假设（请验证或推翻）

1. **没有任何 owner 函数能拿走托管资金**：打新本金、曲线上的 `realQuote`、TaxRouterV3 里的欠款都没有提取 / 应急出口。**但 owner 能冻结**（内部审计 A-1、A-4 推翻了上一版「动不了」的说法）：
   - 撤掉核心在 PlatformFeeBucket 的 operator：V3 内盘买卖会 revert，V3 毕业前没有别的退出路径；打新的打新和打满发射会 revert，但卖回不受影响（2026-10-27 起撤出费改为不阻塞、记 `owedFee`，§14 R3-2）。这是新部署 bucket 并交给多签的原因。
   - 打新的卖回不依赖 DividendVault：分红合约拒绝写份额时卖回照常完成，发 `ShareWriteFailed`（§10 A-4 的退款版本已随退款一起删除，§14）。
2. **owner 被信任的地方**（主网用多签的原因）：
   - `setDexRouter` / `setRouter`（handler 的 DEX 路由）：keeper `process` 时会把累计的税币授权给它；恶意路由最多能吞掉 `minQuoteOut` 以上的部分。
   - DividendVault 的 `setOperator` / `setLaunchpad`：operator 能写分红份额，被恶意设置后可以截走之后的分红。`setLaunchpad` 更强：新的 launchpad 能对已登记的币再调 `registerToken` 改掉 `quoteOf`，从而转走**已经存入**的分红（内部审计 V3 I-1，上一版这里写的「已存入的不受影响」不成立）。
   - LaunchpadV3 的 `setAgentGate` / `setWalletCapEnabled` 是全局开关，会影响正在曲线上的币（与 V2 一致）；打新则在创建时快照，不受影响。
   - 核心的 `setRouter`：列入的路由能调 `buyFor` / `mintFor`。
   - DividendVault 的 operator 名单：撤掉 PostGradTaxHandlerV3 的 operator 会让毕业后的 V3 代币无法转账（K-7）；重新授权即恢复。运维规定不撤这个权限。
3. **一个被列入白名单的恶意路由最坏只能「用自己的钱替别人买 / 打新」**——前提是准入开启。准入关闭时它能把代币打给未来的池子地址、分走发射流动性（§10 A-2），所以现在路由入口在准入关闭时直接 revert。核心对路由只开放 `buyFor` / `mintFor`，付款方是 `msg.sender`（路由）。卖出等操作不开放，是因为毕业 / 发射前代币锁在核心里（`TransfersLocked`），如果核心替路由去扣用户的币，路由就能强卖任何人的持仓。测试 `test_v3_listedRouterOnlySpendsItsOwnQuote`、`test_fair_listedRouterOnlySpendsItsOwnQuote` 覆盖：交易者已为卖出给核心授权了代币和报价币，流氓路由仍拿不走任何东西。
4. **keeper 被信任设 `minQuoteOut`**：它可以给一个很低的值然后自己夹，损失的是该币累计的税。`process` 拒绝 `minQuoteOut == 0`。
5. **TaxRouterV3 的 source 只能付钱进来**：`distribute` 从 `msg.sender` 拉 `amount`，再按登记的路由拆分。一个恶意 source 能做的是把自己的钱按任意 `platformAmount`（≤ amount）分出去。

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
9. TaxRouterV3：对每个报价币 `balanceOf(router) ≥ Σ owedOf[token]`；`release` 只付该币自己的欠款。
10. 税率、分红比例、接收地址在创建后不能被任何人改。

GangRouter：

11. 每次调用结束后，路由在本次调用涉及的报价币上的余额回到调用前（误转进来的除外），BNB 余额为 0。

---

## 6. 已知问题与设计取舍

以下是有意的选择或已知限制。如果您认为某条的风险比我们判断的高，请照常报告。

| # | 内容 |
|---|---|
| K-1 | **非 WBNB 报价币按多签设的固定换算额锁价**：不再读参考池（上一版的「参考池现价可被闪电贷拉偏」在第二轮审计里被证明影响远超预期，已改，§11 R2-1）。剩下的风险是换算额过时：BNB 涨跌后，新币锁定的募集额 / 毕业额按 BNB 计会偏离 5–50 BNB / 15 BNB。运维规定：多签在 BNB 价格偏离换算额超过 10% 时更新；只影响之后创建的币。 |
| K-2 | **税只对官方池子收**：别人另建交易对可以绕开税（同 V2）。 |
| K-3 | **打新的出局按余额判断**：转去另一个钱包、拿去加池子、放进别的合约，余额都会下降，跌破线就永久出局，哪怕同一笔交易里又转回来。网站和 CLI 会提前提示。 |
| K-4 | **提前建好的池子**：有人在发射 / 毕业前用同名代币建好 Pancake 池子并打入报价币时，MigratorV2 直接沿用这个池子：把代币和报价币转进去后 `mint`（不先 `sync`）。对方打入（或打入后 `sync` 进储备）的报价币等于送给锁死的 LP，开盘价略高于打新价 / 毕业价。代币发射前锁转账，直接打新时 `msg.sender` 就是持有人，路由入口又要求准入开启（池子拿不到 Agent ID），所以对方打不进代币（上一版漏了路由入口这条路，见 §10 A-2）。 |
| K-5 | **sale 可能永远打不满**：没有截止时间和退款，打新的人只能卖回退出（7 天没有进展后免撤出费，只损失打新费）。任何人都能打完剩下的份数，没有办法永久阻止发射（最后一笔超出剩余份数时自动截断）。 |
| K-6 | **打满那一笔要建池子**，gas 约 250 万–390 万，由最后一个打新的人付。 |
| K-7 | **转账钩子里写分红份额失败时，两个 handler 的处理不同**：HolderRewardHandler（打新）用 `try/catch` 吞掉分红合约真正拒绝写入的错误，不卡转账；但调用方把 gas 卡到让这次调用耗尽 gas 时会 revert（§10 A-5）。恢复后已退出的地址仍按旧份额累计，直到有人为它调 `syncShares`，所以分红合约出过问题后要在链下对所有打新地址补一次同步；已出局 / 被排除的地址每次同步都重写为 0，恢复后自动纠正。PostGradTaxHandlerV3 与 V2 一致，不吞错误：如果 owner 撤掉了它在 DividendVault 的 operator 权限，毕业后所有 V3 代币的转账（含池子买卖）都会 revert。`DividendVault.setShare` 除了权限检查之外没有会 revert 的分支，所以这只会由 owner 自己的操作触发，而且重新授权后立刻恢复，不是永久冻结；运维规定不撤这个权限。V3 有意不改成 `try/catch`：保持与已上线、已审计的 V2 一致，也避免 §8 #9 所说的风险。 |
| K-8 | **G-01 的剩余窗口**：owner 在 DividendVault 排除一个地址后，在该地址下次转账前它仍会按旧份额累计。运维规定：排除操作必须和 `handler.syncShares(token, user, 0)` 放在同一批交易里。 |
| K-9 | **PlatformFeeBucket 的应急出口**（V2 审计 G-03）：owner 申请后 7 天可把卡住的报价币整笔转到金库，绕过 80/20 拆分。原样复用，知悉。 |
| K-10 | **V3 内盘的分红部分在没有合格持有人时并入接收地址**；打新发射后的分红部分在没有合格持有人时并入平台。两者不同是因为 V3 里剩余的税本来就归接收地址。 |
| K-11 | **路由不提供 sweep**：误转进 GangRouter 的代币 / 报价币会永远留在那里。 |
| K-12 | **报价币**：链上强制只收 WBNB 和 QuoteRegistry 白名单里的 18 位币（§10 A-3）。加新报价币前由多签确认：标准 ERC-20、转账不扣费、没有回调。打新另外在扣款时拒绝转账扣费；V3 和 TaxRouterV3 按实际到账等比缩小各部分。 |
| K-13 | **非官方池子也会累计 V3 分红份额**（migrator 已在部署时排除，§11 R2-4）：只有官方池子被设为 0。别人另建的交易对（其他 DEX、Pancake V3 池子）持有代币就有份额，任何人都能用 `claimFor` 把分红推进去，留在那里或被 `skim` 走。运维：发现这类池子后，owner 在 DividendVault 排除它，并在同一批交易里 `handler.syncShares(token, pool, 0)`。打新不受影响：非打新地址的基准为 0。 |
| K-14 | **接收地址永久收不了款时，欠款会一直留在 TaxRouterV3**：例如合作方金库被 USDT 拉黑。接收地址发币后不可改是产品承诺，没有改向出口。 |
| K-15 | **keeper 每次 `process` 会把该币累计的税一次卖光**，不能只卖一部分。累计越多滑点越大，而且这一笔可以被夹：攻击者在 keeper 的 `minQuoteOut` 容忍范围内先卖后买，最多拿走约「容忍度 × 这一批的卖出所得」（§11 R2-2）。运维规定：keeper 高频小额处理，`minQuoteOut` 容忍度不超过 1–2%，通过私有 RPC 发交易。`dexRouter` 只支持 Router02 的 fee-on-transfer 直连路径；经中间合约转一手的路由会触发带税转账，在 `process` 持锁时 revert。 |

### 6.1 V2 审计结论在新合约里的处理

| V2 发现 | 新合约 |
|---|---|
| G-01 被排除地址保留旧份额继续分红 | 受影响，已修：HolderRewardHandler 和 PostGradTaxHandlerV3 对被排除地址的目标份额一律为 0（`_sync` / `_syncShares` / `eligibleShare`）。测试 `test_auditG01_excludedHolderZeroedOnSync`。剩余窗口见 K-8。 |
| G-02 `totalShares == 0` 时存入的钱永远卡住 | 不受影响：HolderRewardHandler 和 TaxRouterV3 只在合格份额 > 0 时存入分红；否则打新那一半给平台，V3 那份给接收地址（没有接收地址的币给平台）。 |
| G-03 `flushStuckQuoteToTreasury` 绕过 80/20 | 原样复用，见 K-9。 |

---

## 7. 测试与验证

```sh
forge build --sizes
forge test                    # 286 个通过（含 V2 原有用例和 invariant；审计回归套件继承基础套件，基础用例会再跑一遍）
BSC_RPC_URL=<主网 RPC> forge test --match-path test/fair-mint/FairMintFork.t.sol   # 主网分叉
```

| 测试文件 | 个数 | 覆盖 |
|---|---|---|
| `test/fair-mint/FairMint.t.sol` | 33 | 参数上下限、报价币换算、上限与最后一笔截断、卖回、打新费当笔进平台、7 天免撤出费、没有截止时间、本金托管恰好等于持仓、发射价格、池子被提前建好、奖励权重 / 出局 / 上限、分账、权限、分红合约出错后的补救、G-01 |
| `test/fair-mint/FairMintFork.t.sol` | 3 | BSC 主网分叉：真实 Pancake 整轮（WBNB）、USDT 报价经 V3 桥接、池子被提前建好并 `sync` |
| `test/launchpad-v3/LaunchpadV3.t.sol` | 14 | 创建规则、下架只拦新币、内盘买卖分账（含不对称税率）、没有持有人时分红并入接收地址、推送失败记欠款 / 补发、外盘按每笔方向记账、无税币、门槛与上限、G-01、各合约权限 |
| `test/fair-mint/FairMintAudit.t.sol` | 8 | 内部审计回归：路由入口须开准入、卖回不依赖分红合约（且发 `ShareWriteFailed`）、卖回不依赖 bucket（`owedFee` / `flushFees`）、计时要净增份数才重启、报价币白名单 + 18 位、migrator 绑定检查、收币方卡 gas 不能留下过期份额、分红合约真拒绝时仍不卡交易 |
| `test/launchpad-v3/LaunchpadV3Audit.t.sol` | 5 | 内部审计回归：`buyFor` 须开准入、报价币白名单 + 18 位、migrator 绑定检查、卖家拿不回自己的卖出税、其他持有人照常分到 |
| `test/launchpad-v3/LaunchpadV3Fuzz.t.sol` | 3 | fuzz（各 1000 轮）：每笔买 / 卖恰好拆成曲线、1% 手续费、税，平台拿成交额 0.5%，上限 / 毕业截断只按实付收费 |
| `test/invariant/CoreInvariants.t.sol` | 8 条不变量 | V3、打新、共用 registry / bucket、GangRouter 放在一起随机操作（发币、直接 / 经路由买卖、打新、卖回、跳时间（最多 8 天，覆盖免撤出费）、打满、毕业、池子交易、keeper 处理、拉黑接收地址、补发），每步后检查 §5 的资金不变量和 bucket / 分红合约的偿付能力。CI 跑 24 × 50；发布前压力跑 400 轮 × 80 步（32,000 次调用）全过 |
| `test/router/GangRouter.t.sol` | 19 | BNB / 报价币两种路径、交易者拿币、门槛和上限按交易者、分红权重归交易者、截断退款、经路由毕业 / 发射、截止时间（路由交易的 `deadline` 参数）、只有白名单路由能代买、流氓路由只能花自己的钱、卖回的钱给交易者本人 |

另外：

- 本地 anvil 测试网 fork 上按主网顺序跑过部署（V3 → 打新共用 registry / bucket → 路由）、路由冒烟、V3 整轮（毕业 + 外盘税 + 补发）和打新整轮（100 个地址打满 + 发射 + 分账 + 领取），全部通过（`script/LaunchpadV3TestnetE2E.s.sol`、`script/FairMintTestnetE2E.s.sol`）。
- BSC 主网状态上做过部署的进程内模拟（不广播）：不设 `OWNER` 时拒绝；设了之后接线检查全部通过。
- BSC 测试网实部署（第 3 套，`cf96281`）：`docs/TESTNET-CORE-ROUTER-2026-10-26.md`（GangRouter `0x1ABd2da0A7aB9eb4797FCC36a8aC19a42382daE1`、V3 核心 `0x2202F7898e7e0b77d2Bb46d661d88d1Ffa7D8330`、打新核心 `0x69bfa8459b01e3705Aa8C0397557E537F2024F53`）。
- 运行时字节码（`1bcc84f`）：LaunchpadV3 22,317 B，FairMintPad 16,533 B，HolderRewardHandler 7,127 B，GangRouter 4,135 B。

**测试的不足**：invariant 测试用的是仓库里简化的 MockPair（不检查 K、不收 0.25% 手续费），池子相关的经济攻击（夹子、闪电贷）由第二轮审计员用仿真的 Pancake V2 池子另外验证过（§11），那些 PoC 没有并入仓库。

---

## 8. 希望重点看的地方

1. **FairMintPad 的记账**：多个 sale 共用同一个报价币时的隔离（§5 #1，含 `owedFee`）；卖回时撤出费的取整（到手 + 撤出费 = 本金）；7 天计时的边界（`>=`）和 `markSold` 的更新；`toUint16` / `toUint128` 的截断。
2. **最后一笔打满即发射**：`_mint` 里在同一笔交易中调用 `_launch` → MigratorV2 → Pancake。有没有办法让发射失败从而卡住 sale，或者在建池时重入。
3. **LaunchpadV3 的费用计算**：`_prepBuy` / `_applyFees` / `_recomputeFee` 在单地址上限或毕业截断时重新算费用和退款，平台部分按成交额而不是按税的比例（`_platformPart`）。
4. **转账钩子里的外部调用**：两个代币每次转账都会调 handler 的 `syncShares` 和 DividendVault。请检查重入、gas 耗尽，以及能否通过让钩子失败来阻止卖出或领取。
5. **出局与基准**：HolderRewardHandler 的出局判断能不能被绕过（例如先收别人的筹码再卖，或用 `reclaim` 的时机），以及池子 / migrator / 核心的基准是否确实为 0。
6. **TaxRouterV3 的欠款**：多个币共用同一个报价币和同一个接收地址时，`owedOf` 和 `release` 的隔离；接收地址是会回调的合约时的重入。
7. **GangRouter**：`fairMintBNB` 用 `previewMint` 预先算好付款额，再由核心按同一状态扣款，两者是否可能不一致；`_settle` 的余额差结算；WBNB `withdraw` 回调只接受 WBNB。
8. **`buyFor` / `mintFor` 的身份**：门槛、上限、分红权重、事件里的买家都用 `trader`，付款和退款用 `msg.sender`。有没有地方混用。
9. **HolderRewardHandler 的 `try/catch` 能否被卡 gas 利用**：卖家把 gas 卡到让 `dividendVault.setShare` 在 `try` 里耗尽 gas，被 `catch` 吞掉后，转账用剩下的 1/64 gas 走完，分红合约里就留着卖出前的份额，继续领分红。我们按 63/64 规则估算，份额更新失败后剩下的 gas 只有几百，不够走完 `_sync(to)`、事件和 Pancake 的后续步骤，实际难以利用，请确认。如果能利用，我们修打新这边（例如失败时 revert，或检查剩余 gas），V3 不受影响（不吞错误）。**内部审计结论**：卖家这一侧实测不能利用，但余量只有约 500 gas；收币方这一侧能利用。已修，见 §10 A-5。

---

## 9. 主网部署计划

- 部署脚本：`script/DeployLaunchpadV3.s.sol`、`script/DeployFairMint.s.sol`、`script/DeployGangRouter.s.sol`。主网广播分别需要 `LAUNCHPAD_V3_MAINNET_OK=true`、`FAIR_MINT_MAINNET_OK=true`、`GANG_ROUTER_MAINNET_OK=true`，审计通过前不会设置。
- 环境变量：`OWNER`（多签）、`USDT_PER_15_BNB`（主网 USDT 的固定换算额，按当时价格算好，18 位小数）。
- 部署前：核对主网上链接的 PoolCheck 库（`0xd2B1…bDb3`，按地址链接、delegatecall 调用）的字节码与本仓库源码一致。
- 顺序：`DeployLaunchpadV3` → `DeployFairMint`（带上前一步输出的 `QUOTE_REGISTRY` / `PLATFORM_BUCKET`，两者共用）→ `DeployGangRouter`。
- owner：主网必须设 `OWNER`（多签），否则脚本拒绝。部署后所有合约进入待接受状态，多签对每个合约调用 `acceptOwnership()`（`Ownable2Step`）。`DeployFairMint` 必须在多签接受之前跑，那时 registry / bucket 还归部署钱包，能加 operator。
- 接线顺序：分红合约、税务路由、handler、bucket operator、接收地址白名单、准入都设好之后，最后一步才 `setMigrator`，核心从这一刻起才能发币。
- keeper：独立热钱包，只有 `process` 和 bucket 的 `collectPlatform` 权限。高频小额处理外盘税，`minQuoteOut` 容忍度不超过 1–2%，经私有 RPC 发交易（K-15）。
- PlatformFeeBucket 和 QuoteRegistry 新部署一份、V3 和打新共用；bucket 的金库和回购销毁合约与 V2 那份相同（脚本从 V2 bucket 链上读取）。主网 QuoteRegistry 上线时只启用 USDT，按 `USDT_PER_15_BNB` 固定换算，多签在 BNB 价格偏离超过 10% 时更新（K-1）。V3 的 DividendVault 排除 migrator。DividendVault 和 MigratorV2 每个核心各一份。
- 接收地址白名单：上线时只列合作方的主网金库（地址待定）。
- V2 自己的 bucket / registry / 分红合约 / 发射台目前 owner 是普通钱包 `0x4EEd…`，同样能冻结 V2 内盘。建议多签建好后由它发起 `transferOwnership`、多签接受；不挡这次上线。

审计报告里的问题修复后，我们会在同一个 PR 上提交修复，并在这份文档里逐条记录处理结果。

---

## 10. 内部审计（2026-10-26）

外部审计前，我们让三个互相独立的审计员各审一块（打新、V3、路由与部署接线），只给代码和本文档，要求把文档里的说法当作待推翻的假设，每个发现都用 Foundry PoC 实测。审计对象是 `5854a35`，修复在 `36d8a7e`。没有发现能直接偷钱的严重 / 高危问题。

| ID | 来源 | 严重度 | 问题 | 处理 | 回归测试 |
|---|---|---|---|---|---|
| A-1 | 路由 / 接线 | 中 | 主网计划复用 V2 的 PlatformFeeBucket，owner 是普通钱包。核心在 V3 内盘每笔买卖、打新撤出和发射时都要调它，没接好 operator 或被撤掉就 revert。部署脚本在接好之前就开放了核心，打新的人会被锁到截止。 | 新部署一份 bucket（和 QuoteRegistry），V3 与打新共用，owner 为多签；主网必须设 `OWNER`；所有接线做完后最后 `setMigrator` | 测试网 fork 与主网模拟部署 |
| A-2 | 打新 / 路由 | 中（有条件） | 准入关闭时，白名单路由能以 `trader = 未来池子地址` 打新 / 买入，把代币送进池子；攻击者再打入报价币先拿第一份 LP，发射时分走约一半流动性（PoC：250,024,999 枚）。GangRouter 总用 `msg.sender`，当前部署不可利用。 | `mintFor` 要求该 sale 有准入，`buyFor` 要求准入开启 | `test_audit_mintForNeedsGate`、`test_audit_buyForNeedsGate` |
| A-3 | 打新 / V3 | 中 | 报价币不限：6 位小数的报价币让每股分红取整为 0，钱进了分红合约却没人能领；转账扣费 / 回调型报价币也能进来。 | `create` 只收 WBNB 或 QuoteRegistry 已启用的 18 位币 | `test_audit_quoteWhitelist`（两套） |
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
| R2-1 | 白拿收益 | 中 | 白名单里没设固定换算额的报价币按 dev 自选参考池的**现价**锁定募集额 / 毕业额。同一笔交易里闪电贷拉偏浅池子，15 BNB 的募集可以锁成真实价值的万分之一（PoC：成本约 0.005 BNB），一伙人低价打满、拿走 50% 筹码后砸给后来的买家。主网计划里 USDT 正是按池子换算，可以被利用。 | 非 WBNB 报价币必须有固定换算额（`graduationAmount > 0`），主网 USDT 由 `USDT_PER_15_BNB` 设定、多签维护 | `test_create_refPoolAgainstWbnb`、`test_audit_quoteWhitelist`（两套）、主网分叉 `test_fork_usdt_raiseTracksBnbPrice` |
| R2-2 | 白拿收益 | 中（金额小） | keeper 的外盘税一次性卖出可以被夹：在 keeper 的 `minQuoteOut` 容忍范围内先卖后买。15 BNB 池子、1% 税时，容忍 3% 赚 0.008 BNB，10% 赚 0.23 BNB；容忍度大时前置卖单还能让 keeper 的交易 revert。 | 运维：高频小额、容忍度 ≤ 1–2%、私有 RPC（K-15） | — |
| R2-3 | 白拿收益 | 低（有条件） | 如果 V3 和打新共用同一个 DividendVault，V3 handler 的 `syncShares` 能给打新代币写份额，绕过出局规则。 | 当前不可达：每个核心一个 DividendVault，而 DividendVault 只认一个 launchpad 登记代币。部署时保持分开 | — |
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

