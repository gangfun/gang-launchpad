/**
 * GangLaunchpad generations (1.0 / 2.0) without a chain: which generation a create goes to, how the env overrides it,
 * how a token is moved to its own generation's pad / router / GangBond, how a 1.0 pad is told from a 2.0 one, the 2.0
 * creator fee in gang portfolio, the graduation target a 2.0 creator picks, and the creator-fee / --grad flags refused
 * before any RPC. The on-chain paths are covered by the
 * testnet run listed in the CLI's release notes.
 *
 *   node skill/gang-cli/test/gens.mjs
 */
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { atTokenPad, creatorFeeShareOf, GANG_GENS, gangGens, genOf, gradTargetBnbOf, gradTiersOf, padNets } from '../src/gangpad.js'
import { bondAddress } from '../src/bond.js'
import { _test } from '../src/portfolio.js'

const t = (n) => `0x${String(n).padStart(40, '0')}`
// testnet: 2.0 with the graduation pick (the create target), the first 2.0 (its tokens only), 1.0 (set 10)
const [V2, V2a, V1] = GANG_GENS.testnet
const ENV = ['GANG_TESTNET_PAD', 'GANG_TESTNET_ROUTER', 'GANG_TESTNET_BOND', 'GANG_TESTNET_LP_FACTORY']
const clean = () => { for (const k of ENV) delete process.env[k] }
clean()

// ---- built in: testnet creates on 2.0 and keeps 1.0 for its tokens; mainnet has 1.0 only until 2.0 is deployed
assert.deepEqual(gangGens(true).map((g) => g.gen), ['2.0', '2.0', '1.0'])
assert.deepEqual(gangGens(false).map((g) => g.gen), ['1.0'])
const net = padNets('v3').testnet
assert.deepEqual([net.gen, net.pad, net.router, net.bond], ['2.0', V2.pad, V2.router, V2.bond])
assert.equal(bondAddress(true), V2.bond)
// each generation has its own contracts: never one generation's pad with another's router
for (const k of ['pad', 'router', 'bond', 'splitterFactory', 'splitFactory', 'lpFactory']) {
  assert.equal(new Set([V2, V2a, V1].map((g) => g[k].toLowerCase())).size, 3, k)
}

// ---- env: a known pad picks its generation with its own contracts; the other generation stays for its tokens
process.env.GANG_TESTNET_PAD = V1.pad.toLowerCase()
assert.deepEqual(gangGens(true).map((g) => [g.gen, g.router, g.bond]), [['1.0', V1.router, V1.bond], ['2.0', V2.router, V2.bond], ['2.0', V2a.router, V2a.bond]])
// the first 2.0 named by the env: its own router, not the newer 2.0's
process.env.GANG_TESTNET_PAD = V2a.pad
assert.deepEqual(gangGens(true).map((g) => g.router), [V2a.router, V2.router, V1.router])
// an unknown pad gets only what the env names: no built-in router or bond of another pad
process.env.GANG_TESTNET_PAD = t(0xaa)
const [own] = gangGens(true)
assert.deepEqual([own.gen, own.pad, own.router, own.bond, own.lpFactory], [null, t(0xaa), null, null, null])
assert.deepEqual(gangGens(true).slice(1).map((g) => g.gen), ['2.0', '2.0', '1.0'])
process.env.GANG_TESTNET_ROUTER = t(0xbb)
assert.equal(gangGens(true)[0].router, t(0xbb))
clean()
// a contract override applies to the create target only
process.env.GANG_TESTNET_BOND = t(0xcc)
assert.deepEqual(gangGens(true).map((g) => g.bond), [t(0xcc), V2a.bond, V1.bond])
assert.equal(bondAddress(true), t(0xcc))
clean()
// one naming another generation's contract (an old GANG_TESTNET_ROUTER for set 10) is left out: 2.0 keeps its own router
process.env.GANG_TESTNET_ROUTER = V1.router
assert.deepEqual(gangGens(true).map((g) => g.router), [V2.router, V2a.router, V1.router])
clean()

