/**
 * GangLaunchpad generations (1.0 / 2.0 / 3.0 / 2.0 金库版) without a chain: which generation a create goes to, how the env overrides it,
 * how a token is moved to its own generation's pad / router / GangBond, how a 1.0 pad is told from a 2.0 one, the 2.0
 * creator fee in gang portfolio, the graduation target a 2.0 creator picks, and the creator-fee / --grad flags refused
 * before any RPC. The on-chain paths are covered by the
 * testnet run listed in the CLI's release notes.
 *
 *   node skill/gang-cli/test/gens.mjs
 */
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { atTokenPad, creatorFeeShareOf, GANG_GENS, gangGens, genOf, gradTargetBnbOf, gradTiersOf, padNets, PAD3_GEN, VAULT_GEN, vaultGenOf, vaultModeOf } from '../src/gangpad.js'
import { bondAddress } from '../src/bond.js'
import { _test } from '../src/portfolio.js'

const t = (n) => `0x${String(n).padStart(40, '0')}`
// testnet: 3.0 (the create target), 2.0 with the graduation pick, the first 2.0 (its tokens only), 1.0 (set 10), 2.0 金库版
const [V3, V2, V2a, V1, VT] = GANG_GENS.testnet
const ENV = ['GANG_TESTNET_PAD', 'GANG_TESTNET_ROUTER', 'GANG_TESTNET_BOND', 'GANG_TESTNET_LP_FACTORY', 'GANG_TESTNET_COMBO_FACTORY']
const clean = () => { for (const k of ENV) delete process.env[k] }
clean()

// ---- built in: both networks create on 3.0 and keep 2.0 and 1.0 for their tokens
assert.deepEqual(gangGens(true).map((g) => g.gen), [PAD3_GEN, '2.0', '2.0', '1.0', VAULT_GEN])
assert.deepEqual(gangGens(false).map((g) => g.gen), [PAD3_GEN, '2.0', '1.0', VAULT_GEN])

