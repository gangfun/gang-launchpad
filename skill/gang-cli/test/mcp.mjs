/**
 * `gang mcp` (mcp.js) as a real child process over stdio: initialize, tools/list, read tools against a fake gang.fun
 * API (GANG_API), gang_watch over the fake API's stream, a cancelled call and a closed stdin killing a read's CLI child
 * but letting gang_execute finish (a fake `baw` on PATH that takes 2 s), argument checks, and the refusals. No chain, no
 * wallet.
 *
 *   node skill/gang-cli/test/mcp.mjs
 */
import assert from 'node:assert/strict'
import http from 'node:http'
import { execFileSync, spawn } from 'node:child_process'
import { chmodSync, existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createInterface } from 'node:readline'
import { fileURLToPath } from 'node:url'

const addr = (n) => `0x${String(n).padStart(40, '0')}`
const WBNB = '0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c'
const v3 = (n, o = {}) => ({
  address: addr(n), symbol: `T${n}`, track: 'v3', chainId: 56, quoteAddress: WBNB, quoteSymbol: 'WBNB', realQuote: String(3e18),
  gradAmt: String(15e18), progressPct: 20, createdAt: Math.floor(Date.now() / 1000), trades24h: 4, volume24hQuote: 1, ...o,
})
let streams = 0 // /stream connections open now
let quietStream = false // send ready only: a watch on it waits until killed or timed out
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x')
  if (url.pathname === '/stream') {
    streams++
    res.on('close', () => streams--)
    res.writeHead(200, { 'content-type': 'text/event-stream' })
    if (quietStream) return res.write(`id: 1\ndata: ${JSON.stringify({ event: 'ready', at: 1, tokens: 1 })}\n\n`)
    res.write(`id: 1\ndata: ${JSON.stringify({ event: 'ready', at: 1, tokens: 1 })}\n\n`)
    setTimeout(() => res.write(`data: ${JSON.stringify({ event: 'new_token', at: 2, rate: 600, row: v3(2) })}\n\nid: 2\ndata: {"event":"snapshot","at":2}\n\n`), 200)
    return
  }
  res.writeHead(200, { 'content-type': 'application/json' })
  res.end(JSON.stringify({ items: url.pathname === '/v3/tokens' ? [v3(1)] : [], hasMore: false, nextOffset: null }))
})
await new Promise((r) => server.listen(0, '127.0.0.1', r))

