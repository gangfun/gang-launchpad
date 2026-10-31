/**
 * Split module (split-v1) without a chain: --split parsing and every check GangSplitModule.initialize makes, the status
 * shape (formatSplit) for a keeper-served, a manual and an unbound module, and the launch / command flags refused before
 * any RPC (index.js, launch.js). The on-chain steps are covered by the testnet run in the CLI's release notes.
 *
 *   node skill/gang-cli/test/split.mjs
 */
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { getAddress } from 'viem'
import { parseSplitSpec, formatSplit, splitLine, SPLIT_TYPE, HINTS } from '../src/split.js'
import { untrustedBuybackQuote } from '../src/launch.js'

const ME = '0x00000000000000000000000000000000000000aa'
const ME_C = getAddress(ME)
const A = '0x1111111111111111111111111111111111111111'
const B = '0x2222222222222222222222222222222222222222'
const t = (n) => `0x${String(n).padStart(40, '0')}`

// ---- parsing: me / self, order kept, % with up to 2 decimals → bps
const ok = parseSplitSpec(`self:60,${A}:30,${B}:10`, ME)
assert.equal(ok.error, undefined)
assert.deepEqual(ok.shares, [6000, 3000, 1000])
assert.deepEqual(ok.payees, [ME_C, A, B])
assert.deepEqual(ok.list[0], { index: 0, payee: ME_C, pct: 60, you: true })
assert.equal(ok.list[1].you, undefined)
assert.deepEqual(parseSplitSpec(` ${A} : 33.33 , SELF:66.67 `, ME).shares, [3333, 6667])
assert.deepEqual(parseSplitSpec(`me:50,${A}:50`, ME).payees, [ME_C, A]) // me: an alias of self
assert.deepEqual(parseSplitSpec(`${A}:99.99,${B}:0.01`, ME).shares, [9999, 1])
assert.deepEqual(parseSplitSpec(`${A}:100`, ME).payees, [A])
// all-lowercase is accepted and checksummed; your own address written out counts as you
const low = parseSplitSpec(`${ME}:50,${A}:50`, ME_C)
assert.equal(low.list[0].you, true)
// ten payees is the most
const ten = Array.from({ length: 10 }, (_, i) => `${t(i + 1)}:10`).join(',')
assert.equal(parseSplitSpec(ten, ME).payees.length, 10)

const bad = (raw, re, me = ME) => {
  const r = parseSplitSpec(raw, me)
  assert.ok(r.error, `refused: ${raw}`)
  assert.match(r.error, re, raw)
}
bad(undefined, /takes <addr>:<pct>/)
bad('--dev-buy', /takes <addr>:<pct>/) // the next flag, not a value
bad(`${A}:50,,${B}:50`, /empty entry/)
bad(`${Array.from({ length: 11 }, (_, i) => `${t(i + 1)}:9`).join(',')}`, /at most 10 payees/)
bad(`${A}`, /not <addr>:<pct>/)
bad(`0x123:100`, /not a 0x address/)
bad(`0x1111111111111111111111111111111111111111:50,0xAbCdEf0000000000000000000000000000000000:50`, /not a 0x address/) // bad checksum
bad(`${t(0)}:100`, /zero address/)
bad(`${A}:33.333,${B}:66.667`, /at most 2 decimals/)
bad(`${A}:abc`, /at most 2 decimals/)
bad(`${A}:-10,${B}:110`, /at most 2 decimals/)
bad(`${A}:0,${B}:100`, /0% share/)
bad(`${A}:0.00,${B}:100`, /0% share/)
bad(`${A}:150`, /more than 100%/)
bad(`${A}:60,${B}:30`, /add up to 90%, not 100%/)
bad(`${A}:60,${B}:50`, /add up to 110%/)
bad(`${A}:50,${A.toLowerCase()}:50`, /appears twice/)
bad(`self:50,${ME}:50`, /appears twice/) // self is your wallet
bad(`self:100`, /needs your wallet address/, null)

assert.equal(splitLine([A, B], [6000, 4000]), `${A}: 60%, ${B}: 40%`)

