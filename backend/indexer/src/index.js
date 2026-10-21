import { openDb } from './db.js'
import { Indexer } from './indexer.js'
import { startApi } from './api.js'
import { refreshHandles } from './handles.js'

const DEFAULT_RPCS = 'https://bsc-rpc.publicnode.com,https://bsc.publicnode.com'
const urls = (process.env.GANG_RPC_URLS || process.env.GANG_RPC_URL || DEFAULT_RPCS)
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean)

const cfg = {
  // Comma-separated GANG_RPC_URLS preferred (viem fallback). Single GANG_RPC_URL still works.
  // Near-head sync (raised GANG_START_BLOCK) does not need archive RPC.
  rpcUrls: urls,
  launchpad: process.env.GANG_LAUNCHPAD || '0xBfBB10db587DdFDF38c888cB80C5124f1Aa3C0Eb',
  startBlock: Number(process.env.GANG_START_BLOCK || 0),
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
  ix.run()
}