// ---- 2.0 金库版: last on each network (never a plain create's target), its own pad and router, no GangBond or factory
{
  const MV = GANG_GENS.mainnet[3]
  assert.deepEqual([MV.gen, MV.pad, MV.router], [VAULT_GEN, '0xE90851A90C6278E3d6e4C24320101f8B13D90A11', '0xAcd4944A4090c13d9DACAe60f3019cef9d9bB1Ad'])
  assert.deepEqual([VT.gen, VT.pad, VT.router], [VAULT_GEN, '0x9108e7b85e69060A5E626A04Ce6DEf323071C8a9', '0x9bF3E197a6719Af856a7c82d23CABFdBcc184f69'])
  for (const g of [MV, VT]) {
    assert.deepEqual([g.bond, g.splitterFactory, g.splitFactory, g.lpFactory, g.comboFactory], [null, null, null, null, null])
  }
  assert.equal(vaultGenOf(gangGens(false)).pad, MV.pad)
  assert.equal(vaultGenOf(gangGens(true)).pad, VT.pad)
  assert.equal(vaultGenOf(padNets('v3').mainnet.gens).router, MV.router)
  assert.equal(vaultGenOf([V3, V2, V1]), null)
  assert.notEqual(padNets('v3').mainnet.pad, MV.pad)
  // no other generation shares its pad or router
  for (const k of ['pad', 'router']) {
    assert.equal(new Set(GANG_GENS.mainnet.map((g) => g[k].toLowerCase())).size, 4, k)
    assert.equal(new Set(GANG_GENS.testnet.map((g) => g[k].toLowerCase())).size, 5, k)
  }
}
// mainnet: 3.0 (2026-11-03) is the create target, 2.0 and 1.0 keep their tokens; each with its own contracts
{
  const [M3, M2, M1] = GANG_GENS.mainnet
  assert.deepEqual([M3.gen, M3.pad, M3.router, M3.bond], [PAD3_GEN, '0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29', '0xec9717E5C68b9F18fA76D3961C9Cd7e67b5E61e7', '0x830b38F695Ca1bCbdD313CD5AA5943e2125Be9D6'])
  assert.deepEqual([M3.splitterFactory, M3.splitFactory, M3.lpFactory, M3.comboFactory], ['0xc1282e7Fd3DFa5e00e74E9EbF8c54fFfB5763194', '0x904D4498a9257E4d7638afEbB95A1162cB2171f2', '0x98C506F0F4762F9d1Ec96C27499CE8B7e5981752', '0x20188054dE31De844df205712768852BdeD3eA39'])
  assert.deepEqual([M2.pad, M2.router, M2.bond], ['0x770331a9accdb53ACb4a45B6c5B7D151fADCe557', '0xa83209d6bfC2B220cD86410cCDDC71FEb354844a', '0x231339463d04A2127E6dD5756756Dd56853AE0D8'])
  assert.deepEqual([M2.splitterFactory, M2.splitFactory, M2.lpFactory, M2.comboFactory], ['0x77e499c892e5E6B3eEe1721e6821e9DA1293803C', '0xa73dC3d63AAf72E70b1cb012e5f3A541360Bec59', '0x8ac85f150f87B536fb05eA163908b1077D95c0E4', '0xcCeA388DbC0Edb206eC25C9715546d57029198Be'])
  assert.equal(M1.pad, '0x15CFD2dc8278Fb87a1783ef42111618E20874365')
  for (const k of ['pad', 'router', 'bond', 'splitterFactory', 'splitFactory', 'lpFactory', 'comboFactory']) {
    assert.equal(new Set([M3, M2, M1].map((g) => g[k].toLowerCase())).size, 3, k)
  }
  const m = padNets('v3').mainnet
  assert.deepEqual([m.gen, m.pad, m.router, m.bond], [PAD3_GEN, M3.pad, M3.router, M3.bond])
  assert.equal(bondAddress(false), M3.bond)
}
const net = padNets('v3').testnet
assert.deepEqual([net.gen, net.pad, net.router, net.bond], [PAD3_GEN, V3.pad, V3.router, V3.bond])
assert.deepEqual([V3.pad, V3.router, V3.bond], ['0x0508232833aE6849c03b28F7aA248BBd5cFCceE2', '0x09544Fd87c5Ff2c4fb05885A76861A12e83f87b9', '0xa87727dc3CC28a44709649A22aDbD77287B99fc1'])
assert.deepEqual([V3.splitterFactory, V3.splitFactory, V3.lpFactory], ['0x3533E63EF0386adfBC96227C50f1b82EEA18d110', '0xf8d4FA57FD65Bf16427Eef653518811fFa2606dc', '0x4A3aC160eAF4A2747046b119631988D5D8056B07'])
assert.equal(bondAddress(true), V3.bond)
// each generation has its own contracts: never one generation's pad with another's router
for (const k of ['pad', 'router', 'bond', 'splitterFactory', 'splitFactory', 'lpFactory']) {
  assert.equal(new Set([V3, V2, V2a, V1].map((g) => g[k].toLowerCase())).size, 4, k)
}
// the module helpers' built-in factories are the create target's (3.0)
{
  const { MAINNET_SPLITTER_FACTORY, TESTNET_SPLITTER_FACTORY } = await import('../src/buyback.js')
  const { MAINNET_SPLIT_FACTORY, TESTNET_SPLIT_FACTORY } = await import('../src/split.js')
  const { MAINNET_LP_FACTORY, TESTNET_LP_FACTORY } = await import('../src/lp.js')
  const { MAINNET_BOND, TESTNET_BOND } = await import('../src/bond.js')
  const [M3] = GANG_GENS.mainnet
  assert.deepEqual([MAINNET_SPLITTER_FACTORY, MAINNET_SPLIT_FACTORY, MAINNET_LP_FACTORY, MAINNET_BOND], [M3.splitterFactory, M3.splitFactory, M3.lpFactory, M3.bond])
  assert.deepEqual([TESTNET_SPLITTER_FACTORY, TESTNET_SPLIT_FACTORY, TESTNET_LP_FACTORY, TESTNET_BOND], [V3.splitterFactory, V3.splitFactory, V3.lpFactory, V3.bond])
}

