#!/usr/bin/env node
// V2 存量外盘税的历史持仓归属 + Merkle 补发表（只读链，不发交易）。
//
// For one V2 tax token: replays the token's Transfer logs and its handler's TaxAccrued logs in chain order, and
// credits the holders' half of every tax payment (DIV_SHARE_BPS = 50%) to the addresses that held dividend shares in
// the V2 DividendVault at that moment — the shares the vault would have paid if the tax had been sold right away.
// V2 share rule (src/launchpad-v2/PostGradTaxHandler.sol _syncShares + DividendVault.setShare): every transfer syncs
// both sides to share = balance; 0 for the pair, the handler, 0x0 / 0xdead, vault-excluded addresses, and any
// balance <= vault.minimumShareBalance. A taxed pool trade emits Transfer(net) → Transfer(tax → handler) →
// TaxAccrued, and syncs shares only after notifyTax, so each tax is credited with the shares as they stood BEFORE
// that trade.
//
// Then, given the quote the backlog actually sold for (--holder-quote, the holders' half from V2TaxChunkSeller),
// each address gets holderQuote × its credited tokens / all credited tokens (rounded down), and a Merkle tree for
// MerkleQuoteDistributor is written: leaf = keccak256(bytes.concat(keccak256(abi.encode(index, account, amount)))),
// sorted-pair hashing, an odd node is carried up. Every proof is re-verified before writing.
//
// Usage:
//   node tools/remedy/attribute.mjs --token 0x… --from-block N [--to-block N] [--holder-quote WEI] [--out DIR]
//                                   [--rpc URL1,URL2] [--span 5000]
// --to-block should be the adoption block (the backlog = every TaxAccrued up to it); it defaults to the head − 3.
// Outputs in DIR: logs.json (raw logs, cache), accruals.csv, entitlements.csv, summary.json, claims.json.
import { createPublicClient, http, parseAbi, parseAbiItem, keccak256, encodeAbiParameters, concat, getAddress } from 'viem'
import { bsc } from 'viem/chains'
import { mkdirSync, writeFileSync, existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, all) => {
  if (a.startsWith('--')) acc.push([a.slice(2), all[i + 1] && !all[i + 1].startsWith('--') ? all[i + 1] : true])
  return acc
}, []))
const need = (k) => { if (!args[k] || args[k] === true) { console.error(`--${k} required`); process.exit(2) } return args[k] }

const TOKEN = getAddress(need('token'))
const FROM = BigInt(need('from-block'))
const SPAN = BigInt(args.span || 4000)
const RPCS = String(args.rpc || 'https://rpc-bsc.48.club,https://bsc-rpc.publicnode.com').split(',') // 48.club serves history (≤ 5,000 blocks a call)
const OUT = args.out || `remedy-${TOKEN.slice(2, 8).toLowerCase()}`
mkdirSync(OUT, { recursive: true })

const clients = RPCS.map((url) => createPublicClient({ chain: bsc, transport: http(url, { timeout: 30_000, retryCount: 2 }) }))
let rr = 0
async function withRpc(fn) {
  let last
  for (let i = 0; i < clients.length * 2; i++) {
    const c = clients[(rr + i) % clients.length]
    try { const v = await fn(c); rr = (rr + i) % clients.length; return v } catch (e) { last = e }
  }
  throw last
}

const TOKEN_ABI = parseAbi(['function pair() view returns (address)', 'function taxHandler() view returns (address)',
  'function balanceOf(address) view returns (uint256)'])
const HANDLER_ABI = parseAbi(['function dividendVault() view returns (address)', 'function accruedTax(address) view returns (uint256)',
  'function DIV_SHARE_BPS() view returns (uint256)'])
const VAULT_ABI = parseAbi(['function minimumShareBalance() view returns (uint256)', 'function excluded(address) view returns (bool)'])
const TRANSFER = parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)')
const TAX_ACCRUED = parseAbiItem('event TaxAccrued(address indexed token, address indexed from, address indexed to, uint256 taxAmount, uint256 accrued)')
const MIN_SHARE_UPD = parseAbiItem('event MinimumShareBalanceUpdated(uint256 amount)')
const EXCLUDED_EV = parseAbiItem('event Excluded(address indexed account, bool excluded)')
const ZERO = '0x0000000000000000000000000000000000000000'
const DEAD = '0x000000000000000000000000000000000000dEaD'

