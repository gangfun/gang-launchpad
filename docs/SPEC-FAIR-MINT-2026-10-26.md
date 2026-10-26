# 规格 · 打新发射（铭文式打进度）+ 发射前持有人奖励

- 日期：2026-10-26 Asia/Shanghai
- 作者：Claude（本页为产品规格 + 合约设计；**非执行单**）
- 性质：**禁止主网广播**。尚无合约代码。
- 来源：用户口述（2026-10-26）：「没有内盘的概念，跟以前铭文一样打进度。dev 自定义规则，但是我们要设置上下限，比如最低 100 人，最高 0.5%。内盘没有价格，只有打满了之后代币发射，内盘依旧保持 1% 的买卖税。发射后有默认 1% 的税费，发射前就在的地址如果持有代币保持 50% 就可以享有 1% 税费中的 50% 作为持有奖励，剩下的 50% 跟目前的税费外盘规则不变，回购 + 入金库。」
- 用户已定：固定价格打进度、打满即发射；打新阶段买卖各 1%；发射后 1% 税，50% 给发射前持有人、50% 回购 + 金库；dev 在平台上下限内设规则。
- 待批（Claude 建议，§9 汇总）：奖励算法、失败退款、税率是否可选、出局线是否给 dev 选、报价币范围、V2 是否下线新建；以及 Claude 自己定的打新 / 池子 50 / 50、10,000 份、各参数上下限。
- 2026-10-26 自审修订：改正 BNB 收款方式（V2 只收 WBNB）；补 §5.5 安全约束（管理员权限、托管资金）；补最后一笔截断、出局的误伤场景、开盘价措辞、接线遗漏；去掉「查 Agent ID 铸造时间」（ERC-721 不记录铸造时间）。
- 与 `SPEC-V3-ECONOMIC-TEMPLATES-2026-10-26.md` 的关系：本方案不需要模版市场，V3 分支搁置不删；可复用部分见 §6.3。

---

## 0. 一句话产品

dev 设好募集额、单地址上限和截止时间，所有人按**同一个价格**一份一份打；打满就自动加池子开盘，开盘价等于打新价。开盘后每笔交易 1% 税，一半分给**打新时就进来、而且一直没怎么卖**的人，一半照旧回购 GANG 和进金库。

---

## 1. 规则

### 1.1 dev 可设的参数（平台上下限）

| 参数 | 范围 | 默认 | 说明 |
|---|---|---|---|
| 募集额 `raise` | 5–50 BNB 等值 | 15 BNB | 打满即发射；非 BNB 报价币在创建时按参考池换算并锁定 |
| 单地址上限 `capBps` | 0.1%–0.5% 总量 | 0.5% | **最少参与地址数由它推出**：50% ÷ 上限（0.5% → 100 个，0.1% → 500 个） |
| 截止时间 `duration` | 1–72 小时 | 24 小时 | 到期没打满 → 失败退款 |
| 出局线 `holdBps`（待批，可选） | 30%–80% | 50% | 不开放则固定 50% |
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
| 准入 | 打新必须持 Agent ID（同 V2）；撤出 / 退款不要求 |
| 收款 | 同 V2：只收 ERC-20 报价币（BNB 用 WBNB），`transferFrom` 只拉实际成交的份数，不涉及原生 BNB |
| dev 预留 | 无。dev 想要筹码就和别人一样打，受同样的上限 |

### 1.3 打新阶段（没有价格曲线）

| 动作 | 规则 | 费用 |
|---|---|---|
| 打 `mint(n)` | 按份打；累计不超过单地址上限；最后一笔自动截到剩余份数，只按成交份数收钱 | 本金 + **1%** 手续费（手续费先托管，见下） |
| 撤 `withdraw(n)` | 打满前、截止前随时可撤；退回本金 − **1%** | 打入时的 1% 不退，撤出再收 1%，均即时进平台；之后即使项目失败也不再退 |
| 打满 | 最后一份打出的那笔交易里直接发射（§1.4） | 托管的打入手续费全部进平台 |
| 失败 `refund()` | 截止时没打满 → 每人自己领回**本金 + 打入手续费**，全额 | 0（待批，见 §9） |

- 代币在打的时候就记到地址上（钱包里看得到），但**发射前锁转账**：只有发射台能动（撤出 / 退款时收回）。这样既杜绝场外私下交易和抢先建池，也让「发射前的地址」= 打新的地址。
- 所有平台收入走现有 PlatformFeeBucket：80% 回购 GANG / 20% feeVault。

### 1.4 发射

打满那一刻：
1. 解锁代币，5 亿枚 + 全部募集本金进 Pancake V2 池子，LP 打到 0xdead（沿用 MigratorV2）。
2. 托管的打入手续费转给 PlatformFeeBucket。
3. 打开 1% 交易税（税只对池子买卖收，同 V2 有税代币）。