// combined recipients: a factory per generation (bound to one pad), none on the first testnet 2.0
assert.deepEqual([V3, V2, V2a, V1].map((g) => g.comboFactory), ['0xdc1687961c8aAf5A0340c1A73b604cf3a2be543C', '0x312c86F7139b3e3a75ee66b4D5Bfdbe5077584BD', null, '0x52a8f90a92E5C1828b4436a0B99C6b293f7F4CFE'])
assert.deepEqual(GANG_GENS.mainnet.map((g) => g.comboFactory), ['0x20188054dE31De844df205712768852BdeD3eA39', '0xcCeA388DbC0Edb206eC25C9715546d57029198Be', '0xd33C38BE3f8472b3013167830F0638C1704e1DBd', null])
assert.equal(net.comboFactory, V3.comboFactory)
{
  const { comboFactoryAddress } = await import('../src/combo.js')
  assert.equal(comboFactoryAddress(true), V3.comboFactory)
  process.env.GANG_TESTNET_COMBO_FACTORY = t(0xdd)
  assert.deepEqual(gangGens(true).map((g) => g.comboFactory), [t(0xdd), V2.comboFactory, null, V1.comboFactory, null])
  assert.equal(comboFactoryAddress(true), t(0xdd))
  // GANG_TESTNET_PAD naming 1.0 makes it the create target: the factory override goes with it; without one, 1.0's own
  process.env.GANG_TESTNET_PAD = V1.pad
  assert.equal(comboFactoryAddress(true), t(0xdd))
  delete process.env.GANG_TESTNET_COMBO_FACTORY
  assert.equal(comboFactoryAddress(true), V1.comboFactory)
  delete process.env.GANG_TESTNET_PAD
}

