/**
 * LP splitter (GangLiquiditySplitter, lp-burn-v1) without a chain: --lp parsing, the status shape (formatLp) for a
 * ready, an unbound, a not-graduated, a too-soon and a price-waiting splitter, the quote check --lp shares with --buyback
 * / --split, and the launch / command flags refused before any RPC (index.js, launch.js). The on-chain steps are
 * covered by the testnet run in the CLI's release notes.
 *
 *   node skill/gang-cli/test/lp.mjs
 */
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { lpBpsOf, formatLp, lpFactoryAddress, HINTS, LP_TYPE, LP_EVENT_ABIS, TESTNET_LP_FACTORY, MAINNET_LP_FACTORY } from '../src/lp.js'
import { untrustedBuybackQuote } from '../src/launch.js'
import { decodeEventLog, encodeAbiParameters, encodeEventTopics } from 'viem'

const ME = '0x00000000000000000000000000000000000000aa'
const A = '0x1111111111111111111111111111111111111111'
const t = (n) => `0x${String(n).padStart(40, '0')}`
const E18 = 10n ** 18n

// ---- --lp <pct> → bps (0–100, up to 2 decimals as bps)
const thrower = (msg) => { throw new Error(msg) }
assert.equal(lpBpsOf(thrower, '70'), 7000)
assert.equal(lpBpsOf(thrower, '0'), 0)
assert.equal(lpBpsOf(thrower, '100'), 10000)
assert.equal(lpBpsOf(thrower, '33.33'), 3333)
assert.throws(() => lpBpsOf(thrower, '101'), /--lp must be a number between 0 and 100/)
assert.throws(() => lpBpsOf(thrower, '-1'), /--lp must be/)
assert.throws(() => lpBpsOf(thrower, '--dev-buy'), /--lp must be/) // the next flag, not a value
assert.throws(() => lpBpsOf(thrower, undefined), /--lp must be/)
assert.throws(() => lpBpsOf(thrower, 'abc', 'pct'), /--pct must be/)

// ---- factory addresses: built in, env overrides
assert.equal(lpFactoryAddress(true), TESTNET_LP_FACTORY)
assert.equal(lpFactoryAddress(false), MAINNET_LP_FACTORY)
process.env.GANG_TESTNET_LP_FACTORY = A
assert.equal(lpFactoryAddress(true), A)
delete process.env.GANG_TESTNET_LP_FACTORY

// ---- status shape
const WBNB = t(0xbb), S = t(0x5), T = t(0x7)
const NOW = 1_800_000_000
const raw = (extra = {}) => ({
  splitter: S, dev: ME, payee: ME, token: T, quote: WBNB, quoteSymbol: 'WBNB', bps: 7000, cut: [false, 0, 0n],
  left: 5n * E18 / 10n, unsplit: 0n, owed: 0n, lastAddAt: BigInt(NOW - 600),
  preview: [true, 2n * E18 / 10n, 123_456n * E18], work: [true, 1n], graduated: true, now: NOW,
  ...extra,
})
const s = formatLp(raw())
assert.equal(s.moduleType, LP_TYPE)
assert.deepEqual([s.lpPct, s.lpBps, s.lpLeft, s.unsplit, s.devOwed, s.quoteSymbol], [70, 7000, '0.5', '0', '0', 'WBNB'])
assert.deepEqual(s.nextChunk, { quoteChunk: '0.2', buyHalf: '0.1', tokensBought: '123456' })
assert.equal(s.nextChunkWaitsFor, undefined)
assert.equal(s.pendingCut, null)
assert.equal(s.lastAddAt, new Date((NOW - 600) * 1000).toISOString())
assert.deepEqual(s.keeper, { due: true })
assert.match(s.note, /^70% of each tax payment .* LP goes to 0xdead .* the rest goes to the dev\./)
assert.match(s.note, /gang lp set-payee/)

// another payee, a cut asked for, owed: shown as they are
const other = formatLp(raw({ payee: A, cut: [true, 5000, BigInt(NOW + 3 * 86400)], owed: 25n * E18 / 100n }))
assert.match(other.note, new RegExp(`the rest goes to the payee ${A}`))
assert.deepEqual(other.pendingCut, {
  toPct: 50, appliesFrom: new Date((NOW + 3 * 86400) * 1000).toISOString(), lapsesAfter: new Date((NOW + 10 * 86400) * 1000).toISOString(),
})
assert.equal(other.devOwed, '0.25')

// what the next chunk waits for, most basic first
const waits = (extra) => formatLp(raw({ preview: [false, 0n, 0n], work: [false, 0n], ...extra })).nextChunkWaitsFor
const unbound = formatLp(raw({ token: t(0), quote: t(0), preview: null, work: null, graduated: null, left: 0n }))
assert.deepEqual([unbound.token, unbound.quote, unbound.nextChunk, unbound.keeper, unbound.quoteSymbol], [null, null, null, undefined, undefined])
assert.match(unbound.nextChunkWaitsFor, /not bound to a token yet/)
assert.match(waits({ graduated: false, left: 0n }), /has not graduated/)
assert.match(waits({ left: 0n }), /nothing set aside/)
// quote waiting to be split counts as set aside (its LP share)
assert.match(waits({ left: 0n, unsplit: E18, lastAddAt: BigInt(NOW - 60) }), /one chunk per 4 minutes: the next from/)
assert.equal(waits({ lastAddAt: BigInt(NOW - 60) }), `one chunk per 4 minutes: the next from ${new Date((NOW + 180) * 1000).toISOString()}`)
assert.match(waits({ lastAddAt: 0n }), /the price check: a 10-minute average/)
assert.match(waits({}), /the price check/)
assert.equal(formatLp(raw({ lastAddAt: 0n })).lastAddAt, null)

