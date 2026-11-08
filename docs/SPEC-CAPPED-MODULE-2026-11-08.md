# 规格 · 税收封顶模块（GangCappedSplitter，`capped-v1`）

- 日期：2026-11-04 起草，2026-11-08 实现
- 基础：本仓库 GangComboSplitter（`combo-v1`）
- 状态：已实现；BSC 测试网已部署并验收（`docs/TESTNET-CAPPED-MODULE-2026-11-08.md`），主网未部署
- 代码里的 K-、I- 编号和 § 引用都指本文件

## 1. 做什么

一个 3.0 V3 有税币的收款合约。dev（及合作方）从税里拿一定比例，**累计拿到写死的上限后，就再也拿不到**，之后这份税全部转去回购销毁和加池。

对外可以这样说：**dev 从税里最多拿 X BNB，写死改不了；拿满之后，这份税全部回到币上。**

### 收款规则

模块收到的报价币（入账额 `incoming`）这样拆：

| 阶段 | 给收款人 | 其余 |
|---|---|---|
| 封顶前 | `incoming × payBps`，且不超过剩余额度 `capAmount - paidTotal` | 按固定比例留作回购和加池 |
| 封顶后 | 0 | 全部按同一比例留作回购和加池 |

跨过上限的那一笔，收款人只拿到剩余额度，多出来的全部进回购和加池，分毫不差。

### 算一笔账

买卖税 3%、分红 40%、收款人比例 50%、上限 20 BNB、其余 70% 回购 / 30% 加池。池子成交 100 BNB 时：

| 去向 | 封顶前 | 封顶后 |
|---|---|---|
| 平台（成交额的 0.5%） | 0.50 BNB | 0.50 BNB |
| 持有人分红（剩余 2.5 的 40%） | 1.00 BNB | 1.00 BNB |
| 模块收到（剩余 2.5 的 60%） | 1.50 BNB | 1.50 BNB |
| → 收款人 | 0.75 BNB | 0 |
| → 回购 | 0.525 BNB | 1.05 BNB |
| → 加池 | 0.225 BNB | 0.45 BNB |

### 多少成交量会封顶

`封顶成交量 ≈ capAmount / ((税率 - 0.5%) × (1 - 分红比例) × payBps)`。税收是分块卖成报价币的，实际数字会略有出入。

| 税率 | 分红 | payBps | 上限 | 封顶成交量 |
|---|---|---|---|---|
| 3% | 40% | 50% | 20 BNB | 约 2,667 BNB |
| 3% | 40% | 50% | 10 BNB | 约 1,333 BNB |
| 3% | 0% | 100% | 20 BNB | 800 BNB |
| 5% | 0% | 100% | 20 BNB | 约 444 BNB |

## 2. 封顶管什么、不管什么

**这一节决定对外口径，必须写进运营文档和网站。**

| 项目 | 是否受封顶限制 | 说明 |
|---|---|---|
| 毕业后，税里给收款人的部分 | **受限** | 模块的全部承诺就是这一项 |
| 曲线手续费分成（1% 里的 70%） | 不受限 | 留在 pad 上由创建者领取，可领到任意地址（`claimCreatorFee`），模块碰不到 |
| dev 持有的代币 | 不受限 | dev 可以持币、卖币。封顶不是锁仓 |
| 持有人分红 | 不相关 | 由 `dividendBps` 决定，建币时写死，封顶前后不变 |

## 3. 关键决定

