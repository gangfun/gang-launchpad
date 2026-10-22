import { createPublicClient, http, fallback } from 'viem'
import { bscTestnet } from 'viem/chains'
import { STOCKS_EVENTS } from './stocksAbi.js'
import { getMeta, setMeta } from './db.js'

/** Test-calibrated curve (LaunchpadS VIRTUAL_*). */
const VIRTUAL_QUOTE = 333_333_333_333_333_333n
const VIRTUAL_TOKEN = 1_066_666_666_666_666_666_666_666_667n
const price = (realQuote, sold) => ((VIRTUAL_QUOTE + realQuote) * 10n ** 18n) / (VIRTUAL_TOKEN - sold)

const META_KEY = 'stocks_last_block'

/**
 * Chapel LaunchpadS indexer → stock_tokens / stock_trades (same SQLite as main track).
 * Never touches main `tokens` / `trades`. chainId 97 only.
 */
export class StocksIndexer {
  constructor({
    db,
    rpcUrls,
    launchpad,
    startBlock,
    batch = 2000,
    log = console.log,
  }) {
    this.db = db
    this.launchpad = launchpad
    this.startBlock = BigInt(startBlock)
    this.batch = BigInt(batch)
    this.log = log
    const urls = (rpcUrls || []).filter(Boolean)
    if (!urls.length) throw new Error('stocks indexer: no RPC urls')
    const transport = urls.length > 1
      ? fallback(urls.map((u) => http(u, { retryCount: 2, retryDelay: 800, timeout: 20_000 })), { rank: false })
      : http(urls[0], { retryCount: 3, retryDelay: 800, timeout: 20_000 })
    this.client = createPublicClient({ chain: bscTestnet, transport })
    this.blockTs = new Map()
    this.stmts = {
      insTok: db.prepare(`INSERT OR IGNORE INTO stock_tokens(
        address,name,symbol,creator,quote,created_block,created_ts,created_tx,last_price
      ) VALUES(?,?,?,?,?,?,?,?,?)`),
      updTok: db.prepare('UPDATE stock_tokens SET real_quote=?, sold=?, last_price=?, trades=trades+1, last_trade_ts=? WHERE address=?'),
      grad: db.prepare('UPDATE stock_tokens SET graduated=1, pair=?, graduated_ts=? WHERE address=?'),
      insTrade: db.prepare(`INSERT OR IGNORE INTO stock_trades(
        token,side,trader,quote_in,tax_div,tax_plat,tokens,real_quote,price,block,ts,tx,log_index
      ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)`),
      getSold: db.prepare('SELECT sold FROM stock_tokens WHERE address=?'),
    }
  }

  async retry(fn, tries = 6) {
    for (let i = 0; ; i++) {
      try { return await fn() } catch (e) {
        if (i >= tries) throw e
        await new Promise((r) => setTimeout(r, 400 * 2 ** i))
      }
    }
  }

  async ts(blockNumber) {
    if (!this.blockTs.has(blockNumber)) {
      const b = await this.retry(() => this.client.getBlock({ blockNumber }))
      this.blockTs.set(blockNumber, Number(b.timestamp))
      if (this.blockTs.size > 5000) this.blockTs.delete(this.blockTs.keys().next().value)
    }
    return this.blockTs.get(blockNumber)
  }

  async syncOnce() {
    let head = await this.retry(() => this.client.getBlockNumber())
    let from = BigInt(getMeta(this.db, META_KEY) ?? (this.startBlock - 1n)) + 1n
    let span = this.batch
    while (from <= head) {
      let to = from + span - 1n > head ? head : from + span - 1n
      let logs
      try {
        logs = await this.client.getLogs({
          address: this.launchpad,
          events: STOCKS_EVENTS,
          fromBlock: from,
          toBlock: to,
        })
      } catch (e) {
        const msg = e.message || ''
        if (/beyond|future block|higher than/i.test(msg)) {
          head = await this.retry(() => this.client.getBlockNumber())
          if (from > head) break
          to = from + span - 1n > head ? head : from + span - 1n
          await new Promise((r) => setTimeout(r, 200))
          continue
        }
        if (/limit|range|too many|exceed/i.test(msg) && span > 50n) {
          span /= 2n
          this.log(`stocks getLogs limited, span -> ${span}`)
          await new Promise((r) => setTimeout(r, 300))
          continue
        }
        throw e
      }
      logs.sort((a, b) => (a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : Number(a.blockNumber - b.blockNumber)))
      for (const l of logs) await this.apply(l)
      setMeta(this.db, META_KEY, to)
      if (logs.length) this.log(`stocks synced ${from}-${to}: ${logs.length} events`)
      from = to + 1n
      if (span < this.batch) span = span * 2n > this.batch ? this.batch : span * 2n
      await new Promise((r) => setTimeout(r, 80))
    }
    return head
  }

  async apply(l) {
    const a = l.args
    const ts = await this.ts(l.blockNumber)
    const tok = a.token.toLowerCase()
    switch (l.eventName) {
      case 'Created':
        this.stmts.insTok.run(
          tok, a.name, a.symbol, a.creator.toLowerCase(), a.quote.toLowerCase(),
          Number(l.blockNumber), ts, l.transactionHash, price(0n, 0n).toString(),
        )
        break
      case 'Buy': {
        const sold = BigInt(this.stmts.getSold.get(tok)?.sold ?? '0') + a.tokensOut
        const p = price(a.realQuote, sold)
        this.stmts.insTrade.run(
          tok, 'buy', a.buyer.toLowerCase(),
          a.quoteIn.toString(), a.taxDividend.toString(), a.taxPlatform.toString(),
          a.tokensOut.toString(), a.realQuote.toString(), p.toString(),
          Number(l.blockNumber), ts, l.transactionHash, l.logIndex,
        )
        this.stmts.updTok.run(a.realQuote.toString(), sold.toString(), p.toString(), ts, tok)
        break
      }
      case 'Sell': {
        const sold = BigInt(this.stmts.getSold.get(tok)?.sold ?? '0') - a.tokensIn
        const p = price(a.realQuote, sold)
        this.stmts.insTrade.run(
          tok, 'sell', a.seller.toLowerCase(),
          a.quoteOut.toString(), a.taxDividend.toString(), a.taxPlatform.toString(),
          a.tokensIn.toString(), a.realQuote.toString(), p.toString(),
          Number(l.blockNumber), ts, l.transactionHash, l.logIndex,
        )
        this.stmts.updTok.run(a.realQuote.toString(), sold.toString(), p.toString(), ts, tok)
        break
      }
      case 'Graduated':
        this.stmts.grad.run(a.pair.toLowerCase(), ts, tok)
        break
    }
  }

  async run(intervalMs = 5000) {
    for (;;) {
      try { await this.syncOnce() } catch (e) { this.log('stocks sync error:', e.message) }
      await new Promise((r) => setTimeout(r, intervalMs))
    }
  }
}
