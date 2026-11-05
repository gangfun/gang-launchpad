#!/usr/bin/env node
// Compute a settlement for one GangPromotePoolModule (docs/SPEC-PROMOTER-POOL-SHARE-2026-11-05.md §4). Read-only: it
// prints the root and the leaves; posting is the settler's. Anyone can run it to check a posted root.
//
//   RPC_URL=<a node keeping full logs> [ROUTERS=0x…,0x…] node settle.mjs --module 0x… --through <block> [--prev prev.json]
//
// First period: set FROM_BLOCK to the block of the module's Bound event (or earlier). --prev is the JSON this printed for
// the previous period. Exits non-zero, printing no root, when the logs don't reconcile with the contracts' state.
// --check: recompute a root already posted at --through (pending or in effect, a closed module too) and compare it;
// exits non-zero on a mismatch. To check independently, run it WITHOUT --prev, from FROM_BLOCK: a root commits only to the
// cumulative amounts, so a --prev someone else made can carry a tampered queue and make a wrong root look right.
import { readFileSync } from 'node:fs'
import { parseArgs } from 'node:util'
import { createPublicClient, http, parseAbi, parseAbiItem, getAddress } from 'viem'
import { apply, emptyState, loadState, saveState, buildTree, promoterOf } from './lib.mjs'

const { values: args } = parseArgs({
  options: {
    module: { type: 'string' },
    through: { type: 'string' },
    prev: { type: 'string' },
    chunk: { type: 'string', default: '2000' },
    check: { type: 'boolean', default: false },
  },
})
if (!args.module || !args.through || !process.env.RPC_URL) {
  console.error('usage: RPC_URL=… [ROUTERS=0x…,0x…] node settle.mjs --module 0x… --through <block> [--prev prev.json] [--check] [--chunk 2000]')
  process.exit(2)
}

const client = createPublicClient({ transport: http(process.env.RPC_URL, { retryCount: 5, batch: { batchSize: 100 } }) })
const WBNB_MAINNET = '0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c'
/** Called directly by a wallet, these let the tx sender stand in for the address that moved the tokens (spec §4). */
const ROUTERS_MAINNET = [
  '0xec9717e5c68b9f18fa76d3961c9cd7e67b5e61e7', // GangRouter of 3.0
  '0x10ed43c718714eb63d5aa57b78b54704e256024e', // Pancake V2
  '0x1de460f363af910f51726def188f9004276bf4bc', // the aggregator's three routers (docs/MAINNET-GANG-LAUNCHPAD-3-2026-11-03.md)
  '0xdb97fc3329ed1939012d56eceaef00be1c0cdff5',
  '0x3508dca95a64c9378cb07ef6f40553a50905372a',
]
const moduleAbi = parseAbi([
  'function token() view returns (address)',
  'function quote() view returns (address)',
  'function pad() view returns (address)',
  'function dev() view returns (address)',
  'function taxHandler() view returns (address)',
  'function shareBps() view returns (uint16)',
  'function window() view returns (uint32)',
  'function escrowIn() view returns (uint256)',
  'function reclaimed() view returns (uint256)',
  'function closed() view returns (bool)',
  'function root() view returns (bytes32)',
  'function pendingRoot() view returns (bytes32)',
  'function allocatedTotal() view returns (uint256)',
  'function pendingAllocated() view returns (uint256)',
  'function throughBlock() view returns (uint64)',
  'function pendingThroughBlock() view returns (uint64)',
])
const padAbi = parseAbi(['function bindingOf(address,address) view returns (address,uint40,bool)'])
const tokenAbi = parseAbi(['function buyTaxBps() view returns (uint16)', 'function sellTaxBps() view returns (uint16)', 'function pair() view returns (address)'])
const handlerAbi = parseAbi(['function accruedTax(address) view returns (uint256)'])
const OUTER = parseAbiItem('event OuterTax(address indexed from, address indexed to, uint256 taxed, uint256 net)')
const SPLIT = parseAbiItem('event Split(uint256 incoming, uint256 toEscrow, uint256 toDev)')
const BOUND = parseAbiItem('event Bound(address indexed token, address indexed quote, uint16 shareBps, uint32 window)')
const SOLD = parseAbiItem('event TaxChunkSold(address indexed token, uint256 taxTokens, uint256 quoteOut, uint256 holderUnits, bool swapBack)')
const DIST = parseAbiItem('event TaxDistributed(address indexed token, uint8 phase, uint256 amount, uint256 toPlatform, uint256 toDividend, uint256 toRecipient)')
const PAID = parseAbiItem('event TaxPaid(address indexed token, address indexed recipient, address indexed quote, uint256 amount)')
const OWED = parseAbiItem('event TaxOwed(address indexed token, address indexed recipient, address indexed quote, uint256 amount)')