// ---- a token's generation: kindOf asked of every pad
const kinds = (byPad, failing = []) => async (address, _abi, fn) => {
  assert.equal(fn, 'kindOf')
  if (failing.includes(address)) throw new Error('rpc down')
  return byPad[address] ?? 0
}
const ctxOf = (read) => ({ ...padNets('v3').testnet, read })
assert.deepEqual(await genOf(ctxOf(kinds({ [V1.pad]: 1 })), t(1)).then((r) => [r.g.gen, r.kind]), ['1.0', 'v3'])
assert.deepEqual(await genOf(ctxOf(kinds({ [V2.pad]: 2 })), t(1)).then((r) => [r.g.gen, r.kind]), ['2.0', 'fair'])
// a token of the first 2.0: that pad, not the create target
assert.deepEqual(await genOf(ctxOf(kinds({ [V2a.pad]: 1 })), t(1)).then((r) => [r.g.pad, r.kind]), [V2a.pad, 'v3'])
assert.deepEqual(await genOf(ctxOf(kinds({})), t(1)), { g: null, kind: 'none' })
// one pad unreadable and no other has it: unknown (null), not "none"
assert.deepEqual(await genOf(ctxOf(kinds({}, [V1.pad])), t(1)), { g: null, kind: null })
assert.equal((await genOf(ctxOf(kinds({ [V2.pad]: 1 }, [V1.pad])), t(1))).kind, 'v3')
// atTokenPad moves the whole ctx (pad, router, GangBond, factories) and drops what was read from the other pad
const c = { ...ctxOf(kinds({ [V1.pad]: 1 })), _tax: 'old', fees: 'old' }
assert.equal(await atTokenPad(c, t(1)), 'v3')
assert.deepEqual([c.gen, c.pad, c.router, c.bond, c.lpFactory, c._tax, c.fees], ['1.0', V1.pad, V1.router, V1.bond, V1.lpFactory, undefined, undefined])
// no pad has it: stays on the create target
const c2 = ctxOf(kinds({}))
assert.equal(await atTokenPad(c2, t(1)), 'none')
assert.equal(c2.pad, V2.pad)
assert.equal(await atTokenPad(c2, 'nope'), undefined)
// a pad unreadable: null (the caller says retry), ctx unchanged
assert.equal(await atTokenPad(ctxOf(kinds({}, [V1.pad])), t(1)), null)

// ---- 1.0 vs 2.0: a built-in generation is known without a call; a pad from the env is asked, and only a revert
// without data (no such function) means no creator fee. An RPC error, even one viem reports as a revert, is thrown
const chainErr = (...causes) => Object.assign(new Error('x'), { walk: (fn) => causes.find(fn) })
const noData = chainErr({ name: 'ContractFunctionRevertedError', data: undefined, raw: '0x' })
const internal = chainErr({ name: 'ContractFunctionRevertedError', data: undefined }, { code: -32603 })
const httpErr = chainErr({ name: 'HttpRequestError' })
const never = async () => { throw new Error('no call expected') }
assert.equal(await creatorFeeShareOf({ chainId: '97', pad: V1.pad, read: never }), null)
assert.equal(await creatorFeeShareOf({ chainId: 'x1', pad: t(1), read: async () => 7000n }), 7000)
assert.equal(await creatorFeeShareOf({ chainId: 'x1', pad: t(2), read: async () => { throw noData } }), null)
await assert.rejects(creatorFeeShareOf({ chainId: 'x1', pad: t(3), read: async () => { throw httpErr } }), /x/)
await assert.rejects(creatorFeeShareOf({ chainId: 'x1', pad: t(6), read: async () => { throw internal } }), /x/)
// a known 2.0 pad never falls back to "1.0", whatever the error
await assert.rejects(creatorFeeShareOf({ chainId: '97x', pad: V2.pad, read: async () => { throw noData } }), /x/)
// the failed read is not cached: the next call asks again
assert.equal(await creatorFeeShareOf({ chainId: 'x1', pad: t(3), read: async () => 7000n }), 7000)

