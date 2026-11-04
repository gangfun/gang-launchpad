/**
 * 铸币飞轮 on GangLaunchpad 3.0 (kind 3; docs/SPEC-GANG-LAUNCHPAD-3-2026-11-03.md §10): the traps of having every kind on
 * one address. Run as the real CLI against a local fake BSC testnet node that answers only what 3.0 answers, so a read of
 * V2's taxHandler() or of 打新's sales() on a fly token is seen. No chain.
 *
 *   node skill/gang-cli/test/fly-pad3.mjs
 */
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { createServer } from 'node:http'
import { decodeFunctionData, encodeFunctionResult, parseAbi, toFunctionSelector, zeroAddress } from 'viem'
import { FLY_PADS, FLY_PAD_V2_ABI, flyCtx, isFlyToken } from '../src/fly.js'
import { GANG_GENS, genOf, PAD3_GEN } from '../src/gangpad.js'

const t = (n) => `0x${String(n).padStart(40, '0')}`
const lower = (a) => a.toLowerCase()
const PAD3 = GANG_GENS.testnet[0].pad
const WBNB = '0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd'
const MULTICALL3 = '0xcA11bde05977b3631167028862bE2a173976CA11'
const ME = t(0x71), GATE = t(0x72), FLY_HANDLER = t(0x73), CURVE_HANDLER = t(0x74), VAULT = t(0x75)
const CURVE = t(0x80), FAIR = t(0x81), FLY = t(0x82), FLY_V2 = t(0x83), NOBODY = t(0x84)

// ---- the pads, without a node
for (const [testnet, net] of [[true, 'testnet'], [false, 'mainnet']]) {
  const ctx = flyCtx(testnet)
  assert.deepEqual(ctx.pads.map((p) => [p.version, p.address]), [
    [3, GANG_GENS[net].find((g) => g.gen === PAD3_GEN).pad], [2, FLY_PADS[net].v2], [1, FLY_PADS[net].v1],
  ])
  assert.deepEqual([ctx.pad, ctx.version], [ctx.pads[0].address, 3], 'creates go to 3.0')
  // pool trades stay on the GangRouter they were accepted with (the 1.0 generation's)
  assert.equal(ctx.router, GANG_GENS[net].find((g) => g.gen === '1.0').router)
}
assert.equal(flyCtx(true).pads[0].address, PAD3)
assert.equal(flyCtx(false).pads[0].address, '0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29')

// genOf: kind 3 is 3.0's fly token, not an unreadable pad
const kindsCtx = (kinds, down = []) => ({
  gens: GANG_GENS.testnet,
  read: async (pad, _abi, fn, [token]) => {
    assert.equal(fn, 'kindOf')
    if (down.includes(pad)) throw new Error('rpc')
    return token && lower(pad) === lower(PAD3) ? kinds : 0
  },
})
assert.deepEqual(await genOf(kindsCtx(3), FLY).then((r) => [r.g.gen, r.kind]), [PAD3_GEN, 'fly'])
assert.deepEqual(await genOf(kindsCtx(1), CURVE).then((r) => [r.g.gen, r.kind]), [PAD3_GEN, 'v3'])
assert.deepEqual(await genOf(kindsCtx(2), FAIR).then((r) => [r.g.gen, r.kind]), [PAD3_GEN, 'fair'])
assert.deepEqual(await genOf(kindsCtx(3, [GANG_GENS.testnet[1].pad]), FLY).then((r) => r.kind), 'fly')

// isFlyToken: 3.0's curve and 打新 tokens name 3.0 as launchpad() too: only its kindOf counts
const flyAt = (named, kinds, kindsDown = false) => {
  const ctx = flyCtx(true)
  ctx.read = async (to, _abi, fn) => {
    if (fn === 'launchpad') {
      if (!named) throw new Error('no such function')
      return named
    }
    assert.equal(fn, 'kindOf')
    if (kindsDown) throw new Error('rpc')
    return kinds[to] ?? 0
  }
  return isFlyToken(ctx, t(1))
}
assert.equal(await flyAt(PAD3, { [PAD3]: 1 }), false, 'a 3.0 curve token')
assert.equal(await flyAt(PAD3, { [PAD3]: 2 }), false, 'a 3.0 打新 token')
assert.equal(await flyAt(PAD3, { [PAD3]: 3 }), true, 'a 3.0 fly token')
assert.equal(await flyAt(FLY_PADS.testnet.v2, {}), true, 'a V2 token (its pad names it; every V2 token is a fly token)')
assert.equal(await flyAt(FLY_PADS.testnet.v1, {}), true, 'a V1 token')
assert.equal(await flyAt(null, { [FLY_PADS.testnet.v2]: 3 }), true, 'no launchpad(): asked of each pad')
assert.equal(await flyAt(null, {}), false)
assert.equal(await flyAt(PAD3, {}, true), null, 'kindOf unreadable: null, never "not a fly token"')

