/**
 * Floor module (GangFloorModule, floor-v1) without a chain: parsing a floor launch's --redeem-fee / --tax-cap /
 * --tax-cap-share / --split (every refusal GangFloorModule.initialize makes), the contract's split and redemption math
 * to the wei (figures from the BSC testnet acceptance), the % of pool volume that reaches the treasury, the status
 * shape (formatFloor) in each state — unverified, unbound, before graduation, live —, the warning for a token that pays
 * a module cloned for another one, the fixed-salt create (vanity.js), the creator-fee notes, the events gang tx
 * decodes, and the launch / command flags refused before any RPC.
 * The launch itself (clone → create at the planned address → bind), distribute and redeem ran on the BSC testnet:
 * docs/TESTNET-FLOOR-MODULE-2026-11-11.md.
 *
 *   node skill/gang-cli/test/floor.mjs
 */
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { decodeEventLog, encodeAbiParameters, encodeEventTopics, getAddress, zeroAddress } from 'viem'
import {
  FLOOR_ABI, FLOOR_EVENT_ABIS, FLOOR_FACTORY_ABI, FLOOR_NOTE, FLOOR_TYPE, floorFactoryAddress, floorLine, floorNotDeployed,
  formatFloor, HINTS, MAINNET_FLOOR_FACTORY, notItsFloor, parseFloorSpec, parseRedeemFee, partsOf, PERMANENT_NOTE, quoteFor,
  TESTNET_FLOOR_FACTORY, treasuryShare, UNVERIFIED_NOTE,
} from '../src/floor.js'
import { claimToModule, floorModuleOfAnother, notThroughModule, payOutCmd, unverifiedFloorNote } from '../src/creatorfee.js'
import { isLaunch, LAUNCH_FLAGS, untrustedBuybackQuote } from '../src/launch.js'
import { wantsPoolModule } from '../src/promote.js'
import { mineSalt, vanityAddress, vanityCreate } from '../src/vanity.js'
import { GANG_GENS, gangGens, PAD3_GEN } from '../src/gangpad.js'

const t = (n) => getAddress(`0x${n.toString(16).padStart(40, '0')}`)
const ME = t(0xaa), A = t(0xa1), B = t(0xb2), M = t(0x30d), T = t(0x70c), OTHER = t(0x0e), WBNB = t(0xb0b), USDC = t(0x5dc)
const E18 = 10n ** 18n

