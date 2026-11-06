/**
 * The examples' pure parts, and each one against a stand-in `gang` so no network or wallet is involved.
 *
 *   node skill/gang-cli/test/examples.mjs
 */
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { chmodSync, mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { clean, messageOf } from '../examples/watch-telegram/watch.mjs'
import { balanceOf, findingsOf, holdersOf, taxOf } from '../examples/risk-check/risk-check.mjs'

const T = `0x${'a'.repeat(40)}`, PAD = `0x${'b'.repeat(40)}`, PAIR = `0x${'c'.repeat(40)}`, W = `0x${'d'.repeat(40)}`

// watch: control characters out, length capped, plain messages, and nothing for events not meant for people
assert.equal(clean('a\u0000b‮c\nd'), 'a b c d')
assert.equal(clean('x'.repeat(100)).length, 40)
assert.equal(clean(''), '?')
assert.equal(clean('a\u2028b\u2029c'), 'a b c')
assert.equal(clean(`${'x'.repeat(39)}😀😀`), `${'x'.repeat(39)}😀`, 'a cut never splits an emoji')
assert.equal(messageOf({ event: 'new_token', address: T, symbol: 'AB', name: 'Alpha' }), `New token: AB (Alpha)\nhttps://gang.fun/token/${T}`)
assert.equal(messageOf({ event: 'near_grad', token: T, symbol: 'AB', progressPct: 81.25 }), `Near graduation: AB, 81.3%\nhttps://gang.fun/token/${T}`)
assert.equal(messageOf({ event: 'graduated', token: T, symbol: 'AB' }), `Graduated: AB\nhttps://gang.fun/token/${T}`)
assert.equal(messageOf({ event: 'watching', mode: 'market' }), null)
assert.equal(messageOf({ event: 'new_token', address: 'https://evil.example', symbol: 'AB' }), null, 'only a real address makes a link')

// risk check: the pad, the pair and burned tokens are not holders, and shares come from balances
const row = (holder, balance) => ({ holder, balance: String(balance), pct: 0 })
const items = [row(PAD, 8_300_000), row(PAIR, 100), row('0x000000000000000000000000000000000000dEaD', 50), row(W, 300), row(`0x${'e'.repeat(40)}`, 100)]
const held = holdersOf({ items, source: 'transfers', complete: true }, { pad: PAD, pair: PAIR, token: T })
assert.deepEqual(held.wallets.map((h) => h.holder), [W, `0x${'e'.repeat(40)}`])
assert.equal(held.total, 400)
assert.equal(holdersOf({ items: [], source: 'transfers', complete: true }, {}), null, 'an empty list is not 0% concentration')
assert.equal(holdersOf({ items, source: 'curve_trades', complete: true }, {}), null, 'a partial source is unknown')
assert.equal(holdersOf({ items, source: 'transfers', provider: 'someone', complete: true }, {}), null, "a third party's top 10 is not the whole list")
assert.equal(holdersOf({ items: [row(PAD, 5), row(W, 5)], source: 'transfers', complete: true }, { pad: 'v2', padAddress: PAD }).wallets.length, 1, 'V2 / Soft: pad is a name, padAddress the address')

// each kind's real field names
assert.deepEqual(taxOf({ buyTaxPct: 4, sellTaxPct: 3 }), { buy: 4, sell: 3 })
assert.deepEqual(taxOf({ tax: { buyPct: 1, sellPct: 2 } }), { buy: 1, sell: 2 })
assert.equal(balanceOf({ balance: '5' }), 5)
assert.equal(balanceOf({ myBalance: '24,599,758.29', myBalanceRaw: '6000000000000000000' }), 6, 'the formatted one has commas')
assert.equal(balanceOf({ balance: 'not a number' }), null)
assert.equal(balanceOf({ position: { balance: '7' } }), 7)
assert.equal(balanceOf({ position: { shares: 200, baselineTokens: '10000000' } }), 10000000)
assert.equal(balanceOf(null), null)

const findings = (o) => findingsOf({ info: {}, holders: held, creatorBalance: 0, record: { launch: { count: 3, graduated: 1 } }, ...o })
const levels = (o) => Object.fromEntries(findings(o).map((f) => [f.check, f.level]))
assert.equal(levels({ info: { buyTaxPct: 5 } }).tax, 'warn', 'the top of the range can fire')
assert.equal(levels({ info: { buyTaxPct: 4, sellTaxPct: 4 } }).tax, 'info')
assert.equal(levels({ info: { tax: { buyPct: 1, sellPct: 2 } } }).tax, 'info')
assert.equal(levels({ info: { buyTaxPct: 0, sellTaxPct: 0 } }).tax, undefined, 'untaxed says nothing')
assert.equal(levels({}).holders, 'warn')
assert.equal(levels({})['largest-holder'], 'warn')
const spread = { wallets: Array.from({ length: 100 }, (_, i) => ({ holder: W + i, balance: 1 })), total: 100, complete: true }
assert.equal(levels({ holders: spread }).holders, 'info')
assert.equal(levels({ holders: spread })['largest-holder'], undefined)
assert.match(findings({ holders: { ...held, complete: false } }).find((f) => f.check === 'holders').detail, /largest holders only/)
assert.equal(levels({ holders: null }).holders, 'unknown')
assert.match(findings({ holders: null, creatorBalance: 500_000_000 }).find((f) => f.check === 'creator-holding').detail, /500,000,000 tokens/, 'a known balance is said even without a holder list')
assert.equal(levels({ creatorBalance: 300 })['creator-holding'], 'warn')
assert.equal(levels({ creatorBalance: null })['creator-holding'], 'unknown')
assert.equal(levels({ record: { launch: { count: 9, graduated: 0 } } })['creator-history'], 'warn')
assert.equal(levels({ record: null })['creator-history'], 'unknown')
assert.match(findings({ record: undefined }).find((f) => f.check === 'creator-history').detail, /couldn't read/, 'a failed read is not the same as no record')
// no tax figure is not the same as no tax
assert.deepEqual(taxOf({}), { buy: null, sell: null })
assert.equal(levels({ info: { kind: 'v2', taxed: true } }).tax, 'unknown')
assert.equal(levels({ info: { kind: 'fair' } }).tax, 'unknown')
assert.equal(levels({ info: { kind: 'soft' } }).tax, undefined)
assert.equal(levels({ info: { kind: 'v2', taxed: false } }).tax, undefined)
assert.equal(levels({ info: { kind: 'v3', buyTaxPct: 0, sellTaxPct: 0 } }).tax, undefined)
assert.equal(findingsOf({ info: { buyTaxPct: 5 }, holders: null, creatorBalance: null, record: null })[0].level, 'warn', 'worst first')

// the programs, with a stand-in gang
const dir = mkdtempSync(join(tmpdir(), 'gang-examples-'))
const fake = join(dir, 'gang')
writeFileSync(fake, `#!/bin/sh
case "$1" in
  watch)
    case "$*" in
      *nonsense*) echo '{"event":"error","fatal":true,"error":"--events: unknown","code":"USAGE"}'; exit 1 ;;
    esac
    echo '{"event":"watching","mode":"market"}'; echo 'not json'; echo '{"event":"graduated","token":"${T}","symbol":"AB"}' ;;
  info) echo '{"success":false,"error":"not a Gang token","code":"ERROR"}'; exit 1 ;;
esac
`)
chmodSync(fake, 0o755)
const example = (name, ...args) => spawnSync(process.execPath, [fileURLToPath(new URL(`../examples/${name}`, import.meta.url)), ...args],
  { encoding: 'utf8', env: { ...process.env, GANG_BIN: fake, TELEGRAM_BOT_TOKEN: '', TELEGRAM_CHAT_ID: '' } })

const watched = example('watch-telegram/watch.mjs', '--dry', '--max-events', '1')
assert.equal(watched.status, 0)
assert.equal(watched.stdout.trim(), `Graduated: AB\nhttps://gang.fun/token/${T}`)
assert.equal(example('watch-telegram/watch.mjs').status, 2, 'no bot token, no --dry: says what to set')
assert.equal(example('watch-telegram/watch.mjs', '--dry', '--events', 'nonsense').status, 1, 'a bad flag stops it: no restart loop')

const failed = example('risk-check/risk-check.mjs', T)
assert.equal(failed.status, 1)
assert.deepEqual(JSON.parse(failed.stdout), { success: false, error: 'not a Gang token' })
assert.equal(example('risk-check/risk-check.mjs', 'nonsense').status, 2)
console.log('examples: ok')
