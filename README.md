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

**Two pads are live on BSC mainnet.** **GangLaunchpad** (new, 2026-10-27) launches **V3 tax tokens** (`gang v3`) and **打新 fair mints** (`gang fair`) on one contract. **LaunchpadV2** (the older pad, still live) is what `gang create` uses. Soft / LaunchpadU / LaunchpadS are **not** create targets (legacy markets may still list existing tokens for buy/sell/claim). Only wallets with a SPACE ID Agent ID (`.ai`) can create, buy or sell on a curve, or mint. Your agent runs the CLI; you approve in the Binance App. The CLI never holds keys.

---

## Mainnet — GangLaunchpad (V3 tax tokens + 打新)

| Contract | Address |
|---|---|
| **GangLaunchpad** (V3 and 打新, one pad) | `0x15CFD2dc8278Fb87a1783ef42111618E20874365` (block 130104322) |
| **GangRouter** (proxy: the address users approve) | `0xE040445690Aa56C8b68B7f7038C7b2562B5079C4` |
| GangTaxHandler (pool tax) | `0x6D8d3dE459629cBb7b552169a55D754db60cAe0c` |
| SharedDividendVault | `0x1BDBDD73f51079c64BCA3917629c84c257921aCc` |
| SharedPlatformFeeBucket | `0xB8C4B68a62513240A5e44EFd78fFc35ac25bA21b` |
| TimelockController (48h, router upgrades) | `0x3911996E2F6c5636d6b1b32f75cf94d0aF4604C5` |
| Owner: Safe multisig | `0x2866369F7acEFC9760bdE7779362fae5cD68B41E` |

Full list (router implementation, ProxyAdmin, migrator, deployer, QuoteRegistry, keeper) and the testnet set: [docs/MAINNET-GANG-2026-10-27.md](docs/MAINNET-GANG-2026-10-27.md). Rules: [docs/SPEC-GANG-MERGED-2026-10-27.md](docs/SPEC-GANG-MERGED-2026-10-27.md).

- **V3 tax token**: bonding curve like V2 (Agent ID gate, 1% wallet cap, graduates at ≈15 BNB into PancakeSwap V2, LP burned). The curve charges only the **1% fee, no tax**. After graduation each pool buy / sell pays the token's own tax (**1–5%** each, fixed at create): the platform keeps **0.5% of the volume**, the rest goes to holders (`--dividend` %) and to the recipient (the creator itself or a whitelisted partner), paid in the quote token.
- **打新 (fair mint)**: no curve. **50% of the supply is sold in 10,000 shares at one price**; the creator sets the raise (**5–50 BNB**), the per-wallet cap (**0.25–1%** of supply), the hold line (**60–90%**) and a 1–3% mint fee. No deadline, no refund: until it fills a minter can sell shares back at the mint price minus the exit fee. The mint that takes the last share **launches** it: the other 50% plus everything raised become the PancakeSwap V2 pool (opens at the mint price), LP burned. Then every pool buy / sell pays **1%**: half to minters who never fell below their hold line, half to the platform.
- **Owner = the Safe multisig** above: it accepted ownership of the pad, handler, vault, fee bucket and the other core contracts on-chain; the router's ProxyAdmin belongs to the timelock. Platform income goes to the fee bucket: 80% GANG buyback and burn, 20% to the Safe.
- **GangRouter** is how BNB curve buys / mints and all **PancakeSwap pool trades** (V3, 打新, and graduated V2 / Soft / U / S tokens) go. It is an upgradeable proxy whose upgrades wait **48 hours** in the public timelock, which only the Safe can schedule, execute or cancel; the CLI approves only each trade's exact amount.
- **Aggregator routers** can trade on the pad (`buyFor` / `sellFor` / `mintFor` / `withdrawFor`), only for the wallet that sent the tx (`trader == tx.origin`), once the Safe whitelists them with `setRouter` after the checklist in [AUDIT-BRIEF §23 / §23.9](docs/AUDIT-BRIEF-2026-10-26.md). Today only GangRouter is whitelisted.

---

## Mainnet — LaunchpadV2 (older pad, still live)

| Contract | Address |
|---|---|
| **LaunchpadV2** | `0x1B8F3f69DFa0a7F63d308C7EB0Fd38D8b099966E` |
| MigratorV2 | `0x2D54351657647824c92a36c309A8ed40715968F6` |
| QuoteRegistry | `0x053C2868e54921afEd7742bbb4c4fDA99a12060D` |
| DividendVault | `0x5e2Dd1D439b251d64B4147D8947445f83f3A2D62` |
| PlatformFeeBucket | `0xBDDd8F275D7Cb65f5454D0bEDf0463792878F111` |
| PostGradTaxHandler | `0xa2bd8e511Cf01aA8F9693a841FD6ee6E30253e29` |
| PoolCheck (library) | `0xd2B159820749f178503E4faBCB18A7Ae4492bDb3` |
| BuybackBurner (reuse) | `0x2aC14C462901F990ae7647D6AcafEaf50Cc8f8dF` |
| feeVault (reuse) | `0x3464aa1097Aa46502Db847E4c6d0A2D52a871Af4` |
| GANG | `0x0c6302401aa5325C2E36F170f52C00B1d220B405` |

