import { openDb } from './db.js'
import { Indexer } from './indexer.js'
import { startApi } from './api.js'

const cfg = {
  // Prefer an archive-friendly public RPC in prod (e.g. https://1rpc.io/bnb). publicnode archive often needs a token.
  rpc: process.env.GANG_RPC_URL || 'https://1rpc.io/bnb',
  launchpad: process.env.GANG_LAUNCHPAD || '0xBfBB10db587DdFDF38c888cB80C5124f1Aa3C0Eb',
  startBlock: Number(process.env.GANG_START_BLOCK || 0),
  db: process.env.GANG_DB || './gang.db',
  port: Number(process.env.PORT || 8787),
  batch: Number(process.env.GANG_BATCH || 50),
}
const db = openDb(cfg.db)
const ix = new Indexer({ db, rpc: cfg.rpc, launchpad: cfg.launchpad, startBlock: cfg.startBlock, batch: cfg.batch })
const once = process.argv.includes('--once')
// Serve API immediately so deploys aren't blocked on long backfills.
if (!once) startApi(db, { port: cfg.port, launchpad: cfg.launchpad })
try {
  const head = await ix.syncOnce()
  console.log(`synced to block ${head}`)
} catch (e) {
  console.error('initial sync failed:', e.message)
}
if (!once) ix.run()
