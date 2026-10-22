# Token logo / metadata feasibility

## Current on-chain create path

- `Launchpad.create(string name, string symbol)` deploys `LaunchToken`, a minimal OpenZeppelin `ERC20` with fixed `name` and `symbol` in the constructor.
- `LaunchToken` has no `tokenURI`, no EIP-2612/ERC-1046 fields, and no storage for an image or metadata hash.
- The `Created` event emits `(token, creator, name, symbol)` only.

**Conclusion:** the live mainnet contract cannot accept an image URI or IPFS CID at create time without a new deployment.

## What would be needed on-chain (not in this test bake)

Reasonable options for a future version:

1. **Extended create** — e.g. `create(string name, string symbol, string metadataURI)` stored immutably on `LaunchToken` or in a `Launchpad` mapping, emitted in `Created`.
2. **ERC-20 extensions** — optional `logoURI()` or EIP-1046 `tokenURI()` on `LaunchToken` (wallets/explorers rarely show these for arbitrary ERC-20s; indexers and UIs still matter).
3. **IPFS** — creators upload JSON `{ name, symbol, image }` to IPFS; URI passed into (1). On-chain cost is one string; hosting is off-chain.

No mainnet contract changes are deployed as part of the lazy test bake.

## Test-bake off-chain path (implemented)

| Piece | Behavior |
|--------|----------|
| Indexer DB | `token_logos` table + files under `backend/indexer/data/logos/` (or `GANG_MEDIA_DIR`) |
| `POST /tokens/:addr/logo` | JSON `{ "image": "data:image/png;base64,..." }`, max 512KB; token must already exist in indexer |
| `GET /tokens/:addr/logo` | Serves image bytes; list/detail JSON includes `logoUrl` when set |
| Web `/launch` | Creator picks image + runs CLI create; pastes address; registers logo |
| UI | `TokenAvatar` uses `logoUrl` on market cards and token page |

**Trust model (test only):** anyone can POST a logo for any indexed token. Production would need creator signature, tx binding, or owner-only updates.

## CLI / skill

`gang create` today forwards name/symbol to the wallet preview only. Logo registration is web/indexer-only until a future CLI flag (e.g. `--logo-url`) posts to the same API after create.
