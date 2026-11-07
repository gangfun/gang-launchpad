import { openDb } from './db.js'
import { Indexer } from './indexer.js'
import { startApi } from './api.js'
import { refreshHandles } from './handles.js'
import { refreshAgentBuyers } from './agentBuyers.js'

const DEFAULT_RPCS = 'https://bsc-rpc.publicnode.com,https://bsc.publicnode.com'
const urls = (process.env.GANG_RPC_URLS || process.env.GANG_RPC_URL || DEFAULT_RPCS)
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean)

const cfg = {
  // Comma-separated GANG_RPC_URLS preferred (viem fallback). Single GANG_RPC_URL still works.
  // Near-head sync (raised GANG_START_BLOCK) does not need archive RPC.
  rpcUrls: urls,
  launchpad: process.env.GANG_LAUNCHPAD || '0x315Ba2e8952D06094CC636b2B84229FA32fb23A7',
  startBlock: Number(process.env.GANG_START_BLOCK || 128977029),
  db: process.env.GANG_DB || './gang.db',
  port: Number(process.env.PORT || 8787),
  batch: Number(process.env.GANG_BATCH || 50),
}
const db = openDb(cfg.db)
const ix = new Indexer({ db, rpcUrls: cfg.rpcUrls, launchpad: cfg.launchpad, startBlock: cfg.startBlock, batch: cfg.batch })
const once = process.argv.includes('--once')
// Serve API immediately so deploys aren't blocked on long backfills.
if (!once) startApi(db, { port: cfg.port, launchpad: cfg.launchpad, rpcUrls: cfg.rpcUrls })
try {
  const head = await ix.syncOnce()
  console.log(`synced to block ${head}`)
} catch (e) {
  console.error('initial sync failed:', e.message)
}
if (!once) {
  refreshHandles(db, ix.client).catch((e) => console.error('handle refresh:', e.message))
  refreshAgentBuyers(db, ix.client).catch((e) => console.error('agent buyer refresh:', e.message))
  ix.run()
}
