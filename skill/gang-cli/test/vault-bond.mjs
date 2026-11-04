/**
 * A token bound to a lock vault takes no GangBond: `gang bond post` refuses it (GangBond's report() slashes once the
 * creator's wallet holds less than the promised X, and a vault lock takes tokens out of that wallet). Run as the real
 * CLI against a local fake BSC testnet node that answers the pad's reads (kindOf, curves, vaultOf). No chain.
 *
 *   node skill/gang-cli/test/vault-bond.mjs
 */
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { createServer } from 'node:http'
import { decodeFunctionData, encodeAbiParameters, parseAbi, toFunctionSelector, zeroAddress } from 'viem'
import { GANG_GENS } from '../src/gangpad.js'

const PAD3 = GANG_GENS.testnet[0].pad
const t = (n) => `0x${String(n).padStart(40, '0')}`
const TOKEN = t(0x70), ME = t(0x71), VAULT = t(0x72), WBNB = '0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd'
const ABI = parseAbi([
  'function kindOf(address token) view returns (uint8)',
  'function curves(address token) view returns (address, address, uint128, uint128, uint128, uint128, bool, uint16, uint16, uint16, address, address)',
  'function vaultOf(address token) view returns (address)',
])
const SEL = Object.fromEntries(['kindOf', 'curves', 'vaultOf'].map((n) => [toFunctionSelector(ABI.find((x) => x.name === n)), n]))
const REVERT = { error: { code: 3, message: 'execution reverted', data: '0x' } }

// the node's answers for this run: vaultMode (vaultOf(0) answers 32 bytes), the token's vault, vaultOf(token) failing as the RPC
let world
const calls = []
const server = createServer((req, res) => {
  let raw = ''
  req.on('data', (c) => (raw += c))
  req.on('end', () => {
    const body = JSON.parse(raw)
    const one = (b) => {
      if (b.method === 'eth_chainId') return { result: '0x61' }
      if (b.method !== 'eth_call') return { error: { code: -32601, message: `unexpected ${b.method}` } }
      const { to, data } = b.params[0]
      const fn = SEL[data.slice(0, 10)]
      calls.push(fn ?? data.slice(0, 10))
      if (!fn) return { error: { code: -32000, message: 'not served by this fake node' } }
      const { args } = decodeFunctionData({ abi: ABI, data })
      const onPad3 = to.toLowerCase() === PAD3.toLowerCase()
      if (fn === 'kindOf') return { result: encodeAbiParameters([{ type: 'uint8' }], [onPad3 && args[0].toLowerCase() === TOKEN.toLowerCase() ? 1 : 0]) }
      if (fn === 'curves') {
        return { result: encodeAbiParameters(ABI[1].outputs, [ME, WBNB, 0n, 10n ** 24n, 6n * 10n ** 18n, 1n, false, 0, 0, 0, zeroAddress, zeroAddress]) }
      }
      // vaultOf
      if (!world.vaultMode) return REVERT
      if (args[0] === zeroAddress) return { result: encodeAbiParameters([{ type: 'address' }], [zeroAddress]) }
      if (world.vaultDown) return { error: { code: -32603, message: 'internal error' } }
      return { result: encodeAbiParameters([{ type: 'address' }], [world.vault ?? zeroAddress]) }
    }
    const answer = Array.isArray(body) ? body.map((b) => ({ jsonrpc: '2.0', id: b.id, ...one(b) })) : { jsonrpc: '2.0', id: body.id, ...one(body) }
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify(answer))
  })
})
await new Promise((r) => server.listen(0, '127.0.0.1', r))
const url = `http://127.0.0.1:${server.address().port}`

const gang = (...args) => new Promise((resolve) => {
  const p = spawn(process.execPath, [new URL('../src/index.js', import.meta.url).pathname, ...args], {
    env: { ...process.env, GANG_TESTNET_RPC_URL: url, GANG_UPDATE_CHECK: '0', GANG_TELEMETRY: '0', PATH: '' },
  })
  let out = ''
  p.stdout.on('data', (c) => (out += c))
  p.on('close', () => resolve(JSON.parse(out)))
})
const post = ['bond', 'post', '--token', TOKEN, '--hold', '1000', '--days', '7', '--amount', '0.01', '--testnet', '--from', ME, '--calldata']

try {
  // bound to a vault on a pad serving the vault mode: refused before any bond read, with the reason and the vault
  world = { vaultMode: true, vault: VAULT }
  calls.length = 0
  let r = await gang(...post)
  assert.equal(r.success, false)
  assert.match(r.error, /bound to a lock vault, so it takes no GangBond/)
  assert.match(r.error, /wallet balance drops below the promised holding/)
  assert.equal(r.vault, VAULT)
  assert.equal(r.padGen, '3.0')
  assert.ok(calls.includes('vaultOf'), 'asked the pad for the token\'s vault')

  // the token's vault unreadable (RPC): refused too, with a retry (never posted blind)
  world = { vaultMode: true, vault: VAULT, vaultDown: true }
  r = await gang(...post)
  assert.equal(r.success, false)
  assert.match(r.error, /could not read whether this token is bound to a lock vault/)
  assert.equal(r.retry, 'same command again')

  // no vault (3.0 token created without --vault), or a pad without the vault mode: the vault check lets it through
  // (this fake node then fails the bond's own reads; that the error is another one is what is checked)
  for (const w of [{ vaultMode: true, vault: null }, { vaultMode: false }]) {
    world = w
    calls.length = 0
    r = await gang(...post)
    assert.doesNotMatch(JSON.stringify(r), /lock vault/, JSON.stringify(w))
    assert.ok(calls.some((c) => !['kindOf', 'curves', 'vaultOf'].includes(c)), 'went on to the bond reads')
  }

  // the help says so, and so does the MCP instructions text
  const help = await new Promise((resolve) => {
    const p = spawn(process.execPath, [new URL('../src/index.js', import.meta.url).pathname, 'help'])
    let out = ''
    p.stdout.on('data', (c) => (out += c))
    p.on('close', () => resolve(out))
  })
  assert.match(help, /A token bound to a lock vault\s+\(gang create --vault\) is refused/)
  const { readFileSync } = await import('node:fs')
  assert.match(readFileSync(new URL('../src/mcp.js', import.meta.url), 'utf8'), /A token bound to a lock vault \(gang info → vault\) takes no bond: never suggest one/)
} finally {
  server.close()
}
console.log('vault-bond: ok')
