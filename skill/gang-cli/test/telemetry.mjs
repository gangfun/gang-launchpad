/**
 * Anonymous telemetry (telemetry.js) and the trending list (trending.js) against a local fake gang.fun: what an event
 * holds (never flag values, addresses or messages), the queue + detached flush to POST /api/t, GANG_TELEMETRY=0, and
 * `gang trending` / its cache, and its first-trade view (no 铸币飞轮 rows for a wallet that never traded on Gang). No chain;
 * a fake baw answers the wallet address only when FAKE_WALLET is set.
 *
 *   node skill/gang-cli/test/telemetry.mjs
 */
import assert from 'node:assert/strict'
import { execFile, spawn } from 'node:child_process'
import { promisify } from 'node:util'
import { createServer } from 'node:http'
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const dir = mkdtempSync(join(tmpdir(), 'gang-telemetry-'))
const CLI = fileURLToPath(new URL('../src/index.js', import.meta.url))
const tok = (n) => `0x${String(n).repeat(40).slice(0, 40)}`
const posts = []
let trendingBody = null
let trendingHits = 0
// GET /api/ref/eligible: these wallets never traded on Gang; refDown answers 500
const newWallets = new Set()
let refDown = false
let refHits = 0
const server = createServer((req, res) => {
  let body = ''
  req.on('data', (c) => { body += c })
  req.on('end', () => {
    if (req.method === 'POST' && req.url === '/api/t') {
      posts.push({ ua: req.headers['user-agent'], body: JSON.parse(body) })
      res.writeHead(204).end()
    } else if (req.url.startsWith('/api/ref/eligible?')) {
      refHits++
      const w = new URL(req.url, 'http://x').searchParams.get('wallet').toLowerCase()
      if (refDown) res.writeHead(500).end()
      else {
        res.writeHead(200, { 'content-type': 'application/json' })
          .end(JSON.stringify(newWallets.has(w) ? { eligible: true, referrer: null } : { eligible: false, referrer: null, reason: 'already_traded' }))
      }
    } else if (req.url === '/api/trending') {
      trendingHits++
      if (!trendingBody) res.writeHead(404).end()
      else res.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify(trendingBody))
    } else res.writeHead(404).end()
  })
})
await new Promise((r) => server.listen(0, '127.0.0.1', r))
const API = `http://127.0.0.1:${server.address().port}/api`
process.env.GANG_API = API
process.env.GANG_TELEMETRY_DIR = join(dir, 'gang')
process.env.GANG_TRENDING_CACHE = join(dir, 'gang', 'trending.json')
delete process.env.GANG_TELEMETRY
delete process.env.DO_NOT_TRACK
const { clientOf, codeOf, eventOf, installId } = await import('../src/telemetry.js')
const { trendingBlock } = await import('../src/trending.js')

// a fake baw: `wallet address` answers $FAKE_WALLET, everything else (and an unset FAKE_WALLET) fails like a signed-out baw
const bin = join(dir, 'bin')
mkdirSync(bin, { recursive: true })
writeFileSync(join(bin, 'baw'), `#!/bin/sh
if [ "$1 $2" = "wallet address" ] && [ -n "$FAKE_WALLET" ]; then
  echo '{"success":true,"data":{"addresses":[{"binanceChainId":"56","address":"'"$FAKE_WALLET"'"}]}}'
else echo '{"success":false,"error":{"code":1,"message":"not signed in"}}'; exit 1; fi
`)
chmodSync(join(bin, 'baw'), 0o755)

const env = (extra = {}) => ({ ...process.env, PATH: `${bin}:${process.env.PATH}`, FAKE_WALLET: '', GANG_UPDATE_CHECK: '0', ...extra })
// async, so this process's fake server can answer the CLI while it runs
const run = async (args, extra) => {
  try {
    return JSON.parse((await promisify(execFile)(process.execPath, [CLI, ...args], { env: env(extra), encoding: 'utf8' })).stdout)
  } catch (e) { return JSON.parse(e.stdout) }
}
const waitFor = async (pred, ms = 8000) => {
  const end = Date.now() + ms
  while (!pred()) {
    if (Date.now() > end) return false
    await new Promise((r) => setTimeout(r, 50))
  }
  return true
}

