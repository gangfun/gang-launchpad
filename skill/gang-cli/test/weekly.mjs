/**
 * gang weekly (the weekly launch event): the application digest and typed data, baw's signature joined, the flags'
 * checks, and the CLI against a local fake gang.fun and a fake `baw` that signs with a test key (no chain, no wallet).
 * Also the `event` row in gang trending.
 *
 *   node skill/gang-cli/test/weekly.mjs
 */
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { createServer } from 'node:http'
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'
import { keccak256, recoverTypedDataAddress, toBytes } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'

const dir = mkdtempSync(join(tmpdir(), 'gang-weekly-'))
process.env.GANG_TRENDING_CACHE = join(dir, 'trending.json')
const { canonical, applicationDigest, typedData, joinSignature, normalizeTelegram, applicationFields, eventRow, isHold, HOLD_NOTE, HOLD_SUBMITTED, WEEKLY_DOMAIN, WEEKLY_NOTE } = await import('../src/weekly.js')
const CLI = fileURLToPath(new URL('../src/index.js', import.meta.url))

// a throwaway test key (anvil's account #1), never a real wallet
const KEY = '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d'
const acct = privateKeyToAccount(KEY)
const CID = `b${'a'.repeat(58)}`
const now = Math.floor(Date.now() / 1000)

