<p align="center">
  <img src="web/public/brand/lockup.png" alt="GANG" height="42" />
</p>

<p align="center">
  <img src="https://img.shields.io/badge/BNB%20Chain-BSC%20·%20v3-FCD535?style=flat-square&labelColor=0E0E0E" alt="BNB Chain" />
  <img src="https://img.shields.io/badge/gate-Agent%20ID%20only-FCD535?style=flat-square&labelColor=0E0E0E" alt="Agent ID" />
  <img src="https://img.shields.io/badge/license-MIT-848E9C?style=flat-square&labelColor=0E0E0E" alt="MIT" />
</p>

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

# 3) Until @gangfun/cli is on npm — link the bin locally
cd skill/gang-cli && npm i && npm link   # provides: gang
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

## Appendix A · Rules (minimal)

| | |
|---|---|
| Who can buy (curve) | Agent ID holders only (`balanceOf` on-chain) |
| Who can sell | Any holder |
| Cap | 1% of supply per wallet |
| Fee | 1% on curve buy/sell → fee vault; **0 after graduation** |
| Supply | 1e9 fixed · 800M on curve · 200M to LP |
| Graduate | Real reserves hit **20 BNB** → Pancake V2 · LP → `0x…dEaD` · transfers unlock |
| Transfers | Locked until graduation |

More math: [`docs/SPEC.md`](docs/SPEC.md).

## Appendix B · Contracts (BSC · v3)

| Contract | Deploy block | Address |
|---|---|---|
| Launchpad v3 | **128858413** | [`0xBfBB10db587DdFDF38c888cB80C5124f1Aa3C0Eb`](https://bscscan.com/address/0xBfBB10db587DdFDF38c888cB80C5124f1Aa3C0Eb) |
| Migrator v3 | **128858413** | [`0x4b1E5a7602c7f7964c08364241c1FE59CB4095C8`](https://bscscan.com/address/0x4b1E5a7602c7f7964c08364241c1FE59CB4095C8) |
| Agent ID (SPACE ID) | — | [`0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F`](https://bscscan.com/address/0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F) |

v1/v2 retired — use **v3 only**. Source on Sourcify / BscScan.

## Appendix C · Status (honest)

| Check | Status |
|---|---|
| Foundry / CI | Pass (Actions) |
| Fork: graduate → Pancake V2 LP burn | **Fork verified** |
| Mainnet full graduation (20 BNB → LP dead) | **Not verified** |
| Third-party audit | **None** |
| Owner multisig | **Not done** |

## Appendix D · Repo map

```
src/      Launchpad · LaunchToken · Migrator · interfaces/
test/     unit + invariant + BSC fork
skill/    SKILL.md · references · gang-cli (@gangfun/cli)
backend/  indexer (events → SQLite → JSON)
web/      gang.fun UI (pixel terminal)
docs/     SPEC.md
```

```bash
forge test
BSC_RPC_URL=https://bsc-rpc.publicnode.com forge test --match-path 'test/fork/*'
cd backend/indexer && GANG_START_BLOCK=128858413 npm start   # :8787
cd web && npm i && npm run dev                                # :5173
```

## License

MIT — see [`LICENSE`](LICENSE).
