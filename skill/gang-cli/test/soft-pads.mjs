/**
 * Soft has two pads with one ABI, and a token resolves on whichever has its curve, as the real CLI meets them against a
 * local fake BSC: quotes, a buy and a sell's approve go to that pad, `gang list` names both, and a graduated token
 * (GANG is one) is priced from its pool and refused by `gang quote`. No chain.
 *
 *   node skill/gang-cli/test/soft-pads.mjs
 */
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { decodeFunctionData, encodeFunctionResult, parseAbi, toFunctionSelector, zeroAddress } from 'viem'

const t = (n) => `0x${String(n).padStart(40, '0')}`
const lower = (a) => a.toLowerCase()
const SOFT_FIRST = '0x315Ba2e8952D06094CC636b2B84229FA32fb23A7', SOFT_LATER = '0x4E6f13c8A453c1b8b4E20b590082bb233a5b80d7'
const ON_FIRST = t(0xa1), ON_LATER = t(0xa2), GRADUATED = t(0xa3), NOWHERE = t(0xa4), CREATOR = t(0xa5), PAIR = t(0xa6), ME = t(0xa7)
const TOKENS_OF = { [lower(SOFT_FIRST)]: [ON_FIRST, GRADUATED], [lower(SOFT_LATER)]: [ON_LATER] }
const E18 = 10n ** 18n

const ABI = parseAbi([
  'function curves(address token) view returns (address creator, uint128 realBnb, uint128 sold, bool graduated, address pair)',
  'function quoteBuy(address token, address buyer, uint256 bnbGross) view returns (uint256, uint256, uint256, uint256)',
  'function quoteSell(address token, uint256 tokensIn) view returns (uint256, uint256)',
  'function spotPrice(address token) view returns (uint256)',
  'function tokenCount() view returns (uint256)',
  'function allTokens(uint256) view returns (address)',
  'function isAgent(address) view returns (bool)',
  'function walletRoom(address, address) view returns (uint256)',
  'function MAX_PER_WALLET() view returns (uint256)',
  'function GRADUATION_BNB() view returns (uint256)',
  'function name() view returns (string)',
  'function symbol() view returns (string)',
  'function locked() view returns (bool)',
  'function balanceOf(address) view returns (uint256)',
  'function allowance(address, address) view returns (uint256)',
  'function getReserves() view returns (uint112, uint112, uint32)',
  'function token0() view returns (address)',
])
const SEL = new Map(ABI.map((x) => [toFunctionSelector(x), x.name]))

