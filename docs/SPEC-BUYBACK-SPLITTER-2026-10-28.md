# 规格 · GangBuybackSplitter（dev 税按比例回购销毁）

- 日期：2026-10-28 Asia/Shanghai
- 作者：Claude（产品规格 + 合约设计）
- 代码：`src/gang/GangHandlerAdmin.sol`（handler 的 owner）、`src/gang/GangBuybackSplitterFactory.sol`、`src/gang/GangBuybackSplitter.sol`（克隆的实现）、`src/gang/interfaces/IGangRecipientModule.sol`（模块通用接口）；部署脚本 `script/DeployGangBuybackSplitterFactory.s.sol`；单测 `test/gang/GangBuybackSplitter.t.sol`（26 个）；CLI `gang create … --buyback <pct> [--buyback-to <addr>]`、`gang buyback …`；keeper gangfun-server `keeper/keeper-module-work.sh`
- 测试网记录：`docs/TESTNET-BUYBACK-SPLITTER-2026-10-28.md`
- 来源：dev 需求（2026-10-28，经用户转达），用户确认：
  1. 只针对新币：dev 拿到的交易税，一部分回购，一部分到 dev 的地址；
  2. 回购的币销毁；
  3. 比例以后可以调整（由谁触发，按本文 §3、§4 的建议）。
  4. 不是每个 dev 都要：不需要的照旧把接收地址填自己。
  5. dev 用 CLI 建币时自己选要不要这个模式，平台不用逐个处理；以后可能还有别的回购合约，要能扩展（§1.1）。

---

## 1. 为什么是一个单独的接收合约

已上线的合约都不能改：`GangTaxHandler`、`GangLaunchpad`、`GangToken`、`SharedDividendVault` 不是代理，互相引用的地址也写死。只有 `GangRouter`、`GangPadRegistry` 可升级，与税的分配无关。

所以回购只能放在 **接收地址这一端**：V3 税收币的接收地址（recipient）本来就可以是白名单里的合约。handler 每卖完一块税，就把 recipient 那份报价币用普通 `transfer` 打过去：没有回调，也不带币地址；转账失败记为 `owedOf`，任何人可以 `release`。回购合约收下这笔报价币，按比例拆分。

一个合约只服务 **一个币**：handler 打款时不带币地址，一个共用合约分不清收到的报价币属于哪个币。所以想要回购的 dev，每个币用一个；不想要的 dev 不受任何影响。

### 1.1 自动加白与扩展：管理合约 + 工厂 + 通用接口

recipient 只能是创建者自己或 handler owner `list` 过的地址（`CurveLogic.sol:128`），这条改不了。为了不让多签逐个 list：

```
多签 ──owner──▶ GangHandlerAdmin ──owner──▶ GangTaxHandler（不可改）
                    ├─ 允许的工厂（多签 setFactory 增删）
                    │    ├─ GangBuybackSplitterFactory（buyback-burn-v1）
                    │    └─ 以后的模块工厂 / 新版本
                    └─ moduleOf[地址] = 克隆它的工厂；modules() 全部列表
```

- **GangHandlerAdmin**（不可升级，越小越好审）：多签把 handler 的 owner 转给它（`Ownable2Step`：多签 `handler.transferOwnership(admin)`，再 `admin.exec(acceptOwnership())`），多签仍是它的 owner。三个入口：`exec(data)` 原样转发调用 handler（list / delist、换 keeper、换 DEX router，以及把 handler 交回：`exec(transferOwnership(safe))` 后多签 accept）；`setFactory(f, allowed)`；`listModule(addr, label)` 只允许工厂调，记下 `moduleOf`。模块列表只增不减，`modulesFrom(from, count)` 分页读。
- **换新版管理合约**：旧管理合约 `exec(transferOwnership(新))`，新管理合约 `exec(acceptOwnership())`，再 `setFactory`。旧管理合约加白过的模块仍在 handler 白名单上（建币时就定了），但不在新管理合约的 `modules()` 里；keeper 要继续服务它们，用 `MODULES` 补上。部署脚本自动识别这种情况（批量的第一笔改成发给旧管理合约）。
- **工厂**：每种模块（或每个版本）一个，只给自己克隆出来的合约申请加白。新逻辑 = 新工厂 + 多签 `setFactory`，不用再动 handler；旧工厂可停用，它克隆出去的合约不受影响（币的 recipient 建币时就定了）。
- **已发出的模块永不升级**：持币人信任的是「这个币的规则不会变」，新逻辑只用于新币。
- **IGangRecipientModule**：`moduleType()`、`dev()`、`token()`、`bind(token)`、`previewWork() → (due, minOut)`、`work(minOut)`。keeper 只认这个接口（到点就 `work`），CLI / 前端用 `moduleOf` + `moduleType()` 认出模块，新种类不用改 keeper。
- 边界：新模块要先审再允许；模块逻辑只能在报价币到账以后发生（handler 是普通转账，无回调、不带币地址）；换新的 pad / handler 时再部署一套管理合约。

