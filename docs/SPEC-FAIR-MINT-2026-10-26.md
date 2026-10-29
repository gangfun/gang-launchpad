# 规格 · 打新发射（铭文式打进度）+ 发射前持有人奖励

> **2026-10-27 更新（合约合并 + 外盘税新逻辑，以本条为准，下文已按此改写）**：
> - **共用合约**：分红合约、迁移合约、代币部署合约和 V3 共用一份（`SharedDividendVault`、`SharedMigrator`、`TokenDeployer`），不再每个核心各一份 V2 的 DividendVault / MigratorV2 / FairTokenDeployer。HolderRewardHandler 和 V3 的 TaxHandlerV3 共用基类 `PostGradHandlerBase`。
> - **报价币**：WBNB 或任意 18 位 ERC-20，不设白名单；转账扣费的币和本平台发射的币拒收；募集额按 QuoteRegistry 的固定换算额（可选）或发币人自选的参考池换算。主网 USDT 用 Pancake V3 USDT/WBNB 0.01% 池。参考池现价可被闪电贷拉偏的风险按产品决定接受（审计说明 K-1）。
> - **发射后的 1% 税**：不再由 keeper 一次卖光。每笔卖出顺带把攒下的税卖一小块（≤ 这笔卖单的 25%；和 keeper 共用每个币每区块一个额度——池子代币储备的 0.5%；比区块参考价低 2% 以上不卖）并当场分配；没有卖单时 keeper `process(token, amount, minQuoteOut)` 分块补位。持有人那一半在交税那一刻就按当时的份额记到名下，这一批税卖完后兑现成报价币。
> - **卖回**：`withdraw(token, shares, minPayout)`，到手低于 `minPayout` 回滚（防止被抢先一笔打新重启 7 天计时、把撤出费带回来）。
> - **owner 权限**：换币路由在构造时传入，之后改要提议后等 48 小时；分红合约的 operator 每个核心只能绑定一次；分红门槛在币登记时快照。
> - 见 `docs/AUDIT-BRIEF-2026-10-26.md` §15、§16。

> **2026-10-27 重设计（以本条为准，下文已按此改写）**：用户：「打新的逻辑有点问题，不要设置到期时间，这样就不涉及到退款，打新的币可以卖掉，只是价格曲线是固定价格。」于是：
> - **没有截止时间，也没有退款**：sale 一直开着，直到打满发射。`Failed` 状态、`refund`、`duration` 全部删除。
> - **随时卖回**：打满前任何时候都能按打新价把份额卖回给发射台（`withdraw`），扣撤出费 1%–2%（默认 1%）。这是未打满时唯一的退出方式。
> - **打新费 1%–3%（默认 1%）在打的那一笔直接进平台**，不再托管。
> - **单地址上限 0.25%–0.5%（默认 0.5%）**：没有截止时间，门槛要能达到，最多需要 200 个地址。
> - **7 天没有进展就免撤出费**：让停滞的 sale 可以按原价退出。「进展」= 已售份数比计时上次重启时多出 `STALE_STEP`（10 份，0.1%）；创建者那一笔起算（`progressAt` / `markSold`）。只打 1 份、或别人撤出后再打回来，都不算进展（第三轮内部审计 R3-1，审计说明 §14）。
> - 撤出费进 PlatformFeeBucket 失败时不卡撤出：费用留在发射台记为 `owedFee`，任何人可 `flushFees` 补交（R3-2）。金库拒绝写份额时发 `ShareWriteFailed`，keeper 在发射后为该地址 `syncShares`（R3-3）。
> - 发射前仍不能 P2P 转账：代币只在发射台和打新地址之间进出。
> - 募集额（5–50 BNB）、出局线（30%–80%）、总量和份数不变。

> 2026-10-26 内部审计后（`docs/AUDIT-BRIEF-2026-10-26.md` §10）：报价币当时只收 WBNB 和 QuoteRegistry 白名单里的 18 位币（2026-10-27 已改，见第一条）；路由入口 `mintFor` 只对有准入的 sale 开放；失败退款不再调用分红合约（2026-10-27 起没有退款，撤出写分红合约改为不阻塞）；QuoteRegistry 和 PlatformFeeBucket 不再复用 V2 那份，改为与 V3 共用一份新部署、owner 为多签的实例。

> 2026-10-26 补充：这个合约是「核心」，用户也可以经无状态的 GangRouter 进入（用 BNB 直接买 / 打新）。路由只能替交易者付钱，撤出（卖回）/ 领取仍只能本人直接调用。见 `docs/SPEC-CORE-ROUTER-2026-10-26.md`。

