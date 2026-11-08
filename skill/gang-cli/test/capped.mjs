/**
 * Capped recipient (GangCappedSplitter, capped-v1) without a chain: parsing a capped launch's --tax-cap / --tax-cap-share /
 * --split / --after-cap (every refusal GangCappedSplitter.initialize makes), the contract's split math to the wei (the split
 * that crosses the cap), the status shape (formatCapped) in a quote with 6 decimals, the rough cap volume, the events gang
 * tx decodes, the launch / command flags refused before any RPC, and — against a local fake BSC testnet node — the
 * launch's clone step, its re-run check and `gang capped status --module`.
 *
 *   node skill/gang-cli/test/capped.mjs
 */
import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  decodeEventLog, decodeFunctionData, encodeAbiParameters, encodeEventTopics, encodeFunctionResult, getAddress, parseAbi,
  stringToHex, toFunctionSelector, zeroAddress,
} from 'viem'
import {
  capUnits, capVolume, cappedFactoryAddress, cappedLine, cappedNotDeployed, decoyWarning, formatCapped, HINTS, parseAfter,
  parseCapShare, parseCappedSpec, partsOf, payeeAmounts, splitPcts, CAPPED_ABI, CAPPED_EVENT_ABIS, CAPPED_TYPE,
  COVERAGE_NOTE, MAINNET_CAPPED_FACTORY, OTHER_ASSETS_NOTE, PERMANENT_NOTE, TESTNET_CAPPED_FACTORY,
} from '../src/capped.js'
import { decodeWorkPlan } from '../src/combo.js'
import { claimToModule, notThroughModule, payOutCmd } from '../src/creatorfee.js'
import { untrustedBuybackQuote } from '../src/launch.js'
import { GANG_GENS, gangGens } from '../src/gangpad.js'

const ME = '0x00000000000000000000000000000000000000aa'
const ME_C = getAddress(ME)
const A = '0x1111111111111111111111111111111111111111'
const B = '0x2222222222222222222222222222222222222222'
const t = (n) => `0x${String(n).padStart(40, '0')}`
const E18 = 10n ** 18n
const E6 = 10n ** 6n