// ---- the real CLI against 3.0 as a fake node
const SALE = `(address creator, address quote, address gate, address pair, uint128 basePrice, uint64 totalShares, uint64 filledAt, uint64 progressAt, uint16 sold, uint16 creatorShares, uint16 markSold, uint16 baseQuota, uint16 holdBps, uint16 mintFeeBps, uint16 exitFeeBps, uint16 devCutBps, uint16 buyBps, uint32 launchDelay, uint32 window, uint8 inviteBonus, uint8 maxPerTx, uint8 windowCapMul, uint8 tierMode, uint16 stepBps, uint32 stepShares, uint16 maxMulX100, bool postMint, bool launched)`
const saleOf = () => ({
  creator: ME, quote: WBNB, gate: GATE, pair: zeroAddress, basePrice: 300_000_000_000_000n, totalShares: 3n, filledAt: 0n, progressAt: 1_000n, sold: 3, creatorShares: 3,
  markSold: 0, baseQuota: 10, holdBps: 6_000, mintFeeBps: 100, exitFeeBps: 100, devCutBps: 1_000, buyBps: 3_000, launchDelay: 60, window: 600, inviteBonus: 1,
  maxPerTx: 10, windowCapMul: 1, tierMode: 1, stepBps: 0, stepShares: 0, maxMulX100: 0, postMint: true, launched: false,
})
const ABI = [
  ...parseAbi([
    `function sales(address token) view returns (${SALE})`,
    'function flyTaxHandler() view returns (address)',
    'function taxHandler() view returns (address)',
    'function migrator() view returns (address)',
    'function agentGateEnabled() view returns (bool)',
    'function tokenCount() view returns (uint256)',
    'function allTokens(uint256) view returns (address)',
    'function kindOf(address token) view returns (uint8)',
    'function launchpad() view returns (address)',
    'function symbol() view returns (string)',
    'function decimals() view returns (uint8)',
    'function balanceOf(address) view returns (uint256)',
    'function allowance(address, address) view returns (uint256)',
    'function exitFeeBpsOf(address token) view returns (uint256)',
    'function owedDev(address token) view returns (uint256)',
    'function owedOf(address token) view returns (uint256)',
    'function quotaLeft(address token, address user) view returns (uint256)',
    'function accounts(address token, address user) view returns (uint32, uint32, uint32, bool, uint64, uint128, uint256)',
    'function previewMint(address token, address user, uint256 shares) view returns (uint256, uint256, uint256)',
    'function previewWithdraw(address token, address user, uint256 shares) view returns (uint256, uint256)',
    'function mintWithBnb(address token, uint256 shares, uint256 minShares, address referrer) payable returns (uint256)',
    'function withdraw(address token, uint256 shares, uint256 minPayout) returns (uint256)',
    'struct Call3 { address target; bool allowFailure; bytes callData; }',
    'struct Result { bool success; bytes returnData; }',
    'function aggregate3(Call3[] calls) payable returns (Result[])',
  ]),
  ...FLY_PAD_V2_ABI.filter((x) => x.name === 'checkConfig'),
]
const SEL = new Map(ABI.filter((x) => x.type === 'function').map((x) => [toFunctionSelector(x), x.name]))
const CHECK = ABI.find((x) => x.name === 'checkConfig')
const KIND = { [lower(CURVE)]: 1, [lower(FAIR)]: 2, [lower(FLY)]: 3 }

