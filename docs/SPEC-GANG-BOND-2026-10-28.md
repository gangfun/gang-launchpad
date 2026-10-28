# 规格 · Agent 押金承诺（GangBond）

- 日期：2026-10-28 Asia/Shanghai
- 作者：Claude（按 claude.ai 文档「Agent 押金承诺规格草案」2026-10-27 版实现；待定问题全部按草案「建议」一栏）
- 性质：**未部署，禁止主网广播**。合约 `src/gang/GangBond.sol`，测试 `test/gang/GangBond.t.sol`，部署脚本 `script/DeployGangBond.s.sol`，CLI `skill/gang-cli/src/bond.js`。

## 一句话

创建者押一笔报价币，承诺截止时间 T 之前创建地址的余额始终不低于 X 枚；期间任何人发现余额低于 X 都能举报，举报人拿 1%，其余分块从交易对买回本币并转到 `0x…dEaD`。到 T 且余额达标，任何人调 `settle`，押金全部退回创建者。

## 和现有合约的边界

GangBond 不可升级、没有 owner，构造时写死 `pad`（GangLaunchpad）和 `wbnb`。只读 pad 的 `kindOf` / `curves` / `sales` 和代币的 `balanceOf` / `buyTaxBps` / `sellTaxBps`，只和交易对做买入。内盘、代币、分红、外盘税合约一行未改，也不需要给 GangBond 任何权限。

## 参数（草案值）

| 常量 | 值 | 作用 |
|---|---|---|
| `MIN_DURATION` / `MAX_DURATION` | 7 天 / 90 天 | 承诺期；`extend` 后的 T 也不超过 now + 90 天 |
| `REPORTER_BPS` | 100（1%） | 举报奖励，从押金出；创建者自己举报不给 |
| `CHUNK_MAX_BPS` | 50（0.5%） | 每块回购最多用交易对报价币储备的 0.5% |
| `TWAP_WINDOW` | 10 分钟 | 回购参考均价的最短窗口 |
| `MAX_PRICE_RISE_BPS` | 200（2%） | 现价高于均价 2% 以上不回购 |

## 实现时对草案的取舍

| 草案写法 | 实现 | 原因 |
|---|---|---|
| 「代币一律从 `token.pair()` 读」 | 交易对从 pad 的 `curves(token).pair` / `sales(token).pair` 读，首次 `post` 时缓存到 `marketOf` | 不收税的 V3 币（CLI 0.10.0 起默认）毕业时不调 `setPair`，`token.pair()` 一直是 0 |
| 卖出税「税收币读 `sellTaxBps()`，打新固定 1%」 | 两种都读 `token.sellTaxBps()` | 打新币的 `sellTaxBps` 本来就是 100，代币上的值就是实际收的税 |
| 视图只列了 5 个 | 另加 `quoteDump(token, holdAmount)`、`previewBurn(token)` | CLI 的 `--cover` 要在押金存在前算覆盖率；keeper / CLI 要给 `burnChunk` 算 `minTokensOut` |
| TWAP 观测方式未写 | 每个币存两个累计价格观测点（`old` / `recent`），均价窗口在 10–20 分钟之间；`report` 时清空，首次 `burnChunk` 只记点；距上次观测超过 20 分钟也重新开始（这次只记点） | 保证「罚没后第一次调用只记一个观测点」；内部审查 M-1：keeper 断档后若用整段空闲期的均价，价格下跌后有人能把价格拉回旧均价附近再卖给回购 |
| `settle` 只看即时余额 | 另要求交易对的代币余额不低于储备，否则 `FlashSwapActive` | 内部审查 L-2：挡住从本币交易对闪电兑换借币冒充达标 |
| 价格保护不过时的处理 | 不回滚，返回 `(0, 0)` | 观测点更新要落盘；只有同块重复调用（`BurnedThisBlock`）和滑点（`Slippage`）回滚 |
| — | 一块小到买不到 1 wei 代币时，这块报价币留在交易对里，`burnLeft` 照减 | 避免尘埃金额让 `burnLeft` 永远大于 0、创建者没法再押 |
| 退押金币种未写 | 退回报价币本身（WBNB 不解包成 BNB） | 不向任意地址发原生币，没有 receive 失败的分支 |
| `raiseHold`「新 X 不低于旧 X」 | 允许等于 | 照草案字面 |

