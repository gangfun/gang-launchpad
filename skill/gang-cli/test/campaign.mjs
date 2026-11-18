/**
 * gang campaign: the sign-up typed data, the summaries, and the CLI against a local fake gang.fun and a fake `baw` that
 * signs with a test key (no chain, no wallet): status, the join preview, --yes (the server recovers the signer), refusals.
 *
 *   node skill/gang-cli/test/campaign.mjs
 */
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { createServer } from 'node:http'
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'
import { recoverTypedDataAddress } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'

const { joinTypedData, summary, mineOf, CAMPAIGN_DOMAIN, CAMPAIGN_NOTE } = await import('../src/campaign.js')
const CLI = fileURLToPath(new URL('../src/index.js', import.meta.url))
const dir = mkdtempSync(join(tmpdir(), 'gang-campaign-'))

// a throwaway test key (anvil's account #1), never a real wallet
const KEY = '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d'
const acct = privateKeyToAccount(KEY)
const now = Math.floor(Date.now() / 1000)

// --- pure parts ---
{
  const td = joinTypedData(acct.address, 'agent-season', 123)
  assert.deepEqual(CAMPAIGN_DOMAIN, { name: 'gang.fun campaign', version: '1', chainId: 56 })
  assert.deepEqual(td.domain, CAMPAIGN_DOMAIN)
  assert.equal(td.primaryType, 'CampaignJoin')
  assert.deepEqual(td.types.CampaignJoin, [{ name: 'wallet', type: 'address' }, { name: 'campaign', type: 'string' }, { name: 'expires', type: 'uint256' }])
  assert.deepEqual(td.types.EIP712Domain.map((x) => x.name), ['name', 'version', 'chainId'])
  const { EIP712Domain, ...types } = td.types
  const sig = await acct.signTypedData({ domain: td.domain, types, primaryType: td.primaryType, message: td.message })
  assert.equal(await recoverTypedDataAddress({ domain: td.domain, types, primaryType: td.primaryType, message: td.message, signature: sig }), acct.address)
}
{
  const s = summary({
    slug: 'agent-season', title: { zh: '入帮季', en: 'Agent Season' }, status: 'live', window: { start: now - 10, end: now + 10 },
    tickets: { total: 250, holders: 180, prizes_now: 2 },
    lottery: { status: 'drawn', snapshot_hash: '0xab', target_block: 7, winners: [{ i: 0, r: '5', wallet: '0x1', prize_u: 500 }] },
  })
  assert.equal(s.title, 'Agent Season')
  assert.deepEqual(s.tickets, { total: 250, holders: 180, prizesNow: 2 })
  assert.deepEqual(s.lottery, { status: 'drawn', snapshotHash: '0xab', targetBlock: 7, winners: [{ wallet: '0x1', prizeU: 500 }] })
  assert.equal(s.url, 'https://gang.fun/campaign/agent-season')
  assert.equal(summary({ slug: 'x', title: 'Plain', status: 'ended', window: { start: 1, end: 2, ended_at: 3 } }).title, 'Plain')
  assert.equal(mineOf(null), null)
  const m = mineOf({ wallet: '0xa', status: 'entered', tickets: { base: 1, revisit: 1, invite: 3, total: 5 }, joined_at: now, won: false })
  assert.deepEqual(m.tickets, { base: 1, revisit: 1, invite: 3, total: 5 })
  assert.equal(m.joined, true)
  assert.equal(mineOf({ wallet: '0xb' }).tickets.total, 0)
}
assert.match(CAMPAIGN_NOTE, /never trade only to earn tickets/i)

