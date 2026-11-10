import assert from 'node:assert/strict'
import {
  ONE,
  readFollowRef,
  callerBalances,
  violationBlock,
  followBuys,
  endOfBlockPrices,
  priceAverage,
  pairPrice,
  curvePrice,
  checkSoldChain,
  allocate,
  sellsBetween,
  exitsOf,
  exitCredit,
  spotLookup,
  checkVaultInflows,
  vaultNet,
  priceLookup,
  forwardBalances,
  checkPadFlows,
  lastAtOrBefore,
  leafHash,
  buildTree,
  verify,
  compareRoot,
  EMPTY_ROOT,
} from './lib.mjs'
import { settle, SettleError, bondAbi } from './settle.mjs'
import { getAddress, encodeFunctionResult } from 'viem'

const tests = []
const test = (name, fn) => tests.push([name, fn])

const NOTE = '0x' + 'ab'.repeat(32)
const OTHER_NOTE = '0x' + 'cd'.repeat(32)
const CALLDATA = '0x7deb6025' + '00'.repeat(96)
const FOLLOW = (tx) => '67616e6703' + tx.slice(2)
const NOTE_V1 = '67616e6701' + '11'.repeat(32)
const NOTE_V2 = '67616e6702' + (6 * 3600).toString(16).padStart(8, '0') + '22'.repeat(32)
const TOOL = '67616e6706' + Buffer.from('agent', 'ascii').toString('hex').padEnd(24, '0')
const REF = '67616e6705' + '33'.repeat(20)

// ---------------------------------------------------------------- the follow ref
test('follow ref', () => {
  assert.equal(readFollowRef(CALLDATA + FOLLOW(NOTE)), NOTE, 'last 37 bytes without a note')
  assert.equal(readFollowRef(CALLDATA + TOOL + REF + FOLLOW(NOTE) + NOTE_V1), NOTE, 'right before a v1 note')
  assert.equal(readFollowRef(CALLDATA + FOLLOW(NOTE) + NOTE_V2), NOTE, 'right before a v2 note')
  assert.equal(readFollowRef((CALLDATA + FOLLOW(NOTE)).toUpperCase().replace('0X', '0x')), NOTE, 'any case')
  assert.equal(readFollowRef(CALLDATA + FOLLOW(NOTE) + '00'), null, 'anywhere else does not count')
  assert.equal(readFollowRef(CALLDATA + FOLLOW(NOTE) + REF), null, 'a ref after the follow ref does not count')
  assert.equal(readFollowRef(CALLDATA), null)
  assert.equal(readFollowRef(CALLDATA + NOTE_V1), null)
})

// ---------------------------------------------------------------- B
const HOLD = 1000n
const tr = (blockNumber, logIndex, delta) => ({ blockNumber, logIndex, delta })
const bOf = (p) => {
  const bal = callerBalances(p)
  return { B: violationBlock({ endOf: bal.endOf, changes: bal.changes, hold: HOLD, reportBlock: p.reportBlock, postBlock: p.postBlock }), bal }
}

test('B: the start of the below-hold run holding R, end-of-block balances only', () => {
  // post in 100 with 1000 = hold
  const transfers = [
    tr(105n, 1, -1n), tr(105n, 2, 1n), // a dip and back in one block: not a violation
    tr(108n, 1, -999n), tr(108n, 4, 999n), // a 1-wei-of-hold dip inside one tx/block: not either
    tr(110n, 3, -500n), // below hold from 110 …
    tr(112n, 0, 500n), // … back at hold at the end of 112
    tr(115n, 7, -600n), // below from 115: the run the report is in
    tr(116n, 2, 600n), tr(116n, 3, -600n), // back and down again inside 116: still below at its end
    tr(118n, 1, 100n), // still below
    tr(120n, 1, -10n), // in R, before the report
    tr(120n, 9, 10n), // in R, after the report: ignored
  ]
  const p = { reportBalance: 490n, reportBlock: 120n, reportLogIndex: 5, postBlock: 100n, postLogIndex: 2, transfers }
  const { B, bal } = bOf(p)
  assert.equal(B, 115n)
  assert.equal(bal.endOf(119n), 500n)
  assert.equal(bal.endOf(115n), 400n)
  assert.equal(bal.endOf(114n), 1000n)
  assert.equal(bal.endOf(110n), 500n)
  assert.equal(bal.endOf(105n), 1000n)
  assert.equal(bal.atPost, 1000n)
})

test('B = R when R − 1 ended at hold', () => {
  const p = { reportBalance: 900n, reportBlock: 50n, reportLogIndex: 4, postBlock: 40n, postLogIndex: 0, transfers: [tr(50n, 1, -100n)] }
  assert.equal(bOf(p).B, 50n)
})

test('B never before the post block', () => {
  // bought in the post block before posting, sold below hold after it in the same block
  const p = { reportBalance: 10n, reportBlock: 60n, reportLogIndex: 0, postBlock: 40n, postLogIndex: 5, transfers: [tr(40n, 2, 1000n), tr(40n, 8, -990n)] }
  const { B, bal } = bOf(p)
  assert.equal(B, 40n)
  assert.equal(bal.atPost, 1000n)
  assert.equal(bal.endOf(39n), 0n, 'below hold before the post: B stays at the post block')
  assert.equal(bal.endOf(40n), 10n)
})

test('missing transfer logs show up', () => {
  // a sale is missing: rebuilding back from the report goes negative
  const p = { reportBalance: 0n, reportBlock: 60n, reportLogIndex: 0, postBlock: 40n, postLogIndex: 5, transfers: [tr(45n, 1, 1000n)] }
  assert.throws(() => callerBalances(p), /incomplete/)
  assert.throws(() => callerBalances({ ...p, transfers: [tr(61n, 0, 1n)] }), /outside/)
})

// ---------------------------------------------------------------- followers
const CALLER = '0x00000000000000000000000000000000000000c0'
const TOKEN = '0x00000000000000000000000000000000000000a1'
const TOKEN2 = '0x00000000000000000000000000000000000000a2'
const PAD = '0x0000000000000000000000000000000000000bad'
const PAIR = '0x0000000000000000000000000000000000000a1a'
const VAULT = '0x00000000000000000000000000000000000007a0'
const MIGRATOR = '0x00000000000000000000000000000000000003a0'
const ZERO = '0x0000000000000000000000000000000000000000'
const F = (i) => `0x${(0xf0 + i).toString(16).padStart(40, '0')}`
const MIN = 2n * 10n ** 15n
const followCase = () => {
  const trades = []
  const txs = new Map()
  const add = (hash, from, input, block, list) => {
    txs.set(hash, { from, input })
    list.forEach((t, i) => trades.push({ transactionHash: hash, blockNumber: block, logIndex: i, token: TOKEN, trader: from, isBuy: true, ...t }))
  }
  const follow = CALLDATA + FOLLOW(NOTE)
  add('0x01', F(1), follow, 120n, [{ quoteAmount: MIN, tokenAmount: 1000n }])
  add('0x02', F(1), follow + NOTE_V1, 130n, [{ quoteAmount: 3n * 10n ** 15n, tokenAmount: 1000n }]) // F1's second follow
  add('0x03', CALLER, follow, 121n, [{ quoteAmount: MIN, tokenAmount: 1000n }]) // the caller following itself
  add('0x04', F(2), follow, 122n, [{ quoteAmount: MIN - 1n, tokenAmount: 1000n }]) // under the minimum
  add('0x05', F(3), follow, 150n, [{ quoteAmount: MIN, tokenAmount: 1000n }]) // in B
  add('0x06', F(4), follow, 100n, [{ quoteAmount: MIN, tokenAmount: 1000n }]) // in the note's block
  add('0x07', F(5), follow, 123n, [{ quoteAmount: MIN, tokenAmount: 1000n, trader: F(9) }]) // trader is not tx.from
  add('0x08', F(6), follow, 124n, [{ quoteAmount: MIN / 2n, tokenAmount: 500n }, { quoteAmount: MIN / 2n, tokenAmount: 500n }]) // two buys in one tx
  add('0x09', F(7), CALLDATA + FOLLOW(OTHER_NOTE), 125n, [{ quoteAmount: MIN, tokenAmount: 1000n }]) // another note
  add('0x0a', F(8), follow, 126n, [{ quoteAmount: MIN, tokenAmount: 1000n, token: TOKEN2 }, { quoteAmount: MIN, tokenAmount: 1000n, isBuy: false }]) // another token, a sell
  add('0x0b', F(10), follow + '00', 127n, [{ quoteAmount: MIN, tokenAmount: 1000n }]) // the ref in the wrong place
  add('0x0c', F(11), follow, 141n, [{ quoteAmount: MIN, tokenAmount: 1000n }]) // after the 24 h when it ends at 140
  add('0x0d', F(12), follow, 128n, [{ quoteAmount: MIN, tokenAmount: 1000n }, { quoteAmount: MIN, tokenAmount: 7n, trader: F(9) }]) // only its own buy counts
  return { trades, txOf: (h) => txs.get(h), noteTx: NOTE.toUpperCase().replace('0X', '0x'), noteBlock: 100n, followEndBlock: 200n, B: 150n, caller: CALLER, token: TOKEN, minQuote: MIN }
}