| # | 决定 | 理由 |
|---|---|---|
| K-1 | 新写一个合约和工厂，不改 `GangComboSplitter` 的源码 | 组合模块已上线，不动它的源码，线上代码和仓库才能继续对得上。复制后只改拆分部分，审计可以只看和组合模块的差异。源码注释写明“改动要同步” |
| K-2 | `capAmount`、`payBps`、回购比例、收款人、份额全部写死，谁都不能改 | 和组合模块同样的理由。封顶的价值就在于不可改 |
| K-3 | 每个收款人可以把自己那一份换到新地址（`setPayee`），但份额和总额度不变 | 同组合模块，对上限没有影响 |
| K-4 | 上限按**全体收款人合计**算，不分人计算 | 对外的承诺就是一个数字 |
| K-5 | 上限以报价币最小单位记账，`create` 时写明报价币 `capQuote`；`bind` 时币的报价币不一致就回滚 `WrongQuote` | 模块建于发币之前。不写明的话，“20”到底是 20 WBNB 还是 20 USDT 要等绑定后才知道 |
| K-6 | 记入 `paidTotal` 的时点是拆分时，不是到账时。推送失败记成欠款也算已付 | 否则收款人拒收就能让额度不被消耗，同时欠款继续累积，可能超过上限 |
| K-7 | 报价币被扣（`Shortfall`）时，各部分余额按比例缩减，`paidTotal` 不回退 | 上限只会更早用完，绝不会被放大。USD1 这类可冻结报价币才可能遇到 |
| K-8 | 绑定的报价币以外的资产，**全部打进 0xdead**，收款人一分不拿（打不进去的留在合约里） | 其他资产无法计入上限。如果像组合模块那样分给收款人，dev 就能绑一个诱饵币，让真币的税走“其他资产”绕过上限 |
| K-9 | 封顶后的去向只能是回购和加池，不能是持有人分红 | 分红金库只接受 pad 或绑定的税处理器写入，模块无权写入。见 §9 D-1 |
| K-10 | `payBps` 允许 1–10000（最高 100%），`capAmount` 只要求大于 0 | 合约无法判断多少才算合理。靠网站和 CLI 明示金额和进度，见 §9 D-2 |
| K-11 | 回购和加池的节奏、价格保护、keeper 计划全部沿用组合模块 | 4 分钟一块、每块不超过储备的 0.5%、TWAP 2% 保护，以及 `previewWork` 把动作编进 `minOut` 最高字节，都已经审计和上线 |
| K-12 | 只部署给 GangLaunchpad 3.0（admin `0xC833…Af76`） | CLI 已把 3.0 作为发币目标 |

## 4. 合约接口

### 工厂 `GangCappedSplitterFactory`

```solidity
function create(
    address capQuote,        // 上限的计价币，也是将来绑定的币的报价币
    uint256 capAmount,       // 上限，> 0
    uint16 payBps,           // 封顶前给收款人的比例，1–10000
    uint16 buybackOfRestBps, // 其余部分里回购的比例，0–10000，加池得到剩下的
    address[] calldata payees,  // 1–10 个，不重复、非 0、不能是模块本身
    uint16[] calldata shares,   // 每个至少 1，合计 10000
    bytes32 salt
) external returns (address module);
```

- 只有 Agent 能调用。克隆、初始化、`listModule(module, "capped-v1")` 在同一笔交易内完成，和组合工厂一样。
- 地址由 `predict(dev, salt)` 给出，dev 是 salt 的一部分。
- 没有收款人的情况不支持：那就是 `--buyback` 加 `--lp` 合计 100% 的组合模块。

### 模块 `GangCappedSplitter`

实现 `IGangRecipientModule`（`moduleType` = `capped-v1`）。

| 和组合模块相同 | 变化 |
|---|---|
| `bind`、`split`、`chunk`、`work`、`previewWork`、`previewChunk`、`release`、`setPayee`、`payeesOf`、`owedOf`、`keeperServes`、`unsplit`、`undistributed` | `bind` 增加报价币检查；`distribute` 和 `release` 对其他资产的处理见 K-8 |

新增状态和查询：

```solidity
address public capQuote;
uint256 public capAmount;
uint16  public payBps;
uint16  public buybackOfRestBps;
uint256 public paidTotal;      // 已计入额度（含欠款），只增不减，永远 <= capAmount

function capLeft() external view returns (uint256);    // capAmount - paidTotal
function capReached() external view returns (bool);    // paidTotal == capAmount

event CapReached(uint256 capAmount);
event Split(uint256 incoming, uint256 toBuyback, uint256 toLp, uint256 toPayees); // 和组合模块同一顺序，见 §11
error BadCap();
error WrongQuote();
```

### 拆分算法

`_splitQuote` 和 `_afterSplit` 必须调用**同一个**内部函数，避免预览和实际执行不一致。这一点比组合模块更严格。