// ---- the factories: testnet only for now (mainnet waits for the pad's CREATE2 deployer)
assert.equal(FLOOR_TYPE, 'floor-v1')
assert.equal(MAINNET_FLOOR_FACTORY, null)
assert.equal(TESTNET_FLOOR_FACTORY, '0x0804C018201D8fFe378b873b41B67f136dbdc3F8')
assert.equal(GANG_GENS.testnet[0].gen, PAD3_GEN)
assert.equal(gangGens(true)[0].floorFactory, TESTNET_FLOOR_FACTORY)
assert.equal(gangGens(true)[1].floorFactory ?? null, null, 'only 3.0 has one')
assert.match(floorNotDeployed(false), /not on BSC mainnet yet \(it waits for the pad's CREATE2 deployer\)/)
assert.match(floorNotDeployed(true), /GANG_TESTNET_FLOOR_FACTORY/)

// ---- --redeem-fee: 0–5%, at most 2 decimals; left out 2%
assert.deepEqual(parseRedeemFee(undefined), { redeemFeeBps: 200 })
assert.deepEqual(parseRedeemFee('0'), { redeemFeeBps: 0 })
assert.deepEqual(parseRedeemFee('5'), { redeemFeeBps: 500 })
assert.deepEqual(parseRedeemFee('1.37'), { redeemFeeBps: 137 })
for (const bad of ['5.01', '6', '-1', 'two', '', '1.234', '--testnet']) assert.match(parseRedeemFee(bad).error, /--redeem-fee is the % of each redemption/, bad)

// ---- a floor launch's flags, as initialize checks them
assert.deepEqual(parseFloorSpec({}, ME), { payBps: 0, redeemFeeBps: 200, payees: [], shares: [], list: [], capped: false })
assert.deepEqual(parseFloorSpec({ redeemFee: '0' }, ME).redeemFeeBps, 0)
assert.match(parseFloorSpec({ capShare: '50' }, ME).error, /--tax-cap-share goes with --tax-cap <amount>: with --floor alone nobody takes a share/)
assert.match(parseFloorSpec({ split: `${A}:100` }, ME).error, /--split goes with --tax-cap <amount>: with --floor alone there are no payees/)
assert.match(parseFloorSpec({ redeemFee: '9' }, ME).error, /--redeem-fee/)
const solo = parseFloorSpec({ cap: true }, ME)
assert.deepEqual([solo.payBps, solo.payees, solo.shares, solo.capped], [10_000, [ME], [10_000], true])
assert.equal(solo.list[0].you, true)
const two = parseFloorSpec({ cap: true, capShare: '50', split: `self:70,${B}:30`, redeemFee: '1.5' }, ME)
assert.deepEqual([two.payBps, two.redeemFeeBps, two.payees, two.shares], [5_000, 150, [ME, B], [7_000, 3_000]])
assert.deepEqual(two.list.map((x) => [x.pctOfPayees, x.pctOfRecipientUntilCap]), [[70, 35], [30, 15]])
assert.match(parseFloorSpec({ cap: true, capShare: '0' }, ME).error, /--tax-cap-share is the payees' %/)
assert.match(parseFloorSpec({ cap: true, split: `${A}:60,${B}:30` }, ME).error, /add up to 90%/)
assert.match(parseFloorSpec({ cap: true, split: `${A}:60,${B}:30` }, ME).hint, /with --floor, --split lists the payees of the capped part/)
assert.match(parseFloorSpec({ cap: true }, null).error, /sign in with baw, or give --from/)

// ---- the contract's math, to the wei (the figures of the testnet acceptance)
assert.deepEqual(partsOf(7868026816606558n, 0n, 10n ** 15n, 5_000), { toPayees: 10n ** 15n, toTreasury: 6868026816606558n }) // crosses the cap
assert.deepEqual(partsOf(600000000000000n, 0n, 500000000000000n, 5_000), { toPayees: 300000000000000n, toTreasury: 300000000000000n })
assert.deepEqual(partsOf(400000000000000n, 300000000000000n, 500000000000000n, 5_000), { toPayees: 200000000000000n, toTreasury: 200000000000000n })
assert.deepEqual(partsOf(10n ** 18n, 5n, 5n, 5_000), { toPayees: 0n, toTreasury: 10n ** 18n }) // after the cap
assert.deepEqual(partsOf(999n, 0n, 0n, 0), { toPayees: 0n, toTreasury: 999n }) // no payees
assert.deepEqual(partsOf(3n, 0n, 100n, 5_000), { toPayees: 1n, toTreasury: 2n }) // rounds toward the treasury
assert.deepEqual(quoteFor(3365196336456469102010738n, 6868026816606558n, 10n ** 27n, 200), { quoteOut: 22650013508291n, fee: 462245173638n })
assert.deepEqual(quoteFor(5047794504684703653016107n, 6845376803098267n, 996634803663543530897989262n, 200), { quoteOut: 33977314635727n, fee: 693414584402n })
assert.deepEqual(quoteFor(10n, 100n, 1000n, 0), { quoteOut: 1n, fee: 0n })
assert.deepEqual(quoteFor(1n, 100n, 1000n, 200), { quoteOut: 0n, fee: 0n })
assert.deepEqual(quoteFor(5n, 100n, 0n, 200), { quoteOut: 0n, fee: 0n })

// ---- how much of the pool volume reaches the treasury
assert.deepEqual(treasuryShare({ buyTaxPct: 3, sellTaxPct: 3 }).afterCap, { pctOfVolume: 2.5 })
assert.equal(treasuryShare({ buyTaxPct: 3, sellTaxPct: 3 }).untilCap, undefined)
const ts = treasuryShare({ buyTaxPct: 3, sellTaxPct: 3, dividendPct: 40, payBps: 5_000 })
assert.deepEqual([ts.untilCap, ts.afterCap], [{ pctOfVolume: 0.75 }, { pctOfVolume: 1.5 }])
assert.match(ts.how, /\(tax − 0\.5% platform\) × \(1 − 40% dividend\) × \(1 − 50% to the payees, until the cap\)/)
assert.deepEqual(treasuryShare({ buyTaxPct: 2, sellTaxPct: 4 }).afterCap, { pctOfVolume: { buys: 1.5, sells: 3.5 } })
assert.deepEqual(treasuryShare({ buyTaxPct: 3, sellTaxPct: 3, payBps: 10_000 }).untilCap, { pctOfVolume: 0 })

// ---- one line for a launch
assert.equal(floorLine({ payBps: 0, redeemFeeBps: 200, payees: [], shares: [] }), 'all of it stays in the treasury that holders can redeem; a redemption leaves 2% of what it takes in the treasury')
assert.match(floorLine({ cap: '20', symbol: 'WBNB', payBps: 5_000, redeemFeeBps: 0, payees: [A, B], shares: [7_000, 3_000] }),
  /^until the payees have been credited 20 WBNB in all: 50% to .*: 70% of it, .*: 30% of it, the rest to the treasury\. From then on all of it stays in the treasury .*leaves 0% of what it takes/)
assert.match(floorLine({ cap: '1', payBps: 10_000, redeemFeeBps: 500, payees: [A], shares: [10_000] }), /in all: all of it to /)

// ---- the status shape
const raw = (over = {}) => ({
  module: M, verified: true, dev: ME, floorToken: T, token: T, quote: USDC, floorQuote: USDC, quoteSymbol: 'USDC', quoteDecimals: 6,
  capAmount: 20_000000n, paidTotal: 5_000000n, payBps: 5_000, redeemFeeBps: 200, payees: [ME, B], shares: [7_000, 3_000],
  treasuryHeld: 100_000000n, treasury: 100_000000n, payeesPending: 0n, floorSupply: 10n ** 9n * E18, floorPrice: 100_000000n * E18 / (10n ** 9n * E18),
  unsplit: 0n, lastPaidAt: 0n, keeperServesQuote: true, work: [false, 0n], graduated: true, tokenExists: true,
  assets: [{ asset: USDC, symbol: 'USDC', decimals: 6, undistributed: 0n, owedTotal: 0n, owed: null }], ...over,
})
const live = formatFloor(raw(), `--token ${T}`)
assert.deepEqual([live.moduleType, live.verified, live.state, live.treasury, live.floorSupply], ['floor-v1', true, 'live', '100', '1000000000'])
assert.deepEqual([live.floorPerToken, live.redeemPerTokenAfterFee, live.redeemFeePct], ['0.0000001', '0.000000098', 2]) // 6-decimal quote, per whole token
assert.deepEqual(live.cap, { amount: '20', paid: '5', left: '15', reached: false, progressPct: 25 })
assert.deepEqual(live.payees.map((p) => [p.index, p.pctOfPayees, p.pctOfRecipientUntilCap, !!p.isDev]), [[0, 70, 35, true], [1, 30, 15, false]])
assert.deepEqual(live.next, [`gang floor redeem --token ${T} --amount <tokens>`])
assert.equal(live.floor, FLOOR_NOTE)
assert.match(live.note, /^Each token redeems for 0\.0000001 USDC before the 2% fee\. 5 of the 20 USDC cap credited/)
assert.ok(live.note.includes(PERMANENT_NOTE))
assert.match(FLOOR_NOTE, /not\b.*a price promise.*starts at 0.*redeeming tokens bought above it is a loss/s)
// waiting quote, and what a redemption set aside: the next distribute pushes both
const waits = formatFloor(raw({ unsplit: 10_000000n, payeesPending: 2_000000n }), `--token ${T}`)
assert.deepEqual(waits.unsplitGoes, { toPayees: '5', toTreasury: '5' })
assert.equal(waits.payeesPending, '2')
assert.equal(waits.next[0], `gang floor distribute --token ${T} (pushes the payees' 7 USDC)`)
// the cap reached; a slot owed; another asset waiting (burned when distributed)
const full = formatFloor(raw({
  paidTotal: 20_000000n,
  assets: [{ asset: USDC, symbol: 'USDC', decimals: 6, undistributed: 0n, owedTotal: 3n, owed: [0n, 3n] }, { asset: WBNB, symbol: 'WBNB', decimals: 18, undistributed: E18, owedTotal: 0n, owed: null }],
}), `--token ${T}`)
assert.equal(full.cap.reached, true)
assert.match(full.note, /The cap is reached: the payees were credited 20 USDC in all, and every payment now stays in the treasury/)
assert.deepEqual(full.assets[0].owed, [{ index: 1, payee: B, amount: '0.000003' }])
assert.equal(full.assets[1].burns, true)
assert.ok(full.next.some((x) => x.startsWith(`gang floor distribute --token ${T} --asset ${WBNB} (BURNS all of it`)))
assert.ok(full.next.includes(`gang floor release --token ${T} --asset ${USDC} --index 1`))
// no payees
const pure = formatFloor(raw({ capAmount: 0n, paidTotal: 0n, payBps: 0, payees: [], shares: [], redeemFeeBps: 0 }), `--token ${T}`)
assert.deepEqual([pure.cap, pure.payPct, pure.payees, pure.redeemFeePct], [null, 0, [], 0])
assert.match(pure.note, /No payees: all of the recipient's part is the treasury/)
assert.equal(pure.redeemPerTokenAfterFee, pure.floorPerToken)
// before graduation, unbound (the token there or not), and a contract the factory did not make
assert.equal(formatFloor(raw({ graduated: false, treasury: 0n, floorPrice: 0n }), `--token ${T}`).state, 'before-graduation')
const unbound = formatFloor(raw({ token: zeroAddress, quote: zeroAddress, graduated: null }), `--module ${M} --testnet`)
assert.deepEqual([unbound.state, unbound.token, unbound.quote, unbound.floorToken], ['unbound', null, null, T])
assert.deepEqual(unbound.next, [`gang floor bind --token ${T} --testnet`])
assert.match(unbound.note, /^Not bound yet: the token it was cloned for exists, anyone can bind it/)
const waiting = formatFloor(raw({ token: zeroAddress, quote: zeroAddress, graduated: null, tokenExists: false }), `--module ${M}`)
assert.match(waiting.note, /the token it was cloned for does not exist\. Whatever reaches the module waits; it can never serve another token/)
assert.deepEqual(waiting.next, ['nothing yet: the token it was cloned for is not created'])
const fake = formatFloor(raw({ verified: false }), `--token ${T}`)
assert.deepEqual([fake.verified, fake.state, fake.next], [false, 'unverified', undefined], 'no command is offered against a contract the factory did not make')
assert.ok(fake.note.startsWith(UNVERIFIED_NOTE))

// ---- a token that pays a floor module cloned for another token has no floor
assert.equal(notItsFloor(live, T), null)
assert.equal(notItsFloor(live, T.toLowerCase()), null)
assert.match(notItsFloor(live, OTHER), /cloned for another token \(.*\): this token has NO floor and its holders can redeem nothing/)
assert.match(notItsFloor(unbound, OTHER), /which is not even bound yet \(the tax waits in the module\)/)

// ---- the create at a fixed salt: the same address, or a mismatch instead of a tx
const DEPLOYER = t(0xdeb), H1 = `0x${'11'.repeat(32)}`, H2 = `0x${'22'.repeat(32)}`
const mined = await mineSalt(DEPLOYER, ME, H1)
assert.ok(mined.token.endsWith('abcd'))
assert.equal(vanityAddress(DEPLOYER, ME, H1, mined.salt), mined.token)
assert.notEqual(vanityAddress(DEPLOYER, A, H1, mined.salt), mined.token, 'the creator is part of the salt')
assert.notEqual(vanityAddress(DEPLOYER, ME, H2, mined.salt), mined.token, 'the name, symbol, metadata and tax rates decide it')
const vctx = (hash) => ({ gen: PAD3_GEN, pad: t(0x9ad), read: async (_a, _abi, fn) => (fn === 'vanityDeployer' ? DEPLOYER : hash) })
const same = await vanityCreate(vctx(H1), ME, '0x1234', { args: [], fixed: { salt: mined.salt, token: mined.token } })
assert.deepEqual([same.salt, same.token, same.mismatch], [mined.salt, mined.token, undefined])
assert.ok(same.data.startsWith('0x'))
const moved = await vanityCreate(vctx(H2), ME, '0x1234', { args: [], fixed: { salt: mined.salt, token: mined.token } })
assert.deepEqual(moved, { mismatch: { expected: mined.token, got: vanityAddress(DEPLOYER, ME, H2, mined.salt) } })
const noDeployer = await vanityCreate({ gen: '2.0', pad: t(0x9ad) }, ME, '0x1234', { args: [], fixed: { salt: mined.salt, token: mined.token } })
assert.deepEqual(noDeployer, { mismatch: { expected: mined.token, got: null } })

// ---- creator fee into the module: its quote joins the treasury, another one is burned
assert.match(payOutCmd('floor-v1', M), /^gang floor distribute --module .* splits it as the tax: .* the rest joins the treasury every holder can redeem/)
assert.match(payOutCmd('floor-v1', M, '', { asset: WBNB, assetSymbol: 'WBNB' }), /sends ALL of it to 0xdead: WBNB is not the module's quote, so it is burned/)
assert.match(claimToModule({ moduleType: 'floor-v1', at: M, bound: USDC, quote: WBNB, quoteSymbol: 'WBNB', boundSymbol: 'USDC' }).warning, /the floor module's quote is USDC, this fee is in WBNB: .* burned/)
assert.match(claimToModule({ moduleType: 'floor-v1', at: M, bound: zeroAddress, quote: WBNB, capQuote: USDC, capSymbol: 'USDC', quoteSymbol: 'WBNB' }).warning, /quote is USDC, .* burned/)
assert.match(claimToModule({ moduleType: 'floor-v1', at: M, bound: zeroAddress, quote: WBNB, capQuote: null, quoteSymbol: 'WBNB' }).warning, /could not read the floor module's quote \(floorQuote\): .*gang floor status --module /)
assert.equal(claimToModule({ moduleType: 'floor-v1', at: M, bound: USDC, quote: USDC }).warning, null)
// --claim --to a floor module cloned for another token: that token's holders get it, said before the claim
assert.equal(floorModuleOfAnother(T, T.toLowerCase()), null)
assert.match(floorModuleOfAnother(OTHER, T), /cloned for another token \(.*\), not this one: a fee claimed there goes to that token's payees and holders/)
assert.match(floorModuleOfAnother(null, T), /could not read which token this floor module was cloned for/)
// --claim --to a contract that only says it is a floor module: three cases, each said as it is
assert.match(unverifiedFloorNote(null, true), /^could not check whether GangFloorModuleFactory made this contract \(RPC error\): run the command again/)
assert.match(unverifiedFloorNote(false, false), /this token's GangLaunchpad generation has no floor factory to check it against/)
assert.match(unverifiedFloorNote(false, true), /but GangFloorModuleFactory did not make it: a fee claimed there is in its hands/)
assert.doesNotMatch(unverifiedFloorNote(false, false), /did not make it/)
assert.match(notThroughModule('floor module', { token: T, at: M, kind: 'floor' }), /does not go through the floor module.*gang floor distribute --module/)

// ---- the events gang tx decodes
const abi = FLOOR_EVENT_ABIS.flat()
const u = (n) => Array.from({ length: n }, () => ({ type: 'uint256' }))
const splitEv = { topics: encodeEventTopics({ abi: FLOOR_ABI, eventName: 'Split' }), data: encodeAbiParameters(u(3), [10n, 7n, 3n]) }
assert.deepEqual(decodeEventLog({ abi, ...splitEv }).args, { incoming: 10n, toTreasury: 7n, toPayees: 3n })
const red = { topics: encodeEventTopics({ abi: FLOOR_ABI, eventName: 'Redeemed', args: { holder: A, to: B } }), data: encodeAbiParameters(u(5), [5n, 4n, 1n, 96n, 995n]) }
assert.deepEqual(decodeEventLog({ abi, ...red }).args, { holder: A, to: B, tokensIn: 5n, quoteOut: 4n, fee: 1n, treasuryAfter: 96n, supplyAfter: 995n })
assert.ok(FLOOR_FACTORY_ABI.some((x) => x.type === 'event' && x.name === 'Created'))
for (const e of ['NoVanityDeployer', 'BadToken', 'WrongToken', 'NothingForRecipient', 'NothingToRedeem', 'NotTradable', 'BadTo']) assert.ok(HINTS[e], e)

// ---- a floor launch takes only the quotes the keeper serves, and is a launch in one command
const REG = t(0x4e9), LISTED = t(0x1157), Q = t(0xcd)
const fakeRead = async (_address, _abi, fn, args) => {
  if (fn === 'quoteRegistry') return REG
  if (fn === 'isQuoted') return args[0].toLowerCase() === LISTED.toLowerCase()
  throw new Error(`unexpected ${fn}`)
}
const net97 = { chainId: '97', pad: t(0x9ad), wbnb: WBNB }
assert.equal(await untrustedBuybackQuote(fakeRead, net97, WBNB, 'floor'), null)
assert.equal(await untrustedBuybackQuote(fakeRead, net97, LISTED, 'floor'), null)
const unlisted = await untrustedBuybackQuote(fakeRead, net97, Q, 'floor')
assert.match(unlisted.error, /^--floor \(a floor module\) needs WBNB, GANG or a quote listed/)
assert.match(unlisted.hint, /launch without --floor/)
assert.match((await untrustedBuybackQuote(async () => { throw new Error('rpc down') }, net97, Q, 'floor')).error, /check the --floor quote: try again/)
const flags = (...on) => (f) => on.includes(f)
assert.ok(LAUNCH_FLAGS.includes('floor') && LAUNCH_FLAGS.includes('redeem-fee'))
assert.equal(isLaunch('v3', flags('floor')), true)
assert.equal(isLaunch('fair', flags('floor')), false)
// --promote with --floor: the recipient is the floor module, so the promoter share stays on the curve
assert.equal(wantsPoolModule('v3', flags('promote', 'buy-tax', 'sell-tax', 'floor'), (f, d) => ({ 'buy-tax': '3', 'sell-tax': '3' }[f] ?? d)), false)
assert.equal(wantsPoolModule('v3', flags('promote', 'buy-tax', 'sell-tax'), (f, d) => ({ 'buy-tax': '3', 'sell-tax': '3' }[f] ?? d)), true)

// ---- flags refused before any RPC (--from: no Agentic Wallet needed)
const cli = new URL('../src/index.js', import.meta.url).pathname
const gangSync = (env, ...args) => {
  const r = spawnSync(process.execPath, [cli, ...args], { encoding: 'utf8', env: { ...process.env, GANG_UPDATE_CHECK: '0', GANG_TELEMETRY: '0', ...env } })
  try { return JSON.parse(r.stdout) } catch { return { raw: r.stdout + r.stderr } }
}
const refused = (args, re, env = {}) => {
  const r = gangSync(env, ...args)
  assert.equal(r.success, false, args.join(' '))
  assert.match(r.error, re, args.join(' '))
  return r
}
const base = ['create', '--name', 'C', '--symbol', 'C', '--from', ME, '--testnet']
const taxed = [...base, '--buy-tax', '2', '--sell-tax', '3']
refused([...base, '--floor'], /--floor \(a floor module\) needs a taxed token: add --buy-tax and --sell-tax, each 1–5/)
refused([...base, '--buy-tax', '2', '--sell-tax', '6', '--floor'], /needs a taxed token/)
for (const f of ['buyback', 'lp']) refused([...taxed, '--floor', `--${f}`, '30'], new RegExp(`^--${f} does not go with --floor: the floor module spends nothing`))
for (const f of ['buyback-to', 'lp-to']) refused([...taxed, '--floor', `--${f}`, A], new RegExp(`^--${f} does not go with --floor`))
refused([...taxed, '--floor', '--after-cap', 'lp:100'], /^--after-cap does not go with --floor/)
refused([...taxed, '--floor', '--recipient', A], /--floor makes the recipient your floor module: leave --recipient out/)
refused([...taxed, '--floor', '--dividend', '100'], /--dividend 100 leaves nothing for the recipient, so the treasury would never fill/)
refused([...taxed, '--floor', '--redeem-fee', '6'], /--redeem-fee is the % of each redemption .*0 to 5/)
refused([...taxed, '--floor', '--tax-cap', '0'], /--tax-cap must be above 0/)
refused([...taxed, '--floor', '--tax-cap-share', '50'], /--tax-cap-share goes with --tax-cap <amount>: with --floor alone/)
refused([...taxed, '--floor', '--split', `${A}:100`], /--split goes with --tax-cap <amount>: with --floor alone/)
refused([...taxed, '--floor', '--tax-cap', '20', '--split', `${A}:60,${B}:30`], /add up to 90%/)
refused([...taxed, '--redeem-fee', '2'], /^--redeem-fee goes with --floor/)
refused([...taxed, '--redeem-fee', '2', '--dev-buy', '1'], /^--redeem-fee goes with --floor/)
for (const f of [['--floor'], ['--redeem-fee', '2']]) {
  refused(['create', '--fair', '--name', 'C', '--symbol', 'C', '--from', ME, '--testnet', ...f], new RegExp(`^${f[0]} is for V3 tokens: it makes the tax recipient a floor module, and a 打新 token has no recipient`))
  refused(['create', '--fair', '--name', 'C', '--symbol', 'C', '--from', ME, '--testnet', '--bond', '1', '--bond-days', '7', ...f], new RegExp(`^${f[0]} is for V3 tokens`))
}
refused(['create', '--fly', '--name', 'C', '--symbol', 'C', '--floor'], /^--floor: 铸币飞轮 tokens take no .*floor module/)
refused([...taxed, '--vault', A, '--floor'], /--floor: a --vault create stands alone/)
// mainnet: not there yet, said before anything else is built
refused(['create', '--name', 'C', '--symbol', 'C', '--from', ME, '--buy-tax', '2', '--sell-tax', '3', '--floor'], /GangFloorModuleFactory .* is not on BSC mainnet yet/, { GANG_FLOOR_FACTORY: '' })
refused(['floor', 'nope'], /usage: gang floor <status\|redeem\|distribute\|release\|set-payee\|bind>/)
refused(['floor'], /usage: gang floor/)
refused(['floor', 'status', '--token', 'nope', '--testnet'], /--token must be a V3 token address/)
refused(['floor', 'status', '--token', T, '--module', M, '--testnet'], /give --token .* or --module, not both/)
refused(['floor', 'redeem', '--module', M, '--testnet'], /gang floor redeem needs --token <the token>/)

console.log('floor: ok')