// --- the CLI against a fake gang.fun and a fake baw ---
const LIVE = {
  now, slug: 'agent-season', type: 'onboarding', title: { zh: '入帮季', en: 'Agent Season' }, status: 'live',
  window: { start: now - 3600, end: now + 86400 }, tickets: { total: 10, holders: 8, prizes_now: 1 }, lottery: { status: 'open' },
}
let campaigns = { 'agent-season': LIVE }
let live = [{ slug: 'agent-season' }]
let walletRow = null
let joinAnswer = { status: 200, body: { ok: true, wallet: acct.address.toLowerCase(), joined_at: now, tickets: { base: 1, revisit: 0, invite: 0, total: 1 } } }
const posted = []
const server = createServer((req, res) => {
  const url = new URL(req.url, 'http://x')
  const send = (code, body) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)) }
  if (req.method === 'GET' && url.pathname === '/api/campaigns') return send(200, { now, items: live })
  let m = /^\/api\/campaigns\/([a-z0-9-]+)\/wallet\/(0x[0-9a-f]{40})$/.exec(url.pathname)
  if (req.method === 'GET' && m) return walletRow ? send(200, { wallet: m[2], ...walletRow }) : send(404, { error: 'not_found' })
  m = /^\/api\/campaigns\/([a-z0-9-]+)$/.exec(url.pathname)
  if (req.method === 'GET' && m) return campaigns[m[1]] ? send(200, campaigns[m[1]]) : send(404, { error: 'not_found' })
  m = /^\/api\/campaigns\/([a-z0-9-]+)\/join$/.exec(url.pathname)
  if (req.method === 'POST' && m) {
    let b = ''
    req.on('data', (c) => { b += c })
    req.on('end', () => { posted.push({ slug: m[1], body: JSON.parse(b) }); send(joinAnswer.status, joinAnswer.body) })
    return
  }
  send(404, { error: 'not_found' })
})
await new Promise((r) => server.listen(0, '127.0.0.1', r))
const base = `http://127.0.0.1:${server.address().port}`

// fake baw: signed in as the test key's address; sign-message preview stores the message, execute signs it like baw
const bin = join(dir, 'bin')
mkdirSync(bin)
const signer = join(dir, 'sign.mjs')
writeFileSync(signer, `import { readFileSync } from 'node:fs'
import { privateKeyToAccount } from ${JSON.stringify(fileURLToPath(new URL('../node_modules/viem/_esm/accounts/index.js', import.meta.url)))}
const m = JSON.parse(readFileSync(process.argv[2], 'utf8'))
const td = JSON.parse(m.params[1]); const { EIP712Domain, ...types } = td.types
const sig = await privateKeyToAccount(${JSON.stringify(KEY)}).signTypedData({ domain: td.domain, types, primaryType: td.primaryType, message: td.message })
console.log(JSON.stringify({ success: true, data: { orderId: 'o1', status: 'COMPLETED', signature: sig.slice(2, 130), signatureRecovery: sig.slice(130) === '1b' ? '00' : '01' } }))
`)
writeFileSync(join(bin, 'baw'), `#!/bin/sh
case "$1 $2" in
  "wallet status") echo '{"success":true,"data":{"status":"CONNECTED"}}' ;;
  "wallet address") echo '{"success":true,"data":{"addresses":[{"binanceChainId":"56","address":"${acct.address}"}]}}' ;;
  "sign-message preview") printf '%s' "$8" > "${dir}/msg.json"; echo '{"success":true,"data":{"requestId":"r1","requireConfirmation":false}}' ;;
  "sign-message execute") "${process.execPath}" "${signer}" "${dir}/msg.json" ;;
  *) echo '{"success":false,"error":{"message":"unexpected"}}'; exit 1 ;;
esac
`)
chmodSync(join(bin, 'baw'), 0o755)
const run = async (cliArgs, { withBaw = true } = {}) => {
  const env = {
    ...process.env, GANG_API: `${base}/api`, GANG_TELEMETRY: '0', GANG_UPDATE_CHECK: '0',
    PATH: withBaw ? `${bin}:/usr/bin:/bin` : '/usr/bin:/bin',
  }
  try { return JSON.parse((await promisify(execFile)(process.execPath, [CLI, ...cliArgs], { env, encoding: 'utf8' })).stdout) } catch (e) { return JSON.parse(e.stdout) }
}