### 1.5 发射后：1% 税

| 去向 | 比例 | 说明 |
|---|---|---|
| 发射前持有人奖励（DividendVault） | 50%（= 成交额 0.5%） | 只给合格地址，见 §1.6 |
| 平台（PlatformFeeBucket → 80% 回购 GANG / 20% feeVault） | 50%（= 成交额 0.5%） | 与 V2 有税轨外盘相同 |

- 税先以代币累计，keeper 带最低成交额换成报价币后分账（同 V2，转账里不做 swap）。
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
| 每份价格 | 0.0015 BNB（+ 1% = 0.001515 BNB） |
| 单地址最多 | 100 份 = 500 万枚 = 0.15 BNB 本金 |
| 最少地址数 | 100 |
| 开盘池子 | 5 亿枚 + 15 BNB → 开盘价 3e-8 BNB / 枚，开盘 FDV 30 BNB |
| 平台打新收入 | 0.15 BNB（募集额的 1%）+ 撤出手续费 |
| 撤出 100 份 | 拿回 0.1485 BNB，平台留 0.003 BNB |
| 失败退款 100 份 | 拿回 0.1515 BNB（全额） |
| 一个只打 1 份的人 | 基准 50,000 枚；持仓低于 25,000 枚出局 |
| 开盘后日成交 100 BNB | 税 1 BNB → 合格持有人 0.5 BNB、平台 0.5 BNB |

---

## 3. 风险与取舍

| # | 风险 | 处理 |
|---|---|---|
| 1 | **女巫**：0.5% 上限下单钱包最多 0.15 BNB，大户只能多开钱包；单地址上限是公平性的全部依据 | 代码注释写的是 Agent ID 灵魂绑定、只能由 Binance Agentic Wallet 铸造（未在链上核实），所以 ID 不能转手复用。真正要查的是**一个人能开多少个 Agentic Wallet**；如果很容易，「100 人」就只是 100 个钱包，奖励也会集中到刷号的人手里。上线前必须查清 |
| 2 | **平台打新收入比 V2 少**：V2 按内盘成交额收 1%（曲线上来回交易多次），打新只按募集额收 1% | 用外盘 0.5% 和撤出手续费补；需要你确认能接受 |
| 3 | 开盘被机器人抢买 | 打新的人开盘正好保本，抢买是把价格往上推；第一版不加防狙击 |
| 4 | 打到 99% 有人大额撤出拖进度 | 撤一次要付 2%，且有截止时间兜底 |
| 5 | 有人提前在 Pancake 建同名池子并打入报价币 | 代币锁转账，打不进代币；MigratorV2 遇到已有池子直接用，对方打进的报价币等于白送，只会让开盘价略高 |
| 6 | 最后一笔打满的交易要建池子，gas 高 | 同 V2 毕业；预估页面提示 |
| 7 | 新 DividendVault 的最低份额 | **不能照搬主网的 100 万枚**：1 份只有 5 万枚、出局线 2.5 万枚（出局线 30% 时 1.5 万）。新 vault 设 10,000 枚（合约默认值） |
| 8 | 差一点没打满就全退 | 第一版接受。可选的后续改法：截止时达到 dev 设的最低比例也发射，池子只放已打出的同等数量，没打出的销毁，开盘价仍等于打新价 |
| 9 | 开盘市值比 V2 低 | 同样 15 BNB：V2 池子 2 亿枚 → 开盘 FDV 75 BNB；打新池子 5 亿枚 → FDV 30 BNB。池子深度相对市值更厚、价格更稳，但排行榜上的市值会显得小 |
| 10 | 有人另建交易对（如本币 / USDT）绕开税 | 沿用 V2 的已知限制：税只对官方池子收，奖励池规模取决于官方池子成交量 |
| 11 | 刷失败币 | 失败全额退、创建不收费，刷币零成本。可要求创建时 dev 至少打 1 份 |

---

## 4. 状态机

```
         create
           │
           ▼
   ┌──── Minting ────┐   mint / withdraw（截止前）
   │                 │
 打满             截止且没打满
   │                 │
   ▼                 ▼
 Launched          Failed ── refund()（每人自领，全额）
   │
   ▼
 交易 1% 税 → keeper process → 50% DividendVault / 50% PlatformFeeBucket
```

`Failed` 不需要专门交易触发：`block.timestamp > deadline && sold < 10,000` 即视为失败，第一个 `refund` 时记状态并发事件。

---

## 5. 合约接口（草案）

### 5.1 FairMintPad

