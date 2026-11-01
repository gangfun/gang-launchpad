# 主网 · QuoteRegistry 登记 USDT / USDC / USD1

BSC 主网（chainId 56），2026-11-01。平台 Safe 在共用的 QuoteRegistry 上登记了三个稳定币，`graduationQuoteAmount` 填 0。

## 为什么

回购、加池、分账、组合这四种收款模块，只接受下面几类报价币：

- WBNB；
- GANG；
- pad 的 QuoteRegistry 里登记过的币。

原因是：

- 转账收税的报价币，会让每次回购和加池都失败；
- 转账时回调收款人的报价币，能让一个收款人把每次分账的 gas 耗尽。

pad 本身接受任何能通过参考池定价的报价币，所以这一层要另外筛选。

主网 QuoteRegistry 之前是空的，所以用 USDT 等稳定币报价的币一律挂不上模块。

## 改了什么

| 报价币 | 地址 | 精度 | 发行方权限 |
|---|---|---|---|
| USDT | `0x55d398326f99059fF775485246999027B3197955` | 18 | 不可升级，没有暂停和冻结 |
| USDC | `0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d` | 18 | 可升级代理，当前实现没有暂停和冻结 |
| USD1 | `0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d` | 18 | 可升级代理；发行方可以暂停、冻结地址、强行划转 |

- 三个币转账都不收税，也不回调收款人。
- USD1 如果冻结了某个池子或模块，或者整个暂停，对应的回购、加池和分账会停下来，直到解除。这是用 USD1 报价的所有币都有的风险，不是模块特有的。

| | |
|---|---|
| QuoteRegistry | `0x8b93919862830ea6A720B28C7D0C42fCbb849F17`（owner = 平台 Safe） |
| 调用 | 每个币一次 `setQuote(quote, true, 0)` |
| Safe 执行 | [`0x8dfbda14…9e4f`](https://bscscan.com/tx/0x8dfbda14d7d06b609d4f8696c7ed585dd57c048da798aeed862796b463f29e4f)，区块 131069193，三条 `QuoteUpdated` |
| Safe batch | `docs/MAINNET-QUOTE-REGISTRY-STABLES-SAFE-BATCH-2026-11-01.json`（USDT、USDC），`docs/MAINNET-QUOTE-REGISTRY-USD1-SAFE-BATCH-2026-11-01.json`（USD1） |

## 影响

- **毕业金额不变。** `graduationQuoteAmount` 填 0：
  - `graduationAmount(quote)` 仍是 0；
  - GangLaunchpad 1.0、2.0 和 Flywheel pad 读的都是这个值，所以毕业金额照旧按创建者的参考池折算，不传参考池仍然报 `RefPoolRequired`。
- **模块。** 已部署的 GangSplitModule 和 GangComboSplitter 克隆在 `keeperServes` 里实时读登记表，登记后对这三个币返回 true，keeper 开始自动分账。回购和加池模块本来就不按报价币限制。
- **CLI。** `--buyback`、`--lp`、`--split` 和组合模式在发币前实时读登记表，现在两个 pad 上都放行这三个币。没登记的报价币仍然被拒绝。不用发新版本。

## 检查

主网 fork 测试 `test/fork/StableQuoteModulesFork.t.sol`：6 个通过，0 个失败。

| 测试 | 内容 |
|---|---|
| `test_fork_listingKeepsGraduationAmounts` | 先取消登记、再登记：两个 pad 上三个币的毕业金额完全一致，不传参考池仍然报 `RefPoolRequired` |
| `test_fork_liveModulesServeListedQuotes` | 线上的 split 和组合工厂克隆出的模块：取消登记时不处理，登记后处理 |
| `test_fork_comboOnUsdtPad1` / `Pad2`、`comboOnUsdcPad2`、`comboOnUsd1Pad2` | 30% 回购、30% 加池、收款人 70:30 的组合模块，用稳定币报价发币并毕业；池子卖出产生的税以稳定币付给模块；keeper 循环做了 7 次回购和 7 次加池，买到的币和 LP 进 0xdead；KOL 收到稳定币 |

说明：

- 这几个测试关掉了 pad 的单钱包上限，让几个买家就能填满曲线。
- 原因是 fork 区块的状态在 RPC 上大约一分钟后就会被清掉，买家太多时测试跑不完。

执行后在主网上复查：

- 三个币 `isQuoted` 都是 true，`graduationAmount` 都是 0。
- USDT 的 `graduationAmountOf`：1.0 为 10,742 USDT，2.0 为 6,445 USDT，和登记前一样，只随价格波动；不传参考池仍然报 `RefPoolRequired`。
- 1.0 和 2.0 的组合实现合约，`keeperServes` 对三个币都是 true。
- CLI 的报价币检查对三个币放行，对未登记的币（CAKE）拒绝。