try {
  // --- what an event holds ---
  {
    const e = eventOf(['buy', '--token', tok(1), '--amount', '0.5', '--note', 'my secret reason', '--amount', '1'], { success: true })
    assert.equal(e.c, 'buy')
    assert.equal(e.s, '')
    assert.deepEqual(e.f, ['token', 'amount', 'note']) // names once each, never values
    assert.equal(e.ok, true)
    assert.equal(e.code, '')
    assert.equal(e.pf, null)
    assert.ok(!JSON.stringify(e).includes(tok(1)) && !JSON.stringify(e).includes('secret') && !JSON.stringify(e).includes('0.5'))
    assert.ok(Math.abs(e.t - Date.now() / 1000) < 5)

    assert.deepEqual([eventOf(['fly', 'mint', '--token', tok(2)]).c, eventOf(['fly', 'mint']).s], ['fly', 'mint'])
    assert.equal(eventOf(['buy', 'mint']).s, '') // only commands with subcommands keep the second word
    // the host's name: only when known, and only as a short slug
    assert.equal(clientOf('Claude Code'), 'claude-code')
    assert.equal(clientOf('cursor-vscode'), 'cursor-vscode')
    assert.equal(clientOf(' My_Agent 2 '), 'my-agent-2')
    assert.equal(clientOf('a-'), 'a')
    assert.equal(clientOf(''), '')
    assert.equal(clientOf('   '), '')
    assert.equal(clientOf(undefined), '')
    assert.equal(clientOf({ toString: 1 }), '')
    // never a shortened copy of something that may identify someone
    for (const raw of [`0x${'7c'.repeat(20)}`, '7c7a1b45dc1c13af', 'james@example.com', '/Users/james/agent', 'james-macbook-pro.local',
      'sk-abc123def456ghi789jkl012mno', 'sk-abc123def456', 'x'.repeat(25), '***', '中文', 'a\nb', '-ab']) {
      assert.equal(clientOf(raw), 'other', raw)
    }
    assert.equal(clientOf('x'.repeat(24)), 'x'.repeat(24))
    assert.ok(!('cl' in eventOf(['buy'])))
    process.env.GANG_CLIENT = 'Claude Code'
    assert.equal(eventOf(['buy']).cl, 'claude-code')
    delete process.env.GANG_CLIENT
    assert.equal(eventOf([tok(3)]).c, 'other') // an address typed as the command never goes out
    assert.equal(eventOf(['fly', tok(3)]).s, '')
    assert.equal(eventOf([]).c, 'other')
    assert.deepEqual(eventOf(['list', '--Weird_Flag', '--ok-flag']).f, ['ok-flag'])
    assert.equal(eventOf(['buy', ...Array.from({ length: 30 }, (_, i) => `--f${i}`)]).f.length, 16)

    const pf = eventOf(['preflight'], { success: false, status: 'CONNECTED', isAgent: true, devMode: false, tradeAllTokens: null, issues: [{ code: 'DEV_MODE_OFF' }] })
    assert.deepEqual(pf.pf, { signedIn: true, agent: true, dev: false, all: null })
    assert.equal(pf.code, 'DEV_MODE_OFF')
    assert.deepEqual(eventOf(['preflight'], { success: false, status: 'NOT_CONNECTED', issues: [{ code: 'NOT_SIGNED_IN' }] }).pf,
      { signedIn: false, agent: null, dev: null, all: null })
  }

  // --- error codes: the result's own code, else a class; never the message, an address or an amount ---
  {
    assert.equal(codeOf({ error: 'x', code: 351803 }), '351803')
    assert.equal(codeOf({ error: 'NotAgent', reason: tok(4) }), 'NotAgent') // steps.js revert: name, first arg in reason
    assert.equal(codeOf({ error: 'execution reverted', reason: '123456789000000000000' }), 'REVERT')
    assert.equal(codeOf({ error: "can't follow this note: expired", reason: 'expired' }), 'expired')
    assert.equal(codeOf({ error: 'x', code: tok(5) }), 'ERROR')
    assert.equal(codeOf({ error: 'baw wallet settings failed: risk (code 351803)' }), '351803')
    assert.equal(codeOf({ error: 'this wallet holds no Agent ID; curve trades are Agent-only', wallet: tok(6) }), 'NO_AGENT_ID')
    assert.equal(codeOf({ error: 'gang API unreachable (https://gang.fun/api/x): timed out after 15s' }), 'NETWORK')
    assert.equal(codeOf({ error: '--slippage must be a number between 0 and 50', got: '99' }), 'USAGE')
    assert.equal(codeOf({ error: 'something odd happened with 0xabc' }), 'ERROR')
    assert.equal(codeOf({ error: 'x', issues: [{ code: 'NO_AGENT_ID' }] }), 'NO_AGENT_ID')
  }

  // --- install id: random v4, created once, kept ---
  {
    const a = installId(), b = installId()
    assert.match(a, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/)
    assert.equal(a, b)
  }

  // --- a CLI run queues its event and a detached child posts it ---
  {
    const v = await run(['version', '--json-ish'])
    assert.equal(v.success, true)
    assert.ok(await waitFor(() => posts.length === 1), 'flush posted')
    const p = posts[0]
    assert.match(p.ua, /^gang-cli\//)
    assert.equal(p.body.i, installId())
    assert.equal(p.body.v, v.version)
    assert.equal(p.body.e.length, 1)
    assert.deepEqual({ ...p.body.e[0], t: 0 }, { t: 0, c: 'version', s: '', f: ['json-ish'], ok: true, code: '', pf: null })
    assert.ok(await waitFor(() => !existsSync(join(dir, 'gang', 'events.ndjson')) || readFileSync(join(dir, 'gang', 'events.ndjson'), 'utf8') === ''))

    // within a minute of the last flush: queued, not posted; the next flush takes both
    await run(['version'])
    await run(['list', '--kind', 'nope'])
    await new Promise((r) => setTimeout(r, 400))
    assert.equal(posts.length, 1)
    const queued = readFileSync(join(dir, 'gang', 'events.ndjson'), 'utf8').trim().split('\n').map((l) => JSON.parse(l))
    assert.deepEqual(queued.map((e) => [e.c, e.ok, e.code]), [['version', true, ''], ['list', false, 'USAGE']])
    rmSync(join(dir, 'gang', 'events.flush'))
    await run(['version'])
    assert.ok(await waitFor(() => posts.length === 2), 'second flush posted')
    assert.deepEqual(posts[1].body.e.map((e) => e.c), ['version', 'list', 'version'])
  }

  // --- `gang mcp`: its tools' events carry the MCP client's name, unless the user set GANG_CLIENT ---
  {
    const queue = join(dir, 'gang', 'events.ndjson')
    const viaMcp = async (extra) => {
      rmSync(queue, { force: true })
      writeFileSync(join(dir, 'gang', 'events.flush'), '') // flushed just now: the events stay in the queue to read
      const child = spawn(process.execPath, [CLI, 'mcp'], { env: env(extra), stdio: ['pipe', 'pipe', 'inherit'] })
      const send = (id, method, params) => child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`)
      let got = 0
      child.stdout.on('data', (d) => { got += String(d).split('\n').filter(Boolean).length })
      send(1, 'initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'Claude Code', version: '1' } })
      assert.ok(await waitFor(() => got >= 1), 'initialized')
      send(2, 'tools/call', { name: 'gang_cli', arguments: { args: ['version'] } })
      assert.ok(await waitFor(() => got >= 2), 'tool answered')
      child.stdin.end()
      return readFileSync(queue, 'utf8').trim().split('\n').map((l) => JSON.parse(l)).find((e) => e.c === 'version')
    }
    assert.equal((await viaMcp({})).cl, 'claude-code')
    assert.equal((await viaMcp({ GANG_CLIENT: 'my host' })).cl, 'my-host')
    rmSync(queue, { force: true })
  }

  // --- GANG_TELEMETRY=0 / DO_NOT_TRACK=1: nothing queued, nothing posted ---
  {
    rmSync(join(dir, 'gang', 'events.flush'), { force: true })
    await run(['version'], { GANG_TELEMETRY: '0' })
    await run(['version'], { DO_NOT_TRACK: '1' })
    await new Promise((r) => setTimeout(r, 600))
    assert.equal(posts.length, 2)
    assert.ok(!existsSync(join(dir, 'gang', 'events.ndjson')) || readFileSync(join(dir, 'gang', 'events.ndjson'), 'utf8') === '')
  }

  // --- trending: a down server is cached as a miss; a list renders and is cached for 5 minutes ---
  {
    const cache = join(dir, 'gang', 'trending.json')
    const miss = await run(['trending'], { GANG_TELEMETRY: '0' })
    assert.equal(miss.success, false)
    assert.equal(miss.retry, true)
    assert.equal(trendingHits, 1)
    await run(['trending'], { GANG_TELEMETRY: '0' })
    assert.equal(trendingHits, 1) // the miss is cached
    rmSync(cache)

    trendingBody = {
      at: 1793500000,
      tokens: [
        { address: tok(7), symbol: 'AAA', name: 'Aaa', track: 'v3', progressPct: 42.1, buyers6h: 37, change24h: 0.12, volume24hUsd: 5123.4, graduated: false },
        { address: 'not-an-address', symbol: 'BAD' },
      ],
      calls: [{
        tx: `0x${'ab'.repeat(32)}`, kind: 'buy', ts: 1793499000, status: 'ok', text: 'strong community', conf: 80,
        agent: { address: tok(8), handle: 'lazy.ai' }, author: { count: 12, scored: 9, hitRate: 0.7777, score: 81.2, revealRate: 1 },
        token: { address: tok(7), symbol: 'AAA', track: 'v3' }, market: { progressPct: 42.1 }, perf: { changeNow: 0.3 },
        follow: { open: true, until: 1793585400, n: 1, usd: 10 },
      }],
    }
    const t = await run(['trending'], { GANG_TELEMETRY: '0' })
    assert.equal(t.success, true)
    assert.equal(t.tokens.length, 1)
    assert.deepEqual(t.tokens[0], {
      symbol: 'AAA', name: 'Aaa', address: tok(7), track: 'v3', progressPct: 42.1, buyers6h: 37, change24h: 0.12,
      volume24hUsd: 5123.4, link: `https://gang.fun/token/${tok(7)}`, next: `gang info --token ${tok(7)}`,
    })
    assert.equal(t.calls.length, 1)
    assert.equal(t.calls[0].author.handle, 'lazy.ai')
    assert.equal(t.calls[0].author.record.hitRate, 0.7777)
    assert.deepEqual(t.calls[0].note, { status: 'shown', text: 'strong community', conf: 80 })
    assert.match(t.calls[0].next, /^gang follow 0x/)
    assert.match(t.note, /not a recommendation/)
    const hits = trendingHits
    await run(['trending'], { GANG_TELEMETRY: '0' })
    assert.equal(trendingHits, hits) // served from the cache

    rmSync(cache)
    trendingBody = { at: 1793500000, tokens: [], calls: [] }
    const empty = await run(['trending'], { GANG_TELEMETRY: '0' })
    assert.equal(empty.success, true)
    assert.match(empty.empty, /Nothing qualifies/)
  }

  // --- trending for a wallet's first Gang trade: 铸币飞轮 sales and the calls on them left out ---
  {
    const cache = join(dir, 'gang', 'trending.json')
    rmSync(cache, { force: true })
    const fly = tok(9)
    const call = (token, track, b) => ({
      tx: `0x${b.repeat(32)}`, kind: 'buy', ts: 1793499000, status: 'ok', text: 'x', conf: 50,
      agent: { address: tok(8), handle: 'lazy.ai' }, author: { count: 6, scored: 5, hitRate: 0.8, score: null, revealRate: 1 },
      token: { address: token, symbol: track.toUpperCase(), track }, market: { progressPct: 10 }, perf: { changeNow: 0 },
      follow: { open: true, until: 1793585400, n: 0, usd: 0 },
    })
    trendingBody = {
      at: 1793500000,
      tokens: [
        { address: fly, symbol: 'FFF', name: 'Fff', track: 'fly', progressPct: 30, buyers6h: 50, change24h: 0, volume24hUsd: 900, graduated: false },
        { address: tok(7), symbol: 'AAA', name: 'Aaa', track: 'v3', progressPct: 42.1, buyers6h: 37, change24h: 0.12, volume24hUsd: 5123.4, graduated: false },
      ],
      calls: [call(fly, 'fly', 'cd'), call(tok(7), 'v3', 'ef')],
    }
    const NEW = tok('a'), OLD = tok('b')
    newWallets.add(NEW.toLowerCase())
    const syms = (t) => t.tokens.map((x) => x.symbol)

    // signed out: no wallet to ask about, so nothing is left out and gang.fun is not asked
    const out = await run(['trending'], { GANG_TELEMETRY: '0' })
    assert.deepEqual(syms(out), ['FFF', 'AAA'])
    assert.equal(out.calls.length, 2)
    assert.equal(out.firstTrade, undefined)
    assert.equal(refHits, 0)

    // a wallet that has traded: everything, as before
    const old = await run(['trending'], { GANG_TELEMETRY: '0', FAKE_WALLET: OLD })
    assert.deepEqual(syms(old), ['FFF', 'AAA'])
    assert.equal(old.firstTrade, undefined)
    assert.equal(refHits, 1)

    // a wallet that never traded on Gang (checksum case in, as baw gives it): the 铸币飞轮 token and its call are gone
    const fresh = await run(['trending'], { GANG_TELEMETRY: '0', FAKE_WALLET: NEW.toUpperCase().replace('0X', '0x') })
    assert.deepEqual(syms(fresh), ['AAA'])
    assert.deepEqual(fresh.calls.map((c) => c.token.address), [tok(7)])
    assert.deepEqual(Object.keys(fresh.firstTrade), ['flyLeftOut', 'note'])
    assert.equal(fresh.firstTrade.flyLeftOut, 2)
    assert.match(fresh.firstTrade.note, /has not traded on Gang yet/)
    assert.match(fresh.firstTrade.note, /gang list --kind fly/)

    // gang.fun can't say: nothing is left out
    refDown = true
    const down = await run(['trending'], { GANG_TELEMETRY: '0', FAKE_WALLET: NEW })
    assert.deepEqual(syms(down), ['FFF', 'AAA'])
    assert.equal(down.firstTrade, undefined)
    refDown = false

    // the block preflight / list carry: same view; a new wallet with no 铸币飞轮 row gets no firstTrade
    const block = await trendingBlock({ wallet: NEW })
    assert.deepEqual(block.tokens.map((x) => x.symbol), ['AAA'])
    assert.equal(block.firstTrade.flyLeftOut, 2)
    assert.equal((await trendingBlock({ wallet: OLD })).firstTrade, undefined)
    assert.equal((await trendingBlock()).tokens.length, 2)
    rmSync(cache)
    trendingBody = { ...trendingBody, tokens: trendingBody.tokens.slice(1), calls: trendingBody.calls.slice(1) }
    const none = await trendingBlock({ wallet: NEW })
    assert.deepEqual(none.tokens.map((x) => x.symbol), ['AAA'])
    assert.equal(none.firstTrade, undefined)
  }

  // --- preflight with issues carries the setup page; signed out needs no chain ---
  {
    const pf = await run(['preflight'], { GANG_TELEMETRY: '0' })
    assert.equal(pf.success, false)
    assert.deepEqual(pf.issues.map((i) => i.code), ['NOT_SIGNED_IN'])
    assert.equal(pf.guide.url, 'https://gang.fun/start')
    assert.match(pf.guide.note, /setup/)
    assert.equal(pf.next, undefined)
  }

  console.log('telemetry: ok')
} finally {
  server.close()
  rmSync(dir, { recursive: true, force: true })
}
