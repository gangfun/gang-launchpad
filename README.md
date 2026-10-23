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
║  GANG · BNB Chain launchpad · bonding + Gang Pair         ║
║  Trade with Binance Agentic Wallet · gang.fun            ║
╚══════════════════════════════════════════════════════════╝
</pre>

**Create is BAW Dev only. Bonding-curve buys and sells require a SPACE ID Agent ID (`.ai`).** Claim the ID from a Binance Agentic Wallet. Your agent runs the CLI; you approve in the Binance App when asked. The CLI never holds keys.

Soft launch on BSC. BNB main track graduates at **20 BNB**. Gang Pair (any-pool) locks `gradAmt` at create — about **15 BNB** equivalent, from an ops override or from spot.

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

# 3) Install Gang CLI (GitHub Packages — not npmjs)
npm i -g @gangfun/cli@0.1.3 --registry=https://npm.pkg.github.com   # provides: gang
# needs GitHub token with read:packages in ~/.npmrc — see cli README
# alternate (no Packages token): npm i -g github:gangfun/cli
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

- **BAW Dev only** (`isDev` / owner `setDev`). Creation fee is 0. Bonding buys and sells after that require an Agent ID.

### Graduated tokens

- If a command says `graduated: true`, the curve is closed — trade on **PancakeSwap V2** with the reported `pair`.
- Untaxed BNB main track: platform fee is 0 after graduation.
- Taxed Gang Pair: pair trades pay an outer **1%**. A keeper calls `process` to settle that tax into dividends and the platform bucket.

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

## Appendix A · Rules (soft launch)

| | |
|---|---|
| Chain | BSC |
| Who can create | **BAW Dev** only (`isDev` / `setDev`) |
| Who can buy / sell (bonding) | **BAW Agent ID** only |
| After graduation | Anyone can trade the Pancake pair. Taxed tokens still pay the outer tax. |
| Cap | 1% of supply per wallet on the curve (`10_000_000` tokens) |
| Supply | 1e9 fixed · 800M on the curve · 200M to LP |
| Untaxed fee | Bonding **1%** → **80%** buyback-and-burn GANG · **20%** treasury (`feeVault`) |
| Taxed fee | Bonding **and** outer **1%** → **50%** dividends (holder share ≥ `TAXED_MIN_SHARE` = 1,000,000 tokens) · the other **50%** splits **80/20** buyback / treasury |
| BNB main track | Graduates at **20 BNB** · LP to `0x…dEaD` · transfers unlock · platform fee 0 after graduation |
| Gang Pair (any-pool) | Create locks `gradAmt` (~**15 BNB** equivalent via ops `graduationQuoteAmount` or spot) · `virtualQuote = floor(gradAmt / 3)` · taxed track also runs PostGrad |
| Transfers | Locked until graduation |
| Buyback | Quote → GANG, burned to `0x…dEaD`. Smart Router path is exact-input (`collectPlatformSmart`). `minGangOut` comes from off-chain. |

## Appendix B · Deployed BNB main track (BSC)

These are the live BNB-curve addresses already published for v4.1. Gang Pair (`LaunchpadU` / `LaunchpadS`) is source in this repo for the soft launch; those pads are not listed here as mainnet deployments. The `Launchpad` source in this repo is the soft-launch pack (Dev allowlist, Agent bonding sell, one-shot `setPlatformToken`). Read `0x315B…` on BscScan for the bytecode that is actually deployed.

| Contract | Deploy block | Address |
|---|---|---|
| Launchpad v4.1 (deployed BNB curve) | **128977029** | [`0x315Ba2e8952D06094CC636b2B84229FA32fb23A7`](https://bscscan.com/address/0x315Ba2e8952D06094CC636b2B84229FA32fb23A7) |
| Migrator v4.1 | **128977029** | [`0xFcB6278b6FE3f2e3F567bb49cBf8d8883bcE96E9`](https://bscscan.com/address/0xFcB6278b6FE3f2e3F567bb49cBf8d8883bcE96E9) |
| Platform token (GANG) | **128977029** | [`0x0c6302401aa5325C2E36F170f52C00B1d220B405`](https://bscscan.com/address/0x0c6302401aa5325C2E36F170f52C00B1d220B405) |
| Agent ID (SPACE ID) | — | [`0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F`](https://bscscan.com/address/0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F) |
| feeVault / ops treasury | — | `0x3464aa1097Aa46502Db847E4c6d0A2D52a871Af4` |
| Pancake V2 Router | — | `0x10ED43C718714eb63d5aA57B78B54704E256024E` |

## Appendix C · OPT5C (short)

Source under `src/stocks/` plus the soft-launch `Launchpad`. `script/DeployMainnetDraft.s.sol` reverts on purpose and does not broadcast.

- Per-curve `virtualQuote = floor(gradAmt / 3)`, locked at create.
- `LaunchpadS` PostGrad: inner and outer **1%**, same split as taxed `LaunchpadU`.
- Ops override: `QuoteRegistry.graduationQuoteAmount > 0` locks that `gradAmt` and skips the V2 spot read.
- Stuck-quote flush is two steps: `requestFlush`, then after **7 days** `flushStuckQuoteToTreasury`. A successful `collectPlatform` / `collectPlatformSmart` clears the request.
- Smart Router buyback: `collectPlatformSmart` → `buybackAndBurnSmart`. The quote spend must be exact-input (`balance == before - amountIn`) or the call reverts `IncompleteQuoteSpend`.
- `TAXED_MIN_SHARE = 1_000_000 ether` (1,000,000 tokens).
- Post-grad pair swap fee model **9975/10000** (Pancake 0.25%). The token transfer hook does not swap.
- `LaunchpadU` / `LaunchpadS` and the fee contracts use **Ownable2Step**.

## Appendix D · Chapel testnet only (chainId 97)

Testnet pads from tip `chapel-opt5c-202610231325`. These are not mainnet addresses.

| | Address |
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