## 2. 资金流

```
池子买卖交税 ─▶ GangTaxHandler 分块卖成报价币
                 ├─ 平台 0.5% 成交额
                 ├─ 持币分红（dividendBps）
                 └─ recipient 部分 ─▶ GangBuybackSplitter
                                         ├─ buybackBps ─▶ buybackLeft ─▶ burnChunk：池子里买入 ─▶ 0xdead
                                         └─ 其余        ─▶ dev（推送失败记为 devOwed，releaseDev 补发）
```

- **拆分时机**：报价币到账时合约不会被调用，所以等到下一次有人碰它时才拆：`split`、`burnChunk`、`releaseDev`、改比例都会先拆。拆分按 **当时的比例** 算；每次改比例前都先拆一次，所以改之前到账的报价币仍按旧比例。
- **回购走正常买入**：先从交易对买到合约自己，再转给 0xdead。代币对 0xdead 免税，如果直接买给 0xdead 就绕过了买入税；现在这样，回购和普通买单一样交买入税，平台和持币人照常分到。

## 3. 比例调整（只有 dev）

| 操作 | 何时生效 |
|---|---|
| 提高（或不变） | 立即生效；同时取消任何待执行的下调 |
| 下调 | 申请后等 `LOWER_NOTICE` = 3 天，由任何人调用 `applyBuybackBps` 执行；到期后 `CUT_TTL` = 7 天内没人执行就作废 |
| 再次申请下调 | 覆盖前一次申请，3 天重新计算 |

- 提高对持币人有利，所以不用等；下调对持币人不利，留 3 天让大家看见（`BuybackBpsProposed` 事件，`pendingCut()` 可查）。
- 作废期防止一个很久以前的申请被留着、等到没人注意时再执行。
- 比例范围 0–10000。0 = 全给 dev，10000 = 全部回购。

## 4. 回购（`burnChunk`，任何人可调）

照搬 GangBond 的分块回购，参数和计算逐字一致，两边要一起改：

- 两块之间至少隔 `CHUNK_GAP` = 4 分钟（v3；不到时间回滚 `BurnTooSoon`，`previewBurn` / `previewWork` 都报不能买）。v1、v2 是每个区块最多一块，见下面「拉盘后卖给回购」；
- 每块最多花掉交易对报价币储备的 `CHUNK_MAX_BPS` = 0.5%；
- 与交易对自己的 TWAP 比：窗口 `TWAP_WINDOW` = 10 分钟，现价比均价高出 `MAX_PRICE_RISE_BPS` = 2% 以上就不买（返回 (0, 0)，不回滚）；
- 超过 2 倍窗口没人调用，观测点从头开始，那一次只记观测点。

所以谁来调都无法在 2% 带宽以外夹它，`minTokensOut` 可以填 0。

**拉盘后卖给回购（GangBond 审计 2026-10-29 H-1，v3 已修）**：价格保护只看「现价 ≤ 10 分钟均价 × 1.02」。攻击者把价格拉高并维持 10 分钟，均价追上来以后，v1 / v2 每个区块都能买一块，攻击者每块卖回同样数量，0.45 秒一块，回购余额几秒钟就被高价买光。v3 两块之间至少 4 分钟（keeper 每 5 分钟一跑，正常回购速度不变），攻击者要把高价维持到整笔回购买完（20% 池子的积压约 2 小时），期间所有持币人都能按高价卖给他。splitter 的积压平时只有 keeper 两轮之间的税，但价格持续上涨（自然或人为）时回购会暂停、积压会变大，所以同样要修。测试：`test_burn_oneChunkPerGap`、`test_burn_pumpAndHoldGetsOneChunkPerGap`（同样的攻击一分钟内 v3 只买 1 块；去掉间隔是 11 块）。keeper 定时调用即可（§6）；dev 或任何人也可以自己调。毕业前调用回滚 `NotTradable`（还没有交易对，而且毕业前根本不收税）。