// --- pure parts ---
assert.equal(canonical({ b: 1, a: [{ d: 'x', c: null }], e: undefined }), '{"a":[{"c":null,"d":"x"}],"b":1}')
assert.equal(canonical('中'), '"中"')
{
  const app = { issue: '2026-11-13', wallet: acct.address, name: 'N', symbol: 'S', logo: `ipfs://${CID}`, description: 'd', contact: '@c' }
  const d = applicationDigest(app)
  assert.equal(d, keccak256(toBytes(canonical({ ...app, wallet: acct.address.toLowerCase() }))))
  assert.equal(applicationDigest({ ...app, wallet: acct.address.toLowerCase() }), d, 'wallet case does not change the digest')
  assert.notEqual(applicationDigest({ ...app, contact: '@other' }), d)
  const td = typedData('WeeklyApply', { wallet: acct.address, issue: app.issue, digest: d, expires: 1 })
  assert.deepEqual(td.domain, { name: 'gang.fun weekly launch', version: '1', chainId: 56 })
  assert.deepEqual(td.types.EIP712Domain.map((x) => x.name), ['name', 'version', 'chainId'])
  assert.deepEqual(Object.keys(td.types), ['EIP712Domain', 'WeeklyApply'])
}
{
  const rs = 'ab'.repeat(64)
  assert.equal(joinSignature(rs, '00'), `0x${rs}1b`)
  assert.equal(joinSignature(rs, '01'), `0x${rs}1c`)
  assert.equal(joinSignature(`${rs}1c`, null), `0x${rs}1c`)
  assert.throws(() => joinSignature('', '00'))
  assert.throws(() => joinSignature(rs, undefined), /recovery/)
  assert.throws(() => joinSignature(rs, '05'))
}
assert.equal(normalizeTelegram('@gang_fun'), 'https://t.me/gang_fun')
assert.equal(normalizeTelegram('t.me/gang_fun/'), 'https://t.me/gang_fun')
assert.equal(normalizeTelegram('https://t.me/+AbC-12'), 'https://t.me/+AbC-12')
assert.equal(normalizeTelegram(''), '')
assert.throws(() => normalizeTelegram('https://evil.com/gang'), /bad_telegram/)
{
  const io = (o) => ({ opt: (k) => o[k], flag: (k) => k in o })
  const base = { name: 'Moon', symbol: 'MOON', description: 'why', contact: '@me' }
  assert.deepEqual(applicationFields(io(base)), base)
  const all = applicationFields(io({ ...base, twitter: '@moon', telegram: '@moonchat', website: 'moon.xyz', modules: 'LP, buyback,lp' }))
  assert.deepEqual(all, { ...base, x: 'https://x.com/moon', tg: 'https://t.me/moonchat', website: 'https://moon.xyz/', modules: ['lp', 'buyback'] })
  assert.throws(() => applicationFields(io({ ...base, modules: 'lp,rocket' })), /modules knows/)
  assert.throws(() => applicationFields(io({ ...base, name: 'x'.repeat(33) })), /name is at most 32/)
  assert.throws(() => applicationFields(io({ ...base, symbol: 'TOO LONG' })), /symbol/)
  assert.throws(() => applicationFields(io({ ...base, symbol: '$MOON' })), /symbol/)
  assert.equal(applicationFields(io({ ...base, symbol: '月猫' })).symbol, '月猫')
  assert.throws(() => applicationFields(io({ ...base, name: 'a\nb' })), /name/)
  assert.throws(() => applicationFields(io({ ...base, contact: '@a\u0007' })), /contact/)
  assert.throws(() => applicationFields(io({ ...base, website: 'http://moon.xyz' })), /https/)
  assert.throws(() => applicationFields(io({ ...base, name: 'A\u202Eevil' })), /name/)
  assert.throws(() => applicationFields(io({ ...base, description: 'ok\u0000' })), /description/)
  assert.throws(() => applicationFields(io({ ...base, contact: '@a\u200b' })), /contact/)
  assert.equal(applicationFields(io({ ...base, description: 'line 1\nline 2\tok' })).description, 'line 1\nline 2\tok')
  assert.equal(applicationFields(io({ ...base, description: 'a\r\nb\rc' })).description, 'a\nb\nc')
  for (const ch of ['\u2060', '\ufeff', '\u00ad']) assert.throws(() => applicationFields(io({ ...base, name: `A${ch}B` })), /name/)
  assert.throws(() => applicationFields(io({ ...base, contact: undefined })), /contact is required/)
  assert.throws(() => applicationFields(io({ ...base, twitter: 'https://evil.com/x' })), (e) => e.field === 'twitter')
  assert.equal(applicationFields(io({ ...base, name: '月'.repeat(32) })).name.length, 32, 'characters, not bytes')
}
assert.equal(eventRow(null), null)
assert.equal(eventRow({ kind: 'other', issue: 'x' }), null)
{
  const e = eventRow({ kind: 'weekly-launch', issue: '2026-11-13', number: 1, status: 'teaser', symbol: 'MOON', launchAt: now + 60, until: now + 99, token: null, extra: 'dropped' })
  assert.equal(e.note, WEEKLY_NOTE)
  assert.equal(e.url, 'https://gang.fun/weekly')
  assert.ok(e.launchAtLocal)
  assert.equal(e.extra, undefined)
}
{
  // the event is shown as Launch Day; the command, the kind and the EIP-712 domain keep "weekly"
  const { COMMANDS } = await import('../src/capabilities.js')
  const { INSTRUCTIONS, RULES, TOOLS } = await import('../src/mcp.js')
  const help = (await promisify(execFile)(process.execPath, [fileURLToPath(new URL('../src/index.js', import.meta.url)), 'help'], { env: { ...process.env, GANG_TELEMETRY: '0', GANG_UPDATE_CHECK: '0' } })).stdout
  const weeklyCaps = COMMANDS.filter((c) => /^weekly/.test(c.command)).map((c) => c.summary).join('\n')
  const shown = [WEEKLY_NOTE, help, weeklyCaps, INSTRUCTIONS, RULES.join('\n'), TOOLS.map((t) => t.description).join('\n')].join('\n')
  assert.match(WEEKLY_NOTE, /Launch Day/)
  assert.match(help, /gang weekly +Gang's Launch Day event/)
  assert.equal(weeklyCaps.split('Launch Day').length - 1, 3, 'weekly, apply and withdraw')
  assert.doesNotMatch(shown, /weekly launch|weekly event|week's pick/i)
  assert.doesNotMatch(shown, /Gang Weekly/, 'the gang weekly command is fine, the old title is not')
  assert.equal(WEEKLY_DOMAIN.name, 'gang.fun weekly launch', 'the signing domain stays')
}
// hold: the server's flag, or an open issue without a closing date / launch time
{
  const t = now
  assert.equal(isHold(null), false)
  assert.equal(isHold({ apply: { open: true, closesAt: t, launchAt: t } }), false, 'the weekly cadence')
  assert.equal(isHold({ hold: false, apply: { open: true, closesAt: t, launchAt: t } }), false)
  assert.equal(isHold({ hold: true, apply: { open: true, closesAt: t, launchAt: t } }), true)
  assert.equal(isHold({ apply: { open: true, closesAt: t, launchAt: t, hold: true } }), true)
  assert.equal(isHold({ apply: { open: true, closesAt: null, launchAt: null } }), true, 'an old server with null times')
  assert.equal(isHold({ hold: false, apply: { open: true, closesAt: null, launchAt: null } }), true, 'null times never name a Friday')
  assert.equal(isHold({ apply: { open: false, closesAt: null, launchAt: null } }), false)
  assert.equal(eventRow({ kind: 'weekly-launch', issue: '2026-11-20', status: 'apply', launchAt: null, until: null, hold: true }).hold, true)
  assert.equal(eventRow({ kind: 'weekly-launch', issue: '2026-11-20', status: 'teaser', launchAt: t }).hold, undefined)
  assert.doesNotMatch(HOLD_NOTE + HOLD_SUBMITTED, /friday|thursday|20:00|12:00|each week|every week/i)
}

// --- the CLI against a fake gang.fun and a fake baw ---
const ISSUE = '2026-11-13'
const board = (open = true) => ({
  now, rules: { pad: 'GangLaunchpad 3.0 V3 curve', featuredDays: 7, revokeSellBps: 2000 },
  apply: { issue: ISSUE, number: 1, opensAt: now - 3600, closesAt: now + 3600, open, launchAt: now + 86400 },
  current: null, past: [],
})
let weekly = board(), posted = [], applyAnswer = { status: 200, body: { ok: true, issue: ISSUE, status: 'pending', replaced: false } }
let trendingBody = { at: now, tokens: [], calls: [] }
let application = null
let applications = {}
const CID2 = `b${'b'.repeat(58)}` // a cid gang.fun does not have
const server = createServer((req, res) => {
  const send = (status, body, type = 'application/json') => res.writeHead(status, { 'content-type': type }).end(typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body))
  const url = new URL(req.url, 'http://x')
  if (req.method === 'GET' && url.pathname === `/ipfs/${CID}`) return send(200, Buffer.from([0x89, 0x50]), 'image/png')
  if (req.method === 'GET' && url.pathname === '/api/weekly') return send(200, weekly)
  if (req.method === 'GET' && url.pathname === '/api/trending') return send(200, trendingBody)
  if (req.method === 'GET' && url.pathname === '/api/weekly/application') {
    // per issue, as gang.fun answers: `application` (one row) or `applications` (by issue)
    const a = applications[url.searchParams.get('issue')] ?? (application?.issue === url.searchParams.get('issue') ? application : null)
    return a ? send(200, a) : send(404, { error: 'not_found' })
  }
  if (req.method === 'POST' && url.pathname.startsWith('/api/weekly/')) {
    let b = ''
    req.on('data', (c) => { b += c })
    req.on('end', () => {
      posted.push({ path: url.pathname, body: JSON.parse(b) })
      send(applyAnswer.status, url.pathname === '/api/weekly/withdraw' ? { ok: true, status: 'withdrawn' } : applyAnswer.body)
    })
    return
  }
  send(404, { error: 'not_found' })
})
await new Promise((r) => server.listen(0, '127.0.0.1', r))
const base = `http://127.0.0.1:${server.address().port}`

// fake baw: signed in as the test key's address; sign-message preview stores the message, execute signs it like baw
// answers (r‖s hex without 0x, recovery '00' / '01')
const bin = join(dir, 'bin')
const signer = join(dir, 'sign.mjs')
writeFileSync(signer, `import { readFileSync } from 'node:fs'
import { privateKeyToAccount } from ${JSON.stringify(fileURLToPath(new URL('../node_modules/viem/_esm/accounts/index.js', import.meta.url)))}
const m = JSON.parse(readFileSync(process.argv[2], 'utf8'))
if (m.params[0] !== ${JSON.stringify(acct.address)}) { console.log(JSON.stringify({ success: false, error: { code: 2, message: 'EIP712 signer address must match current wallet address' } })); process.exit(1) }
const td = JSON.parse(m.params[1]); const { EIP712Domain, ...types } = td.types
const sig = await privateKeyToAccount(${JSON.stringify(KEY)}).signTypedData({ domain: td.domain, types, primaryType: td.primaryType, message: td.message })
console.log(JSON.stringify({ success: true, data: { orderId: 'o1', status: 'COMPLETED', signature: sig.slice(2, 130), signatureRecovery: sig.slice(130) === '1b' ? '00' : '01', message: null } }))
`)
await promisify(execFile)('mkdir', ['-p', bin])
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
    ...process.env, GANG_API: `${base}/api`, GANG_CDN_BASE: base, GANG_TELEMETRY: '0', GANG_UPDATE_CHECK: '0',
    GANG_TRENDING_CACHE: join(dir, `trending-${Math.random()}.json`), PATH: withBaw ? `${bin}:/usr/bin:/bin` : '/usr/bin:/bin',
  }
  try { return JSON.parse((await promisify(execFile)(process.execPath, [CLI, ...cliArgs], { env, encoding: 'utf8' })).stdout) } catch (e) { return JSON.parse(e.stdout) }
}
const APPLY = ['weekly', 'apply', '--name', 'Moon Cat', '--symbol', 'MCAT', '--logo-uri', `ipfs://${CID}`, '--description', 'A cat on the moon.',
  '--contact', '@mooncat', '--twitter', '@mooncat', '--modules', 'lp,buyback']