const calls = []
// one call → [ok, hex]; a function this fake node does not serve answers like a contract without it
const answer = (to, data) => {
  const fn = SEL.get(data.slice(0, 10))
  calls.push({ fn: fn ?? data.slice(0, 10), to: lower(to), data })
  if (!fn) return [false]
  const { args } = decodeFunctionData({ abi: ABI, data })
  const onPad3 = lower(to) === lower(PAD3)
  const value = {
    flyTaxHandler: () => FLY_HANDLER,
    taxHandler: () => (onPad3 ? CURVE_HANDLER : FLY_HANDLER),
    migrator: () => t(0x76),
    agentGateEnabled: () => true,
    tokenCount: () => (onPad3 ? 3n : 0n),
    allTokens: () => [CURVE, FLY, FAIR][Number(args[0])],
    kindOf: () => (onPad3 ? (KIND[lower(args[0])] ?? 0) : 0),
    launchpad: () => (lower(to) === lower(FLY_V2) ? FLY_PADS.testnet.v2 : PAD3),
    symbol: () => 'SYM',
    decimals: () => 18,
    balanceOf: () => 10n ** 21n,
    allowance: () => 0n,
    exitFeeBpsOf: () => 100n,
    owedDev: () => 0n,
    owedOf: () => 0n,
    quotaLeft: () => 7n,
    accounts: () => [3, 3, 0, true, 0n, 0n, 300_000n * 10n ** 18n],
    previewMint: () => [args[2], args[2] * 300_000_000_000_000n, args[2] * 3_000_000_000_000n],
    previewWithdraw: () => [297_000_000_000_000n, 3_000_000_000_000n],
    mintWithBnb: () => args[1],
    withdraw: () => 0n,
    checkConfig: () => [true, ''],
    // 3.0 answers a fly token with V2's struct, a 打新 sale with its own (this test never lets the CLI read that one)
    sales: () => (KIND[lower(args[0])] === 3 ? saleOf() : null),
    aggregate3: () => args[0].map((c) => {
      const [ok, hex] = answer(c.target, c.callData)
      return { success: ok, returnData: hex ?? '0x' }
    }),
  }[fn]()
  if (value === null) return [false]
  return [true, encodeFunctionResult({ abi: ABI, functionName: fn, result: value })]
}
const server = createServer((req, res) => {
  let raw = ''
  req.on('data', (c) => (raw += c))
  req.on('end', () => {
    const one = (b) => {
      if (b.method === 'eth_chainId') return { result: '0x61' }
      if (b.method === 'eth_getBalance') return { result: `0x${(10n ** 18n).toString(16)}` }
      if (b.method !== 'eth_call') return { error: { code: -32601, message: `unexpected ${b.method}` } }
      const [ok, hex] = answer(b.params[0].to, b.params[0].data)
      return ok ? { result: hex } : { error: { code: 3, message: 'execution reverted', data: '0x' } }
    }
    const body = JSON.parse(raw)
    const reply = Array.isArray(body) ? body.map((b) => ({ jsonrpc: '2.0', id: b.id, ...one(b) })) : { jsonrpc: '2.0', id: body.id, ...one(body) }
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify(reply))
  })
})
await new Promise((r) => server.listen(0, '127.0.0.1', r))
const url = `http://127.0.0.1:${server.address().port}`

const gang = (...args) => new Promise((resolve) => {
  calls.length = 0
  const p = spawn(process.execPath, [new URL('../src/index.js', import.meta.url).pathname, ...args, '--testnet'], {
    env: { ...process.env, GANG_TESTNET_RPC_URL: url, GANG_UPDATE_CHECK: '0', GANG_TELEMETRY: '0', PATH: '' },
  })
  let out = ''
  p.stdout.on('data', (c) => (out += c))
  p.on('close', () => resolve(JSON.parse(out)))
})
const made = (fn) => calls.filter((c) => c.fn === fn)

