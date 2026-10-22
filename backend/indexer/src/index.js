import { openDb } from './db.js'
import { Indexer } from './indexer.js'
import { StocksIndexer } from './stocksIndexer.js'
import { startApi } from './api.js'
import { refreshHandles } from './handles.js'
import { refreshAgentBuyers, seedBuyersFromTrades } from './agentBuyers.js'

const DEFAULT_RPCS = 'https://bsc-rpc.publicnode.com,https://bsc.publicnode.com'
const urls = (process.env.GANG_RPC_URLS || process.env.GANG_RPC_URL || DEFAULT_RPCS)
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean)

const DEFAULT_STOCKS_RPCS = 'https://bsc-testnet-rpc.publicnode.com,https://data-seed-prebsc-1-s1.binance.org:8545'
const stocksUrls = (process.env.GANG_STOCKS_RPC_URLS || DEFAULT_STOCKS_RPCS)
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean)

const cfg = {
  rpcUrls: urls,
  launchpad: process.env.GANG_LAUNCHPAD || '0x315Ba2e8952D06094CC636b2B84229FA32fb23A7',
  startBlock: Number(process.env.GANG_START_BLOCK || 128977029),
  db: process.env.GANG_DB || './gang.db',
  port: Number(process.env.PORT || 8787),
  batch: Number(process.env.GANG_BATCH || 50),
  stocksLaunchpad: (process.env.GANG_STOCKS_LAUNCHPAD || '').trim(),
  // Chapel LaunchpadS deploy ~138280516; Created at 138280997
  stocksStartBlock: Number(process.env.GANG_STOCKS_START_BLOCK || 138280500),
  stocksRpcUrls: stocksUrls,
  stocksDividendVault: (process.env.GANG_STOCKS_DIVIDEND_VAULT || '').trim().toLowerCase() || null,
  stocksQuote: (process.env.GANG_STOCKS_QUOTE || '').trim().toLowerCase() || null,
  stocksQuoteSymbol: process.env.GANG_STOCKS_QUOTE_SYMBOL || 'SPCXB',
  stocksQuoteLabel: process.env.GANG_STOCKS_QUOTE_LABEL || 'MockSPCXB',
  stocksTaxBps: Number(process.env.GANG_STOCKS_TAX_BPS || 100),
}

const db = openDb(cfg.db)
seedBuyersFromTrades(db)
const ix = new Indexer({ db, rpcUrls: cfg.rpcUrls, launchpad: cfg.launchpad, startBlock: cfg.startBlock, batch: cfg.batch })
const once = process.argv.includes('--once')

const stocksCfg = cfg.stocksLaunchpad
  ? {
      launchpad: cfg.stocksLaunchpad,
      dividendVault: cfg.stocksDividendVault,
      quote: cfg.stocksQuote,
      quoteSymbol: cfg.stocksQuoteSymbol,
      quoteLabel: cfg.stocksQuoteLabel,
      taxBps: cfg.stocksTaxBps,
      startBlock: cfg.stocksStartBlock,
    }
  : null

if (!once) {
  startApi(db, {
    port: cfg.port,
    launchpad: cfg.launchpad,
    rpcUrls: cfg.rpcUrls,
    stocks: stocksCfg,
    stocksRpcUrls: cfg.stocksRpcUrls,
  })
}

try {
  const head = await ix.syncOnce()
  console.log(`synced to block ${head}`)
} catch (e) {
  console.error('initial sync failed:', e.message)
}

let stocksIx = null
if (cfg.stocksLaunchpad) {
  stocksIx = new StocksIndexer({
    db,
    rpcUrls: cfg.stocksRpcUrls,
    launchpad: cfg.stocksLaunchpad,
    startBlock: cfg.stocksStartBlock,
    batch: Number(process.env.GANG_STOCKS_BATCH || 2000),
  })
  try {
    const sh = await stocksIx.syncOnce()
    console.log(`stocks synced to block ${sh}`)
  } catch (e) {
    console.error('stocks initial sync failed:', e.message)
  }
}

if (!once) {
  refreshHandles(db, ix.client).catch((e) => console.error('handle refresh:', e.message))
  refreshAgentBuyers(db, ix.client).catch((e) => console.error('agent buyers:', e.message))
  ix.run()
  if (stocksIx) stocksIx.run()
}
