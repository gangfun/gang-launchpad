// The payout rule of docs/SPEC-AGENT-CALLS-2026-11-09.md §5.3, with no chain access: testable on its own.
// Prices are quote wei per 1e18 token wei (TradeV1.postPrice's unit); every division rounds down.
import { encodeAbiParameters, keccak256, concat, toHex } from 'viem'

export const ONE = 10n ** 18n
/** The follow window after the note block's time, and the P_ref window from T_B (seconds). */
export const FOLLOW_WINDOW = 24n * 3600n
export const PRICE_WINDOW = 3600n

// ---------------------------------------------------------------- the follow ref (skill/gang-cli/src/notes.js)
const MAGIC_V1 = '67616e6701'
const MAGIC_V2 = '67616e6702'
const FOLLOW_MAGIC = '67616e6703'
const TX_RE = /^0x[0-9a-f]{64}$/

/** The note suffix at the very end of a tx input, or null: same as notes.js readNoteCommit (and the server's). */
function readNoteCommit(s) {
  const v2 = s.slice(-82)
  if (v2.length === 82 && v2.startsWith(MAGIC_V2)) {
    const revealAfter = parseInt(v2.slice(10, 18), 16)
    if (revealAfter >= 3600 && revealAfter <= 72 * 3600) return { version: 2 }
  }
  const v1 = s.slice(-74)
  if (v1.length === 74 && v1.startsWith(MAGIC_V1)) return { version: 1 }
  return null
}

/**
 * The note tx a tx input follows, or null: notes.js readFollowRef. "gang" 03 noteTx (37 bytes) right before the input's
 * note suffix, or its last 37 bytes when it has none ([calldata][tool][ref][follow][note]); nowhere else counts.
 */
export function readFollowRef(input) {
  const s = String(input || '').toLowerCase()
  const c = readNoteCommit(s)
  const end = s.length - (c ? (c.version === 2 ? 82 : 74) : 0)
  const f = s.slice(Math.max(0, end - 74), end)
  const tx = `0x${f.slice(10)}`
  return f.length === 74 && f.startsWith(FOLLOW_MAGIC) && TX_RE.test(tx) ? tx : null
}

// ---------------------------------------------------------------- §5.3.1–2: end-of-block balances, the violation block
const pos = (a, b) => (a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : a.blockNumber < b.blockNumber ? -1 : 1)

/**
 * The caller's end-of-block balances, rebuilt backwards from the balance the report read (CallBondReported.balance, at
 * the report's position in block R). `transfers`: every Transfer of the token touching the caller from the post block
 * through R, as { blockNumber, logIndex, delta } (delta signed for the caller). Returns `endOf(block)` for blocks from
 * postBlock − 1 to R − 1, and `atPost`, the balance when `post` ran.
 */
export function callerBalances({ reportBalance, reportBlock, reportLogIndex, postBlock, postLogIndex, transfers }) {
  const ts = [...transfers].sort(pos)
  for (const t of ts) if (t.blockNumber < postBlock || t.blockNumber > reportBlock) throw new Error('a transfer outside the post block … report block')
  // end of R − 1 = the report's balance less what moved in R before the report
  let bal = reportBalance
  for (const t of ts) if (t.blockNumber === reportBlock && t.logIndex < reportLogIndex) bal -= t.delta
  // walking back: end of block X − 1 = end of X − what moved in X
  const deltaOf = new Map()
  for (const t of ts) if (t.blockNumber < reportBlock) deltaOf.set(t.blockNumber, (deltaOf.get(t.blockNumber) ?? 0n) + t.delta)
  const changes = [...deltaOf.keys()].sort((a, b) => (a < b ? 1 : a > b ? -1 : 0)) // descending
  const steps = [{ from: reportBlock - 1n, bal }] // end-of-block balance is `bal` on [next change … from]
  for (const c of changes) {
    bal -= deltaOf.get(c)
    steps.push({ from: c - 1n, bal })
  }
  const endOf = (block) => {
    if (block >= reportBlock || block < postBlock - 1n) throw new Error(`no end-of-block balance for ${block}`)
    let out = steps[0].bal
    for (const s of steps) if (s.from >= block) out = s.bal
    return out
  }
  // end of R: what moved in R after the report too (for the checks against the node's state)
  let atR = reportBalance
  for (const t of ts) if (t.blockNumber === reportBlock && t.logIndex > reportLogIndex) atR += t.delta
  const endOfAny = (block) => (block === reportBlock ? atR : endOf(block))
  let atPost = endOf(postBlock - 1n)
  for (const t of ts) if (t.blockNumber === postBlock && t.logIndex < postLogIndex) atPost += t.delta
  if (atPost < 0n || steps.some((s) => s.bal < 0n)) throw new Error('a negative balance: transfer logs are incomplete')
  return { endOf: endOfAny, atPost, changes }
}

