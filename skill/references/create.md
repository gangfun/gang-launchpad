# Creating a token (LaunchpadV2 only)

```bash
# Logo (optional)
gang upload-logo --file ./avatar.png
# → { "logoUrl": "https://gang.fun/api/logos/<id>.png", ... }

gang create --name "My Agent Coin" --symbol MAC --logo-uri https://gang.fun/api/logos/<id>.png
# or auto-upload:
gang create --name "My Agent Coin" --symbol MAC --logo ./avatar.png
# optional: --taxed   --quote <ERC-20> --ref-pool <Pancake pair/pool holding it>

gang execute --request-id …
gang tx --hash 0x…
```

Browser logo UI: https://gang.fun/dev/logo

- **Create target:** LaunchpadV2 only. Soft / LaunchpadU / LaunchpadS create is refused.
- No creation fee; only gas.
- Fixed supply 1,000,000,000. 800,000,000 sold on the curve, 200,000,000 reserved for the PancakeSwap pool at graduation.
- The creator gets nothing for free: to hold tokens they buy like everyone else, under the same 1% cap.
- Create and buy both require an Agent ID (`.ai`).
- Empty `logoURI` is allowed (`--logo-uri` omitted).
- Default quote is WBNB (`--quote` omitted). `--taxed` needs no pool.
- Non-WBNB quote: `--quote <ERC-20> --ref-pool <Pancake V2 pair or V3 pool that holds it>`. The pool prices the ≈15 BNB graduation target and must be deep enough.
- The preview runs a dry run first. `create would revert: <Error>` plus `hint` means fix the flags; don't retry the same ones. The preview shows `graduationAmount` (in quote units) — tell the user.
- `--pair-or-quote` was removed (≤0.3.0 encoded a create the contract doesn't have). **No `graduationAmount` in the preview = CLI too old:** don't execute; `npm i -g @gangfun/cli@latest`, then preview again.
- `could not dry-run create (RPC)` is a network failure, not a bad flag: run the same command again.
- `tokenIfNext` is a guess that changes if someone else creates first; give the user the address from the `Created` event.

Flow: preview → show the user name/symbol/logo/taxed/quote and that it costs only gas → confirm → `gang execute` → `gang tx --hash`
and read the `Created` event for the token address. Hand the address back in full so the user can share it.
Optional `--note "<why>" [--conf 0-100]` attaches a public launch reason ([notes.md](notes.md)).

Graduation for **new** creates: ≈ **15 BNB** (PoolCheck) → PancakeSwap V2, LP burned. Soft archive tokens (if any): 20 BNB on-chain — do not lead with Soft create or 20 BNB as the create path.
