/**
 * `gang preflight` with a signed-in wallet (0.41.0+): the BNB balance, a LOW_BNB warning that doesn't fail preflight, and
 * a balance read that hangs being cut off so preflight still answers and exits. Setup issues (0.46.0+) each carry a url to
 * their step on gang.fun/start, and guide.url opens at the first one. A fake baw and a fake JSON-RPC node.
 *
 *   node skill/gang-cli/test/preflight.mjs
 */
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { createServer } from 'node:http'
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'

const CLI = fileURLToPath(new URL('../src/index.js', import.meta.url))
const WALLET = '0x1234567890123456789012345678901234567890'
const dir = mkdtempSync(join(tmpdir(), 'gang-preflight-'))
const bin = join(dir, 'bin')
mkdirSync(bin, { recursive: true })
writeFileSync(join(bin, 'baw'), `#!/bin/sh
case "$1 $2" in
  "wallet status") echo '{"success":true,"data":{"status":"CONNECTED"}}' ;;
  "wallet address") echo '{"success":true,"data":{"addresses":[{"binanceChainId":"56","address":"${WALLET}"}]}}' ;;
  "wallet settings") cat "${join(dir, 'settings.json')}" ;;
  *) echo '{"success":false,"error":{"code":1,"message":"unexpected"}}'; exit 1 ;;
esac
`)
chmodSync(join(bin, 'baw'), 0o755)
const SETTINGS_OK = { devMode: { enabled: true }, tradeAllTokens: true }
const setSettings = (data) => writeFileSync(join(dir, 'settings.json'), JSON.stringify({ success: true, data }))
setSettings(SETTINGS_OK)

// eth_getBalance answers `balance` (wei, hex) or never, when hang is set; isAgent (eth_call) answers `isAgent`
let balance = '0x0', hang = false, isAgent = true
const rpc = createServer((req, res) => {
  let body = ''
  req.on('data', (c) => { body += c })
  req.on('end', () => {
    if (req.method !== 'POST') return res.writeHead(404).end()
    const answer = (m) => {
      if (m.method === 'eth_chainId') return '0x38'
      if (m.method === 'eth_getBalance') return balance
      if (m.method === 'eth_call') return `0x${'0'.repeat(63)}${isAgent ? 1 : 0}`
      if (m.method === 'eth_blockNumber') return '0x1'
      return null
    }
    const msg = JSON.parse(body)
    const list = Array.isArray(msg) ? msg : [msg]
    if (hang && list.some((m) => m.method === 'eth_getBalance')) return // never answers
    const out = list.map((m) => ({ jsonrpc: '2.0', id: m.id, result: answer(m) }))
    res.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify(Array.isArray(msg) ? out : out[0]))
  })
})
const api = createServer((req, res) => res.writeHead(404).end())
await Promise.all([rpc, api].map((s) => new Promise((r) => s.listen(0, '127.0.0.1', r))))

const env = {
  ...process.env, PATH: `${bin}:${process.env.PATH}`, GANG_TELEMETRY: '0', GANG_UPDATE_CHECK: '0',
  GANG_RPC_URL: `http://127.0.0.1:${rpc.address().port}`, GANG_API: `http://127.0.0.1:${api.address().port}/api`,
}
const preflight = async () => {
  const t0 = Date.now()
  let stdout
  try { stdout = (await promisify(execFile)(process.execPath, [CLI, 'preflight'], { env, encoding: 'utf8', timeout: 30_000 })).stdout } catch (e) { stdout = e.stdout }
  return { r: JSON.parse(stdout), ms: Date.now() - t0 }
}

try {
  // an empty wallet: setup passes, the balance shows, and the warning says how to top up
  balance = '0x0'
  {
    const { r } = await preflight()
    assert.equal(r.success, true)
    assert.deepEqual(r.issues, [])
    assert.equal(r.bnb, '0')
    assert.deepEqual(r.warnings.map((w) => w.code), ['LOW_BNB'])
    assert.match(r.warnings[0].fix, /^Top up before the first trade: send BNB on BNB Smart Chain/)
  }
  // enough for a first buy: no warning
  balance = `0x${(10n ** 17n).toString(16)}` // 0.1 BNB
  {
    const { r } = await preflight()
    assert.equal(r.success, true)
    assert.equal(r.bnb, '0.1')
    assert.equal(r.warnings, undefined)
  }
  // the balance read hangs: preflight answers without it, and the process exits (not held by the pending request)
  hang = true
  {
    const { r, ms } = await preflight()
    assert.equal(r.success, true)
    assert.equal(r.bnb, undefined)
    assert.equal(r.warnings, undefined)
    assert.ok(ms < 15_000, `preflight took ${ms} ms`)
  }
  hang = false
  // every setup issue: each links its own step on the setup page, and guide opens at the first one
  setSettings({ devMode: { enabled: false }, tradeAllTokens: false })
  isAgent = false
  {
    const { r } = await preflight()
    assert.equal(r.success, false)
    assert.deepEqual(r.issues.map((i) => [i.code, i.url]), [
      ['DEV_MODE_OFF', 'https://gang.fun/start#dev-mode'],
      ['TRADE_ALL_TOKENS_OFF', 'https://gang.fun/start#trade-all'],
      ['NO_AGENT_ID', 'https://gang.fun/start#agent-id'],
    ])
    assert.ok(r.issues.every((i) => typeof i.fix === 'string' && i.fix.length))
    assert.equal(r.guide.url, 'https://gang.fun/start#dev-mode')
    assert.equal(r.next, undefined)
  }
  // only the Agent ID missing: guide opens at that step
  setSettings(SETTINGS_OK)
  {
    const { r } = await preflight()
    assert.deepEqual(r.issues.map((i) => i.code), ['NO_AGENT_ID'])
    assert.equal(r.guide.url, 'https://gang.fun/start#agent-id')
  }
  isAgent = true
  console.log('preflight: ok')
} finally {
  rpc.closeAllConnections?.()
  rpc.close(); api.close()
  rmSync(dir, { recursive: true, force: true })
}