`previewBurn()` 返回这一次会不会买、花多少、销毁多少（已扣买入税）。

**报价币对「转进交易对」收税（GangBond 复审 L-1，v4 代码已修、未部署）**：v1–v3 按 `quoteIn` 算买入量，交易对实际收到的少于 `quoteIn`，每块都过不了 Pancake 的 K 检查，回购那一份永远卡在合约里（`sweep` 不能取报价币）。v4 先转账，再按交易对的报价币余额减储备（实际收到的）算买入量；`minTokensOut` 是按整块 `quoteIn` 预估的（预览看不到转账税），按「实际收到 / `quoteIn`」缩小后再比，否则 keeper 的 `minOut` 每次都会 `Slippage`。对每笔转账都收税的报价币，拆分账目照样对得上（dev 那份到手少了报价币自己的税），pad 本来也拒绝这种报价币（首次买入 `FeeOnTransferQuote`）。只对转进交易对收税的报价币能过 pad 的检查，所以 v4 修的是这一种。主网现有回购币都用 WBNB / GANG，不受影响；CLI 0.16.3 起 `--buyback` 只接受 WBNB、GANG 和 QuoteRegistry 里的报价币。v4 等下次回购合约有别的改动时一起部署。测试：`test/gang/GangBuybackSplitterPairTax.t.sol`。

`previewWork()`（模块接口）：能买时 `due = true`、`minOut` = 预览销毁量 − `WORK_SLIPPAGE_BPS`（1%）；不能买时，只有这次调用会记录或推进 TWAP 观测点才 `due`（`minOut` 0）——这一步正是价格检查恢复所需要的；没东西可买、没毕业、距上一块不到 `CHUNK_GAP` 时都不 due。`work(minOut)` = `burnChunk(minOut)`。

**最低金额**：拆分后的回购余额低于交易对报价币储备的 `WORK_MIN_BPS`（0.05%）时不 due——买和推进观测都不报。毕业后每笔卖出的 swap-back 都给回购合约打一点，没有门槛的话 keeper 每 10 分钟左右就要为一点点钱发一笔（约 20–35 万 gas）。攒够以后第一次调用记观测点（停了超过 20 分钟，观测重来），10 分钟后开始买。`burnChunk` 本身仍收任何金额，谁都可以手动调。

门槛也适用于分块买到最后的零头：一大笔回购按 0.5% 储备一块地买，最后剩下的若低于门槛，keeper 就停下，等后面的税把余额补过门槛再接着买。币不再有交易时，这点零头会一直留在回购合约里（仍记在 `buybackLeft`，不会给 dev），要清掉只能有人手动调 `burnChunk`。这是有意的取舍：为零头单独发一笔交易不划算。

## 5. 其它规则

- **收款地址（payee，v2）**：回购以外的那份打给 `payee`，不再固定是 dev。建币时 `--buyback-to <地址>` 指定（工厂 `create(bps, salt, payee)`，0 = dev）；之后 dev 随时 `setPayee` 更换，**立即生效**（这是 dev 自己那份钱，不影响持币人，所以不设公告期），发 `PayeeSet` 事件。更换前到账的报价币先按旧地址拆分；欠款（`devOwed`）和 `sweep` 都付给当时的 payee。比例仍只有 dev 能改。v1 回购合约（主网第一个工厂 `0x6bcd…8546` 克隆的，`moduleType` = `buyback-burn-v1`）没有 payee，永远付给 dev；v2 的 `moduleType` 是 `buyback-burn-v2`，v3（加了 `CHUNK_GAP`）是 `buyback-burn-v3`，也有 payee。CLI、indexer、网站都要认这三种。代码里的 v4（`buyback-burn-v4`，按交易对实际收到的报价币计价，见 §4）还没部署，部署时它们要再认 v4。

