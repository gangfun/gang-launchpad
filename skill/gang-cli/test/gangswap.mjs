/**
 * GangSwap (kind 4; docs/SPEC-GANGSWAP-2026-11-22.md) against a local fake BSC testnet node (no chain, no wallet):
 *   - --venue: parsing and every refusal, before any RPC; not open / older pad / RPC error, before any wallet step;
 *     createGangSwap through createWithSalt (abcd), direct, inside an agent window; the preview's words;
 *   - the kind: never 'v3', legacy or an RPC error; curve buy / sell / info / status on it; every module refuses it;
 *   - after graduation: buy / sell through GangSwapRouter only (target, args, minimum, exact approvals), GangRouter's
 *     pool functions and PancakeSwap never asked; each failing router check; the env override is checked the same way;
 *   - info / status / portfolio / creator-fee (list, status, both claims) / handoff / MCP / tx;
 *   - --grad-reward on it (docs/SPEC-GANGSWAP-GRAD-REWARD-2026-11-25.md): served or not (asked before any wrap or approval),
 *     the stages, the exact approval, every nesting, info / buy / sell previews and gang grad-reward on a kind-4 token;
 *   - kinds 1 / 2 / 3 as before.
 *
 *   node skill/gang-cli/test/gangswap.mjs
 */
import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { execFile, spawn } from 'node:child_process'
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { decodeFunctionData, decodeFunctionResult, encodeErrorResult, keccak256, encodeAbiParameters, encodeEventTopics, encodeFunctionData, encodeFunctionResult, getAddress, maxUint256, parseAbi, parseUnits, toEventSelector, toFunctionSelector, zeroAddress } from 'viem'

process.env.GANG_TELEMETRY = '0'
process.env.GANG_UPDATE_CHECK = '0'
for (const k of ['GANG_SWAP_ROUTER', 'GANG_TESTNET_SWAP_ROUTER']) delete process.env[k]
const { runV3, V3_EVENT_ABIS, V3_NETS } = await import('../src/v3.js')
const G = await import('../src/gangswap.js')
const { parseVenue, venueRefusal } = await import('../src/venue.js')
const { VANITY_ABI } = await import('../src/vanity.js')
const { AGENT_WINDOW_ABI } = await import('../src/agentwindow.js')
const { GANG_GENS, CREATOR_FEE_ABI, GRAD_TARGET_ABI, GANGSWAP_KIND, gangGens, genOf, isCurveKind, kindOf, notThisKind } = await import('../src/gangpad.js')
const { ROUTER_ABI, POOL_HANDLER_ABI } = await import('../src/steps.js')
const { refShown, poolTrade, POOL_NO_REF, GANGSWAP_NO_REF } = await import('../src/pool.js')
const { PROMOTE_PAD_ABI } = await import('../src/promote.js')
const { GRAD_PAD_ABI, GRAD_EVENT_ABIS, runGradReward } = await import('../src/gradreward.js')
const { BASE_PAD_ABI } = await import('../src/base.js')
const { BOND_ABI } = await import('../src/bond.js')
const { CALL_BOND_ABI } = await import('../src/callbond.js')
const { normalize, isGangSwapRow, rank } = await import('../src/discover.js')
const { portfolio } = await import('../src/portfolio.js')
const { buildHandoff } = await import('../src/handoff.js')
const { TOOLS, RULES } = await import('../src/mcp.js')
const { capabilities } = await import('../src/capabilities.js')
const { decodeLogs } = await import('../src/chain.js')

const lc = (a) => String(a).toLowerCase()
const t = (n) => getAddress(`0x${n.toString(16).padStart(40, '0')}`)
const CLI = fileURLToPath(new URL('../src/index.js', import.meta.url))
const E18 = 10n ** 18n
const PAD = lc(gangGens(true)[0].pad)
const MPAD = lc(GANG_GENS.mainnet[0].pad) // mainnet's 3.0 pad answers as the testnet one
const GANG_ROUTER = lc(gangGens(true)[0].router)
const WBNB = lc(V3_NETS.testnet.wbnb)
const PANCAKE = ['0xd99d1c33f9fc3444f8101754abc46c52416550d1', '0x10ed43c718714eb63d5aa57b78b54704e256024e']
const ME = t(0xd3f), OTHER = t(0x0e1), VAN = t(0x7a17), HANDLER = t(0x4a4d)
const GS = lc(t(0x9a5)), K1 = lc(t(0x111)), K2 = lc(t(0x222)), K3 = lc(t(0x333))
const MIGRATOR = lc(t(0x316)), FACTORY = lc(t(0xfac)), BOOST = lc(t(0xb005)), FEES = lc(t(0xfee)), ROUTER = lc(t(0x5a9)), PAIR = lc(t(0xda1))
// the real init code hash and the real GangSwapRouter's runtime code (immutables zero, as the compiler's artifact has it)
const HASH = '0x118a6e086410ad99bc0968c3a4afdce6653288e14174b6248da8a05b0693e13b'
const ARTIFACT = readFileSync(new URL('./fixtures/gangswap-router.hex', import.meta.url), 'utf8').trim()
const push = (a) => `7f${a.slice(2).toLowerCase().padStart(64, '0')}`
const ZERO_SITE = `7f${'0'.repeat(64)}`
/** The code as deployed: each zero PUSH32 of the artifact filled in order with the word at(letter, index). */
const deployed = (at = (c) => (c === 'F' ? FACTORY : WBNB)) => { let i = 0; return ARTIFACT.replaceAll(ZERO_SITE, () => push(at(G.GANGSWAP_ROUTER_SITES[i], i++))) }
const NOW = 2_000_000_000
// a second GangSwap version: its own set, a token of it
const GS2 = lc(t(0x9b5)), MIGRATOR2 = lc(t(0x326)), FACTORY2 = lc(t(0xfad)), BOOST2 = lc(t(0xb006)), FEES2 = lc(t(0xfef)), ROUTER2 = lc(t(0x5b9)), PAIR2 = lc(t(0xda2))

// ---- the pinned versions: one on each network (read on chain 2026-11-24); then emptied for the fake node
assert.deepEqual(G.GANGSWAP_VERSIONS, { mainnet: [{ router: '0xd685e3432472d0da34903888f96b0D0221bC779c', codeHash: G.GANGSWAP_ROUTER_CODE_HASH, sites: G.GANGSWAP_ROUTER_SITES }], testnet: [{ router: '0x1EAdAEe9b7C04Db9b828CcC342c3Ef2355722d94', codeHash: G.GANGSWAP_ROUTER_CODE_HASH, sites: G.GANGSWAP_ROUTER_SITES }] })
assert.deepEqual([G.gangSwapRouterAddresses(true), G.gangSwapRouterAddresses(false)], [['0x1EAdAEe9b7C04Db9b828CcC342c3Ef2355722d94'], ['0xd685e3432472d0da34903888f96b0D0221bC779c']])
const PINNED = lc(G.GANGSWAP_VERSIONS.testnet[0].router) // what a CLI process started here has: another version's on the fake node
const F3 = lc(t(0xfa3)), M3 = lc(t(0x336)), B3 = lc(t(0xb03)), E3 = lc(t(0xfe3))
G.GANGSWAP_VERSIONS.testnet.length = 0
G.GANGSWAP_VERSIONS.mainnet.length = 0

// ---------------------------------------------------------------- pure
assert.equal(GANGSWAP_KIND, 4)
assert.deepEqual(['v3', 'gangswap', 'fair', 'fly', 'none', null].map(isCurveKind), [true, true, false, false, false, false])
// the contract's signatures (feat/gangswap: IGangSwapPad, IGangSwap, GangSwapFees, GangSwapBoost, GangSwapRouter)
for (const [abi, fn, sig] of [
  [G.GANGSWAP_PAD_ABI, 'createGangSwap', 'createGangSwap(string,string,string,string,uint256,address)'], [G.GANGSWAP_PAD_ABI, 'gangSwapMigrator', 'gangSwapMigrator()'], [G.GANGSWAP_PAD_ABI, 'gangSwapMigratorOf', 'gangSwapMigratorOf(address)'],
  [G.GANGSWAP_FEES_ABI, 'claim', 'claim(address,address)'],
  [G.GANGSWAP_ROUTER_ABI, 'swapExactETHForTokens', 'swapExactETHForTokens(uint256,address[],address,uint256)'],
  [G.GANGSWAP_ROUTER_ABI, 'swapExactTokensForETH', 'swapExactTokensForETH(uint256,uint256,address[],address,uint256)'],
  [G.GANGSWAP_ROUTER_ABI, 'swapExactTokensForTokens', 'swapExactTokensForTokens(uint256,uint256,address[],address,uint256)'],
]) assert.equal(toFunctionSelector(abi.find((x) => x.name === fn)), toFunctionSelector(`function ${sig}`), fn)
assert.equal(toEventSelector(G.GANGSWAP_PAD_ABI.find((x) => x.name === 'GangSwapCreated')), toEventSelector('GangSwapCreated(address,address)'))
// GangSwapRouter.getAmountOut: 9900 / 10000, rounded down
assert.equal(G.amountOut(E18, 6n * E18, 200n * E18), (E18 * 9900n * 200n * E18) / (6n * E18 * 10000n + E18 * 9900n))
assert.equal(G.amountOut(1n, 10n ** 30n, 1n), 0n)
// PUSH32 <hash>, byte-aligned, counted
const codeOf = (n, h = HASH) => `0x6080${`7f${h.slice(2)}`.repeat(n)}00`
assert.deepEqual([0, 1, 2].map((n) => G.countInitHash(codeOf(n), HASH)), [0, 1, 2])
assert.equal(G.countInitHash(codeOf(1, `0x${'ab'.repeat(32)}`), HASH), 0)
assert.equal(G.countInitHash(`0x6${`7f${HASH.slice(2)}`}0`, HASH), 0, 'not byte-aligned: not a PUSH32')
assert.equal(G.countInitHash(`0x60${HASH.slice(2)}`, HASH), 0, 'the hash without PUSH32')

const deployed2 = () => deployed((c) => (c === 'F' ? FACTORY2 : WBNB))
// ---- the router's identity
assert.equal(keccak256(ARTIFACT), G.GANGSWAP_ROUTER_CODE_HASH)
assert.equal(ARTIFACT.split(ZERO_SITE).length - 1, G.GANGSWAP_ROUTER_SITES.length)
assert.deepEqual(G.maskedRouter(deployed(), FACTORY, WBNB), { hash: G.GANGSWAP_ROUTER_CODE_HASH, sites: G.GANGSWAP_ROUTER_SITES })
assert.deepEqual(G.maskedRouter(deployed(), FACTORY.toUpperCase().replace('0X', '0x'), WBNB).sites, G.GANGSWAP_ROUTER_SITES)
// masked lookalikes: only the exact expected words are masked, each in its place
const other = lc(t(0xbad))
const FORGED = {
  'structural (the right PUSH32 init hash once, nothing else)': codeOf(1),
  'code before': `0x00${deployed().slice(2)}`, 'code after': `${deployed()}00`, 'another init word after': `${deployed()}${push(FACTORY)}`,
  'one byte changed': `${deployed().slice(0, 400)}${deployed()[400] === '0' ? '1' : '0'}${deployed().slice(401)}`,
  'immutables left zero': ARTIFACT,
  'factory and WBNB swapped everywhere': deployed((c) => (c === 'F' ? WBNB : FACTORY)),
  'one operand swapped': deployed((c, i) => ((c === 'F') !== (i === 2) ? FACTORY : WBNB)),
  'one operand zero': deployed((c, i) => (i === 5 ? zeroAddress : c === 'F' ? FACTORY : WBNB)),
  'one operand another address': deployed((c, i) => (i === 30 ? other : c === 'F' ? FACTORY : WBNB)),
  'every factory another': deployed((c) => (c === 'F' ? other : WBNB)), 'every WBNB another': deployed((c) => (c === 'F' ? FACTORY : other)),
  'dirty upper bytes': deployed().replace(push(FACTORY), `7f01${push(FACTORY).slice(4)}`),
  'dirty upper bytes of WBNB': deployed().replace(push(WBNB), `7f01${push(WBNB).slice(4)}`), 'another opcode before WBNB': deployed().replace(push(WBNB), `7e${push(WBNB).slice(2)}`),
  truncated: deployed().slice(0, -2), empty: '0x',
}

// the event the pad and GangSwapFees share a signature for: told apart by `to` being indexed
{
  const feesLog = { address: FEES, topics: encodeEventTopics({ abi: G.GANGSWAP_FEES_ABI, eventName: 'CreatorFeeClaimed', args: { token: GS, creator: ME } }), data: encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [OTHER, 7n]) }
  const padLog = { address: PAD, topics: encodeEventTopics({ abi: CREATOR_FEE_ABI, eventName: 'CreatorFeeClaimed', args: { token: GS, creator: ME, to: OTHER } }), data: encodeAbiParameters([{ type: 'uint256' }], [9n]) }
  assert.equal(feesLog.topics[0], padLog.topics[0])
  const [a, b] = decodeLogs([feesLog, padLog], V3_EVENT_ABIS)
  assert.deepEqual([a.event, lc(a.to), a.amount], ['CreatorFeeClaimed', lc(OTHER), '7'])
  assert.deepEqual([b.event, lc(b.to), b.amount], ['CreatorFeeClaimed', lc(OTHER), '9'])
}