// ---- --tax-cap-share, --after-cap, --tax-cap
assert.deepEqual(parseCapShare(undefined), { payBps: 10_000 })
assert.deepEqual(parseCapShare('50'), { payBps: 5000 })
assert.deepEqual(parseCapShare('0.01'), { payBps: 1 })
assert.deepEqual(parseCapShare('33.33'), { payBps: 3333 })
for (const x of ['0', '0.00', '100.01', '101', '-5', '1.234', 'x', '']) assert.match(parseCapShare(x).error, /--tax-cap-share is the payees' %/, x)
assert.deepEqual(parseAfter(undefined), { buybackOfRestBps: 10_000 })
assert.deepEqual(parseAfter('buyback:70,lp:30'), { buybackOfRestBps: 7000 })
assert.deepEqual(parseAfter('lp:30,buyback:70'), { buybackOfRestBps: 7000 })
assert.deepEqual(parseAfter('lp:100'), { buybackOfRestBps: 0 })
assert.deepEqual(parseAfter('buyback:100'), { buybackOfRestBps: 10_000 })
assert.deepEqual(parseAfter('BuyBack:33.33,LP:66.67'), { buybackOfRestBps: 3333 })
assert.deepEqual(parseAfter('buyback:0,lp:100'), { buybackOfRestBps: 0 })
assert.match(parseAfter('buyback:70,lp:20').error, /add up to 90%, not 100%/)
assert.match(parseAfter('buyback:70').error, /add up to 70%/)
assert.match(parseAfter('burn:70,lp:30').error, /"burn:70" is not buyback:<pct> or lp:<pct>/)
assert.match(parseAfter('buyback:50,buyback:50').error, /buyback appears twice/)
assert.match(parseAfter('buyback:70.123,lp:29.877').error, /at most 2 decimals/)
assert.match(parseAfter('buyback:170').error, /from 0 to 100/)
assert.match(parseAfter('buyback 70').error, /is not buyback:<pct>/)
assert.match(parseAfter('').error, /--after-cap takes buyback:<pct>,lp:<pct>/)
assert.match(parseAfter('--dev-buy').error, /--after-cap takes/)
// the cap in the quote's own decimals: 6 (USDC-like), 18 (WBNB, BSC USDT)
assert.deepEqual(capUnits('20', 18), { amount: 20n * E18 })
assert.deepEqual(capUnits('20.5', 6), { amount: 20_500_000n })
assert.deepEqual(capUnits('0.000001', 6), { amount: 1n })
assert.deepEqual(capUnits('1.500000', 6), { amount: 1_500_000n }) // trailing zeros are no extra decimals
assert.match(capUnits('0.0000001', 6, 'USDC').error, /USDC has 6 decimals, 0.0000001 has more/)
assert.match(capUnits('0', 18).error, /above 0/)
assert.match(capUnits('0.000', 18).error, /above 0/)
for (const x of ['-1', 'abc', '', undefined, '1e3', '--split']) assert.match(capUnits(x, 18).error, /--tax-cap must be a positive amount/, String(x))
// before the quote is read: the form only; any number of decimals passes (the quote decides), a figure past 30 digits never
assert.deepEqual(capUnits('20.123456789012345678901234567890'), { ok: true })
assert.match(capUnits('0.00').error, /above 0/)
assert.match(capUnits('1'.repeat(31)).error, /--tax-cap is far too large/)
assert.match(capUnits('1'.repeat(31), 18).error, /far too large/)
assert.deepEqual(capUnits('9'.repeat(30), 18), { amount: BigInt('9'.repeat(30)) * E18 })

// ---- the spec: payees default to you, --split shares are of the capped part
const one = parseCappedSpec({}, ME)
assert.deepEqual([one.payBps, one.buybackOfRestBps, one.payees, one.shares], [10_000, 10_000, [ME_C], [10_000]])
assert.deepEqual(one.list, [{ index: 0, payee: ME_C, you: true, pctOfPayees: 100, pctOfRecipientUntilCap: 100 }])
const two = parseCappedSpec({ capShare: '50', split: `self:70,${A}:30`, after: 'buyback:70,lp:30' }, ME)
assert.deepEqual([two.payBps, two.buybackOfRestBps, two.payees, two.shares], [5000, 7000, [ME_C, A], [7000, 3000]])
assert.deepEqual(two.list, [
  { index: 0, payee: ME_C, you: true, pctOfPayees: 70, pctOfRecipientUntilCap: 35 },
  { index: 1, payee: A, pctOfPayees: 30, pctOfRecipientUntilCap: 15 },
])
const ten = Array.from({ length: 10 }, (_, i) => `${t(i + 1)}:10`).join(',')
assert.equal(parseCappedSpec({ split: ten }, ME).payees.length, 10)
const bad = (spec, re, me = ME) => {
  const r = parseCappedSpec(spec, me)
  assert.ok(r.error, `refused: ${JSON.stringify(spec)}`)
  assert.match(r.error, re, JSON.stringify(spec))
  return r
}
bad({}, /sign in with baw, or give --from/, null)
bad({ capShare: '0' }, /--tax-cap-share/)
bad({ after: 'lp:50' }, /add up to 50%/)
const sum = bad({ split: `${A}:60,${B}:30` }, /add up to 90%, not 100%/)
assert.match(sum.hint, /with --tax-cap, --split lists the payees of the capped part/)
bad({ split: `${A}:50,${A}:50` }, /appears twice/)
bad({ split: `self:50,${ME}:50` }, /appears twice/)
bad({ split: `${A}:0,${B}:100` }, /0% share/)
bad({ split: `${t(0)}:100` }, /zero address/)
bad({ split: `${Array.from({ length: 11 }, (_, i) => `${t(i + 1)}:9`).join(',')}` }, /at most 10 payees/)
bad({ split: '' }, /takes <addr>:<pct>/)

// ---- the contract's split (_partsOf) to the wei, and its payee push (_payAll)
// before the cap: payBps of it, the rest by buybackOfRestBps
assert.deepEqual(partsOf(100n * E18, 0n, 20n * E18, 5000, 7000), { toPayees: 20n * E18, toBuyback: 56n * E18, toLp: 24n * E18 })
assert.deepEqual(partsOf(10n * E18, 0n, 20n * E18, 5000, 7000), { toPayees: 5n * E18, toBuyback: 35n * E18 / 10n, toLp: 15n * E18 / 10n })
// the split that crosses the cap pays exactly what is left of it, the rest all to buy-back / LP
assert.deepEqual(partsOf(2n * E18, 195n * E18 / 10n, 20n * E18, 5000, 7000), { toPayees: E18 / 2n, toBuyback: 105n * E18 / 100n, toLp: 45n * E18 / 100n })
// odd numbers: 7777 × 33.33% = 2592.08 → 2592, more than the 4 left → 4; rest 7773 × 66.67% = 5182.25 → 5182, LP 2591
assert.deepEqual(partsOf(7777n, 999_999n, 1_000_003n, 3333, 6667), { toPayees: 4n, toBuyback: 5182n, toLp: 2591n })
// exactly the cap left: all of it, the cap reached with nothing left over
assert.deepEqual(partsOf(2n * E18, 19n * E18, 20n * E18, 5000, 10_000), { toPayees: E18, toBuyback: E18, toLp: 0n })
// after the cap: nothing to the payees
assert.deepEqual(partsOf(3n * E18, 20n * E18, 20n * E18, 5000, 7000), { toPayees: 0n, toBuyback: 21n * E18 / 10n, toLp: 9n * E18 / 10n })
// 100% to the payees until the cap: the rest is only what crosses it; all-LP after
assert.deepEqual(partsOf(5n * E6, 18n * E6, 20n * E6, 10_000, 0), { toPayees: 2n * E6, toBuyback: 0n, toLp: 3n * E6 })
// every split adds up to what arrived, in any state (I-3) and never past the cap (I-1)
for (const [inc, paid, cap, pay, bb] of [[1n, 0n, 1n, 1, 0], [999n, 7n, 10n, 9999, 1], [10n ** 30n, 1n, 10n ** 29n, 2500, 5000], [3n, 0n, 5n, 10_000, 10_000]]) {
  const p = partsOf(inc, paid, cap, pay, bb)
  assert.equal(p.toPayees + p.toBuyback + p.toLp, inc)
  assert.ok(paid + p.toPayees <= cap)
}
assert.deepEqual(payeeAmounts(10n, [3333, 3333, 3334]), [4n, 3n, 3n]) // the first takes the dust
assert.deepEqual(payeeAmounts(E18 / 2n, [7000, 3000]), [35n * E18 / 100n, 15n * E18 / 100n])
assert.deepEqual(payeeAmounts(5n, [10_000]), [5n])
assert.deepEqual(splitPcts(5000, 7000), { untilCap: { payeesPct: 50, buybackPct: 35, lpPct: 15 }, afterCap: { payeesPct: 0, buybackPct: 70, lpPct: 30 } })
assert.deepEqual(splitPcts(10_000, 10_000).untilCap, { payeesPct: 100, buybackPct: 0, lpPct: 0 })
assert.deepEqual(splitPcts(3333, 6667).untilCap, { payeesPct: 33.33, buybackPct: 44.4489, lpPct: 22.2211 })

// ---- the rough pool volume that reaches the cap (spec §1)
const vol = (x) => capVolume({ decimals: 18, symbol: 'WBNB', platformTaxPct: 0.5, ...x })
assert.equal(vol({ capAmount: 20n * E18, buyTaxPct: 3, sellTaxPct: 3, dividendPct: 40, payBps: 5000 }).poolVolume, 'about 2,667 WBNB')
assert.equal(vol({ capAmount: 10n * E18, buyTaxPct: 3, sellTaxPct: 3, dividendPct: 40, payBps: 5000 }).poolVolume, 'about 1,333 WBNB')
assert.equal(vol({ capAmount: 20n * E18, buyTaxPct: 3, sellTaxPct: 3, dividendPct: 0, payBps: 10_000 }).poolVolume, 'about 800 WBNB')
assert.equal(vol({ capAmount: 20n * E18, buyTaxPct: 5, sellTaxPct: 5, dividendPct: 0, payBps: 10_000 }).poolVolume, 'about 444.4 WBNB')
const range = vol({ capAmount: 20n * E18, buyTaxPct: 2, sellTaxPct: 3, dividendPct: 0, payBps: 10_000 })
assert.equal(range.poolVolume, 'about 800 WBNB (every trade at the 3% tax) to 1,333 WBNB (every trade at 2%)')
assert.match(range.how, /^cap \/ \(\(tax − 0.5% platform\) × \(1 − 0% dividend\) × 100% to the payees\)\. An estimate/)
assert.equal(capVolume({ capAmount: 20n * E6, decimals: 6, symbol: 'USDC', buyTaxPct: 3, sellTaxPct: 3, payBps: 10_000 }).poolVolume, 'about 800 USDC')

// ---- the texts a launch preview and status carry
assert.match(PERMANENT_NOTE, /^PERMANENT: the cap, its quote, .*nobody \(not you, not the platform\) can change them later; a payee can only move its own slot .*gang capped set-payee\), which leaves the cap as it is$/)
assert.match(COVERAGE_NOTE, /only this recipient's part of the pool tax.*creator's share of the curve fee .*gang creator-fee.*dev's own tokens .*not a lock.*holders' dividend/)
assert.match(OTHER_ASSETS_NOTE, /all of it goes to 0xdead when it is distributed .*never to the payees; one that cannot be sent there stays in the module$/)
assert.equal(cappedLine({ cap: '20', symbol: 'WBNB', payBps: 5000, buybackOfRestBps: 7000, payees: [ME_C, A], shares: [7000, 3000] }),
  `until the payees have been credited 20 WBNB in all: 50% to ${ME_C}: 70% of it, ${A}: 30% of it; the rest 70% buy-back and burn, 30% liquidity (LP to 0xdead). From then on all of it: 70% buy-back and burn, 30% liquidity (LP to 0xdead)`)