- **绑定**：`bind(token)` 任何人可调，只能绑一次。要求：V3（curve）币、创建者是 dev、handler 里这个币的 recipient 是本合约。设成任何人可调，是为了防止 dev 故意不绑、再用 `sweep` 把报价币拿走。
- **`sweep(asset)`**：绑定后，把绑定报价币以外的任何资产全部转给 payee（v1：dev）（别的币把它填成 recipient、用别的报价币付的税，或者别人误转进来的）。绑定前不能 sweep。用绑定报价币付的税，不管来自哪个币，都按比例拆分。
- **收款方收不到款**：报价币把 payee（v1：dev）拉黑时，推送失败不回滚，那部分记为 `devOwed`，回购照常进行；`releaseDev`（任何人可调）补发给当时的 payee，仍收不到时回滚，欠款不会丢；v2 的 dev 也可以换一个能收款的 payee 再补发。
- **余额被扣**：报价币余额少于账上应有的数（被没收、rebase）时，下一次拆分把差额按比例从回购余额和 dev 欠款两边扣（`Shortfall` 事件），合约继续能用。
- **没有 owner、不可升级**：EIP-1167 克隆，实现合约由工厂部署（`pad` / `taxHandler` / `factory` 是实现里的 immutable，所有克隆共用）；`dev` 和初始比例由工厂在克隆的同一笔交易里 `initialize`（只有工厂能调、只能一次，实现合约本身不能初始化）。只读 pad 和 handler 的公开 view，只和这个币的交易对交易；不需要 pad、代币、分红金库、handler 给它任何权限。

## 6. 接入步骤

**平台，一次性**（每个 pad 一次；以后加新模块只做第 2 步——脚本设 `HANDLER_ADMIN` 只部署新工厂，批量只有 `setFactory`，并列出管理合约上仍允许的其他工厂和停用它们的可选交易，停不停由多签决定，停用后它们克隆出去的合约照常工作）：

| 步骤 | 做什么 |
|---|---|
| 1 | `script/DeployGangBuybackSplitterFactory.s.sol`（`GANG_PAD`）部署 GangHandlerAdmin（owner = handler 现在的 owner，即多签）和工厂，核对接线（admin 的 handler、工厂的 pad / admin、实现合约的 pad / handler / factory、admin 的 owner），打印还要做的多签批量 |
| 2 | 多签按顺序执行：`handler.transferOwnership(admin)`、`admin.exec(acceptOwnership())`、`admin.setFactory(factory, true)`。之后多签对 handler 的操作都经 `admin.exec`；运维文档里直接调 handler 的步骤相应改写 |
| 3 | keeper：gangfun-server `keeper/keeper-module-work.sh` 装进 cron（每 5 分钟） |

**dev，每个币**（CLI 一条命令，重跑续接）：

```
gang create --name … --symbol … --buy-tax 3 --sell-tax 3 [--dividend 50] --buyback 50 [--dev-buy … [--bond …]]
```

| `launch.stage` | 交易 |
|---|---|
| `buyback-splitter` | `factory.create(bps, salt)`：在 `predict(dev, salt)` 克隆、`initialize(dev, bps)`、经 admin 加白，一笔完成（只有 Agent 能调，和建币一样）。CLI 每次启动随机取 salt 记进 plan，克隆前就知道地址；同一钱包并行几个启动也不会互相认错 |
| `create` | `pad.create(…, recipient = 回购合约)` |
| `bind` | `splitter.bind(token)` |
| `dev-buy` / `bond` | 与原来的一键发射相同 |

不加 `--buyback` 的 dev 完全不经过这些合约，税直接给自己。之后：`gang buyback status|set|apply|bind|release --token …`；`gang v3 info` 在 `buyback` 下显示状态。

续接规则：克隆还没上链时重跑，提示等待或 `--restart`；克隆后 `--buyback` 改了比例，提示原比例或 `--restart`（建币后用 `gang buyback set`）；一次启动保持开始时的模式——建币后才加 `--buyback`、或克隆后去掉它，都拒绝（不会重新克隆、也不会建第二个币）。

**keeper**：`keeper-module-work.sh` 每个 pad 从 `taxHandler().owner()`（管理合约）分页读模块（`modulesFrom`，每页 `MODULE_PAGE`），每个模块调一次 `previewWork()`，到点就 `work(minOut)`；什么时候调、`minOut` 多少都由模块决定，keeper 不记状态。扫描不加锁、超过 `SCAN_MAX_SEC` 就停（下一轮从列表另一处开始）；只有发送前才拿共用的 keeper 锁，并在锁内重新 `previewWork`，所以模块再多也不会长时间挡住 tax-process。仍是每 5 分钟（合约 20 分钟没人调会重置观测，10 分钟一跑可能刚好越线）。

- 克隆不用逐个核对代码：工厂只克隆它自己部署的实现，实现的 pad 是工厂的 pad；多签在 `setFactory` 前核对工厂即可（部署脚本的 `check`）。
- 不再从分红中排除：回购在同一笔交易里先买到合约、再转给 0xdead，交税时（`notifyTax`）合约的份额还没写，转走后份额归零，分不到分红（单测 `test_burn_noDividendWithoutExclusion`）；排除只省一点 gas，平台不用碰分红金库。
- 已经发出去的币不能改接收地址（handler 的 route 写一次就不能改），所以只适用于新币。

