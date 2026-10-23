<p align="center">
  <img src="web/public/brand/lockup.png" alt="GANG" height="42" />
</p>

<p align="center">
  <img src="https://img.shields.io/badge/BNB%20Chain-BSC%20mainnet%20%C2%B7%2056-FCD535?style=flat-square&labelColor=0E0E0E" alt="BNB Chain" />
  <img src="https://img.shields.io/badge/status-soft%20launch%20%C2%B7%20not%20audited-FCD535?style=flat-square&labelColor=0E0E0E" alt="Not audited" />
  <img src="https://img.shields.io/badge/gate-BAW%20Dev%20%2B%20Agent%20ID-FCD535?style=flat-square&labelColor=0E0E0E" alt="BAW" />
</p>

<p align="center"><a href="./README.md">English</a> · <a href="./README.zh-CN.md">中文</a></p>

<pre align="center">
╔══════════════════════════════════════════════════════════╗
║  GANG · BNB Chain 发射台 · 内盘 + 帮派池               ║
║  用 Binance Agentic Wallet 交易 · gang.fun               ║
╚══════════════════════════════════════════════════════════╝
</pre>

**新的创建走 LaunchpadV2**（BSC 主网）。Soft Launchpad、LaunchpadU、LaunchpadS 合约还在；这三条的创建已归档。**内盘买入和卖出是 BAW Agent**（SPACE ID Agent ID，`.ai`）。Agent ID 从 Binance Agentic Wallet 领取。由你的 agent 跑 CLI；需要时在币安 App 里确认。CLI **不持有私钥**。**walletCap 开启**（曲线阶段单钱包总供应 1%）。

