<p align="center">
  <img src="web/public/brand/lockup.png" alt="GANG" height="42" />
</p>

<p align="center">
  <img src="https://img.shields.io/badge/BNB%20Chain-BSC-FCD535?style=flat-square&labelColor=0E0E0E" alt="BNB Chain" />
  <img src="https://img.shields.io/badge/gate-BAW%20Dev%20%2B%20Agent%20ID-FCD535?style=flat-square&labelColor=0E0E0E" alt="BAW" />
</p>

<p align="center"><a href="./README.md">English</a> · <a href="./README.zh-CN.md">中文</a></p>

<pre align="center">
╔══════════════════════════════════════════════════════════╗
║  GANG · BNB Chain 发射台 · 内盘 + 帮派池               ║
║  用 Binance Agentic Wallet 交易 · gang.fun               ║
╚══════════════════════════════════════════════════════════╝
</pre>

**创建仅限 BAW Dev。内盘买入和卖出都需要 SPACE ID Agent ID（`.ai`）。** Agent ID 从 Binance Agentic Wallet 领取。由你的 agent 跑 CLI；需要时在币安 App 里确认。CLI **不持有私钥**。

软启动在 BSC。BNB 主轨毕业线是 **20 BNB**。帮派池（任意池）在创建时锁定 `gradAmt`，大约 **15 BNB** 等值，来自运营覆盖或现货。

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

- **仅 BAW Dev**（`isDev` / owner `setDev`）。创建费为 0。之后内盘买卖都要有 Agent ID。

### 已毕业代币

- 若命令返回 `graduated: true`，曲线已关闭 —— 用返回的 `pair` 去 **PancakeSwap V2** 交易。
- 无税 BNB 主轨：毕业后平台费为 0。
- 有税帮派池：外盘交易另收 **1%**。Keeper 调用 `process` 后，这笔税才进入分红和平台桶。

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
| 链 | BSC |
| 谁能创建 | **仅 BAW Dev**（`isDev` / `setDev`） |
| 谁能在内盘买 / 卖 | **仅 BAW Agent ID** |
| 毕业之后 | 任何人都可以在 Pancake 池交易。有税代币仍交外盘税。 |
| 上限 | 曲线阶段单钱包总供应 **1%**（`10_000_000` 枚） |
| 供应 | 固定 10 亿 · 内盘 8 亿 · 进池 2 亿 |
| 无税 | 内盘 **1%** → **80%** 回购并销毁 GANG · **20%** 金库（`feeVault`） |
| 有税 | 内盘 **和** 外盘各 **1%** → **50%** 分红（持仓份额 ≥ `TAXED_MIN_SHARE` = 100 万枚）· 另外 **50%** 再按 **80/20** 分给回购 / 金库 |
| BNB 主轨 | 满 **20 BNB** 毕业 · LP 进 `0x…dEaD` · 转账解锁 · 毕业后平台费为 0 |
| 帮派池（任意池） | 创建时锁定 `gradAmt`（运营 `graduationQuoteAmount` 或现货，约 **15 BNB** 等值）· `virtualQuote = floor(gradAmt / 3)` · 有税轨同时走 PostGrad |
| 转账 | 毕业前锁定 |
| 回购 | quote → GANG，烧到 `0x…dEaD`。Smart Router 路径是 exact-input（`collectPlatformSmart`）。`minGangOut` 由链下给出。 |

## 附录 B · 已部署的 BNB 主轨（BSC）

下表是已经公开的 v4.1 BNB 曲线地址。帮派池（`LaunchpadU` / `LaunchpadS`）的源码在本仓库，供软启动使用；这里不把它们写成主网部署。本仓库里的 `Launchpad` 源码是软启动包（Dev 白名单、内盘卖出也要 Agent、一次性 `setPlatformToken`）。`0x315B…` 链上实际字节码以 BscScan 为准。

| 合约 | 部署区块 | 地址 |
|---|---|---|
| Launchpad v4.1（已部署的 BNB 曲线） | **128977029** | [`0x315Ba2e8952D06094CC636b2B84229FA32fb23A7`](https://bscscan.com/address/0x315Ba2e8952D06094CC636b2B84229FA32fb23A7) |
| Migrator v4.1 | **128977029** | [`0xFcB6278b6FE3f2e3F567bb49cBf8d8883bcE96E9`](https://bscscan.com/address/0xFcB6278b6FE3f2e3F567bb49cBf8d8883bcE96E9) |
| 平台币（GANG） | **128977029** | [`0x0c6302401aa5325C2E36F170f52C00B1d220B405`](https://bscscan.com/address/0x0c6302401aa5325C2E36F170f52C00B1d220B405) |
| Agent ID（SPACE ID） | — | [`0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F`](https://bscscan.com/address/0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F) |
| feeVault / 运维金库 | — | `0x3464aa1097Aa46502Db847E4c6d0A2D52a871Af4` |
| Pancake V2 Router | — | `0x10ED43C718714eb63d5aA57B78B54704E256024E` |

## 附录 C · OPT5C（简）

源码在 `src/stocks/`，外加软启动版 `Launchpad`。`script/DeployMainnetDraft.s.sol` 会主动 revert，不会广播。

- 每条曲线 `virtualQuote = floor(gradAmt / 3)`，创建时锁定。
- `LaunchpadS` PostGrad：内外盘都是 **1%**，分成与有税 `LaunchpadU` 相同。
- 运营覆盖：`QuoteRegistry.graduationQuoteAmount > 0` 时锁定该 `gradAmt`，跳过 V2 现货。
- 卡住的 quote 分两步清：`requestFlush`，满 **7 天** 后 `flushStuckQuoteToTreasury`。成功的 `collectPlatform` / `collectPlatformSmart` 会清掉这条请求。
- Smart Router 回购：`collectPlatformSmart` → `buybackAndBurnSmart`。quote 必须 exact-input 花完（`balance == before - amountIn`），否则 `IncompleteQuoteSpend`。
- `TAXED_MIN_SHARE = 1_000_000 ether`（100 万枚）。
- 毕业后 pair 兑换按 **9975/10000**（Pancake 0.25%）。转账钩子里不做 swap。
- `LaunchpadU` / `LaunchpadS` 和手续费合约使用 **Ownable2Step**。

## 附录 D · 仅 Chapel 测试网（chainId 97）

来自 tip `chapel-opt5c-202610231325` 的测试网地址。不是主网地址。

| | 地址 |
|---|---|
| LaunchpadU | `0xB12f0033B747c01c261AA97565473a19ae2195C3` |
| LaunchpadS | `0x9CA02C10fF73857F2C6ae2d2803660Ca988c52A7` |
| BucketU | `0x4b5A2fAF01637b3de0fc02630e52991b22Fd0eE5` |
| BucketS | `0x80565663BB74dA75A79E82b4dEa899E1E85a3A74` |
| BurnerU | `0x38D021Cd9419760ceCA24559d9381BB8EBda2B64` |
| BurnerS | `0x7De78eDE466d33260947D65999581faF62cB56D1` |
| HandlerU | `0x1eE4DdB60F7E7B5DA32D74eA41C0043E7C1eEDb3` |
| HandlerS | `0xeD91DeFe0a3E5c17e6492c6CbA570C362D0aB52A` |
| VaultU | `0x957bEc2Aa87c6B196c968a4e2a2E8f19C36d5AC8` |
| VaultS | `0x11140E0353770b27c432bCBd0D4eA445F10679eA` |
| RegistryU | `0xDEf94E028A5c314c63d84769b347B7656EFF1D07` |
