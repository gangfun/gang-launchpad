# 规格草案 · Agent 喊单区（展示 + 跟单分佣 + 喊单保证金）

- 日期：2026-11-09
- 性质：**草案，未实现、未审计**。三部分一起上线。2026-11-09 经过两轮独立审查（见第 8 节）。
- 对外名称：「信号区」（英文 Signals），对外文案不用「喊单」；标签「喊完就跑」对外叫「提前卖出」。本文内部仍叫喊单区。

## 1. 一句话

把 agent 已经在发的买入 note 做成一个公开的场子：每一单都是真实买入，先上链后公开，事后算战绩。跟单的人可以把喊单者绑成推广人，让喊单者从 dev 的手续费里分成；喊单者可以押保证金承诺持有，违约时一半销毁，其余按损失赔给跟单者。

## 2. 已有的基础（不重做）

| 能力 | 现状 |
|---|---|
| 喊单 | 买入 note：理由 + 置信度，承诺哈希写在 calldata 尾部，文本事后公开；可 sealed（1–72 小时后公开） |
| 跟单 | 买入的 calldata 带被跟 note 的完整 tx 哈希（`gang` 03）；24 小时窗口、只认内盘、至少 1 美元、不能跟自己 |
| 战绩 | agents 排行榜：命中率、置信度校准分、被跟人数和金额、跟单者胜率和平均收益 |
| 分佣 | 3.0 推广分成（`docs/SPEC-PROMOTER-SHARE-2026-11-04.md`），开了外盘延续的币还有池子分成 |

## 3. 喊单区（web + server）

**收录规则**：只收能跟单的买入 note 和发币宣言。没有交易的纯观点不收。

**信息流**：默认按喊单者分数排，另有「最新」「跟单最多」。每张卡片：

- 喊单者：handle、近 30 天战绩（命中率、校准分、跟单者胜率、守单率）；
- 代币：符号、进度、喊单时价格、到现在的涨跌；
- 跟单：人数、金额、窗口倒计时；
- 标签：`有担保`（附保证金、承诺持有量占喊单者持仓的比例、覆盖率 = 保证金 ÷ 跟单总额、保护到什么时候）、`跟单有分佣`（附比例和有效期）、`喊完就跑`、`违约`；
- 操作：复制跟单命令（`gang follow <tx>`）。站上不下单。

**喊完就跑**：跟单窗口内，喊单者在这个币上的余额低于这笔喊单买入量的 50%，卡片标出来，并计入「守单率」。没押保证金的单也适用。

**曝光**：首页给本周最佳喊单者一个位置；X 只推高分喊单者和有担保的单。门槛见第 7 节。

## 4. 跟单分佣（CLI + server，不改合约）

`gang follow` 在下面的条件都满足时，改用 `buyWithPromoter(token, funds, minAmount, 喊单者)`：

1. 代币在 3.0 pad 上，`promoteOf(token)` 有条款；
2. `canBind(token, 跟单者, 喊单者) == true`（跟单者第一次交易这个币、喊单者有 Agent ID、不是 creator 也不是跟单者本人）；
3. 交易由跟单者的钱包直接发出（`msg.sender == tx.origin`，否则 `TraderNotOrigin`；`canBind` 不查这一点）。baw 钱包直接发交易，满足。

calldata 尾部照旧是 `[tool][ref][follow][note]`，合约忽略尾部字节。条件不满足就照旧走普通买入，跟单本身不受影响。

**预览必须写清**：这笔会把你永久绑给 `<喊单者>`，有效期 `<N>` 天内你在内盘的每笔交易，dev 手续费里的 `<比例>` 分给他；你付的钱和拿到的币不变。给 `--no-promoter` 让跟单者不绑。

**server**：

- 索引要把 `buyWithPromoter` 的买入识别为买入和跟单（尾部按 tx input 读；选择器要加进识别清单），测试网验证。
- 同一笔交易里同时有跟单引用和 `PromoterBound` 的，记为「跟单绑定」。
- 喊单者的分佣收入从 `PromoterFeeAccrued(token, promoter, wallet, amount)` 按 wallet 归到具体跟单者，在喊单者页面单独展示，**不进战绩分**。

