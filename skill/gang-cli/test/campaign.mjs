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

const { joinTypedData, summary, mineOf, noteFor, joinClosed, takesJoin, CAMPAIGN_DOMAIN, CAMPAIGN_NOTE, CAMPAIGN_NOTE_CLOSED, CAMPAIGN_NOTE_LIST } = await import('../src/campaign.js')
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
// sign-up closed by the config: the note says so, keeps the safety rule and never sends to `campaign join`
for (const n of [CAMPAIGN_NOTE_CLOSED, CAMPAIGN_NOTE_LIST]) {
  assert.match(n, /never trade only to earn tickets/i)
  assert.match(n, /never on your own/i)
  assert.match(n, /user's decision, previewed and confirmed/)
  assert.doesNotMatch(n, /campaign join|same base ticket/)
}
assert.match(CAMPAIGN_NOTE_CLOSED, /sign-up is closed/)
assert.match(CAMPAIGN_NOTE_CLOSED, /as the campaign's rules say \(see notice/)
assert.doesNotMatch(CAMPAIGN_NOTE_CLOSED, /GANG 3\.0|any amount/, 'no campaign-specific rule in the CLI: the notice carries it')
assert.match(CAMPAIGN_NOTE_CLOSED, /signed up earlier keep/)
assert.equal(joinClosed({ rules: { ticket: { join: false } } }), true)
assert.equal(joinClosed({ rules: { ticket: {} } }), true, 'no join key = closed (the server refuses a join without it)')
assert.equal(joinClosed({ rules: {} }), true)
assert.equal(joinClosed({ rules: { ticket: { join: true } } }), false)
assert.equal(takesJoin({ status: 'live', tickets: {}, rules: { ticket: {} } }), false, 'no join key')
assert.equal(noteFor({ rules: { ticket: { join: true } } }), CAMPAIGN_NOTE)
assert.equal(takesJoin({ status: 'live', tickets: {}, rules: { ticket: { join: true } } }), true)
assert.equal(takesJoin({ status: 'live', tickets: {}, rules: { ticket: { join: false } } }), false, 'sign-up closed')
assert.equal(takesJoin({ status: 'live', tickets: null, rules: { ticket: { join: true } } }), false, 'no tickets')
assert.equal(takesJoin({ status: 'ended', tickets: {}, rules: { ticket: { join: true } } }), false, 'not live')
assert.equal(takesJoin(null), false)
assert.equal(noteFor({ rules: { ticket: { join: false } } }), CAMPAIGN_NOTE_CLOSED)
{
  const s = summary({ slug: 'x', status: 'live', window: {}, rules: { ticket: { join: false }, page: { notice_en: '  Sign-up closed.  ' } } })
  assert.equal(s.notice, 'Sign-up closed.'); assert.equal(s.signUp, 'closed')
  const o = summary({ slug: 'x', status: 'live', window: {}, rules: { ticket: { join: true }, page: { notice_en: 7 } } })
  assert.equal(o.notice, undefined); assert.equal(o.signUp, undefined)
}

// --- the CLI against a fake gang.fun and a fake baw ---
const LIVE = {
  now, slug: 'agent-season', type: 'onboarding', title: { zh: '入帮季', en: 'Agent Season' }, status: 'live',
  window: { start: now - 3600, end: now + 86400 }, tickets: { total: 10, holders: 8, prizes_now: 1 }, lottery: { status: 'open' },
  rules: { ticket: { enabled: true, min_u: 0, join: true } },
}
let campaigns = { 'agent-season': LIVE }
let live = [{ slug: 'agent-season' }]
let walletRow = null
let joinAnswer = { status: 200, body: { ok: true, wallet: acct.address.toLowerCase(), joined_at: now, tickets: 1 } }
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
  r = await run(['campaign', 'AGENT-SEASON'])
  assert.equal(r.campaign.slug, 'agent-season', 'slugs are case-insensitive')
  r = await run(['campaign', 'agent-season', 'join'])
  assert.equal(r.success, false); assert.match(r.error, /unexpected "join"/)
  r = await run(['campaign', 'nope'])
  assert.equal(r.success, false); assert.match(r.error, /no campaign nope/)

  // join: signed out → refused; preview signs nothing; --yes signs and posts a signature the server can recover
  r = await run(['campaign', 'join'], { withBaw: false })
  assert.equal(r.success, false); assert.match(r.error, /sign in to baw/)
  r = await run(['campaign', 'join'])
  assert.equal(r.preview, true)
  assert.equal(r.join.wallet, acct.address.toLowerCase())
  assert.match(r.signs, /no transaction/)
  assert.equal(r.confirm, 'gang campaign join agent-season --yes', 'confirm names the campaign that was previewed')
  assert.equal(posted.length, 0, 'a preview sends nothing')
  r = await run(['campaign', 'join', 'agent-season', '--yes'])
  assert.equal(r.success, true, JSON.stringify(r))
  assert.equal(r.joined, true)
  assert.equal(r.tickets, 1)
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
  joinAnswer = { status: 400, body: { error: 'expired', message: 'signature expired' } }
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.success, false); assert.equal(r.retry, 'same command again', 'expired: running it again signs anew')
  joinAnswer = { status: 200, body: { ok: true, wallet: acct.address.toLowerCase(), joined_at: now, tickets: 0 } }
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.tickets, 0, 'a count of 0 is kept')

  // the wallet row says not_new: refused before anything is signed
  walletRow = { status: 'not_new', tickets: { base: 0, revisit: 0, invite: 2, total: 2 } }
  let n = posted.length
  r = await run(['campaign'])
  assert.equal(r.next, undefined, 'no sign-up hint for an old wallet')
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.success, false); assert.equal(r.apiCode, 'not_new'); assert.equal(posted.length, n)
  walletRow = { status: 'excluded', tickets: { base: 0, revisit: 0, invite: 0, total: 0 } }
  r = await run(['campaign'])
  assert.equal(r.next, undefined)
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.success, false); assert.equal(r.apiCode, 'not_eligible'); assert.equal(posted.length, n, 'nothing signed or sent')
  walletRow = null

  // sign-up closed by the campaign's config (rules.ticket.join = false): no hint, no signature, the notice comes through
  const NOTICE = 'Free sign-up is closed: the base ticket now comes from a first buy or mint on GANG 3.0.'
  campaigns = { 'agent-season': { ...LIVE, rules: { ticket: { enabled: true, join: false }, page: { notice_en: NOTICE } } } }
  r = await run(['campaign'], { withBaw: false })
  assert.equal(r.success, true)
  assert.equal(r.next, undefined, 'no next once the sign-up closed (and never one that points to a trade)')
  assert.equal(r.campaign.notice, NOTICE); assert.equal(r.campaign.signUp, 'closed')
  assert.equal(r.note, CAMPAIGN_NOTE_CLOSED)
  r = await run(['campaign'])
  assert.equal(r.next, undefined); assert.equal(r.note, CAMPAIGN_NOTE_CLOSED)
  for (const a of [['campaign', 'join'], ['campaign', 'join', '--yes']]) {
    r = await run(a)
    assert.equal(r.success, false); assert.equal(r.apiCode, 'closed'); assert.equal(r.code, 'ERROR')
    assert.match(r.error, /sign-up for agent-season is closed/); assert.match(r.error, /signed up earlier keep their ticket/)
    assert.match(r.error, /Nothing was signed or sent/); assert.match(r.error, /gang\.fun\/campaign\/agent-season/)
    assert.doesNotMatch(r.error, /GANG 3\.0/)
    assert.equal(r.preview, undefined); assert.equal(r.confirm, undefined, 'nothing to confirm or sign')
    assert.equal(r.campaign.notice, NOTICE)
    assert.equal(posted.length, n)
  }
  r = await run(['campaign', 'join'], { withBaw: false })
  assert.equal(r.apiCode, 'closed', 'closed is said before asking to sign in')
  // an earlier sign-up keeps its ticket
  walletRow = { status: 'entered', tickets: { base: 1, revisit: 0, invite: 0, total: 1 }, joined_at: now - 60 }
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.success, true); assert.equal(r.alreadyJoined, true); assert.equal(r.mine.tickets.base, 1); assert.equal(posted.length, n)
  // joined but excluded afterwards: not eligible, never alreadyJoined
  walletRow = { status: 'excluded', tickets: { base: 0, revisit: 0, invite: 0, total: 0 }, joined_at: now - 60 }
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.success, false); assert.equal(r.apiCode, 'not_eligible'); assert.equal(r.alreadyJoined, undefined); assert.equal(posted.length, n)
  walletRow = null
  campaigns = { 'agent-season': LIVE }

  // the server closed it after the CLI read the open config: 409 closed comes back as the same clear refusal
  joinAnswer = { status: 409, body: { error: 'closed', message: 'sign-up is closed' } }
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.success, false); assert.equal(r.apiCode, 'closed'); assert.equal(r.code, 'ERROR')
  assert.match(r.error, /sign-up for agent-season is closed/); assert.equal(r.retry, undefined)
  assert.match(r.error, /signed up earlier keep their ticket/); assert.match(r.error, /never trade only to earn tickets/i)
  n = posted.length

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

  // not live: no sign-up; a wallet that joined still reads alreadyJoined, an excluded one is refused
  campaigns = { 'agent-season': { ...LIVE, status: 'ended' } }
  walletRow = { status: 'entered', tickets: { base: 1, revisit: 0, invite: 0, total: 1 }, joined_at: now - 60 }
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.success, true); assert.equal(r.alreadyJoined, true)
  walletRow = { status: 'excluded', tickets: { base: 0, revisit: 0, invite: 0, total: 0 }, joined_at: now - 60 }
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.success, false); assert.equal(r.apiCode, 'not_eligible')
  walletRow = null
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.success, false); assert.match(r.error, /not open for sign-up/)
  // two live campaigns: status lists both; join without a slug takes the one whose sign-up is open
  const OPEN = (slug) => ({ ...LIVE, slug })
  const SHUT = (slug) => ({ ...LIVE, slug, rules: { ticket: { enabled: true, join: false } } })
  live = [{ slug: 'a' }, { slug: 'b' }]
  campaigns = { a: OPEN('a'), b: SHUT('b') }
  r = await run(['campaign'])
  assert.equal(r.success, true); assert.deepEqual(r.live.map((x) => x.slug), ['a', 'b'])
  assert.equal(r.note, CAMPAIGN_NOTE_LIST)
  n = posted.length
  r = await run(['campaign', 'join'])
  assert.equal(r.success, true, JSON.stringify(r)); assert.equal(r.preview, true)
  assert.equal(r.join.campaign, 'a'); assert.equal(r.confirm, 'gang campaign join a --yes')
  campaigns = { a: SHUT('a'), b: OPEN('b') }
  joinAnswer = { status: 200, body: { ok: true, wallet: acct.address.toLowerCase(), joined_at: now, tickets: 1 } }
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.success, true, JSON.stringify(r)); assert.equal(r.joined, true); assert.equal(posted.at(-1).slug, 'b')
  n = posted.length
  // both open: asks for one, listing only those that take a sign-up
  live = [{ slug: 'a' }, { slug: 'b' }, { slug: 'c' }]
  campaigns = { a: OPEN('a'), b: OPEN('b'), c: SHUT('c') }
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.success, false); assert.deepEqual(r.campaigns, ['a', 'b']); assert.match(r.error, /name one/)
  assert.equal(posted.length, n, 'nothing signed or sent')
  // none open (one closed, one without tickets): says so, nothing signed
  live = [{ slug: 'a' }, { slug: 'b' }]
  campaigns = { a: SHUT('a'), b: { ...OPEN('b'), tickets: null } }
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.success, false); assert.equal(r.apiCode, 'closed'); assert.deepEqual(r.campaigns, ['a', 'b'])
  assert.match(r.error, /no live gang\.fun campaign takes a free sign-up/); assert.match(r.error, /never trade only to earn tickets/i)
  assert.equal(r.preview, undefined); assert.equal(posted.length, n)
  // one live campaign that takes no sign-up: the same refusal shape (apiCode closed, live slugs in campaigns)
  live = [{ slug: 'a' }]
  r = await run(['campaign', 'join'])
  assert.equal(r.success, false); assert.match(r.error, /sign-up for a is closed/)
  assert.equal(r.apiCode, 'closed'); assert.equal(r.code, 'ERROR'); assert.deepEqual(r.campaigns, ['a'])
  campaigns = { a: { ...OPEN('a'), rules: { ticket: { enabled: true } } } }
  r = await run(['campaign', 'join'])
  assert.equal(r.apiCode, 'closed', 'a config without ticket.join takes no sign-up'); assert.deepEqual(r.campaigns, ['a'])
  campaigns = { a: { ...OPEN('a'), tickets: null } }
  r = await run(['campaign', 'join'])
  assert.equal(r.success, false); assert.equal(r.apiCode, 'closed'); assert.deepEqual(r.campaigns, ['a'])
  assert.match(r.error, /no live gang\.fun campaign takes a free sign-up/); assert.equal(posted.length, n)
  // with a slug, no campaigns list
  r = await run(['campaign', 'join', 'a'])
  assert.equal(r.success, false); assert.equal(r.campaigns, undefined)
  campaigns = { 'agent-season': LIVE }
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
