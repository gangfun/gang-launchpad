# 规格 · 推广分成延续到外盘

- 日期：2026-11-05
- 需求：[#113](https://github.com/gangfun/gang-launchpad/issues/113) 的待定项 5。内盘部分见 `docs/SPEC-PROMOTER-SHARE-2026-11-04.md`。
- 源码：`src/gang/GangPromotePoolModule.sol`、`src/gang/GangPromotePoolModuleFactory.sol`。
- 结算参考实现：`scripts/promote-settle/settle.mjs`。
- 测试：`test/gang/GangPromotePoolModule.t.sol`；主网 fork：`test/fork/PromotePoolMainnetFork.t.sol`（WBNB、USDT、USDC、USD1 四种计价币走真实的 Pancake 和 handler，每个测试单独跑）。

## 1. 一句话

邀请只在内盘发生。钱包绑定后，在有效期内到外盘交易，推广人继续从 dev 那部分池子税里分钱，比例和有效期与内盘相同。

## 2. 规则

| 项 | 规则 |
|---|---|
| 绑定 | 只有内盘的 `buyWithPromoter`。毕业后不新增绑定，来源只有 pad 的 `bindingOf` |
| 比例和有效期 | 读 pad 的 `promoteOf`，和内盘同一份，发币时定，之后谁都改不了 |
| 从哪里出钱 | 只出自税接收方的部分。平台的 0.5% 和持币人分红不变 |
| 适用的币 | 用 `createWithPromote` 新发、带税、接收方是本模块、分红不到 100%、毕业前已 `bind` 的币。`bind` 对分红 100% 或已毕业的币都会回滚 |
| 不适用 | 无税币、税全部分红的币、已经发出的币（接收方写死）。第一版不能和回购、LP、Split 模块组合，因为一个币只有一个接收方 |
| 怎么确认一个币有外盘分成 | `routeOf(token).recipient` 是模块，模块的 `token()` 等于这个币，而且 `closed()` 为假。网站和 CLI 都要查。托管到期后（`escrowOpen()` 为假）新到账不再分。实际比例是 `shareBps × (1 - dividendBps)` 占接收方前的部分，页面按这个显示 |

## 3. 钱怎么走

```
池子税（代币）→ handler 分批卖成计价币
├─ 平台 0.5%（占成交额）：不变
├─ 持币人分红：不变
└─ 接收方（本模块）
   ├─ 1 - shareBps：立即转给 dev
   └─ shareBps：留在模块（托管）
      ├─ 结算后：归绑定钱包的推广人
      └─ 其余：结算后归 dev
```

- dev 的 `1 - shareBps` 不用等结算（`shareBps` 最高 50%，这时只有一半）。托管部分最晚在 `window + 7 天` 后停止：之后到账的钱全部直接给 dev。这个时间从模块第一次看到代币已毕业时算起，所有绑定都发生在毕业前，所以这时所有有效期都已结束。
- 刷量在价格不变时一定亏：按先进先出，推广人只分自己带来的这笔交易的税卖出所得。handler 把平台和持币人的比例混在一起算，买卖税率不同时一笔最多拿回自己税款的约 81%，仍然亏。这笔税要之后才卖，如果期间价格上涨，卖出所得也会变多，这是承担价格风险，不是无风险套利。
- 推广人在内盘累积的 `promoterFeeOf` 不受影响，分别领取。

## 4. 结算规则

任何人都能用链上数据复算（参考实现的 `--check`）。按链上顺序处理从模块 `Bound` 所在区块开始的三类事件，每一期只是在 `throughBlock` 处切开，状态延续到下一期。`bind` 只能在毕业前做，而池子税只在毕业后产生，所以队列不会漏掉税。

1. **交易：代币的 `OuterTax(from, to, taxed, net)`，`taxed > 0`。** `from` 是交易对就是买入，地址取 `to`；否则是卖出，地址取 `from`。这个地址在 `bindingOf` 里有推广人，且 `block.timestamp < boundAt + window`，这笔就算这个推广人的；否则，如果这笔交易直接调用的是公开的 router 清单（`tx.to`）里的合约，再看 `tx.from` 的绑定。把 `{taxed, 税率, 推广人}` 放到队尾。
2. **卖出：handler 的 `TaxChunkSold(token, taxTokens, ...)`。** 从队头取走 `taxTokens` 个代币。每段的权重 `w = 代币数 × (rate - 50) / rate`，`rate` 是这笔的税率（基点）。这一块的接收方所得 `toRecipient` 来自同一块的 `TaxDistributed`。如果同一块有 `TaxPaid` 给模块，每个推广人 `p` 记入 `floor(toRecipient × shareBps × w_p / (10000 × w_总))`；没有（`TaxOwed`）就不记，这笔钱之后到账时归 dev。
3. **拆分：模块的 `Split(incoming, toEscrow, toDev)`。** 上次拆分以来记入的金额从 `toEscrow` 里付给推广人，其余归 dev。记入的金额超过 `toEscrow` 时（正常不会发生）按比例封顶。`toEscrow` 为 0（托管已结束）时，记入的金额作废，所以结算方要在托管到期前调用一次 `work`。直接转进模块的钱产生的托管也归 dev。

**发布。** 叶子是 `(account, 累计金额)`，`allocatedTotal` 是所有账户的累计金额之和。叶子哈希和 OpenZeppelin `StandardMerkleTree` 相同：`keccak256(bytes.concat(keccak256(abi.encode(account, cumulative))))`。

**周期。** 从毕业开始到托管结束，结算方每周发布一次，没有新金额也发（还没有任何金额时发固定的占位 root，`allocated` 为 0）。这样 30 天没有发布就真的说明结算方停了，dev 才能 `reclaim`；毕业前 `reclaim` 总是回滚。托管结束且全部分配后停止发布。`throughBlock` 只用已最终确认的区块。

**对账。** 参考实现在输出前要核对：`Split` 的 `toEscrow` 总和等于链上 `escrowIn()`；税的总额减已卖出的总额等于 handler 的 `accruedTax`；每个有接收方所得的块，紧贴 `TaxDistributed` 之前都有一条金额相同的 `TaxPaid` 或 `TaxOwed`（同一笔交易里 `release` 也会发 `TaxPaid`，那是另一笔钱）；上一期的状态能算出它的 root，且 root 和 `throughBlock` 都和链上一致。任何一项不符就退出，不输出 root，因为 root 生效后不能撤销。脚本持续失败要告警，否则结算方沉默 30 天后 dev 就能 `reclaim`。

**独立复算。** 用 `--check` 且不带 `--prev`，从 `Bound` 全量重放。root 只承诺累计金额，别人给的 `--prev` 可能带着改过的队列。

**router 清单（BSC）。** 3.0 的 GangRouter `0xec9717E5C68b9F18fA76D3961C9Cd7e67b5E61e7`、Pancake V2 `0x10ED43C718714eb63d5aA57B78B54704E256024E`，以及 3.0 白名单里的三个聚合器 router（见 `docs/MAINNET-GANG-LAUNCHPAD-3-2026-11-03.md`）。清单之外的合约转发时，`tx.from` 不算，这样 bundler 或订单 filler 这类替别人发交易的地址，绑定了也蹭不到别人的税。一个模块全程用同一份清单，换清单会算出不同的 root，脚本发现不一致会退出。

用先进先出按实际卖出所得分配，不需要价格预言机：税是分批卖出的，代币本身没有区别，先进先出是约定的记账方式。代价是税款卖出比交易晚，推广人要等这笔税卖出才有收入；有效期按交易时间算，所以有效期内的交易在到期后卖出仍然算，直到托管结束。

## 5. 信任边界

结算方是 Safe 在工厂上设置的地址，只有它能发布 root。合约保证：

| 风险 | 上限 |
|---|---|
| root 算错或作恶 | 只影响托管资金：`allocated` 不能超过托管总额，所有领取加起来不能超过 `allocated`。已经转给 dev 的和已经领走的动不了 |
| 发布后发现有错 | 2 天争议期内，工厂 owner（Safe）可以 `veto`。任何人都能复算后提出异议 |
| root 想减少已分配的总额 | 不允许，`allocated` 只能增加 |
| 结算方停摆 | 30 天没有发布，dev 可以 `reclaim` 拿回没分配的托管资金，模块永久关闭：不能再发布，之后到账的钱全部给 dev。已生效的 root 仍可领取。推广人对没分配的部分没有追索权 |

Safe 可以换结算方，所以推广人和 dev 都需要信任 Safe 不会故意错分托管资金。这是这个方案和内盘版本的主要差别：内盘完全在链上分账。结算方和 Safe 必须是不同的账户，部署脚本在主网上会检查。

其他取舍：结算方被盗时可以同时给所有模块发布，Safe 要在 2 天内逐个 `veto`，没有全局暂停。结算方持续发布也能一直挡住 `reclaim`。叶子总和超过 `allocated` 时先到先得，后面的人整笔回滚。

## 6. 已知的限制

- 只有内盘绑定的钱包才算。外盘新买家带不了推广人。
- 钱包把代币转到另一个地址再卖，这笔不算推广人的。
- 合约钱包和第三方代付时，`tx.from` 不是钱包本人；只要转账地址是绑定钱包，这笔仍然算。
- 钱包走清单之外的合约时，转账地址是那个合约，这笔不算推广人的。
- `tx.from` 是绑定钱包、经清单内的 router 把代币买给别的地址时，也算这个钱包。它发起并付了税，推广人只分这笔自己的税。
- 钱被冻结或没收时不做按比例分摊：下一笔到账先填上差额，不产生 `Split`，这之前最后领取的人会回滚。计价币把模块拉黑时，模块里的钱都动不了。
- `reclaim` 依赖 `firstGradSeenAt`。如果从没有人调用过 `work`，先调用一次再等 30 天。
- 毕业前没有 `bind` 的币没有外盘分成，收入由 `sweep` 转给 dev。任何人都能 `bind`，CLI 发币后马上 `bind`。
- 3 个聚合器 router 闭源且可升级，无法确认它们没有代发通道，`tx.from` 回退依赖这一点。
- dev 把真币的接收方指向已绑定诱饵币的模块时，真币的推广人分不到外盘的钱。这种情况链上可见（`token()` 不等于真币），网站和 CLI 不显示外盘分成。
- 没人领的钱留在模块里，没有回收入口。
- `work`、`post`、`reclaim` 都可能先拆分：转给 dev 前要求剩余 gas 足够 `PUSH_GAS`，所以调用方要用 `eth_estimateGas`，不能按实际用量估一个固定值，否则回滚 `PushStarved`。
- 结算依赖完整的历史日志。公共 RPC 可能不报错就返回空结果，参考实现会先探测；生产环境要用保留完整日志的节点。

## 7. 接口

```solidity
// 工厂（dev 调用）
function create(bytes32 salt) external returns (address module);

// 模块
function bind(address token) external;                 // 任何人，一次
function work(uint256) external;                       // 任何人，拆分到账的钱
function post(bytes32 root, uint256 allocated, uint64 through, string uri) external;  // 结算方
function veto() external;                              // 工厂 owner，争议期内
function activate() external;                          // 任何人，争议期后
function claim(uint256 cumulative, bytes32[] proof, address to) external returns (uint256);
function reclaim(address to) external returns (uint256);  // dev，结算方停摆后，关闭模块
function releaseDev(address to) external returns (uint256);  // dev，转账失败留下的部分
function sweep(address asset) external returns (uint256);    // 任何人，把其他资产转给 dev
```

发币顺序：`factory.create` → `pad.createWithPromote(..., tax.recipient = module, ...)` → `module.bind(token)`。

## 8. 上线

需要和内盘版本同批：先升级 3.0（工厂构造时要求 pad 有 `promoteOf`），再部署工厂，然后 Safe 执行 `admin.setFactory(factory, true)`。

## 9. 数据依据

2026-11-05 查了主网两个已毕业带税币（`狙姬`、`GANGBALL`）毕业后前 3 小时的 14814 笔带税交易：约 76% 的交易地址就是发送方钱包；假设内盘钱包全部绑定，它们前 3 小时的外盘收入相当于整个内盘阶段收入的约 102% 和约 34%。样本小，也只看了 3 小时，只用来判断值不值得做。
