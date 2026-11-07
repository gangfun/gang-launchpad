import assert from 'node:assert/strict'
import { weight, promoterOf, emptyState, apply, saveState, loadState, buildTree, leafHash, verify, EMPTY_ROOT } from './lib.mjs'

const PAIR = '0x00000000000000000000000000000000000000aa'
const W1 = '0x0000000000000000000000000000000000000001'
const W2 = '0x0000000000000000000000000000000000000002'
const AGG = '0x0000000000000000000000000000000000000003'
const ROUTER = '0x0000000000000000000000000000000000000004'
const OTHER = '0x0000000000000000000000000000000000000005'
const P1 = '0x0000000000000000000000000000000000000011'
const P2 = '0x0000000000000000000000000000000000000012'
const DEV = '0x0000000000000000000000000000000000000d00'
const WINDOW = 1000
const routers = new Set([ROUTER])
const bindings = { [W1]: { promoter: P1, boundAt: 100 }, [W2]: { promoter: P2, boundAt: 100 } }
const bindingOf = (a) => bindings[a]
const row = (o) => ({ pair: PAIR, timestamp: 200, txFrom: OTHER, txTo: OTHER, ...o })
const who = (o) => promoterOf(row(o), bindingOf, WINDOW, routers)

// the platform's part comes off first
assert.equal(weight(300n, 300n), 250n)
assert.equal(weight(100n, 50n), 0n)

// sell: the seller; buy: the receiver
assert.equal(who({ from: W1, to: PAIR }), P1)
assert.equal(who({ from: PAIR, to: W2 }), P2)
// the tx sender counts only when it called a listed router directly
assert.equal(who({ from: AGG, to: PAIR, txFrom: W1, txTo: ROUTER }), P1)
assert.equal(who({ from: AGG, to: PAIR, txFrom: W1, txTo: OTHER }), null, 'a bundler or filler lends nobody its binding')
assert.equal(who({ from: AGG, to: PAIR }), null)
// the window ends at boundAt + window, exclusive
assert.equal(who({ from: W1, to: PAIR, timestamp: 1099 }), P1)
assert.equal(who({ from: W1, to: PAIR, timestamp: 1100 }), null)
// the wallet's own binding comes first
assert.equal(who({ from: W1, to: PAIR, txFrom: W2, txTo: ROUTER }), P1)

const ctx = { shareBps: 2000, dev: DEV }
const run = (events, s = emptyState()) => {
  for (const e of events) apply(s, e, ctx)
  return s
}
const trade = (tokens, promoter, rate = 300n) => ({ kind: 'trade', tokens, rate, promoter })
const chunk = (tokens, toRecipient, paid = true) => ({ kind: 'chunk', tokens, toRecipient, paid })
const split = (toEscrow) => ({ kind: 'split', toEscrow })

// half the tokens sold were a bound trade's: 20% of the recipient's quote × half
let s = run([trade(100n, P1), trade(100n, null), chunk(200n, 1000n), split(200n)])
assert.equal(s.cumulative.get(P1), 100n)
assert.equal(s.cumulative.get(DEV), 100n)
assert.equal(s.queue.length, 0)

// first in, first out: only the oldest tokens were sold, so the later bound trade waits
s = run([trade(100n, null), trade(100n, P1), chunk(100n, 1000n), split(200n)])
assert.equal(s.cumulative.get(P1), undefined)
assert.equal(s.cumulative.get(DEV), 200n)
s = run([chunk(100n, 500n), split(100n)], s)
assert.equal(s.cumulative.get(P1), 100n)
assert.equal(s.cumulative.get(DEV), 200n)

// Audit M-3: a tiny bound trade around a large sale of someone else's tax gets its own part only, not the whole escrow
s = run([trade(1_000_000n, null), trade(1000n, P1), chunk(1_001_000n, 1_001_000n), split(200_200n)])
assert.equal(s.cumulative.get(P1), 199n, 'its own 1000 of 1,001,000 tokens, rounded down')
assert.equal(s.cumulative.get(DEV), 200_001n)

// different buy and sell rates: by what each trade leaves for the recipient
s = run([trade(100n, P1, 100n), trade(100n, P2, 500n), chunk(200n, 1400n), split(280n)])
assert.equal(s.cumulative.get(P1), (1400n * 2000n * 50n) / (10000n * 140n))
assert.equal(s.cumulative.get(P2), (1400n * 2000n * 90n) / (10000n * 140n))

// a chunk that didn't reach the module pays nobody; its later arrival is the dev's
s = run([trade(100n, P1), chunk(100n, 1000n, false), split(0n), split(200n)])
assert.equal(s.cumulative.get(P1), undefined)
assert.equal(s.cumulative.get(DEV), 200n)

// escrow over: nothing to pay out of, and what was due is dropped
s = run([trade(100n, P1), chunk(100n, 1000n), split(0n), trade(100n, P1), chunk(100n, 1000n), split(200n)])
assert.equal(s.cumulative.get(P1), 200n)
assert.equal(s.cumulative.get(DEV), undefined)

// more due than escrowed (wrong logs): capped, never above the escrow
s = run([trade(100n, P1), trade(100n, P2), chunk(200n, 1000n), split(100n)])
assert.equal(s.cumulative.get(P1) + s.cumulative.get(P2), 100n)

// a chunk selling more than was taxed means logs are missing
assert.throws(() => run([trade(1n, P1), chunk(2n, 1n)]), /incomplete/)

// a stray transfer's escrow is the dev's
s = run([split(50n)])
assert.equal(s.cumulative.get(DEV), 50n)

// the state survives the JSON between periods
s = run([trade(100n, P1), trade(50n, null), chunk(120n, 1000n)])
const back = loadState(JSON.parse(JSON.stringify(saveState(s))))
assert.deepEqual(saveState(back), saveState(s))
run([split(200n)], back)
assert.equal(back.cumulative.get(P1), 167n)

// a tree of any size verifies, and the total is what the contract caps
for (const n of [1, 2, 3, 4, 5, 8, 9, 17]) {
  const m = new Map()
  for (let i = 1; i <= n; i++) m.set(`0x${(i + 256).toString(16).padStart(40, '0')}`, BigInt(i))
  const t = buildTree(m)
  assert.equal(t.allocatedTotal, BigInt((n * (n + 1)) / 2))
  assert.equal(t.leaves.length, n)
  for (const l of t.leaves) assert.ok(verify(l.proof, t.root, leafHash(l.account, l.amount)), `n=${n}`)
  assert.ok(!verify(t.leaves[0].proof, t.root, leafHash(t.leaves[0].account, t.leaves[0].amount + 1n)))
}
// nothing allocated still gives a root to post
const none = buildTree(new Map())
assert.equal(none.root, EMPTY_ROOT)
assert.equal(none.allocatedTotal, 0n)

// the vector test/gang/GangPromotePoolModule.t.sol claims against
const vector = buildTree(new Map([[P1, 3n * 10n ** 17n], [P2, 5n * 10n ** 17n], [DEV, 12n * 10n ** 17n]]))
if (process.env.PRINT_VECTOR) console.log(JSON.stringify(vector, (_, v) => (typeof v === 'bigint' ? v.toString() : v)))
console.log('settle: all checks passed')
