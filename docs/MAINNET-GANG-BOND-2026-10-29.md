# 主网 · GangBond（Agent 押金承诺）

- 日期：2026-10-29 Asia/Shanghai
- 代码：main `0e4dee2`。包含主网前审计的修复（`docs/AUDIT-GANG-BOND-2026-10-29.md`、PR #54）和复审 L-1 的修复（PR #66：回购按交易对实际收到的报价币计价，见下文「复审与重新部署」）。测试网第四版 `0xd6a8…1086` 没有 L-1 的修复，其余相同。
- 审计：只做了内部审计和一次独立复审，没有第三方审计，是否补做由项目方决定。

## 合约

| 项 | 值 |
|---|---|
| GangBond | [`0xe92dC940CB23Dc328639A7334e69F9CCdf3a14E4`](https://bscscan.com/address/0xe92dC940CB23Dc328639A7334e69F9CCdf3a14E4) |
| 部署交易 | [`0xc64d4195…6882`](https://bscscan.com/tx/0xc64d4195e1b084678e8b59ce4de5c71ca663dcc6d58f16d643ad7f6424166882)，区块 130407146，gas 2,995,884 × 0.05 gwei |
| 构造参数 | pad = 在用的 GangLaunchpad `0x15CFD2dc8278Fb87a1783ef42111618E20874365`，wbnb = `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c` |
| 部署钱包 | `0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3` |
| 部署脚本 | `script/DeployGangBond.s.sol`（主网要求 `GANG_PAD` 等于在用 pad），记录在 `broadcast/DeployGangBond.s.sol/56/` |
| 源码验证 | 已验证（2026-10-29，`forge verify-contract`，Etherscan v2 接口；solc 0.8.28，优化 200 runs） |

部署后从链上读回：`pad`、`wbnb` 和上表一致；`CHUNK_GAP` 240、`SETTLE_DELAY` 3600、`MAX_WAIT` 2592000。合约没有 owner，不可升级，部署后也没有要配的东西。

## 接入

| 位置 | 内容 |
|---|---|
| CLI | 0.16.2 内置 `MAINNET_BOND`（`skill/gang-cli/src/bond.js`），同步到 gangfun/cli 并发布到 npm。0.15.1–0.16.1 内置的是弃用的 `0xf26F…C817` |
| 正式站 indexer | gangfun-server v1.2.43 起索引 `0xe92d…14E4`（从部署区块 130407146 开始）；换合约时清掉了旧合约的押金数据（本来就是空的）。`https://gang.fun/api/bonds/config` 返回新地址和 `enabled: true`。具体配置在私有的 gangfun-server 里维护 |
| 正式站 keeper | 盯新合约：违约举报、到期两步取回、罚没后分块回购；举报和回购走私有交易通道（审计 M-1），每几秒检查一次，另有定时任务兜底。回购的最低买入量取自模拟的 `burnChunk(token, 0)`（gangfun-server v1.2.46）。具体配置在私有的 gangfun-server 里维护 |
| 押金 keeper 钱包 | 单独的钱包 [`0x807225305Aa80d048b4bF071331340e618852Fa3`](https://bscscan.com/address/0x807225305Aa80d048b4bF071331340e618852Fa3)，举报的 1% 奖励进这个地址 |
| 网站 | gang-web-legacy v1.2.64（押金面板、标识、「有押金」筛选、两步取回、报价币白名单） |

## 复审与重新部署

第一版主网合约 [`0xf26F33432E33FcE615abf3801ca0c91D1C62C817`](https://bscscan.com/address/0xf26F33432E33FcE615abf3801ca0c91D1C62C817)（区块 130335965，main `88be8e1`，已验证源码）上线后做了一次独立复审：没有高危、中危，有一个低危 L-1。

- L-1：`burnChunk` 按 `quoteIn` 算买入量。如果报价币对「转进交易对」收税，交易对实际收到的少于 `quoteIn`，每块回购都过不了 Pancake 的 K 检查。罚没的押金永远回购不完，这个币也永远不能再押（`BondLive`）。
- 修法：转账后用 `balanceOf(pair) - 储备` 计价（PR #66，测试 `test/gang/GangBondPairTax.t.sol`）。`previewBurn` 仍按 `quoteIn` 估算。

第一版从部署到弃用一直没人用：合约里 0 WBNB，从部署区块到 130402100 没有任何事件。所以重新部署了一个，旧地址弃用，CLI、indexer、keeper 都改到新地址；网站读接口配置，自动跟上。旧合约没有 owner，没法停用：0.15.1–0.16.1 的 CLI 仍然可以往旧合约押，但网站和 keeper 都不再看它。

## 以后要做

- ~~`GangBuybackSplitter` v3（工厂 `0xf1d5…31Cd`）的 `work()` 也按 `quoteIn` 算买入量，L-1 对它同样成立~~：v4（`buyback-burn-v4`）的代码已修（同样按交易对实际收到的计价，另外把 `minTokensOut` 按实际收到的比例缩小），暂不部署，理由见 `docs/MAINNET-BUYBACK-SPLITTER-2026-10-28.md`「v4」。