```solidity
struct MintConfig {
    uint256 raise;      // 报价币计；BNB 等值须在 [5, 50] BNB
    uint16  capBps;     // [10, 50]，占总量
    uint32  duration;   // [1h, 72h]
    uint16  holdBps;    // 出局线；不开放则必须为 5000
}

function create(string name, string symbol, string logoURI, address quote, address refPool, MintConfig cfg,
    uint256 devShares) external returns (address token);          // 须 Agent ID；devShares = 创建时 dev 自己打的份数
function mint(address token, uint256 shares, uint256 minShares) external returns (uint256 accepted);
    // 须 Agent ID；最后一笔被截断到少于 minShares 时 revert；只 transferFrom 成交部分
function withdraw(address token, uint256 shares) external;
function refund(address token) external;
function mintedOf(address token, address user) external view returns (uint256 shares);
function baselineOf(address token, address user) external view returns (uint256 tokens); // 供奖励判断
function status(address token) external view returns (uint8); // Minting / Launched / Failed
function previewMint(address token, address user, uint256 shares)
    external view returns (uint256 accepted, uint256 cost, uint256 fee);
```

存储（每个币）：`creator, quote, sharePrice, capShares, deadline, holdBps, sold, escrowedFee, launched, failed, pair`；每地址：`shares, feePaid`。

### 5.2 FairToken

- 基于 `TaxLaunchTokenV3`（10 亿全部铸给发射台），税率固定 1%。
- 发射前：除发射台外一律不能转；发射台可从地址收回（撤出 / 退款用，不依赖用户授权）。
- 发射后：池子买卖收 1% → handler 累计；每笔转账调 handler 同步奖励份额（同 V2）。
- 创建代码放在独立的部署合约里，避免发射台超 24KB（V3 已验证这个做法）。

### 5.3 HolderRewardHandler（由 PostGradTaxHandlerV3 改）

- `notifyTax` / `process(token, minQuoteOut)`：同 V2，换完后 50% `dividendVault.depositReward`、50% `bucket.notifyAccrual`；`totalShares == 0` 时 100% 进 bucket。
- `syncShares(token, from, to)` 对每个地址：

```
base = pad.baselineOf(token, user)
if base == 0 or out[token][user]:            share = 0
elif balance < base * holdBps / 10000:       out[token][user] = true; share = 0; emit Disqualified
else:                                         share = min(balance, base)
```

- 打新阶段份额由发射台在 `mint` / `withdraw` 时直接写（发射前没有转账，也就不需要 handler 同步）；发射那一刻不需要遍历地址。

### 5.4 事件（索引服务据此改）

| 合约 | 事件 |
|---|---|
| FairMintPad | `Created(token, creator, name, symbol, logoURI, quote, raise, sharePrice, capShares, deadline, holdBps)` |
| | `Minted(token, user, shares, cost, fee, userShares, sold)` · `Withdrawn(token, user, shares, refund, fee, userShares, sold)` |
| | `Launched(token, pair, quote, tokenAmount, quoteAmount, feeToPlatform)` · `Failed(token)` · `Refunded(token, user, amount)` |
| HolderRewardHandler | `TaxAccrued` · `OuterTaxProcessed(token, quote, taxTokens, quoteOut, toHolders, toPlatform)` · `Disqualified(token, user, balance, baseline)` |
| DividendVault | 同 V2（`RewardDeposited` / `ShareSet` / `Claimed`） |

### 5.5 安全约束

打新期间发射台托管每个币最多 50 BNB 等值的本金，所以：

1. **没有任何管理员函数能动托管资金**：没有 flush、没有紧急提取。钱只有四个出口：撤出、失败退款、发射进池子、手续费进 bucket。
2. **规则创建时快照**：单地址上限、准入开关、截止时间、出局线都存进该币自己的配置。V2 的 `setWalletCapEnabled` / `setAgentGate` 这类全局开关不能影响打新中的币，最好不提供 `setWalletCapEnabled`。
3. `setMigrator` / `setPairFactory` 只能设一次（V2 已是一次性）；发射时钱和币只能去这个 migrator。
4. FairToken 的「发射台收回」只在发射前有效，发射后永久失效，且只能收回该地址打到的数量。
5. 撤出、退款全部由用户自己领，不遍历地址；`nonReentrant`。
6. 报价币只接受白名单里的标准 ERC-20，不支持转账扣费的币（退款要求精确记账）。
7. 奖励判断只看「发射时数量」，池子、handler、migrator、发射台的基准天然为 0，不依赖 `excluded` 名单。

---

## 6. 部署

### 6.1 顺序

QuoteRegistry（复用）→ DividendVault（**新部署**，最低份额 10,000 枚）→ PlatformFeeBucket（复用）→ HolderRewardHandler → FairTokenDeployer → FairMintPad → MigratorV2（新实例，launchpad = FairMintPad）→ 接线。

### 6.2 接线