**已知的限制**：

- 只有 `createWithPromote` 发的币有分佣，目前很少。喊单区的 `跟单有分佣` 标签也是给 dev 开推广分成的理由。
- 绑定是永久的，先到先得：跟单绑了喊单者，别的推广链接就绑不上了。
- 喊单者砸盘后，跟单者恐慌卖出的手续费里也有喊单者的分成，合约管不到。分佣收入要和违约、`喊完就跑` 记录放在一起展示。

## 5. 喊单保证金（新合约 GangCallBond）

### 5.1 适用范围和押下时的检查

第一版只接 **3.0 pad 的内盘曲线币**。合约在 `post` 时检查：

- `pad` 是构造时写死的 3.0 代理地址（不读代币自己的 `launchpad()`，也不经 PadRegistry）；
- `pad.kindOf(token) == 1`（曲线；打新是 2，飞轮是 3，老 pad 的币在 3.0 上是 0）；
- `pad.tokenVersionOf(token) == 1`，钉住规则版本；
- `pad.curves(token).graduated == false`：已毕业的不能押（能跟单的 note 本来就只在内盘）；
- `pad.curves(token).quote` 是构造时写死的 4 个地址之一：WBNB、USDT、USDC、USD1。保证金用这个报价币；付 BNB 时合约包成 WBNB。

不接打新、飞轮、老 pad：打新是固定价格，算不出损失；飞轮铸币不经转账增加余额；不同 pad 的价格公式不同。

### 5.2 规则

| 项 | 规则 |
|---|---|
| 承诺 | 从押下起到 `settle` 执行，押款地址的 `balanceOf(token)` 始终 ≥ `hold` |
| 时长 | 48 小时 – 7 天。最短 48 小时：跟单窗口 24 小时，窗口最后一刻进来的跟单者也有 24 小时保护 |
| 每个币一份 | 同一地址同一代币同时只能有一份进行中的保证金 |
| 押下时 | 当前余额 ≥ `hold`，并通过 5.1 的检查 |
| 押下后 | 不能加减、不能延期、不能提前取回 |
| 违约 | 余额 < `hold` 时任何人可 `report`，**截止后、`settle` 执行前也算**（和 GangBond 相同）。举报人 1%、**50% 当场转 `0xdead`**、49% 进这份保证金的赔付池。押款地址自己举报时，那 1% 也销毁 |
| 守约 | 截止后任何人 `requestSettle`，1 小时后余额仍达标再 `settle`，全额退给押款地址。毕业后的 `settle` 另要求交易对（取 `curves(token).pair`，不取 `token.pair()`，不收税的币不设后者）的代币余额不低于储备，同 GangBond 的 `FlashSwapActive`；毕业前不查 |

**内盘期间余额怎么变**（按 3.0 现行实现核对过）：

- 代币转账锁住，只有 pad 能移动持仓。会让余额下降的入口：`sell`、`sellFor`、两个 `sellToken`（用给 pad 的授权拉币）、`vaultLock`。这些入口都只能由持有人本人发起（直接 `sell` 看 `msg.sender`，其余要求 `trader == tx.origin`），**第三方不能替喊单者卖出、逼他违约**。
- 会让余额上升的：买入、`vaultRelease`（没有上限）。`settle` 时余额达标就退款，余额是怎么回来的不影响。
- 毕业后转账放开，转走也算违约。

CLI 在押款地址有进行中保证金时，对卖出、`vaultLock` 和任何对这个代币的授权都先警告。同一份持仓可以同时担保一份 GangBond 和一份 CallBond，合约不排除。

### 5.3 赔付

赔付靠结算方发 Merkle root，模式和推广池模块一样（`docs/SPEC-PROMOTER-POOL-SHARE-2026-11-05.md` 第 4、5 节）。**所有输入只用链上数据**，任何人都能用参考实现的 `--check` 复算。

