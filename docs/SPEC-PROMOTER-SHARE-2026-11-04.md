# 规格 · 推广分成（GangLaunchpad 3.0）

- 日期：2026-11-04
- 需求：[#113](https://github.com/gangfun/gang-launchpad/issues/113)，采用其中的方案 A（放在 pad 里，链上实时分账）。
- 源码：`src/gang/Pad3PromoteStore.sol`、`src/gang/interfaces/IGangPromote.sol`；分账在 `src/gang/CurveLogic3.sol` 的 `_promoterCut`，入口在 `src/gang/Pad3Module.sol`。
- 测试：`test/gang3/Pad3Promote.t.sol`、`Pad3PromoteParity.t.sol`、`Pad3PromoteMix.t.sol`；测试网验收：`script/Pad3PromoteTestnetAcceptance.s.sol`。

## 1. 一句话

dev 发币时可以设一个推广分成：把 creator fee 的一部分让给带来买家的人。钱包第一次交易这个币时带上推广人，就和推广人绑定。有效期内，这个钱包在内盘的每笔交易，creator fee 都按比例分给推广人，推广人自己来领。

## 2. 规则

| 项 | 规则 |
|---|---|
| 比例 `shareBps` | 1–5000，即 creator fee 的 0.01%–50%。发币时定，之后谁都改不了 |
| 有效期 `window` | 7–90 天，从绑定时刻算。发币时定，之后谁都改不了 |
| 绑定时机 | 钱包第一次交易这个币，而且这笔交易走 `buyWithPromoter` |
| 谁发起的才算 | 只有钱包本人发出的交易直接调用 `buyWithPromoter`（`msg.sender == tx.origin`）。任何合约替钱包调用都回滚 `TraderNotOrigin`，包括 router、聚合器和第三方代付的 EIP-7702 钱包：绑定是永久的，还要分走 creator 的钱，所以不让合约替钱包选推广人。EIP-7702 钱包自己发交易时算本人 |
| 只绑一次 | 绑定后不再改变，别人抢不走 |
| 只认新买家 | 钱包第一笔交易没带推广人，就永远不绑；卖光再买也不行 |
| 谁能当推广人 | 绑定时持有 Agent ID，不是交易者本人，也不是这个币的 creator |
| 不合格的推广人 | 忽略，不绑定，这笔买入照常完成（交易不因推广人失败）。预览用 `canBind` |
| 分账时机 | 绑定钱包在有效期内的每笔内盘买卖，任何入口都算：`buy` / `sell`、`buyFor` / `sellFor`、`buyTokenAMAP`、两个 `sellToken` |
| 有效期边界 | `block.timestamp < boundAt + window` 时分账 |
| 适用范围 | 只有 `createWithPromote` 创建的曲线币。其他币、老 pad 的币都没有推广分成 |

## 3. 钱怎么分

一笔内盘交易付 1% 手续费：

```
protocolFee (1%)
├─ 平台 30%：不变，直接进 PlatformFeeBucket
└─ creator 70% ─┬─ 推广人：70% × shareBps（feeOf，向下取整）
                └─ creator：其余（creatorFeeOf）
```

- 交易者付的钱、拿到的币、曲线价格、平台收入，都和没有推广分成的币完全一样。报价接口不用改。
- 钱留在 pad 上，用拉取方式发放：`claimPromoterFee(token, to)`，毕业前后都能领。推广人收不了款也不会卡住交易，和 `claimCreatorFee` 一样。
- 推广人不再持有 Agent ID，不影响已有的绑定和领取。
- **刷量一定亏**：推广人最多拿到交易额的 0.35%（1% × 70% × 50%），而每笔交易至少付 1%。用自己的小号当推广人，相当于从 dev 那里拿到手续费折扣，但自己仍然是净付出。dev 是否接受这一点，由他决定开不开推广分成。

毕业后的池子交易不走 pad，带不了推广人，第一版不分。打新和铸币飞轮不适用。

**已知的限制**：
- 钱包这笔交易的调用链上如果有恶意合约（比如空投领取、swap 路径里的钩子），它可以用 `buyTokenAMAP` 或已上架 router 替钱包买一笔极小的，这算第一笔交易，钱包之后就不能再绑定。钱包的资金不受影响；推广人失去这个钱包。发起者如果是这个币的 creator，他能少付这个钱包的分成，但前提是骗到每个钱包都发一笔这样的交易。不把这种买入算作第一笔交易的话，已经持币的老钱包又能被绑定，所以保留现状。
- 钓鱼网站可以让钱包直接签一笔填了别人推广地址的 `buyWithPromoter`。这和任何交易内容被篡改一样，合约分辨不出来，用户要看清预览里的推广人。
- 合约钱包不能是 `tx.origin`，走不了 `buyWithPromoter`，所以绑定不了；`canBind` 不区分这一点，它假定钱包自己发交易。
- 推广人不领的钱会一直留在 pad 上，没有回收入口，和 `creatorFeeOf` 一样。
- 推广人资格靠 Agent ID 把关，合约里没有再单独排除 pad、WBNB 这些地址。Agent ID 不可转让，这些地址拿不到。

## 4. 接口

都在 3.0 的代理地址上（实现合约没有的选择器走模块 `Pad3Module`）：

```solidity
function createWithPromote(name, symbol, logoURI, metaURI, quote, refPool, tax, gradBnb, uint16 shareBps, uint32 window)
    returns (address token);
function buyWithPromoter(address token, uint256 funds, uint256 minAmount, address promoter)
    payable returns (uint256 amountOut, uint256 fundsUsed);
function claimPromoterFee(address token, address to) returns (uint256 amount);
function promoteOf(address token) view returns (uint16 shareBps, uint32 window);
function bindingOf(address token, address wallet) view returns (address promoter, uint40 boundAt, bool traded);
function promoterFeeOf(address token, address promoter) view returns (uint256);
function canBind(address token, address wallet, address promoter) view returns (bool);
```

`buyWithPromoter` 替调用者买入，其余规则和 `buyTokenAMAP` 的曲线分支一致：BNB 计价的币 `msg.value == funds`，ERC-20 计价的币从钱包拉取，被截断的部分退给钱包（WBNB），发 `GatewayBuy`。代币不是这个 pad 的曲线币，或者已经毕业，回滚 `NotCurveToken`。

新事件：`PromoteSet`、`PromoterBound`、`PromoterFeeAccrued`、`PromoterFeeClaimed`。

**老事件的含义**：
- `CreatorFeeAccrued`：creator 自己实际得到的部分，所以累计减去已领仍然等于 `creatorFeeOf`。
- `TradeV1.creatorFee`：creator 那 70% 的全部，含推广人的部分，所以 `protocolFee - creatorFee` 在任何币上都是平台的部分。

## 5. 给聚合器

不用做任何改动。`tryBuy` / `trySell` 的结果不变，已绑定钱包通过聚合器交易，分账照常发生。聚合器带不了推广人：新钱包第一笔交易走聚合器，就算没有推广人。推广链接要让用户直接调用 pad，CLI 和网站都是这样。

## 6. 存储和升级

- 状态放在 ERC-7201 命名空间 `gang.pad3.promote`（`Pad3PromoteStore`），不动 pad 的顺序布局。`test/gang3/Pad3Promote.t.sol` 锁定槽位和成员位置。
- 升级脚本比对最新 25 个币的条款。绑定和收益没法从 pad 列举，更老的币也不在样本里：有带推广分成的币之后，用 `PAD3_PROMOTE_PROBES` 传入币和钱包（来自 `PromoterBound` 日志）。样本里有这种币却没传，或者传的钱包没有绑定，脚本会打印警告，不会拦下升级。
- 已有的币没有条款（`shareBps == 0`），这次升级不改变它们的任何规则，每笔交易只多一次存储读取。
- `TOKEN_VERSION` 不变：推广分成是发币时的可选项，不改变价格和手续费，和金库模式、飞轮模式的做法一致。