/**
 * §5.3.2: B, the first block of the run of end-of-block balances below `hold` that holds the report block R: the block
 * after the last one before R ending at or above `hold` (R itself when R − 1 did). Never before the post block: the
 * promise started there.
 */
export function violationBlock({ endOf, changes, hold, reportBlock, postBlock }) {
  // `changes`: the blocks before R where the caller's balance moved, descending
  if (endOf(reportBlock - 1n) >= hold) return reportBlock
  // the balance only changes at blocks with a transfer; between them the end-of-block balance stays the same
  for (const c of changes) {
    if (c < postBlock) break
    if (c === postBlock) return postBlock
    if (endOf(c - 1n) >= hold) return c
  }
  return postBlock
}

// ---------------------------------------------------------------- §5.3.3–4: the followers
/**
 * Follow buys per account ({ quote, tokens, txs, firstBlock = F_i }). `trades`: TradeV1 logs { transactionHash, blockNumber, logIndex, token, trader, isBuy,
 * quoteAmount, tokenAmount }; `txOf(hash)` -> { from, input }. A tx counts when its input's follow ref is `noteTx`, its
 * block is after the note's block, at most `followEndBlock` (the last block at or before the note's time + 24 h) and
 * before B, and its sender is neither the caller nor the token's `creator`; its amount is the sum of its TradeV1 buys of `token` with
 * trader == tx.from, and it must reach `minQuote`.
 */
export function followBuys({ trades, txOf, noteTx, noteBlock, followEndBlock, B, caller, creator = null, token, minQuote }) {
  const note = noteTx.toLowerCase()
  const callerL = caller.toLowerCase()
  const creatorL = creator ? creator.toLowerCase() : null
  const tokenL = token.toLowerCase()
  const byTx = new Map()
  for (const t of trades) {
    if (t.blockNumber <= noteBlock || t.blockNumber > followEndBlock || t.blockNumber >= B) continue
    if (!t.isBuy || t.token.toLowerCase() !== tokenL) continue
    if (t.trader.toLowerCase() === callerL) continue // trader must be tx.from, and tx.from must not be the caller
    ;(byTx.get(t.transactionHash) ?? byTx.set(t.transactionHash, []).get(t.transactionHash)).push(t)
  }
  const out = new Map()
  for (const [hash, list] of byTx) {
    const tx = txOf(hash)
    if (!tx) throw new Error(`no transaction ${hash}`)
    const from = tx.from.toLowerCase()
    if (from === callerL || from === creatorL) continue // nor the token's creator (it gets 70% of the fee back)
    if (readFollowRef(tx.input) !== note) continue
    let quote = 0n
    let tokens = 0n
    for (const t of list) {
      if (t.trader.toLowerCase() !== from) continue
      quote += t.quoteAmount
      tokens += t.tokenAmount
    }
    if (tokens === 0n || quote < minQuote) continue
    const block = list[0].blockNumber
    const f = out.get(from) ?? { quote: 0n, tokens: 0n, txs: [], firstBlock: block }
    f.quote += quote
    f.tokens += tokens
    f.txs.push(hash)
    if (block < f.firstBlock) f.firstBlock = block
    out.set(from, f)
  }
  return out
}

// ---------------------------------------------------------------- §5.3.5: P_ref
/** Each block's end price: the last of its price events ({ blockNumber, logIndex, price }), in chain order. */
export function endOfBlockPrices(events) {
  const last = new Map()
  for (const e of [...events].sort(pos)) last.set(e.blockNumber, e.price)
  return [...last].map(([blockNumber, price]) => ({ blockNumber, price }))
}