const die = (msg) => {
  console.error(`settle: ${msg}`)
  process.exit(1)
}

/** Logs over a range, halving a chunk the node refuses. */
async function logs(address, event, from, to, filter) {
  const out = []
  let step = BigInt(args.chunk)
  for (let a = from; a <= to; ) {
    const b = a + step - 1n < to ? a + step - 1n : to
    try {
      out.push(...(await client.getLogs({ address, event, args: filter, fromBlock: a, toBlock: b })))
      a = b + 1n
    } catch (e) {
      if (step <= 1n) throw e
      step /= 2n
    }
  }
  return out
}

/** Public nodes can return nothing for old ranges without an error: on mainnet, WBNB has logs in nearly every block. */
async function assertNodeKeepsLogs(from, to) {
  if ((await client.getChainId()) !== 56) return
  const span = to - from
  for (const b of [from, from + span / 3n, from + (2n * span) / 3n, to]) {
    let seen = false
    for (let i = 0n; i < 5n && !seen; i++) {
      seen = (await client.getLogs({ address: WBNB_MAINNET, fromBlock: b + i, toBlock: b + i })).length > 0
    }
    if (!seen) die(`the node returned no WBNB logs around block ${b}: it does not keep this range`)
  }
}

const order = (a, b) => (a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : a.blockNumber < b.blockNumber ? -1 : 1)

const moduleAddr = getAddress(args.module)
const read = (functionName, blockNumber) => client.readContract({ address: moduleAddr, abi: moduleAbi, functionName, blockNumber })
const [token, quote, pad, dev, handler, shareBps, window_, closed] = await Promise.all(
  ['token', 'quote', 'pad', 'dev', 'taxHandler', 'shareBps', 'window', 'closed'].map((f) => read(f)),
)
if (BigInt(token) === 0n) die('module not bound')
if (closed && !args.check) die('the module is closed: the dev reclaimed, no more roots can be posted')

const finalized = (await client.getBlock({ blockTag: 'finalized' })).number
const through = BigInt(args.through)
if (through > finalized) die(`--through ${through} is past the finalized block ${finalized}`)

const prev = args.prev ? JSON.parse(readFileSync(args.prev, 'utf8')) : null
if (prev && getAddress(prev.module) !== moduleAddr) die('--prev is for another module')
const lastThrough = prev ? BigInt(prev.throughBlock) : 0n
if (prev && buildTree(loadState(prev.state).cumulative).root !== prev.root) die("--prev's state doesn't give its root")
const [chainRoot, chainPending, chainThrough, pendingThrough, chainAllocated, pendingAllocated] = await Promise.all(
  ['root', 'pendingRoot', 'throughBlock', 'pendingThroughBlock', 'allocatedTotal', 'pendingAllocated'].map((f) => read(f)),
)
const isPending = pendingThrough !== 0n
const onChainThrough = isPending ? pendingThrough : chainThrough
const onChainRoot = isPending ? chainPending : chainRoot
if (args.check) {
  if (BigInt(args.through) !== chainThrough && BigInt(args.through) !== pendingThrough) die(`no posted root at block ${args.through}`)
  if (BigInt(args.through) <= lastThrough) die('--prev is not before --through')
} else {
  // a root posted or vetoed since --prev was made means --prev isn't the last one
  if (onChainThrough !== lastThrough) {
    die(`--prev ends at block ${lastThrough}, the module's last root at ${onChainThrough}. Run --check --through ${onChainThrough} without --prev to rebuild it`)
  }
  if (prev && prev.root !== onChainRoot) die(`--prev's root ${prev.root} is not the module's last root ${onChainRoot}`)
  if (through <= lastThrough) die('--through is not past the last root')
}

