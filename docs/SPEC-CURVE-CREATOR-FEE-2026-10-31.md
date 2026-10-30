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
- **合约持有的钱变多**：pad 现在会长期持有 creator 没领的分成。审计重点见 §8。

## 6. 测试

- 新增 `test/gang/CreatorFee.t.sol`：拆分比例和事件、卖出、路由 `buyFor` / `sellFor`、BNB 经 GangRouter 买入、只有 creator 能领、领到任意地址、只能领一次、各种回滚、毕业后照样能领、两个同报价币的币互不影响、creator 被拉黑时交易不受影响，以及买卖守恒的 fuzz。
- 已有断言改成新规则：`LaunchpadV3.t.sol`（bucket 收 30%、creator 70%）、`LaunchpadV3Fuzz.t.sol`、`OriginTrader.t.sol`、`MergeGuards.t.sol`（pad 事件清单加两个新事件，托管对账加 creator 分成）、`PadMergeGuards.t.sol`、`FairMixedIsolation.t.sol`。
- 不变量 `CoreInvariants.t.sol`：handler 新增 `v3ClaimCreatorFee` 动作；每笔内盘交易检查 bucket + creator = 1%、creator = 其中 70%；领取必须正好付出记账的数；pad 余额恒等式（§4）把 creator 分成算进去。
- 本地结果：非 fork 测试 1150 通过 / 0 失败 / 103 跳过（改动前 1140 / 0 / 103）。fork 测试 36 通过 / 3 失败，和改动前的 `origin/main` 一样：`RouterPoolFork` 的两个 `test_fork_pool_fair*` 在 `origin/main` 上同样失败，另一个是 RPC 缺历史状态（missing trie node）。

## 7. 上线方式

已部署的 GangLaunchpad 不可升级，creator 分成只能在新部署的 pad 上生效：

- 旧 pad 上的币不变：内盘 1% 仍全部进 bucket，creator 拿不到分成。旧 pad 停止创建新币（`TokenDeployer.setLaunchpad(旧 pad, false)`），已有的币照常交易、毕业。
- 新 pad 需要新的 `GangTaxHandler`（handler 的 `launchpad` 只能设一次），共用现有的 vault、bucket、migrator、QuoteRegistry、TokenDeployer，由 Safe 把新 pad / 新 handler 接上。
- 构造或初始化时绑死 pad 地址的合约要为新 pad 重新部署：`GangRouter`（`pad` 在初始化时设定）、`GangBond`、`GangBuybackSplitterFactory`、`GangLiquiditySplitterFactory`（后两者还绑定 handler）。`GangGateway` 经 registry 找 pad，不用重部署，只要 registry `addPad(新 pad)`、新 pad `setRouter(gateway)`。
- 下游：indexer 要索引新 pad 和两个新事件，网站展示 creator 可领的分成，CLI 增加领取命令并把创建默认指到新 pad。
- 部署脚本、Safe 批次和测试网验收另写记录文档，按「审计 → 修复 → 独立复审 → 测试网 → 用户确认后主网」的流程走。

## 8. 审计重点

1. `creatorFeeOf` 只在曲线买卖中增加、只在 `claimCreatorFee` 中减少；任何路径（毕业、打新的卖回 / 发射 / `flushFees`）都不能动用它。
2. 拆分后 bucket + creator 正好等于原来的 1%，交易者的支付、退款、报价逐 wei 不变。
3. `claimCreatorFee` 的权限（只有 creator）、重入（`nonReentrant`，先清零后转账）、`to` 的检查。
4. 同一报价币下多个曲线和打新 sale 共用 pad 余额时的隔离（§4 的恒等式）。
5. 打新币不能被当作曲线币来领取（`curves[token].creator` 为 0 时回滚 `UnknownToken`）。