- 日期：2026-10-26 Asia/Shanghai
- 作者：Claude（本页为产品规格 + 合约设计；**非执行单**）
- 性质：**禁止主网广播**。合并后的版本在 `feat/swapback` 分支（冻结点 `ddce6b6`），mock 与主网分叉测试通过（§5.6），已过四轮内部审计（`docs/AUDIT-BRIEF-2026-10-26.md` §10–§16，第五轮进行中，按决定不做外部审计）；测试网第 5 套（合并前的合约）见 `docs/TESTNET-CORE-ROUTER-2026-10-26.md`。
- 来源：用户口述（2026-10-26）：「没有内盘的概念，跟以前铭文一样打进度。dev 自定义规则，但是我们要设置上下限，比如最低 100 人，最高 0.5%。内盘没有价格，只有打满了之后代币发射，内盘依旧保持 1% 的买卖税。发射后有默认 1% 的税费，发射前就在的地址如果持有代币保持 50% 就可以享有 1% 税费中的 50% 作为持有奖励，剩下的 50% 跟目前的税费外盘规则不变，回购 + 入金库。」
- 用户已定：固定价格打进度、打满即发射；打新阶段买卖各 1%；发射后 1% 税，50% 给发射前持有人、50% 回购 + 金库；dev 在平台上下限内设规则。
- 2026-10-26 用户：「按照你的建议开始执行」→ §9 各项按 Claude 建议执行（奖励算法、失败全额退、税率固定 1%、出局线 30%–80% 由 dev 选、报价币同 V2、50 / 50、10,000 份、上下限、dev 至少打 1 份）。仍待办：§9 #6 网站入口、#11 核实 Agentic Wallet。
- 2026-10-26 用户：打新阶段的买（打新）、卖（撤出）手续费分开设 → dev 创建时各在 1%–5% 内选，默认都是 1%；撤出费全部给平台（§1.1、§1.3、§9 #12）。2026-10-27 起范围改为打新费 1%–3%、撤出费 1%–2%（§9 #13）。
- 2026-10-26 自审修订：改正 BNB 收款方式（V2 只收 WBNB）；补 §5.5 安全约束（管理员权限、托管资金）；补最后一笔截断、出局的误伤场景、开盘价措辞、接线遗漏；去掉「查 Agent ID 铸造时间」（ERC-721 不记录铸造时间）。
- 与 `SPEC-V3-ECONOMIC-TEMPLATES-2026-10-26.md` 的关系：本方案不需要模版市场，V3 分支搁置不删；可复用部分见 §6.3。

---

## 0. 一句话产品

dev 设好募集额和单地址上限，所有人按**同一个价格**一份一份打，打满前随时可以按同一个价格卖回；没有截止时间，打满就自动加池子开盘，开盘价等于打新价。开盘后每笔交易 1% 税，一半分给**打新时就进来、而且一直没怎么卖**的人，一半照旧回购 GANG 和进金库。

---

## 1. 规则

### 1.1 dev 可设的参数（平台上下限）

| 参数 | 范围 | 默认 | 说明 |
|---|---|---|---|
| 募集额 `raise` | 5–50 BNB 等值 | 15 BNB | 打满即发射；非 BNB 报价币在创建时按参考池换算并锁定 |
| 单地址上限 `capBps` | 0.25%–0.5% 总量 | 0.5% | **最少参与地址数由它推出**：50% ÷ 上限（0.5% → 100 个，0.25% → 200 个）。没有截止时间，下限不再放到 0.1%（500 个地址太难凑齐） |
| 出局线 `holdBps` | 30%–80% | 50% | |
| 打新手续费 `mintFeeBps` | 1%–3% | 1% | 本金之外另收；打的那一笔直接进平台，不退 |
| 撤出手续费 `exitFeeBps` | 1%–2% | 1% | 从卖回的本金里扣；sale 7 天没有进展时为 0（§1.3）；例：打新 1% / 撤出 2% |
| 名称 / 代号 / 图标 / 报价币 | — | — | 同 V2 |

「最低 100 人」不单独设规则：打新份额固定 50%、单地址最多 0.5% 时，打满必然至少 100 个地址。dev 把上限调低，人数门槛自动变高。

### 1.2 平台固定的参数

| 项 | 值 |
|---|---|
| 总量 | 10 亿（同 V2） |
| 打新份额 | **50%**（5 亿），分成 **10,000 份**，每份 50,000 枚（比例和份数均为 Claude 定，待批） |
| 池子份额 | **50%**（5 亿）+ 全部募集本金，LP 打到 0xdead（同 V2） |
| 每份价格 | `raise / 10,000`（报价币计，创建时锁定） |
| 开盘价 | = 打新价（池子 5 亿枚 : 募集本金 = 打新 5 亿枚 : 募集本金）。打新的人含 1% 手续费，开盘立刻卖还要交 1% 税，所以开盘就卖约亏 2% |
| 准入 | 打新必须持 Agent ID（同 V2）；撤出（卖回）不要求 |
| 收款 | 同 V2：只收 ERC-20 报价币（BNB 用 WBNB），`transferFrom` 只拉实际成交的份数，不涉及原生 BNB |
| dev 预留 | 无。dev 想要筹码就和别人一样打，受同样的上限 |

### 1.3 打新阶段（没有价格曲线）

| 动作 | 规则 | 费用 |
|---|---|---|
| 打 `mint(n)` | 按份打；累计不超过单地址上限；最后一笔自动截到剩余份数，只按成交份数收钱 | 本金 + **打新手续费**（默认 1%），手续费当笔进平台 |
| 卖回 `withdraw(n)` | 打满前随时可以，没有时间限制；按打新价退回本金 − **撤出手续费**（默认 1%；7 天没有进展时为 0） | 打入时的手续费不退；撤出费当笔进平台 |
| 打满 | 最后一份打出的那笔交易里直接发射（§1.4） | — |

