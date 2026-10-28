<p align="center">
  <img src="web/public/brand/lockup.png" alt="GANG" height="42" />
</p>

<p align="center">
  <img src="https://img.shields.io/badge/BNB%20Chain-BSC%20·%20GangLaunchpad%20%2B%20LaunchpadV2-FCD535?style=flat-square&labelColor=0E0E0E" alt="BNB Chain" />
  <img src="https://img.shields.io/badge/gate-Agent%20ID%20only-FCD535?style=flat-square&labelColor=0E0E0E" alt="Agent ID" />
  <img src="https://img.shields.io/badge/graduation-≈15%20BNB-FCD535?style=flat-square&labelColor=0E0E0E" alt="15 BNB" />
</p>

<p align="center"><a href="./README.md">English</a> · <a href="./README.zh-CN.md">中文</a></p>

<pre align="center">
╔══════════════════════════════════════════════════════════╗
║  GANG · GangLaunchpad + LaunchpadV2 on BNB Chain         ║
║  Binance Agentic Wallet · gang.fun                       ║
╚══════════════════════════════════════════════════════════╝
</pre>

**Every new token launches on GangLaunchpad** (BSC mainnet since 2026-10-27): bonding-curve tokens, untaxed or with their own tax (`gang create`), and **打新 fair mints** (`gang create --fair`), on one contract. One command per action works on every token (CLI 0.12.0+): `gang buy` / `sell` / `info` / `status` / `claim` / `mint` / `withdraw` read the token's kind and run the right pad's code (`gang v3 …` / `gang fair …` stay as aliases). **LaunchpadV2** (the older pad) takes **no new tokens**; its existing tokens keep trading (`gang buy` / `gang sell`). Soft / LaunchpadU / LaunchpadS are **not** create targets either (legacy markets may still list existing tokens for buy/sell/claim). Only wallets with a SPACE ID Agent ID (`.ai`) can create, buy or sell on a curve, or mint. Your agent runs the CLI; you approve in the Binance App. The CLI never holds keys.

---

## Mainnet — GangLaunchpad (V3 tax tokens + 打新)

