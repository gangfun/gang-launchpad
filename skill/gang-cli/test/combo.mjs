/**
 * Combined recipient (GangComboSplitter, combo-v1) without a chain: parsing a combined launch's --buyback / --lp / --split
 * (every combination and every refusal GangComboSplitter.initialize makes), the status shape (formatCombo) for a bound,
 * an unbound, a no-payee and a waiting module, previewWork's minOut decoding, the events gang tx decodes, and the launch /
 * command flags refused before any RPC (index.js, launch.js), including mainnet's "not on mainnet yet". The on-chain steps
 * are covered by the testnet run in the CLI's release notes.
 *
 *   node skill/gang-cli/test/combo.mjs
 */
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { decodeEventLog, encodeAbiParameters, encodeEventTopics, getAddress } from 'viem'
import {
  parseComboSpec, formatCombo, decodeWorkPlan, comboFactoryAddress, comboLine, comboNotDeployed, decoyWarning, HINTS,
  COMBO_TYPE, COMBO_EVENT_ABIS, TESTNET_COMBO_FACTORY, MAINNET_COMBO_FACTORY, PERMANENT_NOTE,
} from '../src/combo.js'
import { untrustedBuybackQuote } from '../src/launch.js'

const ME = '0x00000000000000000000000000000000000000aa'
const ME_C = getAddress(ME)
const A = '0x1111111111111111111111111111111111111111'
const B = '0x2222222222222222222222222222222222222222'
const t = (n) => `0x${String(n).padStart(40, '0')}`
const E18 = 10n ** 18n

// ---- parsing: buy-back and LP % of the recipient's part, --split shares of the rest
const three = parseComboSpec({ buybackBps: 3000, lpBps: 3000, split: `self:70,${A}:30` }, ME)
assert.equal(three.error, undefined)
assert.deepEqual([three.buybackBps, three.lpBps], [3000, 3000])
assert.deepEqual(three.payees, [ME_C, A])
assert.deepEqual(three.shares, [7000, 3000])
assert.deepEqual(three.list, [
  { index: 0, payee: ME_C, you: true, pctOfRest: 70, pctOfRecipient: 28 },
  { index: 1, payee: A, pctOfRest: 30, pctOfRecipient: 12 },
])
// two of three: buy-back + split, LP + split, buy-back + LP (the rest to you)
assert.deepEqual(parseComboSpec({ buybackBps: 2000, split: `${A}:50,${B}:50` }, ME).shares, [5000, 5000])
assert.equal(parseComboSpec({ buybackBps: 2000, split: `${A}:50,${B}:50` }, ME).lpBps, 0)
assert.equal(parseComboSpec({ lpBps: 2500, split: `${A}:100` }, ME).list[0].pctOfRecipient, 75)
const noSplit = parseComboSpec({ buybackBps: 4000, lpBps: 2000 }, ME)
assert.deepEqual(noSplit.payees, [ME_C])
assert.deepEqual(noSplit.shares, [10000])
assert.deepEqual(noSplit.list, [{ index: 0, payee: ME_C, you: true, pctOfRest: 100, pctOfRecipient: 40 }])
// 100% buy-back + LP: no payees at all
const full = parseComboSpec({ buybackBps: 5000, lpBps: 5000 }, ME)
assert.deepEqual([full.payees, full.shares, full.list], [[], [], []])
assert.deepEqual(parseComboSpec({ buybackBps: 10000, lpBps: 0 }, ME).payees, [])
// odd ratios: % of the recipient rounded to 4 decimals
assert.equal(parseComboSpec({ buybackBps: 3333, lpBps: 3333, split: `${A}:33.33,${B}:66.67` }, ME).list[0].pctOfRecipient, 11.1122)
// ten payees is the most
const ten = Array.from({ length: 10 }, (_, i) => `${t(i + 1)}:10`).join(',')
assert.equal(parseComboSpec({ buybackBps: 1000, lpBps: 1000, split: ten }, ME).payees.length, 10)