const cli = fileURLToPath(new URL('../src/index.js', import.meta.url))
const child = spawn(process.execPath, [cli, 'mcp'], {
  env: { ...process.env, GANG_API: `http://127.0.0.1:${server.address().port}` }, stdio: ['pipe', 'pipe', 'inherit'],
})
const waiting = new Map()
const notJson = []
createInterface({ input: child.stdout }).on('line', (line) => {
  let m
  try { m = JSON.parse(line) } catch { notJson.push(line); return }
  waiting.get(m.id)?.(m)
  waiting.delete(m.id)
})
let next = 1
const rpc = (method, params) => new Promise((resolve) => {
  const id = next++
  waiting.set(id, resolve)
  child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`)
})
const call = async (name, args) => (await rpc('tools/call', { name, arguments: args })).result
const until = async (f, ms = 8000) => { const end = Date.now() + ms; while (!f()) { if (Date.now() > end) throw new Error('timeout'); await new Promise((r) => setTimeout(r, 20)) } }

const init = await rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '0' } })
assert.equal(init.result.protocolVersion, '2025-06-18')
assert.equal(init.result.serverInfo.name, 'gang')
assert.match(init.result.instructions, /Preview -> show the user -> wait for a yes -> gang_execute/)
child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' })}\n`)
assert.equal((await rpc('initialize', { protocolVersion: '1999-01-01' })).result.protocolVersion, '2025-11-25')
assert.deepEqual((await rpc('ping')).result, {})
assert.equal((await rpc('nope')).error.code, -32601)

const { tools } = (await rpc('tools/list')).result
const names = tools.map((t) => t.name)
assert.equal(tools.length, 17)
for (const n of ['gang_help', 'gang_preflight', 'gang_hot', 'gang_new', 'gang_near_grad', 'gang_info', 'gang_status', 'gang_portfolio', 'gang_notes', 'gang_agents',
  'gang_watch', 'gang_buy', 'gang_sell', 'gang_follow', 'gang_execute', 'gang_tx', 'gang_cli']) assert.ok(names.includes(n), n)
assert.ok(tools.every((t) => t.inputSchema.type === 'object' && !('args' in t)))
assert.equal(tools.find((t) => t.name === 'gang_execute').annotations.destructiveHint, true)
assert.equal(tools.find((t) => t.name === 'gang_hot').annotations.readOnlyHint, true)
// one plain type per argument: Gemini function calling and OpenAI strict mode reject a union ("type": [...])
const unions = tools.flatMap((t) => Object.entries(t.inputSchema.properties).filter(([, v]) => Array.isArray(v.type)).map(([k]) => `${t.name}.${k}`))
assert.deepEqual(unions, [])

// amount: a number from the model is taken as its decimal string; anything but a plain decimal is refused
{
  const { TOOLS, coerce, invalid } = await import('../src/mcp.js')
  const buy = TOOLS.find((t) => t.name === 'gang_buy')
  const check = (amount) => invalid(buy, coerce(buy, { token: addr(1), amount }))
  assert.equal(check(0.05), null)
  assert.equal(check('0.05'), null)
  assert.deepEqual(buy.args(coerce(buy, { token: addr(1), amount: 0.05 })).slice(0, 5), ['buy', '--token', addr(1), '--amount', '0.05'])
  assert.match(check(1e-7), /plain decimal like 0\.05 \(got 1e-7\)/)
  assert.match(check('-1'), /plain decimal/)
  assert.match(check('abc'), /plain decimal/)
  const sell = TOOLS.find((t) => t.name === 'gang_sell')
  assert.equal(invalid(sell, coerce(sell, { token: addr(1), amount: 1000000 })), null)
  // every flag a specialized tool takes lands on the CLI as its own flag
  const args = (name, a) => TOOLS.find((t) => t.name === name).args(a)
  assert.deepEqual(args('gang_buy', { token: addr(1), amount: '1', useWbnb: true, useQuote: true, payBnb: true }).slice(5),
    ['--use-wbnb', '--use-quote', '--pay-bnb'])
  assert.deepEqual(args('gang_sell', { token: addr(1), all: true, settleFirst: true, breakBond: true, confirmOut: true, toBnb: true }),
    ['sell', '--token', addr(1), '--all', '--to-bnb', '--break-bond', '--confirm-out', '--settle-first'])
  assert.deepEqual(args('gang_status', { token: addr(1), from: addr(2), slippage: 2, testnet: true }),
    ['status', '--token', addr(1), '--from', addr(2), '--slippage', '2', '--testnet'])
  assert.deepEqual(args('gang_portfolio', {}), ['portfolio'])
  assert.deepEqual(args('gang_portfolio', { from: addr(2) }), ['portfolio', '--from', addr(2)])
  assert.deepEqual(args('gang_follow', { noteTx: `0x${'a'.repeat(64)}`, amount: '0.1', useWbnb: true }),
    ['follow', `0x${'a'.repeat(64)}`, '--amount', '0.1', '--use-wbnb'])
  assert.deepEqual(args('gang_watch', { interval: '20s', poll: true, webhook: 'https://x.test/h' }),
    ['watch', '--interval', '20s', '--poll', '--webhook', 'https://x.test/h', '--max-events', '1', '--timeout', '50s'])
  assert.deepEqual(args('gang_help', {}), [])
  assert.deepEqual(args('gang_tx', { pending: true }), ['tx', '--pending'])
  assert.deepEqual(args('gang_tx', { hash: `0x${'1'.repeat(64)}`, testnet: true }), ['tx', '--hash', `0x${'1'.repeat(64)}`, '--testnet'])

  // the CLI children's PATH: the host's first, then node's dir, the package's global bin and the usual install dirs
  const { childEnv } = await import('../src/mcp.js')
  const { delimiter, dirname, join } = await import('node:path')
  const cliAt = join('/opt', 'npm', 'lib', 'node_modules', '@gangfun', 'cli', 'src', 'index.js')
  const env = childEnv({ PATH: ['/usr/bin', '/bin'].join(delimiter), HOME: '/h' }, cliAt)
  const dirs = env.PATH.split(delimiter)
  assert.deepEqual(dirs.slice(0, 2), ['/usr/bin', '/bin'])
  assert.ok(dirs.includes(dirname(process.execPath)))
  assert.ok(dirs.includes(join('/opt', 'npm', 'bin')))
  if (process.platform !== 'win32') assert.ok(dirs.includes('/opt/homebrew/bin') && dirs.includes('/usr/local/bin'))
  assert.equal(new Set(dirs).size, dirs.length)
  assert.equal(env.HOME, '/h')
  // Windows spells it Path: that key is extended, no second one added
  const win = childEnv({ Path: 'C:\\Windows' }, cliAt)
  assert.ok(win.Path.startsWith('C:\\Windows') && !('PATH' in win))
}

// no baw on PATH (the CLI run directly, without gang mcp's PATH): one plain sentence on what to do, not spawnSync ENOENT
{
  const { execFileSync } = await import('node:child_process')
  let outText = ''
  try { execFileSync(process.execPath, [cli, 'preflight'], { env: { PATH: '/nonexistent', HOME: process.env.HOME }, encoding: 'utf8' }) } catch (e) { outText = e.stdout }
  assert.match(JSON.parse(outText).error, /^baw \(the Binance Agentic Wallet CLI\) is not installed or not on PATH: npm i -g @binance\/agentic-wallet/)
}

// a read tool runs the CLI and returns its JSON
const hot = await call('gang_hot', { limit: 5, track: 'v3' })
assert.equal(hot.isError, false)
assert.equal(hot.structuredContent.success, true)
assert.equal(hot.structuredContent.tokens[0].address, addr(1))
assert.deepEqual(JSON.parse(hot.content[0].text), hot.structuredContent)

// gang_watch: blocks for the next event (over the stream), returns it with the meta lines apart
const w = await call('gang_watch', { mode: 'market', timeout: '10s' })
assert.equal(w.isError, false)
assert.deepEqual(w.structuredContent.events.map((e) => `${e.event}:${e.address}`), [`new_token:${addr(2)}`])
assert.equal(w.structuredContent.meta[0].transport, 'stream')
// nothing before the timeout: timedOut, call again
const quiet = await call('gang_watch', { events: ['graduated'], timeout: '1s' })
assert.equal(quiet.isError, false)
assert.deepEqual(quiet.structuredContent.events, [])
assert.equal(quiet.structuredContent.timedOut, true)

// argument checks happen before anything runs
for (const [name, args, re] of [
  ['gang_info', {}, /token is required/],
  ['gang_info', { token: '0x12' }, /not a valid address/],
  ['gang_buy', { token: addr(1), amount: 1, bogus: 1 }, /unknown argument bogus/],
  ['gang_buy', { token: addr(1), amount: 1, conf: 101 }, /out of range/],
  ['gang_sell', { token: addr(1) }, /amount or all is required/],
  ['gang_watch', { timeout: '2h' }, /at most 30m/],
  ['gang_watch', { mode: 'token' }, /needs token/],
  ['gang_watch', { mode: 'market', token: addr(1) }, /leave out token/],
  ['gang_watch', { agent: 'lazy' }, /only apply to mode notes/],
  ['gang_watch', { mode: 'notes', minPct: 50 }, /do not apply to mode notes/],
  ['gang_cli', { args: ['execute', '--request-id', 'x'] }, /use the gang_execute tool/],
  ['gang_cli', { args: ['watch'] }, /use the gang_watch tool/],
  ['gang_cli', { args: ['help'] }, /use the gang_help tool/],
  ['gang_cli', { args: ['--help'] }, /use the gang_help tool/],
  ['gang_cli', { args: ['-h'] }, /use the gang_help tool/],
  ['gang_cli', { args: ['mcp'] }, /gang mcp is this server/],
  ['gang_watch', { timeout: 'soon' }, /timeout must look like 90, 50s, 5m or 1h \(got soon\)/],
  ['gang_watch', { interval: '10x' }, /interval must look like/],
  ['gang_watch', { webhook: 'ftp://x' }, /webhook must be an http\(s\) URL/],
  ['gang_watch', { mode: 'token', token: addr(1), poll: true }, /poll only applies to mode market/],
  ['gang_status', { token: addr(1), from: '0x12' }, /from is not a valid address \(0x \+ 40 hex\)/],
  ['gang_tx', { hash: '0x12' }, /hash is not a valid tx hash/],
  ['gang_tx', {}, /hash or pending: true is required/],
  ['gang_tx', { pending: true, hash: `0x${'1'.repeat(64)}` }, /pending finds the tx itself/],
]) {
  const r = await call(name, args)
  assert.equal(r.isError, true, `${name} ${JSON.stringify(args)}`)
  assert.match(JSON.parse(r.content[0].text).error, re)
}
assert.equal((await rpc('tools/call', { name: 'gang_nope', arguments: {} })).error.code, -32602)

// gang_cli runs any other command
const v = await call('gang_cli', { args: ['version'] })
assert.match(v.structuredContent.version, /^\d+\.\d+\.\d+/)
// a CLI failure comes back as isError with the CLI's own message
const bad = await call('gang_cli', { args: ['hot', '--track', 'nope'] })
assert.equal(bad.isError, true)
assert.match(bad.structuredContent.error, /--track must be/)
// an unknown command: a short error, not the whole help text
const unknown = await call('gang_cli', { args: ['nonsense'] })
assert.equal(unknown.isError, true)
assert.equal(unknown.structuredContent.error, 'not a gang command: nonsense (gang_help lists them)')

// gang_help: the CLI's whole help text (every command, every flag) and the rules
const help = await call('gang_help', {})
assert.equal(help.isError, false)
for (const c of ['gang create', 'gang mint', 'gang withdraw', 'gang claim', 'gang release', 'gang quote', 'gang list', 'gang upload-logo',
  'gang bond post', 'gang bond burn', 'gang buyback set-payee', 'gang split set-payee', 'gang lp set-payee', 'gang lp add', 'gang combo set-payee', 'gang combo chunk', 'gang v3 income', 'gang tx', '--dev-buy', '--keep-logo-uri']) {
  assert.ok(help.structuredContent.help.includes(c), `help mentions ${c}`)
}
assert.ok(help.structuredContent.rules.some((r) => /no early withdrawal/.test(r)))
assert.ok(help.structuredContent.rules.some((r) => /sellableBeforeOut/.test(r)))

// a relative logo path says what it was relative to and what to pass instead (no upload: the file is not there)
const missing = await call('gang_cli', { args: ['upload-logo', '--file', './no-such-logo.png'] })
assert.equal(missing.isError, true)
assert.match(missing.structuredContent.error, /file not found: .*no-such-logo\.png \(\.\/no-such-logo\.png is relative to .*\); give the image's absolute path, or its URL instead/)

// a cancelled call: its CLI child is killed (the stream it held closes) and the request gets no answer
quietStream = true
{
  const id = next++
  let answered = false
  waiting.set(id, () => { answered = true })
  child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method: 'tools/call', params: { name: 'gang_watch', arguments: { timeout: '20m' } } })}\n`)
  await until(() => streams === 1)
  child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', method: 'notifications/cancelled', params: { requestId: id, reason: 'test' } })}\n`)
  await until(() => streams === 0, 3000)
  await new Promise((r) => setTimeout(r, 300))
  assert.equal(answered, false)
  assert.deepEqual((await rpc('ping')).result, {}, 'still serving')
}
// a watch still running when the client closes stdin: killed, and the server exits at once
child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id: next++, method: 'tools/call', params: { name: 'gang_watch', arguments: { timeout: '20m' } } })}\n`)
await until(() => streams === 1)

assert.deepEqual(notJson, [], 'stdout carries only JSON-RPC')
const t0 = Date.now()
child.stdin.end()
const code = await new Promise((r) => child.on('exit', r))
assert.equal(code, 0)
assert.ok(Date.now() - t0 < 3000, 'exits without waiting for the watch')
await until(() => streams === 0, 3000)

// gang_execute is a write: a cancel, a closed stdin or a SIGTERM must not kill it (baw may have broadcast already)
{
  const dir = mkdtempSync(join(tmpdir(), 'gang-mcp-'))
  try {
    writeFileSync(join(dir, 'baw'), `#!/bin/sh\nsleep 2\ntouch "${dir}/done-$4"\necho '{"success":true,"data":{"status":"SUCCESS"}}'\n`)
    chmodSync(join(dir, 'baw'), 0o755)
    const start = () => {
      const p = spawn(process.execPath, [cli, 'mcp'], {
        env: {
          ...process.env, PATH: `${dir}:${process.env.PATH}`, GANG_NOTES_DIR: join(dir, 'notes'), GANG_UPDATE_CHECK: '0',
          GANG_API: `http://127.0.0.1:${server.address().port}`,
        },
        stdio: ['pipe', 'pipe', 'inherit'],
      })
      p.answers = []
      createInterface({ input: p.stdout }).on('line', (l) => p.answers.push(JSON.parse(l)))
      p.send = (o) => p.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', ...o })}\n`)
      p.exited = new Promise((r) => p.on('exit', (code, signal) => r({ code, signal })))
      return p
    }
    const alive = (rid) => { try { execFileSync('pgrep', ['-f', `execute --request-id ${rid}`]); return true } catch { return false } }
    const done = (rid) => existsSync(join(dir, `done-${rid}`))
    const tag = Date.now().toString(36)
    const execute = (p, id, rid) => p.send({ id, method: 'tools/call', params: { name: 'gang_execute', arguments: { requestId: rid } } })

    // cancelled: no answer, but the CLI runs to the end (baw's marker appears, then the process goes)
    let mcp = start()
    execute(mcp, 1, `c-${tag}`)
    await until(() => alive(`c-${tag}`), 3000)
    mcp.send({ method: 'notifications/cancelled', params: { requestId: 1 } })
    await new Promise((r) => setTimeout(r, 500))
    assert.ok(alive(`c-${tag}`), 'a cancelled execute keeps running')
    await until(() => done(`c-${tag}`) && !alive(`c-${tag}`), 5000)
    await new Promise((r) => setTimeout(r, 200))
    assert.equal(mcp.answers.filter((a) => a.id === 1).length, 0, 'a cancelled request gets no answer')

    // stdin closed mid-execute: the server waits for it, then exits
    execute(mcp, 2, `e-${tag}`)
    await until(() => alive(`e-${tag}`), 3000)
    const t1 = Date.now()
    mcp.stdin.end()
    assert.equal((await mcp.exited).code, 0)
    assert.ok(Date.now() - t1 >= 1000, 'waited for the execute')
    assert.ok(done(`e-${tag}`))

    // SIGTERM with a watch and an execute running: the watch is stopped (its stream closes), the server exits at once,
    // the execute finishes on its own
    mcp = start()
    mcp.send({ id: 3, method: 'tools/call', params: { name: 'gang_watch', arguments: { timeout: '20m' } } })
    execute(mcp, 4, `t-${tag}`)
    await until(() => streams === 1 && alive(`t-${tag}`), 5000)
    const t2 = Date.now()
    mcp.kill('SIGTERM')
    assert.equal((await mcp.exited).code, 0)
    assert.ok(Date.now() - t2 < 1000, 'exits at once')
    await until(() => streams === 0, 3000)
    assert.ok(alive(`t-${tag}`), 'the execute outlives the server')
    await until(() => done(`t-${tag}`) && !alive(`t-${tag}`), 5000)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

server.close()
console.log('mcp: ok')
