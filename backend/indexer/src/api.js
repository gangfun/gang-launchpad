import http from 'node:http'
import fs from 'node:fs'
import { formatEther } from 'viem'
import { getHandleMap, makeClient, makeStocksClient } from './handles.js'
import { countAgentBuyers, refreshAgentBuyers, seedBuyersFromTrades } from './agentBuyers.js'
import { getMeta } from './db.js'
import { readPair, fetchDexOhlcv, fetchSwapOhlcv, mergeCurveAndDex, sumDexVolume24hBnb } from './pancake.js'
import { getGraduatedHolderStats } from './holdersLive.js'
import {
  getLogoMap, initMediaTable, logoFilePath, parseDataUrl, saveTokenLogo, setLogoRow,
} from './media.js'

async function readJson(req, maxBytes = 700_000) {
  const chunks = []
  let n = 0
  for await (const chunk of req) {
    n += chunk.length
    if (n > maxBytes) throw new Error('body too large')
    chunks.push(chunk)
  }
  if (!chunks.length) return {}
  return JSON.parse(Buffer.concat(chunks).toString('utf8'))
}

const ADDR_RE = /^0x[a-fA-F0-9]{40}$/

const GRAD = 20n * 10n ** 18n
const fmtTok = (s) => formatEther(BigInt(s))
const tokRow = (r) => {
  const graduated = !!r.graduated
  // Graduated curve is full: never show 0/20 (indexer used to zero real_bnb on Graduated)
  const raisedWei = graduated ? GRAD : BigInt(r.real_bnb || '0')
  return {
    address: r.address, name: r.name, symbol: r.symbol, creator: r.creator,
    createdAt: r.created_ts, createdTx: r.created_tx,
    graduated, pair: r.pair, graduatedAt: r.graduated_ts,
    raisedBnb: formatEther(raisedWei), progressPct: graduated ? 100 : Number((raisedWei * 10000n) / GRAD) / 100,
    soldTokens: fmtTok(r.sold), priceBnb: formatEther(BigInt(r.last_price)), fdvBnb: formatEther(BigInt(r.last_price) * 1000000000n),
    trades: r.trades, lastTradeAt: r.last_trade_ts,
    volume24hBnb: r.vol24 != null ? formatEther(BigInt(r.vol24)) : undefined,
    trades24h: r.n24, holders: r.holders,
  }
}


const GRAD_QUOTE = 10n ** 18n // Chapel test graduation ≈ 1 MockSPCXB
const stockRow = (r, stocks) => {
  const graduated = !!r.graduated
  const raisedWei = graduated ? GRAD_QUOTE : BigInt(r.real_quote || '0')
  const quote = (r.quote || stocks?.quote || '').toLowerCase()
  const quoteIsMock = stocks?.quote && quote === stocks.quote
  return {
    track: 'stocks',
    address: r.address,
    name: r.name,
    symbol: r.symbol,
    creator: r.creator,
    createdAt: r.created_ts,
    createdTx: r.created_tx,
    graduated,
    pair: r.pair,
    graduatedAt: r.graduated_ts,
    quoteAddress: quote || null,
    quoteSymbol: stocks?.quoteSymbol || 'SPCXB',
    quoteLabel: quoteIsMock ? (stocks?.quoteLabel || 'MockSPCXB') : (stocks?.quoteSymbol || 'SPCXB'),
    taxBps: stocks?.taxBps || 100,
    divSplit: '50/50',
    dividendVault: stocks?.dividendVault || null,
    raisedQuote: formatEther(raisedWei),
    progressPct: graduated ? 100 : Number((raisedWei * 10000n) / GRAD_QUOTE) / 100,
    soldTokens: fmtTok(r.sold),
    priceQuote: formatEther(BigInt(r.last_price || '0')),
    // Keep fdvBnb/volume24hBnb nullish so FE does not invent BNB mcap for stocks
    fdvBnb: 0,
    volume24hBnb: 0,
    trades: r.trades,
    lastTradeAt: r.last_trade_ts,
    pairLabel: r.pair
      ? `${r.symbol}/${stocks?.quoteSymbol || 'SPCXB'}`
      : `${r.symbol}/${stocks?.quoteSymbol || 'SPCXB'}`,
    chainId: 97,
    explorer: 'https://testnet.bscscan.com',
  }
}


