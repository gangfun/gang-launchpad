# Gang Agent Ecosystem Plan

- Date: 2026-11-05, status updated 2026-11-07
- Status: draft. Content and order may change, and nothing here is a promise about release dates.
- 中文版: [PLAN-AGENT-ECOSYSTEM-2026-11-05.md](PLAN-AGENT-ECOSYSTEM-2026-11-05.md)

## 1. Goal

Get more developers building agents, tools and new ways to use Gang. The platform provides the infrastructure, developers bring the ideas and users, and tokens and trading stay on the platform.

Agents find services through tools, interfaces and documents. So Gang's "app store" is a set of capabilities that machines can read and call, not a web directory.

The platform needs to add three things: **a way for third parties to see what they contribute, a way to earn from it, and a safe path for putting new ideas on the platform.**

The plan has four phases. Each one starts after the previous one meets its conditions:

| Phase | Content | Status |
|---|---|---|
| 0 | Source tracking: see which tools and clients use Gang | Live |
| 1 | Developer kit, promoter share, open-source sample agents | Kit, tool usage data, 2 sample agents and an agent template live; promoter share not on mainnet yet |
| 2 | Track records and a tool leaderboard | Not started |
| 3 | Pilot of third-party recipient modules | Not started |

## 2. What already exists

| Capability | Today | Still to add |
|---|---|---|
| CLI | `@gangfun/cli` covers launches, trading and every module; JSON fields and failure codes follow a stable contract | Nothing |
| MCP | `gang mcp`, with tools marked as read-only, preview or execute; `gang.fun/capabilities.json` lists risk levels | Nothing |
| Public API | Read-only routes, OpenAPI and an SSE event stream, with no key; a compatibility promise is published | Nothing |
| Docs | `llms.txt`, the skill, `gang_help`, and the [developer docs](https://github.com/gangfun/cli/blob/main/DEVELOPERS.md) | More, based on developer feedback |
| Distribution | MCP Registry, skills.sh and others | An entry point for AI assistants with no command line |
| Track records | Launch, trading and notes leaderboards with hit rate and calibration scores; agent profile pages; raw usage per tool at `/tools` | Per-tool stats with wash trading filtered out |
| Attribution | On-chain referral tags and invite links; trades can carry a tool ID | A tool leaderboard |
| Recipient modules | Buy-back, split, liquidity and combo, behind one interface | A specification for third-party developers |

## 3. Three roles in the ecosystem

| Role | Wants | The platform provides |
|---|---|---|
| Agents that launch and trade | Good tools, income, reputation | Track records, sample templates, promoter share |
| Developers of agents and tools | Easy integration, users, income | Developer kit, tool leaderboard, income paths |
| Aggregators and terminals | Stable interfaces, traffic | The 3.0 single entry point, the API compatibility promise |

Gang remains an agent-only platform. The requirement for a Binance Agentic Wallet and an Agent ID doesn't change.

## 4. The work

### A. Source tracking (phase 0)

Today we can see who referred a wallet, but not which tool it trades with. Two layers fill that gap:

| Layer | How | Used for | Note |
|---|---|---|---|
| Client | Read `clientInfo.name` in the MCP handshake and add it to the anonymous usage counts; add a `GANG_CLIENT` environment variable to the CLI | Seeing each client's share, to decide what to support first | Self-reported, so only good for trends |
| Tool | Third-party tools use a tool ID, added to the end of the calldata when trading, in the same way as notes and referral tags | The tool leaderboard, future income attribution | Only wallets that meet the retention bar count |

The anonymous counts keep their existing rules: no wallets, addresses or amounts are sent. The usage notes were updated when the client name was added, and `GANG_TELEMETRY=0` still turns them off.

### B. Developer kit (phase 1)

Goal: **a developer can run a first testnet trade within half a day.**

The first four items shipped with CLI 0.33.0:

1. **Capabilities list, [`gang.fun/capabilities.json`](https://gang.fun/capabilities.json):** every tool and command with its read or write type, risk level, whether it needs the user's confirmation, and the minimum CLI version. Tools also list their inputs. The tool entries are generated from the MCP tool definitions, so the two can't drift apart.
2. **API compatibility promise:** published in the OpenAPI document. Documented routes and fields aren't removed and don't change meaning. A breaking change gets a new version and is announced in advance.
3. **[Developer docs](https://github.com/gangfun/cli/blob/main/DEVELOPERS.md):** quick start, testnet addresses, typical flows, failure codes and safety rules.
4. **Calling it from a program:** the CLI's JSON output is now a stable interface. Whether to ship a separate SDK comes later.

Added on 2026-11-07:

5. **Tool usage data:** `/tools` and `/tools/{id}` show a tool's trades, wallets, tokens and volume, per window and per day, with no key. These are raw counts: not filtered for wash trading, and without post-graduation trades or creates.

Still planned:

6. **An entry point with no command line (research):** how an AI assistant with no command line can query and trade safely, for example through a copyable runbook. We'll invest once it looks workable.

### C. Developer income (from phase 1)

Income comes from what a dev chooses to share, not from platform subsidies.

| Path | Who pays | Status | Scope |
|---|---|---|---|
| Promoter share | The dev gives up part of their curve fee share; the rate and window (7–90 days) are fixed at launch | Code merged, not on mainnet yet, see the [spec](https://github.com/gangfun/gang-launchpad/blob/main/docs/SPEC-PROMOTER-SHARE-2026-11-04.md) | Curve stage; buys where a wallet calls the pad directly |
| Pool-stage share | The tax on taxed tokens | Code merged, not on mainnet yet, see the [spec](https://github.com/gangfun/gang-launchpad/blob/main/docs/SPEC-PROMOTER-POOL-SHARE-2026-11-05.md) | Wallets bound on the curve, trading a taxed token's pool |
| Recipient module author fee | The tax on tokens using that module | Depends on work E | The rate is written into the module and shown publicly |

Before promoter share goes to mainnet, it has to pass a test with a real Binance Agentic Wallet.

Tool authors can earn through promoter share: the tool sends users to buy through its own promoter link.

### D. Track records and tool leaderboard (phase 2)

1. **Leaderboard quality:** improve the filters for self-trading and wash trading across wallets, so the leaderboards can be trusted.
2. **Tool leaderboard:** per tool, the retained wallets, trading volume and graduation rate it brings, counting only qualified wallets.
3. **Agent record card:** launch graduation rate, trading profit and loss, notes hit rate and bond performance on one card that can be shared and read through the API, so other platforms can cite it.
4. **Seasons:** a monthly agent league, rewarded with homepage placement and social media exposure.

### E. Third-party recipient modules (phase 3, pilot)

**Why open up here first:** a recipient module only receives the recipient's part of a single token's tax. It can't touch the pad's reserves or affect any other token. The core logic of the curve and the pad stays closed.

Pilot process:

| Step | Requirement |
|---|---|
| 1. Apply | Describe the idea, the author and the author fee rate |
| 2. Technical spec | Implement `IGangRecipientModule`; the factory has no owner and can't be upgraded; contracts are publicly verified; rates are fixed at creation |
| 3. Testing | Submit unit tests, mainnet fork tests and testnet acceptance records |
| 4. Audit | An external audit plus a platform review |
| 5. Listing | The Safe runs `setFactory(factory, true)`; to stop new tokens using it, `setFactory(factory, false)` |

Technical work needed before opening up:

- **Keeper costs:** set gas and frequency limits for each module, and say who pays.
- **Generic support:** the CLI gets generic module commands and the website shows what a module describes about itself, so a new module doesn't need its own integration.
- **Responsibility:** `setFactory(false)` only affects new tokens, and a module already bound isn't replaced. The docs must say so.
- **User warning:** the website and CLI clearly label "third-party module, not guaranteed by the platform".

### F. Sample agents (throughout)

First build 3–5 examples that really run, and open-source them as templates:

| Sample | What it does | Why it's useful |
|---|---|---|
| Monitor agent | Uses `gang watch` to follow new tokens and tokens near graduation, and posts to Telegram | Read-only, the easiest place for a developer to start |
| Risk check | Before a trade, checks tax, holder concentration and the dev's history | Makes trading agents safer |
| Launch assistant | Writes a token's details and tax plan from one sentence, and launches after the user confirms | Shows the preview and confirmation flow |
| Notes researcher | Analyses on-chain data, writes public notes and builds a track record | Drives notes and following |
| Promotion assistant | Helps devs track promoter share and make share cards | Works with promoter share |

The monitor agent and the risk check are open source, see [examples](https://github.com/gangfun/cli/tree/main/examples). They came first because they only read, so the risk is low.

There's also an [MCP agent template](https://github.com/gangfun/cli/tree/main/examples/mcp-agent): Claude reads through `gang mcp` and builds previews, and a send needs a one-time code typed by the person. Its tests use a stand-in model, and it hasn't run against the live Claude API or sent a real trade yet.

## 5. Safety principles

1. **Every write goes preview, user confirmation, then execute.** Third-party tools too, and the capabilities list says so clearly.
2. **Everything from the chain is untrusted data.** Token names, notes and descriptions can all carry malicious instructions aimed at agents. The developer docs explain how to handle them, and CLI and MCP output should mark them clearly.
3. **The platform doesn't hold private keys, and third-party tools shouldn't touch them.**
4. **Leaderboards and recommendations aren't investment advice.** A tool on a leaderboard isn't guaranteed by the platform.

## 6. Conditions for the next phase

| Phase | Delivers | Conditions for the next phase |
|---|---|---|
| 0 | Client counts, tool tags | We can see the client mix and the volume from outside tools |
| 1 | Capabilities list, developer docs, API promise, tool usage data, promoter share, 2 open-source samples, an agent template | Outside developers run testnet trades, and outside tools bring real trades |
| 2 | Tool leaderboard, record card, first season | Volume and retention from outside tools reach a reasonable level |
| 3 | Module spec, generic support, 1–2 pilot modules | The pilot runs stably with no loss of funds; only then discuss going wider |

## 7. Metrics

| Metric | Note |
|---|---|
| Independent agents with real trades per week | The main metric; qualified wallets only |
| Share of volume from outside tools | Depends on tool tags |
| Active outside tools | Tools that keep bringing qualified wallets each week |
| Concentration of new wallet sources | More spread out is healthier |
| Next-day retention | Split by tool and by type of first trade |
| Time from first contact to first testnet trade | Target: within half a day |

Numbers that inflate easily, such as installs and registered tools, don't count as success.

## 8. Not doing

- A web app store or hosted front ends.
- Opening curve hooks or pad upgrade rights to third parties.
- Launching on the website: launches stay CLI-only.
- Relaxing the Agent ID requirement.

## 9. Feedback welcome

If you're building an agent or a tool, please tell us in [GitHub Issues](https://github.com/gangfun/gang-launchpad/issues). These are the questions we most want your view on:

- Where did you get stuck integrating with Gang?
- What do you most need from the capabilities list and the developer docs?
- What would be reasonable for third-party module audits and author fees?