1. **余额只看区块末**。同一笔交易或同一个区块里先跌破又恢复的，不算。
2. **违约区块 `B`**：设 `report` 在区块 `R`。`B` 是 `R` 之前最后一个「区块末余额 ≥ `hold`」的区块的下一个区块；如果 `R` 前一个区块末余额就 ≥ `hold`，`B = R`。也就是举报所在的这一段连续跌破的起点。
3. **跟单买入**：一笔交易里 `trader == tx.from` 的 `TradeV1` 买入，加总这笔交易里的所有这类买入。条件：交易输入的跟单引用等于这份保证金的 `noteTx`；代币是这份保证金的代币；所在区块在 note 交易之后，时间不晚于 note 区块时间 + 24 小时，并且早于 `B`；买入者不是押款地址，也不是这个代币的创建者（创建者拿回 70% 手续费，反复买卖能低成本抬高自己的成本）。
4. **买入额和买入价**：买入额 = `TradeV1.quoteAmount` 之和（pad 实际收下的部分，退款已扣）；最低额按这个算（WBNB 0.002，稳定币 1 枚）。买入价 = 买入额 ÷ `tokenAmount` 之和。一个地址多笔跟单合成一个，按代币加权平均。
5. **参考价 `P_ref`**：`T_B` = 区块 `B` 的时间戳，取 `[T_B, T_B + 3600)` 里每一秒 `s` 的价格再平均。`s` 时的价格 = 时间戳 ≤ `s` 的最后一个区块结束时的价格。内盘价格取截至那个区块最后一笔 `TradeV1` 的 `postPrice`；毕业后取交易对 `Sync` 的储备算出的价格。
6. **损失**：设 `F_i` 是地址 i 第一笔跟单买入所在的区块，`T_i` 是它跟单买入得到的代币之和。
   - 在 [F_i, B) 内，i 的代币离开钱包有三种：内盘卖出（`TradeV1` 卖出）、锁进 vault（`VaultLocked`）、其他（外盘卖出、转给别的地址）。
   - 持仓 `e_i = min(T_i, max(0, B 开始时的余额 − F_i 开始时的余额 + vault 净锁仓))`：只算跟单之后净增加的部分，跟单之前就有的持仓不算；锁进 vault 的仍然算持有。vault 净锁仓 = [F_i, B) 内 `VaultLocked` 减 `VaultReleased`（不低于 0），已经取回钱包的部分在余额里，不重复算。
   - 退出抵扣 `X_i = Σ（每笔「其他」方式移出的代币 × max(这笔转账之前一刻的价格, 该区块结束时的价格, P_ref)）`：外盘卖出或转走的币按三者里最高的价格折算，从成本里扣掉（同一区块里先卖再砸盘，压不低之前那一刻的价格）。转给自己不算。
   - 净成本 `C_i = max(0, 跟单买入额之和 − i 在 [F_i, B) 内内盘卖出的额 − X_i)`：买入额和卖出额都取 `TradeV1.quoteAmount`（买入含 1% 手续费；卖出是扣手续费之前的数）。
   - `loss_i = max(0, C_i − e_i × P_ref)`。
   这样「大买再卖回」只剩真实花掉的钱；违约前已经在外盘卖掉获利的跟单者拿不到赔付；把币转走的人按至少 `P_ref` 计算，不会比一直持有拿得多。
7. **怎么分**：`Σloss ≤ 赔付池` 时每人赔满 `loss_i`；否则按 `loss_i` 比例分完（向下取整）。剩下的转 `0xdead`，**永远不回到押款地址**。
8. **叶子**：每个地址一片，`(合约地址, chainId, id, account, amount)`，哈希方式同 OpenZeppelin `StandardMerkleTree`。

**参考实现的取舍**（`scripts/callbond-settle/`，2026-11-09）：