let from
if (prev) {
  from = lastThrough + 1n
} else {
  const start = BigInt(process.env.FROM_BLOCK ?? 0)
  if (start === 0n) die("first period: set FROM_BLOCK to the block of the module's Bound event or earlier")
  const bound = await logs(moduleAddr, BOUND, start, finalized)
  if (bound.length !== 1) die(`expected one Bound event since FROM_BLOCK, got ${bound.length}`)
  from = bound[0].blockNumber
}
await assertNodeKeepsLogs(from, finalized)

const [pair, buyRate, sellRate] = await Promise.all(
  ['pair', 'buyTaxBps', 'sellTaxBps'].map((functionName) => client.readContract({ address: token, abi: tokenAbi, functionName })),
)
const pairL = pair.toLowerCase()
const routerList = process.env.ROUTERS ? process.env.ROUTERS.split(',') : (await client.getChainId()) === 56 ? ROUTERS_MAINNET : []
const routers = new Set(routerList.map((a) => a.trim().toLowerCase()))
// one list for a module's whole history: another list gives another root
if (prev && JSON.stringify([...routers].sort()) !== JSON.stringify([...prev.routers].sort())) die("--prev used another router list")

// everything up to `finalized`: only what is within `through` is settled, the rest is there to reconcile with the state
const [outer, sold, dist, paid, owed, splits] = await Promise.all([
  logs(token, OUTER, from, finalized),
  logs(handler, SOLD, from, finalized, { token }),
  logs(handler, DIST, from, finalized, { token }),
  logs(handler, PAID, from, finalized, { token, recipient: moduleAddr, quote }),
  logs(handler, OWED, from, finalized, { token, recipient: moduleAddr, quote }),
  logs(moduleAddr, SPLIT, from, finalized),
])

const hashes = [...new Set(outer.filter((l) => l.blockNumber <= through).map((l) => l.transactionHash))]
const txs = new Map()
await Promise.all(hashes.map(async (hash) => txs.set(hash, await client.getTransaction({ hash }))))
const blocks = [...new Set(outer.filter((l) => l.blockNumber <= through).map((l) => l.blockNumber))]
const times = new Map()
await Promise.all(blocks.map(async (n) => times.set(n, (await client.getBlock({ blockNumber: n })).timestamp)))

// a binding never changes once set and none is made after graduation, so a read now holds for every pool trade
const rowOf = (l) => {
  const tx = txs.get(l.transactionHash)
  return {
    pair: pairL,
    from: l.args.from.toLowerCase(),
    to: l.args.to.toLowerCase(),
    txFrom: tx.from.toLowerCase(),
    txTo: (tx.to ?? '').toLowerCase(),
    timestamp: times.get(l.blockNumber),
  }
}
const inRange = outer.filter((l) => l.blockNumber <= through && l.args.taxed > 0n)
const addresses = [...new Set(inRange.flatMap((l) => { const r = rowOf(l); return [r.from === pairL ? r.to : r.from, r.txFrom] }))]
const bindings = new Map()
await Promise.all(
  addresses.map(async (a) => {
    const [promoter, boundAt] = await client.readContract({ address: pad, abi: padAbi, functionName: 'bindingOf', args: [token, a] })
    if (BigInt(promoter) !== 0n) bindings.set(a, { promoter: promoter.toLowerCase(), boundAt })
  }),
)

// `_sellChunk` emits, per chunk, in this order: TaxPaid (or TaxOwed), TaxDistributed, TaxChunkSold. Several chunks can share
// a tx, so each looks only as far back as the chunk before it. A chunk with quote for the recipient has exactly one of the
// two: anything else means a log is missing, and a missing TaxPaid would otherwise pass the promoters' part to the dev.
const byTx = (list) => {
  const m = new Map()
  for (const l of list) (m.get(l.transactionHash) ?? m.set(l.transactionHash, []).get(l.transactionHash)).push(l)
  return m
}
const [soldByTx, distByTx, paidByTx, owedByTx] = [sold, dist, paid, owed].map(byTx)
const between = (index, s, lo) => (index.get(s.transactionHash) ?? []).filter((x) => x.logIndex < s.logIndex && x.logIndex > lo)
function chunkOf(s) {
  const before = (soldByTx.get(s.transactionHash) ?? []).filter((x) => x.logIndex < s.logIndex).at(-1)
  const lo = before ? before.logIndex : -1
  const ds = between(distByTx, s, lo)
  if (ds.length !== 1) die(`${ds.length} TaxDistributed for the chunk in ${s.transactionHash}: logs are incomplete`)
  const toRecipient = ds[0].args.toRecipient
  if (toRecipient === 0n) return { toRecipient, paid: false }
  // the log right before TaxDistributed: a `release` earlier in the same tx also emits TaxPaid, for other money
  const own = (index) => (index.get(s.transactionHash) ?? []).filter((x) => x.logIndex === ds[0].logIndex - 1)
  const ps = own(paidByTx)
  const os = own(owedByTx)
  if (ps.length + os.length !== 1 || (ps[0] ?? os[0]).args.amount !== toRecipient) {
    die(`the chunk in ${s.transactionHash} has no matching TaxPaid or TaxOwed: logs are incomplete`)
  }
  return { toRecipient, paid: ps.length === 1 }
}