// ---- env: a known pad picks its generation with its own contracts; the other generation stays for its tokens
process.env.GANG_TESTNET_PAD = V1.pad.toLowerCase()
assert.deepEqual(gangGens(true).map((g) => [g.gen, g.router, g.bond]), [['1.0', V1.router, V1.bond], [PAD3_GEN, V3.router, V3.bond], ['2.0', V2.router, V2.bond], ['2.0', V2a.router, V2a.bond], [VAULT_GEN, VT.router, null]])
// the first 2.0 named by the env: its own router, not the newer 2.0's
process.env.GANG_TESTNET_PAD = V2a.pad
assert.deepEqual(gangGens(true).map((g) => g.router), [V2a.router, V3.router, V2.router, V1.router, VT.router])
// 2.0 named by the env (back to it as the create target): its own contracts; 3.0 stays for its tokens
process.env.GANG_TESTNET_PAD = V2.pad
assert.deepEqual(gangGens(true).map((g) => [g.gen, g.pad, g.bond, g.comboFactory]), [['2.0', V2.pad, V2.bond, V2.comboFactory], [PAD3_GEN, V3.pad, V3.bond, V3.comboFactory], ['2.0', V2a.pad, V2a.bond, null], ['1.0', V1.pad, V1.bond, V1.comboFactory], [VAULT_GEN, VT.pad, null, null]])
// an unknown pad gets only what the env names: no built-in router or bond of another pad
process.env.GANG_TESTNET_PAD = t(0xaa)
const [own] = gangGens(true)
assert.deepEqual([own.gen, own.pad, own.router, own.bond, own.lpFactory], [null, t(0xaa), null, null, null])
assert.deepEqual(gangGens(true).slice(1).map((g) => g.gen), [PAD3_GEN, '2.0', '2.0', '1.0', VAULT_GEN])
process.env.GANG_TESTNET_ROUTER = t(0xbb)
assert.equal(gangGens(true)[0].router, t(0xbb))
clean()
// a contract override applies to the create target only
process.env.GANG_TESTNET_BOND = t(0xcc)
assert.deepEqual(gangGens(true).map((g) => g.bond), [t(0xcc), V2.bond, V2a.bond, V1.bond, null])
assert.equal(bondAddress(true), t(0xcc))
clean()
// one naming another generation's contract (an old GANG_TESTNET_ROUTER for set 10 or 2.0) is left out: 3.0 keeps its own router
process.env.GANG_TESTNET_ROUTER = V1.router
assert.deepEqual(gangGens(true).map((g) => g.router), [V3.router, V2.router, V2a.router, V1.router, VT.router])
process.env.GANG_TESTNET_ROUTER = V2.router
assert.equal(gangGens(true)[0].router, V3.router)
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
assert.deepEqual(await genOf(ctxOf(kinds({ [V3.pad]: 1 })), t(1)).then((r) => [r.g.gen, r.g.pad, r.kind]), [PAD3_GEN, V3.pad, 'v3'])
assert.deepEqual(await genOf(ctxOf(kinds({ [V3.pad]: 2 })), t(1)).then((r) => [r.g.gen, r.kind]), [PAD3_GEN, 'fair'])
// a 2.0 token stays on 2.0 (3.0's kindOf is 0 for it: its entry forwards older tokens, its own records are its own)
assert.deepEqual(await genOf(ctxOf(kinds({ [V2.pad]: 1 })), t(1)).then((r) => [r.g.pad, r.g.router, r.g.bond]), [V2.pad, V2.router, V2.bond])
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
assert.equal(c2.pad, V3.pad)
assert.equal(await atTokenPad(c2, 'nope'), undefined)
// a pad unreadable: null (the caller says retry), ctx unchanged
assert.equal(await atTokenPad(ctxOf(kinds({}, [V1.pad])), t(1)), null)
const noDataEarly = Object.assign(new Error('x'), { walk: (fn) => [{ name: 'ContractFunctionRevertedError', data: undefined, raw: '0x' }].find(fn) })
// a 2.0 金库版 token: that pad and its router, no GangBond / factories; the vault pad unreadable alone is unknown too
{
  const cv = { ...ctxOf(kinds({ [VT.pad]: 1 })), _tax: 'old', fees: 'old' }
  assert.equal(await atTokenPad(cv, t(1)), 'v3')
  assert.deepEqual([cv.gen, cv.pad, cv.router, cv.bond, cv.comboFactory, cv._tax], [VAULT_GEN, VT.pad, VT.router, null, null, undefined])
  assert.equal(await atTokenPad(ctxOf(kinds({}, [VT.pad])), t(1)), null)
  // a known 2.0 金库版 pad has the creator fee and the graduation pick: asked of the pad, never taken for 1.0
  assert.equal(await creatorFeeShareOf({ chainId: 'v1', pad: VT.pad, read: async () => 7000n }), 7000)
  await assert.rejects(creatorFeeShareOf({ chainId: 'v2', pad: VT.pad, read: async () => { throw noDataEarly } }), /x/)
}

