/**
 * Soft has two pads with one ABI: the first holds the Soft tokens, the later one holds none. A token resolves on
 * whichever has its curve, and its quote is read from that pad, against a local fake BSC. No chain.
 *
 *   node skill/gang-cli/test/soft-pads.mjs
 */
import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { decodeFunctionData, encodeFunctionResult, parseAbi, toFunctionSelector, zeroAddress } from 'viem'

const t = (n) => `0x${String(n).padStart(40, '0')}`
const lower = (a) => a.toLowerCase()
const ON_FIRST = t(0xa1), ON_LATER = t(0xa2), NOWHERE = t(0xa3), CREATOR = t(0xa4)

const ABI = parseAbi([
  'function curves(address token) view returns (address creator, uint128 realBnb, uint128 sold, bool graduated, address pair)',
  'function quoteSell(address token, uint256 tokensIn) view returns (uint256, uint256)',
])
const SEL = new Map(ABI.map((x) => [toFunctionSelector(x), x.name]))
const FIRST = '0x315Ba2e8952D06094CC636b2B84229FA32fb23A7', LATER = '0x4E6f13c8A453c1b8b4E20b590082bb233a5b80d7'
const pads = { [lower(FIRST)]: ON_FIRST, [lower(LATER)]: ON_LATER }

const seen = []
const answer = (to, data) => {
  const fn = SEL.get(data.slice(0, 10))
  const own = pads[lower(to)]
  if (!fn || !own) return [false]
  const { args } = decodeFunctionData({ abi: ABI, data })
  seen.push({ fn, to: lower(to) })
  if (fn === 'quoteSell') return [true, encodeFunctionResult({ abi: ABI, functionName: fn, result: [99n, 1n] })]
  const mine = lower(args[0]) === lower(own)
  return [true, encodeFunctionResult({
    abi: ABI,
    functionName: fn,
    result: mine ? [CREATOR, 1n, 2n, false, zeroAddress] : [zeroAddress, 0n, 0n, false, zeroAddress],
  })]
}
const server = createServer((req, res) => {
  let raw = ''
  req.on('data', (c) => (raw += c))
  req.on('end', () => {
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

// chain.js builds its client on load, so the fake RPC goes in first
process.env.GANG_RPC_URL = url
process.env.GANG_UPDATE_CHECK = '0'
const { resolvePad, quoteSell } = await import('../src/chain.js')

for (const [token, pad, name] of [[ON_FIRST, FIRST, 'first'], [ON_LATER, LATER, 'later']]) {
  const r = await resolvePad(token)
  assert.equal(r.kind, 'soft', `${name} pad: kind`)
  assert.equal(lower(r.address), lower(pad), `${name} pad: resolved`)
  seen.length = 0
  const q = await quoteSell(token, 100n)
  assert.equal(lower(q.padAddress), lower(pad), `${name} pad: the quote names it`)
  assert.equal(q.out, 99n, `${name} pad: the quote`)
  assert.ok(seen.some((c) => c.fn === 'quoteSell' && c.to === lower(pad)), `${name} pad: the quote is read from it`)
}
await assert.rejects(resolvePad(NOWHERE), /not a Gang token/, 'a token on neither')

server.close()
console.log('soft-pads: ok')
process.exit(0)