test('follower filtering', () => {
  const c = followCase()
  const f = followBuys(c)
  assert.deepEqual([...f.keys()].sort(), [F(1), F(6), F(11), F(12)].sort())
  assert.equal(f.get(F(1)).quote, 5n * 10n ** 15n, 'two follows of one address add up')
  assert.equal(f.get(F(1)).tokens, 2000n)
  assert.deepEqual(f.get(F(1)).txs, ['0x01', '0x02'])
  assert.equal(f.get(F(1)).firstBlock, 120n, 'F_i: the block of its first follow buy')
  assert.equal(f.get(F(6)).quote, MIN, "a tx's buys add up before the minimum")
  assert.equal(f.get(F(12)).tokens, 1000n)
  // the follow window ends with the note's time + 24 h
  assert.ok(!followBuys({ ...c, followEndBlock: 140n }).has(F(11)))
  // a later B lets the follow in B count
  assert.ok(followBuys({ ...c, B: 151n }).has(F(3)))
  // a tx the node doesn't know stops the run
  assert.throws(() => followBuys({ ...c, txOf: () => undefined }), /no transaction/)
})

// ---------------------------------------------------------------- P_ref
test('P_ref: per second, several blocks a second, the last block of a second counts', () => {
  const ev = (blockNumber, logIndex, price) => ({ blockNumber, logIndex, price })
  const blocks = endOfBlockPrices([ev(11n, 3, 120n), ev(10n, 1, 105n), ev(10n, 7, 110n), ev(12n, 0, 130n), ev(13n, 0, 140n), ev(14n, 0, 200n), ev(15n, 0, 999n)])
  assert.deepEqual(blocks.map((b) => b.price), [110n, 120n, 130n, 140n, 200n, 999n], 'the last trade of each block')
  const ts = { 10: 1000n, 11: 1000n, 12: 1001n, 13: 1001n, 14: 1005n, 15: 1010n }
  const points = blocks.map((b) => ({ timestamp: ts[Number(b.blockNumber)], price: b.price }))
  const { sum, pRef } = priceAverage({ seed: 100n, points, start: 1000n, len: 10n })
  // s = 1000: 120 (two blocks that second), 1001–1004: 140, 1005–1009: 200; block 15 (1010) is past the window
  assert.equal(sum, 120n + 4n * 140n + 5n * 200n)
  assert.equal(pRef, 168n)
  // nothing traded in the window: the price before it all along
  assert.equal(priceAverage({ seed: 77n, points: [], start: 0n }).pRef, 77n)
  // a trade later in the window, rounding down
  const r = priceAverage({ seed: 10n, points: [{ timestamp: 3599n, price: 11n }], start: 0n })
  assert.equal(r.sum, 10n * 3599n + 11n)
  assert.equal(r.pRef, 10n)
  assert.throws(() => priceAverage({ seed: 1n, points: [{ timestamp: 5n, price: 1n }, { timestamp: 4n, price: 1n }], start: 0n }), /order/)
})

test('prices from the pair and the curve', () => {
  assert.equal(pairPrice(2n * ONE, 6n * ONE, true), 3n * ONE, 'token is token0: quote / token')
  assert.equal(pairPrice(6n * ONE, 2n * ONE, false), 3n * ONE)
  assert.equal(curvePrice({ virtualQuote: 3n, realQuote: 1n, sold: 2n }, 10n), (4n * ONE) / 8n)
})

test('the TradeV1 sold chain', () => {
  const t = (logIndex, isBuy, tokenAmount, sold) => ({ transactionHash: '0x', blockNumber: 1n, logIndex, isBuy, tokenAmount, sold })
  const trades = [t(2, false, 30n, 170n), t(1, true, 100n, 200n)]
  checkSoldChain(trades, 100n, 170n)
  assert.throws(() => checkSoldChain([trades[0]], 100n, 170n), /incomplete/, 'a missing buy')
  assert.throws(() => checkSoldChain(trades, 100n, 171n), /incomplete/, 'a missing last trade')
  checkSoldChain([], 5n, 5n)
  assert.throws(() => checkSoldChain([], 5n, 6n), /incomplete/, 'logs returned empty')
})

// ---------------------------------------------------------------- losses and payouts
// followers as followBuys gives them; `bal`: { account: [at F_i, at B] }; `sold`: { account: what its sells got }
const fol = (entries) => new Map(entries.map(([a, quote, tokens, firstBlock = 1n]) => [a, { quote, tokens, firstBlock }]))
const alloc = (followers, bal, sold, pRef, pool = 10n ** 40n) =>
  allocate({ followers, balanceAtF: (a) => bal[a][0], balanceAtB: (a) => bal[a][1], soldQuote: (a) => sold[a] ?? 0n, pRef, pool })

test('losses: C_i − e_i × P_ref', () => {
  // F1 paid 200 for 100 tokens and holds them: 200 − 100 × 1.5 = 50
  // F2 paid 300 for 100 but sold 60 of them (for 120) before B: C = 180, e = 40 → 180 − 60 = 120
  // F3 bought at P_ref: no loss
  const followers = fol([[F(1), 200n * ONE, 100n * ONE], [F(2), 300n * ONE, 100n * ONE], [F(3), 150n * ONE, 100n * ONE]])
  const bal = { [F(1)]: [0n, 100n * ONE], [F(2)]: [0n, 40n * ONE], [F(3)]: [0n, 100n * ONE] }
  const a = alloc(followers, bal, { [F(2)]: 120n * ONE }, (3n * ONE) / 2n)
  const by = Object.fromEntries(a.rows.map((r) => [r.account, r]))
  assert.equal(by[F(1)].loss, 50n * ONE)
  assert.equal(by[F(2)].exposed, 40n * ONE)
  assert.equal(by[F(2)].cost, 180n * ONE)
  assert.equal(by[F(2)].loss, 120n * ONE)
  assert.equal(by[F(3)].loss, 0n)
  assert.equal(a.capped, false)
  assert.equal(a.total, 170n * ONE, 'under the pool: every loss in full')
})

test('H-1: a buy sold back in the same tx only costs what it really spent', () => {
  // one tx: buys 100000 tokens for 100 (avg 0.001), sells 99000 back for 98.9: net +1000 tokens for 1.1
  const followers = fol([[F(1), 100n * ONE, 100_000n * ONE, 50n]])
  const trades = [
    { blockNumber: 50n, token: TOKEN, trader: F(1), isBuy: true, quoteAmount: 100n * ONE, tokenAmount: 100_000n * ONE },
    { blockNumber: 50n, token: TOKEN, trader: F(1), isBuy: false, quoteAmount: 989n * 10n ** 17n, tokenAmount: 99_000n * ONE },
  ]
  const sold = sellsBetween(trades, F(1), TOKEN, 50n, 60n)
  assert.equal(sold, 989n * 10n ** 17n)
  const a = alloc(followers, { [F(1)]: [0n, 1000n * ONE] }, { [F(1)]: sold }, ONE / 1000n)
  const r = a.rows[0]
  assert.equal(r.exposed, 1000n * ONE, 'e: only the 1000 tokens it kept, not the 100000 it bought')
  assert.equal(r.cost, 11n * 10n ** 17n)
  assert.equal(r.loss, 11n * 10n ** 17n - ONE, '1.1 − 1000 × 0.001')
})

