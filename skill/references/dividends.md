# Tax dividends (V2 / S / U)

A taxed V2 / S / U token sends part of its trading tax to its holders. Each token is registered in one **DividendVault**
and pays out in that vault's quote token for it (GANG, WBNB, a stock token, …). Nothing arrives by itself: the holder
calls `claim(token)` on the vault; `gang dividends` shows what is owed and `gang claim` claims it.

| Rail | DividendVault |
|---|---|
| V2 | `0x5e2Dd1D439b251d64B4147D8947445f83f3A2D62` |
| S | `0x41E42A6E8b81794AD6589A02545Fdf9d4963B06C` |
| U | `0x2E95280a3bCbB4a6b41D92B0CaEE3E9fc6c72F38` |

BSC mainnet only. V3 and 打新 dividends are a different vault: `gang v3 status|claim`, `gang fair status|claim`
([v3.md](v3.md), [fair.md](fair.md)); those commands only work with `--testnet` for now.

## `gang dividends [--token <addr>] [--from <addr>]`

Read-only, no signing. Checks every taxed token gang.fun lists (or just `--token`, read on-chain) for the Agentic Wallet
(or `--from`, any address) and lists the ones it holds or is owed something on, claimable first:

- `balance`: the wallet's tokens.
- `vaults[]`: the vault the token is registered in (`rail`, `vault`, `quote`, `quoteSymbol`), and `pending`: what
  `claim(token)` sends now, in the quote's units. `share` is the balance that vault counts; `earning: false` with a
  balance means it earns no new dividends there (e.g. below the vault's minimum holding). Older credit is still claimable.
- `claimable`: some vault owes it something now.

`checked` = how many tokens were read. A token with an empty `vaults` is untaxed or not a V2 / S / U token.
Show amounts with `quoteSymbol`; never add amounts of different quotes together.

## `gang claim [--token <addr>]`

Previews `claim(token)` for every vault that owes the wallet something (every token, or just `--token`). Each claim is
dry-run first; one that would revert is listed under `skipped` with the reason and never previewed. The result has one
entry per claim in `claims[]`, each with its own `requestId`:

1. Show the user each claim: token, amount, `quoteSymbol`.
2. After they confirm, `gang execute --request-id <id>` for each one. Previews expire (`expiresAt`, about 5 minutes):
   with many claims, execute soon or run `gang claim` again.
3. `gang tx --hash <hash>` waits for the receipt.

Nothing to claim → `success: false`, `error: nothing to claim…`, `hint: gang dividends`. That is an answer, not a fault.

`--calldata` prints each raw tx (`to` = the vault, `data` = `claim(token)`) instead of a baw preview; with it, `--from`
builds for another wallet. A preview always signs from the Agentic Wallet, so `--from` is refused without `--calldata`.

```bash
gang dividends
gang claim                                  # → claims[].requestId
gang execute --request-id <id>              # once per claim, after the user confirms
gang dividends --token 0x… --from 0x…       # someone else's, read-only
```
