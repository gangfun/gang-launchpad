/**
 * The opening base (base-v1) against a local fake BSC testnet node (no chain, no wallet):
 *   - --base / --base-vest parsing, and the numbers of the spec's §2 tables from the curve's own formula;
 *   - gang create --base: refused on a pad without it (mainnet before its upgrade) or with it closed, and with the flags
 *     it does not take; with abcd on, createWithSalt carries createWithBase and exactly previewBaseCost as the value
 *     (the dry run too); with abcd off, createWithBase is called directly with that value;
 *   - gang base status / release: not started, graduated but not started, half way (unreleased by time, not balance),
 *     nothing to release.
 *
 *   node skill/gang-cli/test/base.mjs
 */
import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { decodeFunctionData, encodeFunctionResult, formatUnits, getAddress, parseAbi, stringToHex, toFunctionSelector, zeroAddress } from 'viem'

process.env.GANG_TELEMETRY = '0'
const { runV3, V3_EVENT_ABIS, V3_NETS } = await import('../src/v3.js')
const { runBase, BASE_PAD_ABI, BASE_VAULT_ABI, basePayoff, parseBase } = await import('../src/base.js')
const { VANITY_ABI } = await import('../src/vanity.js')
const { CREATOR_FEE_ABI, GRAD_TARGET_ABI, gangGens } = await import('../src/gangpad.js')

const lc = (a) => String(a).toLowerCase()
const t = (n) => getAddress(`0x${n.toString(16).padStart(40, '0')}`)
const PAD = lc(gangGens(true)[0].pad)
const ME = t(0xd3f), VAN = t(0x7a17), HANDLER = t(0x4a4d), IMPL = t(0x1a91), VAULT = lc(t(0xba5e)), TOKEN = lc(t(0x70c))
const E18 = 10n ** 18n

// CurveLogic3.baseCost, as the contract computes it: what the fake pad answers for previewBaseCost
const VIRTUAL_TOKEN = 1_066_666_666_666_666_666_666_666_667n
const ceilDiv = (a, b) => (a + b - 1n) / b
const baseCost = (g, bps) => {
  const tokens = (1_000_000_000n * E18 * BigInt(bps)) / 10_000n
  const vq = g / 3n
  const net = ceilDiv(vq * VIRTUAL_TOKEN, VIRTUAL_TOKEN - tokens) - vq
  return ceilDiv(net * 10_000n, 9_900n)
}

// ---- parsing
assert.deepEqual(parseBase('5', '30'), { baseBps: 500, vestDays: 30 })
assert.deepEqual(parseBase('10%', '180'), { baseBps: 1000, vestDays: 180 })
assert.match(parseBase('10', '30').error, /90 or 180/)
assert.match(parseBase('7', '90').error, /--base <5\|10>/)
assert.match(parseBase('5', undefined).error, /needs --base-vest/)
assert.match(parseBase('5', '60').error, /30, 90, 180/)

// ---- spec §2: the cost table (4 dp) and the payoff rows at 9 BNB
const COSTS = { 6: ['0.0994', '0.2090'], 9: ['0.1490', '0.3135'], 12: ['0.1987', '0.4180'], 15: ['0.2484', '0.5225'] }
for (const [g, [five, ten]] of Object.entries(COSTS)) {
  assert.equal(Number(formatUnits(baseCost(BigInt(g) * E18, 500), 18)).toFixed(4), five, `${g} BNB, 5%`)
  assert.equal(Number(formatUnits(baseCost(BigInt(g) * E18, 1000), 18)).toFixed(4), ten, `${g} BNB, 10%`)
}
// the testnet record: 6 BNB, 5% = 0.099354197714853454 tBNB
assert.equal(baseCost(6n * E18, 500), 99_354_197_714_853_454n)
const p = (bps, days) => basePayoff({ gradBnb: 9, baseBps: bps, vestDays: days, cost: baseCost(9n * E18, bps) })
assert.match(p(500, 30).youGet.minimum, /about 1\.8 BNB.*64% of the graduation price/)
assert.match(p(1000, 90).youGet.minimum, /about 3 BNB.*44% of the graduation price/)
assert.match(p(500, 30).youGet.atGraduationPrice, /^2\.25 BNB/)
assert.match(p(1000, 90).youGet.atGraduationPrice, /^4\.5 BNB/)
for (const [bps, days, back, perDay] of [[500, 30, '2', '0.83'], [500, 90, '6', '0.28'], [500, 180, '11.9', '0.14'], [1000, 90, '6.3', '0.56'], [1000, 180, '12.5', '0.28']]) {
  assert.match(p(bps, days).youGet.daysToRecoverCost, new RegExp(`about ${back.replace('.', '\\.')} days`), `${bps} / ${days}`)
  assert.match(p(bps, days).youGet.releasedPerDay, new RegExp(`^${perDay.replace('.', '\\.')}%`), `${bps} / ${days}`)
}
assert.match(p(500, 30).poolShare, /^25%/)
assert.match(p(1000, 90).poolShare, /^50%/)
assert.match(p(500, 30).othersPay.startPrice, /1\.1×/)
assert.match(p(1000, 90).othersPay.startPrice, /1\.22×/)
assert.match(p(500, 30).othersPay.averageToGraduation, /4\.9% more/)
assert.match(p(1000, 90).othersPay.averageToGraduation, /10\.3% more/)
assert.match(p(500, 30).averagePrice, /1\/15\.1/)