const head = await withRpc((c) => c.getBlockNumber())
const TO = args['to-block'] ? BigInt(args['to-block']) : head - 3n
const read = (address, abi, functionName, a = []) => withRpc((c) => c.readContract({ address, abi, functionName, args: a, blockNumber: TO }))
// public nodes refuse state older than ~128 blocks: the exclusion list is read at the head (vault Excluded events in
// the range are reported in summary.json for review)
const readLatest = (address, abi, functionName, a = []) => withRpc((c) => c.readContract({ address, abi, functionName, args: a }))

// wiring is fixed after graduation (minimumShareBalance changes are checked against the vault's events below)
const handler = getAddress(await readLatest(TOKEN, TOKEN_ABI, 'taxHandler'))
const pair = getAddress(await readLatest(TOKEN, TOKEN_ABI, 'pair'))
const vault = getAddress(await readLatest(handler, HANDLER_ABI, 'dividendVault'))
const minShare = await readLatest(vault, VAULT_ABI, 'minimumShareBalance')
const divBps = await readLatest(handler, HANDLER_ABI, 'DIV_SHARE_BPS')
let accruedAtTo = null // best effort: only while a node still has the state at TO
try { accruedAtTo = await read(handler, HANDLER_ABI, 'accruedTax', [TOKEN]) } catch { /* checked from the events instead */ }
console.log(`token ${TOKEN} handler ${handler} pair ${pair} vault ${vault} minShare ${minShare} divBps ${divBps}`)
console.log(`blocks ${FROM}..${TO}; accruedTax at ${TO} = ${accruedAtTo ?? 'unavailable'}`)

// one range at a time; a refused range is halved (down to 50 blocks), then grown back
async function logs(address, event, extraArgs) {
  const out = []
  let span = SPAN
  for (let a = FROM; a <= TO;) {
    const b = a + span - 1n > TO ? TO : a + span - 1n
    try {
      out.push(...await withRpc((c) => c.getLogs({ address, event, args: extraArgs, fromBlock: a, toBlock: b })))
      a = b + 1n
      if (span < SPAN) span *= 2n
    } catch (e) {
      if (span <= 50n) throw e
      span /= 2n
    }
  }
  return out
}

const cache = join(OUT, 'logs.json')
let raw
if (existsSync(cache) && !args.refresh) {
  raw = JSON.parse(readFileSync(cache, 'utf8'))
  if (raw.to !== String(TO) || raw.from !== String(FROM)) raw = null
}
if (!raw) {
  const tr = await logs(TOKEN, TRANSFER)
  const ta = await logs(handler, TAX_ACCRUED, { token: TOKEN })
  const ms = await logs(vault, MIN_SHARE_UPD)
  const ex = await logs(vault, EXCLUDED_EV)
  const slim = (l) => ({ b: String(l.blockNumber), i: l.logIndex, tx: l.transactionHash, n: l.eventName,
    a: Object.fromEntries(Object.entries(l.args).map(([k, v]) => [k, typeof v === 'bigint' ? String(v) : v])) })
  raw = { from: String(FROM), to: String(TO), transfer: tr.map(slim), taxAccrued: ta.map(slim), minShareUpdates: ms.map(slim), excluded: ex.map(slim) }
  writeFileSync(cache, JSON.stringify(raw))
}
console.log(`logs: ${raw.transfer.length} Transfer, ${raw.taxAccrued.length} TaxAccrued; vault MinimumShareBalanceUpdated ${raw.minShareUpdates.length}, Excluded ${raw.excluded.length} (in range)`)

const all = [...raw.transfer, ...raw.taxAccrued].sort((x, y) => (BigInt(x.b) - BigInt(y.b) ? (BigInt(x.b) < BigInt(y.b) ? -1 : 1) : x.i - y.i))