assert.match(HINTS.NotFactory, /not allowed on the platform's GangHandlerAdmin/)
assert.match(HINTS.NotFactory, /unset it to use the built-in factory/)
assert.match(HINTS.AddTooSoon, /4 minutes/)

// ---- gang tx: the splitter's LiquidityAdded and Split decode with the CLI's ABIs
const [factoryAbi, lpAbi] = LP_EVENT_ABIS
const added = {
  topics: encodeEventTopics({ abi: lpAbi, eventName: 'LiquidityAdded' }),
  data: encodeAbiParameters([{ type: 'uint256' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'uint256' }], [1n, 2n, 3n, 4n]),
}
assert.deepEqual(decodeEventLog({ abi: lpAbi, ...added }).args, { quoteIn: 1n, tokensIn: 2n, liquidity: 3n, left: 4n })
const created = { topics: encodeEventTopics({ abi: factoryAbi, eventName: 'Created', args: { dev: ME, splitter: S } }), data: encodeAbiParameters([{ type: 'uint16' }, { type: 'address' }], [7000, A]) }
assert.equal(decodeEventLog({ abi: factoryAbi, ...created }).args.lpBps, 7000)

// ---- --lp takes only the quotes the keeper serves, the same check as --buyback / --split
const GANG = '0x0c6302401aa5325c2e36f170f52c00b1d220b405'
const REG = t(0x4e9), LISTED = t(0x1157), Q = t(0xcc)
const fakeRead = ({ registry = REG, fails = false } = {}) => async (address, _abi, fn, args) => {
  if (fails) throw new Error('rpc down')
  if (fn === 'quoteRegistry') return registry
  if (fn === 'isQuoted') return args[0].toLowerCase() === LISTED.toLowerCase()
  throw new Error(`unexpected ${fn}`)
}
const net56 = { chainId: '56', pad: t(0x9ad), wbnb: WBNB }
const net97 = { chainId: '97', pad: t(0x9ad), wbnb: WBNB }
assert.equal(await untrustedBuybackQuote(fakeRead(), net56, WBNB, 'lp'), null)
assert.equal(await untrustedBuybackQuote(fakeRead(), net56, GANG, 'lp'), null)
assert.equal(await untrustedBuybackQuote(fakeRead(), net97, LISTED, 'lp'), null)
const unlisted = await untrustedBuybackQuote(fakeRead(), net97, Q, 'lp')
assert.match(unlisted.error, /^--lp needs WBNB, GANG or a quote listed in the pad's QuoteRegistry/)
assert.match(unlisted.hint, /launch without --lp/)
assert.ok(await untrustedBuybackQuote(fakeRead(), net97, GANG, 'lp')) // GANG counts only on mainnet
assert.match((await untrustedBuybackQuote(fakeRead({ registry: t(0) }), net97, LISTED, 'lp')).error, /--lp needs/)
assert.match((await untrustedBuybackQuote(fakeRead({ fails: true }), net97, Q, 'lp')).error, /check the --lp quote: try again/)

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
const base = ['create', '--name', 'L', '--symbol', 'L', '--from', ME, '--testnet']
const taxed = [...base, '--buy-tax', '2', '--sell-tax', '2']
refused([...base, '--lp', '50'], /--lp needs a taxed token/)
refused([...base, '--buy-tax', '0', '--sell-tax', '0', '--lp', '50'], /--lp needs a taxed token/)
// with --buyback / --split it is a combined recipient (test/combo.mjs), where --lp-to does not apply
refused([...taxed, '--lp', '50', '--buyback', '60'], /more than 100%/)
refused([...taxed, '--lp', '50', '--split', `${A}:100`, '--lp-to', A], /--lp-to does not apply to a combined recipient/)
refused([...taxed, '--lp', '50', '--recipient', A], /--lp makes the recipient your LP splitter: leave --recipient out/)
refused([...taxed, '--lp', '50', '--dividend', '100'], /nothing to add to the pool/)
refused([...taxed, '--lp', '101'], /--lp must be a number between 0 and 100/)
refused([...taxed, '--lp', '--dev-buy', '0.1'], /--lp must be a number/)
refused([...taxed, '--lp', '50', '--lp-to', '0x123'], /--lp-to must be a 0x address/)
refused([...taxed, '--lp', '50', '--lp-to', t(0)], /--lp-to must be a 0x address/)
refused([...taxed, '--buyback', '50', '--lp-to', A], /--lp-to <addr> goes with --lp <pct>/)
refused([...taxed, '--lp-to', A], /--lp-to only applies to a launch in one command/)
refused(['create', '--fair', '--name', 'L', '--symbol', 'L', '--from', ME, '--lp', '50'], /--lp is for V3 tokens/)
refused(['create', '--fly', '--name', 'L', '--symbol', 'L', '--lp', '50'], /LP splitter/)
refused(['lp', 'nope'], /usage: gang lp <status\|set\|set-payee\|apply\|bind\|release\|add>/)
refused(['lp'], /usage: gang lp/)
refused(['lp', 'status', '--token', 'nope', '--testnet'], /--token must be a V3 token address/)

// the help lists the commands and the flags
const help = spawnSync(process.execPath, [cli, 'help'], { encoding: 'utf8', env: { ...process.env, GANG_UPDATE_CHECK: '0' } }).stdout
for (const c of ['--lp <0-100> [--lp-to <addr>]', 'gang lp status', 'gang lp set ', 'gang lp set-payee', 'gang lp apply', 'gang lp add', 'GANG_LP_FACTORY']) {
  assert.ok(help.includes(c), `help mentions ${c}`)
}

console.log('lp: ok')