test('H-1: a buy, then a sell in a later tx before B', () => {
  const trades = [
    { blockNumber: 40n, token: TOKEN, trader: F(1), isBuy: false, quoteAmount: 7n * ONE, tokenAmount: 1n }, // before F_i: not counted
    { blockNumber: 50n, token: TOKEN, trader: F(1), isBuy: true, quoteAmount: 20n * ONE, tokenAmount: 2000n * ONE },
    { blockNumber: 55n, token: TOKEN, trader: F(1), isBuy: false, quoteAmount: 9n * ONE, tokenAmount: 1000n * ONE },
    { blockNumber: 55n, token: TOKEN2, trader: F(1), isBuy: false, quoteAmount: 5n * ONE, tokenAmount: 1n }, // another token
    { blockNumber: 55n, token: TOKEN, trader: F(2), isBuy: false, quoteAmount: 5n * ONE, tokenAmount: 1n }, // someone else
    { blockNumber: 60n, token: TOKEN, trader: F(1), isBuy: false, quoteAmount: 3n * ONE, tokenAmount: 1n }, // in B: not counted
  ]
  const sold = sellsBetween(trades, F(1), TOKEN, 50n, 60n)
  assert.equal(sold, 9n * ONE)
  const a = alloc(fol([[F(1), 20n * ONE, 2000n * ONE, 50n]]), { [F(1)]: [0n, 1000n * ONE] }, { [F(1)]: sold }, ONE / 200n)
  assert.equal(a.rows[0].cost, 11n * ONE)
  assert.equal(a.rows[0].exposed, 1000n * ONE)
  assert.equal(a.rows[0].loss, 6n * ONE, '11 − 1000 × 0.005')
  // sold more than it paid: C = 0, no loss
  const b = alloc(fol([[F(1), 20n * ONE, 2000n * ONE, 50n]]), { [F(1)]: [0n, 1000n * ONE] }, { [F(1)]: 25n * ONE }, 1n)
  assert.equal(b.rows[0].cost, 0n)
  assert.equal(b.rows[0].loss, 0n)
})

test('H-1: a bag from before the follow does not count', () => {
  // held 5000 before following; followed for 1000 more; holds 6000 at B → e = 1000
  const a = alloc(fol([[F(1), 10n * ONE, 1000n * ONE]]), { [F(1)]: [5000n * ONE, 6000n * ONE] }, {}, ONE / 200n)
  assert.equal(a.rows[0].exposed, 1000n * ONE)
  assert.equal(a.rows[0].loss, 5n * ONE)
  // sold part of the old bag too: holds 5500 at B → e = 500, though it follow-bought 1000
  const b = alloc(fol([[F(1), 10n * ONE, 1000n * ONE]]), { [F(1)]: [5000n * ONE, 5500n * ONE] }, {}, ONE / 200n)
  assert.equal(b.rows[0].exposed, 500n * ONE)
  assert.equal(b.rows[0].loss, 10n * ONE - 25n * 10n ** 17n)
  // holds less at B than at F_i: e = 0, the whole cost is the loss
  const c = alloc(fol([[F(1), 10n * ONE, 1000n * ONE]]), { [F(1)]: [5000n * ONE, 3000n * ONE] }, {}, ONE / 200n)
  assert.equal(c.rows[0].exposed, 0n)
  assert.equal(c.rows[0].loss, 10n * ONE)
})

test('losses round down', () => {
  // C = 10 wei, e = 3 tokens-wei × P_ref 3.333…e18 → 10 − 9.999… = 0.000…1 → 0
  const a = alloc(fol([[F(1), 10n, 3n]]), { [F(1)]: [0n, 3n] }, {}, 3333333333333333333n)
  assert.equal(a.rows[0].loss, 0n)
  // C = 10, e × P = 8.5 → 1.5 → 1
  const b = alloc(fol([[F(1), 10n, 1n]]), { [F(1)]: [0n, 1n] }, {}, 85n * 10n ** 17n)
  assert.equal(b.rows[0].loss, 1n)
  assert.equal(a.rows[0].avgPrice, 3333333333333333333n, 'avgPrice is still shown')
})

test('pro rata past the pool, rounding down', () => {
  const three = fol([[F(1), 2n * ONE, ONE], [F(2), 2n * ONE, ONE], [F(3), 2n * ONE, ONE]])
  const bal = { [F(1)]: [0n, ONE], [F(2)]: [0n, ONE], [F(3)]: [0n, ONE] }
  const a = alloc(three, bal, {}, ONE, 2n * ONE)
  assert.equal(a.sumLoss, 3n * ONE)
  assert.equal(a.capped, true)
  for (const r of a.rows) assert.equal(r.paid, 666666666666666666n, 'each part rounded down')
  assert.equal(a.total, 2n * ONE - 2n, 'the 2 wei left over are not handed out')
  // exactly the pool: paid in full, not scaled
  const b = alloc(three, bal, {}, ONE, 3n * ONE)
  assert.equal(b.capped, false)
  assert.equal(b.total, 3n * ONE)
  // unequal losses scale by loss
  const c = alloc(fol([[F(1), 4n * ONE, ONE], [F(2), 2n * ONE, ONE]]), bal, {}, ONE, ONE)
  const by = Object.fromEntries(c.rows.map((r) => [r.account, r.paid]))
  assert.equal(by[F(1)], (3n * ONE * ONE) / (4n * ONE))
  assert.equal(by[F(2)], (ONE * ONE) / (4n * ONE))
})

test('no follower: total 0, the placeholder root', () => {
  const a = alloc(new Map(), {}, {}, ONE, 100n)
  assert.equal(a.total, 0n)
  const t = buildTree(new Map(), () => assert.fail('no leaf'))
  assert.equal(t.root, EMPTY_ROOT)
  assert.equal(t.total, 0n)
  assert.deepEqual(t.leaves, [])
  assert.notEqual(BigInt(EMPTY_ROOT), 0n, 'the contract refuses a zero root')
  // followers whose loss is 0 get no leaf either
  const z = buildTree(new Map([[F(1), 0n]]), () => '0x' + '00'.repeat(32))
  assert.equal(z.root, EMPTY_ROOT)
})

// ---------------------------------------------------------------- the leaf and the tree
const BOND = '0xBE2B8519278E9D31B6c4040bAd35f727fD5d2A70'
const F1 = '0x8A2C1dDbDC5D0Acc4588481BF9Ab502F916b3468'
const F2 = '0x0B57AC8516765E4a4E49Ca4aaFC903720908F684'
test('the leaf is GangCallBond.leaf', () => {
  // GangCallBond.leaf(1, F1, 0.00147e18) read from the testnet contract (chain 97)
  assert.equal(leafHash(BOND, 97, 1n, F1, 1470000000000000n), '0x91eedb534a65723f66b1823c3be89acbf961ddb117d2f94ed67fd85fdaf18b6c')
  // the root script/CallBondTestnetAcceptance.s.sol posted for bond 1 (sorted pair of the two leaves)
  const t = buildTree(new Map([[F1, 1470000000000000n], [F2, 2940000000000000n]]), (a, v) => leafHash(BOND, 97, 1n, a, v))
  assert.equal(t.root, '0x150532b17b3c4de65908dd69da85827d8fdd201569f6d11e1711baa4851487cb')
  assert.equal(t.total, 4410000000000000n)
  // contract, chain id and bond id are all in the leaf
  const base = leafHash(BOND, 97, 1n, F1, 1n)
  assert.notEqual(leafHash(BOND, 56, 1n, F1, 1n), base)
  assert.notEqual(leafHash(BOND, 97, 2n, F1, 1n), base)
  assert.notEqual(leafHash(F2, 97, 1n, F1, 1n), base)
})

test('trees of any size verify', () => {
  const leafOf = (a, v) => leafHash(BOND, 97, 1n, a, v)
  for (const n of [1, 2, 3, 4, 5, 8, 9, 17]) {
    const m = new Map()
    for (let i = 1; i <= n; i++) m.set(`0x${(i + 256).toString(16).padStart(40, '0')}`, BigInt(i))
    const t = buildTree(m, leafOf)
    assert.equal(t.total, BigInt((n * (n + 1)) / 2))
    assert.equal(t.leaves.length, n)
    for (const l of t.leaves) assert.ok(verify(l.proof, t.root, leafOf(l.account, l.amount)), `n=${n}`)
    assert.ok(!verify(t.leaves[0].proof, t.root, leafOf(t.leaves[0].account, t.leaves[0].amount + 1n)))
  }
})

// ---------------------------------------------------------------- --check
test('--check compares root and total', () => {
  const mine = { root: '0x' + '12'.repeat(32), total: 5n }
  assert.deepEqual(compareRoot(mine, { root: '0x' + '12'.repeat(32), total: 5n }), { ok: true })
  assert.deepEqual(compareRoot(mine, { root: ('0x' + '12'.repeat(32)).toUpperCase().replace('0X', '0x'), total: 5n }), { ok: true })
  assert.equal(compareRoot(mine, { root: '0x' + '13'.repeat(32), total: 5n }).ok, false, 'another root')
  assert.equal(compareRoot(mine, { root: '0x' + '12'.repeat(32), total: 6n }).ok, false, 'same root, another total')
  assert.match(compareRoot(mine, { root: '0x' + '00'.repeat(32), total: 0n }).reason, /no root/)
  // the empty case: total 0 under the placeholder
  assert.equal(compareRoot({ root: EMPTY_ROOT, total: 0n }, { root: EMPTY_ROOT, total: 0n }).ok, true)
})

