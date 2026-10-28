# 主网 · GangBond（Agent 押金承诺）

- 日期：2026-10-29 Asia/Shanghai
- 代码：main `88be8e1`。包含主网前审计的修复（`docs/AUDIT-GANG-BOND-2026-10-29.md`、PR #54），和测试网第四版 `0xd6a8…1086` 是同一份代码。
- 审计：只做了内部审计，没有第三方审计，是否补做由项目方决定。

## 合约

| 项 | 值 |
|---|---|
| GangBond | [`0xf26F33432E33FcE615abf3801ca0c91D1C62C817`](https://bscscan.com/address/0xf26F33432E33FcE615abf3801ca0c91D1C62C817) |
| 部署交易 | [`0xed05117e…b606`](https://bscscan.com/tx/0xed05117edc439be8f319a693b935fd53b86965e5e5f57585e0547b719f8bb606)，区块 130335965，gas 2,969,709 × 0.05 gwei |
| 构造参数 | pad = 在用的 GangLaunchpad `0x15CFD2dc8278Fb87a1783ef42111618E20874365`，wbnb = `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c` |
| 部署钱包 | `0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3` |
| 部署脚本 | `script/DeployGangBond.s.sol`（主网要求 `GANG_PAD` 等于在用 pad），记录在 `broadcast/DeployGangBond.s.sol/56/` |
| 源码验证 | 已验证（2026-10-29，`forge verify-contract`，Etherscan v2 接口；solc 0.8.28，优化 200 runs） |

部署后从链上读回：`pad`、`wbnb` 和上表一致；`CHUNK_GAP` 240、`SETTLE_DELAY` 3600、`MAX_WAIT` 2592000。合约没有 owner，不可升级，部署后也没有要配的东西。

## 接入

| 位置 | 内容 |
|---|---|
| CLI | 0.15.1 内置 `MAINNET_BOND`（`skill/gang-cli/src/bond.js`），已同步到 gangfun/cli 并发布到 npm |
| 正式站 indexer | gangfun-server v1.2.43；`/opt/gang/indexer/indexer.env` 加了 `GANG_BOND`、`GANG_BOND_START_BLOCK=130335965` 和 `GANG_BOND_BALANCE_RPC_URLS`（QuickNode，可读历史状态）；修改前备份为 `indexer.env.bak-20261029-bond`。`https://gang.fun/api/bonds/config` 返回 `enabled: true` |
| 正式站 keeper | `/opt/gang/keeper/.env`（修改前备份为 `.env.bak.<时间戳>`）加了 `BONDS=main:0xf26F…C817@130335965`、`BOND_WATCH=1` 和 `BOND_LOCK`；举报和回购走 48 Club 隐私 RPC（`KEEPER_PRIVATE_RPC=https://rpc.48.club`），读链走 QuickNode。crontab 每 5 分钟跑一次 `keeper-bond.sh`；systemd `gang-keeper-bond-watch` 每 3 秒检查一次 |
| 押金 keeper 钱包 | 单独的钱包 [`0x807225305Aa80d048b4bF071331340e618852Fa3`](https://bscscan.com/address/0x807225305Aa80d048b4bF071331340e618852Fa3)：私钥只在服务器 `.env` 里，举报的 1% 奖励进这个地址；从主 keeper 转入 0.06 BNB（[`0x1dd9665e…96db`](https://bscscan.com/tx/0x1dd9665e0e395c312a4d77929f1e02dc1c990ce1bfb8a70c99b78c2955df96db)） |
| 网站 | gang-web-legacy v1.2.64（押金面板、标识、「有押金」筛选、两步取回、报价币白名单） |

## 以后要做

- 私有通道换 QuickNode：在 QuickNode 后台给正式站的 BSC 节点开 **Merkle – MEV Protection** 插件，确认它支持 BSC 后，把 `KEEPER_PRIVATE_RPC` 换成同一个 QuickNode 地址，然后重启 `gang-keeper-bond-watch`。
- `GangBuybackSplitter` 复制了同一套回购逻辑，已经在主网上（工厂 v1 / v2，见 `docs/MAINNET-BUYBACK-SPLITTER-2026-10-28.md`）。审计 I-5（拉盘后卖给回购）对它同样成立，要尽快按时间限速出新版。
