# 规格 · 内盘手续费分给 creator（pons 模式，70%）

- 日期：2026-10-31 Asia/Shanghai
- 作者：Claude（按用户 2026-10-31 的决定：参考 pons，内盘给 creator 奖励，比例 70%；只做 V3 曲线）
- 性质：**合约已改，未部署**。合约 `src/gang/CurveLogic.sol`、`src/gang/GangLaunchpad.sol`，接口 `src/gang/interfaces/IGangLaunchpad.sol` / `IGangPad.sol`，测试 `test/gang/CreatorFee.t.sol`（其余改动见 §6）。已部署的 GangLaunchpad 不能升级，这套规则只对新一代 pad 上创建的币生效（§7）。

## 一句话

V3 曲线（内盘）每笔买卖仍然只收 1% 手续费，其中 70% 记给这个币的 creator，30% 进平台 bucket。creator 随时自己领取，毕业前后都可以领。

## 1. 参考：pons

pons 每笔交易收 1% 手续费，70% 给 creator，30% 给协议（协议那份大部分用于回购销毁 PONS）。我们只照搬内盘这部分：

| | pons | 本规格 |
|---|---|---|
| 内盘手续费 | 1% | 1%（不变） |
| creator 分成 | 70% | 70%（成交额的 0.7%） |
| 平台分成 | 30% | 30%（成交额的 0.3%），进 bucket 后照旧 80% 回购 GANG 销毁、20% 进 feeVault |
| 毕业后 | 仍是 1% / 70% | 不变：外盘按币的买卖税走（平台拿成交额 0.5%，剩下按 `dividendBps` 分给持币人和接收地址） |
| 打新 | 无 | 不做：打新费、撤出费的分配不变（用户 2026-10-31 选定） |

## 2. 规则

| 项 | 规则 |
|---|---|
| 范围 | 只有 V3 曲线币（`kindOf == 1`）的内盘买卖。有税币、无税币一样 |
| 手续费 | 每笔 `protocolFee = 1%`，算法和以前完全一样（买入按实际花掉的 gross，卖出按曲线付出的 `quoteOut`）。交易者付的钱、拿到的币、报价都不变 |
| 拆分 | `creatorFee = protocolFee × 7000 / 10000`（向下取整），`platformFee = protocolFee − creatorFee`。零头归平台 |
| creator 那份 | 留在 pad 上，记在 `creatorFeeOf[token]`（报价币，按币分开记）；当笔发 `CreatorFeeAccrued(token, creator, amount)` |
| 平台那份 | 当笔推给 bucket（`notifyAccrual`），bucket 拒收则整笔回滚，和以前一样 |
| 谁算 creator | `curves[token].creator`，即调用 `create` 的地址，创建后不能改 |
| 领取 | `claimCreatorFee(token, to)`：只有 creator 本人直接调用（路由不能代领），把 `creatorFeeOf[token]` 全部转给 `to`，清零，发 `CreatorFeeClaimed(token, creator, to, amount)`。`to` 不能是 0 或 pad 自己；没有可领的回滚 `ZeroAmount`；不是 creator 回滚 `NotCreator`；不是本 pad 的曲线币回滚 `UnknownToken` |
| 什么时候领 | 毕业前后都可以，没有期限。毕业不会动这笔钱（迁移只用 `realQuote`） |
| creator 自己的交易 | 也照常计入。creator 自买自卖实际只付 0.3% |
| 收不到款的 creator | 交易从不向 creator 转账，所以 creator 被报价币拉黑、或者是拒收的合约，都不会卡住交易；creator 可以把钱领到别的地址 |

为什么用领取而不是每笔直接转给 creator：直接转的话，creator 只要让转账失败（例如报价币把它拉黑），就能让这个币的所有买卖回滚。

## 3. 接口改动

新增（pad 地址上）：

| 名称 | 说明 |
|---|---|
| `CREATOR_FEE_SHARE_BPS() → 7000` | creator 占 1% 手续费的比例 |
| `creatorFeeOf(token) → uint256` | 这个币还没领的 creator 分成（报价币单位） |
| `claimCreatorFee(token, to) → amount` | 见 §2 |
| `event CreatorFeeAccrued(address indexed token, address indexed creator, uint256 amount)` | 每笔内盘买卖发一次（`amount > 0` 时） |
| `event CreatorFeeClaimed(address indexed token, address indexed creator, address indexed to, uint256 amount)` | 领取时发 |
| `error NotCreator()` | |