- PlatformFeeBucket：FairMintPad、HolderRewardHandler 设为 operator。
- DividendVault：`setLaunchpad(FairMintPad)`；HolderRewardHandler 设为 operator；池子、handler、migrator、0xdead 排除。
- HolderRewardHandler：`setKeeper`、`setDexRouter`。
- FairMintPad：`setMigrator`、`setPairFactory`（均一次性）、Agent ID 注册表、bridge 池（非 BNB 报价币用）。
- 每个币：创建时发射台 `dividendVault.registerToken(token, quote)`；发射时 `setPair`、`setTaxHandler(HolderRewardHandler)`、migrator 免税。

### 6.3 从现有代码复用

| 来源 | 用途 |
|---|---|
| V2 `MigratorV2` / `PoolCheck` / `QuoteRegistry` / Agent ID 判断 | 建池、报价币换算、准入，原样用 |
| V2 `DividendVault` / `PlatformFeeBucket` | 原样用（vault 新部署一份） |
| V3 分支 `TaxLaunchTokenV3` + 部署合约 | 改成 FairToken |
| V3 分支 `PostGradTaxHandlerV3` 的换币代码、`TaxRouterV3` 的「没人有份额就转平台」 | 并入 HolderRewardHandler |
| 不用 | TemplateRegistry、TaxRouterV3 分账、模版工厂 |

---

## 7. 测试清单

1. 参数上下限：每个参数越界都 revert，并给出原因。
2. 打新：单地址上限、最后一笔截断、非 Agent 不能打、截止后不能打。
3. 撤出：本金 −1%、打入手续费不退、上限额度释放、份额同步。
4. 失败：截止后全额退（本金 + 打入手续费）；退两次 revert；发射前代币不能转。
5. 发射：最后一份触发；池子数量与开盘价 = 打新价；LP 在 0xdead；托管手续费进 bucket；已存在池子的情况。
6. 奖励：只有打新地址有份额；卖出后份额按持仓下降；跌破出局线永久出局、买回不恢复；收别人筹码份额不超基准；出局前奖励可领；没人合格时 100% 进平台。
7. 权限：owner 在打新中改任何设置都不影响该币的上限 / 准入 / 截止；没有任何路径能把托管资金转给 owner。
8. 最后一笔：截断后只拉成交部分；低于 `minShares` revert；建池失败时整笔回滚，币保持打新中直到截止。
9. fork 测试：真实 Pancake 池子、USDT 类报价币、keeper `process`。

---

## 8. 各端要改的

| 端 | 内容 |
|---|---|
| gangfun-server | 索引 §5.4 事件；币状态（打新中 / 已发射 / 失败）、进度、参与地址数、倒计时；每地址基准 / 是否出局 / 可领奖励 |
| gang.fun | 打新页（进度条、每份价格、我的份数、撤出、失败退款）；代币页「持有奖励」：合格 / 已出局、当前权重、可领；风险提示（转钱包、加池子会出局） |
| CLI / skill | `gang create --raise 15 --cap 0.5 --hours 24`、`gang mint <token> <份数>`、`gang withdraw`、`gang refund`、`gang rewards`；preflight 显示费用与出局线 |
| 审计 | 发射台 + FairToken + handler，主网前外部审计 |

---

## 9. 待批（Claude 建议）

| # | 问题 | 建议 |
|---|---|---|
| 1 | 奖励算法 | 按当前持仓加权、上限为发射时数量；低于 50% 永久出局（§1.6） |
| 2 | 打新失败退不退打入的 1% | 退，全额。失败还收手续费伤口碑，这点收入不值 |
| 3 | 发射后税率 | 第一版固定 1%，不让 dev 选 |
| 4 | 出局线给不给 dev 选 | 可以给（30%–80%），这是 dev 唯一能调的经济参数，也回应了「自定义经济模型」的反馈；不影响平台收入。嫌复杂就固定 50% |
| 5 | 报价币 | 同 V2（BNB + 白名单报价币，代码现成）；嫌复杂第一版只做 BNB |
| 6 | V2 曲线还开不开新币 | 网站新建入口只留打新；V2 继续服务已有的币 |
| 7 | 平台打新收入下降（§3 #2） | 需要你确认能接受 |
| 8 | 打新 / 池子比例、份数 | 50 / 50、10,000 份。「最低 100 人」靠 50 / 50 推出来，改比例就要重算上限 |
| 9 | 各参数上下限 | 募集 5–50 BNB、上限 0.1%–0.5%、截止 1–72 小时 |
| 10 | 创建时 dev 至少打 1 份 | 建议要求，挡零成本刷币 |
| 11 | 上线前核实 | 一个人能开多少个 Binance Agentic Wallet；Agent ID 灵魂绑定是否属实 |