// eligibility: vault.excluded read at TO (ranges with Excluded events are reported above, for review)
const lc = (a) => String(a).toLowerCase()
const never = new Set([ZERO, DEAD, pair, handler].map(lc))
const exclCache = new Map()
async function excluded(a) {
  const k = lc(a)
  if (never.has(k)) { exclCache.set(k, true); return true }
  if (!exclCache.has(k)) exclCache.set(k, await readLatest(vault, VAULT_ABI, 'excluded', [getAddress(a)]))
  return exclCache.get(k)
}
const addrs = new Set()
for (const l of raw.transfer) { addrs.add(lc(l.a.from)); addrs.add(lc(l.a.to)) }
for (const a of addrs) await excluded(a)

const SCALE = 10n ** 48n
const bal = new Map(), share = new Map(), credit = new Map(), last = new Map()
let total = 0n, acc = 0n, unattributed = 0n, credited = 0n, taxSum = 0n
const shareOf = (a, b) => (exclCache.get(a) || b <= minShare ? 0n : b)
function settle(a) {
  const s = share.get(a) || 0n
  if (s) credit.set(a, (credit.get(a) || 0n) + (s * (acc - (last.get(a) || 0n))) / SCALE)
  last.set(a, acc)
}
function applyTransfer(l) {
  const v = BigInt(l.a.value)
  for (const [a, d] of [[lc(l.a.from), -v], [lc(l.a.to), v]]) {
    if (a === ZERO) continue
    const nb = (bal.get(a) || 0n) + d
    bal.set(a, nb)
    settle(a)
    const ns = shareOf(a, nb), os = share.get(a) || 0n
    if (ns !== os) { total += ns - os; share.set(a, ns) }
  }
}
const accrualRows = ['block,tx,taxTokens,holderTokens,eligibleHolders,totalShares']
for (let k = 0; k < all.length; k++) {
  const l = all[k]
  if (l.n === 'TaxAccrued') throw new Error(`TaxAccrued without its taxed transfers at ${l.tx}:${l.i}`)
  const t1 = all[k + 1], ta = all[k + 2]
  const taxed = t1 && ta && ta.n === 'TaxAccrued' && ta.tx === l.tx && t1.tx === l.tx && t1.n === 'Transfer'
    && lc(t1.a.to) === lc(handler) && ta.i === l.i + 2 && t1.i === l.i + 1
  if (taxed) {
    const tax = BigInt(ta.a.taxAmount)
    if (tax !== BigInt(t1.a.value)) throw new Error(`tax mismatch at ${ta.tx}`)
    taxSum += tax
    const h = (tax * divBps) / 10_000n
    if (total === 0n) unattributed += h
    else { acc += (h * SCALE) / total; credited += h }
    let n = 0
    for (const s of share.values()) if (s) n++
    accrualRows.push(`${ta.b},${ta.tx},${tax},${h},${n},${total}`)
    applyTransfer(l)
    applyTransfer(t1)
    k += 2
  } else {
    applyTransfer(l)
  }
}
for (const a of share.keys()) settle(a)

// sanity: replayed balances equal the chain's at TO for a few top holders; tax sum equals accruedTax (never processed)
const top = [...bal.entries()].filter(([, b]) => b > 0n).sort((x, y) => (y[1] > x[1] ? 1 : -1)).slice(0, 5)
// (nodes keep no old state, so roll the replayed balances forward to the head with the Transfers after TO, then read)
let balanceCheck = 'ok'
{
  const now = await withRpc((c) => c.getBlockNumber())
  const later = []
  for (let a = TO + 1n; a <= now; a += SPAN) {
    const b = a + SPAN - 1n > now ? now : a + SPAN - 1n
    later.push(...await withRpc((c) => c.getLogs({ address: TOKEN, event: TRANSFER, fromBlock: a, toBlock: b })))
  }
  const rolled = new Map(bal)
  for (const l of later) {
    const v = l.args.value
    if (lc(l.args.from) !== ZERO) rolled.set(lc(l.args.from), (rolled.get(lc(l.args.from)) || 0n) - v)
    rolled.set(lc(l.args.to), (rolled.get(lc(l.args.to)) || 0n) + v)
  }
  for (const [a] of top) {
    const onchain = await withRpc((c) => c.readContract({ address: TOKEN, abi: TOKEN_ABI, functionName: 'balanceOf', args: [getAddress(a)], blockNumber: now }))
    if (onchain !== (rolled.get(a) || 0n)) throw new Error(`replay balance mismatch ${a}: ${rolled.get(a)} vs ${onchain}`)
  }
  balanceCheck = `ok: top ${top.length} replayed balances equal the chain at block ${now}`
}
const creditTotal = [...credit.values()].reduce((x, y) => x + y, 0n)
const rows = [...credit.entries()].filter(([, e]) => e > 0n).sort((x, y) => (lc(x[0]) < lc(y[0]) ? -1 : 1))
writeFileSync(join(OUT, 'accruals.csv'), accrualRows.join('\n') + '\n')
writeFileSync(join(OUT, 'entitlements.csv'), ['address,creditedTokens,ppm'].concat(rows.map(([a, e]) =>
  `${getAddress(a)},${e},${(e * 1_000_000n) / (creditTotal || 1n)}`)).join('\n') + '\n')

