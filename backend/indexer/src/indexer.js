import { createPublicClient, http, fallback, parseAbiItem } from 'viem'
import { bsc } from 'viem/chains'
import { EVENTS } from './abi.js'
import { getMeta, setMeta } from './db.js'
import { refreshHandles } from './handles.js'
import { noteCurveBuyer, refreshAgentBuyers } from './agentBuyers.js'

const VIRTUAL_BNB = 6666666666666666667n
const VIRTUAL_TOKEN = 1066666666666666666666666667n
const price = (realBnb, sold) => ((VIRTUAL_BNB + realBnb) * 10n ** 18n) / (VIRTUAL_TOKEN - sold) // wei per token

export class Indexer {
  constructor({ db, rpc, rpcUrls, launchpad, startBlock, batch = 1000, log = console.log }) {
    this.db = db; this.launchpad = launchpad; this.startBlock = BigInt(startBlock); this.batch = BigInt(batch); this.log = log
    const urls = (rpcUrls && rpcUrls.length ? rpcUrls : [rpc]).filter(Boolean)
    const transport = urls.length > 1
      ? fallback(urls.map((u) => http(u, { retryCount: 2, retryDelay: 800 })), { rank: true, retryCount: 3 })
      : http(urls[0], { retryCount: 3, retryDelay: 800 })
    this.client = createPublicClient({ chain: bsc, transport })
    this.blockTs = new Map()
    this.stmts = {
      insTok: db.prepare('INSERT OR IGNORE INTO tokens(address,name,symbol,creator,created_block,created_ts,created_tx,last_price) VALUES(?,?,?,?,?,?,?,?)'),
      updTok: db.prepare('UPDATE tokens SET real_bnb=?, sold=?, last_price=?, trades=trades+1, last_trade_ts=? WHERE address=?'),
      grad: db.prepare("UPDATE tokens SET graduated=1, pair=?, graduated_ts=?, real_bnb='20000000000000000000' WHERE address=?"),
      insTrade: db.prepare('INSERT OR IGNORE INTO trades(token,side,trader,bnb,fee,tokens,real_bnb,price,block,ts,tx,log_index) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)'),
      getSold: db.prepare('SELECT sold FROM tokens WHERE address=?'),
      holder: db.prepare('INSERT INTO holders(token,holder,balance) VALUES(?,?,?) ON CONFLICT(token,holder) DO UPDATE SET balance=excluded.balance'),
      getHolder: db.prepare('SELECT balance FROM holders WHERE token=? AND holder=?'),
    }
  }

  async retry(fn, tries = 6) {
    for (let i = 0; ; i++) {
      try { return await fn() } catch (e) { if (i >= tries) throw e; await new Promise((r) => setTimeout(r, 400 * 2 ** i)) }
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
    let from = BigInt(getMeta(this.db, 'last_block') ?? (this.startBlock - 1n)) + 1n
    let span = this.batch
    let beyondHits = 0
    while (from <= head) {
      let to = from + span - 1n > head ? head : from + span - 1n
      let logs
      try {
        logs = await this.client.getLogs({ address: this.launchpad, events: EVENTS, fromBlock: from, toBlock: to })
        beyondHits = 0
      } catch (e) {
        const msg = e.message || ''
        if (/beyond|future block|higher than/i.test(msg)) {
          // tip moved between getBlockNumber and getLogs — refresh head, clamp to, retry
          const h = await this.retry(() => this.client.getBlockNumber())
          head = h
          if (from > h) break
          to = to > h ? h : to
          beyondHits += 1
          if (beyondHits >= 2 && span > 50n) {
            span = span / 2n > 50n ? span / 2n : 50n
            this.log(`getLogs beyond head x${beyondHits}, span -> ${span}, tip -> ${h}`)
          } else {
            this.log(`getLogs beyond head, clamp to=${to}, tip -> ${h}`)
          }
          // recompute to from from+span capped by refreshed head
          to = from + span - 1n > head ? head : from + span - 1n
          await new Promise((r) => setTimeout(r, 200))
          continue
        }
        if (/limit|range|too many|exceed/i.test(msg) && span > 50n) { span /= 2n; this.log(`getLogs limited, span -> ${span}`); await new Promise((r) => setTimeout(r, 500)); continue }
        throw e
      }
      logs.sort((a, b) => (a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : Number(a.blockNumber - b.blockNumber)))
      for (const l of logs) await this.apply(l)
      setMeta(this.db, 'last_block', to)
      if (logs.length) this.log(`synced ${from}-${to}: ${logs.length} events`)
      from = to + 1n
      if (span < this.batch) span = span * 2n > this.batch ? this.batch : span * 2n
      await new Promise((r) => setTimeout(r, 120))
    }
    return head
  }

  async apply(l) {
    const a = l.args; const ts = await this.ts(l.blockNumber); const tok = a.token.toLowerCase()
    switch (l.eventName) {
      case 'Created':
        this.stmts.insTok.run(tok, a.name, a.symbol, a.creator.toLowerCase(), Number(l.blockNumber), ts, l.transactionHash, price(0n, 0n).toString())
        break
      case 'Buy': {
        const sold = BigInt(this.stmts.getSold.get(tok)?.sold ?? '0') + a.tokensOut
        const p = price(a.realBnb, sold)
        this.stmts.insTrade.run(tok, 'buy', a.buyer.toLowerCase(), a.bnbIn.toString(), a.fee.toString(), a.tokensOut.toString(), a.realBnb.toString(), p.toString(), Number(l.blockNumber), ts, l.transactionHash, l.logIndex)
        this.stmts.updTok.run(a.realBnb.toString(), sold.toString(), p.toString(), ts, tok)
        this.bump(tok, a.buyer.toLowerCase(), a.tokensOut)
        noteCurveBuyer(this.db, a.buyer, ts)
        break
      }
      case 'Sell': {
        const sold = BigInt(this.stmts.getSold.get(tok)?.sold ?? '0') - a.tokensIn
        const p = price(a.realBnb, sold)
        this.stmts.insTrade.run(tok, 'sell', a.seller.toLowerCase(), a.bnbOut.toString(), a.fee.toString(), a.tokensIn.toString(), a.realBnb.toString(), p.toString(), Number(l.blockNumber), ts, l.transactionHash, l.logIndex)
        this.stmts.updTok.run(a.realBnb.toString(), sold.toString(), p.toString(), ts, tok)
        this.bump(tok, a.seller.toLowerCase(), -a.tokensIn)
        break
      }
      case 'Graduated':
        this.stmts.grad.run(a.pair.toLowerCase(), ts, tok)
        break
    }
  }

  bump(token, holder, delta) {
    const cur = BigInt(this.stmts.getHolder.get(token, holder)?.balance ?? '0')
    this.stmts.holder.run(token, holder, (cur + delta).toString())
  }

  async run(intervalMs = 3000) {
    let handleTick = 0
    for (;;) {
      try { await this.syncOnce() } catch (e) { this.log('sync error:', e.message) }
      // Agent ID handleOf cache — every ~5 sync cycles, non-blocking for API.
      if (++handleTick % 5 === 0) {
        try { await refreshHandles(this.db, this.client, { log: this.log }) } catch (e) { this.log('handle refresh:', e.message) }
        try { await refreshAgentBuyers(this.db, this.client, { log: this.log }) } catch (e) { this.log('agent buyer refresh:', e.message) }
      }
      await new Promise((r) => setTimeout(r, intervalMs))
    }
  }
}