function sendJson(res, code, body, opts = {}) {
  const headers = { 'content-type': 'application/json', 'access-control-allow-origin': '*' }
  if (opts.noStore) headers['cache-control'] = 'no-store'
  res.writeHead(code, headers); res.end(JSON.stringify(body))
}

function stockCandlesFromTrades(db, addr, resSec, since, createdTs, openPriceWei) {
  const out = []
  let cur = null
  const open0 = Number(formatEther(BigInt(openPriceWei || '6250000000')))
  const t0 = Math.floor((createdTs || 0) / resSec) * resSec
  if (t0 >= since) cur = { t: t0, o: open0, h: open0, l: open0, c: open0, v: 0 }
  const rows = db.prepare(
    `SELECT (CAST(ts AS INTEGER) / CAST(? AS INTEGER)) * CAST(? AS INTEGER) AS t, price, quote_in, id
     FROM stock_trades WHERE token=? AND ts>=? ORDER BY id`,
  ).all(resSec, resSec, addr, since)
  for (const r of rows) {
    const px = Number(formatEther(BigInt(r.price)))
    const v = Number(formatEther(BigInt(r.quote_in || '0')))
    if (!cur || cur.t !== r.t) {
      if (cur) out.push(cur)
      const o = cur ? cur.c : px
      cur = { t: r.t, o, h: Math.max(o, px), l: Math.min(o, px), c: px, v }
    } else {
      cur.h = Math.max(cur.h, px)
      cur.l = Math.min(cur.l, px)
      cur.c = px
      cur.v += v
    }
  }
  if (cur) out.push(cur)
  return out
}

