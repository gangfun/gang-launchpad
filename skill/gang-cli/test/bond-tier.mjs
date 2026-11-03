/**
 * The bond badge's anchored tier (bond.js): tierBps against the live / anchor dump values, and anchorOf against a local
 * fake gang.fun (mainnet only, the same round and GangBond, anything else → null so the tier falls back to live).
 *
 *   node skill/gang-cli/test/bond-tier.mjs
 */
import assert from 'node:assert/strict'
import { createServer } from 'node:http'

const seen = []
let answers = []
const server = createServer((req, res) => {
  seen.push(req.url)
  const [status, body] = answers.shift() ?? [500, null]
  res.writeHead(status, { 'content-type': 'application/json' }).end(body == null ? '' : JSON.stringify(body))
})
await new Promise((r) => server.listen(0, '127.0.0.1', r))
process.env.GANG_API = `http://127.0.0.1:${server.address().port}/api`
const { tierBps, anchorOf } = await import('../src/bond.js')
const E = 10n ** 18n
const MAX_UINT = 2n ** 256n - 1n
const bond = `0x${'b0'.repeat(20)}`, token = `0x${'AB'.repeat(20)}`
const ctx = { chainId: '56', bond }

try {
  // no anchor: the live coverage
  assert.equal(tierBps(1n * E, 1n * E, null), 10_000n)
  // the price doubled since the anchor: the tier stays at 100%, the live one would be 50%
  assert.equal(tierBps(1n * E, 2n * E, 1n * E), 10_000n)
  // the price fell below the anchor: the live (higher) coverage
  assert.equal(tierBps(1n * E, E / 2n, 1n * E), 20_000n)
  // a top-up after a rise raises the tier
  assert.equal(tierBps(3n * E / 2n, 2n * E, 1n * E), 15_000n)
  // X fetches nothing: as GangBond.coverageBps
  assert.equal(tierBps(1n * E, 0n, null), MAX_UINT)

  answers = [[200, { round: 2, bond, anchorDumpValue: String(4n * E) }]]
  assert.equal(await anchorOf(ctx, token, 2), 4n * E)
  assert.equal(seen.pop(), `/api/bonds/${token.toLowerCase()}`)

  // another round (a re-post gang.fun has not indexed yet), another GangBond, no anchor, 0, 404, 500: live tier
  for (const a of [
    [200, { round: 1, bond, anchorDumpValue: '1' }],
    [200, { round: 2, bond: `0x${'cc'.repeat(20)}`, anchorDumpValue: '1' }],
    [200, { round: 2, bond, anchorDumpValue: null }],
    [200, { round: 2, bond, anchorDumpValue: '0' }],
    [404, null],
    [500, null],
  ]) {
    answers = [a]
    assert.equal(await anchorOf(ctx, token, 2), null)
  }
  // a server from before the anchor fields: no bond field either → the round's own GangBond assumed, no anchor
  answers = [[200, { round: 2 }]]
  assert.equal(await anchorOf(ctx, token, 2), null)

  // testnet: gang.fun is not asked
  const n = seen.length
  assert.equal(await anchorOf({ chainId: '97', bond }, token, 2), null)
  assert.equal(seen.length, n)
  console.log('bond-tier: ok')
} finally {
  server.close()
}