test('exits: what leaves other than by a curve sell or a vaultLock', () => {
  const L = (blockNumber, logIndex, to, value) => ({ blockNumber, logIndex, from: F(1), to, value })
  const out = [
    L(50n, 0, PAD, 1000n), // a curve sell
    L(51n, 1, F(2), 200n), // to another wallet
    L(51n, 0, PAIR, 300n), // a pool sale, same block, earlier
    L(53n, 0, PAD, 100n), // a vaultLock
    L(54n, 0, F(1), 999n), // to itself
    L(55n, 5, PAD, 40n), // to the pad after the Graduated log: an exit
    L(49n, 0, F(2), 7n), // before F_i
    L(60n, 0, F(2), 7n), // in B
  ]
  const exits = exitsOf({ account: F(1), transfersOut: out, pad: PAD, grad: { blockNumber: 55n, logIndex: 2 }, from: 50n, to: 60n })
  assert.deepEqual(exits.map((x) => [x.blockNumber, x.logIndex, x.tokens]), [[51n, 0, 300n], [51n, 1, 200n], [55n, 5, 40n]], 'one per Transfer, in order')
})

test('exits are priced at max(spot right before, end of block, P_ref)', () => {
  const E = (blockNumber, logIndex, price) => ({ blockNumber, logIndex, price })
  // block 51: price 3 before the sale (log 1), the sale's own Sync to 2.9 (log 3), a dump to 0.5 (log 7); 54: 1
  const events = [E(51n, 3, (29n * ONE) / 10n), E(51n, 7, ONE / 2n), E(50n, 9, 3n * ONE), E(54n, 0, ONE)]
  const spotBefore = spotLookup(10n * ONE, events)
  assert.equal(spotBefore({ blockNumber: 51n, logIndex: 1 }), 3n * ONE, 'the last event before the Transfer, the block before')
  assert.equal(spotBefore({ blockNumber: 51n, logIndex: 5 }), (29n * ONE) / 10n)
  assert.equal(spotBefore({ blockNumber: 51n, logIndex: 3 }), 3n * ONE, 'strictly before')
  assert.equal(spotBefore({ blockNumber: 40n, logIndex: 0 }), 10n * ONE, 'none before: the seed')
  const priceAtEndOf = priceLookup(10n * ONE, endOfBlockPrices(events))
  assert.equal(priceAtEndOf(51n), ONE / 2n)
  assert.equal(priceAtEndOf(53n), ONE / 2n, 'carried forward')
  const kit = { spotBefore, priceAtEndOf }
  // sold 100 at log 1 of block 51: the dump to 0.5 later in the block does not lower it: 100 × 3
  assert.equal(exitCredit([{ blockNumber: 51n, logIndex: 1, tokens: 100n }], kit, ONE / 10n), 300n)
  // after the dump (log 8), the end of the block (0.5) is under P_ref 2: P_ref
  assert.equal(exitCredit([{ blockNumber: 51n, logIndex: 8, tokens: 100n }], kit, 2n * ONE), 200n)
  // a pump at the end of the block counts too: 54 ends at 1, spot before 0.5, P_ref 0.1
  assert.equal(exitCredit([{ blockNumber: 54n, logIndex: 0, tokens: 100n }], kit, ONE / 10n), 100n)
  // rounded down once, over the sum
  const third = { spotBefore: () => ONE / 3n, priceAtEndOf: () => 0n }
  assert.equal(exitCredit([{ blockNumber: 1n, logIndex: 0, tokens: 3n }], third, 0n), 0n)
  assert.equal(exitCredit([{ blockNumber: 1n, logIndex: 0, tokens: 3n }, { blockNumber: 2n, logIndex: 0, tokens: 3n }], third, 0n), 1n)
})

test('L-1: pre-graduation inflows from anyone but the pad are vault releases', () => {
  const T = (blockNumber, logIndex, from, value) => ({ blockNumber, logIndex, from, to: F(1), value })
  const R = (blockNumber, logIndex, amount) => ({ blockNumber, logIndex, user: F(1), amount })
  const base = { account: F(1), pad: PAD, grad: { blockNumber: 70n, logIndex: 0 }, from: 50n, to: 80n }
  const transfersIn = [T(51n, 0, PAD, 1000n), T(52n, 0, VAULT, 50n), T(53n, 0, '0x00000000000000000000000000000000000007b0', 20n), T(75n, 0, F(3), 9n)]
  checkVaultInflows({ ...base, transfersIn, releases: [R(52n, 1, 50n), R(53n, 1, 20n)] }) // after graduation: free transfers
  // a release from a vault never seen in range is still counted: dropping its VaultReleased shows
  assert.throws(() => checkVaultInflows({ ...base, transfersIn, releases: [R(52n, 1, 50n)] }), /got 70 from others than the pad before graduation, VaultReleased says 50/)
  assert.throws(() => checkVaultInflows({ ...base, transfersIn: transfersIn.slice(0, 2), releases: [R(52n, 1, 50n), R(53n, 1, 20n)] }), /incomplete/, 'a dropped Transfer')
  checkVaultInflows({ ...base, transfersIn: [], releases: [] })
})

test('vaults: locked counts as held, a release goes back to the balance', () => {
  const V = (blockNumber, amount, user = F(1)) => ({ blockNumber, user, amount })
  assert.equal(vaultNet([V(50n, 200n)], [], F(1), 50n, 60n), 200n)
  assert.equal(vaultNet([V(50n, 200n)], [V(55n, 50n)], F(1), 50n, 60n), 150n)
  assert.equal(vaultNet([V(50n, 200n)], [V(55n, 200n)], F(1), 50n, 60n), 0n, 'locked then released')
  assert.equal(vaultNet([V(40n, 200n)], [V(55n, 200n)], F(1), 50n, 60n), 0n, 'releasing an older lock: floored')
  assert.equal(vaultNet([V(50n, 200n, F(2)), V(60n, 9n)], [], F(1), 50n, 60n), 0n)
  // followed 1000, locked 200, released 200: holds all 1000 again, e = 1000
  const a = allocate({ followers: fol([[F(1), 10n * ONE, 1000n * ONE]]), balanceAtF: () => 0n, balanceAtB: () => 1000n * ONE, soldQuote: () => 0n, vaulted: () => 0n, pRef: ONE / 200n, pool: 10n ** 30n })
  assert.equal(a.rows[0].exposed, 1000n * ONE)
  // locked 200, not released: 800 in the wallet + 200 in the vault
  const b = allocate({ followers: fol([[F(1), 10n * ONE, 1000n * ONE]]), balanceAtF: () => 0n, balanceAtB: () => 800n * ONE, soldQuote: () => 0n, vaulted: () => 200n * ONE, pRef: ONE / 200n, pool: 10n ** 30n })
  assert.equal(b.rows[0].exposed, 1000n * ONE)
  assert.equal(b.rows[0].loss, 5n * ONE)
})

test('exits: a pool sale at a profit pays nothing; sending tokens away never pays more than holding them', () => {
  const run = (bAtB, x) => allocate({ followers: fol([[F(1), 10n * ONE, 1000n * ONE]]), balanceAtF: () => 0n, balanceAtB: () => bAtB, soldQuote: () => 0n, exitCredit: () => x, pRef: ONE / 200n, pool: 10n ** 30n }).rows[0]
  // sold all 1000 on the pool at 0.02 (above P_ref 0.005): X = 20 > C = 10
  const one = (tokens) => [{ blockNumber: 55n, logIndex: 0, tokens }]
  const flat = (p) => ({ spotBefore: () => p, priceAtEndOf: () => p })
  const profit = run(0n, exitCredit(one(1000n * ONE), flat(ONE / 50n), ONE / 200n))
  assert.equal(profit.cost, 0n)
  assert.equal(profit.loss, 0n)
  // sold all 1000 on the pool at 0.001 (below P_ref): credited at P_ref, the same loss as holding
  const hold = run(1000n * ONE, 0n)
  const cheap = run(0n, exitCredit(one(1000n * ONE), flat(ONE / 1000n), ONE / 200n))
  assert.equal(cheap.loss, hold.loss)
  assert.equal(hold.loss, 5n * ONE)
  // sent 400 to another wallet at any price: never more than holding
  for (const p of [ONE / 1000n, ONE / 200n, ONE / 10n]) {
    const away = run(600n * ONE, exitCredit(one(400n * ONE), flat(p), ONE / 200n))
    assert.ok(away.loss <= hold.loss)
    assert.equal(away.exposed, 600n * ONE)
  }
})

test('the creator is no follower', () => {
  const c = followCase()
  assert.ok(followBuys(c).has(F(1)))
  assert.ok(!followBuys({ ...c, creator: F(1).toUpperCase().replace('0X', '0x') }).has(F(1)))
})

