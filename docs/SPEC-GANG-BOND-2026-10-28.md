# 规格 · Agent 押金承诺（GangBond）

- 日期：2026-10-28 Asia/Shanghai
- 作者：Claude（按 claude.ai 文档「Agent 押金承诺规格草案」2026-10-27 版实现；待定问题全部按草案「建议」一栏）
- 性质：**测试网已部署（当前版本 `0xd6a8…1086`，含 2026-10-29 审计修复；更早的 `0x587f…5d7E`、`0x5a99…d716`、`0xB034…EBE3` 见 `docs/TESTNET-GANG-BOND-2026-10-28.md`）；主网 2026-10-29 已部署 `0xe92d…14E4`（另含复审 L-1 的修复；第一版 `0xf26F…C817` 没人用过，已弃用，见 `docs/MAINNET-GANG-BOND-2026-10-29.md`）**。合约 `src/gang/GangBond.sol`，测试 `test/gang/GangBond.t.sol`，部署脚本 `script/DeployGangBond.s.sol`，CLI `skill/gang-cli/src/bond.js`。

## 一句话

创建者在发币后任何时候（内盘 / 打新期间也可以）押一笔报价币，承诺从押下那一刻起，创建地址的余额始终不低于 X 枚，直到「毕业 / 开盘时间 + N 天」（N = 7–90）。期间任何人发现余额低于 X 都能举报，举报人拿 1%，其余分块从交易对买回本币并转到 `0x…dEaD`。到 T 且余额达标，任何人先调 `requestSettle`，1 小时后余额仍达标再调 `settle`，押金全部退回创建者（两步是 2026-10-29 审计加的，见文末）。

## 发币时押（2026-10-28 改）

第一版按草案「待定问题」的建议，只能在毕业 / 开盘后押。评估后改为发币后随时可押：内盘和发币当天是交易者决策最集中的时候，只在外盘押会错过绝大多数币。用户拍板的三条：

| 问题 | 决定 |
|---|---|
| 承诺期 T 从哪天算 | 从毕业 / 开盘那天算。押的时候币已经上池子，就从押的那天算 |
| 一直没毕业 / 开盘的兜底 | 30 天（`MAX_WAIT`）：押后 30 天仍没交易对，没违约的可以申请退款（见下方公告期）；违约了的，罚没剩下的报价币转 0xdead |
| 退款怎么发起（内部审查后补充） | 只有 dev 能发起，分两步：`requestRefund` 开始 3 天公告期（`REFUND_NOTICE`），期间承诺照常有效、可被举报，期间毕业 / 开盘则申请作废、开始计时；公告期满仍没交易对、没违约，dev 才能 `refund` |
| 开盘前能不能撤回 | 不能；除上面的 `refund` 外没有任何提前取回 |

机制：

- `post(token, amount, holdAmount, duration)`：传时长不传截止时间。币还没上池子，`deadline` 记 0（「待开始」），承诺照常生效。
- `start(token)`：任何人可调。币毕业 / 开盘后，把 `deadline` 定为当前时间 + `duration`。GangBond 是独立合约，pad 没法在毕业时通知它，所以由 keeper 在毕业后马上调；其他写操作（加押金、提高 X、延期、举报、取回）也会顺带调用。拖着不调只会让承诺期更晚结束，创建者自己也有动力尽快调。
- 内盘期间判违约照样只看 `balanceOf(creator)`：V3 在内盘卖出、打新卖回份额都会让余额下降。
- 内盘期间罚没：举报奖励当场发，`burnChunk` 回滚 `NotTradable` 等交易对；押后满 30 天仍没交易对，`burnChunk` 把剩下的报价币转 0xdead。
- `requestRefund(token)` / `refund(token)`：只有创建者能调。押后满 30 天、没交易对、没违约时申请，3 天后执行；押金退给创建者，新状态 `Refunded`，不计入守约次数。币已经上池子时都回滚 `AlreadyLive`（这时应该 `start`），`start` 会清掉未执行的申请。公告期的作用：dev 没法在毕业前一刻悄悄抽走押金，买家能提前 3 天看到。
- `extend(token, by)`：待开始时加在 `duration` 上（总长不超过 90 天），已开始时加在 `deadline` 上（不超过当前时间 + 90 天）。
- 待开始时 `dumpValue` / `coverageBps` 返回 0，`quoteDump` 回滚：没有交易对就没法给 X 定价。网站在内盘期间只显示押金额和 X，不显示覆盖率标识。
- 新增事件 `BondStarted`、`RefundRequested`、`BondRefunded`；`BondPosted` / `BondExtended` 带上时长。服务端要订阅 10 个事件。