// --venue
const flags = (o) => ({ opt: (n, d) => o[n] ?? d, flag: (n) => Object.hasOwn(o, n) })
const refusal = (o, extra = {}) => { const f = flags({ venue: 'gangswap', ...o }); return venueRefusal({ ...f, testnet: true, ...extra }) }
assert.deepEqual(parseVenue(flags({}).opt, flags({}).flag), { venue: 'pancake' })
for (const v of ['pancake', 'gangswap']) assert.deepEqual(parseVenue(flags({ venue: v }).opt, flags({ venue: v }).flag), { venue: v })
for (const v of ['', undefined, 'GangSwap', 'uniswap', 'pancakeswap', '--testnet']) assert.match(refusal({ venue: v }).error, /--venue must be pancake .* or gangswap/, String(v))
assert.equal(refusal({}), null)
assert.equal(refusal({ grad: '6', 'agent-window': '30', website: 'a.xyz', twitter: '@a', description: 'x', logo: 'a.png', note: 'n', 'buy-tax': '0', 'sell-tax': '0' }), null)
assert.equal(refusal({ quote: V3_NETS.testnet.wbnb }), null)
assert.equal(refusal({ quote: WBNB }), null)
const REFUSED = {
  'buy-tax': '2', 'sell-tax': '2', dividend: '0', recipient: ME, quote: OTHER, 'ref-pool': OTHER, promote: '10', 'promote-days': '30', base: '5', 'base-vest': '30', vault: OTHER,
  'gr-carry': '0',
  'countdown-reward': '', 'cd-max-payout': '1', 'cd-window': '60m', 'cd-seed': '1',
  'dev-buy': '1', bond: '1', 'bond-hold': 'all', 'bond-days': '7', buyback: '10', 'buyback-to': ME, split: 'self:100', lp: '10', 'lp-to': ME, 'tax-cap': '1', 'tax-cap-share': '1', 'after-cap': 'x', floor: '', 'redeem-fee': '1', restart: '',
  fair: '', fly: '', raise: '15', hold: '60', 'mint-fee': '1', 'exit-fee': '1', cap: '1', shares: '1', preset: 'j', quota: '5', 'dev-shares': '1',
}
for (const [f, v] of Object.entries(REFUSED)) {
  const r = refusal({ [f]: v })
  assert.ok(r?.error, `--${f} must be refused with --venue gangswap`)
  assert.match(r.error, new RegExp(`--${f} can't go with --venue gangswap`), f)
  // and with the default venue it is not this check's business
  assert.equal(venueRefusal({ ...flags({ [f]: v, venue: 'pancake' }), testnet: true }), null, `pancake ${f}`)
}
assert.match(refusal({}, { fair: true }).error, /--fair can't go/)
assert.match(refusal({}, { fly: true }).error, /--fly can't go/)

// words the product must not use, anywhere a user reads
for (const f of ['README.md', 'README.zh-CN.md', 'DEVELOPERS.md', 'DEVELOPERS.zh-CN.md']) {
}

// ---------------------------------------------------------------- the fake node
const fresh = () => ({
  kinds: { [GS]: 4, [GS2]: 4, [K1]: 1, [K2]: 2, [K3]: 3 }, vanity: true, migrator: MIGRATOR, hasGetter: true, migratorOf: { [GS]: MIGRATOR, [GS2]: MIGRATOR2 }, downAt: new Set(), count: 2n, router2Code: null, hasOf: true, down: new Set(),
  graduated: false, pair: PAIR, quoteIs0: false, rq: 6n * E18, rt: 200_000_000n * E18, virtual: 12n * E18 / 10n, real: 48n * E18 / 10n, feeAccrued: 1_000_000_007n, collected: 0n,
  boost: [PAIR, 1_999_999_990n, false, 12n * E18 / 10n, 9n * E18 / 10n],
  routerCode: deployed(), routerFactory: FACTORY, routerWeth: WBNB, listedPair: PAIR, hash: HASH,
  curveFee: 5n * E18 / 100n, creator: ME, agents: new Set([lc(ME)]), native: 10n * E18, wbnb: 10n * E18, wbnbAllow: 0n, tokenBal: 5_000_000n * E18, tokenAllow: 0n,
  gsGrad: 'served', reward: null, gated: true, creators: {}, promote: [0, 0], swapData: null, openAt: 0, swapRevert: null, gas: 160_000n, calls: [], sent: [], code: [], txs: {}, receipts: {},
})
let world = fresh()
const ERC20 = parseAbi(['function symbol() view returns (string)', 'function name() view returns (string)', 'function decimals() view returns (uint8)', 'function balanceOf(address) view returns (uint256)',
  'function allowance(address,address) view returns (uint256)', 'function kindOf(address token) view returns (uint8)', 'function implementation() view returns (address)', 'function owedOf(address token) view returns (uint256)',
  'function launchpad() view returns (address)', 'function approve(address,uint256) returns (bool)', 'function deposit() payable', 'function tokenCount() view returns (uint256)', 'function allTokens(uint256) view returns (address)',
  'function moduleType() view returns (bytes32)'])
const SWAP = parseAbi([
  'function factory() view returns (address)', 'function boost() view returns (address)', 'function WETH() view returns (address)', 'function fees() view returns (address)', 'function migrator() view returns (address)', 'function getPair(address,address) view returns (address)',
  'function INIT_CODE_PAIR_HASH() view returns (bytes32)', 'function token0() view returns (address)', 'function getReserves() view returns (uint112,uint112,uint32)', 'function virtualReserve() view returns (uint256)',
  'function realQuoteReserve() view returns (uint256)', 'function feeAccrued() view returns (uint256)', 'function boosts(address) view returns (address,uint64,bool,uint128,uint128)', 'function CREATOR_BPS() view returns (uint256)',
])
const MULTI = parseAbi(['struct Call { address target; bool allowFailure; bytes callData; }', 'struct Res { bool success; bytes returnData; }', 'function aggregate3(Call[] calls) payable returns (Res[])'])
const functions = new Map()
for (const f of [...POOL_HANDLER_ABI, ...V3_EVENT_ABIS.flat(), ...SWAP, ...ERC20, ...VANITY_ABI, ...GRAD_TARGET_ABI, ...CREATOR_FEE_ABI, ...AGENT_WINDOW_ABI, ...G.GANGSWAP_PAD_ABI, ...G.GANGSWAP_FEES_ABI, ...G.GANGSWAP_ROUTER_ABI, ...ROUTER_ABI, ...PROMOTE_PAD_ABI, ...GRAD_PAD_ABI, ...BASE_PAD_ABI, ...BOND_ABI, ...CALL_BOND_ABI, ...MULTI]
  .filter((x) => x.type === 'function')) if (!functions.has(toFunctionSelector(f))) functions.set(toFunctionSelector(f), f)
const revert = { error: { code: 3, message: 'execution reverted', data: '0x' } }
const err = (sig) => ({ error: { code: 3, message: 'execution reverted', data: toFunctionSelector(sig) } })
const reason = (s) => ({ error: { code: 3, message: `execution reverted: ${s}`, data: `0x08c379a0${encodeAbiParameters([{ type: 'string' }], [s]).slice(2)}` } })
const rpcDown = { error: { code: -32603, message: 'internal error' } }

let inMulti = false
const call = ({ to, data, from, value }) => {
  const f = functions.get(data.slice(0, 10))
  const at = lc(to) === MPAD ? PAD : lc(to)
  if (!f) { world.calls.push([at, data.slice(0, 10)]); return revert }
  const { args = [] } = decodeFunctionData({ abi: [f], data })
  world.calls.push([at, f.name])
  if (f.name === 'aggregate3') {
    const result = args[0].map((c) => { inMulti = true; const r = call({ to: c.target, data: c.callData, from }); inMulti = false; return { success: !r.error, returnData: r.result ?? '0x' } })
    return { result: encodeFunctionResult({ abi: MULTI, functionName: 'aggregate3', result }) }
  }
  if (world.down.has(f.name) || world.downAt.has(at)) return rpcDown
  const ok = (result) => ({ result: encodeFunctionResult({ abi: [f], functionName: f.name, result }) })
  if (at === PINNED) return { factory: () => ok(F3), WETH: () => ok(WBNB) }[f.name]?.() ?? revert
  if (at === F3) return { fees: () => ok(E3), migrator: () => ok(M3) }[f.name]?.() ?? revert
  if (at === M3) return { factory: () => ok(F3), boost: () => ok(B3) }[f.name]?.() ?? revert
  if (at === MIGRATOR2) return { factory: () => ok(FACTORY2), boost: () => ok(BOOST2) }[f.name]?.() ?? revert
  if (at === FACTORY2) return { fees: () => ok(FEES2), migrator: () => ok(MIGRATOR2), getPair: () => ok(lc(args[0]) === GS2 ? PAIR2 : zeroAddress), INIT_CODE_PAIR_HASH: () => ok(HASH) }[f.name]?.() ?? revert
  if (at === BOOST2) return f.name === 'boosts' ? ok([lc(args[0]) === GS2 ? PAIR2 : zeroAddress, 0n, false, 2n * E18, E18]) : revert
  if (at === FEES2) return { CREATOR_BPS: () => ok(7000n), creatorFeeOf: () => ok(22n), claim: () => ok(22n) }[f.name]?.() ?? revert
  if (at === PAIR2) return { token0: () => ok(GS2), getReserves: () => ok([100_000_000n * E18, 9n * E18, 0]), virtualReserve: () => ok(E18), realQuoteReserve: () => ok(8n * E18), feeAccrued: () => ok(0n) }[f.name]?.() ?? revert
  if (at === ROUTER2) {
    if (f.name === 'factory') return ok(FACTORY2)
    if (f.name === 'WETH') return ok(WBNB)
    if (f.name === 'swapExactETHForTokens') return ok([BigInt(value), G.amountOut(BigInt(value), 9n * E18, 100_000_000n * E18)])
    return f.name.startsWith('swap') ? ok([args[0], lc(args[2][0]) === WBNB ? G.amountOut(args[0], 9n * E18, 100_000_000n * E18) : G.amountOut(args[0], 100_000_000n * E18, 9n * E18)]) : revert
  }
  if (at === MIGRATOR) return { factory: () => ok(FACTORY), boost: () => ok(BOOST) }[f.name]?.() ?? revert
  if (at === FACTORY) return { fees: () => ok(FEES), migrator: () => ok(MIGRATOR), getPair: () => ok(lc(args[0]) === GS2 ? zeroAddress : world.listedPair), INIT_CODE_PAIR_HASH: () => ok(world.hash) }[f.name]?.() ?? revert
  if (at === BOOST) return f.name === 'boosts' ? ok(world.boost) : revert
  if (at === FEES) {
    if (f.name === 'claim') return lc(from) === lc(world.creator) ? ok(world.collected + (world.feeAccrued * 7000n) / 10000n) : err('NotCreator()')
    return { CREATOR_BPS: () => ok(7000n), creatorFeeOf: () => ok(world.collected) }[f.name]?.() ?? revert
  }
  if (at === PAIR) {
    const r = world.quoteIs0 ? [world.rq, world.rt, 0] : [world.rt, world.rq, 0]
    return { token0: () => ok(world.quoteIs0 ? WBNB : GS), getReserves: () => ok(r), virtualReserve: () => ok(world.virtual), realQuoteReserve: () => ok(world.real), feeAccrued: () => ok(world.feeAccrued) }[f.name]?.() ?? revert
  }
  if (at === ROUTER) {
    if (f.name === 'factory') return world.routerFactory ? ok(world.routerFactory) : revert
    if (f.name === 'WETH') return ok(world.routerWeth)
    if (f.name.startsWith('swap')) {
      if (world.swapRevert) return world.swapRevert
      if (world.swapData) return { result: world.swapData }
      const native = f.name === 'swapExactETHForTokens'
      const [amountIn, minOut, path] = native ? [BigInt(value ?? 0), args[0], args[1]] : [args[0], args[1], args[2]]
      const buy = lc(path[0]) === WBNB
      const out = buy ? G.amountOut(amountIn, world.rq, world.rt) : G.amountOut(amountIn, world.rt, world.rq)
      if (out < minOut) return reason('GangSwapRouter: INSUFFICIENT_OUTPUT_AMOUNT')
      return ok([amountIn, out])
    }
    return revert
  }
  if (at === WBNB) return { balanceOf: () => ok(world.wbnb), allowance: () => ok(world.wbnbAllow), symbol: () => ok('WBNB'), decimals: () => ok(18) }[f.name]?.() ?? revert
  if (at === GS || at === GS2 || at === K1) return { balanceOf: () => ok(world.tokenBal), allowance: () => ok(world.tokenAllow), symbol: () => ok('GSW'), decimals: () => ok(18), launchpad: () => ok(PAD) }[f.name]?.() ?? revert
  if (at === lc(HANDLER) && f.name === 'owedOf') return ok(0n)
  if (f.name === 'kindOf' && world.kindDown && inMulti) return revert
  if (f.name === 'kindOf') return ok(at === PAD ? world.kinds[lc(args[0])] ?? 0 : 0)
  if (f.name === 'implementation') return ok(t(0x1111))
  if (f.name === 'bondOf') {
    return ok(BOND_ABI.find((x) => x.name === 'bondOf').outputs[0].components ? Object.fromEntries(BOND_ABI.find((x) => x.name === 'bondOf').outputs[0].components.map((c) => [c.name, c.type === 'address' ? zeroAddress : c.type === 'bool' ? false : /uint(8|16|32|40|48)$/.test(c.type) ? 0 : 0n])) : 0n)
  }
  if (f.name === 'activeBondOf') return ok(0n)
  if (at === GANG_ROUTER) return f.name === 'v3BuyBNB' ? ok(1_000_000n * E18) : revert
  if (f.name === 'tokenInitCodeHash') return ok(`0x${'ab'.repeat(32)}`)
  if (f.name === 'tokenCount') return ok(at === PAD ? world.count : 0n)
  if (f.name === 'allTokens') return ok([GS, K1, GS2][Number(args[0])])
  if (f.name === 'CREATOR_FEE_SHARE_BPS') return ok(7000n)
  if (f.name === 'curves' && at !== PAD) return ok([zeroAddress, zeroAddress, 0n, 0n, 0n, 0n, false, 0, 0, 0, zeroAddress, zeroAddress])
  if (at !== PAD) return revert
  const isGs = args[0] && lc(args[0]) === GS
  const inner = (d) => {
    const g = functions.get(d.slice(0, 10))
    world.sent.push(g?.name)
    if (g?.name === 'createWithSalt') return inner(decodeFunctionData({ abi: [g], data: d }).args[1])
    return g?.name
  }
  // the pad's rule: the named version is the current one (world.nowMigrator: the owner switched after the read)
  const changed = (d) => {
    const g = functions.get(d.slice(0, 10))
    if (g?.name === 'createWithSalt') return changed(decodeFunctionData({ abi: [g], data: d }).args[1])
    if (g?.name !== 'createGangSwap') return null
    const current = world.nowMigrator ?? world.migrator
    if (lc(decodeFunctionData({ abi: [g], data: d }).args[5]) === current) return null
    return { error: { code: 3, message: 'execution reverted', data: encodeErrorResult({ abi: G.GANGSWAP_PAD_ABI, errorName: 'GangSwapVersionChanged', args: [current] }) } }
  }
  // createGangSwapWithGradReward as the pad runs it: `via` the wrappers around it (window first); null: another create
  const gradCreate = (d, via = []) => {
    const g = functions.get(d.slice(0, 10))
    if (g?.name === 'createWithAgentWindow' || g?.name === 'createWithSalt') return gradCreate(decodeFunctionData({ abi: [g], data: d }).args[1], [...via, g.name])
    if (g?.name !== 'createGangSwapWithGradReward') return null
    const a = decodeFunctionData({ abi: [g], data: d }).args
    world.gradCalls = [...(world.gradCalls ?? []), { via, seed: a[6].seed }]
    if (world.gsGrad === 'down') return rpcDown
    if (world.gsGrad === 'absent') return via.length ? err(via.at(-1) === 'createWithSalt' ? 'BadVanityCall()' : 'BadAgentWindowCall()') : revert
    if (world.gsGrad === 'unwrapped' && via.length) return err('BadVanityCall()')
    if (world.gsGrad === 'odd') return { result: '0x' }
    if (world.gsGrad === 'closed') return err('GradNotOpen()')
    const c = a[6]
    if (!c.seed || !c.minBuy || !c.entries || c.carryBps || c.promoteBps || c.promoteWindow) return err('BadGradConfig()')
    if (world.vanity && !via.includes('createWithSalt')) return err('VanityContextRequired()')
    const current = world.nowMigrator ?? world.migrator
    if (lc(a[5]) !== current) return { error: { code: 3, message: 'execution reverted', data: encodeErrorResult({ abi: G.GANGSWAP_PAD_ABI, errorName: 'GangSwapVersionChanged', args: [current] }) } }
    assert.ok(world.wbnb >= c.seed && world.wbnbAllow >= c.seed, 'the real dry run comes after the funding')
    return { result: encodeAbiParameters([{ type: 'address' }], [t(0x6abcd)]) }
  }
  if (/^create/.test(f.name)) { const x = gradCreate(data); if (x) return x }
  const noReward = { state: 0, pot: 0n, minBuy: 0n, entries: 0, lastBps: 0, carryBps: 0, refundAfter: 0, createdAt: 0, refundAt: 0, gradAt: 0, seq: 0n, countdown: zeroAddress, claimed: 0n, carryOwed: 0n, settled: false, valid: 0, validSpent: 0n, refundPending: false }
  const rw = lc(args[0] ?? '') === GS ? world.reward : null
  switch (f.name) {
    case 'gradRewardDeps': return ok([world.gradOpen ?? true, t(0xad), zeroAddress])
    case 'gradReward': return world.noGradViews ? revert : ok({ ...noReward, ...rw })
    case 'gradEntries': return ok(rw ? [[ME, OTHER], [2n, 1n], [E18 / 50n, E18 / 20n], [true, true]] : [[], [], [], []])
    case 'gradClaimable': return ok(rw?.state === 2 && lc(args[1]) === lc(ME) ? E18 / 5n : 0n)
    case 'claimGradReward': return ok(E18 / 5n)
    case 'gradRefund': return ok(rw.pot)
    case 'requestGradRefund': case 'cancelGradRefund': case 'settleGradReward': case 'sweepGradReward': return ok(undefined)
    case 'gangSwapMigrator': return world.hasGetter ? ok(world.migrator) : revert
    case 'gangSwapMigratorOf': return world.hasOf ? ok(world.migratorOf[lc(args[0])] ?? zeroAddress) : revert
    case 'createGangSwap': world.sent.push(f.name); if (changed(data)) return changed(data); return world.vanity ? err('VanityContextRequired()') : world.migrator === zeroAddress ? err('GangSwapNotOpen()') : ok(t(0x2abcd))
    case 'createWithSalt': inner(data); return changed(data) ?? ok(t(0x1abcd))
    case 'createWithAgentWindow': world.sent.push(`window:${args[0]}`); inner(args[1]); return changed(args[1]) ?? ok(t(0x3abcd))
    case 'create': case 'createWithGradTarget': world.sent.push(f.name); return ok(t(0x4abcd))
    case 'vanityDeployer': return ok(world.vanity ? VAN : zeroAddress)
    case 'MIN_AGENT_WINDOW_MINUTES': return ok(1)
    case 'MAX_AGENT_WINDOW_MINUTES': return ok(1440)
    case 'agentOpenAt': return ok(world.openAt)
    case 'agentWindowOpen': return ok(world.openAt !== 0 && NOW >= world.openAt)
    case 'walletCapOn': return ok(!(world.openAt !== 0 && NOW >= world.openAt))
    case 'canTradeCurve': return ok(world.agents.has(lc(args[1])) || (world.openAt !== 0 && NOW >= world.openAt))
    case 'taxHandler': case 'router': case 'recipientRegistry': return ok(HANDLER)
    case 'agentGateEnabled': return ok(world.gated)
    case 'isAgent': return ok(world.agents.has(lc(args[0])))
    case 'walletRoom': return ok(10_000_000n * E18)
    case 'curves': {
      const kind = world.kinds[lc(args[0])]
      return ok(kind === 1 || kind === 4
        ? [world.creator, WBNB, world.graduated ? 0n : E18, 50_000_000n * E18, 6n * E18, 2n * E18, world.graduated, 0, 0, 0, world.graduated ? (lc(args[0]) === GS2 ? PAIR2 : world.pair) : zeroAddress, zeroAddress]
        : [zeroAddress, zeroAddress, 0n, 0n, 0n, 0n, false, 0, 0, 0, zeroAddress, zeroAddress])
    }
    case 'graduationRemaining': return ok(world.graduated ? 0n : 5n * E18)
    case 'taxConfigOf': return ok([0, 0, 0, zeroAddress])
    case 'gradTargetOf': return ok(6n * E18)
    case 'promoteOf': return ok(world.promote)
    case 'bindingOf': return ok([zeroAddress, 0, false])
    case 'buy': return world.graduated ? err('AlreadyGraduated()') : ok(1_000_000n * E18)
    case 'sell': return ok(E18 / 100n)
    case 'checkTaxConfigFor': case 'checkTaxConfig': return ok([true, ''])
    case 'GRAD_BNB_TIERS': return ok([6n, 9n, 12n, 15n].map((x) => x * E18))
    case 'TARGET_GRAD_BNB': case 'graduationAmountOf': return ok(9n * E18)
    case 'graduationAmountFor': return ok(args[2])
    case 'PROTOCOL_FEE_BPS': return ok(100n)
    case 'PLATFORM_TAX_BPS': return ok(50n)
    case 'CREATOR_FEE_SHARE_BPS': return ok(7000n)
    case 'creatorFeeOf': return ok(isGs ? world.curveFee : 0n)
    case 'claimCreatorFee': return lc(from) === lc(world.creator) ? ok(world.curveFee) : err('NotCreator()')
    case 'tokenVersionOf': return ok(1)
    case 'dividendVault': return ok(t(0xd17))
    default: return revert
  }
}
const answer = (b) => {
  const p = b.params ?? []
  switch (b.method) {
    case 'eth_chainId': return { result: '0x61' }
    case 'eth_getCode': world.code.push(lc(p[0])); return world.down.has('getCode') ? rpcDown : { result: lc(p[0]) === ROUTER ? world.routerCode : lc(p[0]) === ROUTER2 ? world.router2Code ?? deployed2() : '0x' }
    case 'eth_blockNumber': return { result: '0x100' }
    case 'eth_getBalance': return { result: `0x${world.native.toString(16)}` }
    case 'eth_estimateGas': world.calls.push([lc(p[0].to), 'estimateGas']); return { result: `0x${world.gas.toString(16)}` }
    case 'eth_getTransactionByHash': world.calls.push(['tx', 'getTransaction']); return { result: world.txs[p[0]] ?? null }
    case 'eth_getTransactionReceipt': return { result: world.receipts[p[0]] ?? null }
    case 'eth_getBlockByNumber': return { result: { number: '0x100', timestamp: `0x${NOW.toString(16)}`, hash: `0x${'11'.repeat(32)}`, parentHash: `0x${'22'.repeat(32)}`, transactions: [], baseFeePerGas: '0x0', gasLimit: '0x1', gasUsed: '0x0', difficulty: '0x0', logsBloom: `0x${'00'.repeat(256)}`, miner: zeroAddress, extraData: '0x', nonce: '0x0000000000000000', sha3Uncles: `0x${'00'.repeat(32)}`, size: '0x1', stateRoot: `0x${'00'.repeat(32)}`, receiptsRoot: `0x${'00'.repeat(32)}`, transactionsRoot: `0x${'00'.repeat(32)}`, uncles: [], totalDifficulty: '0x0' } }
    case 'eth_call':
      if (world.replay && p[1] !== 'latest') { world.replayed = [...(world.replayed ?? []), p[1]]; return world.replay[p[1]] ?? { result: '0x' } }
      return call(p[0])
    default: return { error: { code: -32601, message: `unexpected ${b.method}` } }
  }
}
const server = createServer((req, res) => {
  let body = ''
  req.on('data', (c) => (body += c))
  req.on('end', () => {
    const input = JSON.parse(body)
    const one = (b) => ({ jsonrpc: '2.0', id: b.id, ...answer(b) })
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify(Array.isArray(input) ? input.map(one) : one(input)))
  })
})
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
const rpc = `http://127.0.0.1:${server.address().port}`
process.env.GANG_TESTNET_RPC_URL = rpc
V3_NETS.testnet.rpcs = [rpc]

class Failed extends Error { constructor(m, d) { super(`${m} ${JSON.stringify(d ?? {})}`); this.d = d } }
const io = (f, notes = {}) => ({
  opt: (k, d) => f[k] ?? d, flag: (k) => Object.hasOwn(f, k), out: (x) => x,
  fail: (m, d) => { throw new Failed(m, d) }, summarize: () => assert.fail('raw calldata needs no wallet preview'), checkMeta: () => {},
  resolveLogo: async () => { world.uploads = (world.uploads ?? 0) + 1; return { logoURI: 'ipfs://logo' } },
  resolveMeta: async () => ({ metaURI: 'ipfs://meta', metadata: { name: 'G' } }),
  notes: { step: (_c, tx, extra) => ({ success: true, ...extra, tx: { ...tx, value: String(tx.value ?? 0n) } }), skipped: () => ({}), follow: async () => null, priced: async () => null, following: false, pool: {}, ...notes },
})
const run = (sub, f = {}, notes) => runV3(sub, io({ token: GS, testnet: true, calldata: true, from: ME, ...f }, notes))
const create = (f = {}) => runV3('create', io({ name: 'G', symbol: 'GSW', venue: 'gangswap', from: ME, testnet: true, calldata: true, ...f }))
const refused = (p, re) => assert.rejects(p, (e) => e instanceof Failed && re.test(e.message), String(re))
const env = (extra = {}) => ({ ...process.env, HOME: '/nonexistent-gang-test-home', PATH: '', GANG_API: 'http://127.0.0.1:1/api', ...extra })
const cli = (args, extra) => new Promise((resolve) => execFile(process.execPath, [CLI, ...args], { env: env(extra), maxBuffer: 1 << 24 }, (_e, out) => { try { resolve(JSON.parse(out)) } catch { resolve({ raw: out }) } }))
const ON = { GANG_TESTNET_SWAP_ROUTER: ROUTER }
const withRouter = async (fn) => { process.env.GANG_TESTNET_SWAP_ROUTER = ROUTER; try { return await fn() } finally { delete process.env.GANG_TESTNET_SWAP_ROUTER } }
/** No pool function of GangRouter, no Pancake router, no tax-handler quote was asked. */
const neverPancake = (why) => {
  for (const [at, fn] of world.calls) {
    assert.ok(!PANCAKE.includes(at), `${why}: asked the Pancake router (${fn})`)
    assert.doesNotMatch(fn, /^pool(Buy|Sell)|getAmountsOut|previewSell|pancakeRouter/, `${why}: ${fn} at ${at}`)
    if (world.graduated) assert.notEqual(at, GANG_ROUTER, `${why}: asked GangRouter (${fn})`)
  }
}

try {
  // ---------------------------------------------------------------- create
  // refused through the CLI before any RPC (the node sees nothing), on every create path
  for (const [args, re] of [
    [['create', '--venue', 'uniswap'], /--venue must be/], [['create', '--venue'], /--venue must be/], [['v3', 'create', '--venue', 'Gangswap'], /--venue must be/],
    [['create', '--venue', 'gangswap', '--fair'], /--fair can't go/], [['fair', 'create', '--venue', 'gangswap'], /--fair can't go/], [['create', '--venue', 'gangswap', '--fly'], /--fly can't go/], [['fly', 'create', '--venue', 'gangswap'], /--fly can't go/],
    [['create', '--venue', 'gangswap', '--dev-buy', '1'], /--dev-buy can't go/], [['v3', 'create', '--venue', 'gangswap', '--buy-tax', '2', '--sell-tax', '2', '--promote', '10'], /--buy-tax can't go/],
    [['create', '--venue', 'gangswap', '--promote', '10'], /--promote can't go/], [['create', '--venue', 'gangswap', '--bond', '1'], /--bond can't go/], [['create', '--venue', 'gangswap', '--countdown-reward', '--cd-max-payout', '1'], /--countdown-reward can't go/],
    [['create', '--venue', 'gangswap', '--vault', OTHER], /--vault can't go/], [['create', '--venue', 'gangswap', '--base', '5', '--base-vest', '30'], /--base can't go/], [['create', '--venue', 'gangswap', '--grad-reward', '1', '--gr-carry', '0'], /--gr-carry can't go.*untaxed, so it has none/],
    [['create', '--venue', 'gangswap', '--grad-reward', '1', '--promote', '10'], /--promote can't go.*no promoter share/], [['create', '--venue', 'gangswap', '--grad-reward', '1', '--countdown-reward', '--cd-max-payout', '1'], /--countdown-reward can't go/],
    [['create', '--venue', 'gangswap', '--grad-reward', '1', '--dev-buy', '1'], /--dev-buy can't go/], [['create', '--venue', 'gangswap', '--gr-last', '10'], /--gr-last goes with --grad-reward/],
    [['create', '--venue', 'gangswap', '--quote', OTHER, '--ref-pool', OTHER], /--quote can't go/],
  ]) {
    world = fresh()
    const r = await cli([...args, '--name', 'G', '--symbol', 'GSW', '--testnet', '--calldata'])
    assert.equal(r.success, false, args.join(' '))
    assert.match(r.error, re, args.join(' '))
    assert.equal(world.calls.length, 0, `${args.join(' ')}: before any read`)
  }
  for (const cmd of ['info', 'sell', 'status']) assert.match((await cli([cmd, '--token', GS, '--testnet', '--venue', 'gangswap'])).error, /only applies when creating/)
  assert.match((await cli(['buy', '--token', GS, '--amount', '1', '--testnet', '--venue', 'gangswap'])).error, /only applies when creating|not a flag of a buy/)
  // runLaunch refuses by itself too (runV3 never sees a launch)
  {
    const { runLaunch } = await import('../src/launch.js')
    await refused(runLaunch('v3', { io: io({ name: 'G', symbol: 'G', venue: 'gangswap', 'dev-buy': '1', testnet: true }) }), /--dev-buy can't go with --venue gangswap/)
    await refused(runLaunch('v3', { io: io({ name: 'G', symbol: 'G', venue: 'gangswap', testnet: true }) }), /plain create/)
    await refused(runLaunch('v3', { io: io({ name: 'G', symbol: 'G', venue: 'nope', testnet: true }) }), /--venue must be/)
  }
  // runV3 refuses the same (a caller that skips index.js)
  world = fresh()
  for (const [f, v] of Object.entries(REFUSED)) await refused(create({ [f]: v }), new RegExp(`--${f} can't go with --venue gangswap`))
  assert.deepEqual([world.sent, world.uploads], [[], undefined])
  await refused(create({ 'buy-tax': '0' }), /both --buy-tax and --sell-tax/)

  // not open: the migrator 0, or a pad without the getter; an RPC failure is said apart. All before a wallet step (no baw,
  // no --from), a read of the wallet or an upload
  for (const [set, re] of [[{ migrator: zeroAddress }, /^GangSwap is not open on this network yet$/], [{ hasGetter: false }, /^GangSwap is not open on this network yet$/], [{ hasOf: false }, /^GangSwap is not open on this network yet$/], [{ down: new Set(['gangSwapMigrator']) }, /could not check the pad for GangSwap \(RPC error\)/], [{ down: new Set(['gangSwapMigratorOf']) }, /could not check the pad for GangSwap \(RPC error\)/]]) {
    world = { ...fresh(), ...set }
    const r = await cli(['create', '--venue', 'gangswap', '--name', 'G', '--symbol', 'GSW', '--testnet', '--calldata'])
    assert.equal(r.success, false)
    assert.match(r.error, re)
    assert.deepEqual([world.sent, [...new Set(world.calls.map((c) => c[1]))].filter((x) => !/^gangSwapMigrator(Of)?$/.test(x))], [[], []])
  }
  // an older generation as the create target: not open, nothing asked
  world = fresh()
  {
    const V2 = GANG_GENS.testnet.find((g) => g.gen === '2.0').pad
    const r = await cli(['create', '--venue', 'gangswap', '--name', 'G', '--symbol', 'GSW', '--testnet', '--calldata'], { GANG_TESTNET_PAD: V2 })
    assert.match(r.error, /GangSwap is not open on this network yet/)
    assert.equal(world.calls.length, 0)
  }

  // open, abcd on: createWithSalt(salt, createGangSwap(name, symbol, logo, meta, grad))
  world = fresh()
  let r = await create({ grad: '6' })
  assert.equal(r.success, true, JSON.stringify(r))
  let d = decodeFunctionData({ abi: VANITY_ABI, data: r.tx.data })
  assert.equal(d.functionName, 'createWithSalt')
  assert.deepEqual(decodeFunctionData({ abi: G.GANGSWAP_PAD_ABI, data: d.args[1] }), { functionName: 'createGangSwap', args: ['G', 'GSW', 'ipfs://logo', 'ipfs://meta', 6n * E18, getAddress(MIGRATOR)] })
  assert.deepEqual([lc(r.tx.to), r.tx.value, r.addressSuffix], [PAD, '0', 'abcd'])
  assert.deepEqual(world.sent, ['createWithSalt', 'createGangSwap'], 'the dry run went through the same calls')
  assert.deepEqual([r.buyTaxPct, r.sellTaxPct, r.recipient, r.graduationTargetBnb, r.quote], [0, 0, null, 6, 'WBNB'])
  // the preview's words
  const said = JSON.stringify(r)
  assert.match(r.venue.permanent, /PERMANENT.*for good/)
  assert.equal(lc(r.venue.version), MIGRATOR)
  assert.match(r.venue.versionNote, new RegExp(`version is fixed at this create, for good.*${MIGRATOR}.*the tx reverts \\(GangSwapVersionChanged\\)`, 'i'))
  assert.match(r.venue.trading, /trades on GangSwap after graduation, not PancakeSwap.*DexScreener may not list it/)
  assert.match(r.venue.buyBack, /no trade could ever reach.*scheduled buy-back and burn: about 40 steps over about 5 minutes/)
  assert.match(r.venue.fee, /1% fee.*on buys.*creator gets 70%.*on sells.*creator gets nothing/)
  assert.match(r.graduation, /graduates into GangSwap once 6 BNB/)
  assert.doesNotMatch(r.graduation + r.split, /PancakeSwap/)
  assert.match(r.note, /Venue: GangSwap, for good/)
  // no --grad: the pad's default target
  r = await create()
  assert.equal(decodeFunctionData({ abi: G.GANGSWAP_PAD_ABI, data: decodeFunctionData({ abi: VANITY_ABI, data: r.tx.data }).args[1] }).args[4], 9n * E18)
  await refused(create({ grad: '7' }), /--grad must be one of 6 \/ 9 \/ 12 \/ 15/)
  // an agent window around it
  world = fresh()
  r = await create({ 'agent-window': '30' })
  d = decodeFunctionData({ abi: AGENT_WINDOW_ABI, data: r.tx.data })
  assert.deepEqual([d.functionName, d.args[0]], ['createWithAgentWindow', 30])
  assert.equal(decodeFunctionData({ abi: G.GANGSWAP_PAD_ABI, data: decodeFunctionData({ abi: VANITY_ABI, data: d.args[1] }).args[1] }).functionName, 'createGangSwap')
  assert.equal(lc(decodeFunctionData({ abi: G.GANGSWAP_PAD_ABI, data: decodeFunctionData({ abi: VANITY_ABI, data: d.args[1] }).args[1] }).args[5]), MIGRATOR)
  assert.deepEqual(world.sent, ['window:30', 'createWithSalt', 'createGangSwap'])
  assert.equal(r.agentWindow.minutes, 30)
  // the version named is the pad's current one, whichever it is
  world = { ...fresh(), migrator: MIGRATOR2 }
  r = await create()
  assert.deepEqual([lc(decodeFunctionData({ abi: G.GANGSWAP_PAD_ABI, data: decodeFunctionData({ abi: VANITY_ABI, data: r.tx.data }).args[1] }).args[5]), lc(r.venue.version)], [MIGRATOR2, MIGRATOR2])
  // the owner switched after it was read: every form reverts, with the new version and what to do; no tx, no upload
  for (const [o, f] of [[{}, {}], [{}, { 'agent-window': '30' }], [{ vanity: false }, {}], [{ vanity: false }, { 'agent-window': '30' }]]) {
    world = { ...fresh(), ...o, nowMigrator: MIGRATOR2 }
    r = await create(f)
    assert.deepEqual([r.success, r.reverted, r.error, lc(r.reason), r.tx, world.uploads], [false, true, 'GangSwapVersionChanged', MIGRATOR2, undefined, undefined], JSON.stringify(r))
    assert.match(r.hint, /re-run the create to see the new version/)
  }
  assert.equal(toFunctionSelector('function GangSwapVersionChanged(address)'), encodeErrorResult({ abi: G.GANGSWAP_PAD_ABI, errorName: 'GangSwapVersionChanged', args: [PAD] }).slice(0, 10))
  // no router of that version known: warned (in venue and on the preview), never refused; unread said as unread
  {
    const L = G.GANGSWAP_VERSIONS.testnet
    const V1 = { router: ROUTER, codeHash: G.GANGSWAP_ROUTER_CODE_HASH, sites: G.GANGSWAP_ROUTER_SITES }, V2 = { ...V1, router: ROUTER2 }
    const NONE = /^this CLI version has no GangSwapRouter for this GangSwap version.*update the CLI/, UNREAD = /^could not read whether this CLI version has a GangSwapRouter/
    const warned = async (list, w, re, e = null) => {
      L.length = 0; L.push(...list)
      if (e) process.env.GANG_TESTNET_SWAP_ROUTER = e
      world = { ...fresh(), ...w }
      const x = await create()
      delete process.env.GANG_TESTNET_SWAP_ROUTER
      assert.deepEqual([x.success, !!x.tx], [true, true], JSON.stringify(x))
      assert.equal(x.warning, x.venue.routerWarning)
      if (re) assert.match(x.warning ?? '', re); else assert.deepEqual([x.warning, 'routerWarning' in x.venue], [undefined, false])
    }
    await warned([], {}, NONE)
    for (const l of [[V1], [V1, V2], [V2, V1]]) await warned(l, {}, null)
    await warned([V1, V2], { migrator: MIGRATOR2 }, null)
    for (const l of [[V1], [{ ...V2, router: lc(t(0x5c9)) }, V1]]) await warned(l, { migrator: MIGRATOR2 }, NONE)
    await warned([V1], { routerCode: codeOf(1) }, NONE) // the right factory(), another code
    await warned([], {}, null, ROUTER)
    await warned([], {}, NONE, ROUTER2)
    await warned([], {}, NONE, 'nope')
    await warned([V1], {}, null, ROUTER2)
    await warned([V1], { migrator: MIGRATOR2 }, null, ROUTER2)
    await warned([], { migrator: MIGRATOR2 }, null, `${ROUTER},${ROUTER2}`)
    for (const down of ['factory', 'WETH', 'INIT_CODE_PAIR_HASH']) await warned([V1], { down: new Set([down]) }, UNREAD)
    await warned([V1], { downAt: new Set([MIGRATOR]) }, UNREAD)
    await warned([V1, V2], { downAt: new Set([ROUTER]) }, UNREAD)
    await warned([V1, V2], { downAt: new Set([ROUTER2]) }, null)
    L.length = 0
  }
  // abcd off: direct
  world = { ...fresh(), vanity: false }
  r = await create({ grad: '15' })
  assert.deepEqual(decodeFunctionData({ abi: G.GANGSWAP_PAD_ABI, data: r.tx.data }).args, ['G', 'GSW', 'ipfs://logo', 'ipfs://meta', 15n * E18, getAddress(MIGRATOR)])
  assert.equal(r.tokenIfNext, t(0x2abcd))
  // it closed between the check and the dry run: the pad's own error, in words
  // (an agent id is still needed)
  world = { ...fresh(), agents: new Set() }
  await refused(create(), /no Agent ID/)
  // regression: without --venue, and with --venue pancake, the create is what it was
  for (const v of [{ venue: undefined }, { venue: 'pancake' }]) {
    world = fresh()
    const f = { name: 'G', symbol: 'GSW', from: ME, testnet: true, calldata: true, grad: '6', ...(v.venue && v) }
    r = await runV3('create', io(f))
    assert.equal(decodeFunctionData({ abi: V3_EVENT_ABIS[0], data: decodeFunctionData({ abi: VANITY_ABI, data: r.tx.data }).args[1] }).functionName, 'createWithGradTarget')
    assert.equal(r.venue, undefined)
    assert.match(r.graduation, /graduates into PancakeSwap/)
    assert.match(r.split, /no tax in the PancakeSwap pool/)
    assert.doesNotMatch(r.note, /GangSwap/)
    assert.ok(!world.calls.some(([, fn]) => fn === 'gangSwapMigrator'), 'the pad is not asked about GangSwap')
  }

  // ---------------------------------------------------------------- create with a graduation reward
  {
    const cfgT = (abi, fn) => JSON.stringify(abi.find((x) => x.name === fn).inputs.at(-1).components.map((c) => [c.name, c.type]))
    assert.equal(cfgT(G.GANGSWAP_PAD_ABI, 'createGangSwapWithGradReward'), cfgT(GRAD_PAD_ABI, 'createWithGradReward'))
    // the selector of the contract's signature (IGangSwapPad)
    assert.equal(toFunctionSelector(G.GANGSWAP_PAD_ABI.find((x) => x.name === 'createGangSwapWithGradReward')),
      toFunctionSelector('function createGangSwapWithGradReward(string,string,string,string,uint256,address,(uint128,uint96,uint8,uint16,uint16,uint32,uint16,uint32))'))
    assert.equal(refusal({ 'grad-reward': '1', 'gr-min-buy': '1', 'gr-entries': '5', 'gr-last': '1', 'gr-refund-days': '30', grad: '6', 'agent-window': '5' }), null)
    const G1 = { 'grad-reward': '0.5' }
    const SHAPES = [
      [{ vanity: true }, {}, ['createWithSalt']], [{ vanity: false }, {}, []],
      [{ vanity: true }, { 'agent-window': '30' }, ['createWithAgentWindow', 'createWithSalt']], [{ vanity: false }, { 'agent-window': '30' }, ['createWithAgentWindow']],
    ]
    const ABIS = [...G.GANGSWAP_PAD_ABI, ...VANITY_ABI, ...AGENT_WINDOW_ABI]
    const unwrap = (data, via = []) => {
      const x = decodeFunctionData({ abi: ABIS, data })
      return x.functionName.startsWith('createWith') ? unwrap(x.args[1], [...via, x.functionName]) : { ...x, via }
    }
    // ---- not served / closed / unread: refused in the shape asked for, with no money in the wallet: before any wrap, approval or upload
    for (const [o, f, via] of SHAPES) {
      for (const [gsGrad, re] of [['absent', /^GangLaunchpad 3\.0 on the BSC testnet has no graduation reward for GangSwap tokens yet \(the pad is not upgraded for it\): drop --grad-reward, or --venue gangswap/],
        ['odd', /no graduation reward for GangSwap tokens yet/], ['closed', /^the graduation reward is closed on this pad/], ['down', /^could not check the pad for a graduation reward on GangSwap tokens \(RPC error\).*same command again/]]) {
        world = { ...fresh(), ...o, gsGrad, wbnb: 0n }
        await refused(create({ ...G1, ...f }), re)
        assert.deepEqual(world.gradCalls.map((x) => [x.via, x.seed])[0], [via, 0n], 'asked with an empty config, in the shape of this create')
        assert.ok(world.gradCalls.every((x) => x.seed === 0n))
        assert.deepEqual([world.uploads, world.sent], [undefined, []])
        assert.ok(!world.calls.some(([at, fn]) => at === WBNB && (fn === 'balanceOf' || fn === 'allowance')), `${gsGrad}: the wallet's WBNB was not looked at`)
      }
    }
    // an entry without the wrapper's listing is not served in that shape
    world = { ...fresh(), gsGrad: 'unwrapped', wbnb: 0n }
    await refused(create(G1), /no graduation reward for GangSwap tokens yet/)
    world = { ...fresh(), gsGrad: 'absent', vanity: false }
    assert.equal((await create()).success, true, 'a plain GangSwap create does not need it')
    assert.equal(world.gradCalls, undefined, 'nor asks for it')
    // mainnet says so by name
    {
      world = { ...fresh(), gsGrad: 'absent', wbnb: 0n }
      const o = await cli(['create', '--venue', 'gangswap', '--grad-reward', '0.5', '--name', 'G', '--symbol', 'GSW', '--calldata', '--from', ME], { GANG_RPC_URL: rpc })
      assert.deepEqual([o.success, /GangLaunchpad 3\.0 on BSC mainnet has no graduation reward for GangSwap tokens yet/.test(o.error)], [false, true], JSON.stringify(o))
    }
    // the reward closed by its own switch
    world = { ...fresh(), gradOpen: false, wbnb: 0n }
    await refused(create(G1), /the graduation reward is closed on this pad: drop --grad-reward/)
    // GangSwap closed: that first
    world = { ...fresh(), migrator: zeroAddress, wbnb: 0n }
    await refused(create(G1), /GangSwap is not open/)

    // ---- the stages, each read from the chain: wrap what is short, approve exactly the seed, create
    for (const [o, f, via] of SHAPES) {
      world = { ...fresh(), ...o, wbnb: E18 / 5n }
      for (let again = 0; again < 2; again++) {
        r = await create({ ...G1, ...f })
        assert.deepEqual([r.step, r.wrap, lc(r.tx.to), r.tx.value], ['wrap-bnb', '0.3', WBNB, String((E18 * 3n) / 10n)], 'the same step again until it lands')
      }
      assert.match(r.why, /pulls the 0\.5 WBNB reward pool/)
      assert.deepEqual([lc(r.venue.version), r.gradReward.pool], [MIGRATOR, '0.5 WBNB'], 'what the money is for, before it moves')
      assert.match(r.stages, /wrap-bnb.*approve-quote \(exactly the seed\) → create/)
      world.wbnb = E18 / 2n
      for (const allow of [0n, E18 / 2n - 1n]) {
        world.wbnbAllow = allow
        r = await create({ ...G1, ...f })
        const ap = decodeFunctionData({ abi: ERC20, data: r.tx.data })
        assert.deepEqual([r.step, r.approve, ap.functionName, lc(ap.args[0]), ap.args[1], r.tx.value], ['approve-quote', '0.5', 'approve', PAD, E18 / 2n, '0'])
        assert.equal(world.uploads, undefined, 'nothing uploaded before the create stage')
      }
      world.wbnbAllow = E18 / 2n
      world.gradCalls = []
      r = await create({ ...G1, ...f, grad: '6' })
      assert.deepEqual([r.success, r.step, lc(r.tx.to), r.tx.value], [true, 'create', PAD, '0'], JSON.stringify(r))
      const u = unwrap(r.tx.data)
      assert.deepEqual([u.via, u.functionName], [via, 'createGangSwapWithGradReward'])
      assert.deepEqual(u.args, ['G', 'GSW', 'ipfs://logo', 'ipfs://meta', 6n * E18, getAddress(MIGRATOR), { seed: E18 / 2n, minBuy: E18 / 100n, entries: 10, lastBps: 3000, carryBps: 0, refundAfter: 90 * 86_400, promoteBps: 0, promoteWindow: 0 }])
      assert.deepEqual(world.gradCalls.map((x) => [x.via, x.seed]), [[via, 0n], [via, E18 / 2n]], 'asked, then dry-run in the very shape')
      if (f['agent-window']) assert.equal(decodeFunctionData({ abi: AGENT_WINDOW_ABI, data: r.tx.data }).args[0], 30)
      assert.equal(G.asksGangSwap(r.tx.data), true)
      // the preview
      assert.match(r.venue.terms, /graduation reward you fund \(see gradReward\): it is paid from your seed only/)
      assert.match(r.gradReward.gangSwap, /never part of the GangSwap pool or its buy-back.*back to you/)
      assert.match(r.gradReward.claims, /sweeps the unclaimed rest .* back to you/)
      assert.match(r.gradReward.warning, /PERMANENT: 0\.5 WBNB leaves this wallet/)
      assert.match(r.graduation, /graduates into GangSwap once 6 BNB/)
      assert.deepEqual([r.gradReward.risks, r.agentWindow?.gradReward], [undefined, undefined])
    }
    // the settings
    world = { ...fresh(), wbnbAllow: E18 }
    r = await create({ 'grad-reward': '1', 'gr-min-buy': '0.05', 'gr-entries': '20', 'gr-last': '0', 'gr-refund-days': '30', quote: WBNB })
    assert.deepEqual(unwrap(r.tx.data).args[6], { seed: E18, minBuy: E18 / 20n, entries: 20, lastBps: 0, carryBps: 0, refundAfter: 30 * 86_400, promoteBps: 0, promoteWindow: 0 })
    // a larger seed on a later run: the shortfall and a new exact approval, never the old one
    world = { ...fresh(), wbnb: E18 / 2n, wbnbAllow: E18 / 2n }
    r = await create({ 'grad-reward': '0.8' })
    assert.deepEqual([r.step, r.wrap], ['wrap-bnb', '0.3'])
    world.wbnb = E18
    r = await create({ 'grad-reward': '0.8' })
    assert.deepEqual([r.step, r.approve], ['approve-quote', '0.8'])
    // refused before the money: a seed too small, bounds, no Agent ID, --gr-* alone
    world = { ...fresh(), wbnb: 0n }
    await refused(create({ 'grad-reward': '0.09' }), /at least 0\.1 WBNB/)
    await refused(create({ ...G1, 'gr-entries': '21' }), /between 1 and 20/)
    await refused(create({ 'gr-entries': '5' }), /--gr-entries goes with --grad-reward/)
    for (const [k, v] of [['gr-carry', '0'], ['gr-carry', '20'], ['promote', '10'], ['countdown-reward', ''], ['cd-seed', '1']]) await refused(create({ ...G1, [k]: v }), new RegExp(`--${k} can't go with --venue gangswap`))
    await refused(create({ ...G1, 'countdown-reward': '' }), /untaxed, so it takes no countdown reward/)
    await refused(create({ ...G1, 'gr-carry': '20' }), /a carry goes into the token's countdown reward.*goes back to you/)
    world = { ...fresh(), wbnb: 0n, agents: new Set() }
    await refused(create(G1), /no Agent ID/)
    world = { ...fresh(), wbnb: 0n, native: E18 / 10n }
    r = await create(G1)
    assert.deepEqual([r.success, r.error], [false, 'not enough BNB'])
    // the version moved after it was read: the pad's words, no tx, no upload
    world = { ...fresh(), wbnbAllow: E18, nowMigrator: MIGRATOR2 }
    r = await create(G1)
    assert.deepEqual([r.success, r.error, r.tx, world.uploads], [false, 'GangSwapVersionChanged', undefined, undefined])
    // without --venue the entry is kind 1's, and the GangSwap one is not asked for
    world = { ...fresh(), wbnbAllow: E18 }
    r = await runV3('create', io({ name: 'G', symbol: 'GSW', from: ME, testnet: true, calldata: true, ...G1 }))
    assert.equal(decodeFunctionData({ abi: GRAD_PAD_ABI, data: decodeFunctionData({ abi: VANITY_ABI, data: r.tx.data }).args[1] }).functionName, 'createWithGradReward')
    assert.deepEqual([world.gradCalls, r.venue, r.stages, typeof r.gradReward.risks], [undefined, undefined, undefined, 'string'])
    // a landed one whose event is missing is seen as a GangSwap create through every wrapper
    const bare = encodeFunctionData({ abi: G.GANGSWAP_PAD_ABI, functionName: 'createGangSwapWithGradReward', args: ['G', 'G', '', '', 6n * E18, MIGRATOR, { seed: 1n, minBuy: 1n, entries: 1, lastBps: 0, carryBps: 0, refundAfter: 1, promoteBps: 0, promoteWindow: 0 }] })
    assert.equal(G.asksGangSwap(bare), true)

    // ---- the token: info, the previews, gang grad-reward
    const live = { state: 1, pot: E18 / 2n, minBuy: E18 / 20n, entries: 10, lastBps: 3000, refundAfter: 90 * 86_400, createdAt: NOW - 86_400, seq: 2n }
    world = { ...fresh(), reward: live, openAt: NOW - 5, wbnbAllow: maxUint256, tokenAllow: maxUint256 }
    r = await run('info')
    assert.deepEqual([r.kind, r.gradReward.state, r.gradReward.pool, r.gradReward.list.length, r.agentWindow.gradReward], ['gangswap', 'on the curve', '0.5', 2, undefined])
    assert.match(r.gradReward.more, /gang grad-reward status --token .* --testnet/)
    r = await run('buy', { amount: '0.1', 'use-wbnb': true })
    assert.deepEqual([r.rewards.gradReward.counts, r.rewards.gradReward.openWarning, r.rewards.countdown], [true, undefined, undefined])
    r = await run('buy', { amount: '0.01', 'use-wbnb': true })
    assert.equal(r.rewards.gradReward.counts, false)
    world.agents = new Set()
    r = await run('buy', { amount: '0.1', 'use-wbnb': true })
    assert.deepEqual([r.rewards.gradReward.counts, /only Agent ID wallets/.test(r.rewards.gradReward.why)], [false, true])
    world.agents = new Set([lc(ME)])
    r = await run('sell', { all: true, 'break-bond': true, 'break-call-bond': true })
    assert.equal(r.rewards.gradReward.entriesLost, 1)
    // none on the token, or a pad without the views: no field, as before
    for (const o of [{}, { noGradViews: true }]) {
      world = { ...fresh(), ...o, wbnbAllow: maxUint256, tokenAllow: maxUint256 }
      assert.equal((await run('info')).gradReward, undefined)
      assert.equal((await run('buy', { amount: '0.1', 'use-wbnb': true })).rewards, undefined)
      assert.equal((await run('sell', { all: true, 'break-bond': true, 'break-call-bond': true })).rewards, undefined)
    }
    // an unreadable reward is said, never read as none
    world = { ...fresh(), down: new Set(['gradReward']), tokenAllow: maxUint256 }
    assert.match((await run('info')).gradReward.error, /could not read/)
    assert.match((await run('sell', { all: true, 'break-bond': true, 'break-call-bond': true })).rewards.gradReward.warning, /could not read/)

    const gr = (sub, f = {}) => runGradReward(sub, io({ token: GS, testnet: true, calldata: true, from: ME, ...f }))
    const built = async (sub, fn) => {
      const x = await gr(sub)
      assert.deepEqual([x.success, x.kind, lc(x.tx.to)], [true, 'gangswap', PAD], JSON.stringify(x))
      assert.deepEqual(decodeFunctionData({ abi: GRAD_PAD_ABI, data: x.tx.data }), { functionName: fn, args: [getAddress(GS)] })
      return x
    }
    world = { ...fresh(), reward: live }
    r = await gr('status')
    assert.deepEqual([r.kind, r.state, r.pool, r.quote, r.restGoesTo], ['gangswap', 'on the curve', '0.5', 'WBNB', undefined])
    await refused(gr('claim'), /not in the state/)
    await refused(gr('refund-request'), /too early/)
    await refused(gr('retry-carry'), /GangSwap token has no countdown module/)
    world.reward = { ...live, createdAt: NOW - 91 * 86_400 }
    await built('refund-request', 'requestGradRefund')
    await refused(gr('refund-request', { from: OTHER }), /only the token's creator/)
    world.reward = { ...world.reward, refundAt: NOW - 3 * 86_400, refundPending: true }
    await refused(gr('refund'), /notice runs until/)
    await built('refund-cancel', 'cancelGradRefund')
    world.reward = { ...world.reward, refundAt: NOW - 8 * 86_400 }
    assert.match((await built('refund', 'gradRefund')).note, /whole pool \(0\.5 WBNB\)/)
    world = { ...fresh(), graduated: true, reward: { ...live, state: 2, gradAt: NOW - 86_400 } }
    assert.match((await gr('status')).next, /gang grad-reward claim/)
    assert.equal((await run('info')).gradReward.state, 'graduated: claims open')
    assert.equal((await built('claim', 'claimGradReward')).amount, '0.2')
    await built('settle', 'settleGradReward')
    await refused(gr('sweep'), /180 days/)
    world.reward = { ...world.reward, gradAt: NOW - 181 * 86_400 }
    assert.match((await built('sweep', 'sweepGradReward')).note, /the creator 0x/)
    await refused(gr('retry-carry'), /GangSwap token has no countdown module/)
    // a kind-4 token without one; the other kinds still refused
    world = fresh()
    await refused(gr('status'), /has no graduation reward/)
    await refused(gr('status', { token: K2 }), /not a V3 curve token/)
    // gang tx decodes what the pad logs for it
    assert.ok(GRAD_EVENT_ABIS.flat().some((x) => x.name === 'GradRewardSet'))
    const caps = capabilities().commands.find((x) => x.command === 'create --venue gangswap --grad-reward')
    assert.deepEqual([caps.access, caps.risk, caps.needsUserConfirmation], ['preview', 'high', true])
  }

  // ---------------------------------------------------------------- the created tx, checked
  const gsCreate = encodeFunctionData({ abi: G.GANGSWAP_PAD_ABI, functionName: 'createGangSwap', args: ['G', 'GSW', '', '', 6n * E18, MIGRATOR] })
  const salted = encodeFunctionData({ abi: VANITY_ABI, functionName: 'createWithSalt', args: [HASH, gsCreate] })
  const windowed = encodeFunctionData({ abi: AGENT_WINDOW_ABI, functionName: 'createWithAgentWindow', args: [5, salted] })
  const made = { address: PAD, topics: encodeEventTopics({ abi: G.GANGSWAP_PAD_ABI, eventName: 'GangSwapCreated', args: { token: GS, migrator: MIGRATOR } }), data: '0x' }
  const tctx = { chainId: '97', read: async (_a, _b, fn, args) => { if (world.down.has(fn)) throw new Error('rpc'); if (fn === 'gangSwapMigratorOf') return world.migratorOf[lc(args[0])] ?? zeroAddress; return fn === 'curves' ? [world.creators[lc(args[0])] ?? ME] : world.kinds[lc(args[0])] ?? 0 } }
  const check = (logs, input, status = 'success', sender = null) => G.gangSwapCreateCheck(tctx, { status, events: decodeLogs(logs, V3_EVENT_ABIS), input, sender })
  world = fresh()
  for (const input of [gsCreate, salted, windowed, `${windowed}67616e6701020304`, null]) {
    const c = (await check([made], input)).gangSwap
    assert.deepEqual([c.verified, c.kind, c.kindOf, lc(c.token)], [true, 'gangswap', 4, GS])
  }
  world.kinds[GS] = 1
  assert.equal((await check([made], salted)).gangSwap.verified, false, 'the event but another kind')
  world.kinds[GS] = 4; world.down.add('kindOf')
  assert.deepEqual([(await check([made], salted)).gangSwap.verified], [null])
  world = fresh()
  assert.equal(lc((await check([made], salted)).gangSwap.creator), lc(ME))
  world.down.add('curves')
  assert.equal((await check([made], salted)).gangSwap.verified, null)
  // whose it is: the creator named, flagged when it isn't the sender
  world = fresh()
  let g1 = (await check([made], salted, 'success', ME)).gangSwap
  assert.deepEqual([g1.creatorIsSender, g1.warning], [undefined, undefined])
  g1 = (await check([made], salted, 'success', OTHER)).gangSwap
  assert.deepEqual([g1.verified, g1.creatorIsSender, lc(g1.creator)], [true, false, lc(ME)])
  assert.match(g1.warning, /creator is not the wallet that sent the tx/)
  // several in one tx: every one is checked
  {
    const GSB = lc(t(0x9a6))
    const made2 = { ...made, topics: encodeEventTopics({ abi: G.GANGSWAP_PAD_ABI, eventName: 'GangSwapCreated', args: { token: GSB, migrator: MIGRATOR } }) }
    world.migratorOf[GSB] = MIGRATOR
    world.kinds[GSB] = 4; world.creators[GSB] = OTHER
    let m = (await check([made, made2], salted, 'success', ME)).gangSwap
    assert.deepEqual([m.verified, m.tokens.map((x) => [lc(x.token), x.verified, lc(x.creator), x.creatorIsSender])], [true, [[GS, true, lc(ME), undefined], [GSB, true, lc(OTHER), false]]])
    world.kinds[GSB] = 1
    m = (await check([made, made2], salted, 'success', ME)).gangSwap
    assert.deepEqual([m.verified, m.tokens.map((x) => x.verified)], [false, [true, false]])
  }
  // the version: the event's migrator is the token's own, or it is not verified
  world = fresh()
  assert.equal(lc((await check([made], salted)).gangSwap.migrator), MIGRATOR)
  for (const m of [zeroAddress, lc(t(0x317))]) {
    world.migratorOf[GS] = m
    const x = (await check([made], salted)).gangSwap
    assert.deepEqual([x.verified, x.kind, lc(x.migrator)], [false, undefined, MIGRATOR])
    assert.match(x.error, /gangSwapMigratorOf\) is not the one in its GangSwapCreated event/)
  }
  world = fresh(); world.down.add('gangSwapMigratorOf')
  assert.equal((await check([made], salted)).gangSwap.verified, null)
  // a pad without gangSwapMigratorOf: said, not verified; the old one-argument event is not a GangSwapCreated at all
  world = fresh()
  {
    const missing = Object.assign(new Error('x'), { walk: (fn) => [{ name: 'ContractFunctionZeroDataError' }].find(fn) })
    const x = (await G.gangSwapCreateCheck({ ...tctx, read: async (a, b, fn, args) => { if (fn === 'gangSwapMigratorOf') throw missing; return tctx.read(a, b, fn, args) } }, { status: 'success', events: decodeLogs([made], V3_EVENT_ABIS), input: salted })).gangSwap
    assert.deepEqual([x.verified, /no gangSwapMigratorOf/.test(x.error)], [false, true])
    const old = { ...made, topics: [toEventSelector('GangSwapCreated(address)'), made.topics[1]] }
    assert.deepEqual(decodeLogs([old], V3_EVENT_ABIS), [])
    assert.deepEqual(decodeLogs([{ ...made, topics: made.topics.slice(0, 2) }], V3_EVENT_ABIS), [])
    assert.match((await check([old], salted)).gangSwap.error, /no GangSwapCreated event/)
    assert.deepEqual(await check([old], null), {})
  }
  // the input is a GangSwap create but the pad emitted no event: said; another contract's event of that name does not count
  for (const input of [gsCreate, salted, windowed, `${salted}67616e67`]) assert.equal((await check([], input)).gangSwap.verified, false)
  assert.equal((await check([{ ...made, address: OTHER }], salted)).gangSwap.verified, false)
  assert.deepEqual(await check([], salted, 'reverted'), {})
  // not a GangSwap create: nothing added
  const plain = encodeFunctionData({ abi: VANITY_ABI, functionName: 'createWithSalt', args: [HASH, '0x12345678'] })
  for (const input of [plain, '0x', null, '0xdeadbeef']) assert.deepEqual(await check([], input), {})
  {
    const hash = `0x${'a1'.repeat(32)}`
    world.receipts[hash] = { transactionHash: hash, status: '0x1', blockNumber: '0xff', blockHash: HASH, transactionIndex: '0x0', from: ME, to: PAD, gasUsed: '0x1', cumulativeGasUsed: '0x1', effectiveGasPrice: '0x1', logsBloom: `0x${'00'.repeat(256)}`, type: '0x0', contractAddress: null, logs: [{ ...made, blockNumber: '0xff', logIndex: '0x0', transactionHash: hash, transactionIndex: '0x0', blockHash: HASH, removed: false }] }
    world.txs[hash] = { hash, input: salted, from: ME, to: PAD, value: '0x0', nonce: '0x0', gas: '0x1', gasPrice: '0x1', blockNumber: '0xff', blockHash: HASH, transactionIndex: '0x0', type: '0x0', v: '0x1b', r: HASH, s: HASH, chainId: '0x61' }
    for (const args of [['tx', '--hash', hash, '--testnet'], ['v3', 'tx', '--hash', hash, '--testnet']]) {
      const o = await cli(args)
      assert.equal(o.success, true, JSON.stringify(o))
      assert.equal(o.gangSwap?.verified, true, args.join(' '))
      assert.ok(o.events.some((e) => e.event === 'GangSwapCreated'))
      assert.equal(lc(o.gangSwap.creator), lc(ME))
    }
    // no event: the input is fetched (a tx to the pad only) to see whether it was a GangSwap create, on testnet and through gang v3 tx too
    const bare = `0x${'a2'.repeat(32)}`, elsewhere = `0x${'a3'.repeat(32)}`
    world.receipts[bare] = { ...world.receipts[hash], transactionHash: bare, logs: [] }
    world.txs[bare] = { ...world.txs[hash], hash: bare }
    world.receipts[elsewhere] = { ...world.receipts[bare], transactionHash: elsewhere, to: OTHER }
    world.txs[elsewhere] = { ...world.txs[bare], hash: elsewhere, to: OTHER }
    for (const args of [['tx', '--testnet'], ['v3', 'tx', '--testnet']]) {
      let x = await cli([...args, '--hash', bare])
      assert.equal(x.gangSwap?.verified, false, args.join(' '))
      assert.match(x.gangSwap.error, /asked for a GangSwap token, but no GangSwapCreated/)
      x = await cli([...args, '--hash', elsewhere])
      assert.deepEqual([x.success, x.gangSwap], [true, undefined])
    }
    // a reverted GangSwap create: why, by replaying the call; anything else adds nothing
    {
      const KEEP = { r: world.receipts, x: world.txs }
      const bad = `0x${'a4'.repeat(32)}`, other = `0x${'a5'.repeat(32)}`, off = `0x${'a6'.repeat(32)}`
      const rc = (h, o = {}) => ({ ...KEEP.r[hash], transactionHash: h, logs: [], status: '0x0', ...o })
      const txOf = (h, input, o = {}) => ({ ...KEEP.x[hash], hash: h, input, gas: '0x7a1200', ...o })
      world.receipts = { [bad]: rc(bad), [other]: rc(other), [off]: rc(off, { to: OTHER }) }
      world.txs = { [bad]: txOf(bad, salted), [other]: txOf(other, plain), [off]: txOf(off, salted, { to: OTHER }) }
      const changed = { error: { code: 3, message: 'execution reverted', data: encodeErrorResult({ abi: G.GANGSWAP_PAD_ABI, errorName: 'GangSwapVersionChanged', args: [MIGRATOR2] }) } }
      const closed = { error: { code: 3, message: 'execution reverted', data: toFunctionSelector('function GangSwapNotOpen()') } }
      const oog = { error: { code: -32000, message: 'out of gas' } }
      for (const args of [['tx', '--testnet'], ['v3', 'tx', '--testnet']]) {
        const ask = async (h, replay) => { world.replay = replay; world.replayed = []; const y = await cli([...args, '--hash', h]); assert.deepEqual([y.success, y.status], [true, 'reverted'], JSON.stringify(y)); return y.gangSwap }
        let g = await ask(bad, { '0xfe': changed })
        assert.deepEqual([g.created, g.reverted, lc(g.current)], [false, 'GangSwapVersionChanged', MIGRATOR2])
        assert.match(g.hint, /re-run the create to see the new version/)
        assert.deepEqual(world.replayed, ['0xfe'])
        g = await ask(bad, { '0xff': changed }) // switched in the same block
        assert.deepEqual([g.reverted, world.replayed.join()], ['GangSwapVersionChanged', '0xfe,0xff'])
        g = await ask(bad, { '0xfe': closed })
        assert.deepEqual([g.reverted, g.current, /not open/.test(g.hint)], ['GangSwapNotOpen', undefined, true])
        assert.equal(await ask(bad, {}), undefined, 'the replay passes: nothing said')
        for (const e of [revert, err('NotAgent()'), oog]) assert.equal(await ask(bad, { '0xfe': e, '0xff': changed }), undefined, 'another reason, or no state: nothing said')
        assert.equal(await ask(other, { '0xfe': changed }), undefined, 'not a GangSwap create')
        assert.deepEqual(world.replayed, [])
        world.calls = []
        assert.equal(await ask(off, { '0xfe': changed }), undefined)
        assert.deepEqual([world.replayed, world.calls.some((c) => c[1] === 'getTransaction')], [[], false], 'not sent to a 3.0 pad: its data is not even read')
        const tx0 = world.txs[bad]; delete world.txs[bad]
        assert.equal(await ask(bad, { '0xfe': changed }), undefined, 'the tx unreadable')
        world.txs[bad] = tx0
      }
      // mainnet
      world.receipts[bad].to = MPAD; world.txs[bad].to = MPAD
      world.replay = { '0xfe': changed }
      let y = await cli(['tx', '--hash', bad], { GANG_RPC_URL: rpc })
      assert.deepEqual([y.success, y.status, y.gangSwap?.reverted], [true, 'reverted', 'GangSwapVersionChanged'], JSON.stringify(y))
      // a tx that succeeded is never replayed
      world.replayed = []
      world.receipts[bad].status = '0x1'
      y = await cli(['tx', '--hash', bad], { GANG_RPC_URL: rpc })
      assert.deepEqual([world.replayed, y.gangSwap?.reverted], [[], undefined])
      world.replay = null
      world.receipts = KEEP.r; world.txs = KEEP.x
    }
    // the input can't be read: said as unread, only for a tx to the pad without the event
    const noTx = world.txs
    world.txs = {}
    for (const args of [['tx', '--testnet'], ['v3', 'tx', '--testnet']]) {
      for (const [h, unread] of [[bare, true], [elsewhere, false], [hash, false]]) {
        const y = await cli([...args, '--hash', h])
        assert.equal(y.success, true)
        assert.equal(/could not be read/.test(y.gangSwapUnread ?? ''), unread, `${args} ${h}`)
        if (h === bare) assert.equal(y.gangSwap, undefined)
      }
    }
    for (const h of [bare, elsewhere]) { // mainnet
      const r2 = world.receipts[h].to
      if (h === bare) world.receipts[h].to = MPAD
      const y = await cli(['tx', '--hash', h], { GANG_RPC_URL: rpc })
      assert.deepEqual([y.success, !!y.gangSwapUnread], [true, h === bare], JSON.stringify(y))
      world.receipts[h].to = r2
    }
    world.receipts[bare].status = '0x0'
    assert.equal((await cli(['tx', '--testnet', '--hash', bare])).gangSwapUnread, undefined)
    world.receipts[bare].to = MPAD
    assert.equal((await cli(['tx', '--hash', bare], { GANG_RPC_URL: rpc })).gangSwapUnread, undefined)
    world.receipts[bare].status = '0x1'; world.receipts[bare].to = PAD
    world.txs = noTx
    for (const args of [['tx', '--testnet'], ['v3', 'tx', '--testnet']]) for (const h of [hash, bare, elsewhere]) assert.equal((await cli([...args, '--hash', h])).gangSwapUnread, undefined)
    // mainnet gang tx
    const MAIN = { GANG_RPC_URL: rpc }
    world.receipts[hash].logs[0].address = MPAD
    let x = await cli(['tx', '--hash', hash], MAIN)
    assert.deepEqual([x.success, x.gangSwap?.verified, lc(x.gangSwap?.creator)], [true, true, lc(ME)], JSON.stringify(x))
    world.txs[hash].from = OTHER
    x = await cli(['tx', '--hash', hash], MAIN)
    assert.equal(x.gangSwap.creatorIsSender, false)
    x = await cli(['tx', '--hash', bare], MAIN)
    assert.equal(x.gangSwap.verified, false)
  }

  // ---------------------------------------------------------------- the kind
  world = fresh()
  const rctx = (read) => ({ chainId: '97', pad: GANG_GENS.testnet[0].pad, gens: GANG_GENS.testnet, read })
  const kindRead = async (a, _b, fn, args) => { assert.equal(fn, 'kindOf'); return lc(a) === PAD ? world.kinds[lc(args[0])] ?? 0 : 0 }
  for (const [tok, k] of [[GS, 'gangswap'], [K1, 'v3'], [K2, 'fair'], [K3, 'fly'], [lc(t(0x999)), 'none']]) {
    assert.equal(await kindOf(rctx(kindRead), tok), k)
    assert.equal((await genOf(rctx(kindRead), tok)).kind, k)
  }
  assert.equal((await genOf(rctx(kindRead), GS)).g.gen, '3.0')
  assert.equal(await kindOf(rctx(async () => 5), GS), null, 'an unknown later kind')
  assert.deepEqual(await Promise.all(['v3', 'fair'].map(async (w) => (await notThisKind(rctx(kindRead), GS, w)).kind)), ['gangswap', 'gangswap'])
  assert.match((await notThisKind(rctx(kindRead), GS, 'fair')).error, /GangSwap curve token, not a 打新 sale/)
  // verbs through the CLI: its own kind, never legacy, never an RPC error; the wrong verbs say why
  for (const [args, re] of [
    [['mint', '--token', GS, '--shares', '1'], /does not apply to a GangSwap curve token/], [['withdraw', '--token', GS, '--all'], /does not apply to a GangSwap curve token/],
    [['claim', '--token', GS], /does not apply to a GangSwap curve token/], [['release', '--token', GS], /does not apply to a GangSwap curve token/],
    [['v3', 'claim', '--token', GS], /untaxed: it pays no dividend/], [['v3', 'release', '--token', GS], /untaxed: it has no tax recipient/],
    [['buy', '--token', GS, '--amount', '1', '--promoter', OTHER], /--promoter is for V3 curve tokens/], [['promote', 'buy', '--token', GS, '--amount', '1', '--promoter', OTHER], /--promoter is for V3 curve tokens/],
    [['v3', 'buy', '--token', GS, '--amount', '1', '--promoter', OTHER], /takes no promoter share/],
    [['buy', '--token', GS, '--amount', '1', '--cd-uncounted'], /--cd-uncounted applies to gang buy of a graduated V3 token/],
    [['fair', 'info', '--token', GS], /GangSwap curve token, not a 打新 sale/], [['fair', 'buy', '--token', GS, '--amount', '1'], /GangSwap curve token/], [['fly', 'info', '--token', GS], /not a 铸币飞轮/],
    [['quote', '--token', GS, '--amount', '1'], /gang buy simulates the trade/],
    [['bond', 'post', '--token', GS, '--hold', '1', '--days', '7', '--amount', '1'], /takes no GangBond/], [['bond', 'status', '--token', GS], /takes no GangBond/],
    [['call-bond', 'post', '--token', GS, '--amount', '1', '--for', '48h'], /takes no call bond/],
    [['buyback', 'status', '--token', GS], /takes no buy-back splitter/], [['split', 'status', '--token', GS], /takes no split module/], [['lp', 'status', '--token', GS], /takes no LP splitter/],
    [['combo', 'status', '--token', GS], /takes no combined recipient/], [['capped', 'status', '--token', GS], /takes no capped recipient/], [['floor', 'status', '--token', GS], /takes no floor module/],
    [['base', 'status', '--token', GS], /takes no opening base/], [['grad-reward', 'status', '--token', GS], /this token has no graduation reward/], [['countdown', 'status', '--token', GS], /takes no countdown reward/],
    [['promote', 'status', '--token', GS], /takes no promoter share/],
  ]) {
    const o = await cli([...args, '--testnet', '--calldata', '--from', ME])
    assert.equal(o.success, false, args.join(' '))
    assert.match(o.error, re, `${args.join(' ')} → ${o.error}`)
    if (args[0] !== 'quote') assert.doesNotMatch(o.error, /RPC error|V2 \/ Soft/, args.join(' '))
    if (!['fly', 'quote', 'v3'].includes(args[0])) assert.equal(o.kind, 'gangswap', args.join(' '))
  }
  // poolTrade itself refuses it (a caller that forgets)
  assert.match((await poolTrade({ chainId: '97', router: ROUTER }, { side: 'buy', token: GS, me: ME, amount: '1', base: { kind: 'gangswap' } }, {})).error, /never trades through GangRouter/)

  // ---------------------------------------------------------------- on the curve: as kind 1
  for (const token of [GS, K1]) {
    world = fresh()
    r = await run('buy', { token, amount: '0.1' })
    assert.equal(r.success, true, JSON.stringify(r))
    assert.deepEqual([lc(r.tx.to), decodeFunctionData({ abi: ROUTER_ABI, data: r.tx.data }).functionName, r.via], [GANG_ROUTER, 'v3BuyBNB', 'router'])
    assert.equal(r.graduationVenue, token === GS ? 'gangswap' : undefined)
    assert.equal(r.kind, token === GS ? 'gangswap' : undefined)
    world = { ...fresh(), wbnbAllow: maxUint256, tokenAllow: maxUint256 }
    r = await run('buy', { token, amount: '0.1', 'use-wbnb': true })
    assert.deepEqual([lc(r.tx.to), decodeFunctionData({ abi: V3_EVENT_ABIS[0], data: r.tx.data }).functionName], [PAD, 'buy'])
    r = await run('sell', { token, all: true, 'break-bond': true, 'break-call-bond': true })
    assert.deepEqual([lc(r.tx.to), decodeFunctionData({ abi: V3_EVENT_ABIS[0], data: r.tx.data }).functionName], [PAD, 'sell'])
  }
  world = { ...fresh(), agents: new Set() }
  await refused(run('buy', { amount: '0.1' }), /no Agent ID/)
  world = { ...fresh(), agents: new Set(), openAt: NOW - 5, wbnbAllow: maxUint256 }
  r = await run('buy', { amount: '0.1', 'use-wbnb': true })
  assert.deepEqual([r.agentWindow.open, r.agentWindow.walletCap], [true, false])
  world = fresh()
  r = await run('info')
  assert.deepEqual([r.kind, r.venue, r.tradesOn, r.graduated, r.gangSwap.graduatesTo], ['gangswap', 'gangswap', 'curve', false, 'GangSwap'])
  assert.match(r.graduationNote, /graduates into GangSwap/)
  assert.match(r.gangSwap.warning, /PancakeSwap pool of it was made by someone else/)
  assert.equal(r.creatorFee.pool.claimable, '0')
  r = await run('status')
  assert.deepEqual([r.kind, r.venue, r.tradesOn], ['gangswap', 'gangswap', 'curve'])
  // through the CLI: kind on the result
  assert.deepEqual(await cli(['info', '--token', GS, '--testnet']).then((x) => [x.success, x.kind]), [true, 'gangswap'])
  // the curve graduated between the read and the simulation: the hint names GangSwap
  world = { ...fresh(), wbnbAllow: maxUint256 }
  const real = run('buy', { amount: '0.1', 'use-wbnb': true }, { follow: async () => { world.graduated = true; return null } })
  r = await real
  assert.deepEqual([r.error, /trade it on GangSwap/.test(r.hint)], ['AlreadyGraduated', true])

  // kind 1 info / status: no GangSwap field
  world = fresh()
  for (const sub of ['info', 'status']) {
    r = await run(sub, { token: K1 })
    for (const k of ['kind', 'venue', 'tradesOn', 'gangSwap']) assert.equal(r[k], undefined, `${sub} ${k}`)
    assert.equal(r.creatorFee?.pool, undefined)
  }
  assert.ok(!world.calls.some(([, fn]) => fn === 'gangSwapMigrator'))

  // ---------------------------------------------------------------- graduated
  const grad = (o = {}) => { world = { ...fresh(), graduated: true, ...o }; return world }
  // no router: actionable, nothing else used
  grad()
  for (const [sub, f] of [['buy', { amount: '0.1' }], ['sell', { all: true }]]) {
    r = await run(sub, f)
    assert.equal(r.success, false)
    assert.match(r.error, /no GangSwapRouter address.*no other router is used/)
    assert.match(r.hint, /update the CLI/)
    assert.doesNotMatch(r.hint, /SWAP_ROUTER/, 'no hint invites an address')
    assert.equal(r.tx, undefined)
  }
  neverPancake('no router')

  await withRouter(async () => {
    // --- buy, native BNB (both token orders)
    for (const quoteIs0 of [false, true]) {
      grad({ quoteIs0 })
      r = await run('buy', { amount: '0.1', slippage: '2' })
      assert.equal(r.success, true, JSON.stringify(r))
      assert.deepEqual([r.step, r.venue, r.via, r.kind, lc(r.tx.to), r.tx.value], ['pool-buy', 'gangswap', 'gangswap-router', 'gangswap', ROUTER, parseUnits('0.1', 18).toString()])
      d = decodeFunctionData({ abi: G.GANGSWAP_ROUTER_ABI, data: r.tx.data })
      const out = G.amountOut(E18 / 10n, 6n * E18, 200_000_000n * E18)
      assert.equal(d.functionName, 'swapExactETHForTokens')
      assert.equal(d.args[0], (out * 9800n) / 10000n, 'minOut: effective reserves, 1% fee, 2% slippage')
      assert.deepEqual([d.args[1].map(lc), lc(d.args[2])], [[WBNB, GS], lc(ME)])
      const left = Number(d.args[3]) - Math.floor(Date.now() / 1000)
      assert.ok(left > 1700 && left <= 1800, 'the deadline of every pool trade')
      assert.equal(r.tx.gas, '300000', '1.5 × the estimate, at least the floor')
      assert.equal(r.warning, undefined)
      neverPancake('buy')
    }
    grad({ gas: 400_000n })
    assert.equal((await run('buy', { amount: '0.1' })).tx.gas, '600000')
    // the 0.002 BNB gas reserve
    grad({ native: E18 / 10n + 1_999_999_999_999_999n })
    r = await run('buy', { amount: '0.1' })
    assert.deepEqual([r.success, /not enough BNB/.test(r.error), r.tx], [false, true, undefined])
    grad({ native: E18 / 10n + 2_000_000_000_000_000n })
    assert.equal((await run('buy', { amount: '0.1' })).success, true)
    // --use-wbnb / --use-quote: exact approval to GangSwapRouter, then the token swap
    for (const f of ['use-wbnb', 'use-quote']) {
      grad()
      r = await run('buy', { amount: '0.1', [f]: true })
      assert.deepEqual(r.steps.map((s) => s.step), ['approve-quote', 'pool-buy'])
      const a = decodeFunctionData({ abi: ERC20, data: r.steps[0].tx.data })
      assert.deepEqual([lc(r.steps[0].tx.to), a.functionName, lc(a.args[0]), a.args[1]], [WBNB, 'approve', ROUTER, E18 / 10n])
      const b = decodeFunctionData({ abi: G.GANGSWAP_ROUTER_ABI, data: r.steps[1].tx.data })
      assert.deepEqual([lc(r.steps[1].tx.to), b.functionName, b.args[0], r.steps[1].tx.value, r.steps[1].tx.gas], [ROUTER, 'swapExactTokensForTokens', E18 / 10n, '0', '300000'])
    }
    grad({ wbnb: E18 / 20n })
    r = await run('buy', { amount: '0.1', 'use-wbnb': true })
    assert.deepEqual(r.steps.map((s) => s.step), ['wrap-bnb', 'approve-quote', 'pool-buy'])
    assert.equal(r.steps[0].tx.value, (E18 / 20n).toString())
    grad({ wbnbAllow: E18 / 10n })
    r = await run('buy', { amount: '0.1', 'use-wbnb': true })
    assert.deepEqual([r.steps, decodeFunctionData({ abi: G.GANGSWAP_ROUTER_ABI, data: r.tx.data }).functionName], [undefined, 'swapExactTokensForTokens'])
    // large against the REAL liquidity: warned; the price impact is on the effective one
    grad({ real: E18 })
    r = await run('buy', { amount: '0.1' })
    assert.match(r.warning, /real liquidity \(1 BNB\)/)
    assert.equal(r.pctOfRealLiquidity, 10)
    assert.ok(Math.abs(r.priceImpactPct - (0.099 / 6.099) * 100) < 0.001, String(r.priceImpactPct))
    grad({ real: E18 })
    assert.equal((await run('buy', { amount: '0.099' })).warning, undefined)
    grad({ real: 0n })
    assert.match((await run('buy', { amount: '0.001' })).warning, /the pool holds no real BNB now/)
    // the amount the tx carries is the one shown
    grad()
    r = await run('buy', { amount: '0.1000000000000000009' })
    assert.deepEqual([parseUnits(r.spend, 18).toString(), r.spend], [r.tx.value, '0.100000000000000001'])

    // --- sell: exact approval, WBNB by default, --to-bnb BNB
    const amt = 1_000n * E18
    const want = G.amountOut(amt, 200_000_000n * E18, 6n * E18)
    for (const [f, fn] of [[{}, 'swapExactTokensForTokens'], [{ 'to-bnb': true }, 'swapExactTokensForETH']]) {
      grad()
      r = await run('sell', { amount: '1000', slippage: '1', ...f })
      assert.deepEqual(r.steps.map((s) => s.step), ['approve', 'pool-sell'])
      const a = decodeFunctionData({ abi: ERC20, data: r.steps[0].tx.data })
      assert.deepEqual([lc(r.steps[0].tx.to), lc(a.args[0]), a.args[1]], [GS, ROUTER, amt], 'this amount only')
      d = decodeFunctionData({ abi: G.GANGSWAP_ROUTER_ABI, data: r.steps[1].tx.data })
      assert.deepEqual([d.functionName, d.args[0], d.args[1], d.args[2].map(lc), lc(d.args[3])], [fn, amt, (want * 9900n) / 10000n, [GS, WBNB], lc(ME)])
      neverPancake('sell')
      grad({ tokenAllow: amt })
      r = await run('sell', { amount: '1000', ...f })
      assert.deepEqual([r.steps, r.step, lc(r.tx.to), r.receive], [undefined, 'pool-sell', ROUTER, f['to-bnb'] ? 'BNB' : 'WBNB'])
    }
    grad({ tokenAllow: maxUint256 })
    r = await run('sell', { all: true })
    assert.equal(decodeFunctionData({ abi: G.GANGSWAP_ROUTER_ABI, data: r.tx.data }).args[0], world.tokenBal)
    grad({ tokenAllow: maxUint256 })
    r = await run('sell', { amount: '9000000' })
    assert.equal(r.error, 'amount exceeds balance')
    grad({ tokenBal: 0n })
    assert.equal((await run('sell', { all: true })).error, 'no balance to sell')
    // a sell priced over what the pool can pay: nothing built
    grad({ real: 1000n, tokenAllow: maxUint256 })
    r = await run('sell', { amount: '1000' })
    assert.match(r.error, /more than the pool's real liquidity/)
    assert.equal(r.tx, undefined)
    grad({ real: (want * 10n) - 1n, tokenAllow: maxUint256 })
    assert.match((await run('sell', { amount: '1000' })).warning, /large against/)
    // no wallet: a quote only, from the pair
    grad()
    {
      const o = await cli(['sell', '--token', GS, '--amount', '1000', '--testnet'], ON)
      assert.match(o.error, /pass --from/)
      assert.equal(o.poolQuote.expectOut, Number(o.poolQuote.expectOut) ? o.poolQuote.expectOut : null)
      assert.match(o.hint, /GangSwap only/)
      neverPancake('quote')
    }

    // --- a reverted simulation: no tx; the reason named
    grad({ swapRevert: reason('GangSwapRouter: INSUFFICIENT_OUTPUT_AMOUNT') })
    r = await run('buy', { amount: '0.1' })
    assert.deepEqual([r.success, r.reverted, r.tx, r.doNotSend, /INSUFFICIENT_OUTPUT_AMOUNT/.test(r.error), /slippage/.test(r.hint)], [false, true, undefined, true, true, true])
    // a simulation that does not answer as a swap paying the minimum: no tx
    const ans = (xs) => encodeAbiParameters([{ type: 'uint256[]' }], [xs])
    const floorOut = (G.amountOut(E18 / 10n, 6n * E18, 200_000_000n * E18) * 9900n) / 10000n
    for (const [swapData, re] of [['0x', /did not answer as a GangSwapRouter swap/], [`0x${'00'.repeat(31)}01`, /did not answer/], [ans([]), /did not answer/], [ans([1n, 2n, floorOut]), /did not answer/], [ans([E18 / 10n, floorOut - 1n]), /less than the minimum/]]) {
      grad({ swapData })
      r = await run('buy', { amount: '0.1' })
      assert.deepEqual([r.success, r.tx, r.doNotSend], [false, undefined, true])
      assert.match(r.error, re)
    }
    grad({ swapData: ans([E18 / 10n, floorOut]) })
    assert.equal((await run('buy', { amount: '0.1' })).success, true)
    grad({ swapRevert: rpcDown })
    r = await run('buy', { amount: '0.1' })
    assert.deepEqual([r.success, r.tx, /RPC error while simulating/.test(r.error)], [false, undefined, true])

    // --- every router check: refused with no tx, and nothing else asked to trade
    const BAD = [
      [{ routerCode: '0x' }, /no contract at it/], [{ routerFactory: lc(t(0xbad)) }, /its factory\(\) is/], [{ routerFactory: null }, /factory\(\) is not readable/], [{ routerWeth: lc(t(0xbad)) }, /its WETH\(\)/],
      [{ routerCode: codeOf(0) }, /hash 0 times/], [{ routerCode: codeOf(2) }, /hash 2 times/],
      ...Object.values(FORGED).map((routerCode) => [{ routerCode }, /not this token's GangSwapRouter/]), [{ routerCode: codeOf(1) }, /not a GangSwapRouter build/], [{ routerCode: FORGED['one operand swapped'] }, /not where the GangSwapRouter build has them/], [{ hash: `0x${'ee'.repeat(32)}` }, /hash 0 times/],
      [{ listedPair: lc(t(0xbad)) }, /is not the pair the pad recorded/], [{ listedPair: zeroAddress }, /is not the pair the pad recorded/],
      [{ migratorOf: {} }, /GangSwap version is not set \(gangSwapMigratorOf is 0\)/], [{ hasOf: false }, /GangSwap version is not readable.*not supported/], [{ down: new Set(['gangSwapMigratorOf']) }, /RPC error while reading this token's GangSwap version/],
      [{ down: new Set(['factory']) }, /RPC error/], [{ down: new Set(['getPair']) }, /RPC error/], [{ down: new Set(['getCode']) }, /RPC error/], [{ down: new Set(['realQuoteReserve']) }, /RPC error/], [{ down: new Set(['INIT_CODE_PAIR_HASH']) }, /RPC error/],
    ]
    for (const [set, re] of BAD) {
      for (const [sub, f] of [['buy', { amount: '0.1' }], ['buy', { amount: '0.1', 'use-wbnb': true }], ['sell', { all: true }]]) {
        grad(set)
        r = await run(sub, f)
        assert.equal(r.success, false, `${JSON.stringify(Object.keys(set))} ${sub}`)
        assert.match(r.error, re)
        assert.deepEqual([r.tx, r.steps, r.venue, r.step], [undefined, undefined, 'gangswap', `pool-${sub}`])
        assert.ok(!world.calls.some(([, fn]) => fn.startsWith('swap')), 'never simulated')
        neverPancake(sub)
      }
    }
    // one command reads the network facts once
    grad({ tokenAllow: maxUint256 })
    await run('sell', { all: true })
    // the caches are per pad and per router: another one is read again
    {
      grad()
      const c = { chainId: '97', pad: PAD, wbnb: WBNB, client: { getCode: async () => { seen.push('code'); return world.routerCode } }, read: async (a, _b, fn) => { seen.push(`${fn}@${lc(a)}`); return { gangSwapMigratorOf: MIGRATOR, factory: lc(a) === ROUTER ? FACTORY : FACTORY, boost: BOOST, fees: FEES, WETH: WBNB, INIT_CODE_PAIR_HASH: HASH, getPair: PAIR }[fn] } }
      const seen = []
      await G.checkRouter(c, GS, PAIR); await G.checkRouter(c, GS, PAIR)
      assert.deepEqual([seen.filter((x) => x === 'code').length, seen.filter((x) => x.startsWith('gangSwapMigratorOf')).length], [1, 1])
      process.env.GANG_TESTNET_SWAP_ROUTER = lc(t(0x5aa))
      world.routerCode = codeOf(1)
      await assert.rejects(G.checkRouter(c, GS, PAIR), /not this token's GangSwapRouter/, 'another router is never vouched for by the first')
      process.env.GANG_TESTNET_SWAP_ROUTER = ROUTER
      world.routerCode = deployed()
      c.pad = lc(t(0xaad))
      await G.checkRouter(c, GS, PAIR)
      assert.ok(seen.includes(`gangSwapMigratorOf@${lc(t(0xaad))}`), 'another pad names its own migrator')
      // a failed read is not kept
      const c2 = { ...c, _gangSwap: undefined, _gangSwapRouter: undefined, read: async () => { throw new Error('down') } }
      await assert.rejects(G.gangSwapSet(c2, GS), /RPC error/)
      c2.read = c.read
      assert.equal((await G.gangSwapSet(c2, GS)).fees, FEES)
    }
    grad({ tokenAllow: maxUint256 })
    await run('sell', { all: true })
    assert.ok(!world.calls.some((c) => c[1] === 'gangSwapMigrator'), 'the version new tokens get is never asked for an existing one')
    for (const fn of ['gangSwapMigratorOf', 'INIT_CODE_PAIR_HASH', 'WETH', 'getPair']) assert.equal(world.calls.filter((c) => c[1] === fn).length, 1, fn)

    // --- follow / promoter / cd-uncounted / notes after graduation
    grad()
    await refused(run('buy', { amount: '0.1' }, { following: true }), /trades on GangSwap now/)
    await refused(run('buy', { amount: '0.1', promoter: OTHER }), /takes no promoter share/)
    await refused(run('buy', { amount: '0.1', 'cd-uncounted': true }), /takes no countdown reward/)
    r = await run('buy', { amount: '0.1' }, { pool: { agentNote: { attached: false, reason: 'notes are matched to curve trades only: this PancakeSwap trade carries none' } } })
    assert.match(r.agentNote.reason, /this GangSwap trade carries none/)
    // raw calldata carries no tag after the router's own call
    assert.equal(r.tx.data.length, 2 + 8 + 64 * (4 + 3))

    // --- info / status
    grad({ openAt: NOW - 5 })
    r = await run('info')
    assert.deepEqual([r.venue, r.tradesOn, lc(r.pair), lc(r.gangSwap.pair), r.gangSwap.router, lc(r.gangSwap.routerFromEnv), r.gangSwap.routerVerified], ['gangswap', 'gangswap', PAIR, PAIR, null, ROUTER, false])
    assert.match(r.gangSwap.routerNote, /not verified here/)
    assert.deepEqual([r.gangSwap.liquidity.effectiveBnb, r.gangSwap.liquidity.realBnb, r.gangSwap.liquidity.virtualBnb], ['6', '4.8', '1.2'])
    assert.deepEqual([r.gangSwap.buyBack.totalBnb, r.gangSwap.buyBack.spentBnb, r.gangSwap.buyBack.leftBnb, r.gangSwap.buyBack.stepsDoneApprox, r.gangSwap.buyBack.stepsLeftApprox, r.gangSwap.buyBack.finished], ['1.2', '0.3', '0.9', 10, 30, false])
    assert.match(r.gangSwap.warning, /PancakeSwap pool/)
    assert.match(r.agentWindow.status, /the GangSwap pool is open/)
    assert.equal(r.priceFrom, 'pool')
    assert.equal(r.priceQuote, '0.00000003')
    const poolFee = (1_000_000_007n * 7000n) / 10000n
    assert.equal(r.creatorFee.pool.claimableRaw, poolFee.toString())
    assert.equal(r.swapBack, undefined)
    neverPancake('info')
    grad({ boost: [PAIR, 5n, false, 12n * E18 / 10n, 0n] })
    r = await run('info')
    assert.deepEqual([r.gangSwap.buyBack.finished, r.gangSwap.buyBack.stepsLeftApprox, r.gangSwap.buyBack.stepsDoneApprox], [true, undefined, 40])
    grad({ down: new Set(['boosts']) })
    r = await run('info')
    assert.equal(r.success, true)
    assert.match(r.gangSwap.error, /could not read the GangSwap pool/)
    grad()
    r = await run('status')
    const all = G.amountOut(world.tokenBal, world.rt, world.rq)
    assert.equal(parseUnits(r.poolSellAll.expectOut, 18), all)
    assert.equal(parseUnits(r.poolSellAll.minOut, 18), (all * 9900n) / 10000n)
    assert.match(r.poolSellAll.hint, /GangSwapRouter/)
    assert.equal(r.creatorFee.pool.claimableRaw, poolFee.toString())
    neverPancake('status')
    r = await run('status', { from: OTHER })
    assert.equal(r.creatorFee, undefined)
  })
  // status needs no router (it only reads)
  grad()
  assert.ok((await run('status')).poolSellAll)

  // --- the env override goes through the same checks; a bad address is refused
  for (const bad of ['nope', PANCAKE[0], GANG_ROUTER]) {
    grad()
    process.env.GANG_TESTNET_SWAP_ROUTER = bad
    r = await run('buy', { amount: '0.1' })
    assert.equal(r.success, false, bad)
    assert.match(r.error, /is not this token's GangSwapRouter/)
    assert.equal(r.tx, undefined)
    if (bad === 'nope') assert.match(r.error, /not a 0x address/)
    assert.match(r.hint, /^unset GANG_TESTNET_SWAP_ROUTER \(a development setting\), then update the CLI/)
  }
  delete process.env.GANG_TESTNET_SWAP_ROUTER
  process.env.GANG_SWAP_ROUTER = ROUTER // mainnet's: never read on testnet
  grad()
  assert.match((await run('buy', { amount: '0.1' })).error, /no GangSwapRouter address/)
  delete process.env.GANG_SWAP_ROUTER
  assert.deepEqual([G.gangSwapRouterAddresses(true), G.gangSwapRouterAddresses(false)], [[], []])
  {
    G.GANGSWAP_VERSIONS.testnet.push({ router: ROUTER, codeHash: G.GANGSWAP_ROUTER_CODE_HASH, sites: G.GANGSWAP_ROUTER_SITES })
    grad()
    assert.equal((await run('buy', { amount: '0.1' })).success, true, 'a pinned address works the same')
    grad({ routerCode: codeOf(0) })
    r = await run('buy', { amount: '0.1' })
    assert.equal(r.success, false, 'and is verified the same')
    assert.match(r.hint, /^update the CLI/)
    G.GANGSWAP_VERSIONS.testnet.length = 0
  }
  // through the CLI end to end: --from / --calldata
  grad()
  {
    const o = await cli(['buy', '--token', GS, '--amount', '0.1', '--testnet', '--calldata', '--from', ME], ON)
    assert.deepEqual([o.success, o.kind, o.step, lc(o.tx?.to)], [true, 'gangswap', 'pool-buy', ROUTER], JSON.stringify(o))
    neverPancake('cli buy')
  }
  // an unreadable kind is an error, never legacy or a trade
  grad({ down: new Set(['kindOf']) })
  for (const c of ['buy', 'v3 buy']) {
    const o = await cli([...c.split(' '), '--token', GS, '--amount', '0.1', '--testnet', '--calldata', '--from', ME], ON)
    assert.equal(o.success, false)
    assert.match(o.error, /kindOf; RPC error/)
  }

  // ---------------------------------------------------------------- the wallet (a fake baw): preview, then execute
  {
    const dir = mkdtempSync(join(tmpdir(), 'gang-gangswap-'))
    const log = join(dir, 'log')
    writeFileSync(join(dir, 'baw'), `#!/bin/sh
echo "$@" >> "${log}"
case "$1 $2" in
  "contract-call preview") echo '{"success":true,"data":{"requestId":"req-1","expiresAt":1,"requireConfirmation":false,"risks":{"riskDetails":[]},"simulationResult":{"balanceChanges":[]}}}';;
  "contract-call execute") echo '{"success":true,"data":{"status":"SUCCESS","txHash":"0x${'ab'.repeat(32)}","orderId":"1"}}';;
  "wallet status") echo '{"success":true,"data":{"status":"CONNECTED"}}';;
  "wallet address") echo '{"success":true,"data":{"addresses":[{"binanceChainId":"56","address":"${ME}"},{"binanceChainId":"97","address":"${ME}"}]}}';;
  *) exit 1;;
esac
`)
    chmodSync(join(dir, 'baw'), 0o755)
    const W = { ...ON, PATH: `${dir}:/usr/bin:/bin`, GANG_NOTES_DIR: join(dir, 'notes') }
    grad()
    let w = await cli(['buy', '--token', GS, '--amount', '0.1', '--testnet'], W)
    assert.deepEqual([w.success, w.requestId, w.next, w.step, w.venue, w.kind], [true, 'req-1', 'gang execute --request-id req-1', 'pool-buy', 'gangswap', 'gangswap'], JSON.stringify(w))
    const line = readFileSync(log, 'utf8').split('\n').find((x) => x.startsWith('contract-call preview'))
    assert.match(line, new RegExp(`--binanceChainId 97 --from ${ME} --to ${ROUTER} --value 100000000000000000 --inputData 0x7ff36ab5[0-9a-f]+ --gasLimit 300000`, 'i'))
    w = await cli(['execute', '--request-id', 'req-1'], W)
    assert.deepEqual([w.success, w.txHash, w.agentNote], [true, `0x${'ab'.repeat(32)}`, undefined], 'a pool trade is not asked for a note')
    // an approve comes first, for this amount, to the router; then the sell
    grad()
    w = await cli(['sell', '--token', GS, '--amount', '1000', '--testnet'], W)
    assert.deepEqual([w.step, w.next, lc(w.spender), w.approve, w.venue], ['approve', 'gang execute --request-id req-1', ROUTER, '1000', 'gangswap'], JSON.stringify(w))
    grad({ tokenAllow: 1000n * E18 })
    w = await cli(['sell', '--token', GS, '--amount', '1000', '--testnet', '--to-bnb'], W)
    assert.deepEqual([w.step, w.function], ['pool-sell', 'swapExactTokensForETH'])
    // a refused router asks the wallet for nothing but its address
    writeFileSync(log, '')
    grad({ routerCode: codeOf(0) })
    w = await cli(['buy', '--token', GS, '--amount', '0.1', '--testnet'], W)
    assert.equal(w.success, false)
    assert.doesNotMatch(readFileSync(log, 'utf8'), /contract-call/)
    rmSync(dir, { recursive: true, force: true })
  }

  // ---------------------------------------------------------------- gang follow: a curve buy with the follow ref
  {
    const noteTx = `0x${'cd'.repeat(32)}`
    const api = createServer((q, s) => { s.writeHead(200, { 'content-type': 'application/json' }); s.end(JSON.stringify(q.url.includes('/followable') ? { ok: true, token: GS, expiresAt: NOW, blind: false } : { error: 'x' })) })
    await new Promise((res) => api.listen(0, '127.0.0.1', res))
    const F = { GANG_API: `http://127.0.0.1:${api.address().port}/api`, GANG_PAD: PAD, GANG_RPC_URL: rpc }
    world = { ...fresh(), wbnbAllow: maxUint256 }
    let w = await cli(['follow', noteTx, '--amount', '0.1', '--calldata', '--from', ME], F)
    assert.deepEqual([w.success, w.step, w.kind, lc(w.tx?.to), w.tx?.data.endsWith('cd'.repeat(32)), w.follow?.attached], [true, 'buy', 'gangswap', PAD, true, true], JSON.stringify(w))
    grad()
    w = await cli(['follow', noteTx, '--amount', '0.1', '--calldata', '--from', ME], F)
    assert.match(w.error, /--follow only counts on curve buys.*trades on GangSwap now/)
    api.close()
  }

  // ---------------------------------------------------------------- MCP: the tools run the same code
  {
    grad()
    const child = spawn(process.execPath, [CLI, 'mcp'], { env: env(ON), stdio: ['pipe', 'pipe', 'ignore'] })
    const replies = new Map()
    let buf = ''
    child.stdout.on('data', (x) => { buf += x; for (let i; (i = buf.indexOf('\n')) >= 0; buf = buf.slice(i + 1)) { const m = JSON.parse(buf.slice(0, i)); replies.get(m.id)?.(m) } })
    let id = 0
    const ask = (method, params) => new Promise((res) => { const n = ++id; replies.set(n, res); child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id: n, method, params })}\n`) })
    await ask('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '0' } })
    const use = async (name, args) => JSON.parse((await ask('tools/call', { name, arguments: args })).result.content[0].text)
    let m = await use('gang_info', { token: GS, testnet: true })
    assert.deepEqual([m.kind, m.gangSwap.buyBack.finished], ['gangswap', false])
    m = await use('gang_cli', { args: ['buy', '--token', GS, '--amount', '0.1', '--testnet', '--calldata', '--from', ME] })
    assert.deepEqual([m.kind, lc(m.tx.to)], ['gangswap', ROUTER])
    m = await use('gang_cli', { args: ['create', '--venue', 'gangswap', '--name', 'G', '--symbol', 'G', '--testnet', '--vault', OTHER] })
    assert.match(m.error, /--vault can't go with --venue gangswap/)
    child.stdin.end()
    child.kill()
  }

  // ---------------------------------------------------------------- versions
  {
    const V1 = { router: ROUTER, codeHash: G.GANGSWAP_ROUTER_CODE_HASH, sites: G.GANGSWAP_ROUTER_SITES }, V2 = { ...V1, router: ROUTER2 }
    const L = G.GANGSWAP_VERSIONS.testnet
    const set = (...v) => { L.length = 0; L.push(...v) }
    const toOf = async (token, side = 'buy') => { const x = await run(side, { token, ...(side === 'buy' ? { amount: '0.1' } : { amount: '1000' }) }); return x.success ? lc((x.steps?.at(-1) ?? x).tx.to) : x }
    // both at once: each token on its own router, whatever new tokens get now (v1, v2, or nothing: creation closed)
    for (const order of [[V1, V2], [V2, V1]]) {
      for (const migrator of [MIGRATOR, MIGRATOR2, zeroAddress]) {
        for (const side of ['buy', 'sell']) {
          set(...order)
          grad({ migrator })
          assert.equal(await toOf(GS, side), ROUTER, `${side} v1, current ${migrator}`)
          grad({ migrator })
          assert.equal(await toOf(GS2, side), ROUTER2, `${side} v2, current ${migrator}`)
          assert.ok(!world.calls.some(([at, fn]) => fn === 'gangSwapMigrator' || at === ROUTER && fn.startsWith('swap')), 'v2 never asks the current version nor swaps on v1')
          neverPancake('versions')
        }
      }
    }
    // the quote and approval are the token's own pair and router
    grad()
    r = await run('sell', { token: GS2, amount: '1000' })
    assert.deepEqual([lc(r.pair), lc(r.router), lc(decodeFunctionData({ abi: ERC20, data: r.steps[0].tx.data }).args[0]), parseUnits(r.expectOut, 18)], [PAIR2, ROUTER2, ROUTER2, G.amountOut(1000n * E18, 100_000_000n * E18, 9n * E18)])
    // only one version known: the other's token is refused, both ways, with no tx
    for (const [known, token] of [[V1, GS2], [V2, GS]]) {
      set(known)
      for (const side of ['buy', 'sell']) {
        grad()
        const x = await run(side, { token, amount: '1' })
        assert.deepEqual([x.success, x.tx, x.steps], [false, undefined, undefined])
        assert.match(x.error, /another version's router/)
        assert.match(x.hint, /^update the CLI/)
      }
    }
    // several known, none of the token's version
    set(V1, { ...V1, router: lc(t(0x5c9)) })
    grad()
    let x = await run('buy', { token: GS2, amount: '1' })
    assert.match(x.error, /knows no GangSwapRouter of this token's GangSwap version/)
    assert.match(x.hint, /^update the CLI/)
    assert.equal(lc(x.migrator), MIGRATOR2)
    assert.ok(!world.calls.some(([, fn]) => fn.startsWith('swap')))
    // the env: one router, or a comma list, beside the pinned ones; each serves its own version's tokens only
    const env2 = async (list, v, want1, want2) => {
      set(...v)
      process.env.GANG_TESTNET_SWAP_ROUTER = list
      for (const [token, want] of [[GS, want1], [GS2, want2]]) {
        for (const side of ['buy', 'sell']) {
          grad()
          const y = await toOf(token, side)
          if (want) { assert.equal(y, want, `${side} ${token} env ${list}: ${JSON.stringify(y)}`); continue }
          assert.deepEqual([y.success, y.tx, y.steps], [false, undefined, undefined])
          assert.match(y.error, /another version's router|knows no GangSwapRouter of this token's GangSwap version/)
        }
      }
      delete process.env.GANG_TESTNET_SWAP_ROUTER
    }
    await env2(ROUTER, [], ROUTER, null)
    await env2(ROUTER2, [], null, ROUTER2)
    await env2(ROUTER2, [V1], ROUTER, ROUTER2)
    await env2(ROUTER, [V2], ROUTER, ROUTER2)
    for (const list of [`${ROUTER},${ROUTER2}`, ` ${ROUTER2} , ${ROUTER},`, `${ROUTER2},${ROUTER},${ROUTER2}`]) await env2(list, [], ROUTER, ROUTER2)
    await env2(`${lc(t(0x5c9))},nope`, [V1], ROUTER, null)
    await env2(`nope,${ROUTER2}`, [V1], ROUTER, ROUTER2)
    await env2(',', [V1, V2], ROUTER, ROUTER2)
    // in the list as alone: the full identity check
    for (const code of Object.values(FORGED)) {
      set(V1)
      process.env.GANG_TESTNET_SWAP_ROUTER = `${lc(t(0x5c9))},${ROUTER2}`
      const asV2 = code.replaceAll(push(FACTORY), push(FACTORY2))
      grad({ router2Code: asV2 })
      x = await run('buy', { token: GS2, amount: '0.1' })
      assert.deepEqual([x.success, x.tx], [false, undefined])
      assert.match(x.error, /is not this token's GangSwapRouter|knows no GangSwapRouter/)
    }
    set(V1)
    grad({ router2Code: codeOf(1) })
    x = await run('buy', { token: GS2, amount: '0.1' })
    assert.match(x.error, /not a GangSwapRouter build/)
    assert.match(x.hint, /^unset GANG_TESTNET_SWAP_ROUTER/)
    grad({ routerCode: codeOf(1) })
    assert.match((await run('buy', { amount: '0.1' })).hint, /^update the CLI/, 'a pinned one that fails is not the env\'s fault')
    // pinned and named again: one entry, held to its own build
    set({ ...V2, codeHash: HASH })
    process.env.GANG_TESTNET_SWAP_ROUTER = ROUTER2.toUpperCase().replace('0X', '0x')
    grad()
    assert.match((await run('buy', { token: GS2, amount: '0.1' })).error, /not a GangSwapRouter build/)
    // info: the pinned one as such, the env's as unverified
    set(V1)
    process.env.GANG_TESTNET_SWAP_ROUTER = `${ROUTER2}`
    grad()
    let vw = (await run('info')).gangSwap
    assert.deepEqual([lc(vw.router), vw.routerFromEnv, vw.routerNote], [ROUTER, undefined, undefined])
    grad()
    vw = (await run('info', { token: GS2 })).gangSwap
    assert.deepEqual([vw.router, lc(vw.routerFromEnv), vw.routerVerified], [null, ROUTER2, false])
    process.env.GANG_TESTNET_SWAP_ROUTER = lc(t(0x5c9))
    grad()
    vw = (await run('info', { token: GS2 })).gangSwap
    assert.deepEqual([vw.router, vw.routerFromEnv, /no GangSwapRouter of this token's/.test(vw.routerNote)], [null, undefined, true])
    delete process.env.GANG_TESTNET_SWAP_ROUTER
    // mainnet: the same rule, added to the pinned ones, never instead of them
    G.GANGSWAP_VERSIONS.mainnet.push({ router: ROUTER, codeHash: G.GANGSWAP_ROUTER_CODE_HASH, sites: G.GANGSWAP_ROUTER_SITES })
    process.env.GANG_SWAP_ROUTER = `${ROUTER2},${ROUTER}`
    assert.deepEqual(G.gangSwapRouterAddresses(false), [ROUTER, ROUTER2])
    delete process.env.GANG_SWAP_ROUTER
    G.GANGSWAP_VERSIONS.mainnet.length = 0
    set(V1, V2)
    process.env.GANG_TESTNET_SWAP_ROUTER = ROUTER2
    grad({ router2Code: codeOf(1) })
    assert.match((await run('buy', { token: GS2, amount: '0.1' })).error, /not a GangSwapRouter build/)
    delete process.env.GANG_TESTNET_SWAP_ROUTER
    // one version's router unreadable: the other's tokens trade on; its own is an RPC error, never "none known"
    grad({ downAt: new Set([ROUTER2]) })
    assert.equal(await toOf(GS), ROUTER)
    grad({ downAt: new Set([ROUTER2]) })
    assert.match((await toOf(GS2)).error, /RPC error while reading the GangSwap router/)
    // a later build: only under its own entry (or the env), never accepted at the earlier version's
    const code2 = `${deployed2()}00`
    const B2 = { router: ROUTER2, codeHash: G.maskedRouter(code2, FACTORY2, WBNB).hash, sites: G.GANGSWAP_ROUTER_SITES }
    set(V1, B2)
    grad({ router2Code: code2 })
    assert.equal(await toOf(GS2), ROUTER2)
    grad({ router2Code: code2, routerCode: `${deployed()}00` })
    assert.match((await toOf(GS)).error, /not a GangSwapRouter build/)
    grad()
    assert.match((await toOf(GS2)).error, /not a GangSwapRouter build/, 'the earlier build at the later entry')
    set(V1, { ...B2, router: lc(t(0x5c9)) })
    process.env.GANG_TESTNET_SWAP_ROUTER = ROUTER2
    grad({ router2Code: code2 })
    assert.equal(await toOf(GS2), ROUTER2, 'the env: any known build')
    delete process.env.GANG_TESTNET_SWAP_ROUTER
    // hash and order of one entry, never mixed across entries
    set({ ...V1, sites: 'F'.repeat(35) }, V2)
    grad()
    assert.match((await toOf(GS)).error, /not where the GangSwapRouter build has them/)
    // two entries of one version: the one that passes
    set({ ...V1, codeHash: HASH }, V1)
    grad()
    assert.equal(await toOf(GS), ROUTER, 'the first fails its own check, the second passes')
    // one ctx, both tokens: nothing of one is used for the other
    set(V1, V2)
    {
      const c = { chainId: '97', pad: PAD, wbnb: WBNB, client: { getCode: async ({ address }) => (lc(address) === ROUTER ? deployed() : deployed2()) }, read: async (a, abi, fn, args = []) => { const f = abi.find((y) => y.name === fn); const q = call({ to: a, data: encodeFunctionData({ abi: [f], functionName: fn, args }), from: ME }); if (q.error) throw new Error('rpc'); return decodeFunctionResult({ abi: [f], functionName: fn, data: q.result }) } }
      grad()
      assert.deepEqual([lc(await G.checkRouter(c, GS, PAIR)), lc(await G.checkRouter(c, GS2, PAIR2)), lc(await G.checkRouter(c, GS, PAIR))], [ROUTER, ROUTER2, ROUTER])
      assert.deepEqual([lc((await G.gangSwapSet(c, GS)).fees), lc((await G.gangSwapSet(c, GS2)).fees)], [FEES, FEES2])
      const third = lc(t(0x9c5))
      world.migratorOf[third] = MIGRATOR
      world.calls = []
      assert.equal(lc((await G.gangSwapSet(c, third)).fees), FEES)
      assert.deepEqual(world.calls.map((y) => y[1]), ['gangSwapMigratorOf'], 'the version of a third token, its set already read')
      await assert.rejects(G.checkRouter(c, GS2, PAIR), /is not the pair the pad recorded/)
      // with one version known, its router vouched for by the first token is still not the second's
      set(V1)
      assert.equal(lc(await G.checkRouter(c, GS, PAIR)), ROUTER)
      await assert.rejects(G.checkRouter(c, GS2, PAIR2), /another version's router/)
      set(V1, V2)
    }
    // one known version costs no factory read twice, and no other router's
    set(V1)
    grad()
    await run('buy', { amount: '0.1' })
    for (const fn of ['gangSwapMigratorOf', 'WETH', 'INIT_CODE_PAIR_HASH', 'getPair']) assert.equal(world.calls.filter((y) => y[1] === fn).length, 1, fn)
    assert.equal(world.calls.filter(([at, fn]) => at === ROUTER && fn === 'factory').length, 1)
    // info / status: each its own pool, boost, fees and router; the version shown on the curve too
    set(V1, V2)
    for (const [token, m, pr, rt, fe, total] of [[GS, MIGRATOR, PAIR, ROUTER, FEES, '1.2'], [GS2, MIGRATOR2, PAIR2, ROUTER2, FEES2, '2']]) {
      for (const sub of ['info', 'status']) {
        grad({ migrator: zeroAddress })
        const y = await run(sub, { token })
        assert.deepEqual([lc(y.gangSwap.migrator), lc(y.gangSwap.pair), lc(y.gangSwap.router), lc(y.gangSwap.fees), y.gangSwap.buyBack.totalBnb, lc(y.creatorFee.pool.contract)], [m, pr, rt, fe, total, fe], `${sub} ${token}`)
      }
      world = { ...fresh(), migrator: zeroAddress }
      assert.equal(lc((await run('info', { token })).gangSwap.migrator), m)
    }
    set(V1)
    grad()
    const y = await run('info', { token: GS2 })
    assert.deepEqual([y.success, y.gangSwap.router, /no GangSwapRouter of this token's GangSwap version/.test(y.gangSwap.routerNote)], [true, null, true])
    // a router that can't be read leaves the pool's numbers as they are
    for (const v of [[V1], [V1, V2]]) {
      for (const sub of ['info', 'status']) {
        set(...v)
        grad({ downAt: new Set([ROUTER]) })
        const z = (await run(sub)).gangSwap
        assert.deepEqual([z.error, z.router, z.liquidity?.realBnb, z.buyBack?.totalBnb, z.routerNote], [undefined, null, '4.8', '1.2', undefined], `${sub} ${JSON.stringify(z)}`)
        assert.match(z.routerUnread, /RPC error while reading the GangSwap router/)
      }
    }
    grad()
    set(V1)
    assert.equal((await run('info')).gangSwap.routerUnread, undefined)
    // the curve: trading needs no version read, and a token with none says so instead of taking the current one
    world = { ...fresh(), migratorOf: {} }
    assert.match((await run('info')).gangSwap.error, /GangSwap version is not set/)
    for (const [w2, re] of [[{ migratorOf: {} }, /is not set/], [{ hasOf: false }, /not supported/], [{ down: new Set(['gangSwapMigratorOf']) }, /RPC error/]]) {
      grad(w2)
      const z = await run('info')
      assert.match(z.gangSwap.error, re)
      assert.match(z.creatorFee.pool.error, re)
      assert.ok(!world.calls.some(([, fn]) => fn === 'gangSwapMigrator'))
    }
    assert.deepEqual(G.gangSwapRouterAddresses(true).map(lc), [ROUTER])
    set(V1, V2)
    process.env.GANG_TESTNET_SWAP_ROUTER = lc(t(0x5aa))
    assert.deepEqual(G.gangSwapRouterAddresses(true).map(lc), [ROUTER, ROUTER2, lc(t(0x5aa))])
    delete process.env.GANG_TESTNET_SWAP_ROUTER
    set()
    // creator fee: each version's own GangSwapFees, with creation closed
    const f2 = (args, extra) => cli(['creator-fee', ...args, '--testnet', '--calldata', '--from', ME], extra)
    for (const [token, fe] of [[GS, FEES], [GS2, FEES2]]) {
      grad({ migrator: zeroAddress })
      let z = await f2(['--token', token, '--claim', '--part', 'pool'])
      assert.deepEqual([z.success, lc(z.tx?.to)], [true, fe], JSON.stringify(z))
      assert.ok(!world.calls.some(([, fn]) => fn === 'gangSwapMigrator'))
    }
    for (const to of [FEES2, BOOST2, FACTORY2, MIGRATOR2, PAIR2]) { grad(); assert.match((await f2(['--token', GS2, '--claim', '--to', to])).error, /could not be taken out/, to) }
    // --to: the contracts of every known router's version, whichever token is claimed
    const N2 = { GANG_TESTNET_SWAP_ROUTER: ROUTER2 }
    for (const to of [FACTORY2, FEES2, BOOST2, MIGRATOR2, ROUTER2]) {
      for (const part of ['curve', 'pool']) { grad(); assert.match((await f2(['--token', GS, '--claim', '--part', part, '--to', to], N2)).error ?? '', /could not be taken out/, to) }
    }
    set(V1, V2)
    {
      const c = { chainId: '97', pad: PAD, wbnb: WBNB, read: async (a, abi, fn, args = []) => { const f = abi.find((q) => q.name === fn); const q = call({ to: a, data: encodeFunctionData({ abi: [f], functionName: fn, args }), from: ME }); if (q.error) throw new Error('rpc'); return decodeFunctionResult({ abi: [f], functionName: fn, data: q.result }) } }
      const all = async (w) => { grad(w); const k = await G.gangSwapKnownContracts(c, true); return { a: k.addresses.map(lc).sort(), unread: k.unread } }
      assert.deepEqual(await all(), { a: [FACTORY, FEES, MIGRATOR, BOOST, FACTORY2, FEES2, MIGRATOR2, BOOST2].sort(), unread: [] })
      assert.deepEqual(await all({ downAt: new Set([ROUTER2]) }), { a: [FACTORY, FEES, MIGRATOR, BOOST].sort(), unread: [ROUTER2] })
      assert.deepEqual(await all({ downAt: new Set([MIGRATOR2]) }), { a: [FACTORY, FEES, MIGRATOR, BOOST, FACTORY2, FEES2, MIGRATOR2].sort(), unread: [ROUTER2] })
      assert.deepEqual((await all({ down: new Set(['fees']) })).unread, [ROUTER, ROUTER2])
      assert.ok((await all({ down: new Set(['fees']) })).a.includes(BOOST2), 'one unread contract does not hide the others')
    }
    set()
    // one that can't be read: the claim is built and says so; to this wallet itself nothing is read
    for (const [part, w] of [['curve', { downAt: new Set([ROUTER2]) }], ['pool', { downAt: new Set([ROUTER2]) }], ['pool', { downAt: new Set([MIGRATOR2]) }]]) {
      grad(w)
      let z = await f2(['--token', GS, '--claim', '--part', part, '--to', OTHER], N2)
      assert.equal(z.success, true, JSON.stringify(z))
      assert.match(z.toUnchecked ?? '', new RegExp(`not checked against every GangSwap contract.*${ROUTER2}`))
      grad(w)
      z = await f2(['--token', GS, '--claim', '--part', part], N2)
      assert.deepEqual([z.success, z.toUnchecked], [true, undefined])
      assert.ok(!world.calls.some(([at]) => at === ROUTER2))
    }
    grad()
    assert.equal((await f2(['--token', GS, '--claim', '--part', 'pool', '--to', OTHER], N2)).toUnchecked, undefined)
    grad({ count: 3n, migrator: zeroAddress })
    const list = await cli(['creator-fee', '--from', ME, '--testnet'])
    assert.deepEqual(list.tokens.filter((z) => z.gangSwapPool).map((z) => [lc(z.token), lc(z.gangSwapPool.contract), parseUnits(z.gangSwapPool.claimable, 18)]), [[GS2, FEES2, 22n], [GS, FEES, (1_000_000_007n * 7000n) / 10000n]], JSON.stringify(list))
    assert.equal(parseUnits(list.totals[0].gangSwapPool, 18), 22n + (1_000_000_007n * 7000n) / 10000n)
  }

  // ---------------------------------------------------------------- creator-fee
  const fee = (args, extra) => cli(['creator-fee', ...args, '--testnet'], extra)
  grad()
  const poolDue = (world.feeAccrued * 7000n) / 10000n
  let o = await fee(['--token', GS])
  assert.deepEqual([o.success, o.kind, o.claimable, o.pool.claimableRaw, lc(o.pool.contract), o.pool.collected], [true, 'gangswap', '0.05', poolDue.toString(), FEES, '0'])
  // claim: the curve part first, on the pad; both as separate txs in raw mode
  o = await fee(['--token', GS, '--claim', '--calldata', '--from', ME])
  assert.deepEqual(o.steps.map((s) => [s.step, s.part, lc(s.tx.to)]), [['claim-creator-fee', 'curve', PAD], ['claim-gangswap-fee', 'pool', FEES]])
  assert.deepEqual(decodeFunctionData({ abi: CREATOR_FEE_ABI, data: o.steps[0].tx.data }).args.map(lc), [GS, lc(ME)])
  d = decodeFunctionData({ abi: G.GANGSWAP_FEES_ABI, data: o.steps[1].tx.data })
  assert.deepEqual([d.functionName, d.args.map(lc)], ['claim', [GS, lc(ME)]])
  assert.deepEqual(o.tx, o.steps[0].tx)
  for (const [part, to] of [['curve', PAD], ['pool', FEES]]) {
    o = await fee(['--token', GS, '--claim', '--part', part, '--calldata', '--from', ME])
    assert.deepEqual([o.success, o.part, lc(o.tx.to), o.steps], [true, part, to, undefined], JSON.stringify(o))
  }
  o = await fee(['--token', GS, '--claim', '--part', 'pool', '--to', OTHER, '--calldata', '--from', ME])
  assert.equal(lc(decodeFunctionData({ abi: G.GANGSWAP_FEES_ABI, data: o.tx.data }).args[1]), lc(OTHER))
  assert.match(o.toNote, /goes to --to/)
  world.collected = 11n; world.curveFee = 0n
  o = await fee(['--token', GS, '--claim', '--calldata', '--from', ME])
  assert.deepEqual([o.step, o.part, lc(o.tx.to), parseUnits(o.amount, 18)], ['claim-gangswap-fee', 'pool', FEES, poolDue + 11n], 'nothing on the pad: the pool part')
  assert.match((await fee(['--token', GS, '--claim', '--part', 'curve', '--calldata', '--from', ME])).error, /nothing to claim yet in the curve part/)
  world.collected = 0n; world.feeAccrued = 0n
  assert.match((await fee(['--token', GS, '--claim', '--calldata', '--from', ME])).error, /nothing to claim yet/)
  grad()
  assert.match((await fee(['--token', GS, '--claim', '--calldata', '--from', OTHER])).error, /only the token's creator/)
  for (const to of [GANG_ROUTER, ROUTER]) assert.match((await fee(['--token', GS, '--claim', '--to', to, '--calldata', '--from', ME], ON)).error, /could not be taken out/, to)
  world = fresh() // on the curve too
  for (const to of [GS, WBNB, FEES, BOOST, FACTORY, MIGRATOR, GANG_ROUTER, ROUTER]) assert.match((await fee(['--token', GS, '--claim', '--to', to, '--calldata', '--from', ME], ON)).error, /could not be taken out/, to)
  grad()
  // unknown flags and --flag=value are refused before any read; the known ones are not
  for (const [a, re] of [[['--too', OTHER], /--too is not a flag of gang creator-fee: did you mean --to\?/], [[`--to=${OTHER}`], /give the value after a space \(--to /], [['--Claim'], /not a flag of gang creator-fee/], [['--recipient', OTHER], /not a flag/], [['--url', 'x'], /not a flag of gang creator-fee: see gang help/]]) {
    world.calls = []
    const x = await fee(['--token', GS, '--claim', '--calldata', '--from', ME, ...a])
    assert.match(x.error, re)
    assert.match(x.error, /Nothing was built|after a space/)
    assert.equal(world.calls.length, 0)
  }
  // a repeated flag: refused, never the first one taken
  for (const [f, v] of [['--to', OTHER], ['--part', 'pool'], ['--token', K1], ['--from', OTHER]]) {
    world.calls = []
    assert.match((await fee(['--token', GS, '--claim', '--to', ME, '--part', 'curve', '--calldata', '--from', ME, f, v])).error, new RegExp(`give ${f} once`))
    assert.equal(world.calls.length, 0)
  }
  assert.equal((await fee(['--token', GS, '--json', '--from', ME])).success, true)
  for (const to of [GS, PAIR, WBNB, FEES, BOOST, FACTORY, MIGRATOR]) assert.match((await fee(['--token', GS, '--claim', '--to', to, '--calldata', '--from', ME])).error, /could not be taken out/, to)
  assert.match((await fee(['--token', GS, '--claim', '--to', zeroAddress, '--calldata', '--from', ME])).error, /zero address/)
  assert.match((await fee(['--token', GS, '--claim', '--to', PAD, '--calldata', '--from', ME])).error, /pad itself/)
  assert.match((await fee(['--token', GS, '--part', 'pool'])).error, /--part goes with --claim/)
  assert.match((await fee(['--token', GS, '--claim', '--part', 'x'])).error, /--part must be/)
  // the pool part unreadable: said, never "nothing"
  grad({ down: new Set(['CREATOR_BPS']), curveFee: 0n })
  o = await fee(['--token', GS, '--claim', '--calldata', '--from', ME])
  assert.match(o.error, /could not read the GangSwap creator fee/)
  grad({ down: new Set(['CREATOR_BPS']) })
  o = await fee(['--token', GS, '--claim', '--calldata', '--from', ME])
  assert.deepEqual([o.step, /could not read/.test(o.poolError)], ['claim-creator-fee', true])
  // on the curve: no pool part
  world = fresh()
  o = await fee(['--token', GS, '--claim', '--calldata', '--from', ME])
  assert.deepEqual([o.step, o.part, o.steps, lc(o.tx.to)], ['claim-creator-fee', 'curve', undefined, PAD])
  assert.match((await fee(['--token', GS, '--claim', '--part', 'pool', '--calldata', '--from', ME])).error, /nothing to claim yet in the pool part/)
  // kind 1: as before, no part / kind / pool
  grad()
  o = await fee(['--token', K1])
  assert.deepEqual([o.kind, o.pool, o.claimable], [undefined, undefined, '0'])
  assert.match((await fee(['--token', K1, '--claim', '--part', 'pool', '--calldata', '--from', ME])).error, /--part is for GangSwap tokens/)
  // the list: the pool part on its own line and in the totals
  o = await fee(['--from', ME])
  assert.equal(o.success, true, JSON.stringify(o))
  const row = o.tokens.find((x) => lc(x.token) === GS)
  assert.deepEqual([row.kind, row.claimable, parseUnits(row.gangSwapPool.claimable, 18)], ['gangswap', '0.05', poolDue], JSON.stringify(o))
  assert.equal(o.tokens.find((x) => lc(x.token) === K1).gangSwapPool, undefined)
  assert.equal(parseUnits(o.totals[0].gangSwapPool, 18), poolDue)
  assert.deepEqual(o.next.map((x) => lc(x).includes(GS)), [true])

  assert.equal(o.unreadNote, undefined)
  // a kind or a pool fee that can't be read is counted, never passed off as none
  for (const [set, re] of [[{ down: new Set(['CREATOR_BPS']) }, /^1 token\(s\) could not be read/], [{ kindDown: true }, /^2 token\(s\) could not be read/]]) {
    grad(set)
    const x = await fee(['--from', ME])
    assert.equal(x.success, true)
    assert.match(x.unreadNote ?? '', re)
    assert.equal(x.tokens.find((y) => lc(y.token) === GS).gangSwapPool, undefined)
  }

  // ---------------------------------------------------------------- a GangSwap token as the quote of a PancakeSwap trade
  for (const [side, f] of [['buy', { payBnb: true }], ['sell', { toBnb: true }]]) {
    const asked = []
    const trade = (kind, o2 = {}) => poolTrade({ chainId: '97', router: GANG_ROUTER, wbnb: WBNB, pad: PAD, client: { getCode: async () => '0x' }, read: async (a, _b, fn, args) => { asked.push([lc(a), fn, args?.[0] && lc(args[0])]); if (fn === 'kindOf') { if (kind === null) throw new Error('down'); return kind } throw new Error('stop') } }, { side, token: K1, quote: GS, me: ME, amount: '1', slippage: 1, base: {}, ...f, ...o2 }, {})
    assert.match((await trade(4)).error, /the quote is a GangSwap token/)
    assert.deepEqual(asked, [[PAD, 'kindOf', GS]], 'the 3.0 pad, before anything else')
    assert.match((await trade(null)).error, /RPC error while checking the quote token/)
    for (const k of [0, 1]) assert.match((await trade(k)).error, /no contract at it/, 'goes on to the router check')
    // no BNB leg, or a WBNB quote: not asked
    for (const o2 of [{ payBnb: false, toBnb: false }, { quote: WBNB }, { quote: null }]) { asked.length = 0; await trade(4, o2); assert.ok(!asked.some((x) => x[1] === 'kindOf'), JSON.stringify(o2)) }
  }

  // ---------------------------------------------------------------- promoter terms / held tax: never a GangSwap token's
  {
    const noteTx = `0x${'ce'.repeat(32)}`
    for (const token of [GS, K1]) {
      world = { ...fresh(), promote: [1000, 30 * 86_400], wbnbAllow: maxUint256, txs: { [noteTx]: { hash: noteTx, input: '0x', from: OTHER, to: PAD, value: '0x0', nonce: '0x0', gas: '0x1', gasPrice: '0x1', blockNumber: '0xff', blockHash: HASH, transactionIndex: '0x0', type: '0x0', v: '0x1b', r: HASH, s: HASH, chainId: '0x61' } } }
      r = await run('buy', { token, amount: '0.1', 'use-wbnb': true })
      assert.equal(r.promoteWarning === undefined, token === GS, `promoteWarning ${token}`)
      r = await run('buy', { token, amount: '0.1', 'use-wbnb': true }, { follow: async () => ({ noteTx }) })
      assert.equal(r.followPromoter === undefined, token === GS, `followPromoter ${token}: ${JSON.stringify(r)}`)
    }
    grad()
    assert.ok(!world.calls.some((x) => x[1] === 'accruedTax'))
    await run('info')
    assert.ok(!world.calls.some((x) => x[1] === 'accruedTax'), 'a GangSwap token has no held tax to read')
    await run('info', { token: K1 })
    assert.ok(world.calls.some((x) => x[1] === 'accruedTax'))
  }
  // --venue twice
  world = fresh()
  for (const c of [['create'], ['v3', 'create'], ['fair', 'create']]) assert.match((await cli([...c, '--venue', 'pancake', '--venue', 'gangswap', '--name', 'G', '--symbol', 'G', '--testnet'])).error, /give --venue once/)
  assert.equal(world.calls.length, 0)

  // ---------------------------------------------------------------- portfolio
  {
    const pos = (n, track, extra = {}) => ({ track, address: t(n), symbol: `T${n}`, quoteSymbol: 'BNB', quoteUsd: 600, costQuote: '1', status: 'curve', balance: '1000', priceQuote: '0.002', ...extra })
    const items = [pos(1, 'v3'), pos(2, 'gangswap'), pos(3, 'v3', { kind: 4 }), pos(4, 'v3', { venue: 'gangswap' }), pos(5, 'v3'), pos(6, 'gangswap')]
    const st = { [t(1)]: { kind: 'gangswap', graduated: true, balance: '1000', dividendPct: 0, poolSellAll: { expectOut: '3' } }, [t(2)]: { kind: 'gangswap', graduated: false, balance: '1000', dividendPct: 0 }, [t(3)]: { kind: 'gangswap', graduated: false, balance: '1000' }, [t(4)]: { kind: 'gangswap', graduated: false, balance: '1000' }, [t(5)]: { graduated: true, balance: '1000', poolSellAll: { expectOut: '2' } }, [t(6)]: { graduated: false, balance: '1000' } }
    const asked = []
    const p = await portfolio({
      wallet: ME, get: async (path) => (path.endsWith('/positions') ? { items } : path.includes('/launches') ? { items: [{ track: 'v3', address: t(1), symbol: 'T1' }] } : {}),
      statusOf: async (k, token) => { asked.push(k); return st[token] }, bondOf: async () => null,
      creatorFeesOf: async () => ({ scanned: [1], tokens: [{ token: t(1), symbol: 'T1', quoteSymbol: 'WBNB', claimable: '0', claimableRaw: '0', padGen: '3.0', gangSwapPool: { claimable: '0.5' } }], totals: [{ quote: 'WBNB', claimable: '0', gangSwapPool: '0.5' }] }),
    })
    assert.equal(p.errors, undefined, JSON.stringify(p.errors))
    // the chain's kind, whatever the row says or leaves out (T1: the server says v3; T6: the server says gangswap, the chain v3)
    assert.deepEqual(Object.fromEntries(p.holdings.map((h) => [h.symbol, h.kind])), { T1: 'gangswap', T2: 'gangswap', T3: 'gangswap', T4: 'gangswap', T5: 'v3', T6: 'v3' })
    const h1 = p.holdings.find((h) => h.symbol === 'T1')
    assert.deepEqual([h1.status, h1.value, /GangSwap/.test(h1.valueBasis), h1.next], ['graduated', 3, true, [`gang sell --token ${t(1)} --all`]])
    assert.equal(p.holdings.find((h) => h.symbol === 'T5').valueBasis, 'selling it all into the pool now, tax included')
    assert.deepEqual(asked.sort(), ['gangswap', 'gangswap', 'gangswap', 'gangswap', 'v3', 'v3'])
    assert.deepEqual([p.bonds, p.creatorFees.tokens[0].gangSwapPool, p.creatorFees.totals.length], [[], 0.5, 1])
  }

  // ---------------------------------------------------------------- discovery rows
  const v3row = { track: 'v3', address: GS, symbol: 'G', quoteSymbol: 'WBNB', quoteAddress: WBNB, realQuote: String(E18), gradAmt: String(6n * E18), progressPct: 16, createdAt: 1, gradTargetBnb: 6, agentWindow: { openAt: 5, open: true } }
  assert.equal(normalize(v3row).venue, undefined, 'a row without it is a V3 one')
  for (const r2 of [{ ...v3row, kind: 4 }, { ...v3row, kind: '4' }, { ...v3row, kind: 'gangswap' }, { ...v3row, venue: 'gangswap' }, { ...v3row, track: 'gangswap' }, { ...v3row, track: undefined, kind: 4 }]) {
    const n = normalize(r2)
    assert.deepEqual([n.venue, ['v3', 'gangswap'].includes(n.track), n.graduationTarget, n.graduationTargetBnb, n.agentWindow.open], ['gangswap', true, 6, 6, true], JSON.stringify(r2))
    assert.match(rank([{ ...n, trades24h: 1 }], 'hot')[0].next, /^gang buy --token/)
    assert.match(rank([{ ...n, trades24h: 1, graduated: true }], 'hot', { includeGraduated: true })[0].next, /^gang buy --token/)
  }
  for (const r2 of [{ track: 'stocks', kind: 4 }, { track: 'main', venue: 'gangswap' }, { track: 'fair', kind: 4 }, { track: 'fly', kind: 4 }, null, {}]) assert.equal(isGangSwapRow(r2), false, JSON.stringify(r2))

  // ---------------------------------------------------------------- invite tag, handoff, MCP, capabilities
  const att = { attached: true, referrer: OTHER }
  assert.equal(refShown({ step: 'pool-buy', venue: 'gangswap' }, att).reason, GANGSWAP_NO_REF)
  assert.equal(refShown({ step: 'approve-quote', next: 'pool-buy', venue: 'gangswap' }, att).attached, false)
  assert.equal(refShown({ step: 'pool-buy', venue: 'pancakeswap' }, att).reason, POOL_NO_REF)
  assert.deepEqual(refShown({ step: 'buy', kind: 'gangswap' }, att), att, 'a curve buy carries the tag')
  {
    const curve = (graduated) => [ME, WBNB, 0n, 0n, 0n, 0n, graduated, 0, 0, 0, zeroAddress, zeroAddress]
    const read = (graduated) => ({ readContract: async ({ functionName }) => ({ curves: curve(graduated), tokenVersionOf: 1, agentOpenAt: 5, decimals: 18, symbol: 'G', tryBuy: [zeroAddress, zeroAddress, 5n, 1n, 1n, 0n, 0n, 0n], balanceOf: 0n }[functionName]), getBlockNumber: async () => 7n, getBalance: async () => E18 })
    await assert.rejects(buildHandoff({ side: 'buy', token: GS, amount: '1', kind: 'gangswap', read: read(true), now: () => NOW }), (e) => e.code === 'HANDOFF_NOT_SERVED' && /trades on GangSwap now, not PancakeSwap/.test(e.message) && !/any DEX/.test(e.message))
    await assert.rejects(buildHandoff({ side: 'buy', token: GS, amount: '1', kind: 'v3', read: read(true), now: () => NOW }), /PancakeSwap pool now, with any DEX/)
  }
  // the handoff command lets a curve GangSwap token through to the checks (mainnet only: the kind is asked of the fake node)
  {
    const o2 = await cli(['buy', '--token', K2, '--amount', '1', '--handoff'], { GANG_RPC_URL: rpc })
    assert.equal(o2.success, false)
  }
  const tool = (n) => TOOLS.find((x) => x.name === n).description
  assert.match(tool('gang_info'), /gangswap/)
  assert.match(tool('gang_buy'), /GangSwap/)
  assert.match(tool('gang_sell'), /GangSwap/)
  assert.match(tool('gang_cli'), /--venue gangswap.*permanent/)
  assert.ok(RULES.some((x) => /--venue gangswap/.test(x) && /permanent/.test(x) && /not PancakeSwap/.test(x)))
  const cap = capabilities().commands.find((x) => x.command === 'create --venue gangswap')
  assert.deepEqual([cap.access, cap.risk, cap.needsUserConfirmation], ['preview', 'high', true])
} finally {
  server.close()
}
console.log('gangswap: ok')