test('forward balances', () => {
  const endOf = forwardBalances({ startBalance: 10n, fromBlock: 5n, toBlock: 9n, transfers: [{ blockNumber: 6n, delta: 5n }, { blockNumber: 6n, delta: -3n }, { blockNumber: 8n, delta: -12n }] })
  assert.deepEqual([4n, 5n, 6n, 7n, 8n, 9n].map(endOf), [10n, 10n, 12n, 12n, 0n, 0n])
  assert.throws(() => forwardBalances({ startBalance: 1n, fromBlock: 5n, toBlock: 9n, transfers: [{ blockNumber: 6n, delta: -2n }] }), /incomplete/)
  assert.throws(() => endOf(10n), /no end-of-block/)
})

test("the pad's token flows against TradeV1, VaultLocked and Graduated", () => {
  const L = (blockNumber, logIndex, o) => ({ blockNumber, logIndex, ...o })
  const fromPad = [L(10n, 0, { from: PAD, to: F(1), value: 100n }), L(12n, 1, { from: PAD, to: VAULT, value: 30n }), L(20n, 1, { from: PAD, to: MIGRATOR, value: 500n }), L(21n, 0, { from: PAD, to: F(2), value: 9n })]
  const toPad = [L(4n, 0, { from: ZERO, to: PAD, value: 10n ** 27n }), L(11n, 0, { from: F(1), to: PAD, value: 40n }), L(12n, 0, { from: F(1), to: PAD, value: 30n }), L(22n, 0, { from: F(3), to: PAD, value: 5n })]
  const trades = [L(10n, 1, { isBuy: true, tokenAmount: 100n }), L(11n, 1, { isBuy: false, tokenAmount: 40n }), L(20n, 0, { isBuy: true, tokenAmount: 0n })]
  const locks = [L(12n, 2, { amount: 30n })]
  const grad = { blockNumber: 20n, logIndex: 3, tokenAmount: 500n }
  const base = { from: 4n, ends: [9n, 14n, 30n], pad: PAD, fromPad, toPad, trades, locks, grad }
  checkPadFlows(base) // the mint and anything after the Graduated log are left out
  assert.throws(() => checkPadFlows({ ...base, trades: trades.filter((t) => t.blockNumber !== 10n) }), /blocks 10–14/, 'a dropped buy')
  assert.throws(() => checkPadFlows({ ...base, trades: trades.filter((t) => t.blockNumber !== 11n) }), /blocks 10–14/, 'a dropped sell')
  assert.throws(() => checkPadFlows({ ...base, locks: [] }), /blocks 10–14/, 'a dropped VaultLocked')
  assert.throws(() => checkPadFlows({ ...base, grad: null }), /blocks 15–30/, 'a dropped Graduated')
  assert.throws(() => checkPadFlows({ ...base, toPad: toPad.slice(0, 2) }), /blocks 10–14/, "a dropped Transfer into the pad")
  // a round trip in one segment: both ways count, nothing nets out
  const rt = { from: 1n, ends: [9n], pad: PAD, fromPad: [L(5n, 0, { from: PAD, to: F(1), value: 7n })], toPad: [L(6n, 0, { from: F(1), to: PAD, value: 7n })], trades: [], locks: [], grad: null }
  assert.throws(() => checkPadFlows(rt), /blocks 1–9: the pad sent 7 \/ took 7 tokens, the trades, vault locks and graduation say 0 \/ 0/)
})

// ---------------------------------------------------------------- settle.mjs against a mocked chain
// A small chain: 2 blocks a second, a 3.0 curve token, a bond, follows, a report; then the script's I/O end to end, and
// with chunks of logs silently dropped (as a public node can), which it must refuse.
const A = (n) => getAddress(`0x${n.toString(16).padStart(40, '0')}`)
const M = { bond: A(0xb0), pad: A(0xbad), token: A(0x70), quote: A(0x99), pair: A(0xa1a), caller: A(0xc0), reporter: A(0xee), migrator: A(0x3a), vault: A(0x7a), vault2: A(0x7b) }
const TOTAL = 10n ** 27n
const MF = (i) => A(0xf00 + i)
const VT = 1_066_666_666_666_666_666_666_666_667n
const VQ = 30n * ONE
const T0 = 1_800_000_000n
const tsOf = (n) => T0 + n / 2n
const HASH = (n) => `0x${n.toString(16).padStart(64, '0')}`
const NOTE_TX = HASH(0x9071en)

