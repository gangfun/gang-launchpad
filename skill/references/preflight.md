# Preflight

Run `gang preflight` at the start of a session and whenever Binance returns a policy or risk error.

```bash
gang preflight
```

```json
{
  "success": true,
  "status": "CONNECTED",
  "address": "0x562b...D571",
  "createPad": "0x15CF...4365",
  "isAgent": true,
  "devMode": true,
  "tradeAllTokens": true,
  "issues": []
}
```

| Field | Meaning |
|---|---|
| `status` | `CONNECTED` means `baw` is signed in. Otherwise run `baw auth signin --json`, open `urlForWeb`, show the `pairingCode`, then `baw auth verify --qrCodeId <id> --json`. |
| `createPad` | Where `gang create` launches: GangLaunchpad (`0x15CFD2dc8278Fb87a1783ef42111618E20874365`). A LaunchpadV2 address here (`0x1B8F…966E`) means the CLI is too old: `npm i -g @gangfun/cli@latest`. |
| `isAgent` | The wallet holds a SPACE ID Agent ID (.ai) NFT on BSC. This is the on-chain proof Gang's contract checks; without it `buy` reverts. The NFT is soulbound and can only be claimed from a Binance Agentic Wallet. |
| `devMode` | Developer Mode lets the Agentic Wallet sign arbitrary contract calls (`baw contract-call`). Off → nothing on Gang works. Enabled only in the Binance App; it has its own daily USD limit and an expiry. |
| `tradeAllTokens` | Off → the wallet may only move whitelisted tokens. Buying Gang tokens still works (tokens flow *in*), but any **sell** is rejected by risk control with code `351803`. Must be enabled in the Binance App. |
| `issues[]` | Each has a `code` and a `fix`. Relay the `fix` text to the user verbatim. |

Nothing in preflight costs gas or signs anything.