## 和现有合约的边界

GangBond 不可升级、没有 owner，构造时写死 `pad`（GangLaunchpad）和 `wbnb`。只读 pad 的 `kindOf` / `curves` / `sales` 和代币的 `balanceOf` / `buyTaxBps` / `sellTaxBps`，只和交易对做买入。内盘、代币、分红、外盘税合约一行未改，也不需要给 GangBond 任何权限。

## 参数（草案值）

| 常量 | 值 | 作用 |
|---|---|---|
| `MIN_DURATION` / `MAX_DURATION` | 7 天 / 90 天 | 承诺期（从毕业 / 开盘起算）；`extend` 后待开始的总长不超过 90 天，已开始的 T 不超过 now + 90 天 |
| `MAX_WAIT` | 30 天 | 押后最多等多久没有交易对：之后可申请退款，或把罚没剩下的报价币转 0xdead |
| `REFUND_NOTICE` | 3 天 | 退款申请到可执行之间的公告期 |
| `REPORTER_BPS` | 100（1%） | 举报奖励，从押金出；创建者自己举报不给 |
| `CHUNK_MAX_BPS` | 50（0.5%） | 每块回购最多用交易对报价币储备的 0.5% |
| `TWAP_WINDOW` | 10 分钟 | 回购参考均价的最短窗口 |
| `MAX_PRICE_RISE_BPS` | 200（2%） | 现价高于均价 2% 以上不回购 |
| `CHUNK_GAP` | 4 分钟 | 两块回购之间至少隔这么久（2026-10-29 审计 H-1，原为每块一次） |
| `SETTLE_DELAY` | 1 小时 | `requestSettle` 到 `settle` 之间的等待，期间承诺照常有效、可被举报（2026-10-29 审计 M-2） |

## 实现时对草案的取舍

| 草案写法 | 实现 | 原因 |
|---|---|---|
| 「代币一律从 `token.pair()` 读」 | 交易对从 pad 的 `curves(token).pair` / `sales(token).pair` 读，首次 `post` 时缓存到 `marketOf` | 不收税的 V3 币（CLI 0.10.0 起默认）毕业时不调 `setPair`，`token.pair()` 一直是 0 |
| 卖出税「税收币读 `sellTaxBps()`，打新固定 1%」 | 两种都读 `token.sellTaxBps()` | 打新币的 `sellTaxBps` 本来就是 100，代币上的值就是实际收的税 |
| 视图只列了 5 个 | 另加 `quoteDump(token, holdAmount)`、`previewBurn(token)` | CLI 的 `--cover` 要在押金存在前算覆盖率；keeper / CLI 要给 `burnChunk` 算 `minTokensOut` |
| TWAP 观测方式未写 | 每个币存两个累计价格观测点（`old` / `recent`），均价窗口在 10–30 分钟之间（`old` 最多比 `recent` 早 20 分钟，调用最多比 `recent` 晚 10 分钟）；`report` 时清空，首次 `burnChunk` 只记点；距上次观测超过 20 分钟也重新开始（这次只记点） | 保证「罚没后第一次调用只记一个观测点」；内部审查 M-1：keeper 断档后若用整段空闲期的均价，价格下跌后有人能把价格拉回旧均价附近再卖给回购 |
| `settle` 只看即时余额 | 另要求交易对的代币余额不低于储备，否则 `FlashSwapActive`；2026-10-29 起分两步，两次都查 | 内部审查 L-2：挡住从本币交易对闪电兑换借币冒充达标；审计 M-2：一笔交易里买入 → settle → 卖出、或从别的池子借币，都只能满足一个时刻 |
| 价格保护不过时的处理 | 不回滚，返回 `(0, 0)` | 观测点更新要落盘；只有同块重复调用（`BurnedThisBlock`）和滑点（`Slippage`）回滚 |
| — | 一块小到买不到 1 wei 代币时，这块报价币留在交易对里，`burnLeft` 照减 | 避免尘埃金额让 `burnLeft` 永远大于 0、创建者没法再押 |
| 退押金币种未写 | 退回报价币本身（WBNB 不解包成 BNB） | 不向任意地址发原生币，没有 receive 失败的分支 |
| `raiseHold`「新 X 不低于旧 X」 | 允许等于 | 照草案字面 |