function mockChain({ graduateAt = null, pump = false, dump = false, vaultFollows = false, oldVault = false } = {}) {
  const logs = []
  const txs = new Map()
  const snaps = [] // [block, state] after each block that changed something
  const st = { bal: new Map(), sold: 0n, realQuote: 0n, graduated: false, reserves: null }
  let block = 0n
  let logIndex = 0
  let txN = 0n
  const copy = () => ({ bal: new Map(st.bal), sold: st.sold, realQuote: st.realQuote, graduated: st.graduated, reserves: st.reserves && [...st.reserves] })
  const goto = (n) => {
    if (n !== block) {
      if (snaps.length === 0 || snaps.at(-1)[0] !== block) snaps.push([block, copy()])
      block = n
      logIndex = 0
    }
  }
  const emit = (address, eventName, args, hash) => logs.push({ address, eventName, args, blockNumber: block, logIndex: logIndex++, transactionHash: hash })
  const tx = (from, input = '0x', hash = HASH(++txN)) => {
    txs.set(hash, { from, input, blockNumber: block })
    return hash
  }
  const move = (from, to, value, hash) => {
    if (from !== M.pad) st.bal.set(from, (st.bal.get(from) ?? 0n) - value)
    if (to !== M.pad) st.bal.set(to, (st.bal.get(to) ?? 0n) + value)
    emit(M.token, 'Transfer', { from, to, value }, hash)
  }
  const trade = (hash, trader, isBuy, quoteAmount, tokenAmount) => {
    if (isBuy) {
      move(M.pad, trader, tokenAmount, hash)
      st.sold += tokenAmount
      st.realQuote += quoteAmount
    } else {
      move(trader, M.pad, tokenAmount, hash)
      st.sold -= tokenAmount
      st.realQuote -= quoteAmount
    }
    const postPrice = curvePrice({ virtualQuote: VQ, realQuote: st.realQuote, sold: st.sold }, VT)
    emit(M.pad, 'TradeV1', { token: M.token, trader, isBuy, quoteAmount, tokenAmount, protocolFee: 0n, creatorFee: 0n, postPrice, realQuote: st.realQuote, sold: st.sold }, hash)
  }
  const sync = (hash, r0, r1) => {
    st.reserves = [r0, r1]
    emit(M.pair, 'Sync', { reserve0: r0, reserve1: r1 }, hash)
  }
  // the migration: pad → migrator → pair, the pair's Sync, then Graduated (as PadCommon.migrate / CurveLogic3._graduate)
  const graduate = () => {
    const h = tx(MF(9))
    trade(h, MF(9), true, 5n * ONE, 30_000n * ONE)
    const tokenAmount = TOTAL - st.sold
    move(M.pad, M.migrator, tokenAmount, h)
    move(M.migrator, M.pair, tokenAmount, h)
    sync(h, tokenAmount, st.realQuote)
    emit(M.pad, 'Graduated', { token: M.token, pair: M.pair, quote: M.quote, tokenAmount, quoteAmount: st.realQuote }, h)
    st.graduated = true
    st.realQuote = 0n
  }
  const step = (n) => {
    if (graduateAt && !st.graduated && graduateAt <= n) {
      goto(graduateAt)
      graduate()
    }
    goto(n)
  }
  // a buy / sell on the curve, or on the pair once graduated (a pool trade is a Transfer and a Sync, no TradeV1)
  const any = (hash, who, isBuy, quoteAmount, tokenAmount) => {
    if (!st.graduated) return trade(hash, who, isBuy, quoteAmount, tokenAmount)
    const [r0, r1] = st.reserves
    if (isBuy) {
      move(M.pair, who, tokenAmount, hash)
      sync(hash, r0 - tokenAmount, r1 + quoteAmount)
    } else {
      move(who, M.pair, tokenAmount, hash)
      sync(hash, r0 + tokenAmount, r1 - quoteAmount)
    }
  }
  const vaultRelease = (hash, user, amount, vault = M.vault) => {
    move(vault, user, amount, hash)
    emit(M.pad, 'VaultReleased', { token: M.token, vault, user, amount }, hash)
  }
  const vaultLock = (hash, user, amount, vault = M.vault) => {
    move(user, M.pad, amount, hash)
    move(M.pad, vault, amount, hash)
    emit(M.pad, 'VaultLocked', { token: M.token, vault, user, amount }, hash)
  }
  const follow = CALLDATA + FOLLOW(NOTE_TX)
  const bondOf = { caller: M.caller, postedAt: 0n, state: 3, token: M.token, deadline: 0n, quote: M.quote, settleAt: 0n, amount: 10n ** 16n, hold: 0n, reportedAt: 0n, reportedBlock: 0n, rootAt: 0n, vetoAt: 0n, pool: 49n * 10n ** 14n, spent: 0n, total: 0n, remainderBurned: false, noteTx: NOTE_TX, root: '0x' + '00'.repeat(32) }

  goto(4n)
  emit(M.token, 'Transfer', { from: A(0), to: M.pad, value: TOTAL }, tx(M.reporter)) // the mint: left out of the pad's flows
  step(5n)
  trade(tx(MF(5)), MF(5), true, ONE / 10n, 5000n * ONE) // F5's bag, before the note
  if (oldVault) {
    step(6n)
    trade(tx(MF(8)), MF(8), true, ONE / 10n, 100n * ONE)
    vaultLock(tx(MF(8)), MF(8), 100n * ONE, M.vault2) // locked before the range the script reads
  }
  step(10n)
  trade(tx(M.caller, CALLDATA + NOTE_V1, NOTE_TX), M.caller, true, ONE, 10_000n * ONE) // the note
  step(12n)
  bondOf.hold = st.bal.get(M.caller)
  bondOf.postedAt = tsOf(12n)
  emit(M.bond, 'CallBondPosted', { id: 1n, caller: M.caller, token: M.token, noteTx: NOTE_TX, quote: M.quote, amount: bondOf.amount, hold: bondOf.hold, deadline: 0n }, tx(M.caller))
  step(14n)
  trade(tx(MF(1), follow), MF(1), true, ONE / 10n, 1000n * ONE) // F1: a plain follow
  step(15n)
  if (pump) {
    trade(tx(MF(6), follow), MF(6), true, ONE / 10n, 1000n * ONE) // F6: sells it all on the pair at a high price
    trade(tx(MF(7), follow), MF(7), true, ONE / 10n, 1000n * ONE) // F7: sells it all on the pair below P_ref
  }
  step(16n)
  let h = tx(MF(2), follow) // F2: buys big and sells back in the same tx
  trade(h, MF(2), true, 10n * ONE, 90_000n * ONE)
  trade(h, MF(2), false, 98n * ONE / 10n, 89_000n * ONE)
  if (vaultFollows) {
    step(16n)
    trade(tx(M.vault, follow), M.vault, true, ONE / 10n, 1000n * ONE) // the vault itself follows
  }
  step(17n)
  trade(tx(A(1), follow), A(1), true, ONE / 10n, 1000n * ONE) // the token's creator following: no follower
  step(18n)
  trade(tx(MF(4), follow), MF(4), true, 2n * ONE / 10n, 2000n * ONE) // F4: buys, vault-locks 200, sells 1000 later
  step(20n)
  trade(tx(M.caller), M.caller, false, ONE / 2n, 5000n * ONE) // the caller below hold …
  step(21n)
  vaultLock(tx(MF(4)), MF(4), 200n * ONE)
  step(22n)
  trade(tx(MF(4)), MF(4), false, 9n * ONE / 100n, 1000n * ONE)
  step(23n)
  trade(tx(M.caller), M.caller, true, ONE / 2n, 5000n * ONE) // … and back at hold
  step(24n)
  trade(tx(MF(5), follow), MF(5), true, ONE / 10n, 1000n * ONE) // F5 follows on top of its bag
  step(25n)
  h = tx(M.caller) // a dip and back inside one block: not a violation
  trade(h, M.caller, false, ONE / 100n, 100n * ONE)
  trade(h, M.caller, true, ONE / 100n, 100n * ONE)
  step(26n)
  trade(tx(M.caller, follow), M.caller, true, ONE / 10n, 1n) // the caller "following" itself: no follower
  vaultRelease(tx(MF(4)), MF(4), 50n * ONE) // F4 takes 50 of its 200 back
  if (oldVault) vaultRelease(tx(MF(1)), MF(1), 40n * ONE, M.vault2) // the old vault releases 40 to F1
  if (graduateAt && graduateAt <= 28n) {
    step(28n)
    move(MF(1), MF(20), 300n * ONE, tx(MF(1))) // F1 moves 300 to another wallet
    any(tx(MF(5)), MF(5), false, ONE / 1000n, 3000n * ONE) // F5 sells 3000 on the pair: mostly its old bag
    if (pump) any(tx(MF(7)), MF(7), false, ONE / 10_000n, 1000n * ONE)
    step(29n)
    any(tx(MF(2)), MF(2), false, ONE / 1000n, 500n * ONE) // F2 sells 500 on the pair
    if (pump) {
      any(tx(MF(9)), MF(9), true, 100_000n * ONE, 1n * ONE) // the price of the pair way up
      any(tx(MF(6)), MF(6), false, ONE / 10n, 1000n * ONE)
      if (dump) any(tx(MF(9)), MF(9), false, st.reserves[1] - st.reserves[1] / 1_000_000n, 10n ** 24n) // and down again
    }
  }
  step(30n)
  any(tx(M.caller), M.caller, false, ONE / 2n, 5000n * ONE) // below hold for good: B = 30
  step(32n)
  bondOf.reportedBlock = 32n
  emit(M.bond, 'CallBondReported', { id: 1n, reporter: M.reporter, reportedBlock: 32n, balance: st.bal.get(M.caller), reward: 0n, burned: 0n, pool: bondOf.pool }, tx(M.reporter))
  // the price window [ts(30), ts(30) + 3600): blocks 30 … 7229
  step(408n)
  any(tx(MF(9)), MF(9), true, 3n * ONE, 20_000n * ONE) // a round trip across the chunk boundary at 409 / 410
  step(411n)
  any(tx(MF(9)), MF(9), false, 3n * ONE, 20_000n * ONE)
  step(1000n)
  any(tx(MF(9)), MF(9), false, ONE / 10n, 1000n * ONE)
  step(2600n)
  any(tx(MF(9)), MF(9), false, ONE / 10n, 10_000n * ONE)
  step(3500n)
  any(tx(MF(9)), MF(9), true, ONE / 2n, 15_000n * ONE)
  step(5000n)
  any(tx(MF(9)), MF(9), true, ONE / 10n, 1000n * ONE)
  goto(7400n)
  const FINAL = 7400n

  const stateAt = (n) => {
    let s0 = { bal: new Map(), sold: 0n, realQuote: 0n, graduated: false, reserves: null }
    for (const [b, s1] of snaps) if (b <= n) s0 = s1
    return n >= block ? copy() : s0
  }
  let drop = () => false
  const calls = { getLogs: 0 }
  const client = {
    getChainId: async () => 97,
    getBlock: async ({ blockNumber, blockTag }) => (blockTag ? { number: FINAL } : { timestamp: tsOf(blockNumber) }),
    getTransactionReceipt: async ({ hash }) => (txs.has(hash) ? { blockNumber: txs.get(hash).blockNumber } : null),
    getTransaction: async ({ hash }) => txs.get(hash) ?? null,
    getLogs: async ({ address, event, args = {}, fromBlock, toBlock }) => {
      calls.getLogs++
      if (drop(event.name, fromBlock, toBlock, args)) return []
      return logs
        .filter((l) => l.address === address && l.eventName === event.name && l.blockNumber >= fromBlock && l.blockNumber <= toBlock)
        .filter((l) => Object.entries(args).every(([k, v]) => String(l.args[k]).toLowerCase() === String(v).toLowerCase()))
        .map((l) => ({ ...l, args: { ...l.args } }))
    },
    readContract: async ({ address, functionName, args = [], blockNumber }) => {
      const s1 = stateAt(blockNumber ?? FINAL)
      switch (functionName) {
        case 'bondOf': return bondOf
        case 'pad': return M.pad
        case 'wbnb': return M.quote
        case 'leaf': return leafHash(M.bond, 97, args[0], args[1], args[2])
        case 'VIRTUAL_TOKEN': return VT
        case 'curves': return [A(1), M.quote, s1.realQuote, s1.sold, 0n, VQ, s1.graduated, 0, 0, 0, s1.graduated ? M.pair : A(0), A(0)]
        case 'balanceOf': return s1.bal.get(getAddress(args[0])) ?? 0n
        case 'decimals': return 18
        case 'token0': return M.token
        case 'getReserves':
          if (!s1.reserves) throw new Error('no pair yet')
          return [s1.reserves[0], s1.reserves[1], 0]
      }
      throw new Error(`mock: ${functionName}`)
    },
  }
  return { client, setDrop: (f) => (drop = f), calls, bondOf }
}