## 边界情况（草案以外补充）

- 报价币把创建者拉黑时 `settle` 会一直失败，押金卡住且随时可能被举报；目前报价币只有 WBNB 和 QuoteRegistry 里的币，接受。
- GangBond 在回购交易里短暂持币：买入那笔转账先记税（`notifyTax`）再同步份额，GangBond 收到币时份额还没写，紧接着转到 0xdead 份额归零，所以不会分到分红。分红合约不需要排除它。
- 「路由被恶意升级后转走创建者的币」一行沿用草案：GangRouter 是 48 小时时间锁可升级代理，这条风险成立。

## 内部审查（2026-10-28，独立代理，只看合约）

没有 critical / high。已修：M-1（空闲后的旧均价，见上表）、L-2（本池闪电兑换）、`previewBurn` 在块大小为 0 时返回 not ready。不改：

- L-1「手续费写死 9975，换工厂会锁死回购」：交易对来自 `SharedMigrator.factory`，是 immutable；pad 的 `setPairFactory` 只影响参考池定价，交易对一定是 Pancake V2。
- 从别处借币（借贷协议、其他池子）在 `settle` 那一刻满足余额：快照式检查的固有局限。前提是违约后一直没人举报；服务端 keeper 上线后会在违约的下一个区块举报，在那之前只能靠第三方。
- 创建者换一个地址举报自己，就能拿回 1%：只是少罚 1%，不影响其余押金回购销毁。
- `historyOf.honored` 能用极小押金刷：前端展示时要和押金额一起看，不能当信誉分。
- `burnChunk` 调用者没有奖励，回购完全靠 keeper；keeper 停了只是变慢。押金远大于池子时，回购会受 2% 上限自我限速，需要很多小时。

## 测试

- `forge test --match-contract GangBondTest`：20 个用例，覆盖三种币（收税 V3、不收税 V3、打新）、全部检查和状态流转、举报奖励、取回后开新一轮、分块回购到 `burnLeft` 归零、拉盘后跳过、滑点、覆盖率公式、空闲后观测重启（改回旧逻辑时该用例失败）、闪电兑换中不能 settle、新一轮罚没在 20 分钟内也重新记点（删掉 `report` 里的重置时该用例失败）、ERC20 报价币的回购、两个币共用 WBNB 时各自记账。交易对用 `test/mocks/TwapMockPair.sol`（带 K 检查、0.25% 手续费和累计价格），`GangFixture` 新增 `_newPairFactory()` 钩子，其他测试不受影响。
- BSC 主网分叉（anvil，本地）上用真实 Pancake 交易对跑了 CLI 端到端：post（`--cover 100`）→ topup → raise-hold → extend → 卖出保护拒绝 / 放行 → `--break-bond` → report（1% 到账）→ 首次 burn 只记点 → 之后每 10 分钟一块；打新币上 post → 过期后卖出被拒、`--settle-first` 给出 settle → 第三方 settle 后押金回到创建者。

## 还没做

- 部署（测试网、主网）以及 CLI 里内置地址（现在靠 `GANG_BOND` / `GANG_TESTNET_BOND`）。
- 网站（gang-web-legacy）：币详情页押金面板和举报按钮、行情页标识和「有押金」筛选、创建者记录、文案。
- 服务端（gangfun-server）：索引 7 个事件、`/bonds` 接口、行情列表带押金和覆盖率、keeper（举报 / 取回 / 每 10 分钟回购）。
