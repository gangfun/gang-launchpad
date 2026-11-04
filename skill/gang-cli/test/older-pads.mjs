/**
 * Older and closed pads, as the real CLI meets them with 3.0 as the create target, against a local fake BSC testnet node.
 * `gang combo status --module` reads graduation on the module's own pad: 3.0 answers curves() of an older token with zeros,
 * which would read as "not graduated". A create on a pad its token deployer no longer lists says that it stopped creating.
 * No chain.
 *
 *   node skill/gang-cli/test/older-pads.mjs
 */
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { createServer } from 'node:http'
import { decodeFunctionData, encodeErrorResult, encodeFunctionResult, parseAbi, stringToHex, toFunctionSelector, zeroAddress } from 'viem'
import { FLY_PAD_V2_ABI } from '../src/fly.js'
import { GANG_GENS, PAD3_GEN } from '../src/gangpad.js'

const t = (n) => `0x${String(n).padStart(40, '0')}`
const lower = (a) => a.toLowerCase()
const PAD3 = GANG_GENS.testnet.find((g) => g.gen === PAD3_GEN).pad
const PAD2 = GANG_GENS.testnet.find((g) => g.gen === '2.0').pad
const PAD1 = GANG_GENS.testnet.find((g) => g.gen === '1.0').pad
const WBNB = '0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd'
const ME = t(0x71), MODULE = t(0x72), TOKEN = t(0x73), OTHER = t(0x74)
const ONLY_LAUNCHPAD = encodeErrorResult({ abi: parseAbi(['error OnlyLaunchpad()']), errorName: 'OnlyLaunchpad' })

const ABI = [
  ...parseAbi([
    'function pad() view returns (address)',
    'function moduleType() view returns (bytes32)',
    'function dev() view returns (address)',
    'function token() view returns (address)',
    'function quote() view returns (address)',
    'function gangQuote() view returns (address)',
    'function buybackBps() view returns (uint16)',
    'function lpBps() view returns (uint16)',
    'function payeesOf() view returns (address[] payees, uint16[] shares)',
    'function buybackLeft() view returns (uint256)',
    'function lpLeft() view returns (uint256)',
    'function unsplit() view returns (uint256)',
    'function lastChunkAt() view returns (uint64)',
    'function lastPaidAt() view returns (uint64)',
    'function previewChunk() view returns (bool, bool, uint256, uint256)',
    'function previewWork() view returns (bool, uint256)',
    'function keeperServes(address q) view returns (bool)',
    'function undistributed(address asset) view returns (uint256)',
    'function owedTotal(address asset) view returns (uint256)',
    'function symbol() view returns (string)',
    'function decimals() view returns (uint8)',
    'function kindOf(address token) view returns (uint8)',
    'function curves(address token) view returns (address, address, uint128, uint128, uint128, uint128, bool, uint16, uint16, uint16, address, address)',
    // creates
    'function checkConfig((uint256 raiseBnb, uint16 capBps, uint16 holdBps, uint16 mintFeeBps, uint16 exitFeeBps) cfg, uint256 devShares) pure returns (bool, string)',
    'function previewCreate(address quote, address refPool, uint256 raiseBnb) view returns (uint256, uint256)',
    'function create(string name, string symbol, string logoURI, string metaURI, address quote, address refPool, (uint256 raiseBnb, uint16 capBps, uint16 holdBps, uint16 mintFeeBps, uint16 exitFeeBps) cfg, uint256 devShares) returns (address)',
    'function balanceOf(address) view returns (uint256)',
    'function allowance(address, address) view returns (uint256)',
    'function migrator() view returns (address)',
    'function agentGateEnabled() view returns (bool)',
  ]),
  ...FLY_PAD_V2_ABI.filter((x) => x.type === 'function' && (x.name === 'create' || x.name === 'checkConfig')),
]
const SEL = new Map(ABI.filter((x) => x.type === 'function').map((x) => [toFunctionSelector(x), x.name]))