// TaxAccrued carries the handler's running total: with no process in between, the last one is the whole backlog
const lastAccrued = raw.taxAccrued.length ? BigInt(raw.taxAccrued[raw.taxAccrued.length - 1].a.accrued) : 0n
const summary = {
  token: TOKEN, handler, pair, vault, fromBlock: String(FROM), toBlock: String(TO), minimumShareBalance: String(minShare),
  taxAccruedEvents: raw.taxAccrued.length, taxSum: String(taxSum), lastEventAccrued: String(lastAccrued),
  taxSumMatchesEvents: taxSum === lastAccrued,
  accruedTaxOnChainAtTo: accruedAtTo == null ? 'unavailable' : String(accruedAtTo),
  taxSumMatchesOnChain: accruedAtTo == null ? 'unavailable' : taxSum === accruedAtTo, holderTokens: String(credited + unattributed),
  creditedTokens: String(creditTotal), unattributedTokens: String(unattributed), roundingTokens: String(credited - creditTotal),
  holders: rows.length, balanceCheckTop5: balanceCheck, vaultMinShareUpdatesInRange: raw.minShareUpdates.length, vaultExcludedEventsInRange: raw.excluded.length,
}

if (args['holder-quote']) {
  const Q = BigInt(args['holder-quote'])
  const claims = rows.map(([a, e], index) => ({ index, account: getAddress(a), amount: (Q * e) / creditTotal }))
    .filter((c) => c.amount > 0n).map((c, index) => ({ ...c, index }))
  const leaf = (c) => keccak256(keccak256(encodeAbiParameters([{ type: 'uint256' }, { type: 'address' }, { type: 'uint256' }],
    [BigInt(c.index), c.account, c.amount])))
  const hp = (x, y) => (x < y ? keccak256(concat([x, y])) : keccak256(concat([y, x])))
  const layers = [claims.map(leaf)]
  while (layers[layers.length - 1].length > 1) {
    const prev = layers[layers.length - 1], next = []
    for (let i = 0; i < prev.length; i += 2) next.push(i + 1 < prev.length ? hp(prev[i], prev[i + 1]) : prev[i])
    layers.push(next)
  }
  const root = layers[layers.length - 1][0]
  const proofOf = (i) => {
    const p = []
    for (let d = 0; d < layers.length - 1; d++) {
      const sib = i ^ 1
      if (sib < layers[d].length) p.push(layers[d][sib])
      i >>= 1
    }
    return p
  }
  const out = claims.map((c) => ({ index: c.index, account: c.account, amount: String(c.amount), proof: proofOf(c.index) }))
  for (const c of out) { // re-verify
    let h = leaf({ ...c, amount: BigInt(c.amount) })
    for (const s of c.proof) h = hp(h, s)
    if (h !== root) throw new Error(`proof check failed for ${c.account}`)
  }
  const totalClaims = claims.reduce((x, c) => x + c.amount, 0n)
  writeFileSync(join(OUT, 'claims.json'), JSON.stringify({ token: TOKEN, root, total: String(totalClaims), holderQuote: String(Q), claims: out }, null, 1))
  Object.assign(summary, { holderQuote: String(Q), merkleRoot: root, claimsTotal: String(totalClaims), claimants: out.length, dust: String(Q - totalClaims) })
}
writeFileSync(join(OUT, 'summary.json'), JSON.stringify(summary, null, 1))
console.log(JSON.stringify(summary, null, 1))
