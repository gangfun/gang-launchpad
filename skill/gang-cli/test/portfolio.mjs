/**
 * gang portfolio (src/portfolio.js) over fake gang.fun answers and fake on-chain status reads: every kind and state, the
 * cost basis check, bonded holdings, USD, read errors. No chain, no network.
 *
 *   node skill/gang-cli/test/portfolio.mjs
 */
import assert from 'node:assert/strict'
import { portfolio, _test } from '../src/portfolio.js'

const W = '0x00000000000000000000000000000000000000AA'
const t = (n) => `0x${String(n).padStart(40, '0')}`
const pos = (n, track, status, extra = {}) => ({
  track, address: t(n), symbol: `T${n}`, quoteSymbol: 'BNB', quoteUsd: 600, costQuote: '1', avgPrice: '0.0000001',
  realizedQuote: '0', realizedUsd: 0, status, balance: status === 'curve' ? '1000' : null, balanceAtGrad: status === 'curve' ? null : '1000',
  ...(status === 'curve' && { priceQuote: '0.002' }), ...extra,
})

const positions = [
  pos(1, 'v3', 'curve'), // curve: 1000 × 0.002 = 2 BNB, cost 1 → +1
  pos(2, 'v3', 'graduated', { quoteSymbol: 'GANG', quoteUsd: 0.0027 }), // pool sell-all quote, dividend to claim
  pos(3, 'fair', 'curve'), // 打新 still minting: shares, worth withdrawing them
  pos(4, 'fair', 'graduated'), // launched, sold on PancakeSwap since: balance moved, reward left
  pos(5, 'stocks', 'curve', { quoteUsd: null, valueQuote: '2', valueUsd: '1200' }), // an older server: USD from valueUsd / valueQuote
  pos(6, 'main', 'graduated'), // graduated V2 / Soft: not priced
  pos(7, 'v3', 'curve'), // sold everything since: nothing left, dropped
  pos(8, 'v3', 'curve'), // the read fails
  pos(9, 'v3', 'graduated'), // bonded by this wallet
  pos(10, 'other', 'curve'), // unknown track: skipped
]
const chain = {
  [t(1)]: { graduated: false, balance: '1000', dividendPct: 0 },
  [t(2)]: { graduated: true, balance: '1000', dividendPct: 50, dividend: { claimable: '25' }, poolSellAll: { expectOut: '30000' } },
  [t(3)]: { sale: { launched: false }, position: { shares: 2, baselineTokens: '1000', sellBackAll: '0.95' } },
  [t(4)]: { sale: { launched: true }, position: { shares: 1, balance: '0', reward: 'out', pendingReward: '0.01', note: 'out for good' } },
  [t(5)]: { graduated: false, myBalance: '1,000', myBalanceRaw: (1000n * 10n ** 18n).toString() },
  [t(6)]: { graduated: true, myBalanceRaw: (1000n * 10n ** 18n).toString() },
  [t(7)]: { graduated: false, balance: '0', dividendPct: 0 },
  [t(9)]: { graduated: true, balance: '1000', dividendPct: 0, poolSellAll: { expectOut: '3' } },
}
const kinds = []
const statusOf = async (kind, token, wallet, p) => {
  kinds.push([kind, token, p.track])
  assert.equal(wallet, W)
  if (token === t(8)) throw new Error('RPC error while reading')
  return chain[token]
}
const launches = [
  { track: 'v3', address: t(9), symbol: 'T9' }, // active bond
  { track: 'fair', address: t(11), symbol: 'T11' }, // no bond
  { track: 'stocks', address: t(12), symbol: 'T12' }, // V2: bonds do not cover it, never asked
  { track: 'v3', address: t(13), symbol: 'T13' }, // bond read fails
]
const bondsAsked = []
const bondOf = async (token) => {
  bondsAsked.push(token)
  if (token === t(9)) return { state: 'active', bond: '1', quote: 'BNB', holdTokens: '600', creatorBalance: '1000', headroomTokens: '400.123456789', violated: false, phase: 'running', deadline: '2026-12-01T00:00:00.000Z' }
  if (token === t(13)) throw new Error('rpc down')
  return { state: 'none' }
}
const api = {
  [`/agents/${W.toLowerCase()}`]: { handle: 'me.ai', trade: { buys: 9, sells: 3, tokens: 10, volumeUsd: 120, realizedPnlUsd: -4.5, gradHits: 1 }, launch: { count: 4, graduated: 1 } },
  [`/agents/${W.toLowerCase()}/positions`]: { items: positions },
  [`/agents/${W.toLowerCase()}/launches?limit=100`]: { items: launches, hasMore: true },
}
const get = async (path) => (path in api ? api[path] : null)

const r = await portfolio({ wallet: W, get, statusOf, bondOf, concurrency: 3 })
const by = Object.fromEntries(r.holdings.map((h) => [h.symbol, h]))

// what was read: each indexed position once with its kind; bonds only on V3 / 打新 launches
assert.deepEqual(kinds.map(([k, tok]) => [k, tok]).sort(), [
  ['fair', t(3)], ['fair', t(4)], ['legacy', t(5)], ['legacy', t(6)], ['v3', t(1)], ['v3', t(2)], ['v3', t(7)], ['v3', t(8)], ['v3', t(9)],
].sort())
assert.deepEqual(bondsAsked.sort(), [t(9), t(11), t(13)].sort())

assert.equal(r.success, true)
assert.equal(r.handle, 'me.ai')
assert.deepEqual(Object.keys(by).sort(), ['T1', 'T2', 'T3', 'T4', 'T5', 'T6', 'T9'])