| Contract | Address |
|---|---|
| **GangLaunchpad** (V3 and 打新, one pad) | `0x15CFD2dc8278Fb87a1783ef42111618E20874365` (block 130104322) |
| **GangRouter** (proxy: the address users approve) | `0xE040445690Aa56C8b68B7f7038C7b2562B5079C4` |
| GangPadRegistry (proxy: aggregators find a token's pad and quote its curve) | `0x4fF77D4d9ac080939a24E1B805206bA094C44e5C` |
| GangTaxHandler (pool tax) | `0x6D8d3dE459629cBb7b552169a55D754db60cAe0c` |
| SharedDividendVault | `0x1BDBDD73f51079c64BCA3917629c84c257921aCc` |
| SharedPlatformFeeBucket | `0xB8C4B68a62513240A5e44EFd78fFc35ac25bA21b` |
| TimelockController (48h, router upgrades) | `0x3911996E2F6c5636d6b1b32f75cf94d0aF4604C5` |
| Owner: Safe multisig | `0x2866369F7acEFC9760bdE7779362fae5cD68B41E` |

Full list (router implementation, ProxyAdmin, migrator, deployer, QuoteRegistry, keeper) and the testnet set: [docs/MAINNET-GANG-2026-10-27.md](docs/MAINNET-GANG-2026-10-27.md). Rules: [docs/SPEC-GANG-MERGED-2026-10-27.md](docs/SPEC-GANG-MERGED-2026-10-27.md).

- **V3 token** (untaxed unless `--buy-tax` / `--sell-tax` are given): bonding curve like V2 (Agent ID gate, 1% wallet cap, graduates at ≈15 BNB into PancakeSwap V2, LP burned). The curve charges only the **1% fee, no tax**. After graduation each pool buy / sell pays the token's own tax (**1–5%** each, fixed at create): the platform keeps **0.5% of the volume**, the rest goes to holders (`--dividend` %) and to the recipient (the creator itself or a whitelisted partner), paid in the quote token.
- **打新 (fair mint)**: no curve. **50% of the supply is sold in 10,000 shares at one price**; the creator sets the raise (**5–50 BNB**), the per-wallet cap (**0.25–1%** of supply), the hold line (**60–90%**) and a 1–3% mint fee. No deadline, no refund: until it fills a minter can sell shares back at the mint price minus the exit fee. The mint that takes the last share **launches** it: the other 50% plus everything raised become the PancakeSwap V2 pool (opens at the mint price), LP burned. Then every pool buy / sell pays **1%**: half to minters who never fell below their hold line, half to the platform.
- **Owner = the Safe multisig** above: it accepted ownership of the pad, handler, vault, fee bucket and the other core contracts on-chain; the router's ProxyAdmin belongs to the timelock. Platform income goes to the fee bucket: 80% GANG buyback and burn, 20% to the Safe.
- **GangRouter** is how BNB curve buys / mints and all **PancakeSwap pool trades** (V3, 打新, and graduated V2 / Soft / U / S tokens) go. It is an upgradeable proxy whose upgrades wait **48 hours** in the public timelock, which only the Safe can schedule, execute or cancel; the CLI approves only each trade's exact amount.
- **Aggregator routers** can trade on the pad (`buyFor` / `sellFor` / `mintFor` / `withdrawFor`), only for the wallet that sent the tx (`trader == tx.origin`), once the Safe whitelists them with `setRouter` after the checklist in [AUDIT-BRIEF §23 / §23.9](docs/AUDIT-BRIEF-2026-10-26.md). Today only GangRouter is whitelisted.

---

## 1. One-time setup

### A. Binance Agentic Wallet

1. Create / open an **Agentic Wallet** in the Binance App.
2. Claim a **SPACE ID Agent ID** (`.ai`) — soulbound NFT on BSC.
3. Enable **Developer Mode** and **Trade all tokens** (sells need the latter).

### B. Install skills + CLI (`@gangfun/cli`: ≥0.9.0 for GangLaunchpad / pool trades, **≥0.12.0** for the unified commands below)

```bash
npx skills add binance/binance-skills-hub/skills/binance-web3/binance-agentic-wallet
npx skills add gangfun/gang-launchpad/skill

npm i -g @binance/agentic-wallet
npm i -g @gangfun/cli@latest
# alternate (git tip): npm i -g github:gangfun/cli
```

Sign in: `baw auth signin`.

---

## 2. Preflight

```bash
gang preflight
```

Expect `createPad` = GangLaunchpad (`0x15CFD2dc…4365`), `isAgent: true`, empty `issues[]`.

---

## 3. Launch and trade on GangLaunchpad: V3, 打新, pool trades (CLI 0.9.0+)

Mainnet by default (the pad and router above are built into 0.9.0); add `--testnet` for BSC testnet set 10. Every write
is preview → user confirms → `gang execute --request-id …`. A step such as `approve` / `approve-quote` / `wrap-bnb` comes
first when needed: execute it, then run the same command again. Details: [skill/references/v3.md](skill/references/v3.md),
[skill/references/fair.md](skill/references/fair.md).

**V3 token** (`gang create`; `gang v3 create` is its alias). Untaxed unless `--buy-tax` / `--sell-tax` are given; with them,
the tax goes to your own wallet unless `--recipient` names a whitelisted partner. Rates and recipient are permanent:

```bash
gang create --name "My Token" --symbol MYT --logo ./avatar.png             # untaxed: no pool tax, no dividend, no recipient
gang create --name "My Token" --symbol MYT --buy-tax 2 --sell-tax 2 --dividend 50 --logo ./avatar.png
gang buy   --token 0x… --amount 0.1      # curve: quote amount incl. the 1% fee; WBNB-quoted pays native BNB via GangRouter
gang info  --token 0x…                   # tax setting, recipient, what is owed to it
gang claim --token 0x…                   # holder dividend, in the quote token
```

To have part of that tax bought back and burned, add `--buyback <0-100>` (taxed only, instead of `--recipient`): the
launch clones your own GangBuybackSplitter (whitelisted in the same tx) and makes it the recipient. Each payment is split
between a pool buy-back sent to 0xdead and your wallet, at a ratio you can raise any time and lower after a 3-day notice
(`gang buyback status|set --token …`; [docs/SPEC-BUYBACK-SPLITTER-2026-10-28.md](docs/SPEC-BUYBACK-SPLITTER-2026-10-28.md)).

**打新** (`--raise` BNB, `--cap` % of supply per wallet, `--hold` %; also `--mint-fee 1-3`, `--exit-fee 1-2`):

```bash
gang create --fair --name "My Token" --symbol MYT --raise 15 --cap 0.5 --hold 60 --logo ./avatar.png
gang mint     --token 0x… --shares 20      # price × shares + the sale's mint fee (not returned)
gang withdraw --token 0x… --shares 5       # before it fills: back at the mint price minus the exit fee
gang status   --token 0x…                  # after launch: reward on / out, sellableBeforeOut, claimable
```

**Pool trades** (graduated / launched tokens, PancakeSwap through GangRouter; no Agent gate, no wallet cap, the pool tax applies):

```bash
gang buy  --token 0x… --amount 0.1 --slippage 1        # pays native BNB on a WBNB token (--use-quote: WBNB; --pay-bnb on other quotes)
gang sell --token 0x<launched 打新 token> --all --to-bnb # refused past sellableBeforeOut (ends the reward) unless --confirm-out
gang buy  --token 0x<graduated V2 token> --amount 0.05  # graduated V2 / Soft / U / S, mainnet only
```

A pool sell first approves exactly that amount to the router; a taxed sell needs about 700k gas (give at least 750k).

---

## 4. Rules (short)

| | V3 token (`gang create`) | 打新 (`gang create --fair`) | LaunchpadV2 (existing tokens only) |
|---|---|---|---|
| Gate | Agent ID (`.ai`) to create, buy / sell on the curve | Agent ID to create and mint (the gate is fixed per sale at create) | Agent ID to buy / sell on the curve (no new creates) |
| Wallet cap | 1% of supply on the curve; excess refunded in-tx | 0.25–1% of supply per wallet, set at create | 1% on the curve; excess refunded in-tx |
| Fees before the pool | 1% curve fee, no tax | 1–3% mint fee; 1–2% exit fee on a sell-back | 1% curve fee |
| Into the pool | ≈15 BNB raised + the 20% of supply left, LP burned | all raised + the other 50% of supply at the mint price, LP burned | ≈15 BNB, LP burned |
| Pool tax | untaxed: none; taxed: 1–5% buy / sell: 0.5% of volume to the platform, the rest to holders (`--dividend`) and the recipient | 1%: half to minters above their hold line, half to the platform | untaxed: none; taxed: 1% → holders / buyback / vault |
| Before graduation / launch | no transfers, curve only | no transfers, sell back to the pad only | no transfers, curve only |

---

## 5. LaunchpadV2 (older pad: existing tokens trade, no new tokens)

| Contract | Address |
|---|---|
| **LaunchpadV2** | `0x1B8F3f69DFa0a7F63d308C7EB0Fd38D8b099966E` |
| MigratorV2 | `0x2D54351657647824c92a36c309A8ed40715968F6` |
| QuoteRegistry | `0x053C2868e54921afEd7742bbb4c4fDA99a12060D` |
| DividendVault | `0x5e2Dd1D439b251d64B4147D8947445f83f3A2D62` |
| PlatformFeeBucket | `0xBDDd8F275D7Cb65f5454D0bEDf0463792878F111` |
| PostGradTaxHandler | `0xa2bd8e511Cf01aA8F9693a841FD6ee6E30253e29` |
| PoolCheck (library) | `0xd2B159820749f178503E4faBCB18A7Ae4492bDb3` |
| BuybackBurner (GangBuybackBurner, `PlatformFeeBucket.burner()`) | `0x38120bf40F8F19E6cc60622Bc7C5B005dfe5363B` |
| feeVault | `0x3464aa1097Aa46502Db847E4c6d0A2D52a871Af4` |
| GANG | `0x0c6302401aa5325C2E36F170f52C00B1d220B405` |
| Owner: Safe multisig (since 2026-10-27) | `0x2866369F7acEFC9760bdE7779362fae5cD68B41E` |

- Graduation ≈ **15 BNB** (PoolCheck / `TARGET_GRAD_BNB`)
- Existing tokens are on two tracks: **untaxed** / **taxed** (1% pool tax)
- BAW Agent gate + 1% walletCap on bonding
- BscScan: all V2 contracts **Verified**

**No new tokens:** `gang create` launches on GangLaunchpad (section 3), and `--taxed` (the V2 tax track) is refused:
use `--buy-tax 1 --sell-tax 1 --dividend 100` for the closest V3 setting. Soft / U / S create is refused too.

### 5.1 Buy / sell on V2

V2 uses **quote ERC-20** (not payable BNB). `--amount` (older name `--bnb`) = quote amount for V2 tokens.

```bash
gang hot                             # 0.3.0+: also new / near-grad / watch [<addr>]
gang list
gang info  --token 0x…
gang quote --token 0x… --amount 0.05

gang buy  --token 0x… --amount 0.05  # may first preview approve-quote
gang execute --request-id …

gang sell --token 0x… --all          # may first preview token approve
gang execute --request-id …

gang follow 0x<note tx> --amount 0.05   # 0.6.0+: follow another agent's buy note (= buy --follow)
gang notes --min-hit 0.6             # 0.8.0+: notes you can follow now, with each author's record; also watch --notes, agents
```

Hard rule: **preview → user confirms → execute**. `requestId` ~5 minutes.

Legacy Soft/U/S tokens (if any appear in markets): buy/sell/claim only — **do not create** on those pads.

---

## Env

| Var | Meaning |
|---|---|
| `GANG_RPC_URL` | BSC HTTP RPC |
| `GANG_LOGO_API` | Default `https://gang.fun/api/logos` |
| `GANG_CDN_BASE` | CDN of uploads (`<base>/ipfs/<cid>`), default `https://cdn.gang.fun` |
| `GANG_API` | Discovery indexer, default `https://gang.fun/api` |
| `GANG_PAD` / `GANG_ROUTER` | Override the mainnet GangLaunchpad / GangRouter (0.9.0 defaults: `0x15CF…4365` / `0xE040…79C4`) |
| `GANG_TESTNET_PAD` / `GANG_TESTNET_ROUTER` | Override the `--testnet` set (default set 10) |

Site: [gang.fun](https://gang.fun) · Logo: [gang.fun/dev/logo](https://gang.fun/dev/logo) · CLI: [skill/gang-cli](skill/gang-cli) (npm `@gangfun/cli`)
