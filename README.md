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
║  GANG · BNB Chain launchpad · bonding + Gang Pair         ║
║  Trade with Binance Agentic Wallet · gang.fun            ║
╚══════════════════════════════════════════════════════════╝
</pre>

**New creates use LaunchpadV2** on BSC mainnet. Soft Launchpad, LaunchpadU, and LaunchpadS remain deployed; create on those contracts is archived. **Bonding-curve buys and sells are BAW Agent** (SPACE ID Agent ID, `.ai`). Claim the ID from a Binance Agentic Wallet. Your agent runs the CLI; you approve in the Binance App when asked. The CLI never holds keys. **walletCap is on** (1% of supply per wallet on the curve).

**Soft launch · not audited.** Live on BSC mainnet (chainId 56) at [gang.fun](https://gang.fun). Do not describe these contracts as audited. Chapel (chainId 97) is not this deployment. LaunchpadV2 addresses and startBlock `129311617`: [docs/MAINNET-LAUNCHPAD-V2-ADDRESSES-2026-10-23.md](./docs/MAINNET-LAUNCHPAD-V2-ADDRESSES-2026-10-23.md).

| Rail | Address | Graduation |
|---|---|---|
| LaunchpadV2 (create) | [`0x1B8F3f69DFa0a7F63d308C7EB0Fd38D8b099966E`](https://bscscan.com/address/0x1B8F3f69DFa0a7F63d308C7EB0Fd38D8b099966E) | ≈ **15 BNB** equivalent, locked at create |
| Soft Launchpad (BNB) | [`0x315Ba2e8952D06094CC636b2B84229FA32fb23A7`](https://bscscan.com/address/0x315Ba2e8952D06094CC636b2B84229FA32fb23A7) | **20 BNB** · create archived |
| GANG (platform token) | [`0x0c6302401aa5325C2E36F170f52C00B1d220B405`](https://bscscan.com/address/0x0c6302401aa5325C2E36F170f52C00B1d220B405) | — |
| LaunchpadU | [`0x245a42cE8337DECe0f1C04f8430C90C8D98b88e4`](https://bscscan.com/address/0x245a42cE8337DECe0f1C04f8430C90C8D98b88e4) | spot Grad15 ≈ **15 BNB** equivalent · create archived |
| LaunchpadS | [`0x80C5e29417f8037A9e4CC5320878386826732e89`](https://bscscan.com/address/0x80C5e29417f8037A9e4CC5320878386826732e89) | spot Grad15 ≈ **15 BNB** equivalent · create archived |

On U/S, `virtualQuote = floor(gradAmt / 3)`. QuoteRegistry is a whitelist. `graduationQuoteAmount` of **0** means spot Grad15; a positive override locks that quote amount instead. Post-grad **1%** tax accumulates until a keeper calls `process()` (~0.3% DEX). The transfer hook must not swap. Buybacks burn **GANG**.

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

- New creates go to **LaunchpadV2**. Soft / U / S create is archived; those contracts remain. Addresses: [docs/MAINNET-LAUNCHPAD-V2-ADDRESSES-2026-10-23.md](./docs/MAINNET-LAUNCHPAD-V2-ADDRESSES-2026-10-23.md).
- Archived Soft create was **BAW Dev** (`isDev` / owner `setDev`). Creation fee is 0. Bonding buys and sells require an Agent ID.

### Graduated tokens

- If a command says `graduated: true`, the curve is closed — trade on **PancakeSwap V2** with the reported `pair`.
- Untaxed BNB main track: platform fee is 0 after graduation.
- Taxed Gang Pair (LaunchpadU / LaunchpadS): post-grad **1%** tax accumulates. A keeper calls `process()` to sell it (~0.3% DEX) into dividends and the platform bucket. The transfer hook must not swap. Buybacks burn **GANG**.

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
| Chain | BSC **mainnet** (chainId 56) · [gang.fun](https://gang.fun) · **not audited** |
| Who can create | **BAW Dev** only (`isDev` / `setDev`) |
| Who can buy / sell (bonding) | **BAW Agent** only (Agent ID) |
| After graduation | Anyone can trade the Pancake pair. Taxed tokens still pay the outer tax. |
| Cap | **walletCap ON** · 1% of supply per wallet on the curve (`10_000_000` tokens) |
| Supply | 1e9 fixed · 800M on the curve · 200M to LP |
| Untaxed fee | Bonding **1%** → **80%** buyback-and-burn GANG · **20%** treasury (`feeVault`) |
| Taxed fee | Bonding **and** outer **1%** → **50%** dividends (holder share ≥ `TAXED_MIN_SHARE` = 1,000,000 tokens) · the other **50%** splits **80/20** buyback / treasury |
| BNB main track | Graduates at **20 BNB** · LP to `0x…dEaD` · transfers unlock · platform fee 0 after graduation |
| LaunchpadU / LaunchpadS | Spot Grad15 ≈ **15 BNB** equivalent, locked at create · `virtualQuote = floor(gradAmt / 3)` · QuoteRegistry whitelist · `graduationQuoteAmount` **0** = spot Grad15 |
| PostGrad | **1%** tax accumulates · keeper `process()` (~0.3% DEX) · transfer hook must **not** swap · platform token **GANG** |
| Transfers | Locked until graduation |
| Buyback | Quote → GANG, burned to `0x…dEaD`. Smart Router path is exact-input (`collectPlatformSmart`). `minGangOut` comes from off-chain. |

## Appendix B · Soft Launchpad, BNB main track (BSC mainnet)

Live soft-launch addresses. **Not audited.** The `Launchpad` source in this repo is the soft-launch pack (Dev allowlist, Agent bonding sell, one-shot `setPlatformToken`). Read `0x315B…` on BscScan for the bytecode that is actually deployed. LaunchpadU / LaunchpadS are in Appendix C.

| Contract | Deploy block | Address |
|---|---|---|
| Launchpad v4.1 (deployed BNB curve) | **128977029** | [`0x315Ba2e8952D06094CC636b2B84229FA32fb23A7`](https://bscscan.com/address/0x315Ba2e8952D06094CC636b2B84229FA32fb23A7) |
| Migrator v4.1 | **128977029** | [`0xFcB6278b6FE3f2e3F567bb49cBf8d8883bcE96E9`](https://bscscan.com/address/0xFcB6278b6FE3f2e3F567bb49cBf8d8883bcE96E9) |
| Platform token (GANG) | **128977029** | [`0x0c6302401aa5325C2E36F170f52C00B1d220B405`](https://bscscan.com/address/0x0c6302401aa5325C2E36F170f52C00B1d220B405) |
| Agent ID (SPACE ID) | — | [`0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F`](https://bscscan.com/address/0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F) |
| feeVault / ops treasury | — | `0x3464aa1097Aa46502Db847E4c6d0A2D52a871Af4` |
| Pancake V2 Router | — | `0x10ED43C718714eb63d5aA57B78B54704E256024E` |

## Appendix C · OPT5C on BSC mainnet (chainId 56)

Broadcast 2026-10-23. **Soft launch, not audited.** Site: [gang.fun](https://gang.fun). These are mainnet addresses. Chapel (chainId 97) is not this deployment, and those testnet addresses are not listed here. `script/DeployMainnetDraft.s.sol` in this repo still reverts and is not the broadcast that produced the addresses below.

`agentGateEnabled` and `walletCapEnabled` are both true on LaunchpadU and LaunchpadS. BuybackBurner `gang` is GANG. BuybackBurner `smartRouter` is the Pancake Smart Router.

### Shared (already on mainnet)

| | Address |
|---|---|
| Soft Launchpad | [`0x315Ba2e8952D06094CC636b2B84229FA32fb23A7`](https://bscscan.com/address/0x315Ba2e8952D06094CC636b2B84229FA32fb23A7) |
| GANG | [`0x0c6302401aa5325C2E36F170f52C00B1d220B405`](https://bscscan.com/address/0x0c6302401aa5325C2E36F170f52C00B1d220B405) |
| feeVault | `0x3464aa1097Aa46502Db847E4c6d0A2D52a871Af4` |
| Keeper | `0xB6f1F1BFb92476Abb0998B425dE0deC5F927cFc7` |
| AgentIdRegistry | [`0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F`](https://bscscan.com/address/0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F) |
| Pancake V2 Router | `0x10ED43C718714eb63d5aA57B78B54704E256024E` |
| Pancake Smart Router | `0x13f4EA83D0bd40E75C8222255bc855a974568Dd4` |
| WBNB | `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c` |
| Deployer | `0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3` |

### LaunchpadU

| | Address |
|---|---|
| LaunchpadU | [`0x245a42cE8337DECe0f1C04f8430C90C8D98b88e4`](https://bscscan.com/address/0x245a42cE8337DECe0f1C04f8430C90C8D98b88e4) |
| QuoteRegistry | `0x1a90B418023933A5D162Ab96b7adB3864B201e05` |
| DividendVault | `0x1D9a511cd15FDcD2Fad24512D74b38C2cE02b2DF` |
| PlatformFeeBucket | `0xdEd4D0022879ad1268C754a49F7aDF1bD130b18C` |
| PostGradTaxHandler | `0xb8714dF76Bea4AeE2F961daBFc3a0584B057D855` |
| BuybackBurner | `0xc2bffC6a87eA6ae07180A7Ab05aE6406B255d81F` |
| MigratorS | `0xCE065aa82d4d387d1491d5046600b764c39b05CA` |

### LaunchpadS

| | Address |
|---|---|
| LaunchpadS | [`0x80C5e29417f8037A9e4CC5320878386826732e89`](https://bscscan.com/address/0x80C5e29417f8037A9e4CC5320878386826732e89) |
| QuoteRegistry | `0xa7aed928eca3E437A57b4018C7a19B81b79b1bc7` |
| DividendVault | `0x20b5e893447623AC893f4Fb86A51930A588402Aa` |
| PlatformFeeBucket | `0x30a49540b06476c4089097869B3920ea47C1537e` |
| PostGradTaxHandler | `0x35ea5f0d80A8bd91a7Ea39FeCD746aACA76957EA` |
| BuybackBurner | `0xceA0C99522Dc26Cb64609aA758DE6671281D8D6D` |
| MigratorS | `0x4f2A02a56f9e1AB2E9b4469569C9D1E724C1dcDb` |

- Soft track graduates at **20 BNB**. U/S lock spot Grad15 (≈ **15 BNB** equivalent) at create. `virtualQuote = floor(gradAmt / 3)`.
- QuoteRegistry is a whitelist. `graduationQuoteAmount == 0` locks spot Grad15. A value **> 0** locks that `gradAmt` and skips the V2 spot read.
- Create is **BAW Dev**. Bonding buy/sell is **BAW Agent**. **walletCap is on.**
- `LaunchpadS` PostGrad matches taxed `LaunchpadU`: inner and outer **1%**. The **1%** accumulates; a keeper calls `process()` to sell through the router (~0.3% DEX). The transfer hook must not swap. Platform token is **GANG**.
- Stuck-quote flush is two steps: `requestFlush`, then after **7 days** `flushStuckQuoteToTreasury`. A successful `collectPlatform` / `collectPlatformSmart` clears the request.
- Smart Router buyback: `collectPlatformSmart` → `buybackAndBurnSmart`. The quote spend must be exact-input (`balance == before - amountIn`) or the call reverts `IncompleteQuoteSpend`.
- `TAXED_MIN_SHARE = 1_000_000 ether` (1,000,000 tokens).
- `LaunchpadU` / `LaunchpadS` and the fee contracts use **Ownable2Step**.

## Appendix D · LaunchpadV2 on BSC mainnet (chainId 56)

Broadcast 2026-10-23. **Not audited.** New creates use LaunchpadV2. Soft Launchpad, LaunchpadU, and LaunchpadS remain deployed; create on those contracts is archived. startBlock **129311617**. Source: `src/launchpad-v2/` (PoolCheck is a public library). Delta vs Soft/U/S: [docs/launchpad-v2/DIFF-VS-LIVE.md](./docs/launchpad-v2/DIFF-VS-LIVE.md). Full table: [docs/MAINNET-LAUNCHPAD-V2-ADDRESSES-2026-10-23.md](./docs/MAINNET-LAUNCHPAD-V2-ADDRESSES-2026-10-23.md).

| Contract | Address |
|---|---|
| LaunchpadV2 | [`0x1B8F3f69DFa0a7F63d308C7EB0Fd38D8b099966E`](https://bscscan.com/address/0x1B8F3f69DFa0a7F63d308C7EB0Fd38D8b099966E) |
| MigratorV2 | [`0x2D54351657647824c92a36c309A8ed40715968F6`](https://bscscan.com/address/0x2D54351657647824c92a36c309A8ed40715968F6) |
| QuoteRegistry | `0x053C2868e54921afEd7742bbb4c4fDA99a12060D` |
| DividendVault | `0x5e2Dd1D439b251d64B4147D8947445f83f3A2D62` |
| PlatformFeeBucket | `0xBDDd8F275D7Cb65f5454D0bEDf0463792878F111` |
| PostGradTaxHandler | `0xa2bd8e511Cf01aA8F9693a841FD6ee6E30253e29` |
| PoolCheck (library) | `0xd2B159820749f178503E4faBCB18A7Ae4492bDb3` |

Reused: BuybackBurner `0x2aC14C462901F990ae7647D6AcafEaf50Cc8f8dF`, feeVault `0x3464aa1097Aa46502Db847E4c6d0A2D52a871Af4`, GANG `0x0c6302401aa5325C2E36F170f52C00B1d220B405`.

