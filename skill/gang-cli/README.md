# Gang CLI (`gang`)

Operate [gang.fun](https://gang.fun) from a Binance **Agentic Wallet**. Curve buys require a SPACE ID `.ai` Agent ID. This CLI builds calldata; `baw` signs — no keys in this package.

Not an open-source product dump: install and run steps only.

## Install

Node ≥ 18. Also install Binance Agentic Wallet CLI (`baw`):

```bash
npm i -g @binance/agentic-wallet
# Primary — public npm (https://www.npmjs.com/package/@gangfun/cli)
npm i -g @gangfun/cli
# or pin: npm i -g @gangfun/cli@0.1.4
npx @gangfun/cli preflight
```

**Backup** (only if npmjs unreachable): `npm i -g github:gangfun/cli` or GitHub Packages (`--registry=https://npm.pkg.github.com`, needs `read:packages`).

If a previous global is stale:

```bash
npm uninstall -g @gangfun/cli
npm i -g @gangfun/cli@0.1.4
```

After install, run `gang preflight` — Launchpad must be `0x315Ba2e8952D06094CC636b2B84229FA32fb23A7` (v4.1). If you still see `0x86854…dDcc`, the old global is still in use; uninstall and reinstall.

Skill install (Claude Code / Cursor / Codex / OpenClaw / Binance AI Pro):

```bash
npx skills add gangfun/gang-launchpad/skill
```

## Setup

1. Binance App → Wallet → Agentic Wallet → create; claim a `.ai` Agent ID.
2. Enable **Developer Mode** and **Trade all tokens**.
3. `baw auth signin` → confirm in the App.
4. `gang preflight`

## Commands

```bash
gang preflight
gang list
gang token --token <addr>
gang quote --token <addr> --bnb <n>
gang buy --token <addr> --bnb <n> [--slippage 1]
gang sell --token <addr> (--amount <tokens> | --all) [--slippage 1]
gang create --name <n> --symbol <s>
gang execute --request-id <id>
gang tx --hash <0x..>
```

Buy / sell / create: **preview → you confirm → execute**. `requestId` expires in ~5 minutes. Sells may need App confirmation.

## Rules (short)

- 1% per-wallet cap on the curve; excess BNB refunded in-tx.
- 20 BNB → graduate to PancakeSwap V2, LP burned.
- Before graduation: no transfers, curve only.
- Graduated: trade on PancakeSwap (`pair` from `gang token`).

## Env

| Var | Meaning |
|---|---|
| `GANG_LAUNCHPAD` | Launchpad address (default v4.1 `0x315Ba2e8952D06094CC636b2B84229FA32fb23A7`; override via env) |
| `GANG_RPC_URL` | BSC HTTP RPC |

## Version

`0.1.4` · repo [gangfun/cli](https://github.com/gangfun/cli) · [npmjs `@gangfun/cli`](https://www.npmjs.com/package/@gangfun/cli); GitHub Packages / `github:` backup only
