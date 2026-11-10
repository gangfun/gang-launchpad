#!/usr/bin/env node
// Compute the followers' payouts of one reported GangCallBond (docs/SPEC-AGENT-CALLS-2026-11-09.md §5.3, §9.2).
// Read-only: it prints the root and the leaves; posting is the settler's. Anyone can run it to check a posted root.
//
//   RPC_URL=<an archive node keeping full logs> node settle.mjs --bond 0x… --id <n> [--check] [--chunk 2000]
//
// Reads balances and the curve at past blocks, so the node must keep old state (a pruned node fails loudly).
// Exits non-zero, printing nothing, when the logs don't reconcile with the contracts' state (checked at the end of
// every getLogs chunk: public nodes can drop a range without an error), or when the price window isn't final yet.
// --check: also compare with the root posted for this bond (pending or in effect); the JSON is still printed, and the
// exit code is non-zero on a mismatch.
import { parseArgs } from 'node:util'
import { pathToFileURL } from 'node:url'
import { createPublicClient, http, parseAbi, parseAbiItem, getAddress } from 'viem'
import {
  FOLLOW_WINDOW,
  PRICE_WINDOW,
  callerBalances,
  violationBlock,
  followBuys,
  endOfBlockPrices,
  priceAverage,
  pairPrice,
  curvePrice,
  checkSoldChain,
  sellsBetween,
  exitsOf,
  exitCredit,
  spotLookup,
  checkVaultInflows,
  vaultNet,
  priceLookup,
  forwardBalances,
  checkPadFlows,
  allocate,
  leafHash,
  buildTree,
  compareRoot,
  lastAtOrBefore,
} from './lib.mjs'

const WBNB_MAINNET = '0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c'
export const bondAbi = parseAbi([
  'struct Bond { address caller; uint64 postedAt; uint8 state; address token; uint64 deadline; address quote; uint64 settleAt; uint128 amount; uint128 hold; uint64 reportedAt; uint64 reportedBlock; uint64 rootAt; uint64 vetoAt; uint128 pool; uint128 spent; uint128 total; bool remainderBurned; bytes32 noteTx; bytes32 root; }',
  'function bondOf(uint256 id) view returns (Bond)',
  'function pad() view returns (address)',
  'function wbnb() view returns (address)',
  'function leaf(uint256 id, address account, uint256 amount) view returns (bytes32)',
])
const padAbi = parseAbi([
  'function curves(address) view returns (address creator, address quote, uint128 realQuote, uint128 sold, uint128 gradAmt, uint128 virtualQuote, bool graduated, uint16 buyTaxBps, uint16 sellTaxBps, uint16 dividendBps, address pair, address refPair)',
  'function VIRTUAL_TOKEN() view returns (uint256)',
])
const erc20Abi = parseAbi(['function balanceOf(address) view returns (uint256)', 'function decimals() view returns (uint8)'])
const pairAbi = parseAbi(['function token0() view returns (address)', 'function getReserves() view returns (uint112, uint112, uint32)'])
export const EVENTS = {
  POSTED: parseAbiItem('event CallBondPosted(uint256 indexed id, address indexed caller, address indexed token, bytes32 noteTx, address quote, uint256 amount, uint256 hold, uint64 deadline)'),
  REPORTED: parseAbiItem('event CallBondReported(uint256 indexed id, address indexed reporter, uint256 reportedBlock, uint256 balance, uint256 reward, uint256 burned, uint256 pool)'),
  TRADE: parseAbiItem('event TradeV1(address indexed token, address indexed trader, bool isBuy, uint256 quoteAmount, uint256 tokenAmount, uint256 protocolFee, uint256 creatorFee, uint256 postPrice, uint256 realQuote, uint256 sold)'),
  GRADUATED: parseAbiItem('event Graduated(address indexed token, address indexed pair, address quote, uint256 tokenAmount, uint256 quoteAmount)'),
  TRANSFER: parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)'),
  SYNC: parseAbiItem('event Sync(uint112 reserve0, uint112 reserve1)'),
  VAULT_LOCKED: parseAbiItem('event VaultLocked(address indexed token, address indexed vault, address indexed user, uint256 amount)'),
  VAULT_RELEASED: parseAbiItem('event VaultReleased(address indexed token, address indexed vault, address indexed user, uint256 amount)'),
}
const REPORTED_STATE = 3
const CLOSED_STATE = 4