## 边界情况（草案以外补充）

- 报价币把创建者拉黑时 `settle` 会一直失败，押金卡住且随时可能被举报。**更正（2026-10-29 审计 M-3）**：pad 接受任何 18 位小数、有 ≥ 1 BNB 参考池的 ERC20 作报价币，不只是 WBNB 和 QuoteRegistry；主网 243 个币里 100 个的报价币不在 QuoteRegistry（GANG、代币化股票、ETF 代币，后两类是发行方可升级的代理）。创建者可以用自己铸的币当报价币，押一笔没有价值的押金，覆盖率照样显示很高。合约不改（押金只影响创建者自己的那一笔），网站和 CLI 只对白名单报价币显示覆盖率和档位，见审计报告。
- GangBond 在回购交易里短暂持币：买入那笔转账先记税（`notifyTax`）再同步份额，GangBond 收到币时份额还没写，紧接着转到 0xdead 份额归零，所以不会分到分红。分红合约不需要排除它。
- 「路由被恶意升级后转走创建者的币」一行沿用草案：GangRouter 是 48 小时时间锁可升级代理，这条风险成立。

## 内部审查（2026-10-28，独立代理，只看合约）

没有 critical / high。已修：M-1（空闲后的旧均价，见上表）、L-2（本池闪电兑换）、`previewBurn` 在块大小为 0 时返回 not ready。不改：

- L-1「手续费写死 9975，换工厂会锁死回购」：交易对来自 `SharedMigrator.factory`，是 immutable；pad 的 `setPairFactory` 只影响参考池定价，交易对一定是 Pancake V2。
- 从别处借币（借贷协议、其他池子）在 `settle` 那一刻满足余额：快照式检查的固有局限。前提是违约后一直没人举报；服务端 keeper 上线后会在违约的下一个区块举报，在那之前只能靠第三方。
- 创建者换一个地址举报自己，就能拿回 1%：只是少罚 1%，不影响其余押金回购销毁。
- `historyOf.honored` 能用极小押金刷：前端展示时要和押金额一起看，不能当信誉分。
- `burnChunk` 调用者没有奖励，回购完全靠 keeper；keeper 停了只是变慢。押金远大于池子时，回购会受 2% 上限自我限速，需要很多小时。

## 内部审查二（2026-10-28，发币时押，独立代理，只看改动）

没有 critical / high。中危：押后满 30 天未开盘时，原先任何人都能立即 `refund`，dev 可以抢在毕业那一刻收回押金再砸盘 → 改成 dev 发起、3 天公告期（见上）。不改、写进文档的两条低危：

- 毕业前被罚、满 30 天未开盘时，任何人都能抢在毕业前把报价币转 0xdead，持有人少一笔回购买盘；dev 得不到好处，毕业后这条路就走不到。
- 毕业前违约、30 天内没人举报，dev 买回后再申请退款：和 `settle` 一样是快照式检查的局限；毕业前代币锁定，dev 余额只能经 pad 变化，链上都看得到，靠 keeper 及时举报（毕业前也要举报）。

补上的测试：毕业晚于 30 天时仍走回购而不是报价币销毁、已上池子未开始时 `settle` 回滚不留状态、`extend` 走已开始分支、公告期内违约 / 毕业。