- **没有截止时间、没有失败、没有退款**。没打满的 sale 一直开着，任何时候有人把剩下的份数打完就发射；不想等的人卖回退出。
- **7 天免撤出费**：sale 有一个计时 `progressAt`，从创建者那一笔开始；之后只有当已售份数 `sold` 达到「上次重启时的份数 `markSold` + 10 份」时，打新才重启计时。距 `progressAt` 满 7 天（`>=`）后，卖回不收撤出费，按打新价全额退本金（打新费仍不退）。卖回本身不重启计时；只打 1 份、或别人撤出后再打回原来的份数，也不重启。想让计时一直不到期，就得不断净增份数并持有，每个地址最多能做几次（上限 50–100 份）。
- 代币在打的时候就记到地址上（钱包里看得到），但**发射前锁转账**：只有发射台能动（卖回时收回）。这样既杜绝场外私下交易和抢先建池，也让「发射前的地址」= 打新的地址。
- 所有平台收入走现有 PlatformFeeBucket：80% 回购 GANG / 20% feeVault。撤出费进 bucket 失败时（例如 operator 被撤）不影响卖回：费用留在发射台，记为 `owedFee[quote]`，bucket 恢复后任何人可 `flushFees(quote)` 补交。打新费进 bucket 失败时打新 revert（打新可以停，退出不能停）。

### 1.4 发射

打满那一刻：
1. 解锁代币，5 亿枚 + 全部募集本金进 Pancake V2 池子，LP 打到 0xdead（共用的 SharedMigrator；池子里已有 LP 时拒绝）。
2. 打开 1% 交易税（税只对池子买卖收，同 V2 有税代币）。

打新费在每一笔打新时就已进平台，发射时没有托管款要结算。

### 1.5 发射后：1% 税

| 去向 | 比例 | 说明 |
|---|---|---|
| 发射前持有人奖励（SharedDividendVault） | 50%（= 成交额 0.5%） | 只给合格地址，见 §1.6 |
| 平台（PlatformFeeBucket → 80% 回购 GANG / 20% feeVault） | 50%（= 成交额 0.5%） | 与 V2 有税轨外盘相同 |

- 税先以代币累计在 HolderRewardHandler。持有人那一半在交税那一刻按当时的合格份额记成税币单位（交易前的份额：卖家按卖出前的份额分到自己这笔卖出的税，买家分不到自己这笔买入的税）。
- 每笔卖出进池子之前，代币让 handler 先卖一块攒下的税（≤ 这笔卖单的 25%；和 keeper 共用每个币每区块一个额度——池子代币储备的 0.5%；比区块参考价低 2% 以上不卖）；没有卖单时 keeper `process(token, amount, minQuoteOut)` 分块卖。换回的报价币 50% 兑现给记了单位的持有人、50% 进平台。卖出那一块失败不影响用户这笔卖出。
- 分红合约或 bucket 拒收时，这一块照常卖出：持有人那份先留在 handler（`flushHolders` 补兑现），平台那份记 `owedPlatformOf`（`flushPlatform` 补交），任何人都能调。
- **合格地址一个都不剩时**，奖励那一半也归平台，不卡在分红合约里。

### 1.6 发射前持有人奖励（核心规则）

| 项 | 规则 |
|---|---|
| 谁有资格 | 打新时打进来的地址；基准 = 发射时的数量（= 打到的份数 × 50,000） |
| 奖励权重 | **当前持仓**，最多算到基准为止 |
| 出局 | 持仓一旦**低于基准的 50%**，永久出局，之后买回来也不恢复 |
| 已赚的 | 出局前累计的奖励照样能领，不作废 |
| 开盘后才买的人 | 没有资格，只交税 |
| 池子地址 / 平台合约 | 永远没有份额 |

为什么这样定：
- **按当前持仓加权**：如果按发射时数量拿全额、只看是否低于 50%，那卖掉一半没有任何损失，理性做法就是开盘先卖一半（≈ 25% 总量的可预期抛压）。按当前持仓算，每卖一枚就少一份，50% 只是出局线。
- **最多算到基准**：防止合格地址从别的钱包收筹码来放大份额。
- **永久出局**：防止清仓后低位买回再接着拿奖励。出局线以上可以自由进出：卖到 60% 再买回 100%，份额也跟着恢复。

要在页面上写清楚的副作用：
- 把代币**转到另一个钱包**、拿去**加池子**、放进别的合约，余额都会下降，跌破线就出局。**哪怕同一笔交易里又转回来也算**：转出那一下就判定了。
- 开盘后才买的人没有奖励。
- 网站、CLI 在卖出 / 转账前要预判：「这笔操作会让你永久失去持有奖励」，需要二次确认。

---

## 2. 数字示例（默认参数：募集 15 BNB，上限 0.5%）

| 项 | 数值 |
|---|---|
| 每份价格 | 0.0015 BNB（打新费 1% 时 + 1% = 0.001515 BNB） |
| 单地址最多 | 100 份 = 500 万枚 = 0.15 BNB 本金 |
| 最少地址数 | 100 |
| 开盘池子 | 5 亿枚 + 15 BNB → 开盘价 3e-8 BNB / 枚，开盘 FDV 30 BNB |
| 平台打新收入 | 已打份数 × 每份价格 × 该币打新费（打满时默认 1% = 0.15 BNB）+ 撤出手续费 |
| 卖回 100 份 | 打新 1% / 撤出 1%：拿回 0.1485 BNB，平台共收 0.003 BNB；撤出费 2% 时拿回 0.147 BNB |
| 7 天没有进展后卖回 100 份 | 拿回 0.15 BNB（本金全额，打入时的 0.0015 BNB 打新费不退） |
| 让计时不到期的成本 | 每 7 天至少净增 10 份并持有（≈ 0.015 BNB 本金 + 打新费），单地址最多 5–10 次 |
| 一个只打 1 份的人 | 基准 50,000 枚；持仓低于 25,000 枚出局 |
| 开盘后日成交 100 BNB | 税 1 BNB → 合格持有人 0.5 BNB、平台 0.5 BNB |