async function respondStockToken(db, res, addr, stocks, stocksClient, p, url, limit) {
  const dayAgo = Math.floor(Date.now() / 1000) - 86400
  const r = db.prepare(`
    SELECT t.*,
      (SELECT SUM(CAST(quote_in AS REAL)) FROM stock_trades WHERE token=t.address AND ts>?) AS vol24,
      (SELECT COUNT(*) FROM stock_trades WHERE token=t.address AND ts>?) AS n24
    FROM stock_tokens t WHERE t.address=?
  `).get(dayAgo, dayAgo, addr)
  if (!r) return false
  const logos = getLogoMap(db, [addr])
  const base = {
    ...stockRow(r, stocks),
    volume24hQuote: r.vol24 != null ? formatEther(BigInt(Math.round(Number(r.vol24)))) : '0',
    trades24h: r.n24 || 0,
    logoUrl: logos[addr] ? `/tokens/${addr}/logo` : undefined,
    creatorUrl: r.creator ? `https://testnet.bscscan.com/address/${r.creator}` : null,
  }
  // Live pair spot (quote per token) when graduated
  if (r.graduated && r.pair && stocksClient) {
    try {
      const pk = await readPair(stocksClient, r.pair, addr)
      if (pk?.priceBnb > 0) {
        base.priceQuote = String(pk.priceBnb)
        base.pancake = {
          ...pk,
          quoteSymbol: stocks?.quoteSymbol || 'SPCXB',
          pancakeUrl: `https://testnet.bscscan.com/address/${r.pair}`,
          pairUrl: `https://testnet.bscscan.com/address/${r.pair}`,
          infoUrl: `https://testnet.bscscan.com/address/${r.pair}`,
        }
      }
    } catch { /* ignore */ }
  }
  if (!p[2]) {
    sendJson(res, 200, base)
    return true
  }
  if (p[2] === 'trades') {
    const offset = Math.max(0, Math.min(Number(url.searchParams.get('offset') || 0) || 0, 10_000))
    const sideRaw = (url.searchParams.get('side') || 'all').toLowerCase()
    const side = sideRaw === 'buy' || sideRaw === 'sell' ? sideRaw : 'all'
    const sortRaw = (url.searchParams.get('sort') || 'ts_desc').toLowerCase()
    const sorts = {
      ts_desc: 'ts DESC, id DESC',
      ts_asc: 'ts ASC, id ASC',
      amount_desc: 'CAST(quote_in AS REAL) DESC, id DESC',
    }
    const sort = sorts[sortRaw] ? sortRaw : 'ts_desc'
    const sideClause = side === 'all' ? '' : ' AND side=?'
    const stmt = db.prepare(
      `SELECT side,trader,quote_in,tax_div,tax_plat,tokens,price,block,ts,tx FROM stock_trades WHERE token=?${sideClause} ORDER BY ${sorts[sort]} LIMIT ? OFFSET ?`,
    )
    const args = side === 'all' ? [addr, limit + 1, offset] : [addr, side, limit + 1, offset]
    const raw = stmt.all(...args)
    const hasMore = raw.length > limit
    const rows = hasMore ? raw.slice(0, limit) : raw
    sendJson(res, 200, {
      items: rows.map((x) => ({
        side: x.side,
        trader: x.trader,
        bnb: formatEther(BigInt(x.quote_in || '0')), // FE column reused as quote amount
        fee: formatEther(BigInt((BigInt(x.tax_div || '0') + BigInt(x.tax_plat || '0')).toString())),
        tokens: fmtTok(x.tokens),
        price: formatEther(BigInt(x.price || '0')),
        block: x.block,
        ts: x.ts,
        tx: x.tx,
        quote: true,
      })),
      hasMore,
      nextOffset: hasMore ? offset + limit : null,
      limit,
      offset,
      side,
      sort,
      track: 'stocks',
    })
    return true
  }
  if (p[2] === 'holders') {
    // Stocks holders not indexed yet — empty honest response
    sendJson(res, 200, { items: [], hasMore: false, nextOffset: null, limit, offset: 0, track: 'stocks', note: 'stocks holders not indexed' })
    return true
  }
  if (p[2] === 'candles') {
    const tf = (url.searchParams.get('res') || url.searchParams.get('interval') || '5m').toLowerCase()
    const res_ = { '1m': 60, '5m': 300, '15m': 900, '1h': 3600, '4h': 14400, '1d': 86400 }[tf] || 300
    const since = Number(url.searchParams.get('since') || 0)
    const curve = stockCandlesFromTrades(db, addr, res_, since, r.created_ts, r.last_price || '6250000000')
    let out = curve
    // Graduated Chapel: no GeckoTerminal — best-effort Swap logs on MockPair.
    // If DEX empty (common on Chapel mock pairs), keep curve candles (merge drops the
    // graduation bucket when dex=[] and live=0).
    if (r.graduated && r.pair && stocksClient) {
      const dex = await fetchSwapOhlcv(stocksClient, {
        pair: r.pair,
        token: addr,
        fromTs: r.graduated_ts || r.created_ts,
        resSec: res_,
        maxBlocks: 12_000n,
      })
      let live = 0
      try {
        const pk = await readPair(stocksClient, r.pair, addr)
        live = pk?.priceBnb > 0 ? pk.priceBnb : 0
      } catch { /* ignore */ }
      const merged = mergeCurveAndDex(curve, dex, r.graduated_ts, res_, live)
      out = (merged && merged.length) ? merged : curve
    }
    sendJson(res, 200, out, { noStore: true })
    return true
  }
  return false
}

let bnbUsd = 0
async function pollBnb() {
  try { const r = await fetch('https://api.binance.com/api/v3/ticker/price?symbol=BNBUSDT'); const j = await r.json(); if (j.price) bnbUsd = Number(j.price) } catch { /* keep last */ }
}
pollBnb(); setInterval(pollBnb, 60_000)

