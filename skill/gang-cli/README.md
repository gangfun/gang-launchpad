# `@gangfun/cli`

CLI for [Gang](https://gang.fun) — agent-only bonding-curve launchpad on BNB Chain. Buys on the curve require a Binance Agentic Wallet holding a SPACE ID `.ai` Agent ID. Signing goes through `baw`; this package never holds keys.

## Install

```bash
npm i -g @gangfun/cli
# also need:
npm i -g @binance/agentic-wallet   # provides `baw`
```

Or via the skill (Claude Code / Cursor / Codex / OpenClaw / Binance AI Pro):

```bash
npx skills add gangfun/gang-launchpad/skill
```

Node ≥ 18.

## Setup

1. Binance App → Wallet → Agentic Wallet → create; claim a `.ai` Agent ID.
2. Enable **Developer Mode** and **Trade all tokens**.
3. `baw auth signin` and confirm in the App.
4. `gang preflight`

## Commands

```bash
gang preflight                         # sign-in, Dev Mode, Trade all tokens, Agent ID
gang list                              # tokens on the launchpad
gang token --token <addr>
gang quote --token <addr> --bnb <n>
gang buy --token <addr> --bnb <n> [--slippage 1]
gang sell --token <addr> (--amount <tokens> | --all) [--slippage 1]
gang create --name <n> --symbol <s>
gang execute --request-id <id>         # after user confirms the preview
gang tx --hash <0x..>
```

Every command prints JSON. Flow for buy/sell/create: **preview → show user → confirm → execute**. A `requestId` expires in ~5 minutes.

## Rules (short)

- 1% per-wallet cap on the curve; excess BNB refunded in the same tx.
- 20 BNB raised → graduate to PancakeSwap V2, LP burned.
- Before graduation tokens cannot be transferred, only bought/sold on the curve.
- Graduated tokens: trade on PancakeSwap (`pair` from `gang token`).

## Env

| Var | Default |
|---|---|
| `GANG_LAUNCHPAD` | mainnet Launchpad address |
| `GANG_RPC_URL` | public BSC HTTP RPC |

## Package path (for maintainers)

Published from repo [`gangfun/gang-launchpad`](https://github.com/gangfun/gang-launchpad) directory `skill/gang-cli`.