const refuses = async (chain, chunk, pattern) => {
  await assert.rejects(settle(chain.client, { bond: M.bond, id: 1n, chunk }), (e) => e instanceof SettleError && pattern.test(e.message))
}

test('mock chain: B, followers, H-1 losses end to end', async () => {
  const { client } = mockChain()
  const { out, tree } = await settle(client, { bond: M.bond, id: 1n, chunk: 100n })
  assert.equal(out.B, '30', 'the dip inside block 25 and the run 20–22 that recovered do not count')
  assert.equal(out.postBlock, '12')
  assert.equal(out.priceWindow.lastBlock, '7229')
  const by = Object.fromEntries(out.followers.map((f) => [f.account, f]))
  assert.deepEqual(Object.keys(by).sort(), [MF(1), MF(2), MF(4), MF(5)].sort(), 'F9 never followed; the caller is no follower')
  const pRef = BigInt(out.pRef)
  const lossOf = (C, e) => (C * ONE > e * pRef ? (C * ONE - e * pRef) / ONE : 0n)
  // F1: plain
  assert.equal(by[MF(1)].exposed, String(1000n * ONE))
  assert.equal(by[MF(1)].loss, String(lossOf(ONE / 10n, 1000n * ONE)))
  // F2: bought 90000 for 10, sold 89000 back for 9.8 in the same tx: C = 0.2, e = 1000
  assert.equal(by[MF(2)].cost, String(2n * ONE / 10n))
  assert.equal(by[MF(2)].exposed, String(1000n * ONE))
  assert.equal(by[MF(2)].loss, String(lossOf(2n * ONE / 10n, 1000n * ONE)))
  // F4: bought 2000 for 0.2, vault-locked 200, sold 1000 for 0.09, took 50 back: C = 0.11, e = 850 + 150 in the vault
  assert.equal(by[MF(4)].cost, String(11n * ONE / 100n))
  assert.equal(by[MF(4)].balanceAtB, String(850n * ONE))
  assert.equal(by[MF(4)].vaulted, String(150n * ONE))
  assert.equal(by[MF(4)].exited, '0', 'a vaultLock is no exit')
  assert.equal(by[MF(4)].exposed, String(1000n * ONE))
  assert.ok(!by[A(1)], "the token's creator is no follower")
  // F5: 5000 bag before the follow, followed for 1000: e = 1000
  assert.equal(by[MF(5)].balanceAtF, String(5000n * ONE))
  assert.equal(by[MF(5)].exposed, String(1000n * ONE))
  for (const f of out.followers) assert.ok(BigInt(f.loss) > 0n)
  // the losses top the 0.0049 pool: pro rata, rounded down
  const sumLoss = out.followers.reduce((s1, f) => s1 + BigInt(f.loss), 0n)
  assert.equal(out.proRata, true)
  assert.equal(out.sumLoss, String(sumLoss))
  for (const f of out.followers) assert.equal(f.paid, String((BigInt(f.loss) * BigInt(out.pool)) / sumLoss))
  assert.ok(BigInt(out.total) <= BigInt(out.pool))
  for (const l of out.leaves) assert.ok(verify(l.proof, out.root, leafHash(M.bond, 97, 1n, l.account, BigInt(l.amount))))
  assert.equal(compareRoot(tree, { root: out.root, total: BigInt(out.total) }).ok, true, '--check against its own root')
  assert.equal(compareRoot(tree, { root: '0x' + '00'.repeat(32), total: 0n }).ok, false, '--check with nothing posted')
  // the same run with another chunk size gives the same root
  assert.equal((await settle(client, { bond: M.bond, id: 1n, chunk: 37n })).out.root, out.root)
})

test('mock chain: P_ref from Sync after a graduation in the window', async () => {
  const { client } = mockChain({ graduateAt: 2000n })
  const { out } = await settle(client, { bond: M.bond, id: 1n, chunk: 100n })
  // brute force over the raw logs: per second, the last price event in a block with ts ≤ s; the migration's Sync (before
  // the graduating TradeV1's Graduated, after its TradeV1) counts, Syncs never come before it
  const all = [
    ...(await client.getLogs({ address: M.pad, event: { name: 'TradeV1' }, fromBlock: 0n, toBlock: 7400n })).map((l) => ({ ...l, price: l.args.postPrice })),
    ...(await client.getLogs({ address: M.pair, event: { name: 'Sync' }, fromBlock: 0n, toBlock: 7400n })).map((l) => ({ ...l, price: pairPrice(l.args.reserve0, l.args.reserve1, true) })),
  ].sort((x, y) => (x.blockNumber === y.blockNumber ? x.logIndex - y.logIndex : x.blockNumber < y.blockNumber ? -1 : 1))
  let sum = 0n
  for (let sec = tsOf(30n); sec < tsOf(30n) + 3600n; sec++) sum += all.filter((l) => tsOf(l.blockNumber) <= sec).at(-1).price
  assert.equal(out.pRef, String(sum / 3600n))
  assert.equal(out.B, '30')
})

// prices and exit credits recomputed from the mock's raw logs, for the end-to-end checks
async function priceKit(chain, pRef) {
  const get = (address, name) => chain.client.getLogs({ address, event: { name }, fromBlock: 0n, toBlock: 7400n })
  const ord = (x, y) => (x.blockNumber === y.blockNumber ? x.logIndex - y.logIndex : x.blockNumber < y.blockNumber ? -1 : 1)
  const ev = [
    ...(await get(M.pad, 'TradeV1')).map((l) => ({ ...l, price: l.args.postPrice })),
    ...(await get(M.pair, 'Sync')).map((l) => ({ ...l, price: pairPrice(l.args.reserve0, l.args.reserve1, true) })),
  ].sort(ord)
  const transfers = await get(M.token, 'Transfer')
  const end = (n) => ev.filter((l) => l.blockNumber <= n).at(-1).price
  const spot = (t) => ev.filter((l) => ord(l, t) < 0).at(-1).price
  const max = (...v) => v.reduce((a, b) => (b > a ? b : a))
  const exitsOfIn = (from, block) => transfers.filter((t) => t.args.from === from && t.blockNumber === block && t.args.to !== from && t.args.to !== M.pad)
  const credit = (from, blocks) => blocks.flatMap((b) => exitsOfIn(from, b)).reduce((x, t) => x + t.args.value * max(spot(t), end(t.blockNumber), pRef), 0n) / ONE
  return { end, spot, credit, exitsOfIn }
}

test('M-1: a pool sale or a transfer away is an exit, credited at max(spot, end of block, P_ref)', async () => {
  // graduation at 27, before B = 30: F1 moves 300 to another wallet at 28, F5 sells 3000 on the pair at 28, F2 sells
  // 500 on the pair at 29
  const chain = mockChain({ graduateAt: 27n })
  const { out } = await settle(chain.client, { bond: M.bond, id: 1n, chunk: 50n })
  assert.equal(out.B, '30', 'the caller sold on the pair')
  const pRef = BigInt(out.pRef)
  const k = await priceKit(chain, pRef)
  const by = Object.fromEntries(out.followers.map((f) => [f.account, f]))
  // F1: 1000 followed, 300 sent away: holds 700, the 300 credited
  assert.equal(by[MF(1)].balanceAtB, String(700n * ONE))
  assert.equal(by[MF(1)].exposed, String(700n * ONE))
  assert.equal(by[MF(1)].exited, String(300n * ONE))
  assert.equal(by[MF(1)].exitCredit, String(k.credit(MF(1), [28n])))
  const c1 = ONE / 10n - k.credit(MF(1), [28n])
  assert.equal(by[MF(1)].cost, String(c1))
  assert.equal(by[MF(1)].loss, String((c1 * ONE - 700n * ONE * pRef) / ONE))
  // F2: kept 1000 after the same-tx round trip, sold 500 on the pair: e = 500, C = 0.2 − X
  assert.equal(by[MF(2)].exposed, String(500n * ONE))
  assert.equal(by[MF(2)].exited, String(500n * ONE), 'the 89000 sold on the curve are no exit')
  assert.equal(by[MF(2)].exitCredit, String(k.credit(MF(2), [29n])))
  assert.equal(by[MF(2)].cost, String(2n * ONE / 10n - k.credit(MF(2), [29n])))
  // F5: a 5000 bag before the follow, 1000 followed, 3000 sold on the pair after graduation: e = max(0, 3000 − 5000) = 0,
  // and the whole exit is credited against its cost
  assert.equal(by[MF(5)].balanceAtF, String(5000n * ONE))
  assert.equal(by[MF(5)].balanceAtB, String(3000n * ONE))
  assert.equal(by[MF(5)].exposed, '0')
  assert.equal(by[MF(5)].exited, String(3000n * ONE))
  const x5 = k.credit(MF(5), [28n])
  assert.equal(by[MF(5)].exitCredit, String(x5))
  const c5 = ONE / 10n > x5 ? ONE / 10n - x5 : 0n
  assert.equal(by[MF(5)].cost, String(c5))
  assert.equal(by[MF(5)].loss, String(c5), 'e = 0: the loss is the cost left')
  // a dropped chunk of F1's own transfers (the 300 out) is refused
  const c = mockChain({ graduateAt: 27n })
  c.setDrop((name, from, to, args) => name === 'Transfer' && String(args.from).toLowerCase() === MF(1).toLowerCase() && from <= 28n && to >= 28n)
  await refuses(c, 50n, new RegExp(`${MF(1).toLowerCase()}'s balance .* transfer logs are incomplete`))
})