const answer = (to, data) => {
  const fn = SEL.get(data.slice(0, 10))
  if (!fn) return [false]
  const { args = [] } = decodeFunctionData({ abi: ABI, data })
  const onPad = TOKENS_OF[lower(to)]
  const ofToken = [ON_FIRST, ON_LATER, GRADUATED].includes(lower(to))
  const inPair = lower(to) === lower(PAIR)
  const value = {
    curves: () => (!onPad ? null
      : !onPad.includes(lower(args[0])) ? [zeroAddress, 0n, 0n, false, zeroAddress]
        : lower(args[0]) === GRADUATED ? [CREATOR, 0n, 8n * E18, true, PAIR] : [CREATOR, E18, 2n * E18, false, zeroAddress]),
    quoteBuy: () => (onPad ? [100n * E18, E18 / 100n, E18 / 10000n, 0n] : null),
    quoteSell: () => (onPad ? [E18 / 100n, E18 / 10000n] : null),
    spotPrice: () => (onPad ? 3n * 10n ** 10n : null),
    tokenCount: () => (onPad ? BigInt(onPad.length) : null),
    allTokens: () => (onPad ? onPad[Number(args[0])] : null),
    isAgent: () => (onPad ? true : null),
    walletRoom: () => (onPad ? E18 : null),
    MAX_PER_WALLET: () => (onPad ? E18 : null),
    GRADUATION_BNB: () => (onPad ? 20n * E18 : null),
    name: () => (ofToken ? 'Soft' : null),
    symbol: () => (ofToken ? 'SFT' : null),
    locked: () => (ofToken ? true : null),
    balanceOf: () => (ofToken ? 5n * E18 : null),
    allowance: () => (ofToken ? 0n : null),
    // 200 BNB against 40,000,000 tokens: 5e-6 BNB per token
    getReserves: () => (inPair ? [40_000_000n * E18, 200n * E18, 0] : null),
    token0: () => (inPair ? GRADUATED : null),
  }[fn]()
  if (value === null) return [false]
  return [true, encodeFunctionResult({ abi: ABI, functionName: fn, result: value })]
}
const server = createServer((req, res) => {
  let raw = ''
  req.on('data', (c) => (raw += c))
  req.on('end', () => {
    if (req.method !== 'POST') { // gang.fun's API, down here: the CLI goes on without its extras
      res.writeHead(503)
      return res.end()
    }
    const one = (b) => {
      if (b.method === 'eth_chainId') return { result: '0x38' }
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

// the wallet: its address, and every preview it is asked for, written down (from, to, value, data as passed)
const dir = mkdtempSync(join(tmpdir(), 'gang-soft-'))
const previews = join(dir, 'previews.txt')
writeFileSync(join(dir, 'baw'), `#!/bin/sh
case "$1 $2" in
  "wallet address") echo '{"success":true,"data":{"addresses":[{"binanceChainId":"56","address":"${ME}"}]}}' ;;
  *) echo "$@" >> "${previews}"; echo '{"success":true,"data":{"requestId":"r","gasLimit":"100000","simulation":{"success":true}}}' ;;
esac
`)
chmodSync(join(dir, 'baw'), 0o755)
const lastPreview = () => readFileSync(previews, 'utf8').trim().split('\n').at(-1)

const gang = (...args) => new Promise((resolve) => {
  const p = spawn(process.execPath, [new URL('../src/index.js', import.meta.url).pathname, ...args], {
    env: { ...process.env, GANG_RPC_URL: url, GANG_API: `${url}/api`, GANG_UPDATE_CHECK: '0', GANG_TELEMETRY: '0', HOME: dir, PATH: `${dir}:/bin:/usr/bin` },
  })
  let out = ''
  p.stdout.on('data', (c) => (out += c))
  p.on('close', () => resolve(JSON.parse(out)))
})

try {
  for (const [token, pad, name] of [[ON_FIRST, SOFT_FIRST, 'first'], [ON_LATER, SOFT_LATER, 'later']]) {
    const info = await gang('info', '--token', token)
    assert.equal(info.kind, 'soft', `${name} pad: kind`)
    assert.equal(lower(info.padAddress), lower(pad), `${name} pad: info`)
    assert.equal(info.priceBnb, 3e-8, `${name} pad: a curve's price is the pad's spotPrice`)

    const quote = await gang('quote', '--token', token, '--amount', '0.01')
    assert.equal(quote.success, true, `${name} pad: quote`)
    assert.equal(quote.tokensOut, '100', `${name} pad: the pad's quoteBuy`)

    await gang('buy', '--token', token, '--amount', '0.01')
    assert.match(lastPreview(), new RegExp(`--to ${pad}\\b`, 'i'), `${name} pad: the buy goes to it`)

    await gang('sell', '--token', token, '--amount', '1')
    const preview = lastPreview()
    assert.match(preview, new RegExp(`--to ${token}\\b`, 'i'), `${name} pad: a sell approves the token first`)
    const data = preview.match(/\s(0x095ea7b3[0-9a-f]+)/i)[1] // approve(address,uint256)
    const { args } = decodeFunctionData({ abi: parseAbi(['function approve(address, uint256)']), data })
    assert.equal(lower(args[0]), lower(pad), `${name} pad: the spender`)
  }

  const graduated = await gang('info', '--token', GRADUATED)
  assert.equal(graduated.graduated, true)
  assert.equal(graduated.priceBnb, 5e-6, "a graduated token's price comes from its pool")
  assert.equal(graduated.fdvBnb, 5000)
  assert.equal(graduated.raisedBnb, '20', 'it raised its whole target')
  assert.equal(graduated.progressPct, 100)
  assert.equal(graduated.walletCapTokens, null, 'the wallet cap is the curve\'s')
  const mine = await gang('status', '--token', GRADUATED)
  assert.equal(mine.myBalance, '5')
  assert.equal(mine.myRoomTokens, undefined, 'no room left to read after graduation')

  const refused = await gang('quote', '--token', GRADUATED, '--amount', '0.01')
  assert.equal(refused.success, false)
  assert.match(refused.error, /has graduated/, 'gang quote says why, not a raw revert')

  const nowhere = await gang('info', '--token', NOWHERE)
  assert.equal(nowhere.success, false)
  assert.match(nowhere.error, /not a Gang token/)

  const list = await gang('list', '--limit', '5')
  const soft = list.pads.filter((p) => p.pad === 'soft')
  assert.deepEqual(soft.map((p) => [lower(p.address), p.total]), [[lower(SOFT_FIRST), 2], [lower(SOFT_LATER), 1]], 'both pads, told apart')
  assert.deepEqual(new Set(list.tokens.map((r) => lower(r.token))), new Set([ON_FIRST, GRADUATED, ON_LATER]), 'the tokens of both')
} finally {
  server.close()
  rmSync(dir, { recursive: true, force: true })
}
console.log('soft-pads: ok')
