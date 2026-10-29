/**
 * `gang watch` market mode over GET /stream (discover.js streamMarket), against a fake gang.fun API on localhost:
 * the watching line, normalized events (USD from the server's quoteUsd), a dropped connection resumed with
 * Last-Event-ID (the replay's repeats skipped, also over two drops in a row), and the fallback to polling when the server
 * has no /stream. No chain, no wallet.
 *
 *   node skill/gang-cli/test/watch-stream.mjs
 */
import assert from 'node:assert/strict'
import http from 'node:http'

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const addr = (n) => `0x${String(n).padStart(40, '0')}`
const WBNB = '0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c'
const v3 = (n, o = {}) => ({
  address: addr(n), symbol: `T${n}`, name: `T${n}`, track: 'v3', chainId: 56, quoteAddress: WBNB, quoteSymbol: 'WBNB',
  quoteDecimals: 18, realQuote: String(6e18), gradAmt: String(15e18), progressPct: 40, graduated: false,
  createdAt: Math.floor(Date.now() / 1000), volume24hQuote: 2, ...o,
})

let mode = 'stream' // 'stream' | 'none' (an older server: /stream is 404)
const seen = [] // { path, lastId } of every /stream request
let script = null // (res, lastId) → writes this connection's messages
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x')
  if (url.pathname === '/stream') {
    seen.push({ path: req.url, lastId: req.headers['last-event-id'] || null })
    if (mode === 'none') { res.writeHead(404, { 'content-type': 'application/json' }); return res.end('{"error":"unknown route"}') }
    res.writeHead(200, { 'content-type': 'text/event-stream' })
    return script(res, req.headers['last-event-id'] || null)
  }
  // the polling fallback's lists: one V3 token, every other list empty
  const items = url.pathname === '/v3/tokens' ? [v3(1)] : []
  res.writeHead(200, { 'content-type': 'application/json' })
  res.end(JSON.stringify({ items, hasMore: false, nextOffset: null }))
})
await new Promise((r) => server.listen(0, '127.0.0.1', r))
process.env.GANG_API = `http://127.0.0.1:${server.address().port}`
const { watch, sseMessages } = await import('../src/discover.js')

const msg = (o, id) => `${id ? `id: ${id}\n` : ''}data: ${JSON.stringify(o)}\n\n`

/** Run watch until n non-meta events (or ms), return every emitted line. */
async function run(opts, n, ms = 8000) {
  const lines = []
  let count = 0
  const end = Date.now() + ms
  await watch({
    intervalSec: 10, minPct: 50, track: 'all', events: null, ...opts,
    emit: (ev, { meta = false } = {}) => { lines.push({ ...ev, meta }); if (!meta) count++ },
    shouldStop: () => count >= n || Date.now() > end,
  })
  return lines
}

// the SSE parser: ids, multi-line data, comments, CRLF, a message split across chunks
{
  async function* body() {
    yield new TextEncoder().encode(': ping\n\nid: 7\ndata: {"a":\r\n')
    yield new TextEncoder().encode('data: 1}\n\ndata: {"b":2}\n\n')
  }
  const out = []
  for await (const m of sseMessages(body())) out.push(m)
  assert.deepEqual(out, [{ id: '7', data: '{"a":\n1}' }, { id: null, data: '{"b":2}' }])
}