try {
  // list: 3.0's allTokens has every kind; only its fly token is read as a sale (sales would answer the others another struct)
  let r = await gang('list', '--kind', 'fly')
  assert.equal(r.success, true, JSON.stringify(r))
  assert.deepEqual(r.items.map((x) => [x.token.toLowerCase(), x.padVersion, x.status]), [[lower(FLY), 3, 'minting']])
  assert.deepEqual([r.total, r.createPad, r.createPadVersion], [1, PAD3, 3])
  assert.deepEqual(made('sales').map((c) => decodeFunctionData({ abi: ABI, data: c.data }).args[0].toLowerCase()), [lower(FLY)])

  // a pool-side read goes to flyTaxHandler(), never to 3.0's curve / 打新 taxHandler()
  r = await gang('release', '--token', FLY, '--from', ME, '--calldata')
  assert.match(r.error, /nothing is owed/)
  assert.equal(made('flyTaxHandler').length, 1)
  assert.equal(made('taxHandler').length, 0)
  assert.deepEqual(made('owedOf').map((c) => c.to), [lower(FLY_HANDLER)])

  // V2's calls at 3.0's address, direct (no router, no gateway)
  r = await gang('mint', '--token', FLY, '--shares', '2', '--from', ME, '--calldata')
  assert.deepEqual([r.kind, r.step, r.phase, r.shares, r.tx.to], ['fly', 'mint', 'pre-launch', 2, PAD3])
  assert.equal(r.tx.data.slice(0, 10), toFunctionSelector(ABI.find((x) => x.name === 'mintWithBnb')))
  assert.equal(r.tokens, '200000', 'a fly share is 100,000 tokens, not 3.0\'s TOKENS_PER_SHARE()')
  r = await gang('withdraw', '--token', FLY, '--shares', '1', '--from', ME, '--calldata')
  assert.deepEqual([r.kind, r.step, r.tx.to], ['fly', 'withdraw', PAD3])
  assert.equal(r.tx.data.slice(0, 10), toFunctionSelector(ABI.find((x) => x.name === 'withdraw')))
  r = await gang('info', '--token', FLY)
  assert.deepEqual([r.kind, r.padVersion, r.padGen, r.pad, r.tokensPerShare], ['fly', 3, PAD3_GEN, PAD3, '100000'])

  // create: 3.0 is the target and uses V2's FlyConfig (its checkConfig selector); the funding step names 3.0
  r = await gang('create', '--fly', '--name', 'A', '--symbol', 'A', '--from', ME, '--calldata')
  assert.deepEqual([r.step, r.spender], ['approve-quote', PAD3], JSON.stringify(r))
  assert.equal(made('checkConfig')[0].to, lower(PAD3))
  assert.equal(made('checkConfig')[0].data.slice(0, 10), toFunctionSelector(CHECK))
  // V2's post-launch rules hold on 3.0
  r = await gang('create', '--fly', '--name', 'A', '--symbol', 'A', '--quota', '50', '--from', ME, '--calldata')
  assert.match(r.error, /--quota must be 5-10 with post-launch minting on/)
  // a 3.0 token as the quote: said before any wrap / approve step; each kind
  for (const quote of [CURVE, FAIR, FLY]) {
    r = await gang('create', '--fly', '--name', 'A', '--symbol', 'A', '--quote', quote, '--ref-pool', t(1), '--from', ME, '--calldata')
    assert.match(r.error, /--quote cannot be a token of GangLaunchpad 3\.0/, quote)
    assert.equal(made('allowance').length, 0)
  }

  // the other kinds' commands on a fly token: a pointer, never its struct read as theirs
  r = await gang('fair', 'info', '--token', FLY)
  assert.deepEqual([r.success, r.kind], [false, 'fly'])
  assert.match(r.error, /铸币飞轮/)
  assert.equal(made('sales').length, 0)
  r = await gang('creator-fee', '--token', FLY)
  assert.deepEqual([r.success, r.kind], [false, 'fly'])
  assert.match(r.error, /no creator fee/)

  // gang fly on 3.0's other kinds, and on a token of no pad
  for (const token of [CURVE, FAIR, NOBODY]) {
    r = await gang('fly', 'info', '--token', token)
    assert.equal(r.success, false, token)
    assert.match(r.error, /not a 铸币飞轮/, token)
    assert.equal(made('sales').length, 0, token)
  }
  // a V2 token (its launchpad() names V2) is read on V2, not on 3.0: this fake node has no V2 sale, so that read is refused
  r = await gang('fly', 'info', '--token', FLY_V2)
  assert.equal(made('sales').length, 1)
  assert.equal(made('sales')[0].to, lower(FLY_PADS.testnet.v2))
} finally {
  server.close()
}

console.log('fly-pad3: ok')