// ---- status shape
const WBNB = t(0xbb), Q = t(0xcc), G = t(0x99), M = t(0x5), T = t(0x7)
const raw = (extra = {}) => ({
  module: M, dev: ME, token: T, quote: WBNB, payees: [ME, A, B], shares: [6000n, 3000n, 1000n].map(Number),
  lastDistributedAt: 1_800_000_000n, keeperServesQuote: true, due: true,
  assets: [
    { asset: WBNB, symbol: 'WBNB', decimals: 18, undistributed: 10n ** 18n, owedTotal: 0n, owed: null },
    { asset: G, symbol: 'GANG', decimals: 18, undistributed: 0n, owedTotal: 0n, owed: null },
  ],
  ...extra,
})
const ref = `--token ${T} --testnet`
const s = formatSplit(raw(), ref)
assert.equal(s.moduleType, SPLIT_TYPE)
assert.equal(s.distribution, 'keeper')
assert.deepEqual(s.payees.map((p) => [p.index, p.pct, p.bps, !!p.isDev]), [[0, 60, 6000, true], [1, 30, 3000, false], [2, 10, 1000, false]])
assert.deepEqual(s.keeper, { servesQuote: true, due: true, lastDistributedAt: new Date(1_800_000_000_000).toISOString() })
// GANG with nothing in it is left out; the bound quote stays even at 0
assert.deepEqual(s.assets.map((a) => [a.symbol, a.boundQuote ?? false, a.undistributed]), [['WBNB', true, '1']])
assert.match(s.assets[0].splitBy, /^keeper/)
assert.equal(s.next, undefined) // the keeper splits the quote: nothing to do by hand
assert.match(s.note, /fixed for good/)
assert.match(s.note, /The keeper splits the bound quote \(WBNB\)/)

// a quote the keeper does not serve: manual, with the command; an owed slot: its release command
const manual = formatSplit(raw({
  quote: Q, keeperServesQuote: false, due: false, lastDistributedAt: 0n,
  assets: [
    { asset: Q, symbol: 'XQ', decimals: 18, undistributed: 5n * 10n ** 17n, owedTotal: 2n * 10n ** 17n, owed: [0n, 2n * 10n ** 17n, 0n] },
    { asset: WBNB, symbol: 'WBNB', decimals: 18, undistributed: 3n * 10n ** 15n, owedTotal: 0n, owed: null },
  ],
}), ref)
assert.equal(manual.distribution, 'manual')
assert.equal(manual.keeper.lastDistributedAt, null)
assert.match(manual.note, /The keeper does not serve this quote \(XQ\): distribution is manual/)
assert.deepEqual(manual.assets[0].owed, [{ index: 1, payee: A, amount: '0.2' }])
assert.match(manual.assets[0].splitBy, /^hand/)
assert.deepEqual(manual.next, [
  `gang split distribute ${ref} --asset ${Q}`,
  `gang split release ${ref} --asset ${Q} --index 1`,
  `gang split distribute ${ref} --asset ${WBNB}`,
])
// 6-decimal asset formatted in its own units
const six = formatSplit(raw({ assets: [{ asset: WBNB, symbol: 'WBNB', decimals: 18, undistributed: 0n, owedTotal: 0n, owed: null }, { asset: Q, symbol: 'USD6', decimals: 6, undistributed: 1_500_000n, owedTotal: 0n, owed: null }] }), ref)
assert.equal(six.assets[1].undistributed, '1.5')

// unbound: no token / quote, the keeper serves nothing
const unbound = formatSplit(raw({ token: t(0), quote: t(0), keeperServesQuote: false, due: false }), `--module ${M}`)
assert.deepEqual([unbound.token, unbound.quote, unbound.distribution, unbound.keeper.servesQuote], [null, null, 'unbound', null])
assert.match(unbound.note, /Not bound to a token yet/)
assert.deepEqual(unbound.next, [`gang split distribute --module ${M} --asset ${WBNB}`])

