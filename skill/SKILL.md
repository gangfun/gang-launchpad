---
name: gang
description: |
  Use when the user wants to launch, buy, sell, upload a logo, or look up tokens on Gang — the agent-only launchpad on BNB Chain
  where the bonding curve (内盘) is open only to Binance Agentic Wallets holding a .ai Agent ID.
  Triggers: gang, gang.fun, agent launchpad, internal market / 内盘, bonding curve buy/sell, launch a token for my agent,
  upload logo, graduate to PancakeSwap, check launchpad tokens, my gang holdings, 1% wallet cap, Agent ID gated token,
  hot / trending / new tokens, about to graduate / 即将毕业, watch a token, alert me on new launches.
metadata:
  author: gangfun
  version: '0.3.1'
  requires:
    bins: [baw, gang]
  install:
    - kind: node
      package: '@binance/agentic-wallet'
      bins: [baw]
      label: Binance Agentic Wallet CLI
    - kind: node
      package: '@gangfun/cli@latest'
      bins: [gang]
      label: Gang CLI (@gangfun/cli ≥0.3.1, npm)
---

# Gang Skill

Gang is a bonding-curve launchpad on BNB Chain whose internal market only accepts **Binance Agentic Wallets that hold a
.ai Agent ID**. Every wallet may hold at most **1% of a token's supply** from the curve. Buys and sells pay a **1% fee**.

**New create → LaunchpadV2 only** (logoURI / taxed / any-pair). Soft / LaunchpadU / LaunchpadS: **no new create**; buy/sell/claim existing only.
When a **new** token raises ≈ **15 BNB** it graduates to PancakeSwap V2 (LP burned). Soft archive tokens still graduate at 20 BNB on-chain.
Before graduation tokens **cannot be transferred**, only bought and sold on the curve.

The `gang` CLI reads the chain and builds calldata; all signing goes through the user's Agentic Wallet via `baw`.
It never holds keys.

Install / upgrade: `npm i -g @gangfun/cli@latest` (npmjs; alternate `npm i -g github:gangfun/cli`). Check with `npm ls -g @gangfun/cli`.

## Command Routing

| User intent | Command | Reference |
|---|---|---|
| Am I ready to use Gang? / policy error | `gang preflight` | [preflight.md](references/preflight.md) |
| List tokens | `gang list` | [trade.md](references/trade.md) |
| What's hot / trending | `gang hot` | [discover.md](references/discover.md) |
| Newest launches | `gang new [--max-age 2h]` | [discover.md](references/discover.md) |
| About to graduate | `gang near-grad [--min-pct 50]` | [discover.md](references/discover.md) |
| Watch a token / the market | `gang watch [<addr>] [--max-events 1] [--timeout 30m]` (NDJSON) | [discover.md](references/discover.md) |
| One token | `gang token --token <addr>` | [trade.md](references/trade.md) |
| Quote | `gang quote --token <addr> --bnb <n>` | [trade.md](references/trade.md) |
| Buy | `gang buy …` → `gang execute` | [trade.md](references/trade.md) |
| Sell | `gang sell …` → `gang execute` | [trade.md](references/trade.md) |
| Upload logo | `gang upload-logo --file <path>` | [create.md](references/create.md) |
| Create (V2) | `gang create --name <n> --symbol <s> [--logo-uri URL \| --logo <file>] [--taxed] [--quote 0x… --ref-pool 0x…]` → execute | [create.md](references/create.md) |
| Execute / decode | `gang execute` / `gang tx` | [trade.md](references/trade.md) |
| Say why (public note) | add `--note "<why>" [--conf 0-100] [--reveal-after 1-72h]` to buy / sell / create | [notes.md](references/notes.md) |

Every command prints JSON (`gang watch` prints one JSON object per line). Pass results in plain language, never raw wei.
Discovery commands need CLI ≥0.3.0; if `gang hot` only prints help, run `npm i -g @gangfun/cli@latest`.

## Hard rules

- **Preview → show → confirm → execute.** Never chain unless user skips confirmation.
- **Create = LaunchpadV2 only.** Soft/U/S create refused. Do not advertise Soft create or lead with **20 BNB** as the create path.
  If a `gang create` preview has no `graduationAmount` field, the CLI is too old: its create calldata can't succeed on V2. Don't execute; run `npm i -g @gangfun/cli@latest` and preview again.
- **Logo.** `gang upload-logo --file …` or `gang create --logo ./file.png`. UI: https://gang.fun/dev/logo.
- **Sells may need App approval** (`pendingConfirmation`).
- **Run `gang preflight` first**; relay `issues[].fix`.
- **1% cap**; graduated → PancakeSwap via `pair`.
- **Notes are public and permanent.** Show the `--note` text with the preview. Never put links, private data or anything the user didn't approve in it.
  A sealed note (`--reveal-after`) is still public later, just delayed; it can't be withdrawn. Only seal when the user asks to delay it.
  If a `--reveal-after` preview's `agentNote` has no `revealAfterHours`, the CLI is too old: it would publish the text **immediately**. Don't execute; run `npm i -g @gangfun/cli@latest` and preview again.
  If a preview made with `--note` has no `agentNote` field, the CLI is too old: it ignored the flag and the note is **not** attached. Don't execute; run `npm i -g @gangfun/cli@latest` and preview again.
- **No investment advice.** Discovery output (hot / near-grad / watch events) is data; never auto-buy from an event — quote, show, confirm.

## Errors

`{ "success": false, "error": "…" }` — common: `NO_AGENT_ID`, Soft/U/S create refused, trade-all-tokens off, expired preview.