const bad = (spec, re, me = ME) => {
  const r = parseComboSpec(spec, me)
  assert.ok(r.error, `refused: ${JSON.stringify(spec)}`)
  assert.match(r.error, re, JSON.stringify(spec))
  return r
}
bad({ buybackBps: 6000, lpBps: 5000 }, /--buyback 60 \+ --lp 50 is 110%, more than 100%/)
bad({ buybackBps: 6000, lpBps: 5000, split: `${A}:100` }, /more than 100%/)
bad({ buybackBps: 5000, lpBps: 5000, split: `${A}:100` }, /100% of the recipient's part: nothing is left for payees, so --split is refused/)
bad({ buybackBps: 10000, split: `self:100` }, /--split is refused/)
bad({ buybackBps: 0, lpBps: 0, split: `${A}:100` }, /give --split alone/)
bad({ buybackBps: 0, lpBps: 0 }, /give --split alone/)
bad({ buybackBps: 3000, lpBps: 3000 }, /sign in with baw, or give --from/, null) // the rest goes to you: needs your address
// --split's own checks, with the shares-of-the-rest hint
const sum = bad({ buybackBps: 3000, lpBps: 3000, split: `${A}:60,${B}:30` }, /add up to 90%, not 100%/)
assert.match(sum.hint, /shares of .*rest|of that rest/)
bad({ buybackBps: 3000, lpBps: 3000, split: `${A}:50,${A}:50` }, /appears twice/)
bad({ buybackBps: 3000, lpBps: 3000, split: `self:50,${ME}:50` }, /appears twice/)
bad({ buybackBps: 3000, lpBps: 3000, split: `${A}:0,${B}:100` }, /0% share/)
bad({ buybackBps: 3000, lpBps: 3000, split: `${t(0)}:100` }, /zero address/)
bad({ buybackBps: 3000, lpBps: 3000, split: `0x123:100` }, /not a 0x address/)
bad({ buybackBps: 3000, lpBps: 3000, split: `${A}:33.333,${B}:66.667` }, /at most 2 decimals/)
bad({ buybackBps: 3000, lpBps: 3000, split: `${Array.from({ length: 11 }, (_, i) => `${t(i + 1)}:9`).join(',')}` }, /at most 10 payees/)
bad({ buybackBps: 3000, lpBps: 3000, split: '' }, /takes <addr>:<pct>/)
bad({ buybackBps: 3000, lpBps: 3000, split: '--dev-buy' }, /takes <addr>:<pct>/)

// the one-line summary and the permanence text the preview carries
assert.equal(comboLine(3000, 3000, [ME_C, A], [7000, 3000]),
  `30% buy-back and burn, 30% liquidity (LP to 0xdead), the rest (40%) to ${ME_C}: 70% of it, ${A}: 30% of it`)
assert.equal(comboLine(5000, 5000, [], []), '50% buy-back and burn, 50% liquidity (LP to 0xdead)')
assert.match(PERMANENT_NOTE, /^PERMANENT: .*nobody \(not you, not the platform\) can change them later, unlike a lone --buyback or --lp splitter/)

// ---- factory addresses: testnet built in, mainnet not deployed yet (null), env overrides
assert.equal(MAINNET_COMBO_FACTORY, null)
assert.equal(comboFactoryAddress(true), TESTNET_COMBO_FACTORY)
assert.equal(comboFactoryAddress(false), null)
process.env.GANG_COMBO_FACTORY = A
assert.equal(comboFactoryAddress(false), A)
delete process.env.GANG_COMBO_FACTORY
process.env.GANG_TESTNET_COMBO_FACTORY = B
assert.equal(comboFactoryAddress(true), B)
delete process.env.GANG_TESTNET_COMBO_FACTORY
assert.match(comboNotDeployed(false), /not on BSC mainnet yet/)
assert.match(comboNotDeployed(false), /GANG_COMBO_FACTORY/)
assert.match(comboNotDeployed(true), /GANG_TESTNET_COMBO_FACTORY/)

// ---- previewWork's minOut: the action in the top byte, the minimum below
const enc = (code, v) => (BigInt(code) << 248n) | v
assert.deepEqual(decodeWorkPlan(enc(1, 5n * E18)), { code: 1, action: 'buy-back', minTokensOut: '5', what: decodeWorkPlan(enc(1, 0n)).what })
assert.match(decodeWorkPlan(enc(1, 0n)).what, /buy-back chunk/)
assert.equal(decodeWorkPlan(enc(2, 123n * E18)).minTokensOut, '123')
assert.equal(decodeWorkPlan(enc(2, 0n)).action, 'liquidity')
assert.deepEqual(decodeWorkPlan(enc(3, 0n)).action, 'observe')
assert.equal(decodeWorkPlan(enc(3, 0n)).minTokensOut, undefined)
assert.equal(decodeWorkPlan(enc(4, 0n)).action, 'split')
assert.equal(decodeWorkPlan(0n).action, 'none')
assert.equal(decodeWorkPlan(enc(9, 0n)).action, 'unknown (9)')

// ---- status shape
const WBNB = t(0xbb), M = t(0x5), T = t(0x7), OTHER = t(0x8), STRAY = t(0x99)
const NOW = 1_800_000_000
const REF = `--token ${T} --testnet`
const quoteAsset = (extra = {}) => ({ asset: WBNB, symbol: 'WBNB', decimals: 18, undistributed: 0n, owedTotal: 0n, owed: null, ...extra })
const raw = (extra = {}) => ({
  module: M, dev: ME, token: T, quote: WBNB, buybackBps: 3000, lpBps: 3000, payees: [ME, A], shares: [7000, 3000],
  buybackLeft: 4n * E18 / 10n, lpLeft: 2n * E18 / 10n, unsplit: 0n, lastChunkAt: BigInt(NOW - 600), lastPaidAt: BigInt(NOW - 60),
  keeperServesQuote: true, preview: [true, true, 1n * E18 / 10n, 5000n * E18], work: [true, enc(1, 4950n * E18)],
  graduated: true, assets: [quoteAsset()], now: NOW,
  ...extra,
})
const s = formatCombo(raw(), REF)
assert.equal(s.moduleType, COMBO_TYPE)
assert.deepEqual([s.buybackPct, s.lpPct, s.payeesPct, s.permanent], [30, 30, 40, true])
assert.deepEqual(s.payees, [
  { index: 0, payee: ME, pctOfRest: 70, pctOfRecipient: 28, bps: 7000, isDev: true },
  { index: 1, payee: A, pctOfRest: 30, pctOfRecipient: 12, bps: 3000 },
])
assert.deepEqual([s.buybackLeft, s.lpLeft, s.unsplit], ['0.4', '0.2', '0'])
assert.deepEqual(s.nextChunk, { kind: 'buy-back', quoteIn: '0.1', tokensBurned: '5000' })
assert.equal(s.nextChunkWaitsFor, undefined)
assert.equal(s.distribution, 'keeper')
assert.deepEqual(s.keeper, { servesQuote: true, due: true, plan: { code: 1, action: 'buy-back', minTokensOut: '4950', what: decodeWorkPlan(enc(1, 0n)).what } })
assert.equal(s.lastChunkAt, new Date((NOW - 600) * 1000).toISOString())
assert.equal(s.quoteSymbol, 'WBNB')
assert.deepEqual(s.assets, [{ asset: WBNB, symbol: 'WBNB', boundQuote: true, undistributed: '0', owedTotal: '0', splitBy: 'keeper (or anyone, gang combo distribute)' }])
assert.deepEqual(s.next, [`gang combo chunk ${REF}`])
assert.match(s.note, /^PERMANENT: /)
assert.match(s.note, /The keeper serves this quote \(WBNB\)/)
assert.match(s.parts.otherAssets, /buy-back \+ LP share \(60%\) goes to 0xdead, the rest to the payees/)
assert.match(s.parts.buyback, /^30% of each tax payment to this recipient/)
assert.match(s.parts.liquidity, /^30% is set aside .* LP sent to 0xdead/)

// a liquidity chunk ready; the keeper only observing / splitting
const liq = formatCombo(raw({ preview: [true, false, 2n * E18 / 10n, 300n * E18], work: [true, enc(3, 0n)] }), REF)
assert.deepEqual(liq.nextChunk, { kind: 'liquidity', quoteChunk: '0.2', buyHalf: '0.1', tokensBought: '300' })
assert.equal(liq.keeper.plan.action, 'observe')
assert.equal(formatCombo(raw({ work: [true, enc(4, 0n)] }), REF).keeper.plan.action, 'split')
assert.equal(formatCombo(raw({ work: [false, 0n] }), REF).keeper.plan, undefined)

// owed slots and a stray asset waiting: next commands, the asset's way (buy-back + LP share to 0xdead)
const owing = formatCombo(raw({
  assets: [
    quoteAsset({ owedTotal: 3n * E18, owed: [0n, 3n * E18] }),
    { asset: STRAY, symbol: 'X', decimals: 6, undistributed: 2_500_000n, owedTotal: 0n, owed: null },
    { asset: OTHER, symbol: 'Y', decimals: 18, undistributed: 0n, owedTotal: 0n, owed: null }, // nothing: left out
  ],
}), REF)
assert.deepEqual(owing.assets.map((a) => a.asset), [WBNB, STRAY])
assert.deepEqual(owing.assets[0].owed, [{ index: 1, payee: A, amount: '3' }])
assert.equal(owing.assets[1].undistributed, '2.5')
assert.match(owing.assets[1].splitBy, /60% to 0xdead, the rest to the payees/)
assert.deepEqual(owing.next, [
  `gang combo release ${REF} --asset ${WBNB} --index 1`, `gang combo distribute ${REF} --asset ${STRAY}`, `gang combo chunk ${REF}`,
])

// a quote the keeper doesn't serve: manual
const manual = formatCombo(raw({ keeperServesQuote: false, work: [false, 0n], assets: [quoteAsset({ undistributed: E18 })] }), REF)
assert.equal(manual.distribution, 'manual')
assert.match(manual.note, /does not serve this quote .*everything is manual/)
assert.ok(manual.next.includes(`gang combo distribute ${REF} --asset ${WBNB}`))

// unbound: nothing split, bind first; no distribute suggested (NotBound)
const unbound = formatCombo(raw({
  token: t(0), quote: t(0), preview: null, work: null, graduated: null, keeperServesQuote: false, lastChunkAt: 0n, lastPaidAt: 0n,
  buybackLeft: 0n, lpLeft: 0n, assets: [{ asset: STRAY, symbol: 'X', decimals: 18, undistributed: E18, owedTotal: 0n, owed: null }],
}), `--module ${M} --testnet`)
assert.deepEqual([unbound.token, unbound.quote, unbound.distribution, unbound.keeper.servesQuote, unbound.lastChunkAt], [null, null, 'unbound', null, null])
assert.match(unbound.nextChunkWaitsFor, /not bound to a token yet/)
assert.deepEqual(unbound.next, ['gang combo bind --token <the token>'])
assert.match(unbound.assets[0].splitBy, /NotBound/)

// what a chunk waits for, most basic first
const waits = (extra) => formatCombo(raw({ preview: [false, false, 0n, 0n], work: [false, 0n], ...extra }), REF)
assert.match(waits({ graduated: false }).nextChunkWaitsFor, /has not graduated/)
assert.match(waits({ buybackLeft: 0n, lpLeft: 1n }).nextChunkWaitsFor, /nothing set aside/) // 1 wei of LP has no half
assert.equal(waits({ buybackLeft: 0n, lpLeft: 1n }).nextChunk.kind, null)
assert.equal(waits({ lastChunkAt: BigInt(NOW - 60) }).nextChunkWaitsFor, `one chunk per 4 minutes (both kinds together): the next from ${new Date((NOW + 180) * 1000).toISOString()}`)
assert.match(waits({}).nextChunkWaitsFor, /the price check/)
// the next chunk's kind: the larger part once the waiting quote is split (a buy-back on a tie)
assert.equal(waits({}).nextChunk.kind, 'buy-back')
assert.equal(waits({ buybackLeft: E18, lpLeft: 2n * E18 }).nextChunk.kind, 'liquidity')
assert.equal(waits({ buybackLeft: E18, lpLeft: E18 }).nextChunk.kind, 'buy-back')
assert.equal(waits({ buybackLeft: 0n, lpLeft: 0n, unsplit: E18 }).nextChunk.kind, 'buy-back')
assert.equal(waits({ buybackBps: 1000, lpBps: 5000, buybackLeft: 0n, lpLeft: 0n, unsplit: E18 }).nextChunk.kind, 'liquidity')
assert.match(waits({ buybackLeft: 0n, lpLeft: 0n, unsplit: E18 }).nextChunkWaitsFor, /the price check/)

// no payees (100% buy-back + LP): other assets go to 0xdead in full
const none = formatCombo(raw({ buybackBps: 5000, lpBps: 5000, payees: [], shares: [] }), REF)
assert.deepEqual([none.payees, none.payeesPct], [[], 0])
assert.match(none.parts.payees, /no payees/)
assert.match(none.parts.otherAssets, /goes to 0xdead in full/)

// a decoy bind: the token pays the combo, the combo is bound to another token
assert.equal(decoyWarning(s, T, WBNB, REF), null)
assert.equal(decoyWarning(s, null, WBNB, REF), null)
assert.match(decoyWarning(s, OTHER, WBNB, `--token ${OTHER} --testnet`), new RegExp(`bound to another token \\(${T}\\).*gang combo distribute --token ${OTHER} --testnet --asset ${WBNB}`))
assert.equal(decoyWarning({ ...s, token: null }, OTHER, WBNB, REF), null) // unbound: bind says so

assert.match(HINTS.PushStarved, /365k gas/)
assert.match(HINTS.ChunkTooSoon, /4 minutes/)
assert.match(HINTS.NotBound, /gang combo bind/)
assert.match(HINTS.NotFactory, /GANG_COMBO_FACTORY/)

// ---- gang tx: the factory's Created and the module's events decode with the CLI's ABIs
const [factoryAbi, comboAbi] = COMBO_EVENT_ABIS
const created = {
  topics: encodeEventTopics({ abi: factoryAbi, eventName: 'Created', args: { dev: ME, module: M } }),
  data: encodeAbiParameters([{ type: 'uint16' }, { type: 'uint16' }, { type: 'address[]' }, { type: 'uint16[]' }], [3000, 3000, [ME, A], [7000, 3000]]),
}
const c = decodeEventLog({ abi: factoryAbi, ...created }).args
assert.deepEqual([c.buybackBps, c.lpBps, c.payees, c.shares], [3000, 3000, [ME_C, A], [7000, 3000]])
const u = (n) => Array.from({ length: n }, () => ({ type: 'uint256' }))
const split = { topics: encodeEventTopics({ abi: comboAbi, eventName: 'Split' }), data: encodeAbiParameters(u(4), [10n, 3n, 3n, 4n]) }
assert.deepEqual(decodeEventLog({ abi: comboAbi, ...split }).args, { incoming: 10n, toBuyback: 3n, toLp: 3n, toPayees: 4n })
const dist = { topics: encodeEventTopics({ abi: comboAbi, eventName: 'Distributed', args: { asset: STRAY } }), data: encodeAbiParameters(u(2), [10n, 6n]) }
assert.deepEqual(decodeEventLog({ abi: comboAbi, ...dist }).args, { asset: getAddress(STRAY), incoming: 10n, toDead: 6n })
const bb = { topics: encodeEventTopics({ abi: comboAbi, eventName: 'BoughtBack' }), data: encodeAbiParameters(u(3), [1n, 2n, 3n]) }
assert.deepEqual(decodeEventLog({ abi: comboAbi, ...bb }).args, { quoteIn: 1n, burned: 2n, left: 3n })
const pc = { topics: encodeEventTopics({ abi: comboAbi, eventName: 'PayeeChanged', args: { index: 1n, oldPayee: A, newPayee: B } }), data: '0x' }
assert.deepEqual(decodeEventLog({ abi: comboAbi, ...pc }).args, { index: 1n, oldPayee: A, newPayee: B })

// ---- a combined launch takes only the quotes the keeper serves, as the single modules
const GANG = '0x0c6302401aa5325c2e36f170f52c00b1d220b405'
const REG = t(0x4e9), LISTED = t(0x1157), Q = t(0xcc)
const fakeRead = ({ registry = REG } = {}) => async (_address, _abi, fn, args) => {
  if (fn === 'quoteRegistry') return registry
  if (fn === 'isQuoted') return args[0].toLowerCase() === LISTED.toLowerCase()
  throw new Error(`unexpected ${fn}`)
}
const net56 = { chainId: '56', pad: t(0x9ad), wbnb: WBNB }
const net97 = { chainId: '97', pad: t(0x9ad), wbnb: WBNB }
assert.equal(await untrustedBuybackQuote(fakeRead(), net56, GANG, 'combo'), null)
assert.equal(await untrustedBuybackQuote(fakeRead(), net97, LISTED, 'combo'), null)
const unlisted = await untrustedBuybackQuote(fakeRead(), net97, Q, 'combo')
assert.match(unlisted.error, /^a combined recipient \(more than one of --buyback \/ --lp \/ --split\) needs WBNB, GANG or a quote listed/)
assert.match(unlisted.hint, /launch without --buyback \/ --lp \/ --split/)

// ---- flags refused before any RPC (--from: no Agentic Wallet needed)
const cli = new URL('../src/index.js', import.meta.url).pathname
const gang = (...args) => {
  const r = spawnSync(process.execPath, [cli, ...args], { encoding: 'utf8', env: { ...process.env, GANG_UPDATE_CHECK: '0', GANG_COMBO_FACTORY: '', GANG_TESTNET_COMBO_FACTORY: '' } })
  try { return JSON.parse(r.stdout) } catch { return { raw: r.stdout + r.stderr } }
}
const refused = (args, re) => {
  const r = gang(...args)
  assert.equal(r.success, false, args.join(' '))
  assert.match(r.error, re, args.join(' '))
  return r
}
const base = ['create', '--name', 'C', '--symbol', 'C', '--from', ME, '--testnet']
const taxed = [...base, '--buy-tax', '2', '--sell-tax', '2']
// mainnet: not deployed yet, refused first (before the wallet or any RPC)
const main = ['create', '--name', 'C', '--symbol', 'C', '--from', ME, '--buy-tax', '2', '--sell-tax', '2']
const mn = refused([...main, '--buyback', '30', '--lp', '30', '--split', `self:70,${A}:30`], /^the combined recipient .* is not on BSC mainnet yet: give one of --buyback \/ --lp \/ --split alone, or try it with --testnet/)
assert.deepEqual(mn.flags, ['--buyback', '--split', '--lp'])
refused([...main, '--buyback', '30', '--lp', '30'], /not on BSC mainnet yet/)
refused([...main, '--lp', '30', '--split', `${A}:100`], /not on BSC mainnet yet/)
refused([...base, '--buyback', '30', '--lp', '30'], /--buyback \+ --lp needs a taxed token/)
refused([...base, '--buy-tax', '0', '--sell-tax', '0', '--buyback', '30', '--split', `${A}:100`], /--buyback \+ --split needs a taxed token/)
refused([...taxed, '--buyback', '30', '--lp', '30', '--buyback-to', A], /--buyback-to does not apply to a combined recipient .*--split self:<pct>,<addr>:<pct>/)
refused([...taxed, '--buyback', '30', '--lp', '30', '--lp-to', A], /--lp-to does not apply to a combined recipient/)
refused([...taxed, '--buyback', '30', '--lp', '30', '--recipient', A], /makes the recipient your combined recipient: leave --recipient out/)
refused([...taxed, '--buyback', '30', '--lp', '30', '--dividend', '100'], /--dividend 100 leaves nothing for the recipient/)
refused([...taxed, '--buyback', '60', '--lp', '50'], /110%, more than 100%/)
refused([...taxed, '--buyback', '50', '--lp', '50', '--split', `${A}:100`], /--split is refused/)
refused([...taxed, '--buyback', '0', '--split', `${A}:100`], /give --split alone/)
refused([...taxed, '--buyback', '30', '--lp', '30', '--split', `${A}:60,${B}:30`], /add up to 90%/)
refused([...taxed, '--buyback', '30', '--lp', '101'], /--lp must be a number between 0 and 100/)
refused([...taxed, '--buyback', 'x', '--lp', '30'], /--buyback must be a number between 0 and 100/)
refused(['create', '--fair', '--name', 'C', '--symbol', 'C', '--from', ME, '--buyback', '30', '--lp', '30'], /is for V3 tokens/)
refused(['create', '--fly', '--name', 'C', '--symbol', 'C', '--buyback', '30', '--lp', '30'], /combined recipient/)
refused(['combo', 'nope'], /usage: gang combo <status\|distribute\|release\|set-payee\|bind\|chunk>/)
refused(['combo'], /usage: gang combo/)
refused(['combo', 'status', '--token', 'nope', '--testnet'], /--token must be a V3 token address/)
refused(['combo', 'status', '--token', A, '--module', B, '--testnet'], /not both/)
refused(['combo', 'bind', '--module', B, '--testnet'], /needs --token/)

// the help lists the commands and the flags
const help = spawnSync(process.execPath, [cli, 'help'], { encoding: 'utf8', env: { ...process.env, GANG_UPDATE_CHECK: '0' } }).stdout
for (const x of ['--buyback <0-100> --lp <0-100> [--split', 'combined recipient', 'PERMANENT: the ratios', 'gang combo status', 'gang combo distribute',
  'gang combo release', 'gang combo set-payee', 'gang combo bind', 'gang combo chunk', 'GANG_COMBO_FACTORY', 'BSC testnet only for now']) {
  assert.ok(help.includes(x), `help mentions ${x}`)
}

console.log('combo: ok')
