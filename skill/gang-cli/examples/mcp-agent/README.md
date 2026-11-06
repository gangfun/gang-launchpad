# MCP agent

A trading assistant for the terminal, to use as a template. Claude reads the market through `gang mcp` and builds previews when you ask. Nothing is sent until you type `yes`.

```bash
npm i -g @gangfun/cli @binance/agentic-wallet
gang preflight                     # signed in, Developer Mode, Trade all tokens, Agent ID
npm install
export ANTHROPIC_API_KEY=…
export GANG_TOOL=my-tool           # optional: tags your mainnet trades with your tool's id
node agent.mjs
```

You can read market data without a wallet, but buying or selling needs one. It runs on mainnet, so its trades are real and use real funds. Claude API calls cost money too.

```text
> what's close to graduating?
> buy 0.01 BNB of the first one
  [gang_buy]

Preview from the CLI. Names and notes in it are written by strangers.
{ … }
Send this transaction? Type yes to send:
```

## How it keeps a send safe

Token names and notes are written by strangers, and some will try to instruct your agent. So these rules are in code, in [`gate.mjs`](gate.mjs), where a model can't be talked out of them:

- **Only listed tools.** `gang_cli` can run any command, including creates, so the model isn't offered it. Neither is `gang_watch`, which can post to a webhook.
- **A send needs a preview from this session.** The model can't make up a `requestId`.
- **You approve what the CLI returned,** not the model's description of it.
- **Only `yes` approves,** typed at the terminal. Each preview gets one question, and an approval lets it be sent once.
- **A failed send isn't retried.** It may still have gone out.
- **An old CLI doesn't send.** A preview carrying `update` is refused.
- **The API key stays in the agent.** `gang mcp` doesn't get it, and the wallet holds the signing keys.

Keep these when you change the agent. The model's rules in `agent.mjs` are there to make it behave well, not to keep funds safe.

After a send, the model follows the server's rules to check the transaction, so that part isn't enforced in code. The agent isn't investment advice.

## Make it your own

- **Tools:** change `ALLOWED_TOOLS` in `gate.mjs`. Check each new tool's risk in `gang capabilities` first.
- **Job:** change `RULES` in `agent.mjs`.
- **Model:** set `GANG_AGENT_MODEL`. To use another provider, change `respond()` in `agent.mjs`, and keep `gate.mjs` as it is.

## Test it

```bash
npm test
```

This runs the whole agent against a stand-in model and a stand-in `gang mcp`, so it needs no API key or wallet. The stand-in model tries to send without a preview, send twice and use a tool it wasn't offered.