// ---- the V3 graduation target: 2.0 has tiers to pick from and a target per token; 1.0 (and an older 2.0 build) neither
const E = 10n ** 18n
const tierRead = (byFn) => async (_a, _abi, fn, args) => {
  if (!(fn in byFn)) throw new Error(`unexpected ${fn}`)
  const v = byFn[fn]
  if (v instanceof Error) throw v
  return typeof v === 'function' ? v(args) : v
}
assert.equal(await gradTiersOf({ chainId: '97', pad: V1.pad, read: never }), null)
assert.deepEqual(await gradTiersOf({ chainId: 'g1', pad: t(1), read: tierRead({ GRAD_BNB_TIERS: [6n * E, 9n * E, 12n * E, 15n * E] }) }), [6, 9, 12, 15])
assert.equal(await gradTiersOf({ chainId: 'g1', pad: t(2), read: tierRead({ GRAD_BNB_TIERS: noData }) }), null)
// the first 2.0 pad, from before the pick (no GRAD_BNB_TIERS): no tiers, not an error
assert.equal(await gradTiersOf({ chainId: 'g2', pad: V2a.pad, read: tierRead({ GRAD_BNB_TIERS: noData }) }), null)
await assert.rejects(gradTiersOf({ chainId: 'g1', pad: t(3), read: tierRead({ GRAD_BNB_TIERS: httpErr }) }), /x/)
await assert.rejects(gradTiersOf({ chainId: 'g1', pad: t(4), read: tierRead({ GRAD_BNB_TIERS: internal }) }), /x/)
const tiered = { GRAD_BNB_TIERS: [6n * E, 9n * E, 12n * E, 15n * E], TARGET_GRAD_BNB: 9n * E }
// the token's own pick; a token without one (0) falls back to the pad's default; a pad without tiers: its TARGET_GRAD_BNB
assert.equal(await gradTargetBnbOf({ chainId: 'g3', pad: t(5), read: tierRead({ ...tiered, gradTargetOf: 6n * E }) }, t(9)), 6)
assert.equal(await gradTargetBnbOf({ chainId: 'g3', pad: t(5), read: tierRead({ ...tiered, gradTargetOf: 0n }) }, t(9)), 9)
assert.equal(await gradTargetBnbOf({ chainId: '97', pad: V1.pad, read: tierRead({ TARGET_GRAD_BNB: 15n * E }) }, t(9)), 15)

// ---- gang portfolio: the tokens with a creator fee waiting, nothing when the network has no 2.0 pad
const fees = {
  scanned: [{ padGen: '2.0' }],
  tokens: [
    { token: t(4), symbol: 'A', quoteSymbol: 'WBNB', claimable: '0.0014', claimableRaw: '1400000000000000', padGen: '2.0' },
    { token: t(5), symbol: 'B', quoteSymbol: 'WBNB', claimable: '0', claimableRaw: '0', padGen: '2.0' },
  ],
  totals: [{ quote: 'WBNB', claimable: '0.0014' }],
}
const rows = _test.creatorFeeRows(fees).creatorFees
assert.deepEqual(rows.tokens.map((x) => [x.token, x.claimable, x.next]), [[t(4), 0.0014, `gang creator-fee --token ${t(4)} --claim`]])
assert.deepEqual(rows.totals, [{ quote: 'WBNB', claimable: '0.0014' }])
assert.deepEqual(_test.creatorFeeRows({ scanned: [], tokens: [], totals: [] }), {})
assert.deepEqual(_test.creatorFeeRows({ error: 'rpc' }), {})

// ---- refused before any RPC or wallet call
const gang = (...args) => {
  const r = spawnSync(process.execPath, [new URL('../src/index.js', import.meta.url).pathname, ...args], {
    encoding: 'utf8', env: { ...process.env, GANG_UPDATE_CHECK: '0', PATH: '' },
  })
  return JSON.parse(r.stdout)
}
const refused = (args, re) => {
  const r = gang(...args)
  assert.equal(r.success, false, args.join(' '))
  assert.match(r.error, re, args.join(' '))
}
refused(['creator-fee', '--claim'], /--claim needs --token/)
refused(['creator-fee', '--token', t(4), '--to', t(5)], /--to goes with --claim/)
refused(['creator-fee', '--from', 'foo'], /--from must be a 0x address/)
// --grad belongs to a V3 curve create, and is a number of BNB
refused(['create', '--fair', '--name', 'A', '--symbol', 'A', '--grad', '9', '--testnet'], /--grad is a V3 curve setting.*打新/)
refused(['create', '--fly', '--name', 'A', '--symbol', 'A', '--grad', '9', '--testnet'], /--grad is a V3 curve setting.*铸币飞轮/)
refused(['fair', 'create', '--name', 'A', '--symbol', 'A', '--grad', '9', '--testnet'], /--grad is a V3 curve setting.*打新/)
refused(['create', '--name', 'A', '--symbol', 'A', '--grad', 'nine', '--testnet'], /--grad must be the graduation target in BNB raised/)
assert.match(spawnSync(process.execPath, [new URL('../src/index.js', import.meta.url).pathname, 'help'], { encoding: 'utf8' }).stdout, /gang creator-fee --token <addr> --claim \[--to <addr>\]/)
assert.match(spawnSync(process.execPath, [new URL('../src/index.js', import.meta.url).pathname, 'help'], { encoding: 'utf8' }).stdout, /\[--grad 6\|9\|12\|15\]/)

console.log('gens: ok')