/**
 * Σ over s in [start, start + len) of the price at the end of the last block with timestamp ≤ s. `seed`: the price at
 * the end of the block before the first in `points` (blocks from B on: { timestamp, price }, ascending). Returns the sum
 * and P_ref = sum / len.
 */
export function priceAverage({ seed, points, start, len = PRICE_WINDOW }) {
  for (let i = 1; i < points.length; i++) if (points[i].timestamp < points[i - 1].timestamp) throw new Error('points out of order')
  let cur = seed
  let i = 0
  let sum = 0n
  for (let s = start; s < start + len; s++) {
    while (i < points.length && points[i].timestamp <= s) cur = points[i++].price
    sum += cur
  }
  return { sum, pRef: sum / len }
}

/** The pair's price from Sync reserves: quote per 1e18 token. */
export function pairPrice(reserve0, reserve1, tokenIsToken0) {
  const [t, q] = tokenIsToken0 ? [reserve0, reserve1] : [reserve1, reserve0]
  if (t === 0n) throw new Error('empty pair reserve')
  return (q * ONE) / t
}

/** The curve's price (CurveLogic3._price) from `curves(token)`. */
export function curvePrice({ virtualQuote, realQuote, sold }, virtualToken) {
  return ((virtualQuote + realQuote) * ONE) / (virtualToken - sold)
}

/**
 * Every TradeV1 of the token in a range, in chain order, carries the curve's `sold` after it: each must follow from the
 * one before (+ tokens on a buy, − on a sell), from `soldBefore` (sold at the end of the block before the range) to
 * `soldAfter` (at the end of the range). A missing log breaks the chain.
 */
export function checkSoldChain(trades, soldBefore, soldAfter) {
  let sold = soldBefore
  for (const t of [...trades].sort(pos)) {
    const next = t.isBuy ? sold + t.tokenAmount : sold - t.tokenAmount
    if (next !== t.sold) throw new Error(`TradeV1 in ${t.transactionHash} has sold ${t.sold}, expected ${next}: logs are incomplete`)
    sold = next
  }
  if (sold !== soldAfter) throw new Error(`TradeV1 logs end at sold ${sold}, the curve has ${soldAfter}: logs are incomplete`)
}

// ---------------------------------------------------------------- §5.3.6–7: losses and payouts
/** `account`'s TradeV1 sells of `token` in blocks [from, to): Σ quoteAmount (the curve's payout before the 1% fee). */
export function sellsBetween(trades, account, token, from, to) {
  const a = account.toLowerCase()
  const tk = token.toLowerCase()
  let quote = 0n
  for (const t of trades) {
    if (t.isBuy || t.trader.toLowerCase() !== a || t.token.toLowerCase() !== tk) continue
    if (t.blockNumber >= from && t.blockNumber < to) quote += t.quoteAmount
  }
  return quote
}

/**
 * §5.3.6, the ways `account`'s tokens leave it in blocks [from, to):
 * - to the pad before the Graduated log: a curve sell (TradeV1, lowers C_i by its quoteAmount) or a vaultLock (still
 *   held); never an exit here;
 * - to itself: nothing left;
 * - anything else (a pool sale, a transfer to another address): an exit. Returns the exits, one per Transfer, as
 *   { blockNumber, logIndex, tokens }, in chain order.
 * `transfersOut`: { blockNumber, logIndex, from, to, value }; `grad`: the Graduated log's position or null.
 */
export function exitsOf({ account, transfersOut, pad, grad, from, to }) {
  const a = account.toLowerCase()
  const padL = pad.toLowerCase()
  const out = []
  for (const t of transfersOut) {
    if (t.from.toLowerCase() !== a || t.blockNumber < from || t.blockNumber >= to) continue
    const dest = t.to.toLowerCase()
    if (dest === a) continue
    if (dest === padL && (!grad || pos(t, grad) < 0)) continue
    out.push({ blockNumber: t.blockNumber, logIndex: t.logIndex, tokens: t.value })
  }
  return out.sort(pos)
}

/**
 * The spot price right before a log: the last price event ({ blockNumber, logIndex, price }) before it in chain order,
 * else `seed` (the price at the end of the block before the events start).
 */