try {
  // status: the only live campaign, signed out, then signed in with no row
  let r = await run(['campaign'], { withBaw: false })
  assert.equal(r.success, true)
  assert.equal(r.campaign.slug, 'agent-season')
  assert.equal(r.mine, undefined)
  assert.equal(r.next, 'gang campaign join agent-season')
  r = await run(['campaign', 'agent-season'])
  assert.equal(r.campaign.tickets.prizesNow, 1)
  r = await run(['campaign', 'Bad Slug'])
  assert.equal(r.success, false)
  r = await run(['campaign', 'nope'])
  assert.equal(r.success, false); assert.match(r.error, /no campaign nope/)

  // join: signed out → refused; preview signs nothing; --yes signs and posts a signature the server can recover
  r = await run(['campaign', 'join'], { withBaw: false })
  assert.equal(r.success, false); assert.match(r.error, /sign in to baw/)
  r = await run(['campaign', 'join'])
  assert.equal(r.preview, true)
  assert.equal(r.join.wallet, acct.address.toLowerCase())
  assert.match(r.signs, /no transaction/)
  assert.match(r.confirm, /^gang campaign join --yes$/)
  assert.equal(posted.length, 0, 'a preview sends nothing')
  r = await run(['campaign', 'join', 'agent-season', '--yes'])
  assert.equal(r.success, true, JSON.stringify(r))
  assert.equal(r.joined, true)
  assert.deepEqual(r.tickets, { base: 1, revisit: 0, invite: 0, total: 1 })
  assert.equal(posted.length, 1)
  const p = posted[0]
  assert.equal(p.slug, 'agent-season')
  assert.equal(p.body.wallet, acct.address.toLowerCase())
  assert.ok(p.body.expires > now && p.body.expires <= now + 3600 + 60, 'expires within the hour the server takes')
  const td = joinTypedData(acct.address, 'agent-season', p.body.expires)
  const { EIP712Domain, ...types } = td.types
  assert.equal(await recoverTypedDataAddress({ domain: td.domain, types, primaryType: td.primaryType, message: td.message, signature: p.body.signature }), acct.address)

  // the server refuses: its code comes through
  joinAnswer = { status: 403, body: { error: 'not_agent', message: 'this wallet holds no Agent ID' } }
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.success, false); assert.equal(r.code, 'NO_AGENT_ID'); assert.equal(r.apiCode, 'not_agent')
  joinAnswer = { status: 409, body: { error: 'not_new', message: 'this wallet traded on Gang before the campaign' } }
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.success, false); assert.equal(r.apiCode, 'not_new')

  // already joined: no second signature; a base ticket from a trade is said in the preview
  walletRow = { status: 'none', tickets: { base: 1, revisit: 0, invite: 0, total: 1 }, joined_at: now }
  const before = posted.length
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.alreadyJoined, true); assert.equal(posted.length, before)
  walletRow = { status: 'entered', tickets: { base: 1, revisit: 0, invite: 0, total: 1 } }
  r = await run(['campaign', 'join'])
  assert.equal(r.alreadyHasBaseTicket, true)
  r = await run(['campaign'])
  assert.equal(r.mine.tickets.total, 1); assert.equal(r.next, undefined)

  // not live: no sign-up; several live: name one; none live
  campaigns = { 'agent-season': { ...LIVE, status: 'ended' } }
  walletRow = null
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.success, false); assert.match(r.error, /not open for sign-up/)
  live = [{ slug: 'a' }, { slug: 'b' }]
  r = await run(['campaign'])
  assert.equal(r.success, false); assert.deepEqual(r.campaigns, ['a', 'b'])
  live = []
  r = await run(['campaign'])
  assert.equal(r.success, true); assert.deepEqual(r.live, [])
  r = await run(['campaign', 'join'])
  assert.equal(r.success, false); assert.match(r.error, /no gang.fun campaign is live/)
} finally {
  server.close()
  rmSync(dir, { recursive: true, force: true })
}
console.log('campaign: ok')