// this run's chain: world.onPad = the pad holding TOKEN (kind 1), world.graduated, world.modulePad = pad() of MODULE
let world
const calls = []
const answer = (to, data) => {
  const fn = SEL.get(data.slice(0, 10))
  calls.push({ fn: fn ?? data.slice(0, 10), to: lower(to) })
  if (!fn) return [false]
  if (fn === 'create') return [false, ONLY_LAUNCHPAD]
  const { args } = decodeFunctionData({ abi: ABI, data })
  const isToken = (a) => lower(a) === lower(TOKEN)
  const onThisPad = world.onPad && lower(to) === lower(world.onPad)
  const value = {
    pad: () => (world.modulePad ?? null),
    moduleType: () => stringToHex('combo-v1', { size: 32 }),
    dev: () => ME,
    token: () => TOKEN,
    quote: () => WBNB,
    gangQuote: () => zeroAddress,
    buybackBps: () => 3_000,
    lpBps: () => 3_000,
    payeesOf: () => [[ME], [10_000]],
    buybackLeft: () => 10n ** 18n,
    lpLeft: () => 0n,
    unsplit: () => 0n,
    lastChunkAt: () => 0n,
    lastPaidAt: () => 0n,
    previewChunk: () => [false, false, 0n, 0n],
    previewWork: () => [false, 0n],
    keeperServes: () => false,
    undistributed: () => 0n,
    owedTotal: () => 0n,
    symbol: () => 'SYM',
    decimals: () => 18,
    kindOf: () => (onThisPad && isToken(args[0]) ? 1 : 0),
    // what any pad answers for a token that is not its own: all zeros, so not graduated
    curves: () => (onThisPad && isToken(args[0])
      ? [ME, WBNB, 0n, 0n, 0n, 0n, world.graduated, 0, 0, 0, world.graduated ? t(0x75) : zeroAddress, zeroAddress]
      : [zeroAddress, zeroAddress, 0n, 0n, 0n, 0n, false, 0, 0, 0, zeroAddress, zeroAddress]),
    checkConfig: () => [true, ''],
    previewCreate: () => [15n * 10n ** 18n, 15n * 10n ** 14n],
    balanceOf: () => 10n ** 21n,
    allowance: () => 2n ** 200n,
    migrator: () => t(0x76),
    agentGateEnabled: () => true,
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
      if (b.method !== 'eth_call') return { error: { code: -32601, message: `unexpected ${b.method}` } }
      const [ok, hex] = answer(b.params[0].to, b.params[0].data)
      return ok ? { result: hex } : { error: { code: 3, message: 'execution reverted', data: hex ?? '0x' } }
    }
    const body = JSON.parse(raw)
    const reply = Array.isArray(body) ? body.map((b) => ({ jsonrpc: '2.0', id: b.id, ...one(b) })) : { jsonrpc: '2.0', id: body.id, ...one(body) }
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify(reply))
  })
})
await new Promise((r) => server.listen(0, '127.0.0.1', r))
const url = `http://127.0.0.1:${server.address().port}`

const gang = (env, ...args) => new Promise((resolve) => {
  calls.length = 0
  const p = spawn(process.execPath, [new URL('../src/index.js', import.meta.url).pathname, ...args, '--testnet'], {
    env: { ...process.env, GANG_TESTNET_RPC_URL: url, GANG_UPDATE_CHECK: '0', GANG_TELEMETRY: '0', PATH: '', ...env },
  })
  let out = ''
  p.stdout.on('data', (c) => (out += c))
  p.on('close', () => resolve(JSON.parse(out)))
})
const status = () => gang({}, 'combo', 'status', '--module', MODULE)
const NOT_GRADUATED = /has not graduated/
const curvesAsked = () => calls.filter((c) => c.fn === 'curves').map((c) => c.to)

try {
  // ---- gang combo status --module: a graduated token of an older generation
  for (const pad of [PAD2, PAD1]) {
    world = { onPad: pad, modulePad: pad, graduated: true }
    const r = await status()
    assert.equal(r.success, true, JSON.stringify(r))
    assert.doesNotMatch(JSON.stringify(r), NOT_GRADUATED, pad)
    assert.deepEqual(curvesAsked(), [lower(pad)], 'read on the module\'s own pad, not on 3.0')
  }
  // still on the curve: said, whichever generation
  for (const pad of [PAD3, PAD2]) {
    world = { onPad: pad, modulePad: pad, graduated: false }
    assert.match(JSON.stringify(await status()), NOT_GRADUATED, pad)
    assert.deepEqual(curvesAsked(), [lower(pad)])
  }
  // a graduated 3.0 token, the create target
  world = { onPad: PAD3, modulePad: PAD3, graduated: true }
  assert.doesNotMatch(JSON.stringify(await status()), NOT_GRADUATED)
  // a pad this CLI does not know: graduation unread, so nothing is said about it (never a guess from another pad)
  world = { onPad: OTHER, modulePad: OTHER, graduated: true }
  let r = await status()
  assert.equal(r.success, true)
  assert.doesNotMatch(JSON.stringify(r), NOT_GRADUATED)
  assert.deepEqual(curvesAsked(), [])
  // pad() unreadable: the same, graduation unread
  world = { onPad: PAD2, modulePad: null, graduated: true }
  r = await status()
  assert.equal(r.success, true)
  assert.doesNotMatch(JSON.stringify(r), NOT_GRADUATED)
  assert.deepEqual(curvesAsked(), [])

  // ---- a create on a pad its token deployer no longer lists
  const PIN = { GANG_TESTNET_PAD: PAD2 }
  world = {}
  r = await gang(PIN, 'create', '--fair', '--name', 'A', '--symbol', 'A', '--from', ME, '--calldata')
  assert.deepEqual([r.success, r.step, r.error], [false, 'create', 'OnlyLaunchpad'], JSON.stringify(r))
  assert.match(r.hint, /stopped creating/)
  assert.match(r.hint, /GANG_PAD/)
  assert.ok(calls.some((c) => c.fn === 'create' && c.to === lower(PAD2)), 'the pinned pad was the one asked')
  // 铸币飞轮, had 3.0's deployer delisted it: the same answer
  r = await gang({}, 'create', '--fly', '--name', 'A', '--symbol', 'A', '--from', ME, '--calldata')
  assert.deepEqual([r.success, r.step, r.error], [false, 'create', 'OnlyLaunchpad'], JSON.stringify(r))
  assert.match(r.hint, /stopped creating/)
} finally {
  server.close()
}
console.log('older-pads: ok')
