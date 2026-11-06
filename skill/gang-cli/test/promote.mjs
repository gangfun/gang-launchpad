/**
 * The promoter share without a chain: --promote parsing, when a create asks for the pool module, why a --promoter can't bind,
 * the Merkle check against a real root (BSC testnet, docs/TESTNET-GANG-LAUNCHPAD-3-2026-11-03.md), the status shapes, and the
 * flags refused before any RPC. The on-chain steps are covered by the testnet run in the CLI's release notes.
 *
 *   node skill/gang-cli/test/promote.mjs
 */
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { checkPromoter, cloneCode, firstBuyWarning, promoteField, promoteTermsOf, provenAmount, PROMOTE_PAD_ABI, formatBinding, formatPool, leafOf, parsePromote, poolOf, promoteLine, verifyProof, wantsPoolModule, whyNoBind } from '../src/promote.js'
import { isLaunch } from '../src/launch.js'
import { unknownFlagError, CREATE_ACCEPTS } from '../src/flags.js'
import { toEventSignature, zeroAddress } from 'viem'

const A = '0x1111111111111111111111111111111111111111'
const B = '0x2222222222222222222222222222222222222222'
const C = '0x3333333333333333333333333333333333333333'

// ---- --promote / --promote-days
assert.deepEqual(parsePromote('20'), { shareBps: 2000, windowDays: 30, window: 30 * 86_400 })
assert.deepEqual(parsePromote('0.01', '7'), { shareBps: 1, windowDays: 7, window: 7 * 86_400 })
assert.equal(parsePromote('50', '90').shareBps, 5000)
for (const bad of ['0', '50.01', '100', 'x', '', undefined, '1.234', '-5']) assert.ok(parsePromote(bad).error, `share ${bad}`)
for (const bad of ['6', '91', '7.5', 'x']) assert.ok(parsePromote('10', bad).error, `days ${bad}`)

// ---- when the launch makes the recipient a pool module
const args = (o) => ({ flag: (n) => n in o, opt: (n, d) => (n in o ? o[n] : d) })
const wants = (o, kind = 'v3') => {
  const { flag, opt } = args(o)
  return wantsPoolModule(kind, flag, opt)
}
const taxed = { promote: '20', 'buy-tax': '3', 'sell-tax': '3' }
assert.equal(wants(taxed), true)
assert.equal(wants({ ...taxed, dividend: '40' }), true)
assert.equal(wants({ ...taxed, 'buy-tax': '0' }), true, 'launch.js then refuses it, before any clone')
assert.equal(wants({ promote: '20' }), false, 'untaxed: curve only')
assert.equal(wants({ promote: '20', 'buy-tax': '0', 'sell-tax': '0' }), false)
assert.equal(wants({ ...taxed, dividend: '100' }), false, 'all to holders: nothing reaches a recipient')
assert.equal(wants({ ...taxed, recipient: A }), false, 'a named recipient keeps it on the curve')
for (const m of ['buyback', 'lp', 'split']) assert.equal(wants({ ...taxed, [m]: '50' }), false, `one recipient: ${m}`)
assert.equal(wants({ ...taxed, vault: A }), false)
assert.equal(wants(taxed, 'fair'), false)
assert.equal(wants({ 'buy-tax': '3', 'sell-tax': '3' }), false, 'no --promote')
assert.equal(isLaunch('v3', args(taxed).flag, args(taxed).opt), true)
assert.equal(isLaunch('v3', args({ promote: '20' }).flag, args({ promote: '20' }).opt), false, 'one tx')
assert.equal(unknownFlagError(['--promote', '20', '--promote-days', '30'], CREATE_ACCEPTS, 'gang create'), null)