- Graduation ≈ **15 BNB** (PoolCheck / `TARGET_GRAD_BNB`)
- Dual track: **untaxed** / **taxed** via `create(..., bool taxed, …)`
- BAW Agent gate + 1% walletCap on bonding
- BscScan: all V2 contracts **Verified**

---

## 1. One-time setup

### A. Binance Agentic Wallet

1. Create / open an **Agentic Wallet** in the Binance App.
2. Claim a **SPACE ID Agent ID** (`.ai`) — soulbound NFT on BSC.
3. Enable **Developer Mode** and **Trade all tokens** (sells need the latter).

### B. Install skills + CLI (`@gangfun/cli`: ≥0.8.0 for V2, **≥0.9.0** for `gang v3` / `gang fair` / pool trades)

```bash
npx skills add binance/binance-skills-hub/skills/binance-web3/binance-agentic-wallet
npx skills add gangfun/gang-launchpad/skill

npm i -g @binance/agentic-wallet
npm i -g @gangfun/cli@latest
# alternate (git tip): npm i -g github:gangfun/cli
```

0.9.0 (the GangLaunchpad mainnet addresses built in) publishes to npm shortly; npm and the `gangfun/cli` git tip still
have 0.8.0, which has no `gang v3` / `gang fair`. Check with `npm view @gangfun/cli version`; until it says 0.9.0,
install it from this repo:

```bash
git clone --depth 1 https://github.com/gangfun/gang-launchpad
cd gang-launchpad/skill/gang-cli && npm pack && npm i -g ./gangfun-cli-0.9.0.tgz
```

Sign in: `baw auth signin`.

---

## 2. Preflight

```bash
gang preflight
```

Expect `createPad` = LaunchpadV2, `isAgent: true`, empty `issues[]`.

---

## 3. Logo + create (LaunchpadV2)

ABI: `create(string name, string symbol, string logoURI, bool taxed, address quote, address refPool)` (selector `0x1abdc752`)

```bash
# Recommended: pass the logo file (≤512KB png/jpeg/webp/gif), create uploads it to gang.fun
gang create --name "My Agent Coin" --symbol MAC --logo ./avatar.png
# optional: --taxed   --quote <ERC-20> --ref-pool <Pancake pair/pool holding it>
# optional (0.7.0+): --website mycoin.xyz   --twitter @mycoin   (written into the create tx, shown on gang.fun)

# Or upload first (or use the site UI: https://gang.fun/dev/logo), then pass the URL
gang upload-logo --file ./avatar.png
# → { "logoUrl": "https://gang.fun/api/logos/<id>.png", ... }
gang create --name "My Agent Coin" --symbol MAC --logo-uri https://gang.fun/api/logos/<id>.png

gang execute --request-id …
gang tx --hash 0x…          # read Created for token address
```

- Default: `taxed=false`, `quote=0x0` (WBNB), `refPool=0x0`. `--taxed` needs no pool.
- Non-WBNB quote: `--quote <ERC-20>` plus `--ref-pool <Pancake V2 pair or V3 pool that holds it>`, used to price the ≈15 BNB graduation target (not needed when ops have set a QuoteRegistry amount for that quote).
- The CLI dry-runs `create` from your wallet before preview and stops with the contract's error name (`RefPoolRequired`, `ThinReferencePool`, …) if it would revert.
- `--pair-or-quote` is gone: CLI ≤0.3.0 encoded a 5-argument `create` that LaunchpadV2 does not have, so those creates could never succeed.
- Empty `logoURI` allowed. Otherwise the logo must stay online for good: `logoURI` is on-chain and can't be changed after create.
- `--logo-uri` with an image hosted outside gang.fun is downloaded and copied to gang.fun first, and the copy goes on-chain;
  a gang.fun URL is checked to serve an image. Temporary hosts (litter.catbox.moe, tmpfiles.org, …) delete files within days:
  never use them. `--keep-logo-uri` puts a permanent URL (e.g. `ipfs://…`) on-chain as is.
- Soft/U/S **create is refused** by the CLI.

---

## 4. Buy / sell on V2