- `B` 不早于押下所在的区块：跌破那一段如果从押下之前就开始，`B` 取押下的区块。
- 跟单买入必须在 note 交易之后的区块，和 note 同一区块的不算。
- 最低额按每笔跟单交易算（这笔交易里所有买入的和），不按地址累计。
- 每一步都向下取整：`P_ref` = 各秒价格之和 ÷ 3600，损失 = `C_i` − `e_i` × `P_ref` ÷ 1e18，按比例分时 = 损失 × 赔付池 ÷ 损失合计。剩下的零头留在赔付池里，最后销毁。
- 日志完整性：公共 RPC 可能不报错就漏掉一段日志，对不上就拒绝输出。核对三类：
  - 每个 `getLogs` 分段结束处的链上状态：曲线的 `sold` / `realQuote`、押款地址和每个跟单者的余额、毕业后交易对的储备；
  - 押款地址和跟单者在每笔内盘交易所在区块的余额；
  - 毕业前代币只能经 pad 移动：每段里 pad 转出、转入的代币（分开加总，不互相抵消），必须正好对应内盘买入、卖出、`vaultLock` 的两条腿和毕业迁移。
  仍然发现不了的：同一段日志在 `TradeV1` 和 pad 的转账里同时漏掉，而且这段交易恰好让 `sold`、`realQuote` 都不变；毕业后，跟单者的转入、转出查询漏掉同一段，那段里正好一笔外盘买入和一笔等量外盘卖出（交易对的 `Sync` 核对通常能发现）。
- 毕业时迁移产生的 `Sync` 在 `Graduated` 之前发出，所以毕业后的价格从毕业那笔 `TradeV1` 之后的 `Sync` 算起。
- 树的构造和推广池结算一样（叶子按哈希排序，奇数个时最后一个直接上移）。叶子哈希和合约一致，证明用 OpenZeppelin `MerkleProof` 验证；但 root 和 `@openzeppelin/merkle-tree` 对同样叶子算出的不同，复算要用参考实现的构造。
- 只有赔付大于 0 的地址有叶子；输出另有 `followers` 列出所有合格的跟单者（含损失为 0 的）。没有任何赔付时，root 用固定占位值 `keccak256("callbond-v1: no follower is owed anything")`，`total` = 0（合约不接受全 0 的 root）。
- `noteTx` 查不到回执时拒绝输出：分不清是假哈希还是节点丢了交易索引。这种保证金要手工发 `total` = 0 的 root，或等 `burnUnpaid`。
- 需要保留历史状态的节点（读过去区块的余额和曲线状态）；裁剪节点会报错，不会给出错误的数。
- 有税币的外盘卖出里，转给税收合约的那部分也按退出计价，诚实卖出者的抵扣会多算约「卖出税 × 数量 × 价格」，少拿一点；这是有意偏保守。
- 退出只按主交易对的价格计价；卖进另一个价格更高的池子时抵扣会少算差价，需要别人提供错价的流动性，套利会很快抹平。

### 5.4 note 和保证金怎么对上（`有担保` 的条件）

合约只存 `noteTx`（bytes32），不验证。server 在下面的条件都满足时，才把这条 note 显示为 `有担保`：

- `noteTx` 是押款地址自己在这个代币上的买入 note；
- 押下时间在 note 交易之后 10 分钟内，且这期间押款地址没有卖出；
- **`hold` 等于押下时押款地址在这个代币上的全部余额**：承诺一枚都不卖，包括 note 之前就有的持仓；
- 截止时间不早于 note 区块时间 + 48 小时；
- 一条 note 只认第一份满足条件的保证金。

不满足的照样受合约约束，只是喊单区不显示担保。卡片写明保证金、`hold`、覆盖率；每个跟单者看到「保护到 <截止时间>」。CLI 的 `gang buy --note … --bond <金额> --for <时长>` 先买、再押，`hold` 默认等于押下时的全部余额。

### 5.5 结算的状态机

时间点：`F` = 举报时刻（`reportedAt`）；`V` = 最近一次 `veto` 的时刻（没有则为 0）。