---

## 3. 风险与取舍

| # | 风险 | 处理 |
|---|---|---|
| 1 | **女巫**：0.5% 上限下单钱包最多 0.15 BNB，大户只能多开钱包；单地址上限是公平性的全部依据 | 2026-10-26 链上核实（Agent ID `0x60B9…022F`）：转账 / 授权全部 revert `Soulbound`，ID 不能转手；铸造走 `register(name, deadline, signature)`，要官方后台签名；最近 269 次铸造都是全新钱包给自己铸、免费，抽查 60 个持有人每个都只有 1 个 ID。所以单地址上限 ≈ 单个 Agentic Wallet 上限。2026-10-26 用户在 Binance App 实测：**一个人只能开 1 个 Agentic Wallet**。因此「至少 100 个地址」≈ 至少 100 个 Binance 账户；剩余的刷号空间取决于 Binance 自己的一人一号管控 |
| 2 | **平台打新收入比 V2 少**：V2 按内盘成交额收 1%（曲线上来回交易多次），打新只按募集额收 1% | 用外盘 0.5% 和撤出手续费补；需要你确认能接受 |
| 3 | 开盘被机器人抢买 | 打新的人开盘正好保本，抢买是把价格往上推；第一版不加防狙击 |
| 4 | 打到 99% 有人大额撤出拖进度 | 打进再撤出要付打新费 + 撤出费（至少 2%、最多 5%）。没有截止时间，拖进度只是让发射晚一点，不会让 sale 失败；最后一笔被人抢先撤出 1 份时，按「打剩下全部」下单的人不受影响（多打的部分自动截掉） |
| 5 | 有人提前在 Pancake 建同名池子并打入报价币 | 代币锁转账，打不进代币；SharedMigrator 遇到已有的空池子直接用（已有 LP 时 `PairHasLiquidity`），对方打进的报价币等于白送，只会让开盘价略高 |
| 6 | 最后一笔打满的交易要建池子，gas 高 | 同 V2 毕业；预估页面提示 |
| 7 | 分红合约的最低份额 | **不能照搬主网的 100 万枚**：1 份只有 5 万枚、出局线 2.5 万枚（出局线 30% 时 1.5 万）。共用分红合约里打新核心的门槛设 10,000 枚，并在每个币登记时快照，之后改门槛不影响已有币 |
| 8 | 一直打不满，钱卡在 sale 里 | 没有截止时间，不会「差一点没打满就全退」；不想等的人随时卖回。sale 7 天没有进展后卖回免撤出费，只损失打新费。网站和 CLI 把停滞的 sale 默认折叠，并显示「还差多少份、至少还要多少地址」 |
| 9 | 开盘市值比 V2 低 | 同样 15 BNB：V2 池子 2 亿枚 → 开盘 FDV 75 BNB；打新池子 5 亿枚 → FDV 30 BNB。池子深度相对市值更厚、价格更稳，但排行榜上的市值会显得小 |
| 10 | 有人另建交易对（如本币 / USDT）绕开税 | 沿用 V2 的已知限制：税只对官方池子收，奖励池规模取决于官方池子成交量 |
| 11 | 刷空 sale | 创建不收费，但 dev 至少要打 1 份并付打新费（不退），没有退款可以白拿。停滞的 sale 在网站上默认折叠 |
| 13 | 有人每周打 1 份，让所有人一直付撤出费 | 已防：只打 1 份、撤了再打回来都不重启计时，要净增 10 份并持有才算进展（审计说明 §14 R3-1） |
| 14 | PlatformFeeBucket 被撤 operator，卡住撤出 | 已防：撤出费改为不阻塞，失败时记 `owedFee`，任何人 `flushFees` 补交（R3-2）。打新会 revert，直到恢复。发射后的税照常卖出，平台那份记 `owedPlatformOf` |
| 15 | keeper 停了，税攒成大单砸盘、分红按卖出时的持有人分（V2 实际发生过） | 已防：卖出时顺带分块卖、每块 ≤ 池子代币储备 0.5%；持有人那一半在交税时就按当时份额记账（审计说明 §16） |
| 16 | 看到撤出费 0% 去卖回，被抢先一笔打新重启计时 | 已防：`withdraw` 带 `minPayout` |
| 12 | 参考池现价可被同一笔交易拉偏 | 没设固定换算额的报价币用 V2 池子（或观测不够的 V3 池子）定价时按现价换算，dev 可借闪电贷让锁定的募集额超出 5–50 BNB 范围。按产品决定沿用 V2 的做法（审计说明 K-1），不改合约：dev 自己也按锁定价打，打新的人看到的是报价币价格；索引服务按实时价格换算募集额，偏离范围的币在页面上标出 |

---

## 4. 状态机

```
   create（dev 至少打 1 份，计时开始）
     │
     ▼
  Minting ── mint / withdraw，没有时间限制；7 天没有进展 → 撤出费为 0
     │
   打满（最后一份那笔交易）
     │
     ▼
  Launched
     │
     ▼
  交易 1% 税 → 交税时按份额记账；卖出时分块卖（keeper 补位）→ 50% 兑现给持有人 / 50% PlatformFeeBucket
```

只有两个状态：`Minting`、`Launched`（`status()` 返回 None / Minting / Launched）。

---

## 5. 合约接口（草案）

### 5.1 FairMintPad