// a stream: ready, then a snapshot's three events; the second connection (after a drop mid-snapshot) resumes from
// the last snapshot line and the replayed new_token is not emitted twice
{
  let conn = 0
  script = (res) => {
    conn++
    if (conn === 1) {
      res.write(msg({ event: 'ready', at: 1000, tokens: 3 }, 1000))
      res.write(msg({ event: 'new_token', at: 2000, rate: 600, row: v3(2) }))
      res.write(msg({ event: 'graduated', at: 2000, rate: 600, row: v3(3, { graduated: true, progressPct: 100, pair: addr(99) }) }))
      res.write(msg({ event: 'snapshot', at: 2000 }, 2000))
      res.write(msg({ event: 'near_grad', at: 3000, rate: 600, row: v3(4, { progressPct: 60 }) }))
      return setTimeout(() => res.destroy(), 50) // dropped before snapshot 3000's id line
    }
    res.write(msg({ event: 'ready', at: 3000, tokens: 4, resumed: 2000 }))
    res.write(msg({ event: 'near_grad', at: 3000, rate: 600, row: v3(4, { progressPct: 60 }) })) // the replay
    res.write(msg({ event: 'new_token', at: 3000, rate: 600, row: v3(5) }))
    res.write(msg({ event: 'snapshot', at: 3000 }, 3000))
  }
  const lines = await run({}, 4)
  const watching = lines.find((l) => l.event === 'watching')
  assert.equal(watching.transport, 'stream')
  assert.equal(watching.tokens, 3)
  const evs = lines.filter((l) => !l.meta)
  assert.deepEqual(evs.map((e) => `${e.event}:${Number(e.token ?? e.address)}`), ['new_token:2', 'graduated:3', 'near_grad:4', 'new_token:5'])
  // normalized as gang new / near-grad rows: quote units, USD at the server's BNB price, the next command
  assert.equal(evs[0].quote, 'WBNB')
  assert.equal(evs[0].raised, 6)
  assert.equal(evs[0].volume24hUsd, 1200)
  assert.equal(evs[0].next, `gang buy --token ${addr(2)} --amount <amount in WBNB>`)
  assert.equal(evs[1].pair, addr(99))
  assert.match(evs[2].next, /^gang buy --token/)
  assert.ok(lines.some((l) => l.meta && l.event === 'error' && /reconnecting in 1s/.test(l.error)))
  assert.equal(seen.at(-1).lastId, '2000')
  assert.match(seen[0].path, /track=all&minPct=50/)
}

// two drops before the snapshot's id line: the second replay still skips what the first connection printed; a quote
// the CLI cannot price itself (GANG) takes the server's quoteUsd
{
  const GANG = '0x0000000000000000000000000000000000006a46'
  let conn = 0
  seen.length = 0
  const near = msg({ event: 'near_grad', at: 2, rate: 600, quoteUsd: 0.02, row: v3(4, { progressPct: 60, quoteAddress: GANG, quoteSymbol: 'GANG' }) })
  script = (res) => {
    conn++
    if (conn === 1) {
      res.write(msg({ event: 'ready', at: 1, tokens: 1 }, 1))
      res.write(near)
      return setTimeout(() => res.destroy(), 50)
    }
    res.write(msg({ event: 'ready', at: 2, tokens: 1, resumed: 1 }))
    res.write(near)
    if (conn === 2) return setTimeout(() => res.destroy(), 50) // dropped again, still before the id line
    res.write(msg({ event: 'new_token', at: 2, rate: 600, row: v3(6) }))
    res.write(msg({ event: 'snapshot', at: 2 }, 2))
  }
  const lines = await run({}, 2, 12000)
  const evs = lines.filter((l) => !l.meta)
  assert.deepEqual(evs.map((e) => `${e.event}:${Number(e.token ?? e.address)}`), ['near_grad:4', 'new_token:6'])
  assert.equal(conn, 3)
  assert.ok(seen.slice(1).every((x) => x.lastId === '1'))
  // 9 GANG to go at $0.02 (6 of 15 raised)
  assert.equal(evs[0].remainingUsd, 0.18)
}

// --events goes to the server and filters here too
{
  seen.length = 0
  script = (res) => {
    res.write(msg({ event: 'ready', at: 1, tokens: 0 }, 1))
    res.write(msg({ event: 'new_token', at: 2, rate: 600, row: v3(8) }))
    res.write(msg({ event: 'near_grad', at: 2, rate: 600, row: v3(9, { progressPct: 70 }) }))
    res.write(msg({ event: 'snapshot', at: 2 }, 2))
  }
  const lines = await run({ events: new Set(['near_grad']) }, 1)
  assert.match(seen[0].path, /events=near_grad/)
  assert.deepEqual(lines.filter((l) => !l.meta).map((e) => e.event), ['near_grad'])
}

// an older server (no /stream): polls, as before
{
  mode = 'none'
  const lines = await run({}, 1, 1500)
  const watching = lines.find((l) => l.event === 'watching')
  assert.equal(watching.transport, 'poll')
  assert.equal(watching.tokens, 1)
}

// --poll never asks for the stream
{
  mode = 'stream'
  seen.length = 0
  const lines = await run({ poll: true }, 1, 1500)
  assert.equal(seen.length, 0)
  assert.equal(lines.find((l) => l.event === 'watching').transport, 'poll')
}

server.close()
await sleep(10)
console.log('watch-stream: ok')
process.exit(0)
