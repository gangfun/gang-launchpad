<p align="center">
  <img src="web/public/brand/lockup.png" alt="GANG" height="42" />
</p>

<p align="center">
  <img src="https://img.shields.io/badge/BNB%20Chain-BSC%20·%20v4.1-FCD535?style=flat-square&labelColor=0E0E0E" alt="BNB Chain" />
  <img src="https://img.shields.io/badge/gate-Agent%20ID%20only-FCD535?style=flat-square&labelColor=0E0E0E" alt="Agent ID" />
</p>

<p align="center"><a href="./README.md">English</a> · <a href="./README.zh-CN.md">中文</a></p>

<pre align="center">
╔══════════════════════════════════════════════════════════╗
║  GANG · agent-only launchpad on BNB Chain                ║
║  Trade with Binance Agentic Wallet · gang.fun            ║
╚══════════════════════════════════════════════════════════╝
</pre>

**Only wallets holding a SPACE ID Agent ID (`.ai`) can buy on the curve.** Claim the ID from a Binance Agentic Wallet. Your agent runs the CLI; you approve in the Binance App when asked. The CLI never holds keys.

---

## 1. One-time setup

### A. Binance Agentic Wallet

1. Create / open an **Agentic Wallet** in the Binance App.
2. Claim a **SPACE ID Agent ID** (`.ai` name) from the Agent ID banner — soulbound NFT on BSC; this is what the contract checks.
3. In the App, turn on:
   - **Developer Mode** — required for any contract call (`buy` / `sell` / `create`). Has its own daily limit and expiry.
   - **Trade all tokens** — required to **sell**. Without it, buys can work but sells are blocked (risk code `351803`).

### B. Install skills (for your agent)

```bash
# 1) Binance Agentic Wallet skill (sign-in, signing, risk engine)
npx skills add binance/binance-skills-hub/skills/binance-web3/binance-agentic-wallet

# 2) Gang skill
npx skills add gangfun/gang-launchpad/skill

# 3) Install Gang CLI (public npm)
npm i -g @gangfun/cli          # or pin: npm i -g @gangfun/cli@0.1.4
# provides: gang · https://www.npmjs.com/package/@gangfun/cli
# backup: npm i -g github:gangfun/cli
```

Sign in once with `baw` (open the App pairing URL / code when prompted).

---

## 2. Every session: preflight first

```bash
gang preflight
```

Expect `status: CONNECTED`, `isAgent: true`, `devMode: true`, `tradeAllTokens: true`, empty `issues[]`.

| If you see… | Fix in Binance App / baw |
|---|---|
| not signed in | `baw auth signin` → scan / enter pairing code → `baw auth verify` |
| no Agent ID | Claim `.ai` Agent ID from the Agentic Wallet banner |
| Developer Mode off | Enable Developer Mode (needed for all Gang txs) |
| Trade all tokens off | Enable it before any **sell** |

Relay each `issues[].fix` to the user as written. Preflight never spends gas.

---

## 3. Trade flow (preview → confirm → execute)

Hard rule: **`buy` / `sell` / `create` only preview.** Show the user the quote / risks / fee / refund, wait for an explicit yes, then `gang execute`. A `requestId` expires in ~5 minutes.

```bash
gang list                                    # boards: price, progress, your balance
gang token  --token 0x…                      # one token + graduation progress
gang quote  --token 0x… --bnb 0.05           # exact on-chain quote (fee, cap, refund)

gang buy    --token 0x… --bnb 0.05           # preview → requestId
gang execute --request-id <id>               # broadcast after user says yes

gang sell   --token 0x… --all                # preview (may need token approve first)
gang execute --request-id <id>

gang create --name "My Agent Coin" --symbol MAC
gang execute --request-id <id>

gang tx     --hash 0x…                       # what landed on-chain
```

### Buys

- Need Agent ID + Developer Mode.
- Usually **no** in-App confirm after execute.
- If quote shows a `refund`, you hit the **1% per-wallet cap** (10,000,000 tokens); excess BNB returns in the same tx.

### Sells

- Need **Trade all tokens**.
- After `execute`, Binance may return `pendingConfirmation: true` → **open the Binance App and approve**. Do not re-run `execute`. Poll history / then `gang tx --hash …`.
- Confirmations expire in a few minutes; if expired, preview again.

### Create

- Anyone can create (0 creation fee). Only Agent ID holders can buy on the curve afterward.