test('M-1: a pool exit above P_ref gets nothing, one below P_ref is credited at P_ref', async () => {
  const chain = mockChain({ graduateAt: 27n, pump: true })
  const { out } = await settle(chain.client, { bond: M.bond, id: 1n, chunk: 50n })
  const pRef = BigInt(out.pRef)
  const k = await priceKit(chain, pRef)
  const by = Object.fromEntries(out.followers.map((f) => [f.account, f]))
  // F6 paid 0.1 for 1000 and sold them all on the pair after the pump: more than it paid, no loss, no leaf
  const [sale6] = k.exitsOfIn(MF(6), 29n)
  assert.ok(k.spot(sale6) > pRef)
  assert.equal(by[MF(6)].exitCredit, String((1000n * ONE * k.spot(sale6)) / ONE))
  assert.ok(BigInt(by[MF(6)].exitCredit) > ONE / 10n)
  assert.equal(by[MF(6)].cost, '0')
  assert.equal(by[MF(6)].exposed, '0')
  assert.equal(by[MF(6)].loss, '0')
  assert.ok(!out.leaves.some((l) => l.account === MF(6)))
  // F7 sold its 1000 on the pair before the pump, cheaper than P_ref: credited at P_ref, as if still held
  const [sale7] = k.exitsOfIn(MF(7), 28n)
  assert.ok(k.spot(sale7) < pRef && k.end(28n) < pRef)
  assert.equal(by[MF(7)].exitCredit, String((1000n * ONE * pRef) / ONE))
  const held = (ONE / 10n) * ONE - 1000n * ONE * pRef // what holding the 1000 would have given (× 1e18)
  assert.equal(BigInt(by[MF(7)].loss), held > 0n ? held / ONE : 0n)
})

test('M-1: selling high and dumping in the same block still prices the exit at the high', async () => {
  // block 29: the pair is pumped, F6 sells its 1000, then the price is dumped before the block ends
  const chain = mockChain({ graduateAt: 27n, pump: true, dump: true })
  const { out } = await settle(chain.client, { bond: M.bond, id: 1n, chunk: 50n })
  const pRef = BigInt(out.pRef)
  const k = await priceKit(chain, pRef)
  const f6 = out.followers.find((f) => f.account === MF(6))
  const [sale] = k.exitsOfIn(MF(6), 29n)
  assert.ok(k.end(29n) < k.spot(sale) && pRef < k.spot(sale), 'the block ends low, P_ref is low')
  assert.ok((1000n * ONE * (k.end(29n) > pRef ? k.end(29n) : pRef)) / ONE < ONE / 10n, 'by the end-of-block price it would be paid')
  assert.equal(f6.exitCredit, String((1000n * ONE * k.spot(sale)) / ONE))
  assert.equal(f6.cost, '0')
  assert.equal(f6.loss, '0')
  assert.ok(!out.leaves.some((l) => l.account === MF(6)))
})

test('a vault that follows: what it holds for others is capped by T_i, what it releases is an exit', async () => {
  // the vault buys 1000 at 16; F4 locks 200 into it at 21 and takes 50 back at 26
  const chain = mockChain({ vaultFollows: true })
  const { out } = await settle(chain.client, { bond: M.bond, id: 1n, chunk: 100n })
  const v = out.followers.find((f) => f.account === M.vault)
  assert.ok(v, 'a vault can follow')
  assert.equal(v.balanceAtF, '0')
  assert.equal(v.balanceAtB, String(1150n * ONE))
  assert.equal(v.vaulted, '0', 'it is no user of a vault')
  assert.equal(v.exposed, String(1000n * ONE), 'min(T_i, 1150)')
  assert.equal(v.exited, String(50n * ONE), "the release to F4 leaves the vault's wallet")
  const k = await priceKit(chain, BigInt(out.pRef))
  assert.equal(v.exitCredit, String(k.credit(M.vault, [26n])))
  assert.equal(v.cost, String(ONE / 10n - k.credit(M.vault, [26n])))
  // and the pad's lock into it (from the pad) is no unexplained inflow
})

test('L-1: a release from a vault that locked before the range, its VaultReleased dropped, is refused', async () => {
  const ok = await settle(mockChain({ oldVault: true }).client, { bond: M.bond, id: 1n, chunk: 100n })
  assert.equal(ok.out.followers.find((f) => f.account === MF(1)).balanceAtB, String(1040n * ONE))
  const c = mockChain({ oldVault: true })
  c.setDrop((name, from, to) => name === 'VaultReleased' && from <= 26n && to >= 26n)
  await refuses(c, 100n, /got 40000000000000000000 from others than the pad before graduation, VaultReleased says 0: logs are incomplete/)
})

test('M-3 PoC: one dropped TradeV1 chunk holding a whole round trip is refused', async () => {
  // chunk 9: [406, 414] holds the buy at 408 and the sell at 411; sold and realQuote are back by 414
  const c = mockChain()
  c.setDrop((name, from, to) => name === 'TradeV1' && from <= 408n && to >= 411n)
  await refuses(c, 9n, /blocks 406–414: the pad sent .* logs are incomplete/)
  // the same with the pad's Transfer logs dropped instead
  const d = mockChain()
  d.setDrop((name, from, to, args) => name === 'Transfer' && String(args.from).toLowerCase() === M.pad.toLowerCase() && from <= 408n && to >= 408n)
  await refuses(d, 9n, /the pad sent 0 .* logs are incomplete/)
  // or the VaultLocked log
  const e = mockChain()
  e.setDrop((name) => name === 'VaultLocked')
  await refuses(e, 9n, /logs are incomplete/)
  // or the VaultReleased log: F4's 50 back from the vault would count twice
  const f = mockChain()
  f.setDrop((name) => name === 'VaultReleased')
  await refuses(f, 9n, /got 50000000000000000000 from others than the pad before graduation, VaultReleased says 0: logs are incomplete/)
})

test('M-2: a dropped chunk of Transfer logs is refused', async () => {
  // the chunk holding the caller's buy back (23) and final sale (30): they net to zero, and would move B to 20
  const c = mockChain()
  c.setDrop((name, from, to) => name === 'Transfer' && from <= 23n && to >= 30n)
  await refuses(c, 10n, /transfer logs are incomplete/)
  // only the final sale's chunk
  const d = mockChain()
  d.setDrop((name, from, to) => name === 'Transfer' && from <= 30n && to >= 30n && to < 32n)
  await refuses(d, 5n, /incomplete/)
})

test('M-3: dropped TradeV1 chunks whose trades net to zero are refused', async () => {
  // the round trip 408 / 411 spans the chunks [310, 409] and [410, 509]: dropping both keeps the sold chain intact
  const c = mockChain()
  c.setDrop((name, from, to) => name === 'TradeV1' && from >= 310n && to <= 509n)
  await refuses(c, 100n, /the curve at the end of block 409/)
  // a single dropped chunk with a one-way trade
  const d = mockChain()
  d.setDrop((name, from, to) => name === 'TradeV1' && from <= 5000n && to >= 5000n)
  await refuses(d, 100n, /incomplete/)
})

test('M-1: a dropped chunk of Sync logs is refused', async () => {
  // graduation at 2000; the Sync at 2600 is dropped: the price would stay at the migration's
  const c = mockChain({ graduateAt: 2000n })
  c.setDrop((name, from, to) => name === 'Sync' && from <= 2600n && to >= 2600n)
  await refuses(c, 100n, /reserves at the end of block 2699/)
  // every Sync gone
  const d = mockChain({ graduateAt: 2000n })
  d.setDrop((name) => name === 'Sync')
  await refuses(d, 100n, /no Sync between the graduation|reserves/)
})

let checks = 0
for (const [name, fn] of tests) {
  try {
    await fn()
    checks++
  } catch (e) {
    console.error(`FAIL ${name}`)
    throw e
  }
}
console.log(`settle: all ${checks} checks passed`)