**软启动 · 未审计。** 已在 BSC 主网（chainId 56）上线：[gang.fun](https://gang.fun)。不要把这些合约说成已审计。Chapel（chainId 97）不是这次部署。LaunchpadV2 地址与 startBlock `129311617`：[docs/MAINNET-LAUNCHPAD-V2-ADDRESSES-2026-10-23.md](./docs/MAINNET-LAUNCHPAD-V2-ADDRESSES-2026-10-23.md)。

| 轨道 | 地址 | 毕业 |
|---|---|---|
| LaunchpadV2（创建） | [`0x1B8F3f69DFa0a7F63d308C7EB0Fd38D8b099966E`](https://bscscan.com/address/0x1B8F3f69DFa0a7F63d308C7EB0Fd38D8b099966E) | ≈ **15 BNB** 等值，创建时锁定 |
| Soft Launchpad（BNB） | [`0x315Ba2e8952D06094CC636b2B84229FA32fb23A7`](https://bscscan.com/address/0x315Ba2e8952D06094CC636b2B84229FA32fb23A7) | **20 BNB** · 创建已归档 |
| GANG（平台币） | [`0x0c6302401aa5325C2E36F170f52C00B1d220B405`](https://bscscan.com/address/0x0c6302401aa5325C2E36F170f52C00B1d220B405) | — |
| LaunchpadU | [`0x245a42cE8337DECe0f1C04f8430C90C8D98b88e4`](https://bscscan.com/address/0x245a42cE8337DECe0f1C04f8430C90C8D98b88e4) | 现货 Grad15 ≈ **15 BNB** 等值 · 创建已归档 |
| LaunchpadS | [`0x80C5e29417f8037A9e4CC5320878386826732e89`](https://bscscan.com/address/0x80C5e29417f8037A9e4CC5320878386826732e89) | 现货 Grad15 ≈ **15 BNB** 等值 · 创建已归档 |

U/S 上 `virtualQuote = floor(gradAmt / 3)`。QuoteRegistry 是白名单。`graduationQuoteAmount` 为 **0** 表示现货 Grad15；大于 0 则锁定该 quote 数量。毕业后 **1%** 税先累积，再由 keeper 调用 `process()`（DEX 约 0.3%）。转账钩子不得 swap。回购销毁的是 **GANG**。

---

## 1. 一次性准备

### A. Binance Agentic Wallet

1. 在币安 App 里创建 / 打开 **Agentic Wallet**。
2. 在 Agent ID 入口领取 **SPACE ID Agent ID**（`.ai` 名字）—— BSC 上的灵魂绑定 NFT；合约检查的就是它。
3. 在 App 里打开：
   - **Developer Mode（开发者模式）** — 任何合约调用（`buy` / `sell` / `create`）都需要。有日限额和到期时间。
   - **Trade all tokens（交易全部代币）** — **卖出**需要。不开的话买入可能成功，卖出会被风控拦截（错误码 `351803`）。

### B. 给 agent 安装 skill

```bash
# 1) Binance Agentic Wallet skill（登录、签名、风控）
npx skills add binance/binance-skills-hub/skills/binance-web3/binance-agentic-wallet

# 2) Gang skill
npx skills add gangfun/gang-launchpad/skill

# 3) 安装 Gang CLI（GitHub Packages，不上 npmjs）
npm i -g @gangfun/cli@0.1.3 --registry=https://npm.pkg.github.com   # 得到命令: gang
# 需要带 read:packages 的 GitHub token 写在 ~/.npmrc — 见 cli README
# 备选（不需要 Packages token）: npm i -g github:gangfun/cli
```

用 `baw` 登录一次（按提示打开 App 配对链接 / 输入配对码）。

---

## 2. 每次开干：先 preflight

```bash
gang preflight
```

期望：`status: CONNECTED`、`isAgent: true`、`devMode: true`、`tradeAllTokens: true`、`issues[]` 为空。

| 如果你看到… | 在币安 App / baw 里这样修 |
|---|---|
| not signed in | `baw auth signin` → 扫码 / 输入配对码 → `baw auth verify` |
| no Agent ID | 在 Agentic Wallet 入口领取 `.ai` Agent ID |
| Developer Mode off | 打开 Developer Mode（所有 Gang 交易都需要） |
| Trade all tokens off | **卖出前**必须打开 |

把每条 `issues[].fix` 原文转给用户。Preflight 不花 gas。

---

## 3. 交易流程（预览 → 确认 → 执行）

硬规则：`buy` / `sell` / `create` **只做预览**。把报价 / 风险 / 手续费 / 退款给用户看，等明确说「确认」后再 `gang execute`。`requestId` 大约 5 分钟过期。

```bash
gang list                                    # 列表：价格、进度、你的余额
gang token  --token 0x…                      # 单个代币 + 毕业进度
gang quote  --token 0x… --bnb 0.05           # 链上报价（费、上限、退款）

gang buy    --token 0x… --bnb 0.05           # 预览 → requestId
gang execute --request-id <id>               # 用户确认后再广播

gang sell   --token 0x… --all                # 预览（可能要先 approve）
gang execute --request-id <id>

gang create --name "My Agent Coin" --symbol MAC
gang execute --request-id <id>

gang tx     --hash 0x…                       # 链上最终结果
```

### 买入

- 需要 Agent ID + Developer Mode。
- 执行后通常 **不需要** 再在 App 里点确认。
- 若报价出现 `refund`，说明碰到 **单钱包 1% 上限**（1000 万枚）；多出的 BNB 会在同一笔交易退回。

### 卖出

- 需要打开 **Trade all tokens**。
- `execute` 后币安可能返回 `pendingConfirmation: true` → **打开币安 App 点确认**。不要重复 `execute`。轮询历史，再用 `gang tx --hash …`。
- 待确认订单几分钟内过期；过期就重新预览。

### 创建

- 新的创建走 **LaunchpadV2**。Soft / U / S 的创建已归档，合约仍在。地址：[docs/MAINNET-LAUNCHPAD-V2-ADDRESSES-2026-10-23.md](./docs/MAINNET-LAUNCHPAD-V2-ADDRESSES-2026-10-23.md)。
- 已归档的 Soft 创建是 **BAW Dev**（`isDev` / owner `setDev`）。创建费为 0。内盘买卖都要有 Agent ID。

### 已毕业代币

- 若命令返回 `graduated: true`，曲线已关闭 —— 用返回的 `pair` 去 **PancakeSwap V2** 交易。
- 无税 BNB 主轨：毕业后平台费为 0。
- 有税帮派池（LaunchpadU / LaunchpadS）：毕业后 **1%** 税先累积。Keeper 调用 `process()` 卖掉（DEX 约 0.3%），再进入分红和平台桶。转账钩子不得 swap。回购销毁 **GANG**。

---

## 4. 给 agent 的白话速查

| 用户说 | 你跑 |
|---|---|
| 「我能不能玩 Gang？」 | `gang preflight` |
| 「有哪些盘 / 列表」 | `gang list` |
| 「0.05 BNB 能买多少？」 | `gang quote --token … --bnb 0.05` |
| 「用 0.05 BNB 买 0x…」 | `gang buy` → 展示预览 → 等确认 → `gang execute` |
| 「卖掉全部 0x…」 | `gang sell --all` → 确认 → `execute` → 可能要 App 点确认 |
| 「发一个币」 | `gang create` → 确认 → `execute` |

金额一律说 BNB / 代币，不要说 wei。地址写全；买入前必须确认。

---


## 运维 · 手续费 keeper（VPS）

每日 permissionless 结算：`scripts/keeper-collectfees.sh`（默认 dry-run）。

- Keeper 地址：`0xb6f1f1bfb92476abb0998b425de0dec5f927cfc7`（只付 gas；充 ≥0.05 BNB）
- 私钥**只**放 VPS：`/opt/gang/keeper/.env` → `KEEPER_PRIVATE_KEY=`（禁止进 git）
- cron 示例（上海 10:00）：`0 10 * * * /opt/gang/keeper/keeper-collectfees.sh --broadcast --log-dir /opt/gang/keeper/logs`
- `accruedFees==0` 跳过；超过 0.2 BNB 拒绝自动广播（可用 `--max-accrued` 覆盖）

## 附录 A · 规则（软启动）

| | |
|---|---|
| 链 | BSC **主网**（chainId 56）· [gang.fun](https://gang.fun) · **未审计** |
| 谁能创建 | **仅 BAW Dev**（`isDev` / `setDev`） |
| 谁能在内盘买 / 卖 | **仅 BAW Agent**（Agent ID） |
| 毕业之后 | 任何人都可以在 Pancake 池交易。有税代币仍交外盘税。 |
| 上限 | **walletCap 开启** · 曲线阶段单钱包总供应 **1%**（`10_000_000` 枚） |
| 供应 | 固定 10 亿 · 内盘 8 亿 · 进池 2 亿 |
| 无税 | 内盘 **1%** → **80%** 回购并销毁 GANG · **20%** 金库（`feeVault`） |
| 有税 | 内盘 **和** 外盘各 **1%** → **50%** 分红（持仓份额 ≥ `TAXED_MIN_SHARE` = 100 万枚）· 另外 **50%** 再按 **80/20** 分给回购 / 金库 |
| BNB 主轨 | 满 **20 BNB** 毕业 · LP 进 `0x…dEaD` · 转账解锁 · 毕业后平台费为 0 |
| LaunchpadU / LaunchpadS | 现货 Grad15 ≈ **15 BNB** 等值，创建时锁定 · `virtualQuote = floor(gradAmt / 3)` · QuoteRegistry 白名单 · `graduationQuoteAmount` **0** = 现货 Grad15 |
| PostGrad | **1%** 税先累积 · keeper `process()`（DEX 约 0.3%）· 转账钩子**不得** swap · 平台币 **GANG** |
| 转账 | 毕业前锁定 |
| 回购 | quote → GANG，烧到 `0x…dEaD`。Smart Router 路径是 exact-input（`collectPlatformSmart`）。`minGangOut` 由链下给出。 |

## 附录 B · Soft Launchpad，BNB 主轨（BSC 主网）

软启动的现网地址。**未审计。** 本仓库里的 `Launchpad` 源码是软启动包（Dev 白名单、内盘卖出也要 Agent、一次性 `setPlatformToken`）。`0x315B…` 链上实际字节码以 BscScan 为准。LaunchpadU / LaunchpadS 见附录 C。

| 合约 | 部署区块 | 地址 |
|---|---|---|
| Launchpad v4.1（已部署的 BNB 曲线） | **128977029** | [`0x315Ba2e8952D06094CC636b2B84229FA32fb23A7`](https://bscscan.com/address/0x315Ba2e8952D06094CC636b2B84229FA32fb23A7) |
| Migrator v4.1 | **128977029** | [`0xFcB6278b6FE3f2e3F567bb49cBf8d8883bcE96E9`](https://bscscan.com/address/0xFcB6278b6FE3f2e3F567bb49cBf8d8883bcE96E9) |
| 平台币（GANG） | **128977029** | [`0x0c6302401aa5325C2E36F170f52C00B1d220B405`](https://bscscan.com/address/0x0c6302401aa5325C2E36F170f52C00B1d220B405) |
| Agent ID（SPACE ID） | — | [`0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F`](https://bscscan.com/address/0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F) |
| feeVault / 运维金库 | — | `0x3464aa1097Aa46502Db847E4c6d0A2D52a871Af4` |
| Pancake V2 Router | — | `0x10ED43C718714eb63d5aA57B78B54704E256024E` |

## 附录 C · OPT5C，BSC 主网（chainId 56）

2026-10-23 广播。**软启动，未审计。** 站点：[gang.fun](https://gang.fun)。下面是主网地址。Chapel（chainId 97）不是这次部署，测试网地址不在这里列出。本仓库的 `script/DeployMainnetDraft.s.sol` 仍会 revert，并不是打出下列地址的那次广播。

LaunchpadU 和 LaunchpadS 的 `agentGateEnabled` 与 `walletCapEnabled` 都是 true。BuybackBurner 的 `gang` 是 GANG。BuybackBurner 的 `smartRouter` 是 Pancake Smart Router。

### 共用（主网已有）

| | 地址 |
|---|---|
| Soft Launchpad | [`0x315Ba2e8952D06094CC636b2B84229FA32fb23A7`](https://bscscan.com/address/0x315Ba2e8952D06094CC636b2B84229FA32fb23A7) |
| GANG | [`0x0c6302401aa5325C2E36F170f52C00B1d220B405`](https://bscscan.com/address/0x0c6302401aa5325C2E36F170f52C00B1d220B405) |
| feeVault | `0x3464aa1097Aa46502Db847E4c6d0A2D52a871Af4` |
| Keeper | `0xB6f1F1BFb92476Abb0998B425dE0deC5F927cFc7` |
| AgentIdRegistry | [`0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F`](https://bscscan.com/address/0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F) |
| Pancake V2 Router | `0x10ED43C718714eb63d5aA57B78B54704E256024E` |
| Pancake Smart Router | `0x13f4EA83D0bd40E75C8222255bc855a974568Dd4` |
| WBNB | `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c` |
| 部署者 | `0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3` |

### LaunchpadU

| | 地址 |
|---|---|
| LaunchpadU | [`0x245a42cE8337DECe0f1C04f8430C90C8D98b88e4`](https://bscscan.com/address/0x245a42cE8337DECe0f1C04f8430C90C8D98b88e4) |
| QuoteRegistry | `0x1a90B418023933A5D162Ab96b7adB3864B201e05` |
| DividendVault | `0x1D9a511cd15FDcD2Fad24512D74b38C2cE02b2DF` |
| PlatformFeeBucket | `0xdEd4D0022879ad1268C754a49F7aDF1bD130b18C` |
| PostGradTaxHandler | `0xb8714dF76Bea4AeE2F961daBFc3a0584B057D855` |
| BuybackBurner | `0xc2bffC6a87eA6ae07180A7Ab05aE6406B255d81F` |
| MigratorS | `0xCE065aa82d4d387d1491d5046600b764c39b05CA` |

### LaunchpadS

| | 地址 |
|---|---|
| LaunchpadS | [`0x80C5e29417f8037A9e4CC5320878386826732e89`](https://bscscan.com/address/0x80C5e29417f8037A9e4CC5320878386826732e89) |
| QuoteRegistry | `0xa7aed928eca3E437A57b4018C7a19B81b79b1bc7` |
| DividendVault | `0x20b5e893447623AC893f4Fb86A51930A588402Aa` |
| PlatformFeeBucket | `0x30a49540b06476c4089097869B3920ea47C1537e` |
| PostGradTaxHandler | `0x35ea5f0d80A8bd91a7Ea39FeCD746aACA76957EA` |
| BuybackBurner | `0xceA0C99522Dc26Cb64609aA758DE6671281D8D6D` |
| MigratorS | `0x4f2A02a56f9e1AB2E9b4469569C9D1E724C1dcDb` |

- Soft 轨毕业线是 **20 BNB**。U/S 在创建时锁定现货 Grad15（≈ **15 BNB** 等值）。`virtualQuote = floor(gradAmt / 3)`。
- QuoteRegistry 是白名单。`graduationQuoteAmount == 0` 锁定现货 Grad15。**大于 0** 则锁定该 `gradAmt`，跳过 V2 现货。
- 创建是 **BAW Dev**。内盘买卖是 **BAW Agent**。**walletCap 开启。**
- `LaunchpadS` 的 PostGrad 与有税 `LaunchpadU` 相同：内外盘都是 **1%**。这 **1%** 先累积，keeper 调用 `process()` 经 router 卖掉（DEX 约 0.3%）。转账钩子不得 swap。平台币是 **GANG**。
- 卡住的 quote 分两步清：`requestFlush`，满 **7 天** 后 `flushStuckQuoteToTreasury`。成功的 `collectPlatform` / `collectPlatformSmart` 会清掉这条请求。
- Smart Router 回购：`collectPlatformSmart` → `buybackAndBurnSmart`。quote 必须 exact-input 花完（`balance == before - amountIn`），否则 `IncompleteQuoteSpend`。
- `TAXED_MIN_SHARE = 1_000_000 ether`（100 万枚）。
- `LaunchpadU` / `LaunchpadS` 和手续费合约使用 **Ownable2Step**。

## 附录 D · LaunchpadV2，BSC 主网（chainId 56）

2026-10-23 广播。**未审计。** 新的创建走 LaunchpadV2。Soft Launchpad、LaunchpadU、LaunchpadS 合约还在；这三条的创建已归档。startBlock **129311617**。源码：`src/launchpad-v2/`（PoolCheck 是 public library）。与 Soft/U/S 的差异：[docs/launchpad-v2/DIFF-VS-LIVE.md](./docs/launchpad-v2/DIFF-VS-LIVE.md)。完整表：[docs/MAINNET-LAUNCHPAD-V2-ADDRESSES-2026-10-23.md](./docs/MAINNET-LAUNCHPAD-V2-ADDRESSES-2026-10-23.md)。

| 合约 | 地址 |
|---|---|
| LaunchpadV2 | [`0x1B8F3f69DFa0a7F63d308C7EB0Fd38D8b099966E`](https://bscscan.com/address/0x1B8F3f69DFa0a7F63d308C7EB0Fd38D8b099966E) |
| MigratorV2 | [`0x2D54351657647824c92a36c309A8ed40715968F6`](https://bscscan.com/address/0x2D54351657647824c92a36c309A8ed40715968F6) |
| QuoteRegistry | `0x053C2868e54921afEd7742bbb4c4fDA99a12060D` |
| DividendVault | `0x5e2Dd1D439b251d64B4147D8947445f83f3A2D62` |
| PlatformFeeBucket | `0xBDDd8F275D7Cb65f5454D0bEDf0463792878F111` |
| PostGradTaxHandler | `0xa2bd8e511Cf01aA8F9693a841FD6ee6E30253e29` |
| PoolCheck（library） | `0xd2B159820749f178503E4faBCB18A7Ae4492bDb3` |

复用：BuybackBurner `0x2aC14C462901F990ae7647D6AcafEaf50Cc8f8dF`，feeVault `0x3464aa1097Aa46502Db847E4c6d0A2D52a871Af4`，GANG `0x0c6302401aa5325C2E36F170f52C00B1d220B405`。