try {
  // status, signed out and signed in
  let r = await run(['weekly'], { withBaw: false })
  assert.equal(r.success, true)
  assert.equal(r.apply.issue, ISSUE)
  assert.ok(r.apply.closesAtLocal)
  assert.equal(r.mine, undefined, 'no wallet → no mine')
  assert.match(r.next, /gang weekly apply/)
  r = await run(['weekly'])
  assert.deepEqual(r.mine, [])
  application = { issue: ISSUE, wallet: acct.address.toLowerCase(), status: 'pending', submittedAt: now, symbol: 'MCAT' }
  r = await run(['weekly'])
  assert.equal(r.mine.length, 1); assert.equal(r.mine[0].status, 'pending')
  application = null

  // preview: nothing signed or sent
  r = await run(APPLY)
  assert.equal(r.success, true)
  assert.equal(r.preview, true)
  assert.equal(r.application.wallet, acct.address.toLowerCase())
  assert.equal(r.application.logo, `ipfs://${CID}`)
  assert.match(r.confirm, /^gang weekly apply .*'Moon Cat'.* --yes$/)
  assert.equal(r.application.x, 'https://x.com/mooncat')
  assert.deepEqual(r.application.modules, ['lp', 'buyback'])
  assert.ok(r.terms.some((t) => t.includes('20%')))
  assert.equal(posted.length, 0)

  // --yes: signs with the wallet and posts; the server's check passes on what was sent
  r = await run([...APPLY, '--yes'])
  assert.equal(r.success, true, JSON.stringify(r))
  assert.equal(r.status, 'pending')
  assert.equal(posted.length, 1)
  const { application: app, expires, signature } = posted[0].body
  assert.equal(app.wallet, acct.address.toLowerCase())
  assert.equal(app.logo, `ipfs://${CID}`)
  assert.equal(app.contact, '@mooncat')
  assert.ok(expires > now && expires <= now + 3600 + 5)
  assert.match(signature, /^0x[0-9a-f]{130}$/)
  const { EIP712Domain, ...types } = typedData('WeeklyApply', {}).types
  const who = await recoverTypedDataAddress({ domain: WEEKLY_DOMAIN, types, primaryType: 'WeeklyApply', message: { wallet: app.wallet, issue: app.issue, digest: applicationDigest(app), expires: BigInt(expires) }, signature })
  assert.equal(who, acct.address)

  // the server refuses: its code and field come through, exit 1
  applyAnswer = { status: 400, body: { error: 'no_agent_id', message: 'this wallet has no Agent ID' } }
  r = await run([...APPLY, '--yes'])
  assert.equal(r.success, false)
  assert.equal(r.apiCode, 'no_agent_id')
  applyAnswer = { status: 200, body: { ok: true, issue: ISSUE, status: 'pending', replaced: true } }

  // refused before anything: closed, missing fields, unknown flags, a logo not on gang.fun, signed out
  weekly = board(false)
  r = await run([...APPLY, '--yes'])
  assert.equal(r.success, false)
  assert.match(r.error, /not open/)
  weekly = board()
  r = await run(['weekly', 'apply', '--name', 'X', '--symbol', 'X', '--description', 'd', '--logo-uri', `ipfs://${CID}`])
  assert.equal(r.success, false); assert.equal(r.field, 'contact')
  r = await run([...APPLY.filter((a, i) => i < 6 || i > 7)])
  assert.equal(r.success, false); assert.equal(r.field, 'logo')
  r = await run([...APPLY, '--x', '@a'])
  assert.equal(r.success, false); assert.match(r.error, /does not take --x/)
  r = await run([...APPLY, '--keep-logo-uri'])
  assert.equal(r.success, false)
  r = await run([...APPLY.slice(0, 6), '--logo', join(dir, 'missing.png'), ...APPLY.slice(8)])
  assert.equal(r.success, false); assert.equal(r.field, 'logo'); assert.match(r.error, /no file/)
  r = await run([...APPLY, '--logo', join(dir, 'sign.mjs')])
  assert.equal(r.success, false); assert.match(r.error, /not both/)
  r = await run(APPLY, { withBaw: false })
  assert.equal(r.success, false); assert.match(r.error, /sign in to baw/)
  r = await run([...APPLY, '--issue', 'friday'])
  assert.equal(r.success, false); assert.match(r.error, /--issue/)
  assert.equal(posted.length, 2, 'nothing refused above reached gang.fun')

  // the weekly cadence names the launch and pick times, never "hold"
  r = await run(APPLY)
  assert.equal(r.hold, undefined)
  assert.match(r.terms[0], /at \d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC/)
  r = await run(['weekly'])
  assert.equal(r.hold, undefined); assert.equal(r.holdNote, undefined); assert.equal(r.apply.hold, undefined)
  r = await run([...APPLY, '--yes'])
  assert.match(r.note, /^Submitted\. The team picks one application on \d{4}-/)

  // hold: an open pool with no closing date or launch time; nothing names a day, a time or a cadence
  const HOLD_ISSUE = '2026-11-20'
  const held = { now, hold: true, rules: board().rules, apply: { issue: HOLD_ISSUE, number: 2, opensAt: now - 86400, closesAt: null, open: true, launchAt: null, hold: true }, picking: null, current: null, live: [], past: [] }
  const noDay = /friday|thursday|20:00|12:00|each week|every week|week's pick/i
  for (const b of [held, { ...held, hold: undefined, apply: { ...held.apply, hold: undefined } }]) {
    weekly = b
    r = await run(['weekly'])
    assert.equal(r.success, true)
    assert.equal(r.hold, true); assert.equal(r.apply.hold, true)
    assert.equal(r.apply.closesAtLocal, undefined); assert.equal(r.apply.launchAtLocal, undefined)
    assert.equal(r.holdNote, HOLD_NOTE)
    assert.match(r.next, /gang weekly apply/)
    r = await run(APPLY)
    assert.equal(r.success, true); assert.equal(r.preview, true); assert.equal(r.hold, true); assert.equal(r.issue, HOLD_ISSUE)
    assert.match(r.terms[0], /arranged with the gang\.fun team and announced on gang\.fun\/weekly/)
    assert.doesNotMatch(JSON.stringify(r), noDay)
    const n = posted.length
    r = await run([...APPLY, '--yes'])
    assert.equal(r.success, true, JSON.stringify(r)); assert.equal(r.hold, true)
    assert.equal(r.note, HOLD_SUBMITTED)
    assert.doesNotMatch(JSON.stringify(r), noDay)
    assert.equal(posted.length, n + 1); assert.equal(posted.at(-1).body.application.issue, HOLD_ISSUE)
    // another issue than the open pool: refused without a closing date or "null"
    r = await run([...APPLY, '--issue', '2026-11-27'])
    assert.equal(r.success, false)
    assert.equal(r.error, 'applications for 2026-11-27 are not open (open: 2026-11-20, no closing date)')
  }
  weekly = board()

  // a refused field comes back as USAGE with gang.fun's own code and field
  applyAnswer = { status: 400, body: { error: 'bad_field', field: 'symbol', message: 'bad symbol' } }
  r = await run([...APPLY, '--yes'])
  assert.equal(r.code, 'USAGE'); assert.equal(r.apiCode, 'bad_field'); assert.equal(r.field, 'symbol')
  applyAnswer = { status: 200, body: { ok: true, issue: ISSUE, status: 'pending', replaced: true } }

  // Thursday of week 2: applications for 11-20 closed (apply already points at 11-27) while 11-13's pick is still the
  // featured current; the 11-20 application must still show, with the older ones, newest first
  weekly = { ...board(), apply: { ...board().apply, issue: '2026-11-27', number: 3 }, current: { issue: ISSUE, number: 1, status: 'featured', launchAt: now - 86400 * 6 } }
  const row = (issue, status) => ({ issue, wallet: acct.address.toLowerCase(), status, submittedAt: now, symbol: 'MCAT' })
  applications = { '2026-11-20': row('2026-11-20', 'pending'), [ISSUE]: row(ISSUE, 'not_selected') }
  r = await run(['weekly'])
  assert.deepEqual(r.mine.map((m) => [m.issue, m.status]), [['2026-11-20', 'pending'], [ISSUE, 'not_selected']])
  assert.deepEqual(r.live.map((v) => v.issue), [ISSUE], 'no live list from the server: current when it is live')
  weekly = { ...weekly, live: [{ issue: '2026-11-20', number: 2, status: 'teaser', launchAt: now + 86400 }, { issue: ISSUE, number: 1, status: 'featured', launchAt: now - 6 * 86400 }] }
  r = await run(['weekly'])
  assert.deepEqual(r.live.map((v) => [v.issue, v.status]), [['2026-11-20', 'teaser'], [ISSUE, 'featured']])
  assert.ok(r.live[0].launchAtLocal)
  applications = {}
  weekly = board()

  // an ipfs:// logo gang.fun doesn't have is refused in the preview, without offering --keep-logo-uri
  r = await run([...APPLY.slice(0, 6), '--logo-uri', `ipfs://${CID2}`, ...APPLY.slice(8)])
  assert.equal(r.success, false); assert.equal(r.field, 'logo'); assert.doesNotMatch(JSON.stringify(r), /keep-logo-uri/)

  // withdraw: refused once closed; needs an application; preview, then --yes signs WeeklyWithdraw
  weekly = board(false)
  r = await run(['weekly', 'withdraw', '--yes'])
  assert.equal(r.success, false); assert.match(r.error, /closed/)
  weekly = board()
  r = await run(['weekly', 'withdraw'])
  assert.equal(r.success, false); assert.match(r.error, /no application/)
  application = { issue: ISSUE, wallet: acct.address.toLowerCase(), status: 'pending', submittedAt: now, symbol: 'MCAT' }
  const before = posted.length
  r = await run(['weekly', 'withdraw'])
  assert.equal(r.preview, true)
  assert.match(r.confirm, /^gang weekly withdraw --yes$/)
  assert.equal(posted.length, before)
  r = await run(['weekly', 'withdraw', '--yes'])
  assert.equal(r.status, 'withdrawn')
  const w = posted.at(-1)
  assert.equal(w.path, '/api/weekly/withdraw')
  const { EIP712Domain: _, ...wt } = typedData('WeeklyWithdraw', {}).types
  assert.equal(await recoverTypedDataAddress({ domain: WEEKLY_DOMAIN, types: wt, primaryType: 'WeeklyWithdraw', message: { wallet: w.body.wallet, issue: w.body.issue, expires: BigInt(w.body.expires) }, signature: w.body.signature }), acct.address)

  r = await run(['weekly', 'nope'])
  assert.equal(r.success, false)

  // trending: the event row first, with its note; a list that only has the event is not "empty"
  // the overlap: next week's teaser (newest first) and this week's featured pick, plus a malformed row left out
  trendingBody = { at: now, tokens: [], calls: [], events: [
    { kind: 'weekly-launch', issue: '2026-11-20', number: 2, status: 'teaser', symbol: 'NEXT', launchAt: now + 86400, until: null, token: null },
    { kind: 'weekly-launch', issue: ISSUE, number: 1, status: 'featured', symbol: 'MCAT', launchAt: now - 6 * 86400, until: now + 86400, token: { address: `0x${'11'.repeat(20)}`, symbol: 'MCAT', progressPct: 3 } },
    { kind: 'other' },
  ] }
  r = await run(['trending'], { withBaw: false })
  assert.equal(r.success, true)
  assert.equal(Object.keys(r)[2], 'events', 'events come right after at')
  assert.deepEqual(r.events.map((e) => e.issue), ['2026-11-20', ISSUE])
  assert.equal(r.events[1].token.address, `0x${'11'.repeat(20)}`)
  assert.equal(r.events[0].token, null)
  assert.equal(r.events[0].note, WEEKLY_NOTE)
  assert.equal(r.empty, undefined)
  trendingBody = { at: now, tokens: [], calls: [] }
  r = await run(['trending'], { withBaw: false })
  assert.equal(r.events, undefined)
  assert.ok(r.empty)

  console.log('weekly: ok')
} finally {
  server.close()
  rmSync(dir, { recursive: true, force: true })
}