// ---- the fake node
const world = {
  vanity: true, impl: IMPL, hasBase: true, balance: 10n * E18, calls: [],
  // the vault
  locked: true, startAt: 0n, duration: 30n * 86_400n, total: 0n, released: 0n, releasable: 0n, vaultBalance: 50_000_000n * E18, now: 2_000_000_000n,
}
const ERC20 = parseAbi(['function symbol() view returns (string)', 'function decimals() view returns (uint8)',
  'function balanceOf(address) view returns (uint256)', 'function allowance(address,address) view returns (uint256)', 'function locked() view returns (bool)',
  'function kindOf(address token) view returns (uint8)', 'function implementation() view returns (address)'])
const abi = [...V3_EVENT_ABIS[0], ...CREATOR_FEE_ABI, ...GRAD_TARGET_ABI, ...VANITY_ABI, ...BASE_PAD_ABI, ...BASE_VAULT_ABI, ...ERC20]
const functions = new Map()
for (const f of abi.filter((x) => x.type === 'function')) functions.set(toFunctionSelector(f), f)
const revert = { error: { code: 3, message: 'execution reverted', data: '0x' } }

const answer = (b) => {
  if (b.method === 'eth_chainId') return { result: '0x61' }
  if (b.method === 'eth_getCode') return { result: '0x' }
  if (b.method === 'eth_blockNumber') return { result: '0x100' }
  if (b.method === 'eth_getBalance') return { result: `0x${world.balance.toString(16)}` }
  if (b.method === 'eth_getBlockByNumber') {
    return { result: { number: '0x100', timestamp: `0x${world.now.toString(16)}`, hash: `0x${'11'.repeat(32)}`, parentHash: `0x${'22'.repeat(32)}`, transactions: [], baseFeePerGas: '0x0', gasLimit: '0x1', gasUsed: '0x0', difficulty: '0x0', logsBloom: `0x${'00'.repeat(256)}`, miner: zeroAddress, extraData: '0x', nonce: '0x0000000000000000', sha3Uncles: `0x${'00'.repeat(32)}`, size: '0x1', stateRoot: `0x${'00'.repeat(32)}`, receiptsRoot: `0x${'00'.repeat(32)}`, transactionsRoot: `0x${'00'.repeat(32)}`, uncles: [], totalDifficulty: '0x0' } }
  }
  assert.equal(b.method, 'eth_call')
  const { data, to, value } = b.params[0]
  const sent = BigInt(value ?? '0x0')
  const f = functions.get(data.slice(0, 10))
  if (!f) return revert
  const { args = [] } = decodeFunctionData({ abi: [f], data })
  const at = lc(to)
  let result
  if (at === VAULT) {
    const v = { pad: PAD, token: TOKEN, creator: ME, startAt: world.startAt, duration: world.duration, total: world.total, released: world.released, releasable: world.releasable, moduleType: stringToHex('base-v1', { size: 32 }) }
    if (f.name === 'release') {
      if (world.locked) return { error: { code: 3, message: 'execution reverted', data: toFunctionSelector('NotGraduated()') } }
      result = world.startAt ? world.releasable : 0n
    } else if (f.name in v) result = v[f.name]
    else return revert
    return { result: encodeFunctionResult({ abi: [f], functionName: f.name, result }) }
  }
  if (at === TOKEN) {
    if (f.name === 'balanceOf') result = world.vaultBalance
    else if (f.name === 'locked') result = world.locked
    else if (f.name === 'symbol') result = 'BASE'
    else return revert
    return { result: encodeFunctionResult({ abi: [f], functionName: f.name, result }) }
  }
  if (at !== PAD && f.name === 'kindOf') return { result: encodeFunctionResult({ abi: [f], functionName: f.name, result: 0 }) }
  switch (f.name) {
    case 'kindOf': result = lc(args[0]) === TOKEN ? 1 : 0; break
    case 'vanityDeployer': result = world.vanity ? VAN : zeroAddress; break
    case 'taxHandler': case 'router': case 'recipientRegistry': case 'implementation': result = HANDLER; break
    case 'tokenInitCodeHash': result = `0x${'ab'.repeat(32)}`; break
    case 'baseVaultImpl': if (!world.hasBase) return revert; result = world.impl; break
    case 'previewBaseCost': if (!world.hasBase) return revert; result = baseCost(args[0], args[1]); break
    case 'baseVaultOf': if (!world.hasBase) return revert; result = lc(args[0]) === TOKEN ? VAULT : zeroAddress; break
    case 'baseOf': result = lc(args[0]) === TOKEN ? 50_000_000n * E18 : 0n; break
    case 'createWithSalt': {
      const inner = decodeFunctionData({ abi: BASE_PAD_ABI, data: args[1] })
      world.calls.push({ via: 'createWithSalt', fn: inner.functionName, args: inner.args, value: sent })
      if (sent !== baseCost(inner.args[5], inner.args[6].baseBps)) return { error: { code: 3, message: 'execution reverted', data: toFunctionSelector('BadMsgValue()') } }
      result = t(0x1abcd)
      break
    }
    case 'createWithBase': {
      world.calls.push({ via: 'direct', fn: f.name, args, value: sent })
      if (world.vanity) return { error: { code: 3, message: 'execution reverted', data: toFunctionSelector('VanityContextRequired()') } }
      if (sent !== baseCost(args[5], args[6].baseBps)) return { error: { code: 3, message: 'execution reverted', data: toFunctionSelector('BadMsgValue()') } }
      result = t(0x2abcd)
      break
    }
    case 'create': case 'createWithGradTarget': assert.fail('a --base create must go through createWithBase'); break
    case 'checkTaxConfigFor': case 'checkTaxConfig': result = [true, '']; break
    case 'isAgent': result = true; break
    case 'GRAD_BNB_TIERS': result = [6n, 9n, 12n, 15n].map((x) => x * E18); break
    case 'TARGET_GRAD_BNB': case 'graduationAmountOf': result = 9n * E18; break
    case 'graduationAmountFor': result = args[2]; break
    case 'PROTOCOL_FEE_BPS': result = 100n; break
    case 'PLATFORM_TAX_BPS': result = 50n; break
    case 'CREATOR_FEE_SHARE_BPS': result = 7000n; break
    case 'symbol': result = 'WBNB'; break
    case 'decimals': result = 18; break
    case 'balanceOf': case 'allowance': result = 0n; break
    default: return revert
  }
  return { result: encodeFunctionResult({ abi: [f], functionName: f.name, result }) }
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

class Failed extends Error {}
const io = (flags) => ({
  opt: (key, fallback) => flags[key] ?? fallback,
  flag: (key) => Object.hasOwn(flags, key),
  out: (x) => x,
  fail: (error, details) => { throw new Failed(`${error} ${JSON.stringify(details ?? {})}`) },
  summarize: () => assert.fail('raw calldata needs no wallet preview'),
  checkMeta: () => {},
  resolveLogo: async () => ({ logoURI: 'ipfs://logo' }),
  resolveMeta: async () => ({ metaURI: 'ipfs://meta', metadata: { name: 'Base' } }),
  // as steps.js step with --calldata: the value as a decimal string
  notes: { step: (_ctx, tx, extra) => ({ success: true, ...extra, tx: { ...tx, value: String(tx.value ?? 0n) } }), skipped: () => ({}) },
})
const create = (extra) => runV3('create', io({ name: 'Base', symbol: 'BASE', from: ME, testnet: true, calldata: true, base: '5', 'base-vest': '30', ...extra }))
const refused = async (promise, re) => {
  await assert.rejects(promise, (e) => e instanceof Failed && re.test(e.message), String(re))
}

try {
  // abcd on: createWithSalt(salt, createWithBase(…)) with exactly the cost, in the dry run and in the tx
  world.calls = []
  let r = await create({ grad: '6' })
  assert.equal(r.success, true, JSON.stringify(r))
  assert.equal(r.tx.value, '99354197714853454')
  assert.equal(r.base.costBnb, '0.099354197714853454')
  assert.match(r.base.neverGraduates, /locked in the vault for good/)
  assert.match(r.base.bond, /GangBond does not constrain the base/)
  assert.match(r.base.schedule, /linearly over 30 days/)
  assert.ok(r.base.payoff.youGet.minimum)
  assert.equal(r.base.tax, undefined)
  assert.equal(r.addressSuffix, 'abcd')
  const outer = decodeFunctionData({ abi: VANITY_ABI, data: r.tx.data })
  assert.equal(outer.functionName, 'createWithSalt')
  const inner = decodeFunctionData({ abi: BASE_PAD_ABI, data: outer.args[1] })
  assert.equal(inner.functionName, 'createWithBase')
  assert.equal(inner.args[3], 'ipfs://meta')
  assert.equal(inner.args[5], 6n * E18)
  assert.deepEqual(inner.args[6], { baseBps: 500, vestDays: 30 })
  assert.equal(VANITY_ABI.find((x) => x.name === 'createWithSalt').stateMutability, 'payable')
  assert.deepEqual(world.calls.map((c) => [c.via, c.fn, c.value]), [['createWithSalt', 'createWithBase', 99_354_197_714_853_454n]])

  // taxed, the creator its own recipient: the tax line says the tax comes back but the platform's part
  r = await create({ base: '10', 'base-vest': '90', 'buy-tax': '3', 'sell-tax': '3' })
  assert.equal(r.success, true, JSON.stringify(r))
  assert.equal(r.tx.value, baseCost(9n * E18, 1000).toString())
  assert.match(r.base.tax, /you are this token's tax recipient.*0\.5%/)

  // abcd off: createWithBase directly, with the value
  world.vanity = false; world.calls = []
  r = await create({})
  assert.equal(r.success, true, JSON.stringify(r))
  assert.equal(decodeFunctionData({ abi: BASE_PAD_ABI, data: r.tx.data }).functionName, 'createWithBase')
  assert.equal(r.tx.value, baseCost(9n * E18, 500).toString())
  assert.deepEqual(world.calls.map((c) => [c.via, c.value]), [['direct', baseCost(9n * E18, 500)]])
  world.vanity = true

  // refusals before anything is built
  await refused(create({ vault: t(0x7a), }), /--base and --vault/)
  await refused(create({ promote: '10' }), /--base and --promote/)
  await refused(create({ quote: t(0x777), 'ref-pool': t(0x778) }), /WBNB-quoted tokens only/)
  await refused(create({ 'buy-tax': '2', 'sell-tax': '2', dividend: '20' }), /dividend/)
  await refused(create({ base: '10', 'base-vest': '30' }), /90 or 180/)
  await refused(runV3('create', io({ name: 'B', symbol: 'B', from: ME, testnet: true, calldata: true, 'base-vest': '30' })), /--base-vest goes with --base/)
  world.balance = 10n ** 16n
  await refused(create({}), /not enough BNB for the base/)
  world.balance = 10n * E18
  // a pad without the base (mainnet before its upgrade), and one with it closed
  world.hasBase = false; world.calls = []
  await refused(create({}), /no opening base yet/)
  assert.equal(world.calls.length, 0)
  world.hasBase = true; world.impl = zeroAddress
  await refused(create({}), /closed/)
  world.impl = IMPL

  // ---- gang base
  const base = (sub, extra = {}) => runBase(sub, io({ token: TOKEN, testnet: true, calldata: true, from: t(0x5ee), ...extra }))
  let s = await base('status')
  assert.equal(s.success, true, JSON.stringify(s))
  assert.equal(lc(s.vault), VAULT)
  assert.equal(s.startAt, 'not started')
  assert.equal(s.unreleased, '50000000')
  assert.equal(s.basePct, 5)
  assert.equal(s.next, undefined)
  await refused(base('release'), /has not graduated/)
  await refused(runBase('status', io({ token: t(0x999), testnet: true })), /not a V3 curve token/)

  // graduated, not started: the first release starts the clock and sends nothing
  world.locked = false
  // tokens sent in after graduation, before the start: unreleased is still the base bought at create
  world.vaultBalance = 50_000_001n * E18
  s = await base('status')
  assert.match(s.next, /gang base release/)
  assert.equal(s.unreleased, '50000000')
  assert.equal(s.inVault, '50000001')
  world.vaultBalance = 50_000_000n * E18
  let rel = await base('release')
  assert.equal(rel.success, true, JSON.stringify(rel))
  assert.equal(rel.starts, true)
  assert.equal(lc(rel.tx.to), VAULT)
  assert.equal(decodeFunctionData({ abi: BASE_VAULT_ABI, data: rel.tx.data }).functionName, 'release')

  // half way: unreleased by time (total − vested), not the vault's balance (nobody released yet)
  world.startAt = world.now - 15n * 86_400n; world.total = 50_000_000n * E18; world.releasable = 25_000_000n * E18
  s = await base('status')
  assert.equal(s.started, true)
  assert.equal(s.vestedSoFar, '25000000')
  assert.equal(s.unreleased, '25000000')
  assert.equal(s.inVault, '50000000')
  assert.equal(s.elapsedDays, 15)
  rel = await base('release')
  assert.equal(rel.success, true)
  assert.equal(rel.amount, '25000000')
  assert.match(rel.note, /not to the wallet that calls/)

  // nothing vested since the last release
  world.released = 25_000_000n * E18; world.releasable = 0n; world.vaultBalance = 25_000_000n * E18
  await refused(base('release'), /nothing has vested/)

  // a token on a pad without the base (or created without one)
  world.hasBase = false
  await refused(base('status'), /no opening base/)
  world.hasBase = true

  console.log('base: ok')
} finally { server.closeAllConnections(); server.close() }