export function spotLookup(seed, events) {
  const sorted = [...events].sort(pos)
  return (at) => {
    let lo = 0
    let hi = sorted.length
    while (lo < hi) {
      const m = (lo + hi) >> 1
      if (pos(sorted[m], at) < 0) lo = m + 1
      else hi = m
    }
    return lo === 0 ? seed : sorted[lo - 1].price
  }
}

/**
 * X_i = Σ over exits (tokens × max(the spot right before that Transfer, its block's end price, P_ref)) / 1e18, rounded
 * down once: selling high and dumping in the same block can't price the exit at the dumped price.
 */
export function exitCredit(exits, { spotBefore, priceAtEndOf }, pRef) {
  let sum = 0n
  for (const x of exits) {
    let p = pRef
    const spot = spotBefore(x)
    const end = priceAtEndOf(x.blockNumber)
    if (spot > p) p = spot
    if (end > p) p = end
    sum += x.tokens * p
  }
  return sum / ONE
}

/**
 * Before graduation only the pad moves the token, and it sends a wallet tokens only as a buy (from the pad itself) or
 * a vaultRelease (from the vault). So `account`'s pre-graduation inflows from anyone but the pad (and itself) must add
 * up to its VaultReleased logs in the same range. Throws when they don't.
 */
export function checkVaultInflows({ account, transfersIn, releases, pad, grad, from, to }) {
  const a = account.toLowerCase()
  const padL = pad.toLowerCase()
  const pre = (l) => l.blockNumber >= from && l.blockNumber < to && (!grad || pos(l, grad) < 0)
  const inflow = transfersIn
    .filter((t) => pre(t) && t.to.toLowerCase() === a && t.from.toLowerCase() !== padL && t.from.toLowerCase() !== a)
    .reduce((s, t) => s + t.value, 0n)
  const released = releases.filter((l) => pre(l) && l.user.toLowerCase() === a).reduce((s, l) => s + l.amount, 0n)
  if (inflow !== released) throw new Error(`${a} got ${inflow} from others than the pad before graduation, VaultReleased says ${released}: logs are incomplete`)
}

/**
 * What `account` put into vaults in [from, to) and still has there, by the pad's logs: Σ VaultLocked − Σ VaultReleased
 * (user = account), floored at 0. A release puts the tokens back in the wallet, where the balance at B counts them.
 */
export function vaultNet(locks, releases, account, from, to) {
  const a = account.toLowerCase()
  const sum = (list) => list.filter((l) => l.user.toLowerCase() === a && l.blockNumber >= from && l.blockNumber < to).reduce((s, l) => s + l.amount, 0n)
  const net = sum(locks) - sum(releases)
  return net > 0n ? net : 0n
}

/** The end-of-block price of any block from `seed`'s on: the last of `blockPrices` (ascending) at or before it. */
export function priceLookup(seed, blockPrices) {
  return (block) => {
    let p = seed
    let lo = 0
    let hi = blockPrices.length
    while (lo < hi) {
      const m = (lo + hi) >> 1
      if (blockPrices[m].blockNumber <= block) lo = m + 1
      else hi = m
    }
    if (lo > 0) p = blockPrices[lo - 1].price
    return p
  }
}

/**
 * §5.3.6–7. `followers`: account -> { quote, tokens (T_i), firstBlock (F_i) }; `balanceAtB(a)` / `balanceAtF(a)`: its
 * balance at the start of B / of F_i; `soldQuote(a)`: its curve sells in [F_i, B) (Σ TradeV1 quoteAmount);
 * `vaulted(a)`: vaultNet; `exitCredit(a)`: X_i.
 * - e_i = min(T_i, max(0, balance at B − balance at F_i + vaulted)): only what the follows added and it still holds;
 * - C_i = max(0, Σ follow quote − soldQuote − X_i): what it really spent, less what it got out by other ways;
 * - loss_i = max(0, C_i − e_i × P_ref / 1e18), rounded down.
 * When the losses top the pool, each gets loss × pool / Σloss, rounded down. avgPrice (quote × 1e18 / tokens) is only
 * shown.
 */