assert.equal(cappedLine({ cap: '1', symbol: 'USDC', payBps: 10_000, buybackOfRestBps: 0, payees: [A], shares: [10_000] }),
  `until the payees have been credited 1 USDC in all: all of it to ${A}: 100% of it. From then on all of it: 0% buy-back and burn, 100% liquidity (LP to 0xdead)`)

// ---- factory addresses: the 3.0 entries on both networks (2026-11-08), env overrides
const TESTNET_3_CAPPED = '0xe3f61865d98993dd39c136Af19651C6F6686498A'
const MAINNET_3_CAPPED = '0x294E901ecb66af280C1cDD26fD871601d89a2Dca'
assert.equal(MAINNET_CAPPED_FACTORY, MAINNET_3_CAPPED)
assert.equal(TESTNET_CAPPED_FACTORY, TESTNET_3_CAPPED)
for (const net of ['mainnet', 'testnet']) {
  for (const [i, g] of GANG_GENS[net].entries()) {
    assert.equal(g.cappedFactory, i === 0 ? (net === 'testnet' ? TESTNET_3_CAPPED : MAINNET_3_CAPPED) : null, `${net} ${g.gen} ${g.pad}`)
  }
}
assert.equal(cappedFactoryAddress(false), MAINNET_3_CAPPED)
assert.equal(cappedFactoryAddress(true), TESTNET_3_CAPPED)
process.env.GANG_CAPPED_FACTORY = A
assert.equal(cappedFactoryAddress(false), A)
assert.equal(gangGens(false)[0].cappedFactory, A)
assert.equal(gangGens(false)[1].cappedFactory, null) // the create target's only
delete process.env.GANG_CAPPED_FACTORY
process.env.GANG_TESTNET_CAPPED_FACTORY = B
assert.equal(cappedFactoryAddress(true), B)
delete process.env.GANG_TESTNET_CAPPED_FACTORY
assert.match(cappedNotDeployed(false), /not deployed on BSC mainnet in this CLI version: set GANG_CAPPED_FACTORY/)
assert.match(cappedNotDeployed(true), /not deployed on the BSC testnet in this CLI version: set GANG_TESTNET_CAPPED_FACTORY/)