保持不变：`Buy` / `Sell` 事件（字段、topic0 都不变，`protocolFee` 仍是整笔 1%，其中 creator 那份看同一笔交易的 `CreatorFeeAccrued`）、`curves` 的 12 个字段、`PROTOCOL_FEE_BPS = 100`、所有已有函数的签名。`GangPadRegistry.previewBuy` / `previewSell` 的 `fee` 仍是整笔 1%，报价不受影响，registry 不用升级。

## 4. pad 上的钱

同一个报价币 q，pad 持有的余额：

```
balanceOf(pad, q) = Σ 未发射 sale 的 (已售份数 × 每份价格) + owedFee[q]
                  + Σ 未毕业曲线的 realQuote
                  + Σ 报价币为 q 的曲线的 creatorFeeOf（未毕业和已毕业都算）
                  + 零头
```

零头只增不减。`claimCreatorFee` 让余额和 `creatorFeeOf` 同时减少同样的数，零头不动。

## 5. 风险和取舍

- **平台内盘收入降到原来的 30%**：每笔从成交额的 1% 降到 0.3%。bucket 的回购和 feeVault 按比例减少。
- **刷量更便宜**：creator 自买自卖，每笔实际只付 0.3%，用来做假成交量的成本变低。pons 一样有这个问题，这里接受。
- **刷币赚手续费**：creator 能拿到的只是别人交易手续费的 70%，自己的钱换不出净收益；但用一个币吸引别人交易就能获利，这正是本规格要的激励。
- **自己推毕业更便宜**：用小号把自己的币买到毕业，手续费的实际成本也从 1% 降到约 0.3%。按"毕业数"或"成交量"发的平台激励、榜单要重新评估。
- **creator 分成不走税收接收方**：70% 永远给 `curves[token].creator`，不管接收地址是不是回购 / Split / LP 模块，也不管是不是 `dividendBps = 10000`（税全给持币人）。CLI 和网站介绍这些模块时要写明"内盘 creator 分成另算，归 creator 本人"，免得和"dev 收入全部回购"之类的说法冲突。
- **creator 地址不能改**：私钥丢了，分成就永远锁在 pad 上（pad 没有 sweep / rescue）；私钥被盗，以后的分成也会被领走。creator 是不能主动发起调用的合约时同样领不出来。目前所有 `create` 都由 EOA 或 Agentic Wallet 直接发起，暂不处理；以后任何代用户调 `create` 的合约都要把"能调 `claimCreatorFee`"列为审计项。
- **合约持有的钱变多**：pad 现在会长期持有 creator 没领的分成。审计重点见 §8。

## 6. 测试

- 新增 `test/gang/CreatorFee.t.sol`：拆分比例和事件、卖出、路由 `buyFor` / `sellFor`、BNB 经 GangRouter 买入、只有 creator 能领、领到任意地址、只能领一次、各种回滚、毕业后照样能领、两个同报价币的币互不影响、creator 被拉黑时交易不受影响，以及买卖守恒的 fuzz。
- 已有断言改成新规则：`LaunchpadV3.t.sol`（bucket 收 30%、creator 70%）、`LaunchpadV3Fuzz.t.sol`、`OriginTrader.t.sol`、`MergeGuards.t.sol`（pad 事件清单加两个新事件，托管对账加 creator 分成）、`PadMergeGuards.t.sol`、`FairMixedIsolation.t.sol`。
- 不变量 `CoreInvariants.t.sol`：handler 新增 `v3ClaimCreatorFee` 动作；每笔内盘交易检查 bucket + creator = 1%、creator = 其中 70%；领取必须正好付出记账的数；pad 余额恒等式（§4）把 creator 分成算进去。
- 审计后补充（§9）：同一个 WBNB 下两条曲线 + 一个打新 sale 依次经过 bucket 拒收（曲线交易整笔回滚、不记分成；打新撤出费转为 owed）、`flushFees`、发射、毕业、两个 creator 领取的确定性用例；不变量里领取失败计为错误，不再被忽略。
- 本地结果：非 fork 测试 1151 通过 / 0 失败 / 103 跳过（改动前 1140 / 0 / 103）。fork 测试 36 通过 / 3 失败，和改动前的 `origin/main` 一样：`RouterPoolFork` 的两个 `test_fork_pool_fair*` 在 `origin/main` 上同样失败，另一个是 RPC 缺历史状态（missing trie node）。