// ---- what the preview says
assert.match(promoteLine({ shareBps: 2000, windowDays: 30, pool: false, taxed: false }), /Curve only: an untaxed token/)
assert.match(promoteLine({ shareBps: 2000, windowDays: 30, pool: false, taxed: true }), /goes to another recipient/)
const line = promoteLine({ shareBps: 2000, windowDays: 30, pool: true, taxed: true, dividendPct: 50 })
assert.match(line, /about 10% of the tax/)
assert.match(line, /Escrow ends about 37 days after graduation/)
assert.match(line, /reclaim/)
assert.match(line, /only once you claim it/)
assert.match(line, /unlisted contract/)
assert.match(promoteLine({ shareBps: 2000, windowDays: 30, pool: false, taxed: true, dividendPct: 100 }), /all of this token's tax goes to holders/)

// ---- a --promoter that can't bind: the pad would go on with the buy and drop it
const bind = (o = {}) => whyNoBind({ me: A, promoter: B, creator: C, shareBps: 2000, boundPromoter: zeroAddress, traded: false, promoterIsAgent: true, canBind: true, ...o })
assert.equal(bind(), null)
assert.match(bind({ shareBps: 0 }), /without promoter terms/)
assert.match(bind({ promoter: A.toUpperCase().replace('0X', '0x') }), /own promoter/)
assert.match(bind({ promoter: C }), /creator/)
assert.match(bind({ traded: true }), /first trade/)
assert.match(bind({ traded: true, boundPromoter: B }), /already bound/)
assert.match(bind({ promoterIsAgent: false }), /no Agent ID/)
assert.match(bind({ canBind: false }), /canBind/)

// ---- the Merkle check, on the root posted on BSC testnet for 0x1E1b…33DC
const ROOT = '0x4accb7acc1cbb0e388121684457807e18ad3715d891a5a657af53b1c285c044e'
const PROMOTER = '0xfFC8AF739D1dE098888D1E12289C02Fa694693e2', DEV = '0xCa8e63434072B40d3dFE6f5e7Fd885F93A3200b6'
const lp = leafOf(PROMOTER, 1231862562865088n), ld = leafOf(DEV, 967934423293402n)
assert.equal(verifyProof(ROOT, lp, [ld]), true)
assert.equal(verifyProof(ROOT, ld, [lp]), true)
assert.equal(verifyProof(ROOT.toUpperCase().replace('0X', '0x'), ld, [lp]), true)
assert.equal(verifyProof(ROOT, leafOf(PROMOTER, 1231862562865089n), [ld]), false, 'one wei more')
assert.equal(verifyProof(ROOT, leafOf(DEV, 1231862562865088n), [ld]), false, 'someone else')
assert.equal(verifyProof(ROOT, lp, []), false)
assert.equal(provenAmount(ROOT, PROMOTER, { cumulative: '1231862562865088', proof: [ld] }), 1231862562865088n)
for (const bad of [{ cumulative: '1' }, { cumulative: 'x', proof: [ld] }, { proof: [ld] }, { cumulative: '1231862562865088', proof: [] }, { cumulative: '1231862562865088', proof: ['nope'] }]) {
  assert.equal(provenAmount(ROOT, PROMOTER, bad), null, JSON.stringify(bad))
}

// ---- status shapes
const NOW = 2_000_000_000
const zero32 = `0x${'00'.repeat(32)}`
const raw = {
  module: A, dev: B, token: C, quote: A, shareBps: 2000, window: 30 * 86_400, closed: false, escrowOpen: true, firstGradSeenAt: 0n, lastPostAt: 0n,
  escrowIn: 10n, reclaimed: 0n, claimedTotal: 0n, devOwed: 0n, undistributed: 0n, root: zero32, allocatedTotal: 0n, throughBlock: 0n,
  pendingRoot: zero32, pendingAllocated: 0n, pendingThroughBlock: 0n, pendingActiveAt: 0n,
}
const f = (x) => String(x)
const p0 = formatPool(raw, f, NOW, '--token x')
assert.equal(p0.sharePct, 20)
assert.equal(p0.root, null)
assert.equal(p0.pending, null)
assert.equal(p0.next, undefined)
const p1 = formatPool({ ...raw, undistributed: 5n, devOwed: 1n, pendingRoot: ROOT, pendingActiveAt: BigInt(NOW - 1), pendingAllocated: 9n, pendingThroughBlock: 7n }, f, NOW, '--token x')
assert.equal(p1.pending.due, true)
assert.equal(p1.next.length, 3)
assert.match(p1.next[0], /activate/)
assert.equal(formatPool({ ...raw, pendingRoot: ROOT, pendingActiveAt: BigInt(NOW + 1) }, f, NOW).pending.due, false)
assert.equal(formatPool({ ...raw, root: ROOT, allocatedTotal: 3n, throughBlock: 4n }, f, NOW).root.allocated, '3')

assert.equal(formatBinding(zeroAddress, 0, false, 100, NOW).traded, false)
assert.match(formatBinding(zeroAddress, 0, true, 100, NOW).note, /never bind/)
assert.match(formatBinding(zeroAddress, 0, false, 100, NOW, true).note, /can't bind now/)
assert.match(formatBinding(zeroAddress, 0, false, 100, NOW).note, /first buy can name/)
const b1 = formatBinding(A, NOW - 50, true, 100, NOW)
assert.equal(b1.promoter, A)
assert.equal(b1.inWindow, true)
assert.equal(formatBinding(A, NOW - 100, true, 100, NOW).inWindow, false, 'the window ends at boundAt + window')

// ---- a module is what its code says, not what it says about itself
const FACTORY = '0x4444444444444444444444444444444444444444', IMPL = '0x5555555555555555555555555555555555555555'
const read = async (addr, abi, fn) => {
  if (fn === 'implementation') return IMPL
  if (fn === 'token') return C
  if (fn === 'moduleType' || fn === 'factory') throw new Error('never asked')
  return fn === 'closed' || fn === 'escrowOpen' ? false : fn === 'root' || fn === 'pendingRoot' ? zero32 : fn === 'dev' || fn === 'quote' ? B : 0n
}
assert.equal(cloneCode(IMPL).length, 2 + 45 * 2, 'a 45-byte clone')
assert.equal((await poolOf(read, async () => cloneCode(IMPL), A, FACTORY)).token, C)
assert.equal(await poolOf(read, async () => '0x6080', A, FACTORY), null, 'a contract claiming to be one')
assert.equal(await poolOf(read, async () => cloneCode(A), A, FACTORY), null, 'a clone of something else')
assert.equal(await poolOf(read, async () => undefined, A, FACTORY), null, 'a wallet')
assert.equal(await poolOf(read, async () => cloneCode(IMPL), zeroAddress, FACTORY), null)
assert.equal(await poolOf(read, async () => cloneCode(IMPL), A, null), null, 'no factory known')
await assert.rejects(poolOf(read, async () => { throw new Error('rpc') }, A, FACTORY), /rpc/, 'an RPC error is not "not a module"')

// ---- gang tx finds events by their hash: these are the contracts' signatures (src/gang/interfaces/IGangPromote.sol)
const events = Object.fromEntries(PROMOTE_PAD_ABI.filter((x) => x.type === 'event').map((x) => [x.name, toEventSignature(x)]))
assert.equal(events.PromoteSet, 'PromoteSet(address,uint16,uint32)')
assert.equal(events.PromoterBound, 'PromoterBound(address,address,address)')
assert.equal(events.PromoterFeeAccrued, 'PromoterFeeAccrued(address,address,address,uint256)')
assert.equal(events.PromoterFeeClaimed, 'PromoterFeeClaimed(address,address,address,uint256)')

// ---- refused before any RPC
const CLI = fileURLToPath(new URL('../src/index.js', import.meta.url))
const run = (...a) => {
  const r = spawnSync(process.execPath, [CLI, ...a], { encoding: 'utf8', env: { ...process.env, GANG_TELEMETRY: '0', GANG_UPDATE_CHECK: '0' } })
  try { return JSON.parse(r.stdout) } catch { return { raw: r.stdout + r.stderr } }
}
const refused = (a, re) => {
  const o = run(...a)
  assert.equal(o.success, false, `${a.join(' ')} → ${JSON.stringify(o).slice(0, 200)}`)
  assert.match(String(o.error), re, a.join(' '))
}
refused(['promote'], /usage: gang promote/)
refused(['promote', 'nope'], /usage: gang promote/)
refused(['promote', 'buy', '--token', A, '--amount', '1', '--from', A, '--testnet'], /needs --promoter/)
refused(['promote', 'buy', '--token', A, '--amount', '1', '--from', A, '--testnet', '--promotor', A], /needs --promoter/)
refused(['promote', 'status', '--token', 'nope', '--testnet'], /--token must be a V3 token address/)
refused(['promote', 'status', '--token', A, '--module', B, '--testnet'], /not both/)
refused(['promote', 'claim', '--module', B, '--testnet', '--from', A], /needs --token/)
refused(['promote', 'bind', '--module', B, '--testnet', '--from', A], /needs --token/)
const base = ['create', '--name', 'P', '--symbol', 'P', '--from', A, '--testnet']
refused([...base, '--promote', '60'], /--promote takes/)
refused([...base, '--promote', '60', '--buy-tax', '3', '--sell-tax', '3'], /--promote takes/)
refused([...base, '--promote', '10', '--buy-tax', '3', '--sell-tax', '3', '--promote-days', '1'], /--promote-days takes/)
refused([...base, '--promote-days', '10'], /goes with --promote/)
refused([...base, '--fair', '--promote', '10'], /for V3 curve tokens/)
refused(['fair', 'create', '--name', 'P', '--symbol', 'P', '--from', A, '--testnet', '--promote', '10'], /for V3 curve tokens/)
refused([...base, '--promote', '10', '--sell-tax', '3'], /needs both --buy-tax and --sell-tax/)
refused([...base, '--promote', '10', '--buy-tax', '0', '--sell-tax', '3'], /needs both --buy-tax and --sell-tax/)
for (const typo of [['--promoter=' + A], ['--promotor', A], ['--promote', A], ['--promoters', A], ['--promo', A], ['--promotion', A], ['--promoter-address', A], ['--referrer', A]]) {
  refused(['buy', '--token', A, '--amount', '1', '--from', A, '--testnet', ...typo], /did you mean --promoter/)
}
refused(['buy', '--token', A, '--amount', '1', '--from', A, '--testnet', '--yes'], /not a flag of a buy/)
refused([...base, '--promote', '10', '--buy-tax', '3', '--sell-tax', '3', '--dividend', '150'], /--dividend must be/)
refused(['follow', `0x${'12'.repeat(32)}`, '--amount', '1', '--promoter', A, '--testnet'], /gang buy only/)
// a dash a chat app changed, one hyphen, or no hyphen: no parser sees these, so they must not become a plain buy
for (const word of ['-promoter', '\u2014promoter', '\u2013promoter', '\u2014\u2014promoter', '\u2212promoter', '-p', 'promoter', 'Promoter=' + A]) {
  refused(['buy', '--token', A, '--amount', '1', '--from', A, '--testnet', word, A], /is not a flag: flags start with two plain hyphens/)
}
refused([...base, '--fly', '--promote', '10'], /for V3 curve tokens/)
assert.doesNotMatch(String(run('buy', '--token', A, '--amount', '1', '--from', A, '--testnet', '--promoter', 'promoter.ai').error), /is not a flag/)
// ---- the invite's own command gets past the flag checks, by the CLI and through MCP's argument list; a dead node stops it after
{
  const dead = (...a) => {
    const r = spawnSync(process.execPath, [CLI, ...a], { encoding: 'utf8', env: { ...process.env, GANG_TELEMETRY: '0', GANG_UPDATE_CHECK: '0', GANG_TESTNET_RPC_URL: 'http://127.0.0.1:1' } })
    return JSON.parse(r.stdout)
  }
  for (const cmd of [['promote', 'buy'], ['buy']]) {
    const o = dead(...cmd, '--token', A, '--amount', '1', '--promoter', A, '--from', A, '--testnet', '--note', 'Promoted by a friend', '--ref', 'promoter.ai')
    assert.equal(o.success, false)
    assert.match(String(o.error), /RPC error/, JSON.stringify(o))
    assert.doesNotMatch(String(o.error), /is not a flag|did you mean/)
  }
}

// ---- an RPC error is not "no terms": that answer would send a buyer to a plain buy, which can never bind
const rpcDown = Object.assign(new Error('HTTP 429'), { walk: () => null })
const reverted = Object.assign(new Error('execution reverted'), { walk: (f) => (f({ code: 3 }) ? { code: 3 } : null) })
const ctxFailing = (e) => ({ pad: A, gen: '3.0', read: async () => { throw e } })
const T0 = `0x${'cd'.repeat(20)}`
{
  const down = await checkPromoter(ctxFailing(rpcDown), { token: T0, me: A, raw: A, creator: T0 })
  assert.match(down.refuse, /could not read the promoter terms \(RPC error\).*don't switch to a plain gang buy/)
  assert.equal(down.retry, 'same command again')
  const none = await checkPromoter(ctxFailing(reverted), { token: T0, me: A, raw: A, creator: T0 })
  assert.match(none.refuse, /has no promoter share/)
  assert.equal(none.retry, undefined)
  await assert.rejects(promoteTermsOf(ctxFailing(rpcDown), T0), /HTTP 429/)
  assert.equal(await promoteTermsOf(ctxFailing(reverted), T0), null)
  assert.match((await promoteField(ctxFailing(rpcDown), T0)).error, /doesn't mean there are none/)
  assert.equal(await promoteField(ctxFailing(reverted), T0), null)
}
// ---- a plain first buy on a token with terms warns; nothing else does
{
  const reads = (share, traded) => ({ pad: A, read: async (_a, _abi, fn) => (fn === 'promoteOf' ? [share, 86400n] : [ZERO, 0n, traded]) })
  const ZERO = `0x${'00'.repeat(20)}`
  assert.match(await firstBuyWarning(reads(2000n, false), T0, A), /can never bind later.*gang promote buy --promoter/)
  assert.equal(await firstBuyWarning(reads(2000n, true), T0, A), null)
  assert.equal(await firstBuyWarning(reads(0n, false), T0, A), null)
  assert.equal(await firstBuyWarning(ctxFailing(rpcDown), T0, A), null)
}

console.log('promote: ok')