// ---- 3.0's vault mode: asked of the pad (an upgrade of the same address adds it), never assumed per network
{
  const word = `0x${'0'.repeat(64)}`
  const callWith = (answer) => ({ call: async ({ to, data }) => {
    assert.equal(data, `0x0709df45${'0'.repeat(64)}`) // vaultOf(address(0))
    assert.ok(to)
    if (answer instanceof Error) throw answer
    return { data: answer }
  } })
  const noCall = { call: async () => { throw new Error('no call expected') } }
  // the 2.0 金库版 pad always has it, 1.0 and 2.0 never: no call
  assert.equal(await vaultModeOf({ chainId: '97', pad: VT.pad, client: noCall }), true)
  assert.equal(await vaultModeOf({ chainId: '97', pad: V2.pad, client: noCall }), false)
  assert.equal(await vaultModeOf({ chainId: '97', pad: V1.pad, client: noCall }), false)
  // 3.0: 32 bytes back = served; a revert without data (no fallback before the upgrade) or short data = not served
  assert.equal(await vaultModeOf({ chainId: 'vm1', pad: V3.pad, client: callWith(word) }), true)
  assert.equal(await vaultModeOf({ chainId: 'vm2', pad: V3.pad, client: callWith('0x') }), false)
  assert.equal(await vaultModeOf({ chainId: 'vm3', pad: V3.pad, client: callWith(`${word}00`) }), false)
  const reverted = Object.assign(new Error('execution reverted'), { walk: (fn) => [{ name: 'CallExecutionError' }, { name: 'RpcRequestError', code: 3 }].find(fn) })
  assert.equal(await vaultModeOf({ chainId: 'vm4', pad: V3.pad, client: callWith(reverted) }), false)
  // the node failing is thrown (never "no vault mode"), and not cached
  const down = Object.assign(new Error('fetch failed'), { walk: (fn) => [{ name: 'HttpRequestError' }].find(fn) })
  const internal = Object.assign(new Error('x'), { walk: (fn) => [{ name: 'ExecutionRevertedError' }, { code: -32603 }].find(fn) })
  await assert.rejects(vaultModeOf({ chainId: 'vm5', pad: V3.pad, client: callWith(down) }), /fetch failed/)
  await assert.rejects(vaultModeOf({ chainId: 'vm5', pad: V3.pad, client: callWith(internal) }), /x/)
  assert.equal(await vaultModeOf({ chainId: 'vm5', pad: V3.pad, client: callWith(word) }), true)
  // the answer is kept for the run: one call per pad
  assert.equal(await vaultModeOf({ chainId: 'vm1', pad: V3.pad, client: noCall }), true)
  // "not yet" is asked again after 10 minutes (a long-lived gang mcp sees the upgrade); "served" is kept
  {
    const now = Date.now
    let at = now()
    Date.now = () => at
    try {
      assert.equal(await vaultModeOf({ chainId: 'vm7', pad: V3.pad, client: callWith('0x') }), false)
      assert.equal(await vaultModeOf({ chainId: 'vm7', pad: V3.pad, client: noCall }), false)
      at += 11 * 60_000
      assert.equal(await vaultModeOf({ chainId: 'vm7', pad: V3.pad, client: callWith(word) }), true)
      at += 60 * 60_000
      assert.equal(await vaultModeOf({ chainId: 'vm7', pad: V3.pad, client: noCall }), true)
    } finally { Date.now = now }
  }
  // a pad named by the env is asked too
  assert.equal(await vaultModeOf({ chainId: 'vm6', pad: t(0xee), client: callWith(word) }), true)
  // 3.0 keeps 2.0's creator fee and graduation pick: asked of the pad, never taken for 1.0
  assert.equal(await creatorFeeShareOf({ chainId: 'p3', pad: V3.pad, read: async () => 7000n }), 7000)
  assert.deepEqual(await gradTiersOf({ chainId: 'p3', pad: GANG_GENS.mainnet[0].pad, read: async () => [6n * 10n ** 18n, 9n * 10n ** 18n, 12n * 10n ** 18n, 15n * 10n ** 18n] }), [6, 9, 12, 15])
}

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