## 7. 上线方式

已部署的 GangLaunchpad 不可升级，creator 分成只能在新部署的 pad 上生效：

- 旧 pad 上的币不变：内盘 1% 仍全部进 bucket，creator 拿不到分成。旧 pad 停止创建新币（`TokenDeployer.setLaunchpad(旧 pad, false)`），已有的币照常交易、毕业。
- 新 pad 需要新的 `GangTaxHandler`（handler 的 `launchpad` 只能设一次），共用现有的 vault、bucket、migrator、QuoteRegistry、TokenDeployer，由 Safe 把新 pad / 新 handler 接上。
- 构造或初始化时绑死 pad 地址的合约要为新 pad 重新部署：`GangRouter`（`pad` 在初始化时设定）、`GangBond`、`GangBuybackSplitterFactory`、`GangLiquiditySplitterFactory`（后两者还绑定 handler）。`GangGateway` 经 registry 找 pad，不用重部署，只要 registry `addPad(新 pad)`、新 pad `setRouter(gateway)`。
- `CurveLogic` 的 `buy` / `sell` 多了一个参数，selector 变了：新 pad 必须链接新部署的 `CurveLogic`（和 `FairLogic`），不能复用旧库地址，否则 pad 能创建币却无法交易，而且无法补救。部署自检要检查 `CREATOR_FEE_SHARE_BPS() == 7000`，并实际跑一笔买入、卖出和领取。
- 下游：
  - indexer 要索引新 pad 和两个新事件。`Buy` / `Sell` 的 `protocolFee` 是整笔 1%，平台收入要减去同一笔交易的 `CreatorFeeAccrued`。同一笔交易里 `CreatorFeeAccrued` 先于 `Buy` / `Sell` 发出，按交易聚合，不要按相邻日志配对。
  - 网站展示 creator 可领的分成。
  - CLI 增加领取命令，并把创建默认指到新 pad。旧 pad 没有 `creatorFeeOf` / `claimCreatorFee`，按 pad 代际分开处理。
  - `to` 是 pad 自己时回滚的是 `ZeroAddress`，提示文案要单独写。
- 部署脚本、Safe 批次和测试网验收另写记录文档，按「审计 → 修复 → 独立复审 → 测试网 → 用户确认后主网」的流程走。

## 8. 审计重点

1. `creatorFeeOf` 只在曲线买卖中增加、只在 `claimCreatorFee` 中减少；任何路径（毕业、打新的卖回 / 发射 / `flushFees`）都不能动用它。
2. 拆分后 bucket + creator 正好等于原来的 1%，交易者的支付、退款、报价逐 wei 不变。
3. `claimCreatorFee` 的权限（只有 creator）、重入（`nonReentrant`，先清零后转账）、`to` 的检查。
4. 同一报价币下多个曲线和打新 sale 共用 pad 余额时的隔离（§4 的恒等式）。
5. 打新币不能被当作曲线币来领取（`curves[token].creator` 为 0 时回滚 `UnknownToken`）。

## 9. 审计记录

2026-10-31 两个独立审计（互不知道对方结论，各自写了 Foundry PoC）。结论：无 critical / high / medium。

| 来源 | 级别 | 内容 | 处理 |
|---|---|---|---|
| A、B | low | creator 地址不能改，私钥丢失或 creator 是合约时分成会锁死 | 记入 §5，待产品决定是否加"设置领取地址"；目前不改 |
| B | low | 部署自检认不出旧 pad / 旧 `CurveLogic` | 记入 §7，在新 pad 的部署脚本里实现 |
| B | info | 不变量的领取动作吞掉回滚 | 已改：回滚计为错误 |
| A | info | 缺 bucket 拒收和同报价全路径的确定性用例 | 已补 `test_sameQuote_allPathsLeaveCreatorFee` |
| A、B | info | 刷量 / 自己推毕业更便宜；分成不走税收接收方模块；下游口径 | 记入 §5、§7 |

审计确认没问题的：交易者付出、拿到的数量和报价与改动前逐 wei 一致；毕业、打新发射、withdraw、`flushFees` 都不会动用 creator 分成；只有 creator 能领，打新币和陌生地址领取会回滚；重入被 `nonReentrant` 和"先清零后转账"挡住；creator 自买自卖无法净赚（fuzz）；`curves` 布局、`Buy` / `Sell` ABI、registry 的报价不受影响。