const state = prev ? loadState(prev.state) : emptyState()
const ctx = { shareBps, dev: dev.toLowerCase() }
const events = [...inRange.map((l) => ({ t: 'trade', l })), ...sold.filter((l) => l.blockNumber <= through).map((l) => ({ t: 'chunk', l })), ...splits.filter((l) => l.blockNumber <= through).map((l) => ({ t: 'split', l }))]
events.sort((a, b) => order(a.l, b.l))
for (const { t, l } of events) {
  if (t === 'trade') {
    const isBuy = l.args.from.toLowerCase() === pairL
    apply(state, { kind: 'trade', tokens: l.args.taxed, rate: BigInt(isBuy ? buyRate : sellRate), promoter: promoterOf(rowOf(l), (a) => bindings.get(a), window_, routers) }, ctx)
  } else if (t === 'chunk') {
    apply(state, { kind: 'chunk', tokens: l.args.taxTokens, ...chunkOf(l) }, ctx)
  } else {
    apply(state, { kind: 'split', toEscrow: l.args.toEscrow }, ctx)
  }
}

// Reconcile with the contracts at `finalized`, or print nothing: a silently missing log would otherwise become a root
// nobody can take back (the allocated total only grows).
const later = (ls) => ls.filter((l) => l.blockNumber > through)
const taxedAll = state.totalTaxed + later(outer).reduce((s, l) => s + l.args.taxed, 0n)
const soldAll = state.totalChunks + later(sold).reduce((s, l) => s + l.args.taxTokens, 0n)
const escrowAll = state.totalEscrow + later(splits).reduce((s, l) => s + l.args.toEscrow, 0n)
const [escrowIn, reclaimed, accrued] = await Promise.all([
  read('escrowIn', finalized),
  read('reclaimed', finalized),
  client.readContract({ address: handler, abi: handlerAbi, functionName: 'accruedTax', args: [token], blockNumber: finalized }),
])
if (escrowAll !== escrowIn) die(`Split logs add up to ${escrowAll}, escrowIn() is ${escrowIn}: logs are incomplete`)
if (taxedAll - soldAll !== accrued) die(`taxed less sold is ${taxedAll - soldAll}, accruedTax is ${accrued}: logs are incomplete`)

const tree = buildTree(state.cumulative)
if (tree.allocatedTotal > escrowIn - reclaimed) die(`${tree.allocatedTotal} would be allocated, ${escrowIn - reclaimed} is escrowed`)

if (args.check) {
  const postedPending = through === pendingThrough
  const postedRoot = postedPending ? chainPending : chainRoot
  const postedAllocated = postedPending ? pendingAllocated : chainAllocated
  if (tree.root !== postedRoot || tree.allocatedTotal !== postedAllocated) {
    die(`recomputed ${tree.root} / ${tree.allocatedTotal}, posted ${postedRoot} / ${postedAllocated}`)
  }
  console.error(`settle: the root posted at block ${through} matches`)
}

console.log(
  JSON.stringify(
    {
      module: moduleAddr,
      token,
      fromBlock: from.toString(),
      throughBlock: through.toString(),
      trades: inRange.length,
      routers: [...routers],
      root: tree.root,
      allocatedTotal: tree.allocatedTotal.toString(),
      leaves: tree.leaves.map((l) => ({ account: l.account, amount: l.amount.toString(), proof: l.proof })),
      state: saveState(state),
    },
    null,
    2,
  ),
)