export function allocate({ followers, balanceAtB, balanceAtF, soldQuote, vaulted = () => 0n, exitCredit: credit = () => 0n, pRef, pool }) {
  const rows = []
  for (const [account, f] of followers) {
    const avgPrice = (f.quote * ONE) / f.tokens
    const bAtB = balanceAtB(account)
    const bAtF = balanceAtF(account)
    const locked = vaulted(account)
    const added = bAtB + locked > bAtF ? bAtB + locked - bAtF : 0n
    const e = f.tokens < added ? f.tokens : added
    const sold = soldQuote(account)
    const x = credit(account)
    const cost = f.quote > sold + x ? f.quote - sold - x : 0n
    const num = cost * ONE - e * pRef
    const loss = num > 0n ? num / ONE : 0n
    rows.push({ account, quote: f.quote, tokens: f.tokens, txs: f.txs ?? [], firstBlock: f.firstBlock, avgPrice, balanceAtF: bAtF, balanceAtB: bAtB, vaulted: locked, exitCredit: x, exposed: e, soldQuote: sold, cost, loss })
  }
  const sumLoss = rows.reduce((s, r) => s + r.loss, 0n)
  const capped = sumLoss > pool
  for (const r of rows) r.paid = capped ? (r.loss * pool) / sumLoss : r.loss
  const total = rows.reduce((s, r) => s + r.paid, 0n)
  return { rows: rows.sort((a, b) => (a.account < b.account ? -1 : 1)), sumLoss, capped, total }
}

/**
 * An account's end-of-block balances rebuilt forwards: `startBalance` at the end of fromBlock − 1, then `transfers`
 * ({ blockNumber, delta }) in [fromBlock, toBlock]. Returns endOf(n) for n in [fromBlock − 1, toBlock].
 */
export function forwardBalances({ startBalance, fromBlock, toBlock, transfers }) {
  const deltaOf = new Map()
  for (const t of transfers) {
    if (t.blockNumber < fromBlock || t.blockNumber > toBlock) throw new Error('a transfer outside the range')
    deltaOf.set(t.blockNumber, (deltaOf.get(t.blockNumber) ?? 0n) + t.delta)
  }
  const blocks = [...deltaOf.keys()].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0))
  const steps = []
  let bal = startBalance
  for (const b of blocks) {
    bal += deltaOf.get(b)
    if (bal < 0n) throw new Error('a negative balance: transfer logs are incomplete')
    steps.push([b, bal])
  }
  return (n) => {
    if (n < fromBlock - 1n || n > toBlock) throw new Error(`no end-of-block balance for ${n}`)
    let out = startBalance
    for (const [b, v] of steps) if (b <= n) out = v
    return out
  }
}

/**
 * Before graduation only the pad moves the token, so every token Transfer touching the pad is one of: a curve buy
 * (pad → trader), a curve sell (→ pad), a vaultLock (user → pad → vault: VaultLocked) or the graduation migration
 * (pad → migrator: Graduated.tokenAmount); mints (from 0) are left out (vaultRelease goes vault → user, past the pad).
 * Per segment [lo, hi] (consecutive chunk ends of all the streams), the tokens out of and into the pad must match those
 * logs each way, so a dropped chunk of any one stream shows even when its trades net to zero. Only logs up to the
 * Graduated log count (after it, transfers are free). Logs: { blockNumber, logIndex, ... }; transfers { from, to,
 * value }, trades as TradeV1, locks { amount }, grad { tokenAmount } or null.
 */
export function checkPadFlows({ from, ends, pad, fromPad, toPad, trades, locks, grad }) {
  const padL = pad.toLowerCase()
  const zero = '0x0000000000000000000000000000000000000000'
  const live = (l) => !grad || pos(l, grad) <= 0
  const bounds = [...new Set(ends)].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0))
  let lo = from
  for (const hi of bounds) {
    if (hi < lo) continue
    const inSeg = (l) => l.blockNumber >= lo && l.blockNumber <= hi && live(l)
    const sum = (list, f) => list.filter(inSeg).reduce((s, l) => s + f(l), 0n)
    const out = sum(fromPad.filter((t) => t.from.toLowerCase() === padL && t.to.toLowerCase() !== padL), (t) => t.value)
    const into = sum(toPad.filter((t) => t.to.toLowerCase() === padL && t.from.toLowerCase() !== padL && t.from.toLowerCase() !== zero), (t) => t.value)
    const buys = sum(trades.filter((t) => t.isBuy), (t) => t.tokenAmount)
    const sells = sum(trades.filter((t) => !t.isBuy), (t) => t.tokenAmount)
    const locked = sum(locks, (l) => l.amount)
    const migrated = grad && grad.blockNumber >= lo && grad.blockNumber <= hi ? grad.tokenAmount : 0n
    if (out !== buys + locked + migrated || into !== sells + locked) {
      throw new Error(
        `blocks ${lo}–${hi}: the pad sent ${out} / took ${into} tokens, the trades, vault locks and graduation say ${buys + locked + migrated} / ${sells + locked}: logs are incomplete`,
      )
    }
    lo = hi + 1n
  }
}

