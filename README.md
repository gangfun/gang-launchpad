<p align="center">
  <img src="web/public/brand/lockup.png" alt="GANG" height="42" />
</p>

<p align="center">
  <img src="https://img.shields.io/badge/BNB%20Chain-BSC%20·%20LaunchpadV2-FCD535?style=flat-square&labelColor=0E0E0E" alt="BNB Chain" />
  <img src="https://img.shields.io/badge/gate-Agent%20ID%20only-FCD535?style=flat-square&labelColor=0E0E0E" alt="Agent ID" />
  <img src="https://img.shields.io/badge/graduation-≈15%20BNB-FCD535?style=flat-square&labelColor=0E0E0E" alt="15 BNB" />
</p>

<p align="center"><a href="./README.md">English</a> · <a href="./README.zh-CN.md">中文</a></p>

<pre align="center">
╔══════════════════════════════════════════════════════════╗
║  GANG · LaunchpadV2 on BNB Chain                         ║
║  Binance Agentic Wallet · gang.fun                       ║
╚══════════════════════════════════════════════════════════╝
</pre>

**Create path = LaunchpadV2 only.** Soft / LaunchpadU / LaunchpadS are **not** create targets (legacy markets may still list existing tokens for buy/sell/claim). Only wallets with a SPACE ID Agent ID (`.ai`) can create/buy/sell on the curve. Your agent runs the CLI; you approve in the Binance App. The CLI never holds keys.

---

## Mainnet — LaunchpadV2

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

### B. Install skills + CLI (`@gangfun/cli` on npm, ≥0.5.0)

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

Expect `createPad` = LaunchpadV2, `isAgent: true`, empty `issues[]`.

---

## 3. Logo + create (LaunchpadV2)

ABI: `create(string name, string symbol, string logoURI, bool taxed, address quote, address refPool)` (selector `0x1abdc752`)

```bash
# Recommended: pass the logo file (≤512KB png/jpeg/webp/gif), create uploads it to gang.fun
gang create --name "My Agent Coin" --symbol MAC --logo ./avatar.png
# optional: --taxed   --quote <ERC-20> --ref-pool <Pancake pair/pool holding it>

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
```

Hard rule: **preview → user confirms → execute**. `requestId` ~5 minutes.

Legacy Soft/U/S tokens (if any appear in markets): buy/sell/claim only — **do not create** on those pads.

---

## 5. Rules (short)

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

Site: [gang.fun](https://gang.fun) · Logo: [gang.fun/dev/logo](https://gang.fun/dev/logo) · CLI: [gangfun/cli](https://github.com/gangfun/cli)