## 7. 风险与边界

- **比例是 dev 的承诺，不是平台的**：dev 可以在 3 天公告后把比例降到 0。前端应展示 `buybackBps` 和 `pendingCut()`。
- **白名单会变长**：任何 Agent 都能调工厂克隆（只付 gas），每个克隆都会加进 handler 的白名单（`recipients()`）和 admin 的 `modules()`。前端的合作方列表要按 `moduleOf` 过滤；keeper 每个模块每轮一次只读调用、扫描有时限，见上。
- **重复的 salt**：同一个 dev 用同一个 salt 再克隆会因地址已被占用而失败（CREATE2 冲突会吃掉转发的全部 gas；钱包估算 gas 时就会失败，CLI 每次启动换新 salt）。
- **管理合约是 handler owner 前面多的一层**：它出问题时多签仍能用 `exec` 把 owner 交回；它本身不可升级、只有三个入口。
- **白名单地址对所有发币人开放**：别人也能把这个回购合约填成自己币的 recipient，但只会多给它钱（绑定报价币按比例拆分，其他资产 sweep 给 dev）；绑定只认 dev 自己的币。
- **回购慢**：每块最多 0.5% 储备、最快每 4 分钟一块（keeper 每 5 分钟一跑），大额税要分很多块；价格被拉高时会暂停，直到高价成为均价。
- **报价币**：pad 接受的报价币（WBNB 或任意 18 位、不扣转账费的 ERC-20）都能用；黑名单和余额被扣的情况见 §5。只对转进交易对收税的报价币能过 pad 的检查，已部署的 v1–v3 用它会卡住回购，v4 修了（§4）。

## 8. 测试

- 单测 `test/gang/GangBuybackSplitter.t.sol` 28 个：管理合约（接管、`exec` 转发与报错原样返回、交回 owner、工厂增删、只有允许的工厂能加白、不重复、`modulesFrom` 分页）、工厂（只给 Agent、比例越界、地址等于 `predict`、同一 dev 重复 salt 被拒而别的 dev 可用、克隆状态、实现不能初始化、克隆只能由工厂初始化一次）、绑定检查、按比例拆分和边界、提高立即生效、下调公告 / 作废 / 取消、毕业前拒绝、分块买完、拉盘后跳过、滑点、ERC-20 报价币、不排除分红也分不到、`previewWork` / `work`（观测、窗口内不 due、可买时的 `minOut`、本区块已买、拉盘后推进观测）、dev 被拉黑、两种余额被扣、`previewWork` 低于最低金额不 due（手动 `burnChunk` 照常）、部署脚本（`check` 各项；从旧管理合约迁移和从多签首次接管两种批量，按打印的执行后生效；迁移后旧工厂不能再加白；同一管理合约换工厂时只要 `setFactory`、列出仍允许的旧工厂）、收款地址（建币时指定、默认 dev、只有 dev 能改、不能改成 0、更换前到账的按旧地址拆分、`sweep` 给收款地址、拉黑的收款地址记欠款且换地址后补发给新地址）、sweep、外盘税端到端、两块之间的间隔（间隔内 `burnChunk` / `work` 回滚 `BurnTooSoon`、预览不 due，满 4 分钟恢复）、拉盘维持后每块卖回只能拿到一块。
- 单测 `test/gang/GangBuybackSplitterPairTax.t.sol` 3 个（复审 L-1）：对转进交易对收税 5% 的报价币，keeper 按 `previewWork` / `work` 买到底；缩放后的 `minTokensOut` 仍拦得住过高的值；对每笔转账收税的报价币，拆分账目对得上、回购买完、不欠 dev。改回按 `quoteIn` 计价时三个都以 `K` 失败，去掉 `minTokensOut` 缩放时三个都以 `Slippage` 失败。
- 注意：`src/gang/**` 用 via-ir 单独编译，测试里 `new` 这些合约会变成 `vm.deployCode`，`vm.expectRevert` 看不到它的回滚（回滚会让测试直接当作通过）；构造函数的拒绝路径要经测试合约自己的 external 函数部署（`newFactory` / `newAdmin`）。
- 测试网整轮见 `docs/TESTNET-BUYBACK-SPLITTER-2026-10-28.md`。