export function startApi(db, { port = 8787, launchpad, rpcUrls, stocks = null, stocksRpcUrls = null }) {
  initMediaTable(db)
  const client = makeClient(rpcUrls)
  const stocksClient = stocksRpcUrls?.length ? makeStocksClient(stocksRpcUrls) : null
  seedBuyersFromTrades(db)
  let agentBuyerRefresh = 0
  const maybeRefreshAgentBuyers = async () => {
    const now = Date.now()
    if (now - agentBuyerRefresh < 25_000) return
    agentBuyerRefresh = now
    try { await refreshAgentBuyers(db, client, { limit: 60 }) } catch { /* non-fatal */ }
  }

  /** Graduated + pair → overwrite priceBnb/fdvBnb from Pancake (readPair has 30s TTL). Curve tokens unchanged. */
  async function withDexPrice(row, { includePancake = false } = {}) {
    if (!row?.graduated || !row.pair) return row
    const pk = await readPair(client, row.pair, row.address)
    const out = { ...row }
    if (pk && pk.priceBnb > 0) {
      out.priceBnb = String(pk.priceBnb)
      out.fdvBnb = String(pk.fdvBnb)
      out.priceSource = 'pancake'
    }
    if (includePancake) {
      out.pancake = pk || {
        pair: row.pair,
        pairUrl: `https://bscscan.com/address/${row.pair}`,
        pancakeUrl: `https://pancakeswap.finance/swap?outputCurrency=${row.address}&chain=bsc`,
        infoUrl: `https://pancakeswap.finance/info/v2/pairs/${row.pair}`,
      }
    }
    return out
  }

  /** Post-graduation KPIs: DEX 24h volume; on detail, live holder totals split by Agent ID. */
  async function withGraduatedKpis(row, { detail = false } = {}) {
    if (!row?.graduated || !row.pair) return row
    const out = { ...row }
    const vol = await sumDexVolume24hBnb(row.pair)
    if (vol != null && Number.isFinite(vol)) {
      out.volume24hBnb = String(vol)
      out.volumeSource = 'dex'
    }
    if (detail) {
      const hs = await getGraduatedHolderStats(db, client, {
        token: row.address,
        pair: row.pair,
        graduatedTs: row.graduatedAt,
      })
      if (hs) {
        out.holders = hs.holders
        out.holdersAgent = hs.holdersAgent
        out.holdersOther = hs.holdersOther
        out.holdersSource = 'onchain'
      }
    }
    return out
  }

  const q = {
    list: (order, where = '1=1') => db.prepare(`
      SELECT t.*, (SELECT SUM(CAST(bnb AS REAL)) FROM trades WHERE token=t.address AND ts>?) AS vol24,
             (SELECT COUNT(*) FROM trades WHERE token=t.address AND ts>?) AS n24,
             (SELECT COUNT(*) FROM holders WHERE token=t.address AND balance!='0') AS holders
      FROM tokens t WHERE ${where} ORDER BY ${order} LIMIT ? OFFSET ?`),
    one: db.prepare(`SELECT t.*, (SELECT COUNT(*) FROM holders WHERE token=t.address AND balance!='0') AS holders,
             (SELECT SUM(CAST(bnb AS REAL)) FROM trades WHERE token=t.address AND ts>?) AS vol24,
             (SELECT COUNT(*) FROM trades WHERE token=t.address AND ts>?) AS n24 FROM tokens t WHERE address=?`),
    candles: db.prepare(`SELECT (CAST(ts AS INTEGER) / CAST(? AS INTEGER)) * CAST(? AS INTEGER) AS t, price, bnb, id FROM trades WHERE token=? AND ts>=? ORDER BY id`),
    search: db.prepare(`SELECT address, name, symbol, graduated, pair, last_price FROM tokens
             WHERE lower(address) LIKE ? OR lower(symbol) LIKE ? OR lower(name) LIKE ? ORDER BY trades DESC, created_ts DESC LIMIT 8`),
    stats: db.prepare(`SELECT (SELECT COUNT(*) FROM tokens) AS tokens, (SELECT COUNT(*) FROM tokens WHERE graduated=1) AS graduated,
             (SELECT COUNT(*) FROM trades) AS trades, (SELECT SUM(CAST(bnb AS REAL)) FROM trades WHERE ts>?) AS vol24,
             (SELECT SUM(CAST(fee AS REAL)) FROM trades) AS fees`),
  }
  const json = sendJson
  const day = () => Math.floor(Date.now() / 1000) - 86400

  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://x'); const p = url.pathname.split('/').filter(Boolean)
    const limit = Math.min(Number(url.searchParams.get('limit') || 50), 200)
    try {
      if (p[0] === 'health') {
        const lastBlock = Number(getMeta(db, 'last_block') || 0)
        const tokens = Number(db.prepare('SELECT COUNT(*) AS n FROM tokens').get()?.n || 0)
        let rpcOk = false
        try {
          await Promise.race([
            client.getBlockNumber(),
            new Promise((_, rej) => setTimeout(() => rej(new Error('rpc timeout')), 3000)),
          ])
          rpcOk = true
        } catch { /* leave false */ }
        const stockTokens = Number(db.prepare('SELECT COUNT(*) AS n FROM stock_tokens').get()?.n || 0)
        const stocksLastBlock = Number(getMeta(db, 'stocks_last_block') || 0)
        return json(res, 200, {
          ok: true, launchpad, lastBlock, tokens, rpcOk,
          stockTokens, stocksLastBlock, stocksLaunchpad: stocks?.launchpad || null,
          apiSource: 'local',
        })
      }
      if (p[0] === 'search') {
        const qs = (url.searchParams.get('q') || '').trim().toLowerCase()
        if (qs.length < 2) return json(res, 200, [])
        const like = qs.startsWith('0x') ? `${qs}%` : `%${qs}%`
        const hits = q.search.all(like, like, like).map((r) => ({
          address: r.address, name: r.name, symbol: r.symbol, graduated: !!r.graduated, pair: r.pair,
          priceBnb: formatEther(BigInt(r.last_price)),
        }))
        return json(res, 200, await Promise.all(hits.map(async (r) => withGraduatedKpis(await withDexPrice(r)))))
      }
      if (p[0] === 'stats' && !p[1]) {
        void maybeRefreshAgentBuyers()
        const s = q.stats.get(day())
        const stockTokens = Number(db.prepare('SELECT COUNT(*) AS n FROM stock_tokens').get()?.n || 0)
        return json(res, 200, {
          launchpad, bnbUsd, ...s,
          vol24: s.vol24 ? formatEther(BigInt(Math.round(s.vol24))) : '0',
          fees: s.fees ? formatEther(BigInt(Math.round(s.fees))) : '0',
          agentBuyers: countAgentBuyers(db),
          stockTokens,
          apiSource: 'local',
        })
      }
      if (p[0] === 'stats' && p[1] === 'agent-buyers') {
        await maybeRefreshAgentBuyers()
        return json(res, 200, { agentBuyers: countAgentBuyers(db), launchpad })
      }

      if (p[0] === 'stocks' && p[1] === 'tokens' && !p[2]) {
        if (!stocks?.launchpad) return json(res, 200, { items: [], hasMore: false, nextOffset: null, limit, offset: 0 })
        const offset = Math.max(0, Math.min(Number(url.searchParams.get('offset') || 0) || 0, 10_000))
        const raw = db.prepare(`
          SELECT t.*,
            (SELECT SUM(CAST(quote_in AS REAL)) FROM stock_trades WHERE token=t.address AND ts>?) AS vol24,
            (SELECT COUNT(*) FROM stock_trades WHERE token=t.address AND ts>?) AS n24
          FROM stock_tokens t
          ORDER BY COALESCE(last_trade_ts, created_ts) DESC
          LIMIT ? OFFSET ?
        `).all(day(), day(), limit + 1, offset)
        const hasMore = raw.length > limit
        const page = hasMore ? raw.slice(0, limit) : raw
        const logos = getLogoMap(db, page.map((r) => r.address))
        const items = page.map((r) => {
          const row = stockRow(r, stocks)
          const logo = logos[r.address.toLowerCase()]
          return {
            ...row,
            volume24hQuote: r.vol24 ? formatEther(BigInt(Math.round(r.vol24))) : '0',
            trades24h: r.n24 || 0,
            logoUrl: logo ? `/tokens/${r.address}/logo` : undefined,
          }
        })
        return json(res, 200, {
          items, hasMore, nextOffset: hasMore ? offset + items.length : null, limit, offset, track: 'stocks',
        })
      }
      if (p[0] === 'tokens' && !p[1]) {
        const sort = url.searchParams.get('sort') || 'new'
        const offset = Math.max(0, Math.min(Number(url.searchParams.get('offset') || 0) || 0, 10_000))
        const orders = { new: 'created_ts DESC', hot: 'vol24 DESC, n24 DESC, created_ts DESC', graduated: 'graduated_ts DESC', progress: 'CAST(real_bnb AS REAL) DESC' }
        // hot/new keep graduated visible (badge); progress = curve-only; graduated tab = graduated-only
        const where = sort === 'graduated' ? 'graduated=1' : sort === 'progress' ? 'graduated=0' : '1=1'
        const orderSql = orders[sort] || orders.new
        const pin = (process.env.GANG_PLATFORM_TOKEN || '0x0c6302401aa5325C2E36F170f52C00B1d220B405').toLowerCase()
        const enrich = async (rows) => {
          const handles = getHandleMap(db, rows.map((r) => r.creator))
          const logos = getLogoMap(db, rows.map((r) => r.address))
          const mapped = rows.map((r) => ({
            ...tokRow(r),
            volume24hBnb: r.vol24 ? formatEther(BigInt(Math.round(r.vol24))) : '0',
            creatorHandle: handles[r.creator] || null,
            logoUrl: logos[r.address.toLowerCase()] ? `/tokens/${r.address}/logo` : undefined,
          }))
          // Graduated list rows get live Pancake price/mcap (cached 30s in readPair)
          return Promise.all(mapped.map(async (r) => withGraduatedKpis(await withDexPrice(r))))
        }
        const hotSort = (priced) => {
          priced.sort((a, b) => {
            const va = Number(a.volume24hBnb || 0), vb = Number(b.volume24hBnb || 0)
            if (vb !== va) return vb - va
            return Number(b.fdvBnb || 0) - Number(a.fdvBnb || 0)
          })
          return priced
        }

        let items
        let hasMore
        if (sort === 'hot') {
          // Pin GANG on page 1 only; exclude it from the rest stream so it never duplicates.
          const pinRows = q.list(orderSql, `(${where}) AND lower(address)='${pin}'`).all(day(), day(), 1, 0)
          const pinPresent = pinRows.length > 0
          const restWhere = `(${where}) AND lower(address)!='${pin}'`
          const restOffset = pinPresent ? Math.max(0, offset === 0 ? 0 : offset - 1) : offset
          const wantRest = pinPresent && offset === 0 ? Math.max(0, limit - 1) : limit
          const restRaw = q.list(orderSql, restWhere).all(day(), day(), wantRest + 1, restOffset)
          hasMore = restRaw.length > wantRest
          const restPage = hasMore ? restRaw.slice(0, wantRest) : restRaw
          items = hotSort(await enrich(restPage))
          if (offset === 0 && pinPresent) {
            const [pinItem] = await enrich(pinRows)
            items = [pinItem, ...items]
          }
        } else {
          const raw = q.list(orderSql, where).all(day(), day(), limit + 1, offset)
          hasMore = raw.length > limit
          items = await enrich(hasMore ? raw.slice(0, limit) : raw)
        }
        return json(res, 200, {
          items,
          hasMore,
          nextOffset: hasMore ? offset + items.length : null,
          limit,
          offset,
          sort,
        })
      }
      if (p[0] === 'tokens' && p[1]) {
        const addr = p[1].toLowerCase()
        if (p[2] === 'logo') {
          if (req.method === 'POST') {
            if (!ADDR_RE.test(addr)) return json(res, 400, { error: 'invalid address' })
            const exists = db.prepare('SELECT 1 FROM tokens WHERE address=?').get(addr)
              || db.prepare('SELECT 1 FROM stock_tokens WHERE address=?').get(addr)
            if (!exists) return json(res, 404, { error: 'token not indexed yet' })
            const body = await readJson(req)
            const parsed = parseDataUrl(body.image)
            if (!parsed) return json(res, 400, { error: 'expected data:image/*;base64,... (max 512KB)' })
            const saved = saveTokenLogo(addr, parsed)
            setLogoRow(db, addr, parsed.mime, saved.file)
            return json(res, 200, { ok: true, address: addr, logoUrl: `/tokens/${addr}/logo`, bytes: saved.bytes })
          }
          if (req.method !== 'GET') return json(res, 405, { error: 'method not allowed' })
          const logos = getLogoMap(db, [addr])
          if (!logos[addr]) return json(res, 404, { error: 'no logo' })
          const full = logoFilePath(addr)
          if (!full) return json(res, 404, { error: 'no logo file' })
          const mime = logos[addr].mime || 'image/png'
          res.writeHead(200, {
            'content-type': mime,
            'cache-control': 'public, max-age=300',
            'access-control-allow-origin': '*',
          })
          return res.end(fs.readFileSync(full))
        }
        const t = q.one.get(day(), day(), addr)
        if (!t) {
          const handled = await respondStockToken(db, res, addr, stocks, stocksClient, p, url, limit)
          if (handled) return
          return json(res, 404, { error: 'not found' })
        }
        if (!p[2]) {
          const handles = getHandleMap(db, [t.creator])
          const logos = getLogoMap(db, [addr])
          const body = await withGraduatedKpis(await withDexPrice({
            ...tokRow(t),
            volume24hBnb: t.vol24 ? formatEther(BigInt(Math.round(t.vol24))) : '0',
            creatorHandle: handles[t.creator] || null,
            creatorUrl: t.creator ? `https://bscscan.com/address/${t.creator}` : null,
            logoUrl: logos[addr] ? `/tokens/${addr}/logo` : undefined,
          }, { includePancake: true }), { detail: true })
          return json(res, 200, body)
        }
        if (p[2] === 'trades') {
          const offset = Math.max(0, Math.min(Number(url.searchParams.get('offset') || 0) || 0, 10_000))
          const sideRaw = (url.searchParams.get('side') || 'all').toLowerCase()
          const side = sideRaw === 'buy' || sideRaw === 'sell' ? sideRaw : 'all'
          const sortRaw = (url.searchParams.get('sort') || 'ts_desc').toLowerCase()
          const sorts = {
            ts_desc: 'ts DESC, id DESC',
            ts_asc: 'ts ASC, id ASC',
            amount_desc: 'CAST(bnb AS REAL) DESC, id DESC',
          }
          const sort = sorts[sortRaw] ? sortRaw : 'ts_desc'
          const sideClause = side === 'all' ? '' : ' AND side=?'
          const stmt = db.prepare(
            `SELECT side,trader,bnb,fee,tokens,price,block,ts,tx FROM trades WHERE token=?${sideClause} ORDER BY ${sorts[sort]} LIMIT ? OFFSET ?`,
          )
          const args = side === 'all' ? [addr, limit + 1, offset] : [addr, side, limit + 1, offset]
          const raw = stmt.all(...args)
          const hasMore = raw.length > limit
          const rows = hasMore ? raw.slice(0, limit) : raw
          const handles = getHandleMap(db, rows.map((r) => r.trader))
          return json(res, 200, {
            items: rows.map((r) => ({
              ...r,
              bnb: formatEther(BigInt(r.bnb)), fee: formatEther(BigInt(r.fee)), tokens: fmtTok(r.tokens), price: formatEther(BigInt(r.price)),
              traderHandle: handles[r.trader] || null,
            })),
            hasMore,
            nextOffset: hasMore ? offset + limit : null,
            limit,
            offset,
            side,
            sort,
          })
        }
        if (p[2] === 'holders') {
          const offset = Math.max(0, Math.min(Number(url.searchParams.get('offset') || 0) || 0, 10_000))
          const raw = db.prepare(
            "SELECT holder, balance FROM holders WHERE token=? AND balance!='0' ORDER BY CAST(balance AS REAL) DESC LIMIT ? OFFSET ?",
          ).all(addr, limit + 1, offset)
          const hasMore = raw.length > limit
          const rows = hasMore ? raw.slice(0, limit) : raw
          const handles = getHandleMap(db, rows.map((r) => r.holder))
          return json(res, 200, {
            items: rows.map((r) => ({
              holder: r.holder, balance: fmtTok(r.balance),
              pct: Number(BigInt(r.balance) * 10000n / 10n ** 27n) / 100,
              handle: handles[r.holder] || null,
            })),
            hasMore,
            nextOffset: hasMore ? offset + limit : null,
            limit,
            offset,
          })
        }
        if (p[2] === 'candles') {
          // Accept res= (frontend) and interval= (alias); map UI labels → seconds
          const tf = (url.searchParams.get('res') || url.searchParams.get('interval') || '5m').toLowerCase()
          const res_ = { '1m': 60, '5m': 300, '15m': 900, '1h': 3600, '4h': 14400, '1d': 86400 }[tf] || 300
          const since = Number(url.searchParams.get('since') || 0)
          const out = []; let cur = null
          // opening candle at creation so a token with no trades still has a chart (curve opens at 6.25e-9 BNB)
          const open0 = Number(formatEther(6250000000n)); const t0 = Math.floor(t.created_ts / res_) * res_
          if (t0 >= since) cur = { t: t0, o: open0, h: open0, l: open0, c: open0, v: 0 }
          for (const r of q.candles.all(res_, res_, addr, since)) {
            const px = Number(formatEther(BigInt(r.price))); const v = Number(formatEther(BigInt(r.bnb)))
            if (!cur || cur.t !== r.t) { if (cur) out.push(cur); const o = cur ? cur.c : px; cur = { t: r.t, o, h: Math.max(o, px), l: Math.min(o, px), c: px, v } }
            else { cur.h = Math.max(cur.h, px); cur.l = Math.min(cur.l, px); cur.c = px; cur.v += v }
          }
          if (cur) out.push(cur)
          // Graduated: append DEX OHLCV (GT 1m base → resample to res_). No Swap RPC scan on
          // the request path — it hung interval switches (nginx timeout, chart stuck on prior tf).
          if (t.graduated && t.pair) {
            const dex = await fetchDexOhlcv(t.pair, res_)
            const pk = await readPair(client, t.pair, addr)
            const live = pk?.priceBnb > 0 ? pk.priceBnb : 0
            return json(res, 200, mergeCurveAndDex(out, dex, t.graduated_ts, res_, live), { noStore: true })
          }
          return json(res, 200, out, { noStore: true })
        }
      }
      if (req.method === 'OPTIONS') {
        res.writeHead(204, {
          'access-control-allow-origin': '*',
          'access-control-allow-methods': 'GET, POST, OPTIONS',
          'access-control-allow-headers': 'content-type',
        })
        return res.end()
      }
      json(res, 404, { error: 'unknown route' })
    } catch (e) { json(res, 500, { error: e.message }) }
  })
  server.listen(port, () => console.log(`api on :${port}`))
  return server
}