| 动作 | 谁 | 条件 |
|---|---|---|
| `postRoot(id, root, total)` | 结算方 | 已违约；没有待生效或已生效的 root；`now ≥ F + 1 小时 10 分钟`（`P_ref` 窗口结束并留出确认时间）；`now < F + 28 天` 或 `now < V + 3 天`，并且无论如何 `now < F + 60 天`；`total ≤ 赔付池`（可以为 0：没有合格的跟单者，争议期满后整个赔付池销毁） |
| `veto(id)` | Safe | root 发布后 2 天内；root 作废，记 `V = now` |
| `claim(id, account, amount, proof)` | 任何人 | root 发布满 2 天且没被 `veto`（不需要单独激活）；钱只转给 `account`，`account` 不能是押款地址（root 里有也领不了）；按 (id, account) 记已领；领取总额不超过 `total` |
| 剩余部分销毁 | 任何人 | root 生效后，`赔付池 − total` 可随时转 `0xdead` |
| `burnUnpaid(id)` | 任何人 | 没有待生效或已生效的 root，并且已经不能再 `postRoot`；或者 root 生效满 90 天。剩余的赔付池转 `0xdead`，终态 |

一笔领取失败（比如报价币拉黑了这个地址）只影响这一笔。Safe 连续 `veto` 能把销毁推迟，每次最多 3 天，最晚到举报后 60 天，但拿不到钱。

实现：`src/gang/GangCallBond.sol`、`src/gang/interfaces/IGangCallBond.sol`，测试 `test/gang/GangCallBond.t.sol`。

### 5.6 接口（草案）

```solidity
function post(address token, bytes32 noteTx, uint256 amount, uint256 hold, uint64 duration) external payable returns (uint256 id);
function report(uint256 id) external;
function requestSettle(uint256 id) external;
function settle(uint256 id) external;
function postRoot(uint256 id, bytes32 root, uint256 total) external;   // 结算方
function veto(uint256 id) external;                                    // owner（Safe）
function claim(uint256 id, address account, uint256 amount, bytes32[] calldata proof) external;
function burnRemainder(uint256 id) external;                           // root 生效后，赔付池 − total
function burnUnpaid(uint256 id) external;                              // 见 5.5
function bondOf(uint256 id) external view returns (...);
function activeBondOf(address caller, address token) external view returns (uint256 id);
```

事件：`CallBondPosted`、`CallBondReported`（带举报区块）、`SettleRequested`、`CallBondSettled`、`RootPosted`、`RootVetoed`、`Claimed`、`RemainderBurned`、`UnpaidBurned`、`SettlerSet`。

不可升级。owner 是 Safe，只能换结算方和 `veto`，不能放弃所有权（`renounceOwnership` 回滚）；结算方和 Safe 必须是不同账户。部署脚本要核对构造参数里的 WBNB 和 pad 用的一致。

### 5.7 信任边界

- **违约与否只由链上 `report` 决定**，结算方和 Safe 都改变不了；进行中的保证金和退款它们碰不到。
- **赔付池怎么分要信任结算方和 Safe**：合约验证不了叶子是不是真实的跟单者。结算方私钥被盗时，它可以发一个把整个赔付池给自己的 root，只有 Safe 在 2 天内 `veto` 能拦住。上限是这份保证金的 49%。这和推广池模块的信任模型一样。
- 销毁的 50% 和举报奖励在 `report` 时就在链上完成，不经过结算方。
- **依赖 3.0 pad 的现行实现**：「内盘只有 pad 能移动持仓、卖出必须本人发起」是 pad 现在的代码保证的。pad 是 Safe 可升级的代理，没有时间锁；升级后 5.2 的清单要重新核对。

### 5.8 已知的限制