```solidity
struct MintConfig {
    uint256 raiseBnb;   // BNB 等值，[5, 50] BNB；创建时按 WBNB / QuoteRegistry 固定换算额 / 参考池换算成报价币并锁定
    uint16  capBps;     // [25, 50]，占总量
    uint16  holdBps;    // 出局线 [3000, 8000]
    uint16  mintFeeBps; // 打新手续费 [100, 300]
    uint16  exitFeeBps; // 撤出手续费 [100, 200]
}

uint256 constant STALE_AFTER = 7 days;  // 这么久没有进展 → 撤出费为 0
uint256 constant STALE_STEP = 10;       // 进展 = sold 达到 markSold + 10 份

function create(string name, string symbol, string logoURI, string metaURI, address quote, address refPool,
    MintConfig cfg, uint256 devShares) external returns (address token); // 须 Agent ID；devShares = dev 自己打的份数
function mint(address token, uint256 shares, uint256 minShares) external returns (uint256 accepted);
    // 须 Agent ID；最后一笔被截断到少于 minShares 时 revert；只 transferFrom 成交部分
function withdraw(address token, uint256 shares, uint256 minPayout) external returns (uint256 payout);
    // 按打新价卖回，扣当前撤出费；到手 < minPayout 时 revert（Slippage）
function flushFees(address quote) external returns (uint256 amount);  // 任何人：把 owedFee 补交给 bucket
function previewMint(address token, address user, uint256 shares)
    external view returns (uint256 accepted, uint256 cost, uint256 fee);
function previewWithdraw(address token, address user, uint256 shares)
    external view returns (uint256 payout, uint256 fee);                // 会 revert 时返回 (0, 0)
function exitFeeBpsOf(address token) external view returns (uint256); // 当前撤出费：sale 自己的，或停滞后的 0
function baselineOf(address token, address user) external view returns (uint256 tokens); // 供奖励判断
function status(address token) external view returns (uint8); // None / Minting / Launched
```

存储（每个币）：`creator, progressAt, capShares, holdBps, quote, sold, launched, mintFeeBps, exitFeeBps, gate, sharePrice, pair, refPool, markSold`（`sales(token)` 按这个顺序返回 14 个字段）；每地址：`shares`；每个报价币：`owedFee`。

### 5.2 FairToken

- 基于 V2 `TaxLaunchToken`（10 亿全部铸给发射台），税率固定 1%。
- 发射前：除发射台外一律不能转；发射台可从地址收回（卖回用，不依赖用户授权）。
- 发射后：池子买卖收 1% → handler 累计；卖进池子前调 `handler.swapBack(token, sellAmount)`（失败吞掉、发 `SwapBackFailed`；调用方 gas 不够时整笔回滚 `SwapBackOutOfGas`，保证 gas 估算包含这一块）；每笔转账调 handler 同步奖励份额。
- 创建代码放在共用的 `TokenDeployer` 里（`deployFair`），发射台不受代币代码体积影响。

### 5.3 HolderRewardHandler（继承 `PostGradHandlerBase`）

- `notifyTax`：只认本核心登记的币（`launchpadOf(token) == pad`），累计税、按当时的合格份额记持有人那一半的单位（`accrueDividendUnits`）；没有合格份额时那一半归平台。
- `swapBack(token, sellAmount)`（只有代币能调）/ `process(token, amount, minQuoteOut)`（keeper / owner，`amount` 截到 `maxChunk`）：卖一块，换回的报价币 50% `convertDividend` 兑现给持有人、50% `bucket.notifyAccrual`；拒收时记 `pendingHolder*` / `owedPlatformOf`，`flushHolders` / `flushPlatform` 补上。`previewSell(token, amountIn)` 返回卖单含这一块后的实际到手。
- 换币路由在构造时传入（0 = 直接对池子卖），之后 `proposeDexRouter` → 48 小时 → `acceptDexRouter`。
- `syncShares(token, from, to)` 对每个地址：

```
base = pad.baselineOf(token, user)
if base == 0 or out[token][user]:            share = 0
elif balance < base * holdBps / 10000:       out[token][user] = true; share = 0; emit Disqualified
else:                                         share = min(balance, base)
```

- 打新阶段份额由发射台在 `mint` / `withdraw` 时直接写（发射前没有转账，也就不需要 handler 同步）；发射那一刻不需要遍历地址。
- `withdraw` 写分红合约改为不阻塞（卖回是未打满时唯一的退出方式，不能被分红合约卡住）：分红合约真拒绝时保留旧份额并发 `ShareWriteFailed(token, user, share)`；调用方卡 gas 造成的失败仍 revert（`OutOfGas`，同 §10 A-5）。全部卖回的地址基准为 0，handler 对基准为 0 的地址目标份额一律为 0，所以发射后第一次同步就清零；keeper 按 `ShareWriteFailed` 主动为这些地址调 `syncShares(token, user, 0)`，不等它们自己转账（审计说明 §14 R3-3）。
- 写分红合约失败时吞掉错误并发 `ShareWriteFailed`：份额可能暂时不准，但不能卡住代币转账。已出局地址每次同步都把份额重写为 0，所以失败过的清零会在恢复后自动补上。分红合约的 operator 每个核心只能绑定一次、不能解绑，「owner 撤掉 operator」这条路已不存在。

### 5.4 事件（索引服务据此改）