export class SettleError extends Error {}
const fail = (msg) => {
  throw new SettleError(msg)
}
const pos = (a, b) => (a.blockNumber === b.blockNumber ? a.logIndex - b.logIndex : a.blockNumber < b.blockNumber ? -1 : 1)

/**
 * The settlement of bond `id` on `bond` (§5.3), from `client` (a viem public client, or anything with the same
 * methods). Throws SettleError when inputs don't reconcile. Returns { out (the JSON), posted: { root, total } }.
 */
export async function settle(client, { bond: bondAddr, id: idArg, chunk = 2000n }) {
  /** Logs over a range, halving a chunk the node refuses; `ends`: the last block of each chunk it returned. */
  async function logs(address, event, from, to, filter) {
    const list = []
    const ends = []
    let step = BigInt(chunk)
    for (let a = from; a <= to; ) {
      const b = a + step - 1n < to ? a + step - 1n : to
      try {
        list.push(...(await client.getLogs({ address, event, args: filter, fromBlock: a, toBlock: b })))
        ends.push(b)
        a = b + 1n
      } catch (e) {
        if (step <= 1n) throw e
        step /= 2n
      }
    }
    return { list: list.sort(pos), ends }
  }

  /** Public nodes can return nothing for old ranges without an error: on mainnet, WBNB has logs in nearly every block. */
  async function assertNodeKeepsLogs(chainId, from, to) {
    if (chainId !== 56) return // elsewhere the per-chunk reconciliations are the guard
    const span = to - from
    for (const b of [from, from + span / 3n, from + (2n * span) / 3n, to]) {
      let seen = false
      for (let i = 0n; i < 5n && !seen; i++) {
        seen = (await client.getLogs({ address: WBNB_MAINNET, fromBlock: b + i, toBlock: b + i })).length > 0
      }
      if (!seen) fail(`the node returned no WBNB logs around block ${b}: it does not keep this range`)
    }
  }

  const blockCache = new Map()
  const timeOf = (n) => {
    if (!blockCache.has(n)) blockCache.set(n, client.getBlock({ blockNumber: n }).then((b) => b.timestamp))
    return blockCache.get(n)
  }
  /** The first block in [lo, hi] whose timestamp is ≥ ts, or hi + 1. */
  async function firstBlockAt(ts, lo, hi) {
    let a = lo
    let b = hi + 1n
    while (a < b) {
      const m = (a + b) / 2n
      if ((await timeOf(m)) >= ts) b = m
      else a = m + 1n
    }
    return a
  }
  const at = (address, abi, functionName, fnArgs, blockNumber) =>
    client.readContract({ address, abi, functionName, args: fnArgs, blockNumber }).catch((e) => {
      fail(`${functionName} at block ${blockNumber ?? 'latest'} failed (${e.shortMessage ?? e.message}): the node must keep old state`)
    })
  const curveAt = async (pad, token, blockNumber) => {
    const c = await at(pad, padAbi, 'curves', [token], blockNumber)
    return { creator: c[0], realQuote: c[2], sold: c[3], virtualQuote: c[5], graduated: c[6], pair: c[10] }
  }

  // ---------------------------------------------------------------- the bond
  const chainId = await client.getChainId()
  const contract = getAddress(bondAddr)
  const id = BigInt(idArg)
  const bond = await at(contract, bondAbi, 'bondOf', [id])
  if (bond.state !== REPORTED_STATE && bond.state !== CLOSED_STATE) fail(`bond ${id} is not reported (state ${bond.state})`)
  const [pad, wbnb] = await Promise.all([at(contract, bondAbi, 'pad'), at(contract, bondAbi, 'wbnb')])
  const { caller, token, quote, hold, noteTx, pool } = bond
  const R = bond.reportedBlock
  const finalized = (await client.getBlock({ blockTag: 'finalized' })).number
  if (R > finalized) fail(`the report block ${R} is not final yet (finalized ${finalized})`)

  const reported = (await logs(contract, EVENTS.REPORTED, R, R, { id })).list
  if (reported.length !== 1) fail(`expected one CallBondReported for bond ${id} in block ${R}, got ${reported.length}`)
  const reportLog = reported[0]
  if (reportLog.args.pool !== pool || reportLog.args.reportedBlock !== R) fail("CallBondReported doesn't match bondOf")

  // the post block: one of the blocks with the post's timestamp
  const postLo = await firstBlockAt(bond.postedAt, 1n, R)
  const postHi = (await firstBlockAt(bond.postedAt + 1n, postLo, R)) - 1n
  const posted = (await logs(contract, EVENTS.POSTED, postLo, postHi, { id })).list
  if (posted.length !== 1) fail(`expected one CallBondPosted for bond ${id} in blocks ${postLo}–${postHi}, got ${posted.length}`)
  const postLog = posted[0]
  if (postLog.args.caller !== caller || postLog.args.token !== token || postLog.args.hold !== hold || postLog.args.noteTx !== noteTx) {
    fail("CallBondPosted doesn't match bondOf")
  }
  const postBlock = postLog.blockNumber

  // ---------------------------------------------------------------- §5.3.1–2: B
  const [sent, got] = await Promise.all([
    logs(token, EVENTS.TRANSFER, postBlock, R, { from: caller }),
    logs(token, EVENTS.TRANSFER, postBlock, R, { to: caller }),
  ])
  const transfers = new Map()
  for (const l of [...sent.list, ...got.list]) {
    const delta = (l.args.to === caller ? l.args.value : 0n) - (l.args.from === caller ? l.args.value : 0n)
    transfers.set(`${l.transactionHash}:${l.logIndex}`, { blockNumber: l.blockNumber, logIndex: l.logIndex, delta })
  }
  let bal
  try {
    bal = callerBalances({
      reportBalance: reportLog.args.balance,
      reportBlock: R,
      reportLogIndex: reportLog.logIndex,
      postBlock,
      postLogIndex: postLog.logIndex,
      transfers: [...transfers.values()],
    })
  } catch (e) {
    fail(e.message)
  }
  if (bal.atPost < hold) fail(`the caller's balance rebuilt at the post is ${bal.atPost}, below hold ${hold}: transfer logs are incomplete`)
  const B = violationBlock({ endOf: bal.endOf, changes: bal.changes, hold, reportBlock: R, postBlock })
  // the rebuilt balances against the node's state: at the end of every chunk, every block where it moved, and around B
  // (and below, every block where the caller traded on the curve: another log stream)
  const checkCallerBalances = (blocks) =>
    Promise.all(
      [...new Set(blocks)].filter((n) => n <= R && n >= postBlock - 1n).map(async (n) => {
        const onChain = await at(token, erc20Abi, 'balanceOf', [caller], n)
        if (onChain !== bal.endOf(n)) fail(`the caller's balance at the end of block ${n} is ${onChain}, rebuilt ${bal.endOf(n)}: transfer logs are incomplete`)
      }),
    )
  await checkCallerBalances([...sent.ends, ...got.ends, ...bal.changes, R - 1n, B - 1n, B, postBlock - 1n])

  // ---------------------------------------------------------------- windows
  const TB = await timeOf(B)
  const windowEnd = TB + PRICE_WINDOW
  const afterWindow = await firstBlockAt(windowEnd, B, finalized)
  if (afterWindow > finalized) fail(`the price window [${TB}, ${windowEnd}) is not over in a final block yet`)
  const E = afterWindow - 1n // the last block with a timestamp in the window

  const noteReceipt = await client.getTransactionReceipt({ hash: noteTx }).catch(() => null)
  if (!noteReceipt) fail(`the node has no receipt for noteTx ${noteTx}`)
  const noteBlock = noteReceipt.blockNumber
  const noteTime = await timeOf(noteBlock)
  // the last block at or before the note's time + 24 h (only blocks before B matter)
  const followEndBlock = noteBlock < B ? (await firstBlockAt(noteTime + FOLLOW_WINDOW + 1n, noteBlock, B)) - 1n : noteBlock

  const start = noteBlock < B ? noteBlock : B
  await assertNodeKeepsLogs(chainId, start < postBlock ? start : postBlock, E > R ? E : R)

  // ---------------------------------------------------------------- TradeV1, Graduated over [start, E] (and to R)
  const tradeTo = E > R ? E : R
  const [tradeRes, gradRes] = await Promise.all([logs(pad, EVENTS.TRADE, start, tradeTo, { token }), logs(pad, EVENTS.GRADUATED, start, tradeTo, { token })])
  const trades = tradeRes.list.map((l) => ({ transactionHash: l.transactionHash, blockNumber: l.blockNumber, logIndex: l.logIndex, ...l.args }))
  const gradLogs = gradRes.list
  const [virtualToken, before] = await Promise.all([at(pad, padAbi, 'VIRTUAL_TOKEN'), curveAt(pad, token, start - 1n)])
  if (gradLogs.length > 1 || (before.graduated && gradLogs.length === 1)) fail('Graduated logs disagree with the curve state: logs are incomplete')
  const grad = gradLogs[0] ?? null
  try {
    checkSoldChain(trades, before.sold, trades.length ? trades.at(-1).sold : before.sold)
  } catch (e) {
    fail(e.message)
  }
  // the curve at the end of every chunk: sold, realQuote and graduated as the logs up to there say
  const curveChecks = new Set([...tradeRes.ends, ...gradRes.ends, E])
  const curveAtEnd = new Map()
  await Promise.all(
    [...curveChecks].map(async (n) => {
      const c = await curveAt(pad, token, n)
      curveAtEnd.set(n, c)
      const last = lastAtOrBefore(trades, n)
      const graduated = before.graduated || (grad !== null && grad.blockNumber <= n)
      const sold = last ? last.sold : before.sold
      const realQuote = graduated ? 0n : last ? last.realQuote : before.realQuote
      if (c.sold !== sold || c.realQuote !== realQuote || c.graduated !== graduated) {
        fail(`the curve at the end of block ${n} has sold ${c.sold} / realQuote ${c.realQuote} / graduated ${c.graduated}, the logs say ${sold} / ${realQuote} / ${graduated}: logs are incomplete`)
      }
    }),
  )
  const atEnd = curveAtEnd.get(E)
  // every token the pad moved, each way, against the trades, vault locks and the migration (chunk by chunk)
  const [fromPad, toPad, lockRes, releaseRes] = await Promise.all([
    logs(token, EVENTS.TRANSFER, start, tradeTo, { from: pad }),
    logs(token, EVENTS.TRANSFER, start, tradeTo, { to: pad }),
    logs(pad, EVENTS.VAULT_LOCKED, start, tradeTo, { token }),
    logs(pad, EVENTS.VAULT_RELEASED, start, tradeTo, { token }),
  ])
  const flat = (l) => ({ blockNumber: l.blockNumber, logIndex: l.logIndex, ...l.args })
  try {
    checkPadFlows({
      from: start,
      ends: [...tradeRes.ends, ...gradRes.ends, ...fromPad.ends, ...toPad.ends, ...lockRes.ends],
      pad,
      fromPad: fromPad.list.map(flat),
      toPad: toPad.list.map(flat),
      trades,
      locks: lockRes.list.map(flat),
      grad: grad && { blockNumber: grad.blockNumber, logIndex: grad.logIndex, tokenAmount: grad.args.tokenAmount },
    })
  } catch (e) {
    fail(e.message)
  }
  await checkCallerBalances(trades.filter((t) => t.trader === caller).map((t) => t.blockNumber))
  const gradW = grad && grad.blockNumber <= E ? grad : null // a graduation in the price window

  // price events in chain order: each TradeV1's postPrice; after the graduating trade, the pair's Sync reserves
  const priceEvents = trades.map((t) => ({ blockNumber: t.blockNumber, logIndex: t.logIndex, price: t.postPrice }))
  let seedPrice // at the end of block start − 1
  if (atEnd.graduated) {
    const pair = atEnd.pair
    const token0 = await at(pair, pairAbi, 'token0')
    const isToken0 = token0 === token
    let syncFrom = start
    let after = null // Syncs after this log count
    if (gradW) {
      after = trades.filter((t) => t.transactionHash === gradW.transactionHash && t.logIndex < gradW.logIndex).at(-1)
      if (!after) fail(`no TradeV1 before the Graduated log in ${gradW.transactionHash}`)
      syncFrom = gradW.blockNumber
    }
    const syncRes = await logs(pair, EVENTS.SYNC, syncFrom, E)
    const syncs = syncRes.list
    // the reserves at the end of every chunk are the last Sync's up to there (before any: the reserves before the range)
    const baseline = gradW ? null : await at(pair, pairAbi, 'getReserves', [], syncFrom - 1n)
    await Promise.all(
      [...new Set([...syncRes.ends, E])].map(async (n) => {
        const [r0, r1] = await at(pair, pairAbi, 'getReserves', [], n)
        const last = lastAtOrBefore(syncs, n)
        const want = last ? [last.args.reserve0, last.args.reserve1] : baseline
        if (!want) fail(`no Sync between the graduation and the end of block ${n}: logs are incomplete`)
        if (r0 !== want[0] || r1 !== want[1]) fail(`the pair's reserves at the end of block ${n} differ from its Sync logs: logs are incomplete`)
      }),
    )
    for (const l of syncs) {
      if (after && pos(l, after) <= 0) continue
      priceEvents.push({ blockNumber: l.blockNumber, logIndex: l.logIndex, price: pairPrice(l.args.reserve0, l.args.reserve1, isToken0) })
    }
    if (baseline) seedPrice = pairPrice(baseline[0], baseline[1], isToken0)
  }
  if (seedPrice === undefined) seedPrice = curvePrice(before, virtualToken)

  const blockPrices = endOfBlockPrices(priceEvents.filter((e) => e.blockNumber <= E))
  const priceAtEndOf = priceLookup(seedPrice, blockPrices) // blocks from `start` on
  const spotBefore = spotLookup(seedPrice, priceEvents) // any log from `start` on
  let priceAtB = seedPrice // at the end of B − 1
  for (const p of blockPrices) if (p.blockNumber < B) priceAtB = p.price
  const points = []
  for (const p of blockPrices) if (p.blockNumber >= B) points.push({ timestamp: await timeOf(p.blockNumber), price: p.price })
  const { pRef } = priceAverage({ seed: priceAtB, points, start: TB })

  // ---------------------------------------------------------------- §5.3.3–4: followers
  const callerL = caller.toLowerCase()
  const candidates = [
    ...new Set(
      trades
        .filter((t) => t.isBuy && t.blockNumber > noteBlock && t.blockNumber <= followEndBlock && t.blockNumber < B && t.trader.toLowerCase() !== callerL)
        .map((t) => t.transactionHash),
    ),
  ]
  const txs = new Map()
  await Promise.all(
    candidates.map(async (hash) => {
      const tx = await client.getTransaction({ hash }).catch(() => null)
      if (!tx) fail(`the node has no transaction ${hash}`)
      txs.set(hash, { from: tx.from, input: tx.input })
    }),
  )
  const minQuote = quote === wbnb ? 2n * 10n ** 15n : 10n ** BigInt(await at(quote, erc20Abi, 'decimals'))
  const followers = followBuys({ trades, txOf: (h) => txs.get(h), noteTx, noteBlock, followEndBlock, B, caller, creator: before.creator, token, minQuote })

  // ---------------------------------------------------------------- §5.3.6–8: losses, payouts, tree
  // each follower's balance at F_i − 1 and B − 1, what it holds in vaults, and what left it by other ways than a curve
  // sell or a vaultLock (an exit, credited at max(price, P_ref)). Its transfer logs rebuilt forwards must meet balanceOf
  // at every chunk end, at B − 1 and where it traded on the curve; its pre-graduation inflows from others than the pad
  // must match its VaultReleased logs.
  const locks = lockRes.list.map(flat)
  const releases = releaseRes.list.map(flat)
  const gradPos = grad && { blockNumber: grad.blockNumber, logIndex: grad.logIndex }
  const atB = new Map()
  const atF = new Map()
  const vaulted = new Map()
  const credit = new Map()
  const exitsShown = new Map()
  await Promise.all(
    [...followers].map(async ([a, f]) => {
      const F = f.firstBlock
      const [bF, bB, outs, ins] = await Promise.all([
        at(token, erc20Abi, 'balanceOf', [a], F - 1n),
        at(token, erc20Abi, 'balanceOf', [a], B - 1n),
        logs(token, EVENTS.TRANSFER, F, B - 1n, { from: a }),
        logs(token, EVENTS.TRANSFER, F, B - 1n, { to: a }),
      ])
      const seen = new Map()
      for (const l of [...outs.list, ...ins.list]) {
        const delta = (l.args.to.toLowerCase() === a ? l.args.value : 0n) - (l.args.from.toLowerCase() === a ? l.args.value : 0n)
        seen.set(`${l.transactionHash}:${l.logIndex}`, { blockNumber: l.blockNumber, delta })
      }
      let endOf
      try {
        endOf = forwardBalances({ startBalance: bF, fromBlock: F, toBlock: B - 1n, transfers: [...seen.values()] })
      } catch (e) {
        fail(`${a}: ${e.message}`)
      }
      const own = trades.filter((t) => t.trader.toLowerCase() === a && t.blockNumber >= F && t.blockNumber < B).map((t) => t.blockNumber)
      const checks = [...new Set([...outs.ends, ...ins.ends, ...own, B - 1n])].filter((n) => n >= F && n <= B - 1n)
      await Promise.all(
        checks.map(async (n) => {
          const onChain = n === B - 1n ? bB : await at(token, erc20Abi, 'balanceOf', [a], n)
          if (onChain !== endOf(n)) fail(`${a}'s balance at the end of block ${n} is ${onChain}, rebuilt ${endOf(n)}: transfer logs are incomplete`)
        }),
      )
      try {
        checkVaultInflows({ account: a, transfersIn: ins.list.map(flat), releases, pad, grad: gradPos, from: F, to: B })
      } catch (e) {
        fail(e.message)
      }
      const exits = exitsOf({ account: a, transfersOut: outs.list.map(flat), pad, grad: gradPos, from: F, to: B })
      atF.set(a, bF)
      atB.set(a, bB)
      vaulted.set(a, vaultNet(locks, releases, a, F, B))
      credit.set(a, exitCredit(exits, { spotBefore, priceAtEndOf }, pRef))
      exitsShown.set(a, exits.reduce((x, v) => x + v.tokens, 0n))
    }),
  )
  const alloc = allocate({
    followers,
    balanceAtB: (a) => atB.get(a),
    balanceAtF: (a) => atF.get(a),
    soldQuote: (a) => sellsBetween(trades, a, token, followers.get(a).firstBlock, B),
    vaulted: (a) => vaulted.get(a),
    exitCredit: (a) => credit.get(a),
    pRef,
    pool,
  })
  if (alloc.total > pool) fail(`${alloc.total} would be paid, the pool is ${pool}`)

  const leafOf = (account, amount) => leafHash(contract, chainId, id, account, amount)
  // the contract's own leaf, for one value
  const probe = alloc.rows[0] ?? { account: caller, paid: 1n }
  if ((await at(contract, bondAbi, 'leaf', [id, probe.account, probe.paid])) !== leafOf(probe.account, probe.paid)) {
    fail('the leaf hash differs from GangCallBond.leaf')
  }
  const tree = buildTree(new Map(alloc.rows.map((r) => [r.account, r.paid])), leafOf)
  if (tree.total !== alloc.total) fail('tree total differs from the allocation')

  const rowOf = new Map(alloc.rows.map((r) => [r.account, r]))
  const s = (v) => v.toString()
  const out = {
    chainId,
    contract,
    id: s(id),
    token,
    quote,
    caller,
    hold: s(hold),
    noteTx,
    noteBlock: s(noteBlock),
    postBlock: s(postBlock),
    reportedBlock: s(R),
    B: s(B),
    TB: s(TB),
    priceWindow: { from: s(TB), to: s(windowEnd), lastBlock: s(E) },
    pRef: s(pRef),
    pool: s(pool),
    sumLoss: s(alloc.sumLoss),
    proRata: alloc.capped,
    total: s(tree.total),
    root: tree.root,
    leaves: tree.leaves.map((l) => {
      const r = rowOf.get(l.account)
      return { account: getAddress(l.account), amount: s(l.amount), proof: l.proof, loss: s(r.loss), tokens: s(r.tokens), paid: s(r.paid), avgPrice: s(r.avgPrice) }
    }),
    followers: alloc.rows.map((r) => ({
      account: getAddress(r.account),
      firstBlock: s(r.firstBlock),
      quote: s(r.quote),
      tokens: s(r.tokens),
      avgPrice: s(r.avgPrice),
      soldQuote: s(r.soldQuote),
      cost: s(r.cost),
      balanceAtF: s(r.balanceAtF),
      balanceAtB: s(r.balanceAtB),
      vaulted: s(r.vaulted),
      exited: s(exitsShown.get(r.account)),
      exitCredit: s(r.exitCredit),
      exposed: s(r.exposed),
      loss: s(r.loss),
      paid: s(r.paid),
      txs: r.txs,
    })),
  }
  return { out, tree, posted: { root: bond.root, total: bond.total } }
}

// ---------------------------------------------------------------- CLI
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const { values: args } = parseArgs({
    options: {
      bond: { type: 'string' },
      id: { type: 'string' },
      chunk: { type: 'string', default: '2000' },
      check: { type: 'boolean', default: false },
    },
  })
  if (!args.bond || !args.id || !process.env.RPC_URL) {
    console.error('usage: RPC_URL=… node settle.mjs --bond 0x… --id <n> [--check] [--chunk 2000]')
    process.exit(2)
  }
  const client = createPublicClient({ transport: http(process.env.RPC_URL, { retryCount: 5, batch: { batchSize: 100 } }) })
  let result
  try {
    result = await settle(client, { bond: args.bond, id: args.id, chunk: BigInt(args.chunk) })
  } catch (e) {
    if (!(e instanceof SettleError)) throw e
    console.error(`settle: ${e.message}`)
    process.exit(1)
  }
  console.log(JSON.stringify(result.out, null, 2))
  if (args.check) {
    const c = compareRoot(result.tree, result.posted)
    if (!c.ok) {
      console.error(`settle: --check: ${c.reason}`)
      process.exit(1)
    }
    console.error(`settle: the root posted for bond ${args.id} matches`)
  }
}