- **用小号跟自己**：小号能按损失领回一部分赔付池。当场销毁的 50% 是喊单者无论如何都拿不回的，这是保证金的真实惩罚。小号也能当举报人拿 1%。不做基于资金关系的排除，root 要能确定性复算。
- **关联钱包**：`hold` 只覆盖押款地址。喊单者在别的钱包里的同一个币不受约束，合约和喊单区都看不出来。
- **违约后又买回**：`report` 只能在余额低于 `hold` 的时候成功。喊单者卖出后在举报上链前买回，这次违约就罚不到。危险的是「砸盘 → 跟单者恐慌卖出 → 低价买回」，这要好几个区块，举报 keeper 要走私有发送通道、在下一个区块就发。可选的加强：用 `blockhash` + 存储证明验证 256 个区块内的历史余额，第一版不做。
- **压低 `P_ref`**：任何持币人都可以在 `B` 之后卖出、把价格压一小时再买回，代价只有手续费，结果是跟单者多拿、销毁的少。这是任何时间均价都有的性质；跟单者拿到的仍然不超过自己的净亏损。
- **创建者的小号刷量**：代币创建者本人不算跟单者，但它控制的其他钱包、或绑定到它控制的推广人的钱包仍然算。内盘卖出按扣手续费前的数计入，一来一回只多算约 1%，实际成本约 2%，扣掉拿回的手续费后净多算约 0.4% 的刷量，总额受赔付池限制。
- **夹跟单者**：喊单者在跟单者买入前加仓、买入后卖出加的部分，余额始终 ≥ `hold`，不算违约。跟单者靠 `minAmount` 滑点保护。
- **截止后先卖再结算**：截止后、`settle` 前卖出照样违约。keeper 到期后替所有人调 `requestSettle` 和 `settle`；CLI 提示「先结算再卖」。
- **报价币拉黑**：押款地址被报价币拉黑时 `settle` 一直失败，保证金卡住且随时可能被举报。

## 6. 上线顺序

三部分一起上线，日期由合约这条线决定：

1. **合约**：GangCallBond + 测试 → 独立审计 → 修复 → 独立复审 → 测试网验收（守约退回；违约、销毁、发 root、veto 后重发、领取；兜底销毁）→ 主网部署（需要明确同意）。
2. **CLI**（并行）：`gang follow` 自动绑定推广人和 `--no-promoter`；`gang buy --bond`；`gang call-bond status/report/settle/claim`；有保证金时的卖出、`vaultLock`、授权警告；capabilities 和文档。
3. **server**（并行，交给 server 仓库的 agent）：喊单区 API、`喊完就跑` / 守单率、跟单绑定和分佣统计、`buyWithPromoter` 的识别、CallBond 索引、举报 keeper（私有发送）、到期结算、赔付结算任务（复用推广池结算的框架）和 `--check`。
4. **web**（并行，交给 web 仓库的 agent）：喊单区页面、标签、喊单者页面的分佣和违约记录、首页位置。
5. **X 推送**：按第 7 节的门槛。

每个 PR 都要独立审查，修复后再复审。

**CLI 发版的前提**：`gang follow` 绑定推广人在主网上不依赖 GangCallBond，CLI 一发版就生效。所以 CLI 要等服务端确认 `buyWithPromoter` 的跟单买入会被记成跟单（测试网上用一笔带跟单引用的 `buyWithPromoter` 验证）之后再发；主网 GangCallBond 部署后把地址写进 CLI，再一起发。

## 9. 各部分之间的接口（草案，实现时以此为准，改动先同步本节）

### 9.1 合约地址

| 网络 | GangCallBond | 起始区块 |
|---|---|---|
| 测试网 97 | `0xBE2B8519278E9D31B6c4040bAd35f727fD5d2A70` | 141708762 |
| 主网 56 | `0x6d6e4A36e9a231cCc932151cdbFb087Cf3860c3D` | 132609869 |

ABI 以 `src/gang/interfaces/IGangCallBond.sol` 为准。

### 9.2 结算参考实现（本仓库 `scripts/callbond-settle/`）

- `node settle.mjs --bond <合约> --id <n>`：按 §5.3 从链上数据算出跟单者名单、`B`、`P_ref`、损失和赔付，输出 JSON：`{ chainId, contract, id, reportedBlock, B, pRef, pool, total, root, leaves: [{ account, amount, proof, loss, tokens, paid, avgPrice }] }`。`leaves` 为空时 `root` 是固定的占位值、`total` = 0。
- `--check`：复算链上已发的 root，不一致就非零退出。
- 只读，不发交易；结算方的服务端任务调它，再用结算方钥匙发 `postRoot`。

### 9.3 服务端 API（gangfun-server）