// V3 on the curve: last price, cost comparable
assert.deepEqual([by.T1.status, by.T1.balance, by.T1.value, by.T1.valueUsd, by.T1.unrealized, by.T1.unrealizedUsd], ['curve', 1000, 2, 1200, 1, 600])
assert.match(by.T1.valueBasis, /curve price/)
assert.deepEqual(by.T1.next, [`gang sell --token ${t(1)} --all`])
// V3 graduated: the pool sell-all quote, its own quote's USD, dividend to claim
assert.deepEqual([by.T2.status, by.T2.value, by.T2.valueUsd, by.T2.claimable, by.T2.claimableUsd], ['graduated', 30000, 81, 25, 0.07])
assert.deepEqual(by.T2.next, [`gang sell --token ${t(2)} --all`, `gang claim --token ${t(2)}`])
// 打新 minting: shares, worth withdrawing them all; next is withdraw
assert.deepEqual([by.T3.status, by.T3.shares, by.T3.balance, by.T3.value, by.T3.unrealized], ['minting', 2, 1000, 0.95, -0.05])
assert.deepEqual(by.T3.next, [`gang withdraw --token ${t(3)} --all`])
// 打新 launched and sold since: kept for its reward, cost no longer comparable
assert.deepEqual([by.T4.status, by.T4.balance, by.T4.value, by.T4.claimable, by.T4.reward, by.T4.unrealized], ['launched', 0, 0, 0.01, 'out', null])
assert.match(by.T4.costNote, /moved outside/)
assert.deepEqual(by.T4.next, [`gang claim --token ${t(4)}`])
// V2 / Soft on the curve: balance from the raw wei (myBalance has separators), USD from an older server's valueUsd / valueQuote
assert.deepEqual([by.T5.kind, by.T5.balance, by.T5.value, by.T5.quoteUsd, by.T5.valueUsd], ['legacy', 1000, 2, 600, 1200])
// graduated V2 / Soft: not priced, says how to price it
assert.deepEqual([by.T6.value, by.T6.valueUsd], [null, null])
assert.match(by.T6.valueNote, /gang sell --token/)
// bonded: how much can go keeping the bond (the bond's exact headroom), and next sells at most that
assert.deepEqual([by.T9.bonded.holdTokens, by.T9.bonded.sellableKeepingBond], [600, 400.123456789])
assert.deepEqual(by.T9.next, [`gang sell --token ${t(9)} --amount 400.123456789`, `gang bond status --token ${t(9)}`])
// broken (balance below X) or no headroom: no sell offered
{
  const h = _test.holdingOf(pos(20, 'v3', 'curve'), 'v3', { graduated: false, balance: '1000', dividendPct: 0 })
  for (const headroomTokens of ['-5', '0']) {
    const b = _test.withBond(h, { holdTokens: '1005', headroomTokens })
    assert.deepEqual([b.bonded.sellableKeepingBond, b.next], [0, [`gang bond status --token ${t(20)}`]])
  }
}
// balances stay as read (an agent may sell them), values are rounded for display
{
  const h = _test.holdingOf(pos(21, 'v3', 'curve', { priceQuote: '0.00000123456789' }), 'v3', { graduated: false, balance: '9548786.474360156', dividendPct: 0 })
  assert.deepEqual([h.balance, h.value], [9548786.474360156, 11.7886])
}

// sorted by USD value, unpriced last
assert.equal(r.holdings.at(-1).symbol, 'T6')
assert.ok(r.holdings.slice(0, -1).every((h, i, a) => i === 0 || a[i - 1].valueUsd >= h.valueUsd))
// totals: only priced holdings in valueUsd, and it says how many were left out
assert.equal(r.totals.holdings, 7)
assert.equal(r.totals.unpriced, 1)
assert.equal(r.totals.valueUsd, Math.round(r.holdings.reduce((s, h) => s + (h.valueUsd ?? 0), 0) * 100) / 100)
assert.equal(r.totals.claimableUsd, 6.07)
// record from the profile; bonds: the active one only, and the launches page was cut
assert.deepEqual(r.record, { buys: 9, sells: 3, tokensTraded: 10, volumeUsd: 120, realizedPnlUsd: -4.5, gradHits: 1, launches: 4, launchesGraduated: 1 })
assert.deepEqual(r.bonds.map((b) => [b.symbol, b.state, b.holdTokens]), [['T9', 'active', '600']])
assert.match(r.bondsNote, /newest 100/)
// read errors are listed, not fatal
assert.deepEqual(r.errors.map((e) => e.symbol).sort(), ['T13', 'T8'])
assert.match(r.errors.find((e) => e.symbol === 'T13').error, /^bond: rpc down/)

// an empty wallet: no holdings, no bonds, zero totals; no launches answer (an older server) is fine
{
  const empty = await portfolio({
    wallet: W, statusOf, bondOf,
    get: async (path) => (path.endsWith('/positions') ? { items: [] } : null),
  })
  assert.deepEqual([empty.holdings, empty.bonds, empty.totals.valueUsd, empty.handle], [[], [], 0, null])
  assert.equal(empty.errors, undefined)
}
// a server without the positions route fails clearly
await assert.rejects(portfolio({ wallet: W, statusOf, bondOf, get: async () => null }), /no positions/)

// mapLimit keeps order and never runs more than the limit at once
{
  let running = 0, peak = 0
  const out = await _test.mapLimit([5, 1, 4, 2, 3], 2, async (x) => {
    peak = Math.max(peak, ++running)
    await new Promise((res) => setTimeout(res, x * 5))
    running--
    return x * 10
  })
  assert.deepEqual(out, [50, 10, 40, 20, 30])
  assert.equal(peak, 2)
}
console.log('portfolio: ok')