## 外部视角审计（2026-10-29，主网部署前）

两个独立代理（资金安全 / 状态机；经济攻击 / MEV）加作者复核，带 PoC。报告：`docs/AUDIT-GANG-BOND-2026-10-29.md`。合约改了三处：回购每块之间至少隔 `CHUNK_GAP`（H-1）、`settle` 分两步（M-2）、部署脚本主网锁定 pad 地址。新增 `requestSettle`、事件 `SettleRequested`、错误 `NoSettleRequest` / `BurnTooSoon`（取代 `BurnedThisBlock`），`Bond.refundAt` 改名 `requestAt`（未开始时是退款申请，过期后是 settle 申请；元组布局不变），`lastBurnBlock` 改为 `lastBurnAt`。服务端要订阅 11 个事件。

## 测试

- `forge test --match-contract GangBondTest`：35 个用例（2026-10-29 审计新增 3 个：一笔交易凑余额 settle 失败、延期作废 settle 申请、每 4 分钟最多一块）。发币时押新增 12 个：毕业后 `start` 开始计时、任意写操作顺带开始计时、待开始时延期、V3 内盘卖出违约后等毕业再回购、毕业晚于 30 天仍走回购、一直不毕业时 30 天后报价币转 0xdead、申请退款加 3 天公告期、公告期内违约 / 毕业、违约 / 已上池子时不能退款、已上池子未开始时 settle / extend、打新卖回份额违约、打新开盘后计时和取回。原有 20 个覆盖覆盖三种币（收税 V3、不收税 V3、打新）、全部检查和状态流转、举报奖励、取回后开新一轮、分块回购到 `burnLeft` 归零、拉盘后跳过、滑点、覆盖率公式、空闲后观测重启（改回旧逻辑时该用例失败）、闪电兑换中不能 settle、新一轮罚没在 20 分钟内也重新记点（删掉 `report` 里的重置时该用例失败）、ERC20 报价币的回购、两个币共用 WBNB 时各自记账。交易对用 `test/mocks/TwapMockPair.sol`（带 K 检查、0.25% 手续费和累计价格），`GangFixture` 新增 `_newPairFactory()` 钩子，其他测试不受影响。
- BSC 主网分叉（anvil，本地）上用真实 Pancake 交易对跑了 CLI 端到端：post（`--cover 100`）→ topup → raise-hold → extend → 卖出保护拒绝 / 放行 → `--break-bond` → report（1% 到账）→ 首次 burn 只记点 → 之后每 10 分钟一块；打新币上 post → 过期后卖出被拒、`--settle-first` 给出 settle → 第三方 settle 后押金回到创建者。
- BSC 主网分叉上测了发币时押（当前版本）：V3 内盘押金 30 天后 dev 申请退款 → 公告期内执行被拒 → 3 天后取回；V3 内盘卖出违约 → 举报 → 开盘前回购被拒 → 30 天后报价币转 0xdead；打新卖回份额被卖出保护拦下，`--break-bond` 后判违约。
- BSC 测试网：第一版上 V3 币完整罚没流程按真实出块跑完（4 块回购，销毁 3,722,162 枚），打新币走完取回以外的全部操作；第二版上 V3 内盘押金、延期、内盘卖出保护、违约、举报、开盘前回购被拒都已上链；第三版上内盘押金和各项拒绝已上链，留一笔押金到 11-27 后补测两步退款。见 `docs/TESTNET-GANG-BOND-2026-10-28.md`。

## 还没做

- 源码验证：主网 `0xe92d…14E4`、弃用的 `0xf26F…C817` 和测试网第四版 `0xd6a8…1086` 已在 BscScan 验证（2026-10-29）；更早的三版测试网合约没做。
- 测试网 B 币的取回（2026-11-05 之后）。
- 网站、服务端、keeper 已做（gang-web-legacy #10 / #11，gangfun-server #14 / #15）；正式站上线见 `docs/MAINNET-GANG-BOND-2026-10-29.md`。