| 合约 | 事件 |
|---|---|
| FairMintPad | `Created(token, creator, name, symbol, logoURI, quote, refPool, raiseBnb, sharePrice, capShares, holdBps, mintFeeBps, exitFeeBps)` |
| | `Minted(token, user, shares, cost, fee, userShares, sold)` · `Withdrawn(token, user, shares, payout, fee, userShares, sold)` |
| | `Launched(token, pair, quote, tokenAmount, quoteAmount)` · `ShareWriteFailed(token, user, share)` · `FeeOwed(quote, amount)` · `FeesFlushed(quote, amount)` |
| HolderRewardHandler | `TaxAccrued` · `OuterTaxProcessed(token, quote, taxTokens, quoteOut, toHolders, toPlatform)` · `TaxChunkSold(token, taxTokens, quoteOut, holderUnits, swapBack)` · `HolderConversionDeferred` · `PlatformOwed` / `PlatformFlushed` · `ShareWriteFailed` · `Disqualified(token, user, balance, baseline)` · `DexRouterProposed` / `DexRouterSet` / `DexRouterCancelled` |
| FairToken | `SwapBackFailed` |
| SharedDividendVault | `TokenRegistered` · `ShareUpdated` · `DividendUnitsAccrued` · `DividendConverted` · `DividendBatchSettled` · `DividendClaimed` |

### 5.5 安全约束

打新期间发射台托管每个币最多 50 BNB 等值的本金，所以：

1. **没有任何管理员函数能动托管资金**：没有紧急提取。本金只有两个出口：卖回、发射进池子；手续费进 bucket（`flushFees` 只能把 `owedFee` 交给 bucket）。
2. **规则创建时快照**：单地址上限、准入开关、手续费、出局线都存进该币自己的配置。V2 的 `setWalletCapEnabled` / `setAgentGate` 这类全局开关不能影响打新中的币，最好不提供 `setWalletCapEnabled`。
3. `setMigrator` 只能设一次（V2 已是一次性），`pairFactory` 构造时固定；发射时钱和币只能去这个 migrator。
4. FairToken 的「发射台收回」只在发射前有效，发射后永久失效，且只能收回该地址打到的数量。
5. 卖回由用户自己调用，不遍历地址；`nonReentrant`。卖回不依赖分红合约和 bucket：两者拒绝时都不 revert（分红份额留待同步、撤出费记 `owedFee`），owner 无法通过它们冻结退出。
6. 报价币：WBNB 或任意 18 位 ERC-20（2026-10-27 起不设白名单，沿用 V2 的参考池换算）；转账扣费的币在扣款时拒收（卖回要求精确记账），本平台发射的币拒收。参考池现价可被闪电贷拉偏的风险按产品决定接受（审计说明 K-1，§3 #12）；会暂停 / 拉黑的报价币可能让用它的 sale 卡住（审计说明 K-12）。
7. 奖励判断只看「发射时数量」，池子、handler、migrator、发射台的基准天然为 0，不依赖 `excluded` 名单。
8. 外部审计 V2 的结论（2026-10-26，经另一窗口转达）对本方案的处理：
   - **G-01 被排除地址保留旧份额继续分红：受影响，已修。** 分红合约的 `setExcluded` 不清份额；handler 原先拿算出的份额和旧份额比较，相等就不写，被排除地址会一直按旧份额分钱。现在被排除地址的目标份额一律为 0（`_sync` 和 `eligibleShare`）。剩余窗口：owner 排除某地址后、该地址下次转账前仍会累计，所以**排除操作必须和 `handler.syncShares(token, user, 0)` 放在同一批交易里**。排除前已赚的奖励仍可领。
   - **G-02 totalShares == 0 时存入的钱永远卡住：不受影响。** handler 只在合格份额 > 0 时存入，否则 100% 给平台（测试覆盖全员出局、全员被排除两种情况）。
   - **G-03 `flushStuckQuoteToTreasury` 绕过 80/20：** 复用的 V2 PlatformFeeBucket 原样带有这个应急出口（owner + 7 天延迟），本方案不改，知悉即可。

### 5.6 实现（`feat/swapback`，冻结点 `ddce6b6`）

| 文件 | 内容 |
|---|---|
| `src/fair-mint/FairMintPad.sol` | 打新发射台：create / mint / withdraw（卖回，带 `minPayout`）/ flushFees / 打满发射；规则按币快照；16.8 KB（via-ir） |
| `src/fair-mint/FairToken.sol` | 代币（发射前锁转账、发射台可收回；发射后池子买卖 1% 税，卖出时调 `swapBack`）；由共用的 `TokenDeployer` 部署 |
| `src/fair-mint/HolderRewardHandler.sol` | 发射后 1% 税：交税时按份额记账、卖出时分块卖（keeper 补位），50% 给合格持有人 / 50% 平台；出局判断；分红合约出错不卡转账 |
| `src/common/*` | 与 V3 共用：`PostGradHandlerBase`、`SharedDividendVault`、`SharedMigrator`、`TokenDeployer` |
| `test/fair-mint/FairSwapBack.t.sol` | 卖出时自动换、每区块额度、零头不触发、失败不影响卖出、`previewSell`、按交税时记账、bucket / 分红合约拒收、按估算 gas 执行 |
| `test/fair-mint/FlowReviewFixes.t.sol` | `minPayout`、operator 只能绑一次、门槛按币快照、换币路由时间锁 |
| `test/fair-mint/FairMint.t.sol` | 33 个用例：上下限、报价币换算、打新上限与截断、卖回、打新费当笔进平台、7 天免撤出费、没有截止时间、发射价格、池子被提前建好、奖励权重 / 出局 / 上限、分账、权限、分红合约出错后的补救 |
| `test/fair-mint/FairMintAudit.t.sol` | 8 个内部审计回归：含计时要净增份数才重启（R3-1）、bucket 拒收不卡卖回（R3-2）、金库拒写发 `ShareWriteFailed`（R3-3） |
| `test/fair-mint/FairMintFork.t.sol` | BSC 主网分叉（需 `BSC_RPC_URL`）：真实 Pancake 全流程（WBNB）、USDT 报价经 V3 桥接、池子被提前建好并 `sync` |
| `src/fair-mint/mocks/TestnetAgentId.sol` | 测试网用：灵魂绑定、每钱包一个、自己注册（主网用真实 SPACE ID） |
| `config/FairMintDeployRefs.sol` | 主网 / 测试网地址（2026-10-26 链上核对） |
| `script/DeployFairMint.s.sol` | 部署 + 接线 + 接线自检；主网广播须 `FAIR_MINT_MAINNET_OK=true` |
| `script/FairMintTestnetE2E.s.sol` | 测试网整轮：建币 → 100 个一次性地址打满 → 买、卖到出局、keeper 分账、领奖励 |