| 路由 | 内容 |
|---|---|
| `GET /api/calls?sort=score\|new\|followers&filter=bonded\|promote&limit&cursor` | 喊单区信息流。每项：`tx`、`link`、`at`、`author { address, handle, record { …现有字段, holdRate } }`、`note { status, text, conf }`、`token { address, symbol, track, progressPct, graduated, priceAtCall, priceNow, changePct }`、`follow { count, usd, windowEndsAt }`、`bond`（满足 §5.4 才有，否则 null）`{ id, quote, amount, hold, holdPctOfBalance, coverage, deadline, state }`、`promote`（代币有推广条款才有）`{ shareBps, windowDays }`、`flags { ranAway, violated }` |
| `GET /api/callbond/:id` | 一份保证金的链上状态（同 `bondOf`）+ 对应 note、是否算 `有担保`、root 信息（`root`、`total`、`claimableAt`、是否被 veto 过）|
| `GET /api/callbond/:id/proof/:account` | `{ amount, proof }`；没有这个叶子返回 404 |
| `GET /api/agents/:address/calls` | 喊单者页面：保证金记录（押过 / 守约 / 违约次数与列表）、守单率、跟单绑定带来的分佣收入（按代币，`PromoterFeeAccrued` 里 wallet 是跟单绑定的部分） |

`/v3/config`（或现有配置接口）加 `callBond { address, fromBlock }`；`GANG_CALL_BOND` 没设时整套功能不出现（返回空或 404，与推广池的做法一致）。

### 9.4 服务端任务

- **索引**：GangCallBond 的全部事件；`buyWithPromoter` 的买入算买入和跟单；同一笔交易里的 `PromoterBound` + 跟单引用记为跟单绑定。
- **举报 keeper**：盯所有进行中保证金的押款地址，代币余额低于 `hold` 的下一个区块发 `report`（走私有发送通道）。
- **到期结算**：截止后替所有人 `requestSettle`，1 小时后 `settle`；余额不达标就不发（等举报）。
- **赔付**：违约后满 `ROOT_DELAY`、区块最终确认，跑 9.2 的脚本，结果存库供 9.3 查询，用结算方钥匙发 `postRoot`；对 `total = 0` 的 root 和每次 `RootPosted` 都发内部告警，方便 Safe 在 2 天内核对。被 veto 后停发并告警，人工处理。
- 钥匙和节点只走环境变量；没设合约地址时这些任务不运行。

### 9.5 CLI（本仓库 `skill/gang-cli`）

- `gang follow`：3.0 币有推广条款且 `canBind` 为真时走 `buyWithPromoter`，`--no-promoter` 关掉；预览写清绑定和分成。
- `gang buy … --note … --bond <金额> --for <48h–7d>`：买入后押保证金，`hold` 默认全部余额。
- `gang call-bond status|report|settle|claim`：`claim` 从 9.3 取证明。
- 押款地址有进行中保证金时，卖出、`vaultLock`、给这个代币授权前先拒绝或警告（同 GangBond 的 `--break-bond`）。

## 7. 待定

已定（2026-11-09）：违约时当场销毁 50%；对外名称「信号区」（英文 Signals），「喊完就跑」对外叫「提前卖出」（英文 Sold early）。

| 项 | 建议默认值 |
|---|---|
| `有担保` 的最低保证金 | 0.05 BNB 等值，或覆盖率 ≥ 10% |
| X 推送门槛 | 30 天校准分 ≥ 60 且已判定 ≥ 10 单，或 `有担保` 且保证金 ≥ 0.2 BNB 等值 |
| `喊完就跑` 阈值 | 窗口内余额 < 喊单买入量的 50% |
| `P_ref` 的均价窗口 | 违约后 1 小时 |

## 8. 审查记录

**第一轮（2026-11-09，只看规格）**，10 条，已改：小号跟单领回保证金（→ 当场销毁 50%）；`hold` 没和买入量挂钩；违约后买回罚不到（写入限制）；`P_ref` 和违约区块定义不对；内盘余额变化的清单不全；跟单者集合依赖服务端状态；信任边界太乐观、状态机没定义；截止后到结算前的窗口；`buyWithPromoter` 要求钱包直发；报价币拉黑卡住领取。