```solidity
function _partsOf(uint256 incoming, uint256 paid)
    internal view returns (uint256 toPayees, uint256 toBuyback, uint256 toLp)
{
    toPayees = (incoming * payBps) / BPS;
    uint256 left = capAmount - paid;
    if (toPayees > left) toPayees = left;
    uint256 rest = incoming - toPayees;
    toBuyback = (rest * buybackOfRestBps) / BPS;
    toLp = rest - toBuyback;
}
```

顺序：先更新 `paidTotal`、`buybackLeft`、`lpLeft`，再推送给收款人；`paidTotal` 第一次到达 `capAmount` 时发 `CapReached`（只发一次）。

## 5. 不变量

| # | 不变量 |
|---|---|
| I-1 | 任何时刻 `paidTotal <= capAmount` |
| I-2 | 收款人累计收到的绑定报价币加上欠款，不超过 `capAmount` |
| I-3 | 每次拆分 `toPayees + toBuyback + toLp == incoming`，分毫不差 |
| I-4 | 封顶后，新到的报价币全部进回购和加池 |
| I-5 | `previewWork` 和 `previewChunk` 用的 `_afterSplit` 结果，与紧接着执行 `_splitQuote` 的结果相同 |
| I-6 | 其他资产不会有任何一部分到收款人手里 |
| I-7 | 初始化之后，上限、比例和份额不可改变，`setPayee` 只改地址 |
| I-8 | 收款人拒收、耗尽 gas 都不能阻止拆分、回购和加池 |

## 6. 可能的绕过方式

| 手法 | 结果 | 处理 |
|---|---|---|
| 绑定一个不同报价币的诱饵币，让真币的税走“其他资产” | 这部分税全部打进 0xdead，dev 拿不到 | K-8。网站发现模块绑定的不是这个币时隐藏比例并显示警告（组合模块已有） |
| 绑定一个相同报价币的诱饵币（dev 也是创建者，收款人也是这个模块） | 上限仍然有效，但回购和加池会用到诱饵币上，dev 可能从中获利 | 合约无法分辨。依赖同一个网站警告，CLI 的 `status` 也要提示。组合模块同样存在 |
| 建币时用了和 `capQuote` 不同的报价币 | `bind` 回滚，模块永远绑定不了，税留在合约里取不出来 | dev 自己的失误，持有人不受影响。CLI 在发币前预检，手动调用合约的人自负其责 |
| 把上限设得极高，再对外宣传“封顶” | 等于没有封顶 | 合约不限制。网站永远展示具体金额和进度，不发“已封顶”这类徽章，见 D-2 |
| 多个币共用一个模块 | 相同报价币时，额度合并计算，对 dev 不利；不同报价币按诱饵币处理 | 无需处理 |
| 把曲线手续费领到模块里 | 视作普通入账，要按比例拆分，dev 只亏不赚 | 无需处理。如果报价币不同，会被全部打进 0xdead，CLI 的 `creator-fee` 要提示 |

## 7. 测试和发布

### 测试

| 类别 | 内容 |
|---|---|
| 单元测试 | 把组合模块的测试改到本模块；跨越上限的那一笔精确到最小单位；一笔大额直接跨越；上限恰好用完；`payBps` 为 100%；只回购、只加池；收款人拒收时欠款计入额度；`Shortfall` 不回退 `paidTotal`；`WrongQuote`；其他资产全部打进 0xdead，打不进时留在合约里 |
| 不变量和模糊测试 | §5 全部，随机入账序列和随机收款人行为 |
| 配对税测试 | 对应 `GangComboSplitterPairTax` |
| 主网分叉 | 3.0 上的真实 PancakeSwap：发币、绑定、拆分、跨越上限，封顶后 keeper 循环执行回购和加池，LP 在 0xdead；WBNB 和一个稳定币报价各跑一遍 |
| 测试网验收 | 3.0 测试网，用很小的上限实际跨越一次；对账到最小单位 |

### 发布顺序

按固定流程：实现，审计，修复，独立复审，测试网，然后主网（多签执行 `setFactory`）。