/** The last of `logs` (sorted in chain order) at or before the end of `block`, or null. */
export function lastAtOrBefore(logs, block) {
  let lo = 0
  let hi = logs.length
  while (lo < hi) {
    const m = (lo + hi) >> 1
    if (logs[m].blockNumber <= block) lo = m + 1
    else hi = m
  }
  return lo === 0 ? null : logs[lo - 1]
}

// ---------------------------------------------------------------- §5.3.8: the tree
/** GangCallBond.leaf: keccak256(bytes.concat(keccak256(abi.encode(contract, chainId, id, account, amount)))). */
export function leafHash(contract, chainId, id, account, amount) {
  const inner = keccak256(
    encodeAbiParameters(
      [{ type: 'address' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'address' }, { type: 'uint256' }],
      [contract, BigInt(chainId), BigInt(id), account, amount],
    ),
  )
  return keccak256(concat([inner]))
}

function hashPair(a, b) {
  return BigInt(a) < BigInt(b) ? keccak256(concat([a, b])) : keccak256(concat([b, a]))
}

/** The root posted when no follower is owed anything (total 0): the contract refuses a zero root. */
export const EMPTY_ROOT = keccak256(toHex('callbond-v1: no follower is owed anything'))

/**
 * A Merkle tree over the leaves sorted by hash; an odd node moves up as is; a single leaf is its own root (as
 * scripts/promote-settle). Proofs verify with OpenZeppelin MerkleProof. `amounts`: account -> amount; 0 amounts left out.
 */
export function buildTree(amounts, leafOf) {
  const leaves = [...amounts.entries()]
    .filter(([, a]) => a > 0n)
    .map(([account, amount]) => ({ account, amount, hash: leafOf(account, amount) }))
    .sort((x, y) => (BigInt(x.hash) < BigInt(y.hash) ? -1 : 1))
  if (leaves.length === 0) return { root: EMPTY_ROOT, total: 0n, leaves: [] }
  const layers = [leaves.map((l) => l.hash)]
  while (layers[layers.length - 1].length > 1) {
    const cur = layers[layers.length - 1]
    const up = []
    for (let i = 0; i < cur.length; i += 2) up.push(i + 1 < cur.length ? hashPair(cur[i], cur[i + 1]) : cur[i])
    layers.push(up)
  }
  const proofOf = (index) => {
    const proof = []
    let i = index
    for (const layer of layers.slice(0, -1)) {
      const sib = i ^ 1
      if (sib < layer.length) proof.push(layer[sib])
      i >>= 1
    }
    return proof
  }
  return {
    root: layers[layers.length - 1][0],
    total: leaves.reduce((s, l) => s + l.amount, 0n),
    leaves: leaves.map((l, i) => ({ account: l.account, amount: l.amount, proof: proofOf(i) })),
  }
}

/** MerkleProof.verify. */
export function verify(proof, root, leaf) {
  return proof.reduce((h, p) => hashPair(h, p), leaf) === root
}

/** --check: the recomputed root and total against the bond's posted ones. */
export function compareRoot({ root, total }, posted) {
  if (BigInt(posted.root) === 0n) return { ok: false, reason: 'no root is posted (none yet, or vetoed)' }
  if (root.toLowerCase() !== posted.root.toLowerCase() || total !== posted.total) {
    return { ok: false, reason: `recomputed ${root} / ${total}, posted ${posted.root} / ${posted.total}` }
  }
  return { ok: true }
}
