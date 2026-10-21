# Agent ID monitor

Watches SPACE ID **HandleRegistry** (`0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F` on BSC) for admin / gate-key events that affect Gang Launchpad’s Agent ID buy gate.

## Why

Launchpad `buy` requires `balanceOf(buyer) > 0` on this registry. The registry owner can:

| Call | Event | Risk |
|---|---|---|
| `adminRegister(handle, to)` | `AdminRegistered` | Mint Agent ID without SPACE ID signature (backdoor) |
| `setSigner(addr)` | `SignerChanged` | New signer can issue valid `register` signatures |
| `transferOwnership` | `OwnershipTransferStarted` / `OwnershipTransferred` | Gate control changes hands |
| `setLengthBounds` / `setURIParts` | corresponding events | Config change (lower urgency) |

Normal user mints emit `Registered` + `Transfer(from=0)`; those are high volume and **not** webhooked unless `GANG_ALERT_LOG_MINTS=1`.

## Run

```bash
cd backend/agent-id-monitor
npm i
GANG_MONITOR_START_BLOCK=<current tip> \
GANG_ALERT_WEBHOOK=https://hooks.example/xxx \
npm start
```

Env (aligned with indexer where possible):

| Var | Default | Notes |
|---|---|---|
| `GANG_RPC_URLS` / `GANG_RPC_URL` | publicnode ×2 | Same as indexer |
| `GANG_AGENT_ID` | `0x60B926…022F` | Registry |
| `GANG_MONITOR_START_BLOCK` | required | Use tip on first deploy |
| `GANG_BATCH` | `50` | getLogs span |
| `GANG_MONITOR_STATE` | `./agent-id-monitor.state.json` | Cursor |
| `GANG_ALERT_WEBHOOK` | empty | POST JSON `{text,severity,event}` |
| `GANG_ALERT_MIN_SEVERITY` | `medium` | `critical`/`high`/`medium`/`low`/`info` |
| `GANG_ALERT_LOG_MINTS` | off | Also log `Registered` / mint `Transfer` |
| `GANG_MONITOR_INTERVAL_MS` | `5000` | Poll interval |

## systemd

See `gang-agent-id-monitor.service`. Copy to `/etc/systemd/system/`, set `GANG_MONITOR_START_BLOCK` to tip, optional webhook, then:

```bash
mkdir -p /var/lib/gang
systemctl enable --now gang-agent-id-monitor
journalctl -u gang-agent-id-monitor -f
```

## Ops response

1. **AdminRegistered / SignerChanged / Ownership\*** → treat as incident; decide whether to `proposeAgentIdRegistry` on Launchpad (24h timelock) or pause marketing until SPACE ID clarifies.
2. Keep webhook private; do not commit secrets.
