# 主网 · QuoteRegistry 登记 ANTB

BSC 主网（chainId 56），2026-11-20。平台 Safe 在共用的 QuoteRegistry 上登记 ANTB，`graduationQuoteAmount` 填 0。做法和 [USDT / USDC / USD1 那次](MAINNET-QUOTE-REGISTRY-STABLES-2026-11-01.md)一样。

**状态：已执行。**

## 为什么

不少 BSC 上的新币用 ANTB 当底池。pad 本身已经能用 ANTB 报价：参考池用 Pancake V3 ANTB/USDT 0.25% 池，经 USDT 桥接到 BNB 定价。

但分账、组合、底价、封顶、倒计时、推广池这些收款模块，只认 `keeperServes` 返回 true 的报价币（WBNB、GANG、QuoteRegistry 里登记过的币）。ANTB 没登记，keeper 不会处理这些模块，CLI 也不让用 ANTB 发带这些模块的币。

## ANTB

| | |
|---|---|
| 地址 | `0x38Dd26788Cf2d901E3aBf04efE3007d459d0Fc53`（beacon proxy，beacon `0x156d6dce9a4f6139a3406f1f021f1a4880de93a3`） |
| 当前实现 | `0xCFEd6c4679297ea4889F8183bC057B4A86C64e46`，Sourcify 已验证，`SecuritiesToken` |
| 精度 | 18 |
| 转账收税 | 没有 |
| 回调收款人 | 没有 |
| 发行方权限 | beacon owner 可以升级合约；`pauseManager` 可以暂停所有转账；`compliance` 合约在每次转账时检查双方（以及 `transferFrom` 的调用者），可以拒绝某个地址；`DEFAULT_ADMIN_ROLE` 可以改名、改符号、更换 compliance 和 pauseManager 合约；`DEFAULT_ADMIN_ROLE` 和 `ISSUER_ROLE` 可以给自己增发、销毁自己持有的币、设置只影响显示的 UI 倍数（ERC-8056，`balanceOf` 不变） |
| 参考池 | Pancake V3 ANTB/USDT 0.25% `0x5AFB6E189A268c6adFC9DA13CA13e3BA91171a31` |

风险：

- 发行方暂停 ANTB，或者把某个池子、模块、pad 列进 compliance，用 ANTB 报价的币在 pad 上的买卖、毕业、回购、加池和分账都会停下来，直到解除。这是所有 ANTB 报价币都有的风险，不是模块特有的。
- 发行方如果把合约升级成转账收税，这些币在曲线上的买入会全部失败：pad 每次把报价币转进来都检查到账数量，不符就报 `FeeOnTransferQuote`。

## 改了什么

| | |
|---|---|
| QuoteRegistry | `0x8b93919862830ea6A720B28C7D0C42fCbb849F17`（owner = 平台 Safe） |
| 调用 | `setQuote(0x38Dd…0Fc53, true, 0)` |
| Safe batch | `docs/MAINNET-QUOTE-REGISTRY-ANTB-SAFE-BATCH-2026-11-20.json` |
| Safe 执行 | [`0x2de1f2e2…8443`](https://bscscan.com/tx/0x2de1f2e24248abc824255c91c9b9cd4282692005fd6e2e95f41dcdb3e2738443)，区块 134681591，一条 `QuoteUpdated` |

## 影响

- **毕业金额不变。** `graduationAmount(ANTB)` 仍是 0，3.0 照旧按创建者的参考池折算；不传参考池仍然报 `RefPoolRequired`。
- **哪些 pad。** GangLaunchpad 1.0 `0x15CF…4365`、2.0 `0x7703…e557`、3.0 `0x2bEb…AB29` 和 vault pad `0xE908…0A11` 的 `quoteRegistry()` 都是这个登记表，登记前就都能用 ANTB 加参考池定价（`graduationAmountOf(ANTB, 0x5AFB…1a31)`：1.0 约 94.16 ANTB，其余约 56.49 ANTB）。所以这次登记对这几个 pad 上的模块都生效，不只是 3.0。LaunchpadV2 用的是另一个登记表 `0x053C…060D`，不受影响。
- **模块。** 已部署的模块克隆在 `keeperServes` 里实时读登记表，登记后对 ANTB 返回 true，keeper 开始处理。倒计时、底价、封顶模块创建时也检查 `keeperServes`，登记后可以用 ANTB 创建。
- **CLI。** 发币前实时读登记表（`skill/gang-cli/src/launch.js` 的 `isQuoted`），登记后放行 ANTB。不用发新版本。

## 检查

主网 fork 测试 `test/fork/AntbQuoteModulesFork.t.sol`：3 个通过，0 个失败。测试只覆盖 3.0；1.0、2.0 和 vault pad 只做了下面的链上只读检查。

| 测试 | 内容 |
|---|---|
| `test_fork_antb_listingKeepsGraduationAmount` | 先取消登记、再登记：3.0 上 ANTB 的毕业金额完全一致（默认目标约 56.09 ANTB），不传参考池仍然报 `RefPoolRequired` |
| `test_fork_antb_liveModulesServeOnceListed` | 3.0 线上 split 和组合工厂克隆出的模块：取消登记时不处理，登记后处理 |
| `test_fork_antb_comboOnPad3` | 30% 回购、30% 加池、收款人 70:30 的组合模块，用 ANTB 报价在 3.0 发币（abcd 地址）并毕业；池子卖出产生的税以 ANTB 付给模块；keeper 循环做了 7 次回购和 7 次加池，买到的币和 LP 进 0xdead；KOL 收到 ANTB。ANTB 的转账都走它自己的暂停和 compliance 检查 |

说明：测试关掉了 pad 的单钱包上限，让几个买家就能填满曲线；测试买家的 ANTB 从参考池地址转出（ANTB 余额在命名空间存储里，不用 `deal`）。

执行后在主网上复查：

- `isQuoted(ANTB)` 为 true，`graduationAmount(ANTB)` 为 0。
- 3.0 的 `graduationAmountOf(ANTB, 0x5AFB…1a31)` 约 56.44 ANTB（默认目标），只随价格波动；不传参考池仍然报 `RefPoolRequired`。
- 3.0 线上 split 和组合工厂的实现合约，`keeperServes(ANTB)` 都是 true。
- 1.0、2.0 和 vault pad 的 `quoteRegistry()` 都是 `0x8b93…9F17`，用 ANTB 加参考池的 `graduationAmountOf` 正常返回（见上文"影响"）。