// ---- status shape: a 6-decimal quote (amounts in its decimals, tokens in 18)
const enc = (code, v) => (BigInt(code) << 248n) | v
const USDC = t(0xcc), WBNB = t(0xbb), M = t(0x5), T = t(0x7), OTHER = t(0x8), STRAY = t(0x99)
const NOW = 1_800_000_000
const REF = `--token ${T} --testnet`
const quoteAsset = (extra = {}) => ({ asset: USDC, symbol: 'USDC', decimals: 6, undistributed: 0n, owedTotal: 0n, owed: null, ...extra })
const raw = (extra = {}) => ({
  module: M, dev: ME, token: T, quote: USDC, capQuote: USDC, capSymbol: 'USDC', capDecimals: 6,
  capAmount: 20n * E6, paidTotal: 195n * E6 / 10n, payBps: 5000, buybackOfRestBps: 7000, payees: [ME, A], shares: [7000, 3000],
  buybackLeft: 4n * E6, lpLeft: 2n * E6, unsplit: 2n * E6, lastChunkAt: BigInt(NOW - 600), lastPaidAt: BigInt(NOW - 60),
  keeperServesQuote: true, preview: [true, true, E6 / 10n, 5000n * E18], work: [true, enc(1, 4950n * E18)],
  graduated: true, assets: [quoteAsset({ undistributed: 2n * E6 })], now: NOW,
  ...extra,
})
const s = formatCapped(raw(), REF)
assert.equal(s.moduleType, CAPPED_TYPE)
assert.deepEqual(s.cap, { quote: USDC, symbol: 'USDC', decimals: 6, amount: '20', paid: '19.5', left: '0.5', progressPct: 97.5, reached: false })
assert.deepEqual([s.payPct, s.payBps, s.buybackOfRestBps, s.permanent], [50, 5000, 7000, true])
assert.deepEqual(s.split, { untilCap: { payeesPct: 50, buybackPct: 35, lpPct: 15 }, afterCap: { payeesPct: 0, buybackPct: 70, lpPct: 30 }, now: 'untilCap' })
assert.deepEqual(s.payees, [
  { index: 0, payee: ME, pctOfPayees: 70, pctOfRecipientUntilCap: 35, bps: 7000, isDev: true },
  { index: 1, payee: A, pctOfPayees: 30, pctOfRecipientUntilCap: 15, bps: 3000 },
])
assert.deepEqual([s.buybackLeft, s.lpLeft, s.unsplit], ['4', '2', '2'])
// the waiting 2 USDC crosses the cap: 0.5 to the payees (what is left), 1.05 / 0.45 set aside
assert.deepEqual(s.unsplitGoes, { toPayees: '0.5', toBuyback: '1.05', toLp: '0.45', reachesCap: true })
assert.deepEqual(s.nextChunk, { kind: 'buy-back', quoteIn: '0.1', tokensBurned: '5000' })
assert.deepEqual(s.keeper, { servesQuote: true, due: true, plan: decodeWorkPlan(enc(1, 4950n * E18)) })
assert.equal(s.quoteSymbol, 'USDC')
assert.deepEqual(s.assets, [{ asset: USDC, symbol: 'USDC', boundQuote: true, undistributed: '2', owedTotal: '0', splitBy: 'the keeper (the quote is one it serves) or anyone: gang capped distribute' }])
assert.deepEqual(s.next, [`gang capped chunk ${REF}`])
assert.match(s.note, /^PERMANENT: /)
assert.match(s.note, /19\.5 of the 20 USDC cap credited to the payees so far \(97\.5%\), 0\.5 left/)
assert.match(s.note, /The quote \(USDC\) is one the keeper serves: where the keeper runs capped-v1 it does the chunks and pays the payees \(once/)
assert.match(s.note, /owed to that slot \(it counts against the cap already\)/)
assert.equal(s.covers, COVERAGE_NOTE)
assert.match(s.parts.untilCap, /^50% of each tax payment .* exactly what is left of it$/)
assert.match(s.parts.rest, /70% of it bought back .* 30% added to the pair as liquidity/)
assert.equal(s.parts.otherAssets, OTHER_ASSETS_NOTE)

// the cap reached: nothing more to the payees, the split's "now" is after the cap
const done = formatCapped(raw({ paidTotal: 20n * E6, unsplit: 10n * E6 }), REF)
assert.deepEqual([done.cap.reached, done.cap.left, done.cap.progressPct, done.split.now], [true, '0', 100, 'afterCap'])
assert.deepEqual(done.unsplitGoes, { toPayees: '0', toBuyback: '7', toLp: '3' })
assert.match(done.note, /The cap is reached: the payees were credited 20 USDC in all/)
// after the cap the keeper line no longer promises the payees anything
assert.match(done.note, /where the keeper runs capped-v1 it does the chunks; anyone can do it at any time/)
assert.doesNotMatch(done.note, /pays the payees/)
// progress floors (never shows 100% before the cap is reached)
assert.equal(formatCapped(raw({ paidTotal: 20n * E6 - 1n }), REF).cap.progressPct, 99.99)
assert.equal(formatCapped(raw({ paidTotal: 20n * E6 - 1n }), REF).cap.reached, false)
// unread decimals are said
assert.match(formatCapped(raw({ capDecimals: 18, capDecimalsUnread: true }), REF).cap.decimalsNote, /assume 18/)

// owed slots and a stray asset: release the quote, distribute the stray (all of it to 0xdead)
const owing = formatCapped(raw({
  unsplit: 0n,
  assets: [
    quoteAsset({ owedTotal: 3n * E6, owed: [0n, 3n * E6] }),
    { asset: STRAY, symbol: 'X', decimals: 18, undistributed: 25n * E18 / 10n, owedTotal: 0n, owed: null },
    { asset: OTHER, symbol: 'Y', decimals: 18, undistributed: 0n, owedTotal: 0n, owed: null }, // nothing: left out
  ],
}), REF)
assert.deepEqual(owing.assets.map((a) => a.asset), [USDC, STRAY])
assert.deepEqual(owing.assets[0].owed, [{ index: 1, payee: A, amount: '3' }])
assert.equal(owing.assets[1].splitBy, 'hand: gang capped distribute (anyone): all of it to 0xdead, never to the payees')
assert.equal(owing.unsplitGoes, undefined)
assert.deepEqual(owing.next, [
  `gang capped release ${REF} --asset ${USDC} --index 1`,
  `gang capped distribute ${REF} --asset ${STRAY} (BURNS all of it: sends it to 0xdead, paid to nobody; only if that is wanted)`,
  `gang capped chunk ${REF}`,
])
// unlike combo, the stray asset's entry says it burns
assert.equal(owing.assets[1].burns, true)
assert.equal(owing.assets[0].burns, undefined)

// a quote the keeper doesn't serve: manual
const manual = formatCapped(raw({ keeperServesQuote: false, work: [false, 0n] }), REF)
assert.equal(manual.distribution, 'manual')
assert.match(manual.note, /does not serve this quote .*everything is manual/)
assert.ok(manual.next.includes(`gang capped distribute ${REF} --asset ${USDC}`))

// unbound: bind first, nothing split
const unbound = formatCapped(raw({
  token: zeroAddress, quote: zeroAddress, paidTotal: 0n, preview: null, work: null, graduated: null, keeperServesQuote: false,
  lastChunkAt: 0n, lastPaidAt: 0n, buybackLeft: 0n, lpLeft: 0n, unsplit: 0n, assets: [],
}), `--module ${M} --testnet`)
assert.deepEqual([unbound.token, unbound.quote, unbound.distribution, unbound.keeper.servesQuote, unbound.cap.paid], [null, null, 'unbound', null, '0'])
assert.match(unbound.nextChunkWaitsFor, /not bound to a token yet/)
assert.deepEqual(unbound.next, ['gang capped bind --token <the token>'])
// what a chunk waits for, as combo's
const waits = (extra) => formatCapped(raw({ preview: [false, false, 0n, 0n], work: [false, 0n], ...extra }), REF)
assert.match(waits({ graduated: false }).nextChunkWaitsFor, /has not graduated/)
assert.match(waits({ buybackLeft: 0n, lpLeft: 1n, unsplit: 0n }).nextChunkWaitsFor, /nothing set aside/)
assert.equal(waits({ lastChunkAt: BigInt(NOW - 60) }).nextChunkWaitsFor, `one chunk per 4 minutes (both kinds together): the next from ${new Date((NOW + 180) * 1000).toISOString()}`)
// the next chunk's kind counts the waiting quote as the contract splits it (capped payees' part first)
assert.equal(waits({ buybackLeft: 0n, lpLeft: 0n, unsplit: 10n * E6, paidTotal: 20n * E6 }).nextChunk.kind, 'buy-back')
assert.equal(waits({ buybackLeft: 0n, lpLeft: 0n, unsplit: 10n * E6, buybackOfRestBps: 2000 }).nextChunk.kind, 'liquidity')

// ---- decoy binds: same quote (split under the one cap, bought back elsewhere) or another (all burned)
assert.equal(decoyWarning(s, T, USDC, REF), null)
assert.equal(decoyWarning(s, null, USDC, REF), null)
assert.equal(decoyWarning({ ...s, token: null }, OTHER, USDC, REF), null)
assert.match(decoyWarning(s, OTHER, USDC, REF), /bound to another token \(.*\): this token's tax, in the same quote, is split with that token's under the one cap, and its buy-backs and liquidity go to that token's pair/)
assert.match(decoyWarning(s, OTHER, WBNB, `--token ${OTHER} --testnet`), new RegExp(`is not the bound quote, so it never reaches the payees.*all of it goes to 0xdead \\(gang capped distribute --token ${OTHER} --testnet --asset ${WBNB}\\)`))

assert.match(HINTS.WrongQuote, /capQuote/)
assert.match(HINTS.BadQuote, /WBNB, GANG or a quote in the pad's QuoteRegistry/)
assert.match(HINTS.BadCap, /--tax-cap/)
assert.match(HINTS.NothingOwed, /only ever owed the bound quote/)
assert.match(HINTS.NotFactory, /GANG_CAPPED_FACTORY/)
assert.match(HINTS.PushStarved, /365k gas/)
assert.ok(CAPPED_ABI.some((x) => x.type === 'error' && x.name === 'BadQuote'))

// ---- gang tx: the factory's Created and the module's events decode with the CLI's ABIs
const [factoryAbi, cappedAbi] = CAPPED_EVENT_ABIS
const created = {
  topics: encodeEventTopics({ abi: factoryAbi, eventName: 'Created', args: { dev: ME, module: M, capQuote: USDC } }),
  data: encodeAbiParameters([{ type: 'uint256' }, { type: 'uint16' }, { type: 'uint16' }, { type: 'address[]' }, { type: 'uint16[]' }], [20n * E6, 5000, 7000, [ME, A], [7000, 3000]]),
}
const c = decodeEventLog({ abi: factoryAbi, ...created }).args
assert.deepEqual([c.dev, c.module, c.capQuote, c.capAmount, c.payBps, c.buybackOfRestBps, c.payees, c.shares], [ME_C, getAddress(M), getAddress(USDC), 20n * E6, 5000, 7000, [ME_C, A], [7000, 3000]])
const u = (n) => Array.from({ length: n }, () => ({ type: 'uint256' }))
const reached = { topics: encodeEventTopics({ abi: cappedAbi, eventName: 'CapReached' }), data: encodeAbiParameters(u(1), [20n * E6]) }
assert.deepEqual(decodeEventLog({ abi: cappedAbi, ...reached }).args, { capAmount: 20n * E6 })
const split = { topics: encodeEventTopics({ abi: cappedAbi, eventName: 'Split' }), data: encodeAbiParameters(u(4), [10n, 3n, 2n, 5n]) }
assert.deepEqual(decodeEventLog({ abi: cappedAbi, ...split }).args, { incoming: 10n, toBuyback: 3n, toLp: 2n, toPayees: 5n })
const dist = { topics: encodeEventTopics({ abi: cappedAbi, eventName: 'Distributed', args: { asset: STRAY } }), data: encodeAbiParameters(u(2), [10n, 10n]) }
assert.deepEqual(decodeEventLog({ abi: cappedAbi, ...dist }).args, { asset: getAddress(STRAY), incoming: 10n, toDead: 10n })

// ---- creator fee into the module: its quote counts against the cap, another one is burned
assert.match(payOutCmd('capped-v1', M), /^gang capped distribute --module .* splits it as the tax: the payees' part is pushed and counted against the cap \(so it only uses the cap up sooner\)/)
assert.match(payOutCmd('capped-v1', M, '', { asset: WBNB, assetSymbol: 'WBNB' }), /sends ALL of it to 0xdead: WBNB is not the module's quote, so it is burned/)
assert.match(claimToModule({ moduleType: 'capped-v1', at: M, bound: USDC, quote: WBNB, quoteSymbol: 'WBNB', boundSymbol: 'USDC' }).warning, /quote is USDC, this fee is in WBNB: .* a fee claimed there is burned/)
assert.match(claimToModule({ moduleType: 'capped-v1', at: M, bound: zeroAddress, quote: WBNB, capQuote: USDC, capSymbol: 'USDC', quoteSymbol: 'WBNB' }).warning, /quote is USDC, .* burned/)
assert.match(claimToModule({ moduleType: 'capped-v1', at: M, bound: zeroAddress, quote: USDC, capQuote: USDC }).warning, /not bound to a token yet/)
assert.equal(claimToModule({ moduleType: 'capped-v1', at: M, bound: USDC, quote: USDC }).warning, null)
// the fee itself is never capped; claimed into the module it is split as tax (said in that order)
assert.match(notThroughModule('capped recipient', { token: T, at: M, kind: 'capped' }), /^This creator fee is yours.*after graduation\. The cap never limits it: it covers only the recipient's part of the pool tax\. To put it into the capped recipient anyway, claim it there: .*gang capped distribute --module .*counted against the cap \(so it only uses the cap up sooner\)/)
// capQuote unread on an unbound module: warn that a fee in another quote may be burned (never silent)
const unread = claimToModule({ moduleType: 'capped-v1', at: M, bound: zeroAddress, quote: WBNB, capQuote: null, quoteSymbol: 'WBNB' })
assert.match(unread.warning, /could not read the capped recipient's quote \(capQuote\): if it is not WBNB, this fee's quote, a fee claimed there is burned .*gang capped status --module /)
assert.match(claimToModule({ moduleType: 'capped-v1', at: M, bound: null, quote: WBNB, quoteSymbol: 'WBNB' }).warning, /could not read the capped recipient's quote/)
assert.match(claimToModule({ moduleType: 'combo-v1', at: M, bound: zeroAddress, quote: WBNB }).warning, /not bound to a token yet/) // others as before

// ---- a capped launch takes only the quotes the keeper serves (BadQuote): the same rule as every module
const GANG = '0x0c6302401aa5325c2e36f170f52c00b1d220b405'
const REG = t(0x4e9), LISTED = t(0x1157), Q = t(0xcd)
const fakeRead = async (_address, _abi, fn, args) => {
  if (fn === 'quoteRegistry') return REG
  if (fn === 'isQuoted') return args[0].toLowerCase() === LISTED.toLowerCase()
  throw new Error(`unexpected ${fn}`)
}
const net56 = { chainId: '56', pad: t(0x9ad), wbnb: WBNB }, net97 = { chainId: '97', pad: t(0x9ad), wbnb: WBNB }
assert.equal(await untrustedBuybackQuote(fakeRead, net56, GANG, 'capped'), null)
assert.equal(await untrustedBuybackQuote(fakeRead, net97, WBNB, 'capped'), null)
assert.equal(await untrustedBuybackQuote(fakeRead, net97, LISTED, 'capped'), null)
const unlisted = await untrustedBuybackQuote(fakeRead, net97, Q, 'capped')
const failingRead = async () => { throw new Error('rpc down') }
assert.match((await untrustedBuybackQuote(failingRead, net97, Q, 'capped')).error, /check the --tax-cap quote: try again/)
assert.match((await untrustedBuybackQuote(failingRead, net97, Q, 'combo')).error, /check the --buyback \/ --lp \/ --split quote: try again/)
assert.match(unlisted.error, /^--tax-cap \(a capped recipient\) needs WBNB, GANG or a quote listed/)
assert.match(unlisted.hint, /launch without --tax-cap/)

// ---- flags refused before any RPC (--from: no Agentic Wallet needed)
const cli = new URL('../src/index.js', import.meta.url).pathname
const gangSync = (env, ...args) => {
  const r = spawnSync(process.execPath, [cli, ...args], { encoding: 'utf8', env: { ...process.env, GANG_UPDATE_CHECK: '0', GANG_TELEMETRY: '0', GANG_CAPPED_FACTORY: '', GANG_TESTNET_CAPPED_FACTORY: '', ...env } })
  try { return JSON.parse(r.stdout) } catch { return { raw: r.stdout + r.stderr } }
}
const refused = (args, re, env = {}) => {
  const r = gangSync(env, ...args)
  assert.equal(r.success, false, args.join(' '))
  assert.match(r.error, re, args.join(' '))
  return r
}
const F = { GANG_TESTNET_CAPPED_FACTORY: t(0xfac), GANG_CAPPED_FACTORY: t(0xfac) } // past the not-deployed check
const base = ['create', '--name', 'C', '--symbol', 'C', '--from', ME, '--testnet']
const taxed = [...base, '--buy-tax', '2', '--sell-tax', '3']
// (both networks have one built in since 2026-11-08)
refused([...base, '--tax-cap', '20'], /--tax-cap \(a capped tax recipient\) needs a taxed token: add --buy-tax and --sell-tax/, F)
refused([...base, '--buy-tax', '0', '--sell-tax', '0', '--tax-cap', '20'], /needs a taxed token/, F)
refused([...base, '--buy-tax', '2', '--sell-tax', '6', '--tax-cap', '20'], /needs a taxed token: add --buy-tax and --sell-tax, each 1–5/, F)
for (const f of ['buyback', 'lp']) refused([...taxed, '--tax-cap', '20', `--${f}`, '30'], new RegExp(`--${f} does not go with --tax-cap: .*--after-cap buyback:<pct>,lp:<pct>`), F)
for (const f of ['buyback-to', 'lp-to']) refused([...taxed, '--tax-cap', '20', `--${f}`, A], new RegExp(`--${f} does not go with --tax-cap`), F)
refused([...taxed, '--tax-cap', '20', '--recipient', A], /--tax-cap makes the recipient your capped recipient: leave --recipient out/, F)
refused([...taxed, '--tax-cap', '20', '--dividend', '100'], /--dividend 100 leaves nothing for the recipient: lower it or drop --tax-cap/, F)
refused([...taxed, '--tax-cap', '0'], /--tax-cap must be above 0/, F)
refused([...taxed, '--tax-cap', 'lots'], /--tax-cap must be a positive amount/, F)
refused([...taxed, '--tax-cap', '20', '--tax-cap-share', '0'], /--tax-cap-share is the payees' %/, F)
refused([...taxed, '--tax-cap', '20', '--after-cap', 'buyback:70,lp:20'], /--after-cap: the parts add up to 90%/, F)
refused([...taxed, '--tax-cap', '20', '--after-cap', 'burn:100'], /is not buyback:<pct> or lp:<pct>/, F)
refused([...taxed, '--tax-cap', '20', '--split', `${A}:60,${B}:30`], /add up to 90%/, F)
refused([...taxed, '--tax-cap-share', '50'], /--tax-cap-share \/ --after-cap go with --tax-cap <amount>/)
refused([...taxed, '--after-cap', 'lp:100', '--bond', '1', '--dev-buy', '1', '--bond-days', '7'], /--tax-cap-share \/ --after-cap go with --tax-cap <amount>/)
for (const f of [['--tax-cap', '20'], ['--tax-cap-share', '50'], ['--after-cap', 'lp:100']]) {
  refused(['create', '--fair', '--name', 'C', '--symbol', 'C', '--from', ME, '--testnet', ...f], new RegExp(`^${f[0]} is for V3 tokens: it makes the tax recipient a capped recipient, and a 打新 token has no recipient`))
  refused(['create', '--fair', '--name', 'C', '--symbol', 'C', '--from', ME, '--testnet', '--bond', '1', '--bond-days', '7', ...f], new RegExp(`^${f[0]} is for V3 tokens`))
}
refused(['create', '--fly', '--name', 'C', '--symbol', 'C', '--tax-cap', '20'], /^--tax-cap: 铸币飞轮 tokens take no .*capped recipient/)
refused(['create', '--fly', '--name', 'C', '--symbol', 'C', '--after-cap', 'lp:100'], /capped recipient or --dev-buy/)
refused([...taxed, '--vault', A, '--tax-cap', '20'], /--tax-cap: a --vault create stands alone/)
refused(['capped', 'nope'], /usage: gang capped <status\|distribute\|release\|set-payee\|bind\|chunk>/)
refused(['capped'], /usage: gang capped/)
refused(['capped', 'status', '--token', 'nope', '--testnet'], /--token must be a V3 token address/)
refused(['capped', 'status', '--token', A, '--module', B, '--testnet'], /not both/)
refused(['capped', 'bind', '--module', B, '--testnet'], /needs --token/)
// plain --cap is untouched: the 打新 per-wallet cap, refused on a V3 create and on a 铸币飞轮 one as before
refused(['create', '--fair', '--name', 'C', '--symbol', 'C', '--from', ME, '--testnet', '--cap', '7'], /--cap must be a number between 0.25 and 1/)
const v3cap = refused([...base, '--cap', '20'], /^--cap is a 打新 \(fair-mint\) setting: add --fair to create a sale \(gang create --fair …\)$/, F)
assert.match(v3cap.hint, /use --tax-cap <amount>/)
refused([...taxed, '--cap', '20'], /^--cap is a 打新 \(fair-mint\) setting/, F)
refused(['create', '--fly', '--name', 'C', '--symbol', 'C', '--cap', '20'], /^--cap is 打新's: a 铸币飞轮 sale has a quota per wallet, --quota <5-100> \(\+ --invite-bonus\)$/)

// the help lists the commands and the flags
const help = spawnSync(process.execPath, [cli, 'help'], { encoding: 'utf8', env: { ...process.env, GANG_UPDATE_CHECK: '0' } }).stdout
for (const x of ['--tax-cap <amount> [--tax-cap-share <0.01-100>]', '[--after-cap buyback:<pct>,lp:<pct>]', 'capped recipient (GangCappedSplitter, capped-v1', 'PERMANENT: the cap',
  'not your creator', 'gang capped status', 'gang capped distribute', 'gang capped release', 'gang capped set-payee', 'gang capped bind',
  'gang capped chunk', 'GANG_CAPPED_FACTORY', 'GANG_TESTNET_CAPPED_FACTORY']) {
  assert.ok(help.includes(x), `help mentions ${x}`)
}

// ---- against a fake BSC testnet node: the clone step, the re-run check, gang capped status --module
const FACTORY = t(0xfac), MODULE = getAddress(t(0x5a1)), TOKEN = t(0x7e1)
const NODE_ABI = parseAbi([
  'function quoteRegistry() view returns (address)', 'function isQuoted(address) view returns (bool)',
  'function symbol() view returns (string)', 'function decimals() view returns (uint8)',
  'function predict(address dev, bytes32 salt) view returns (address)', 'function PLATFORM_TAX_BPS() view returns (uint256)',
  'function tokenCount() view returns (uint256)',
  'function create(address capQuote, uint256 capAmount, uint16 payBps, uint16 buybackOfRestBps, address[] payees, uint16[] shares, bytes32 salt) returns (address module)',
  'function pad() view returns (address)', 'function moduleType() view returns (bytes32)', 'function dev() view returns (address)',
  'function token() view returns (address)', 'function quote() view returns (address)', 'function gangQuote() view returns (address)',
  'function capQuote() view returns (address)', 'function capAmount() view returns (uint256)', 'function paidTotal() view returns (uint256)',
  'function payBps() view returns (uint16)', 'function buybackOfRestBps() view returns (uint16)',
  'function payeesOf() view returns (address[], uint16[])', 'function buybackLeft() view returns (uint256)', 'function lpLeft() view returns (uint256)',
  'function unsplit() view returns (uint256)', 'function lastChunkAt() view returns (uint64)', 'function lastPaidAt() view returns (uint64)',
  'function previewChunk() view returns (bool, bool, uint256, uint256)', 'function previewWork() view returns (bool, uint256)',
  'function keeperServes(address) view returns (bool)', 'function undistributed(address) view returns (uint256)',
  'function owedTotal(address) view returns (uint256)', 'function owedOf(address, uint256) view returns (uint256)',
  'function curves(address) view returns (address, address, uint128, uint128, uint128, uint128, bool, uint16, uint16, uint16, address, address)',
  'function balanceOf(address) view returns (uint256)', 'function bind(address token)',
])
const SEL = new Map(NODE_ABI.map((x) => [toFunctionSelector(x), x.name]))
const created_ = [] // the create args the node was asked to simulate
let world = {}
const Q2 = t(0xc2) // another 6-decimal quote (USDT here)
const value = (to, fn, args) => ({
  quoteRegistry: () => REG, isQuoted: () => args[0].toLowerCase() === USDC.toLowerCase(),
  symbol: () => ({ [USDC.toLowerCase()]: 'USDC', [Q2.toLowerCase()]: 'USDT' }[to.toLowerCase()] ?? 'WBNB'),
  decimals: () => ([USDC, Q2].some((q) => q.toLowerCase() === to.toLowerCase()) ? 6 : 18),
  balanceOf: () => 0n, bind: () => undefined,
  predict: () => MODULE, PLATFORM_TAX_BPS: () => 50n, tokenCount: () => 7n,
  create: () => { created_.push(args); return MODULE },
  pad: () => GANG_GENS.testnet[0].pad, moduleType: () => stringToHex(CAPPED_TYPE, { size: 32 }), dev: () => ME,
  token: () => world.token ?? zeroAddress, quote: () => world.token ? USDC : zeroAddress, gangQuote: () => zeroAddress,
  capQuote: () => USDC, capAmount: () => 20n * E6, paidTotal: () => world.paid ?? 0n, payBps: () => 5000, buybackOfRestBps: () => 7000,
  payeesOf: () => [[ME_C, A], [7000, 3000]], buybackLeft: () => 0n, lpLeft: () => 0n, unsplit: () => world.unsplit ?? 0n,
  lastChunkAt: () => 0n, lastPaidAt: () => 0n, previewChunk: () => [false, false, 0n, 0n], previewWork: () => [false, 0n],
  keeperServes: () => true, undistributed: (a = args[0]) => (a.toLowerCase() === USDC.toLowerCase() ? world.unsplit ?? 0n : 0n),
  owedTotal: () => 0n, owedOf: () => 0n,
  curves: () => [ME, USDC, 0n, 0n, 0n, 0n, true, 0, 0, 0, t(0x9a1), zeroAddress],
}[fn]())
const server = createServer((req, res) => {
  let body = ''
  req.on('data', (x) => (body += x))
  req.on('end', () => {
    const one = (b) => {
      if (b.method === 'eth_chainId') return { result: '0x61' }
      if (b.method === 'eth_getCode') return { result: '0x6080' }
      if (b.method !== 'eth_call') return { error: { code: -32601, message: `unexpected ${b.method}` } }
      const { to, data } = b.params[0]
      const fn = SEL.get(data.slice(0, 10))
      if (fn === 'decimals' && world.decimalsFail) return { error: { code: -32603, message: 'node hiccup' } }
      if (!fn) return { error: { code: 3, message: 'execution reverted', data: '0x' } }
      const { args } = decodeFunctionData({ abi: NODE_ABI, data })
      return { result: encodeFunctionResult({ abi: NODE_ABI, functionName: fn, result: value(to, fn, args ?? []) }) }
    }
    const b = JSON.parse(body)
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify(Array.isArray(b) ? b.map((x) => ({ jsonrpc: '2.0', id: x.id, ...one(x) })) : { jsonrpc: '2.0', id: b.id, ...one(b) }))
  })
})
await new Promise((r) => server.listen(0, '127.0.0.1', r))
const LAUNCH_DIR = mkdtempSync(join(tmpdir(), 'gang-capped-'))
const gang = (...args) => new Promise((resolve) => {
  const p = spawn(process.execPath, [cli, ...args, '--testnet'], {
    env: { ...process.env, GANG_TESTNET_RPC_URL: `http://127.0.0.1:${server.address().port}`, GANG_TESTNET_CAPPED_FACTORY: FACTORY, GANG_LAUNCH_DIR: LAUNCH_DIR, GANG_UPDATE_CHECK: '0', GANG_TELEMETRY: '0', PATH: '' },
  })
  let o = ''
  p.stdout.on('data', (x) => (o += x))
  p.on('close', () => resolve(JSON.parse(o)))
})
try {
  const launch = ['create', '--name', 'Capped', '--symbol', 'CAP', '--from', ME, '--buy-tax', '3', '--sell-tax', '3', '--dividend', '40',
    '--quote', USDC, '--tax-cap', '20', '--tax-cap-share', '50', '--split', `self:70,${A}:30`, '--after-cap', 'buyback:70,lp:30', '--calldata']
  // an unlisted quote is refused before the clone (initialize would revert BadQuote)
  const unlistedQ = await gang(...launch.map((x) => (x === USDC ? Q : x)))
  assert.equal(unlistedQ.success, false)
  assert.match(unlistedQ.error, /--tax-cap \(a capped recipient\) needs WBNB, GANG or a quote listed/)
  // too many decimals for the quote's own (6)
  const fine = await gang(...launch.map((x) => (x === '20' ? '20.0000001' : x)))
  assert.match(fine.error, /USDC has 6 decimals/)
  const r = await gang(...launch)
  assert.equal(r.success, true, JSON.stringify(r))
  assert.equal(r.step, 'capped-module')
  assert.deepEqual(r.launch.steps, ['capped-module', 'create', 'bind'])
  assert.equal(r.launch.stage, 'capped-module')
  assert.equal(r.module, MODULE)
  assert.equal(r.tx.to.toLowerCase(), FACTORY.toLowerCase())
  assert.deepEqual(r.cap, { amount: '20', symbol: 'USDC', quote: USDC, decimals: 6 })
  assert.deepEqual([r.payPct, r.untilCap, r.afterCap], [50, { payeesPct: 50, buybackPct: 35, lpPct: 15 }, { payeesPct: 0, buybackPct: 70, lpPct: 30 }])
  assert.deepEqual(r.payees.map((p) => [p.payee, p.pctOfPayees, p.pctOfRecipientUntilCap]), [[ME_C, 70, 35], [A, 30, 15]])
  assert.equal(r.capReachedAt.poolVolume, 'about 2,667 USDC')
  assert.equal(r.permanent, true)
  assert.equal(r.covers, COVERAGE_NOTE)
  assert.match(r.note, /^clones your capped recipient \(capped-v1, listed as a tax recipient in the same tx\)\. Of the recipient's part of the tax: until the payees have been credited 20 USDC in all/)
  assert.match(r.note, /reached after about 2,667 USDC of pool volume \(an estimate\)\. PERMANENT: .*The cap covers only .*Any other asset/)
  // the calldata: the cap in the quote's 6 decimals, the launch's quote as capQuote
  const sent = decodeFunctionData({ abi: NODE_ABI, data: r.tx.data })
  assert.equal(sent.functionName, 'create')
  assert.deepEqual(sent.args.slice(0, 6), [getAddress(USDC), 20n * E6, 5000, 7000, [ME_C, A], [7000, 3000]])
  assert.deepEqual(created_.at(-1).slice(0, 6), sent.args.slice(0, 6)) // simulated before it was offered
  // the re-run: the module is on chain (unbound); other terms are refused, as is another quote
  const other = await gang(...launch.map((x) => (x === '20' ? '25' : x)))
  assert.equal(other.success, false)
  assert.match(other.error, /this launch's capped recipient pays until the payees have been credited 20 USDC .* not what --tax-cap \/ --tax-cap-share \/ --split \/ --after-cap say/)
  const wbnbNow = await gang(...launch.filter((x, i) => x !== '--quote' && launch[i - 1] !== '--quote'))
  assert.match(wbnbNow.error, /counts its cap in USDC, not in WBNB: run it again with --quote/)
  // N-3: another quote is said first, before the cap's form in that quote
  const usdt = await gang(...launch.map((x) => (x === USDC ? Q2 : x === '20' ? '20.0000001' : x)))
  assert.match(usdt.error, /counts its cap in USDC, not in USDT: run it again with --quote/)
  // L-2: a failed decimals read is retried, never a false mismatch pointing at --restart
  world = { decimalsFail: true }
  const flaky = await gang(...launch)
  assert.equal(flaky.success, false)
  assert.match(flaky.error, /could not read the capped recipient's cap or its quote's decimals/)
  assert.equal(flaky.retry, 'same command again')
  assert.doesNotMatch(JSON.stringify(flaky), /--restart/)
  world = {}
  // "20" and "20.000000" are the same cap in raw units: past the check, on to the create (which this fake node can't serve)
  assert.doesNotMatch(String((await gang(...launch.map((x) => (x === '20' ? '20.000000' : x)))).error), /not what --tax-cap|counts its cap/)

  // L-1: after the create (the plan holds the token), changed terms are still refused, and the bind shows the cap
  const [planFile] = readdirSync(LAUNCH_DIR)
  const plan = JSON.parse(readFileSync(join(LAUNCH_DIR, planFile), 'utf8'))
  assert.equal(plan.module, 'capped')
  writeFileSync(join(LAUNCH_DIR, planFile), JSON.stringify({ ...plan, startCount: '6', token: TOKEN }))
  const after = await gang(...launch.map((x) => (x === '20' ? '10' : x)))
  assert.equal(after.success, false)
  assert.match(after.error, /this launch's capped recipient pays until the payees have been credited 20 USDC .* not what --tax-cap/)
  const afterShare = await gang(...launch.map((x) => (x === '50' ? '60' : x)))
  assert.match(afterShare.error, /not what --tax-cap \/ --tax-cap-share/)
  const bind = await gang(...launch)
  assert.equal(bind.success, true, JSON.stringify(bind))
  assert.equal(bind.step, 'bind')
  assert.equal(bind.launch.stage, 'bind')
  assert.deepEqual([bind.cap.amount, bind.cap.symbol, bind.cap.paid, bind.payPct], ['20', 'USDC', '0', 50])
  assert.deepEqual([bind.untilCap, bind.afterCap], [{ payeesPct: 50, buybackPct: 35, lpPct: 15 }, { payeesPct: 0, buybackPct: 70, lpPct: 30 }])
  assert.deepEqual(bind.payees.map((p) => [p.payee, p.pctOfPayees]), [[ME_C, 70], [A, 30]])
  assert.equal(bind.covers, COVERAGE_NOTE)
  assert.match(bind.note, /^ties the capped recipient to this token for good: .*What it holds, fixed for good: until the payees have been credited 20 USDC in all: 50% to /)
  // left out, the flags no longer decide anything: the plan's module is bound as it is, and the preview says what it holds
  const bare = await gang('create', '--name', 'Capped', '--symbol', 'CAP', '--from', ME, '--buy-tax', '3', '--sell-tax', '3', '--dividend', '40', '--quote', USDC, '--calldata', '--dev-buy', '0.1')
  assert.equal(bare.step, 'bind', JSON.stringify(bare))
  assert.equal(bare.cap.amount, '20')

  // gang capped status --module: the bound module, 6 decimals, the waiting quote crossing the cap
  world = { token: TOKEN, paid: 195n * E6 / 10n, unsplit: 2n * E6 }
  const st = await gang('capped', 'status', '--module', MODULE)
  assert.equal(st.success, true, JSON.stringify(st))
  assert.deepEqual(st.cap, { quote: getAddress(USDC), symbol: 'USDC', decimals: 6, amount: '20', paid: '19.5', left: '0.5', progressPct: 97.5, reached: false })
  assert.deepEqual(st.unsplitGoes, { toPayees: '0.5', toBuyback: '1.05', toLp: '0.45', reachesCap: true })
  assert.equal(st.moduleType, CAPPED_TYPE)
} finally {
  server.close()
  rmSync(LAUNCH_DIR, { recursive: true, force: true })
}
console.log('capped: ok')