assert.match(HINTS.PushStarved, /gas limit was too low/)
assert.match(HINTS.NotFactory, /not allowed on the platform's GangHandlerAdmin/)

// ---- --split takes only the quotes the keeper splits (spec §2.4), the same check as --buyback
const GANG = '0x0c6302401aa5325c2e36f170f52c00b1d220b405'
const REG = t(0x4e9)
const LISTED = t(0x1157)
const fakeRead = ({ registry = REG, fails = false } = {}) => async (address, _abi, fn, args) => {
  if (fails) throw new Error('rpc down')
  if (fn === 'quoteRegistry') return registry
  if (fn === 'isQuoted') return args[0].toLowerCase() === LISTED.toLowerCase()
  throw new Error(`unexpected ${fn}`)
}
const net56 = { chainId: '56', pad: t(0x9ad), wbnb: WBNB }
const net97 = { chainId: '97', pad: t(0x9ad), wbnb: WBNB }
assert.equal(await untrustedBuybackQuote(fakeRead(), net56, WBNB, 'split'), null)
assert.equal(await untrustedBuybackQuote(fakeRead(), net56, GANG, 'split'), null)
assert.equal(await untrustedBuybackQuote(fakeRead(), net97, LISTED, 'split'), null)
const unlisted = await untrustedBuybackQuote(fakeRead(), net97, Q, 'split')
assert.match(unlisted.error, /^--split needs WBNB, GANG or a quote listed in the pad's QuoteRegistry/)
assert.match(unlisted.hint, /launch without --split/)
assert.equal(unlisted.quote, Q)
// GANG counts only on mainnet; no registry: refused; an unreadable registry: refused, try again
assert.ok(await untrustedBuybackQuote(fakeRead(), net97, GANG, 'split'))
assert.match((await untrustedBuybackQuote(fakeRead({ registry: t(0) }), net97, LISTED, 'split')).error, /--split needs/)
assert.match((await untrustedBuybackQuote(fakeRead({ fails: true }), net97, Q, 'split')).error, /could not read the pad's QuoteRegistry to check the --split quote/)
// --buyback keeps its own message
assert.match((await untrustedBuybackQuote(fakeRead(), net97, Q)).error, /^--buyback needs/)

// ---- flags refused before any RPC (--from: no Agentic Wallet needed)
const cli = new URL('../src/index.js', import.meta.url).pathname
const gang = (...args) => {
  const r = spawnSync(process.execPath, [cli, ...args], { encoding: 'utf8', env: { ...process.env, GANG_UPDATE_CHECK: '0' } })
  try { return JSON.parse(r.stdout) } catch { return { raw: r.stdout + r.stderr } }
}
const refused = (args, re) => {
  const r = gang(...args)
  assert.equal(r.success, false, args.join(' '))
  assert.match(r.error, re, args.join(' '))
}
const base = ['create', '--name', 'S', '--symbol', 'S', '--from', ME, '--testnet']
const taxed = [...base, '--buy-tax', '2', '--sell-tax', '2']
refused([...base, '--split', `${A}:100`], /--split needs a taxed token/)
// with --buyback / --lp it is a combined recipient (test/combo.mjs): at 100% buy-back + LP no payees are left
refused([...taxed, '--split', `${A}:100`, '--buyback', '50', '--lp', '50'], /--split is refused/)
refused([...taxed, '--split', `${A}:100`, '--recipient', A], /leave --recipient out/)
refused([...taxed, '--split', `${A}:100`, '--dividend', '100'], /nothing to split/)
refused([...taxed, '--split', `${A}:60,${B}:30`], /add up to 90%/)
refused([...taxed, '--split', `me:50,${ME}:50`], /appears twice/)
refused(['create', '--fair', '--name', 'S', '--symbol', 'S', '--from', ME, '--split', `${A}:100`], /--split is for V3 tokens/)
refused(['create', '--fly', '--name', 'S', '--symbol', 'S', '--split', `${A}:100`], /split module/)
refused(['split', 'nope'], /usage: gang split/)
refused(['split', 'status', '--token', 'nope', '--testnet'], /--token must be a V3 token address/)
refused(['split', 'status', '--token', A, '--module', B, '--testnet'], /not both/)
refused(['split', 'bind', '--module', B, '--testnet'], /needs --token/)

console.log('split: ok')