### Graduated tokens

- If a command says `graduated: true`, the curve is closed — trade on **PancakeSwap V2** with the reported `pair`. Platform fee is 0 after graduation.

---

## 4. Plain-language cheatsheet for agents

| User says | You run |
|---|---|
| “Am I ready for Gang?” | `gang preflight` |
| “What’s hot / list tokens” | `gang list` |
| “How much does 0.05 BNB buy?” | `gang quote --token … --bnb 0.05` |
| “Buy 0.05 BNB of 0x…” | `gang buy` → show preview → wait for yes → `gang execute` |
| “Sell all of 0x…” | `gang sell --all` → confirm → `execute` → maybe App approve |
| “Launch a coin” | `gang create` → confirm → `execute` |

Always speak amounts in BNB / tokens, never raw wei. Show full addresses; confirm before buying.

---


## Ops · fee keeper (VPS)

Permissionless daily settle: `scripts/keeper-collectfees.sh` (default dry-run).

- Keeper address: `0xb6f1f1bfb92476abb0998b425de0dec5f927cfc7` (gas only; fund ≥0.05 BNB)
- Key **only** on VPS: `/opt/gang/keeper/.env` → `KEEPER_PRIVATE_KEY=` (never commit)
- Cron example (Asia/Shanghai 10:00): `0 10 * * * /opt/gang/keeper/keeper-collectfees.sh --broadcast --log-dir /opt/gang/keeper/logs`
- Skips when `accruedFees==0`; refuses auto-broadcast if accrued > 0.2 BNB (override `--max-accrued`)

## Appendix A · Rules (minimal)

| | |
|---|---|
| Who can buy (curve) | Agent ID holders only (`balanceOf` on-chain) |
| Who can sell | Any holder |
| Cap | 1% of supply per wallet |
| Fee | 1% on curve buy/sell; **80%** auto-buyback+burn platform token, **20%** ops treasury; **0 after graduation** |
| Supply | 1e9 fixed · 800M on curve · 200M to LP |
| Graduate | Real reserves hit **20 BNB** → Pancake V2 · LP → `0x…dEaD` · transfers unlock |
| Transfers | Locked until graduation |


## Appendix B · Contracts (BSC · v4.1 current)

| Contract | Deploy block | Address |
|---|---|---|
| Launchpad **v4.1** (current) | **128977029** | [`0x315Ba2e8952D06094CC636b2B84229FA32fb23A7`](https://bscscan.com/address/0x315Ba2e8952D06094CC636b2B84229FA32fb23A7) |
| Migrator v4.1 | **128977029** | [`0xFcB6278b6FE3f2e3F567bb49cBf8d8883bcE96E9`](https://bscscan.com/address/0xFcB6278b6FE3f2e3F567bb49cBf8d8883bcE96E9) |
| Platform token (GANG) | **128977029** | [`0x0c6302401aa5325C2E36F170f52C00B1d220B405`](https://bscscan.com/address/0x0c6302401aa5325C2E36F170f52C00B1d220B405) |
| Agent ID (SPACE ID) | — | [`0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F`](https://bscscan.com/address/0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F) |
| feeVault / opsTreasury | — | `0x3464aa1097Aa46502Db847E4c6d0A2D52a871Af4` |
| Pancake V2 Router | — | `0x10ED43C718714eb63d5aA57B78B54704E256024E` |

**Deprecated:** Launchpad v3 [`0xBfBB10db587DdFDF38c888cB80C5124f1Aa3C0Eb`](https://bscscan.com/address/0xBfBB10db587DdFDF38c888cB80C5124f1Aa3C0Eb) · Migrator v3 [`0x4b1E5a7602c7f7964c08364241c1FE59CB4095C8`](https://bscscan.com/address/0x4b1E5a7602c7f7964c08364241c1FE59CB4095C8) (deploy block 128858413). Launchpad **v4** [`0x86854E8ee7D438ca9B52407DCF92D1616385dDcc`](https://bscscan.com/address/0x86854E8ee7D438ca9B52407DCF92D1616385dDcc) · GANG (v4) [`0xDA519ED3Ed0880C96610390467b1A8Eb43f16ab2`](https://bscscan.com/address/0xDA519ED3Ed0880C96610390467b1A8Eb43f16ab2). v1/v2 also retired. Use **live v4.1 only**. Verify on BscScan.

