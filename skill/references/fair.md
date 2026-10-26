# Fair mint (打新)

A fair mint has no bonding curve. Half the supply (500,000,000) is sold in **10,000 equal shares at one fixed price**;
the other half plus every share's principal goes into a PancakeSwap V2 pool when the last share is minted, so the pool
**opens at the mint price**. LP is burned. **No deadline, no refund**: a sale stays open until it fills. Until then a
minter can sell shares back to the sale at the same fixed price (minus the exit fee), so the price is flat both ways.

**For now fair mint runs on BSC testnet only: every `gang fair` command needs `--testnet`.** Without it the CLI answers
`fair mint is not deployed on BSC mainnet yet`. Testnet tokens and quotes have no value; say so if the user asks.

```bash
gang fair list [--status minting|launched|all]              # sales on gang.fun (needs the server to run fair mint)
gang fair info --token <addr> --testnet                      # one sale from the chain
gang fair status --token <addr> --testnet                    # my shares; after launch my reward state
gang fair create --name "My Token" --symbol MYT [--raise 15] [--cap 0.5] [--hold 50] [--mint-fee 1] [--exit-fee 1] [--shares 1] [--logo ./avatar.png | --logo-uri URL] [--website URL] [--twitter @handle] [--description "…"] --testnet
gang fair mint --token <addr> --shares <n> [--min-shares <n>] --testnet
gang fair withdraw --token <addr> (--shares <n> | --all) --testnet   # sell back at the mint price before it fills
gang fair claim --token <addr> --testnet
gang execute --request-id …
gang fair tx --hash 0x… --testnet                            # decode Created / Minted / Launched / … on the fair chain
```

## Rules to tell the user

- **Create** (Agent ID required): `--raise` 5–50 BNB (converted to the quote at create and locked), `--cap` 0.25–0.5% of
  supply per wallet (0.5% = 100 shares, so the sale needs at least 100 wallets to fill; 0.25% → 200), `--hold` 30–80
  (the hold line, below). There is no deadline (`--hours` is gone). The creator must mint at least 1 share in the same tx (`--shares`, default 1).
  Quote is WBNB unless `--quote`, which must be on gang's quote whitelist (listed 18-decimal tokens with a fixed rate,
  such as USDT; anything else fails with `QuoteNotAllowed`). The raise is converted at gang's fixed rate, not a pool.
  Create also uploads the token's metadata JSON (name, symbol, `--description`, the logo, `--website`, `--twitter`) and
  fixes its URL as the token's `contractURI()` / `metaURI()` — permanent, so get the links right first (see v3.md).
- **Fees** are the creator's choice at create, fixed for the sale: `--mint-fee` 1–3% and `--exit-fee` 1–2% (default 1% / 1%).
  `gang fair info` shows them as `mintFeePct` / `exitFeePct` (and `exitFeeNowPct`, what a withdraw pays right now);
  always quote the sale's own numbers, never assume 1%.
- **Mint** (Agent ID required): price per share × shares, **plus the mint fee**, which goes to the platform at once and
  is never returned. A wallet can't exceed its cap. The last mint is cut down to the shares left (`--min-shares` refuses
  less); the mint that fills the sale also launches it, so it costs more gas.
- **Withdraw** (sell back): any time before the sale fills, at the mint price **− the exit fee**; the mint fee is not
  returned (e.g. mint 1% + exit 1% = 2% round trip). **Once the sale has made no progress for 7 days the exit fee is 0** (`stale: true`,
  `exitFeeFreeIn` counts down to it): a stalled sale can be left at the full mint price. Progress = shares sold reaching 10
  above where the clock last restarted (`progressAt`); a 1-share mint, or minting back shares others withdrew, does not
  restart it.
- **Progress can go down**: withdraws return shares to the sale. `gang fair info` shows `sharesLeft` and `minWalletsLeft`
  (at least this many more wallets are needed to fill, given the cap).
- **Locked until launch**: minted tokens sit in the wallet but can't be transferred or traded before launch.
- **After launch**: every buy / sell on the official pool pays 1%. Half goes to **holder rewards**, half to the platform
  (80% GANG buyback / 20% vault).
- **Holder reward**: only wallets that minted. Weight = current balance, capped at what the wallet minted.
  **Falling below the hold line (e.g. 50% of what it minted) once is out for good**: buying back does not restore it.
  Moving tokens to another wallet, adding them to a pool, or into any contract counts like selling. Rewards earned before
  going out stay claimable.

- **Logo**: same as `gang create` — `--logo ./file.png` is uploaded to gang.fun; a `--logo-uri` on another host is copied
  to gang.fun first (`logoURI` is permanent on-chain). The preview shows the final `logoURI`.
- **No notes yet**: `--note` / `--follow` are refused on `gang fair` (the server cannot match them to a fair-mint tx yet).
  Tell the user why in words instead.
- Env: `GANG_FAIR_TESTNET_PAD` / `GANG_FAIR_TESTNET_RPC_URL` override the testnet deployment; `GANG_FAIR_PAD` is for mainnet;
  `GANG_ROUTER_TESTNET` / `GANG_ROUTER` the router.

## Reading results

- `status.position` after launch: `reward` (`earning` / `out`), `balance`, `holdLineTokens`, `sellableBeforeOut`
  (how much can be sold and still earn), `poolSharePct`, `pendingReward`. **Before any sell or transfer of a fair-mint
  token, check `sellableBeforeOut` and warn the user if the trade goes past it** — it ends the reward for good.
- **WBNB sales**: `gang fair mint` pays native BNB through GangRouter in one tx (`via: 'router'`, `payBnb` = cost + mint
  fee); the shares are still this wallet's, and withdraw / claim stay direct. `--use-wbnb` pays from WBNB instead.
- Other quotes (and `--use-wbnb`, and `create`) may return a setup step first: `step: 'wrap-bnb'` (WBNB short: wraps BNB)
  or `step: 'approve-quote'`. Execute it, then **run the same command again** for the real step.
- `success: false` with `error` + `hint` is the pad's own reason (e.g. `WalletCapReached`, `NotMinting`, `BadConfig`).
  Fix the flags; don't retry the same ones. `--cap` / `--mint-fee` / … outside the bounds fail before any chain call.
- A preview error that mentions the chain means the Agentic Wallet may not sign on BSC testnet: `--calldata` prints the
  raw tx (`tx: { chainId, to, data, value }`) instead of a baw preview, for a wallet that can.

Flow: preview → show the user shares, cost **including the sale's mint fee** (`feePct`), the rules above that apply (fee not returned / exit fee / hold line) →
confirm → `gang execute` → `gang fair tx --hash … --testnet`. Link the sale: `https://gang.fun/mint/<token>`.