// ---- 2.0 errors and notes: QuoteAmountTooLarge decodes with its hint; the module note says how to claim into the module
{
  const { MERGED_ERRORS_ABI, MERGED_HINTS } = await import('../src/gangpad.js')
  const { decodeErrorResult, encodeErrorResult } = await import('viem')
  const data = encodeErrorResult({ abi: MERGED_ERRORS_ABI, errorName: 'QuoteAmountTooLarge' })
  assert.equal(decodeErrorResult({ abi: MERGED_ERRORS_ABI, data }).errorName, 'QuoteAmountTooLarge')
  assert.match(MERGED_HINTS.QuoteAmountTooLarge, /PancakeSwap pair/)
  const { notThroughModule } = await import('../src/creatorfee.js')
  assert.doesNotMatch(notThroughModule('LP splitter'), /--to/)
  assert.match(notThroughModule('LP splitter', { token: t(4), at: t(7), net: ' --testnet' }), new RegExp(`gang creator-fee --token ${t(4)} --testnet --claim --to ${t(7)}`))
}

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
// --vault: a V3 create alone, with a 0x vault
refused(['create', '--fair', '--name', 'A', '--symbol', 'A', '--vault', t(7), '--testnet'], /--vault binds a V3 curve token.*leave --fair out/)
refused(['create', '--fly', '--name', 'A', '--symbol', 'A', '--vault', t(7), '--testnet'], /--vault binds a V3 curve token.*leave --fly out/)
refused(['fair', 'create', '--name', 'A', '--symbol', 'A', '--vault', t(7), '--testnet'], /--vault only applies to a V3 create/)
refused(['buy', '--token', t(4), '--vault', t(7), '--testnet'], /--vault only applies to a V3 create/)
for (const [f, v] of [['--dev-buy', '0.1'], ['--bond', '0.1'], ['--buyback', '50'], ['--lp', '50'], ['--split', `${t(8)}:100`]]) {
  refused(['create', '--name', 'A', '--symbol', 'A', '--vault', t(7), f, v, '--testnet'], /a --vault create stands alone/)
}
refused(['create', '--name', 'A', '--symbol', 'A', '--vault', 'nope', '--testnet'], /--vault/)
assert.match(spawnSync(process.execPath, [new URL('../src/index.js', import.meta.url).pathname, 'help'], { encoding: 'utf8' }).stdout, /\[--vault <0x…>\]/)

// ---- 2.0 金库版 ABI: createWithVault's selector, its errors decode with their hints
{
  const { _vaultTest } = await import('../src/v3.js')
  const { decodeErrorResult, encodeErrorResult, encodeFunctionData, zeroAddress } = await import('viem')
  const data = encodeFunctionData({ abi: _vaultTest.PAD_ABI, functionName: 'createWithVault', args: ['A', 'A', '', '', t(1), zeroAddress, { buyTaxBps: 0, sellTaxBps: 0, dividendBps: 0, recipient: zeroAddress }, 9n * E, t(7)] })
  assert.equal(data.slice(0, 10), '0xcb57955e')
  for (const name of ['NotVault', 'NotVaultCreator', 'UseVaultCreate', 'VaultCannotTrade', 'VaultDelisted']) {
    const err = encodeErrorResult({ abi: _vaultTest.PAD_ABI, errorName: name })
    assert.equal(decodeErrorResult({ abi: _vaultTest.PAD_ABI, data: err }).errorName, name)
    assert.ok(_vaultTest.HINTS[name], name)
  }
}

// ---- 3.0 events decode in gang tx (beside 2.0's, which 3.0 keeps unchanged)
{
  const { V3_EVENT_ABIS } = await import('../src/v3.js')
  const { encodeEventTopics, encodeAbiParameters, decodeEventLog } = await import('viem')
  const [abi] = V3_EVENT_ABIS
  const topics = encodeEventTopics({ abi, eventName: 'TokenVersionSet', args: { token: t(1) } })
  const ev = decodeEventLog({ abi, topics, data: encodeAbiParameters([{ type: 'uint8' }], [1]) })
  assert.deepEqual([ev.eventName, ev.args.version], ['TokenVersionSet', 1])
  const tt = encodeEventTopics({ abi, eventName: 'TradeV1', args: { token: t(1), trader: t(2) } })
  const tr = decodeEventLog({ abi, topics: tt, data: encodeAbiParameters(Array(8).fill(0).map((_, i) => ({ type: i ? 'uint256' : 'bool' })), [true, 1n, 2n, 3n, 4n, 5n, 6n, 7n]) })
  assert.deepEqual([tr.eventName, tr.args.isBuy, tr.args.creatorFee], ['TradeV1', true, 4n])
  for (const name of ['GatewayBuy', 'GatewaySell', 'GatewaySellTo', 'Routed', 'VaultBound', 'VaultLocked']) assert.ok(abi.some((x) => x.type === 'event' && x.name === name), name)
  // 3.0's vault mode keeps GangVaultLaunchpad's createWithVault selector
  assert.ok(abi.some((x) => x.name === 'tokenVersionOf'))
}

console.log('gens: ok')
