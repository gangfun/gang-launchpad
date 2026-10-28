# 规格 · GangBuybackSplitter（dev 税按比例回购销毁）

- 日期：2026-10-28 Asia/Shanghai
- 作者：Claude（产品规格 + 合约设计）
- 代码：`src/gang/GangBuybackSplitter.sol`；部署 / 检查脚本 `script/DeployGangBuybackSplitter.s.sol`；单测 `test/gang/GangBuybackSplitter.t.sol`（22 个）
- 测试网记录：`docs/TESTNET-BUYBACK-SPLITTER-2026-10-28.md`
- 来源：dev 需求（2026-10-28，经用户转达），用户确认：
  1. 只针对新币：dev 拿到的交易税，一部分回购，一部分到 dev 的地址；
  2. 回购的币销毁；
  3. 比例以后可以调整（由谁触发，按本文 §3、§4 的建议）。
  4. 不是每个 dev 都要：不需要的照旧把接收地址填自己。

---

## 1. 为什么是一个单独的接收合约

已上线的合约都不能改：`GangTaxHandler`、`GangLaunchpad`、`GangToken`、`SharedDividendVault` 不是代理，互相引用的地址也写死。只有 `GangRouter`、`GangPadRegistry` 可升级，与税的分配无关。

所以回购只能放在 **接收地址这一端**：V3 税收币的接收地址（recipient）本来就可以是白名单里的合约。handler 每卖完一块税，就把 recipient 那份报价币用普通 `transfer` 打过去：没有回调，也不带币地址；转账失败记为 `owedOf`，任何人可以 `release`。回购合约收下这笔报价币，按比例拆分。

一个合约只服务 **一个币**：handler 打款时不带币地址，一个共用合约分不清收到的报价币属于哪个币。所以想要回购的 dev，每个币部署一个；不想要的 dev 不受任何影响。

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

- 每个区块最多一块；
- 每块最多花掉交易对报价币储备的 `CHUNK_MAX_BPS` = 0.5%；
- 与交易对自己的 TWAP 比：窗口 `TWAP_WINDOW` = 10 分钟，现价比均价高出 `MAX_PRICE_RISE_BPS` = 2% 以上就不买（返回 (0, 0)，不回滚）；
- 超过 2 倍窗口没人调用，观测点从头开始，那一次只记观测点。

所以谁来调都无法夹它，`minTokensOut` 可以填 0。keeper 定时调用即可（§6）；dev 或任何人也可以自己调。毕业前调用回滚 `NotTradable`（还没有交易对，而且毕业前根本不收税）。

`previewBurn()` 返回这一次会不会买、花多少、销毁多少（已扣买入税）。

## 5. 其它规则

- **绑定**：`bind(token)` 任何人可调，只能绑一次。要求：V3（curve）币、创建者是 dev、handler 里这个币的 recipient 是本合约。设成任何人可调，是为了防止 dev 故意不绑、再用 `sweep` 把报价币拿走。
- **`sweep(asset)`**：绑定后，把绑定报价币以外的任何资产全部转给 dev（别的币把它填成 recipient、用别的报价币付的税，或者别人误转进来的）。绑定前不能 sweep。用绑定报价币付的税，不管来自哪个币，都按比例拆分。
- **dev 收不到款**：报价币把 dev 拉黑时，推送失败不回滚，那部分记为 `devOwed`，回购照常进行；`releaseDev`（任何人可调）补发，dev 仍收不到时回滚，欠款不会丢。
- **余额被扣**：报价币余额少于账上应有的数（被没收、rebase）时，下一次拆分把差额按比例从回购余额和 dev 欠款两边扣（`Shortfall` 事件），合约继续能用。
- **没有 owner、不可升级**：只读 pad 和 handler 的公开 view，只和这个币的交易对交易；不需要 pad、代币、分红金库、handler 给它任何权限。

## 6. 接入步骤

| 步骤 | 谁 | 做什么 |
|---|---|---|
| 1 | 平台（或 dev 自己） | 跑 `script/DeployGangBuybackSplitter.s.sol` 部署：`GANG_PAD`、`SPLITTER_DEV`（dev 的收款地址，也是改比例的地址）、`SPLITTER_BPS` |
| 2 | 平台 | 用同一个脚本的检查模式（设 `SPLITTER`）核对：pad 是平台的、代码是本仓库的、dev 和比例与 dev 申请的一致、没有待执行的下调；然后把脚本打印的 Safe 批量交给多签执行：`handler.list(splitter, label)`、`divVault.setExcluded(splitter, true)` |
| 3 | dev | 发币时把接收地址填成回购合约：`gang create … --buy-tax … --sell-tax … --recipient <splitter>` |
| 4 | 任何人 | `bind(token)` |
| 5 | keeper | 毕业后定时调 `burnChunk(0)`，间隔 10–20 分钟；`buybackLeft()` 和 `unsplit()` 都为 0 时不用调（会回滚 `NothingToBurn`） |

- 为什么必须由平台检查后才能 list：pad 是构造参数，一个指向假 pad 的回购合约会从假交易对买入。检查模式会部署一个本地参照合约（不广播），比较 runtime code，代码相同就说明源码、pad、handler、dev 都相同。
- 为什么要从分红中排除：回购合约只在一块回购的过程中短暂持有代币，排除后不会给它写分红份额，也省掉金库的写入。
- 已经发出去的币不能改接收地址（handler 的 route 写一次就不能改），所以只适用于新币。

## 7. 风险与边界

- **比例是 dev 的承诺，不是平台的**：dev 可以在 3 天公告后把比例降到 0。平台检查时只保证 list 那一刻比例和 dev 申请的一致、没有正在走的下调。前端应展示 `buybackBps` 和 `pendingCut()`。
- **白名单地址对所有发币人开放**：别人也能把这个回购合约填成自己币的 recipient，但只会多给它钱（绑定报价币按比例拆分，其他资产 sweep 给 dev）；绑定只认 dev 自己的币。
- **回购慢**：每块最多 0.5% 储备、每 10 分钟左右一块，大额税要分很多块；价格被拉高时会暂停，直到高价成为均价。
- **报价币**：pad 接受的报价币（WBNB 或任意 18 位、不扣转账费的 ERC-20）都能用；黑名单和余额被扣的情况见 §5。

## 8. 测试

- 单测 `test/gang/GangBuybackSplitter.t.sol` 22 个：构造、绑定检查、按比例拆分和边界、提高立即生效、下调公告 / 作废 / 取消、毕业前拒绝、分块买完、拉盘后跳过、滑点、ERC-20 报价币、分红排除（含对照）、dev 被拉黑、两种余额被扣、部署脚本 `verify`（假 pad、冒充合约）、`expect`（dev、比例、待执行下调）、比例环境变量越界、sweep、外盘税端到端。
- 部署脚本在 BSC 主网分叉上模拟通过（`SPLITTER_BPS` 越界、缺失时拒绝）。
- 测试网整轮见 `docs/TESTNET-BUYBACK-SPLITTER-2026-10-28.md`。
