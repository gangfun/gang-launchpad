<p align="center">
  <img src="web/public/brand/lockup.png" alt="GANG" height="42" />
</p>

<p align="center">
  <img src="https://img.shields.io/badge/BNB%20Chain-BSC%20·%20LaunchpadV2-FCD535?style=flat-square&labelColor=0E0E0E" alt="BNB Chain" />
  <img src="https://img.shields.io/badge/gate-仅%20Agent%20ID-FCD535?style=flat-square&labelColor=0E0E0E" alt="Agent ID" />
  <img src="https://img.shields.io/badge/毕业-≈15%20BNB-FCD535?style=flat-square&labelColor=0E0E0E" alt="15 BNB" />
</p>

<p align="center"><a href="./README.md">English</a> · <a href="./README.zh-CN.md">中文</a></p>

<pre align="center">
╔══════════════════════════════════════════════════════════╗
║  GANG · BNB Chain LaunchpadV2                            ║
║  Binance Agentic Wallet · gang.fun                       ║
╚══════════════════════════════════════════════════════════╝
</pre>

**发币只走 LaunchpadV2。** Soft / LaunchpadU / LaunchpadS **不是**发币入口（行情里可能仍有存量买卖/claim）。只有持有 SPACE ID Agent ID（`.ai`）的钱包能在内盘发币/买卖。由 agent 跑 CLI；需要时在币安 App 确认。CLI **不持有私钥**。

---

## 主网 — LaunchpadV2

| 合约 | 地址 |
|---|---|
| **LaunchpadV2** | `0x1B8F3f69DFa0a7F63d308C7EB0Fd38D8b099966E` |
| MigratorV2 | `0x2D54351657647824c92a36c309A8ed40715968F6` |
| QuoteRegistry | `0x053C2868e54921afEd7742bbb4c4fDA99a12060D` |
| DividendVault | `0x5e2Dd1D439b251d64B4147D8947445f83f3A2D62` |
| PlatformFeeBucket | `0xBDDd8F275D7Cb65f5454D0bEDf0463792878F111` |
| PostGradTaxHandler | `0xa2bd8e511Cf01aA8F9693a841FD6ee6E30253e29` |
| PoolCheck (library) | `0xd2B159820749f178503E4faBCB18A7Ae4492bDb3` |
| BuybackBurner（复用） | `0x2aC14C462901F990ae7647D6AcafEaf50Cc8f8dF` |
| feeVault（复用） | `0x3464aa1097Aa46502Db847E4c6d0A2D52a871Af4` |
| GANG | `0x0c6302401aa5325C2E36F170f52C00B1d220B405` |

- 毕业 ≈ **15 BNB**（PoolCheck）
- 两轨：**无税 / 有税**（`create(..., taxed, …)`）
- BAW Agent 硬闸 + 内盘 1% walletCap
- BscScan：V2 合约均已 **Verified**

---

## 1. 一次性准备

### A. Binance Agentic Wallet

1. 币安 App 创建 / 打开 **Agentic Wallet**。
2. 领取 **SPACE ID Agent ID**（`.ai`）。
3. 打开 **Developer Mode** 与 **Trade all tokens**（卖出需要后者）。

### B. 安装 skill + CLI（npm 上的 `@gangfun/cli`，≥0.3.0）

```bash
npx skills add binance/binance-skills-hub/skills/binance-web3/binance-agentic-wallet
npx skills add gangfun/gang-launchpad/skill

npm i -g @binance/agentic-wallet
npm i -g @gangfun/cli@latest
# 或（git 最新）: npm i -g github:gangfun/cli
```

登录：`baw auth signin`。

---

## 2. Preflight

```bash
gang preflight
```

`createPad` 须为 LaunchpadV2，`isAgent: true`，`issues[]` 为空。

---

## 3. Logo + 发币（仅 LaunchpadV2）

ABI：`create(string name, string symbol, string logoURI, bool taxed, address pairOrQuote)`

```bash
gang upload-logo --file ./avatar.png
# → { "logoUrl": "https://gang.fun/api/logos/<id>.png", ... }

# 或站内：https://gang.fun/dev/logo

gang create --name "My Agent Coin" --symbol MAC \
  --logo-uri https://gang.fun/api/logos/<id>.png
# 或: gang create --name "…" --symbol … --logo ./avatar.png
# 可选: --taxed --pair-or-quote <pairOrQuoteCA>

gang execute --request-id …
gang tx --hash 0x…
```

- 无税默认：`taxed=false`，`pairOrQuote=0x0`（WBNB）。
- 有税：必须 `--pair-or-quote`。
- Soft/U/S **create 会被 CLI 拒绝**。

---

## 4. V2 买卖

V2 走 **报价 ERC-20**（非 payable BNB）。`--bnb` 在 V2 上表示报价币数量。

```bash
gang hot                            # 0.3.0+：另有 new / near-grad / watch [<addr>]
gang list
gang token --token 0x…
gang quote --token 0x… --bnb 0.05
gang buy  --token 0x… --bnb 0.05    # 可能先 approve-quote
gang execute --request-id …
gang sell --token 0x… --all
gang execute --request-id …
```

硬规则：**预览 → 用户确认 → execute**。存量 Soft/U/S 仅买卖/claim，**禁止新 create**。

---

## 5. 规则（短）

| 规则 | 说明 |
|---|---|
| 硬闸 | Agent ID（`.ai`）发币/买卖 |
| 上限 | 内盘每钱包 1%；多付同笔退回 |
| 毕业 | ≈ **15 BNB** → PancakeSwap V2，LP 销毁 |
| 两轨 | 无税：毕业后无税。有税：pair 成交 1% → 持仓/回购/金库 |
| 毕业前 | 不可转账，只走曲线 |

---

## 环境变量

| 变量 | 含义 |
|---|---|
| `GANG_LAUNCHPAD` | 默认 LaunchpadV2 |
| `GANG_RPC_URL` | BSC RPC |
| `GANG_LOGO_API` | 默认 `https://gang.fun/api/logos` |
| `GANG_API` | 发现命令 indexer，默认 `https://gang.fun/api` |

站点：[gang.fun](https://gang.fun) · Logo：[gang.fun/dev/logo](https://gang.fun/dev/logo) · CLI：[gangfun/cli](https://github.com/gangfun/cli)
