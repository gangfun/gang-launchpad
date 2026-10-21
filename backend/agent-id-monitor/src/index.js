import { AgentIdMonitor } from './monitor.js'

const DEFAULT_RPCS = 'https://bsc-rpc.publicnode.com,https://bsc.publicnode.com'
const urls = (process.env.GANG_RPC_URLS || process.env.GANG_RPC_URL || DEFAULT_RPCS)
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean)

const cfg = {
  rpcUrls: urls,
  registry: process.env.GANG_AGENT_ID || '0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F',
  // Near tip is enough for ongoing alerts; raise if you need historical backfill.
  startBlock: Number(process.env.GANG_MONITOR_START_BLOCK || process.env.GANG_START_BLOCK || 0),
  batch: Number(process.env.GANG_BATCH || 50),
  stateFile: process.env.GANG_MONITOR_STATE || './agent-id-monitor.state.json',
  webhook: process.env.GANG_ALERT_WEBHOOK || '',
  logMints: process.env.GANG_ALERT_LOG_MINTS === '1',
  alertMinSeverity: process.env.GANG_ALERT_MIN_SEVERITY || 'medium',
  intervalMs: Number(process.env.GANG_MONITOR_INTERVAL_MS || 5000),
}

if (!cfg.startBlock) {
  console.error('Set GANG_MONITOR_START_BLOCK (or GANG_START_BLOCK) to current tip before first run.')
  process.exit(1)
}

const mon = new AgentIdMonitor(cfg)
const once = process.argv.includes('--once')
console.log(
  `agent-id-monitor registry=${cfg.registry} start=${cfg.startBlock} webhook=${cfg.webhook ? 'yes' : 'no'} logMints=${cfg.logMints}`,
)

try {
  const head = await mon.syncOnce()
  console.log(`synced to ${head}`)
} catch (e) {
  console.error('initial sync failed:', e.message)
  if (once) process.exit(1)
}

if (!once) mon.run(cfg.intervalMs)