1. 合约、工厂、部署脚本（`DeployGangCappedSplitterFactory.s.sol`，走 `GANG_PAD3`，校验运行时代码）。
2. 审计和复审，审计重点放在与组合模块的差异。
3. 部署到 3.0 测试网并验收。
4. 服务端和网站先上线，能识别 `capped-v1`。
5. 部署到主网，Safe 执行 `admin.setFactory(factory, true)`。
6. CLI 发版。

## 8. 配套改动

| 端 | 改动 |
|---|---|
| CLI | `gang create … --tax-cap 20 --tax-cap-share 50 [--split self:70,0x…:30] [--after-cap buyback:70,lp:30]`；不写 `--split` 时全给 dev，不写 `--after-cap` 时全部回购。不能和 `--buyback`、`--lp`、`--buyback-to`、`--lp-to`、`--recipient` 同用。报价币限制沿用 `untrustedBuybackQuote`。发币前预检报价币一致。新增 `gang capped status / distribute / release / set-payee / bind / chunk`；`creator-fee` 的 `payOutCmd` 加上新类型，并提示其他资产会被销毁 |
| keeper | 把 `capped-v1` 加入和 `combo-v1` 相同的分块类型 |
| 索引 | 识别 `capped-v1`，记录上限、已付和封顶事件 |
| 网站 | 币详情页展示：上限（金额和币种）、已领和进度、封顶前后的去向、封顶状态；明确写“只限制税收，不限制曲线手续费和 dev 持仓”；模块绑定的不是这个币时显示警告；`llms.txt` 更新 |

## 9. 决定（2026-11-08）

| # | 问题 | 决定 |
|---|---|---|
| D-1 | 封顶后要不要让税进持有人分红？ | **这一版不做，只回购和加池。** 分红要改税处理器，而 3.0 的税处理器地址不可变，相当于一次大改。回购销毁同样回馈持有人。真要做，和“分红发其他币”一起放到换税处理器时再做 |
| D-2 | 是否限制上限的取值，或者达到某个条件才显示徽章？ | **不限制，也不发徽章。** 永远展示具体金额和进度，让用户自己判断。合约里写死的阈值无法适应不同报价币和不同项目 |
| D-3 | 其他资产全部销毁（K-8）是否可以接受？ | **可以。** 有人误转的币会被销毁，但这是堵住绕过的最简单办法。运营文档要写明 |

## 10. 不做

- 不改 `GangTaxHandler`、3.0 pad 和分红金库。
- 不限制曲线手续费和 dev 持仓。
- 不支持把上限和“初始投入”挂钩：曲线发射没有开池本金，上限由 dev 直接写明。
- 不做上限到达后的自动通知。

## 11. 实现与审计（2026-11-08）

- 代码：`src/gang/GangCappedSplitter.sol`、`GangCappedSplitterFactory.sol`，部署脚本 `script/DeployGangCappedSplitterFactory.s.sol`，测试网验收 `script/CappedTestnetAcceptance.s.sol`。
- `Split` 事件保留组合模块的字段顺序 `(incoming, toBuyback, toLp, toPayees)`。事件 topic 只看参数类型，两种模块是同一个 topic；顺序一致，同一个解码器才不会读错字段。
- `Distributed` 也和组合模块同 topic，但含义不同：这里 `toDead` 为 0 表示资产留在合约里，不是给了收款人。索引要按 `moduleType` 区分。
- 审计 L-1（已修）：`capQuote` 必须是 keeper 服务的报价币（pad 的 WBNB、GANG、QuoteRegistry 里的币），否则 `BadQuote`。否则 dev 可以用自己发的报价币绕开上限，填错地址的模块也永远绑不上。
- 审计 I-4（已修）：主网部署脚本只接受 3.0 和 3.0 的 GangHandlerAdmin。
- 审计 I-1（索引和网站要做）：同报价币诱饵币（§6 第二行）比原来写的更严重：封顶后真币的全部税都变成诱饵币的买盘。一个模块在 `RouteRegistered` 里作为 recipient 出现不止一次时，网站不展示封顶并显示警告。
- CLI 参数用 `--tax-cap`、`--tax-cap-share`、`--after-cap`，不用 `--cap`：打新已经用了 `--cap`（每钱包上限）。