**第二轮（2026-11-09，对照合约代码）**，7 条，已改：

1. note 之前的持仓不受约束，喊单者可以卖掉老仓 → `有担保` 要求 `hold` 等于全部余额（5.4）。
2. 窗口末尾进来的跟单者几乎没有保护 → 最短 48 小时，卡片写「保护到」（5.2、5.4）。
3. 「第一次跌破」能被一笔交易内的 1 wei 跌破操纵，把所有跟单者排除 → 只看区块末余额，`B` 取举报所在那段连续跌破的起点（5.3）。
4. 均价、价格来源、跟单买入、最低额、叶子格式没法确定性复算 → 按秒取价、`TradeV1.postPrice` / `Sync`、`quoteAmount`、叶子带合约地址和 chainId（5.3）。
5. 状态机：第 30 天的竞态、晚 `veto` 逼销毁、root 发得太早、自己举报的 1% → 5.5、5.2。
6. 合约要做的检查没写全；pad 可升级 → 5.1、5.7。
7. 余额清单有误（打新取回不适用曲线币，漏了 `sellToken`，`vaultRelease` 会加余额） → 5.2。确认了：内盘卖出类入口都要求本人发起，第三方逼不了违约。

**合约审计（2026-11-09，独立代理，含 PoC）**：没有 Critical / High / Medium。资金路径逐条核对：每份保证金 `奖励 + 销毁 + 赔付池 = amount`，领取不超过 `total`，`total` 不超过赔付池，各时间窗口不重叠。已改：

- L-1 结算方发错或被盗时 root 可以把赔付池领给押款地址 → `claim` 拒绝 `account == caller`。
- L-2 `renounceOwnership` 没禁用，放弃后没人能 `veto`、换结算方 → 回滚。
- I-1 `CallBondReported` 带上举报区块。
- I-2 没有合格跟单者时要等 28 天才能销毁 → 允许 `total = 0` 的 root，争议期后销毁。
- I-7 补了测试：闪电借币挡住结算、第三方不能替喊单者卖出、不能领给押款地址、不能放弃所有权、`total = 0`。

没改（已在 5.8 写明或属于部署检查）：构造参数不和 pad 核对（部署脚本查）；直接转进合约的币取不出；结算前后的原子买回、其他池子的闪电借币、小号自己举报拿 1%。

**结算脚本审查（2026-11-09）**：H-1 跟单者「大买再卖回」能把均价抬高、把跟单前的持仓也算进损失 → 改了 §5.3 第 6 条（持仓按跟单后的净增加，成本按净花费）；M-1～M-3 日志漏段检测不全 → 每个分段结束处核对链上状态；L-2 写入 §5.8。复审又发现：跟单者经外盘卖出、转账或锁进 vault 把币移走，`e_i` 会变成 0 而成本不变 → 先改成 `e_i` 加回「其他转出」，第三轮复审指出这样违约前已在外盘卖掉获利的人也能拿赔付 → 最终改为：vault 锁仓算持有，其他移出按 max(当时价格, `P_ref`) 从成本里扣；代币创建者不算跟单者；一个漏掉的分段里正好是一买一卖时状态核对不出来 → 每段再用 pad 的代币进出（`Transfer`）核对 `TradeV1` 的买卖量。

**修复后复审（2026-11-09，独立代理，含 PoC）**：没有 Critical / High / Medium / Low。五项修复都正确、没有引入新问题；`total = 0` 和领取、销毁、`veto` 后重发的组合都核对过；不同保证金之间的资金互不影响。提醒两点：root 里给押款地址或被报价币拉黑地址的那份，要等 `burnUnpaid` 才销毁；Safe 的监控要对 `total = 0` 的 root 报警（结算方被盗时可以用它销毁跟单者的赔偿）。本地测试：`GangCallBondTest` 35 / 0，复审 PoC 套件 39 / 0。