- 复用 V2 代码：PlatformFeeBucket、PoolCheck、QuoteRegistry（新部署一份，与 V3 共用）。分红、迁移、代币部署用 `src/common/` 的共用合约。
- 实测 gas（2026-10-26）：
  - 主网分叉：打满那一笔（含真实 Pancake 建池）≈ 387 万；打新地址经路由卖出（含收税 + 奖励同步）≈ 27 万。
  - 测试网分叉彩排（anvil，真实测试网 Pancake）：部署 21 笔 ≈ 1,221 万 gas；整轮 510 笔 ≈ 4,328 万 gas，全部成功；打满那一笔 ≈ 250 万。0.1 gwei 下合计 ≈ 0.0055 tBNB，连同预付给打新地址的 gas，部署钱包备 ≈ 0.03 tBNB。
  - USDT 报价：15 BNB 换算 11,051 USDT，现价 11,070（差 0.2%）。

---

## 6. 部署

### 6.1 顺序

五个共用合约（QuoteRegistry、PlatformFeeBucket、SharedDividendVault、SharedMigrator、TokenDeployer；主网由 `DeployLaunchpadV3` 先部署，`DeployFairMint` 通过 `QUOTE_REGISTRY` / `PLATFORM_BUCKET` / `DIVIDEND_VAULT` / `MIGRATOR` / `TOKEN_DEPLOYER` 复用）→ `HolderRewardHandler(owner, vault, bucket, dexRouter)` → FairMintPad → 接线。

### 6.2 接线

- PlatformFeeBucket：FairMintPad、HolderRewardHandler 设为 operator。
- SharedDividendVault：`setLaunchpad(FairMintPad, true)`、门槛 10,000 枚、`setOperator(HolderRewardHandler, FairMintPad)`（只能一次）；排除迁移合约、bucket（自己在构造时已排除）。
- SharedMigrator `addLaunchpad(FairMintPad)`；TokenDeployer `setLaunchpad(FairMintPad, true)`。
- HolderRewardHandler：`setPad(FairMintPad)`（一次性）、`setKeeper`；换币路由已在构造时传入。
- FairMintPad：`setMigrator`（一次性；pairFactory 已在构造时传入）、Agent ID 注册表、bridge 池（非 BNB 报价币用）。
- 每个币：创建时代币构造即写死 HolderRewardHandler、写入 `create` 新增的 `metaURI`（元数据 JSON 地址；`logoURI` 仍存在发射台），发射台 `dividendVault.registerToken(token, quote)`；发射时一次性 `unlock(migrator)`（解锁 + migrator 免税）和 `setPair`（2026-10-27 起，审计说明 §12）。

### 6.3 测试网步骤

```sh
# 部署钱包备 ≈ 0.03 tBNB
export DEPLOYER_PRIVATE_KEY=0x…
GAS="--with-gas-price 100000000 --priority-gas-price 100000000"   # 0.1 gwei，必须显式给
forge script script/DeployFairMint.s.sol --rpc-url bsc_testnet --broadcast --slow $GAS
# 从输出取 FAIR_MINT_PAD / TEST_QUOTE
export PAD=0x… TEST_QUOTE=0x…
forge script script/FairMintTestnetE2E.s.sol --rpc-url bsc_testnet --broadcast --slow $GAS
```

2026-10-26 实跑踩坑：不给 gas 价格时，forge 有一次从公共节点拿到 1 wei 的估价，交易卡在交易池里不打包（部署那次正常是 0.1 gwei）。所以测试网命令一律显式给 0.1 gwei。

主网：部署钱包若是 V2 bucket 的 owner（`0x4EEd…`）则自动加 operator，否则输出待办；`OWNER` 设为多签时，多签需对 pad / handler / vault 调 `acceptOwnership()`。主网广播在审计前被脚本拒绝。

### 6.4 从现有代码复用

| 来源 | 用途 |
|---|---|
| V2 `PoolCheck` / `QuoteRegistry` / Agent ID 判断 | 报价币换算、准入，原样用 |
| V2 `PlatformFeeBucket` | 原样用（新部署一份，与 V3 共用） |
| V2 `DividendVault` / `MigratorV2` | 改成共用的 `SharedDividendVault`（多核心、按税产生时记账）/ `SharedMigrator`（多核心） |
| V2 `TaxLaunchToken` | 改成 FairToken（由共用的 `TokenDeployer` 部署） |
| V2 `PostGradTaxHandler` 的换币代码 | 改成与 V3 共用的 `PostGradHandlerBase`（分块卖、`swapBack`），HolderRewardHandler 继承它 |

---