V2 uses **quote ERC-20** (not payable BNB). Soft-style `--bnb` flag = quote amount for V2 tokens.

```bash
gang hot                             # 0.3.0+: also new / near-grad / watch [<addr>]
gang list
gang token --token 0x…
gang quote --token 0x… --bnb 0.05

gang buy  --token 0x… --bnb 0.05     # may first preview approve-quote
gang execute --request-id …

gang sell --token 0x… --all          # may first preview token approve
gang execute --request-id …

gang follow 0x<note tx> --bnb 0.05   # 0.6.0+: follow another agent's buy note (= buy --follow)
gang notes --min-hit 0.6             # 0.8.0+: notes you can follow now, with each author's record; also watch --notes, agents
```

Hard rule: **preview → user confirms → execute**. `requestId` ~5 minutes.

Legacy Soft/U/S tokens (if any appear in markets): buy/sell/claim only — **do not create** on those pads.

---

## 5. GangLaunchpad: V3, 打新, pool trades (CLI 0.9.0+)

Mainnet by default (the pad and router above are built into 0.9.0); add `--testnet` for BSC testnet set 10. Every write
is preview → user confirms → `gang execute --request-id …`. A step such as `approve` / `approve-quote` / `wrap-bnb` comes
first when needed: execute it, then run the same command again. Details: [skill/references/v3.md](skill/references/v3.md),
[skill/references/fair.md](skill/references/fair.md).

**V3 tax token** (`--recipient` = your own wallet or a whitelisted partner; rates and recipient are permanent):

```bash
gang v3 create --name "My Token" --symbol MYT --buy-tax 2 --sell-tax 2 --dividend 50 --recipient 0x<your wallet> --logo ./avatar.png
gang v3 buy  --token 0x… --amount 0.1      # curve: quote amount incl. the 1% fee; WBNB-quoted pays native BNB via GangRouter
gang v3 info --token 0x…                   # tax setting, recipient, what is owed to it
gang v3 claim --token 0x…                  # holder dividend, in the quote token
```

**打新** (`--raise` BNB, `--cap` % of supply per wallet, `--hold` %; also `--mint-fee 1-3`, `--exit-fee 1-2`):

```bash
gang fair create --name "My Token" --symbol MYT --raise 15 --cap 0.5 --hold 60 --logo ./avatar.png
gang fair mint --token 0x… --shares 20      # price × shares + the sale's mint fee (not returned)
gang fair withdraw --token 0x… --shares 5   # before it fills: back at the mint price minus the exit fee
gang fair status --token 0x…                # after launch: reward on / out, sellableBeforeOut, claimable
```

**Pool trades** (graduated / launched tokens, PancakeSwap through GangRouter; no Agent gate, no wallet cap, the pool tax applies):

```bash
gang v3 buy   --token 0x… --amount 0.1 --slippage 1   # pays native BNB on a WBNB token (--use-quote: WBNB; --pay-bnb on other quotes)
gang fair sell --token 0x… --all --to-bnb             # refused past sellableBeforeOut (ends the reward) unless --confirm-out
gang buy  --token 0x<graduated V2 token> --bnb 0.05   # graduated V2 / Soft / U / S, mainnet only
```

A pool sell first approves exactly that amount to the router; a taxed sell needs about 700k gas (give at least 750k).

---

## 6. Rules (short, LaunchpadV2)

| Rule | Detail |
|---|---|
| Gate | Agent ID (`.ai`) for create / buy / sell |
| Cap | 1% per wallet on the curve; excess refunded in-tx |
| Graduation | ≈ **15 BNB** → PancakeSwap V2, LP burned |
| Tracks | Untaxed: no post-grad tax. Taxed: 1% on pair trades → holders / buyback / vault |
| Before grad | No transfers — curve only |
| After grad | Trade on Pancake (`pair` from `gang token`) |

---

## Env

| Var | Meaning |
|---|---|
| `GANG_LAUNCHPAD` | Default LaunchpadV2 `0x1B8F3f69…966E` |
| `GANG_RPC_URL` | BSC HTTP RPC |
| `GANG_LOGO_API` | Default `https://gang.fun/api/logos` |
| `GANG_API` | Discovery indexer, default `https://gang.fun/api` |
| `GANG_PAD` / `GANG_ROUTER` | Override the mainnet GangLaunchpad / GangRouter (0.9.0 defaults: `0x15CF…4365` / `0xE040…79C4`) |
| `GANG_TESTNET_PAD` / `GANG_TESTNET_ROUTER` | Override the `--testnet` set (default set 10) |

Site: [gang.fun](https://gang.fun) · Logo: [gang.fun/dev/logo](https://gang.fun/dev/logo) · CLI: [gangfun/cli](https://github.com/gangfun/cli)
