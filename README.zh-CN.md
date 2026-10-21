<p align="center">
  <img src="web/public/brand/lockup.png" alt="GANG" height="42" />
</p>

<p align="center">
  <img src="https://img.shields.io/badge/BNB%20Chain-BSC%20·%20v3-FCD535?style=flat-square&labelColor=0E0E0E" alt="BNB Chain" />
  <img src="https://img.shields.io/badge/gate-Agent%20ID%20only-FCD535?style=flat-square&labelColor=0E0E0E" alt="Agent ID" />
</p>

<p align="center"><a href="./README.md">English</a> · <a href="./README.zh-CN.md">中文</a></p>

<pre align="center">
╔══════════════════════════════════════════════════════════╗
║  GANG · BNB Chain 上仅 Agent 可买的发射台                ║
║  用 Binance Agentic Wallet 交易 · gang.fun               ║
╚══════════════════════════════════════════════════════════╝
</pre>

**只有持有 SPACE ID Agent ID（`.ai`）的钱包能在内盘买入。** Agent ID 从 Binance Agentic Wallet 领取。由你的 agent 跑 CLI；需要时在币安 App 里确认。CLI **不持有私钥**。

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

# 3) @gangfun/cli 上 npm 之前：本地 link
cd skill/gang-cli && npm i && npm link   # 得到命令: gang
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

- 谁都可以创建（创建费 0）。之后只有持有 Agent ID 的钱包能在内盘买。

### 已毕业代币

- 若命令返回 `graduated: true`，曲线已关闭 —— 用返回的 `pair` 去 **PancakeSwap V2** 交易。毕业后平台费为 0。

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

## 附录 A · 规则（极简）

| | |
|---|---|
| 谁能买（内盘） | 仅 Agent ID 持有人（链上 `balanceOf`） |
| 谁能卖 | 任意持有人 |
| 上限 | 单钱包总供应 **1%** |
| 手续费 | 内盘买卖各 **1%** → 平台金库；**毕业后 0** |
| 供应 | 固定 10 亿 · 内盘 8 亿 · 进池 2 亿 |
| 毕业 | 真实筹资满 **20 BNB** → Pancake V2 · LP → `0x…dEaD` · 转账解锁 |
| 转账 | 毕业前锁定 |

## 附录 B · 合约（BSC · v3）

| 合约 | 部署区块 | 地址 |
|---|---|---|
| Launchpad v3 | **128858413** | [`0xBfBB10db587DdFDF38c888cB80C5124f1Aa3C0Eb`](https://bscscan.com/address/0xBfBB10db587DdFDF38c888cB80C5124f1Aa3C0Eb) |
| Migrator v3 | **128858413** | [`0x4b1E5a7602c7f7964c08364241c1FE59CB4095C8`](https://bscscan.com/address/0x4b1E5a7602c7f7964c08364241c1FE59CB4095C8) |
| Agent ID（SPACE ID） | — | [`0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F`](https://bscscan.com/address/0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F) |

v1 / v2 已作废 —— 只用 **v3**。请在 BscScan 核验。
