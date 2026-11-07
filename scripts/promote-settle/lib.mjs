// The settlement rule of docs/SPEC-PROMOTER-POOL-SHARE-2026-11-05.md §4, with no chain access: testable on its own.
import { encodeAbiParameters, keccak256, concat, toHex } from 'viem'

const PLATFORM_BPS = 50n
const BPS = 10_000n

/** A trade's weight per its taxed tokens: what is left for the recipient once the platform's part is off (`rate` in bps). */
export function weight(tokens, rate) {
  if (rate <= PLATFORM_BPS) return 0n
  return (tokens * (rate - PLATFORM_BPS)) / rate
}

/**
 * The promoter a trade counts for. The wallet moving the tokens first; else, only when the tx called a listed router
 * directly, its sender. `row`: { pair, from, to, txFrom, txTo, timestamp }. `bindingOf(address)` -> { promoter, boundAt }.
 */
export function promoterOf(row, bindingOf, window, routers) {
  const wallet = row.from === row.pair ? row.to : row.from
  const who = [wallet]
  if (routers.has(row.txTo)) who.push(row.txFrom)
  for (const a of who) {
    const b = bindingOf(a)
    if (b && b.promoter && BigInt(row.timestamp) < BigInt(b.boundAt) + BigInt(window)) return b.promoter
  }
  return null
}

export function emptyState() {
  return { queue: [], pending: new Map(), cumulative: new Map(), totalTaxed: 0n, totalChunks: 0n, totalEscrow: 0n }
}

/**
 * Apply one event in chain order.
 * - { kind: 'trade', tokens, rate, promoter }: taxed tokens join the queue.
 * - { kind: 'chunk', tokens, toRecipient, paid }: the oldest taxed tokens sold; each trade's promoter is due the share of
 *   the recipient's quote its tokens fetched. A chunk whose quote didn't reach the module (`paid` false) pays nobody.
 * - { kind: 'split', toEscrow }: what is due since the last split is paid out of it, the rest is the dev's.
 *   A split that escrowed nothing (escrow over) pays nobody.
 */
export function apply(state, ev, { shareBps, dev }) {
  if (ev.kind === 'trade') {
    state.totalTaxed += ev.tokens
    state.queue.push({ tokens: ev.tokens, rate: ev.rate, promoter: ev.promoter })
    return
  }
  if (ev.kind === 'chunk') {
    state.totalChunks += ev.tokens
    let left = ev.tokens
    let all = 0n
    const parts = new Map()
    while (left > 0n && state.queue.length) {
      const head = state.queue[0]
      const take = head.tokens < left ? head.tokens : left
      const w = weight(take, head.rate)
      all += w
      if (head.promoter) parts.set(head.promoter, (parts.get(head.promoter) ?? 0n) + w)
      head.tokens -= take
      left -= take
      if (head.tokens === 0n) state.queue.shift()
    }
    if (left > 0n) throw new Error(`a chunk sold ${left} tokens no trade taxed: logs are incomplete`)
    if (ev.paid && all > 0n) {
      for (const [p, w] of parts) {
        const due = (ev.toRecipient * BigInt(shareBps) * w) / (BPS * all)
        if (due > 0n) state.pending.set(p, (state.pending.get(p) ?? 0n) + due)
      }
    }
    return
  }
  if (ev.kind === 'split') {
    state.totalEscrow += ev.toEscrow
    let due = 0n
    for (const a of state.pending.values()) due += a
    let paid = 0n
    for (const [p, a] of state.pending) {
      // due never tops what was escrowed unless logs are wrong; capped all the same
      const part = due > ev.toEscrow ? (a * ev.toEscrow) / due : a
      if (part > 0n) {
        state.cumulative.set(p, (state.cumulative.get(p) ?? 0n) + part)
        paid += part
      }
    }
    const toDev = ev.toEscrow - paid
    if (toDev > 0n) state.cumulative.set(dev, (state.cumulative.get(dev) ?? 0n) + toDev)
    state.pending = new Map()
    return
  }
  throw new Error(`unknown event ${ev.kind}`)
}

/** For the JSON the next period starts from. */
export function saveState(s) {
  return {
    queue: s.queue.map((q) => ({ tokens: q.tokens.toString(), rate: q.rate.toString(), promoter: q.promoter })),
    pending: Object.fromEntries([...s.pending].map(([a, v]) => [a, v.toString()])),
    cumulative: Object.fromEntries([...s.cumulative].map(([a, v]) => [a, v.toString()])),
    totalTaxed: s.totalTaxed.toString(),
    totalChunks: s.totalChunks.toString(),
    totalEscrow: s.totalEscrow.toString(),
  }
}

export function loadState(j) {
  const map = (o) => new Map(Object.entries(o).map(([a, v]) => [a, BigInt(v)]))
  return {
    queue: j.queue.map((q) => ({ tokens: BigInt(q.tokens), rate: BigInt(q.rate), promoter: q.promoter })),
    pending: map(j.pending),
    cumulative: map(j.cumulative),
    totalTaxed: BigInt(j.totalTaxed),
    totalChunks: BigInt(j.totalChunks),
    totalEscrow: BigInt(j.totalEscrow),
  }
}

export function leafHash(account, amount) {
  const inner = keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [account, amount]))
  return keccak256(concat([inner]))
}

function hashPair(a, b) {
  return BigInt(a) < BigInt(b) ? keccak256(concat([a, b])) : keccak256(concat([b, a]))
}

/** The root posted while nothing is allocated yet: the settler still posts, so silence means it stopped. */
export const EMPTY_ROOT = keccak256(toHex('promote-pool-v1: nothing allocated'))

/** A Merkle tree over sorted leaves; an odd node moves up as is. A single leaf is its own root. */
export function buildTree(cumulative) {
  const leaves = [...cumulative.entries()]
    .filter(([, a]) => a > 0n)
    .map(([account, amount]) => ({ account, amount, hash: leafHash(account, amount) }))
    .sort((x, y) => (BigInt(x.hash) < BigInt(y.hash) ? -1 : 1))
  if (leaves.length === 0) return { root: EMPTY_ROOT, allocatedTotal: 0n, leaves: [] }
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
    allocatedTotal: leaves.reduce((s, l) => s + l.amount, 0n),
    leaves: leaves.map((l, i) => ({ account: l.account, amount: l.amount, proof: proofOf(i) })),
  }
}

/** MerkleProof.verify, for the tests. */
export function verify(proof, root, leaf) {
  return proof.reduce((h, p) => hashPair(h, p), leaf) === root
}