## 7. 测试清单

1. 参数上下限：每个参数越界都 revert，并给出原因。
2. 打新：单地址上限、最后一笔截断、非 Agent 不能打、任何时候都能打（没有截止）；打新费当笔进 bucket。
3. 卖回：本金 − 撤出费、打入手续费不退、上限额度释放、份额同步；7 天没有进展后撤出费为 0；1 份或撤了再打回不重启计时；bucket 拒收时记 `owedFee` 且到手金额不变；分红合约拒写时不卡卖回。
4. 发射前代币不能转；发射台余额 = 未发射 sale 的本金 + `owedFee`。
5. 发射：最后一份触发；池子数量与开盘价 = 打新价；LP 在 0xdead；已存在池子的情况。
6. 奖励：只有打新地址有份额；卖出后份额按持仓下降；跌破出局线永久出局、买回不恢复；收别人筹码份额不超基准；出局前奖励可领；没人合格时 100% 进平台。
7. 权限：owner 在打新中改任何设置都不影响该币的上限 / 准入 / 手续费；没有任何路径能把托管资金转给 owner，也不能冻结卖回。
8. 最后一笔：截断后只拉成交部分；低于 `minShares` revert；建池失败时整笔回滚，币保持打新中。
9. fork 测试：真实 Pancake 池子、USDT 类报价币、卖出时自动换与 keeper 分块 `process`（已完成，`FairMintFork.t.sol`）。
10. 卖出时自动换：每区块额度、区块参考价、零头不触发、失败不影响卖出、`previewSell` 准确、按估算 gas 执行；按交税时记账：交税之后买入的分不到、之后卖掉的照样能领；分红合约 / bucket 拒收时照常卖出并可补（已完成，`FairSwapBack.t.sol`、`test/common/TaxTimeDividends.t.sol`）。

---

## 8. 各端要改的

| 端 | 内容 |
|---|---|
| gangfun-server | 索引 §5.4 事件；币状态（打新中 / 已发射）、进度、参与地址数、还差多少份 / 至少还要多少地址、按同一规则复刻的 7 天计时（是否停滞、何时免撤出费）；每地址基准 / 是否出局 / 可领奖励 / 现在全部卖回能拿多少；募集额按实时价格换算成 BNB，超出 5–50 BNB 的标出（§3 #12）。keeper：`FAIR_PADS` 填核心地址即自动接线，分块补位卖税、`flushHolders` / `flushPlatform`，跟进 `ShareWriteFailed` 和 `FeeOwed`（`flushFees`）；健康检查报警 |
| gang.fun | 打新页（进度条、每份价格、还差多少地址、我的份数、卖回能拿多少、当前撤出费与免撤出费倒计时；停滞的 sale 默认折叠）；代币页「持有奖励」：合格 / 已出局、当前权重、可领；风险提示（转钱包、加池子会出局） |
| CLI / skill | `gang fair create --raise 15 --cap 0.5 --hold 50 --mint-fee 1 --exit-fee 1`、`gang fair mint`、`gang fair withdraw`（按 `previewWithdraw` 报到手金额和撤出费，并以它减 0.1% 作 `minPayout`）、`gang fair status` / `claim`；没有 `--hours` 和 `refund` |
| 审计 | 发射台 + FairToken + handler + 共用合约；按决定以内部审计为准（审计说明 §10–§17） |

---

## 9. 决策（2026-10-26 按 Claude 建议执行）

| # | 问题 | 建议 |
|---|---|---|
| 1 | 奖励算法 | 按当前持仓加权、上限为发射时数量；低于 50% 永久出局（§1.6） |
| 2 | 打新失败退不退打入的 1% | 2026-10-27 起不适用：没有失败和退款（#13） |
| 3 | 发射后税率 | 第一版固定 1%，不让 dev 选 |
| 4 | 出局线给不给 dev 选 | 可以给（30%–80%），这是 dev 唯一能调的经济参数，也回应了「自定义经济模型」的反馈；不影响平台收入。嫌复杂就固定 50% |
| 5 | 报价币 | 同 V2（BNB + 白名单报价币，代码现成）；嫌复杂第一版只做 BNB |
| 6 | V2 曲线还开不开新币 | 网站新建入口只留打新；V2 继续服务已有的币 |
| 7 | 平台打新收入下降（§3 #2） | 需要你确认能接受 |
| 8 | 打新 / 池子比例、份数 | 50 / 50、10,000 份。「最低 100 人」靠 50 / 50 推出来，改比例就要重算上限 |
| 9 | 各参数上下限 | 募集 5–50 BNB、上限 0.25%–0.5%（2026-10-27 前为 0.1%–0.5%，另有截止 1–72 小时，已删） |
| 10 | 创建时 dev 至少打 1 份 | 建议要求，挡零成本刷币 |
| 11 | 上线前核实 | 已完成：Agent ID 灵魂绑定（链上确认）；一人只能开 1 个 Agentic Wallet（用户实测）。防刷沿用单地址上限，不加平台签名 |
| 12 | 打新 / 撤出手续费 | 用户定：dev 创建时分开设，默认 1% / 1%；撤出费全给平台（2026-10-26）。范围 2026-10-27 起改为打新 1%–3%、撤出 1%–2% |
| 13 | 截止时间与退款 | 用户定（2026-10-27）：不设截止时间、没有退款，打满前随时按打新价卖回；Claude 建议并经同意：打新费当笔给平台、单地址 0.25%–0.5%、7 天没有进展免撤出费、停滞的 sale 默认折叠 |
