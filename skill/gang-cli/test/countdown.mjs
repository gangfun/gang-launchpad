/**
 * The countdown reward (倒计时奖励, countdown-v1; docs/SPEC-COUNTDOWN-REWARD-2026-11-17.md):
 *   - the --cd-* flags, their defaults and bounds; the Config in the quote's units (BNB defaults on WBNB only);
 *   - the contract's math to the wei (payout, shares, a capped round), the buy estimate and what is due;
 *   - the launch preview's economics and honest notes, in the user's framing (a reward by fixed public rules);
 * and, against a local fake BSC testnet node (no chain, no wallet):
 *   - gang create … --countdown-reward: clone (for the token's address) → create (that address, the module as the
 *     recipient) → bind → approve → fund, one tx per run; changed tax rates or --cd-* settings refused;
 *   - gang buy of a graduated token goes through its module (buyWithQuote, mustCount by default; --cd-uncounted;
 *     a buy that would not count refused; --ref and --pay-bnb refused); rewards.countdown in buy and sell previews;
 *   - a module the factory did not make, or one cloned for another token, is never bought through or written to;
 *   - gang countdown status / claim / settle / finalize / claim-dev gates; the built-in mainnet and testnet factories and admins.
 *
 *   node skill/gang-cli/test/countdown.mjs
 */
import assert from 'node:assert/strict'
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  decodeFunctionData, encodeAbiParameters, encodeFunctionResult, getAddress, getCreate2Address, keccak256, parseAbi,
  parseAbiParameters, stringToHex, toFunctionSelector, toHex, zeroAddress,
} from 'viem'

const LAUNCH_DIR = mkdtempSync(join(tmpdir(), 'gang-countdown-'))
process.env.GANG_LAUNCH_DIR = LAUNCH_DIR
process.env.GANG_TELEMETRY = '0'
const { runLaunch } = await import('../src/launch.js')
const { runV3, V3_EVENT_ABIS, V3_NETS } = await import('../src/v3.js')
const cd = await import('../src/countdown.js')
const { COUNTDOWN_ABI, COUNTDOWN_FACTORY_ABI, runCountdown } = cd
const { VANITY_ABI } = await import('../src/vanity.js')
const { CREATOR_FEE_ABI, GRAD_TARGET_ABI, gangGens } = await import('../src/gangpad.js')
const { ROUTER_ABI } = await import('../src/steps.js')

const lc = (a) => String(a).toLowerCase()
const t = (n) => getAddress(`0x${n.toString(16).padStart(40, '0')}`)
const E18 = 10n ** 18n
const BNB = (x) => BigInt(Math.round(x * 1e6)) * 10n ** 12n

// ---------------------------------------------------------------- pure
{
  const p = (flags) => cd.parseCountdownSpec((k) => flags[k], (k) => Object.hasOwn(flags, k))
  // the user's defaults: 60m, 6h, 30d, 30%, 20%, 0%, 10 slots; max payout required
  assert.deepEqual(p({ 'cd-max-payout': '1' }), { window: 3600, maxRound: 21600, idle: 30 * 86400, payoutBps: 3000, lastBps: 2000, devBps: 0, entries: 10, minBuy: null, minPot: null, maxPayout: '1', seed: null })
  assert.match(p({}).error, /--cd-max-payout <amount> is required/)
  assert.deepEqual(p({ 'cd-max-payout': '2', 'cd-window': '30m', 'cd-max-round': '1h', 'cd-idle': '7', 'cd-payout': '50', 'cd-last': '0', 'cd-dev': '50', 'cd-entries': '20', 'cd-min-buy': '0.01', 'cd-min-pot': '0', 'cd-seed': '.5' }),
    { window: 1800, maxRound: 3600, idle: 7 * 86400, payoutBps: 5000, lastBps: 0, devBps: 5000, entries: 20, minBuy: '0.01', minPot: '0', maxPayout: '2', seed: '.5' })
  assert.equal(p({ 'cd-max-payout': '1', 'cd-window': '90' }).window, 5400, 'a bare number is minutes')
  assert.equal(p({ 'cd-max-payout': '1', 'cd-idle': '30d' }).idle, 30 * 86400)
  for (const [k, v, re] of [
    ['cd-window', '29m', /30m–24h/], ['cd-window', '25h', /30m–24h/], ['cd-window', '1.5h', /cd-window/],
    ['cd-max-round', '59m', /1h–24h/], ['cd-idle', '6', /7d–90d/], ['cd-idle', '91d', /7d–90d/],
    ['cd-payout', '9.99', /10 to 50/], ['cd-payout', '51', /10 to 50/], ['cd-last', '20.01', /0 to 20/], ['cd-dev', '51', /0 to 50/],
    ['cd-entries', '0', /between 1 and 20/], ['cd-entries', '21', /between 1 and 20/], ['cd-entries', '2.5', /between 1 and 20/],
    ['cd-min-buy', '0', /positive amount/], ['cd-max-payout', '0', /positive amount/], ['cd-seed', '-1', /positive amount/], ['cd-min-pot', 'x', /0 or more/],
  ]) assert.match(p({ 'cd-max-payout': '1', [k]: v }).error, re, `${k} ${v}`)
  assert.match(p({ 'cd-max-payout': '1', 'cd-window': '2h', 'cd-max-round': '1h' }).error, /at least --cd-window/)

  // the Config in the quote's units: the BNB defaults only on a WBNB-quoted token
  const spec = p({ 'cd-max-payout': '1', 'cd-seed': '0.3' })
  const w = cd.countdownConfig(spec, { decimals: 18, wbnbQuoted: true })
  assert.deepEqual(w.config, { window: 3600n, maxRound: 21600n, idle: 2592000n, payoutBps: 3000, lastBps: 2000, devBps: 0, entries: 10, minBuy: BNB(0.05), minPot: BNB(0.1), maxPayout: E18 })
  assert.equal(w.seed, BNB(0.3))
  assert.deepEqual(w.notes, ['--cd-min-buy left out: 0.05 BNB', '--cd-min-pot left out: 0.1 BNB'])
  assert.match(cd.countdownConfig(spec, { decimals: 6, wbnbQuoted: false, symbol: 'USDT' }).error, /--cd-min-buy <amount> is required on a token quoted in USDT/)
  assert.match(cd.countdownConfig({ ...spec, minBuy: '5' }, { decimals: 6, wbnbQuoted: false, symbol: 'USDT' }).error, /--cd-min-pot <amount> is required/)
  const u = cd.countdownConfig({ ...spec, minBuy: '5', minPot: '10' }, { decimals: 6, wbnbQuoted: false })
  assert.deepEqual([u.config.minBuy, u.config.minPot, u.config.maxPayout, u.seed], [5_000_000n, 10_000_000n, 1_000_000n, 300_000n])
  assert.match(cd.countdownConfig({ ...spec, minBuy: '0.0000001', minPot: '1' }, { decimals: 6, wbnbQuoted: false }).error, /rounds to 0/)
  assert.ok(cd.sameConfig(w.config, { ...w.config, window: 3600 }))
  assert.ok(!cd.sameConfig(w.config, { ...w.config, lastBps: 1999 }))

  // the contract's math (the testnet acceptance's numbers, docs/TESTNET-COUNTDOWN-REWARD-2026-11-17.md)
  const cfg = { payoutBps: 3000, lastBps: 2000, maxPayout: E18, entries: 3 }
  const payout = cd.payoutOf(207421901794360030n, cfg)
  assert.equal(payout, 62226570538308009n)
  const sh = cd.sharesOf(payout, 3, cfg)
  assert.deepEqual([sh.each, sh.last - sh.each], [16593752143548802n, 12445314107661601n])
  assert.equal(sh.each * 3n + (sh.last - sh.each) + sh.dust, payout)
  assert.equal(cd.payoutOf(100n * E18, cfg), E18, 'never more than maxPayout')
  assert.deepEqual(cd.sharesOf(900n, 3, cfg, true), { each: 300n, last: 300n, dust: 0n }, 'a capped round: equal shares, no extra')
  assert.deepEqual(cd.sharesOf(900n, 1, cfg), { each: 900n, last: 900n, dust: 0n }, 'one slot takes all')

  // the share of pool volume that reaches the pool: (tax − platform) × (1 − dividend) × (1 − dev)
  assert.deepEqual(cd.poolShare({ buyTaxPct: 3, sellTaxPct: 3, platformTaxPct: 0.5, dividendPct: 20, devBps: 2500 }).pctOfVolume, 1.5)
  assert.deepEqual(cd.poolShare({ buyTaxPct: 2, sellTaxPct: 5 }).pctOfVolume, { buys: 1.5, sells: 4.5 })

  // the buy estimate: a running round, one that ended (the buy freezes it first), the cap
  const base = { cfg: { ...cfg, window: 1800n, maxRound: 21600n, minPot: 0n }, potAvailable: 10n * E18 / 10n, count: 2, now: 1000n }
  let e = cd.estimateShare({ ...base, deadline: 1500n, roundEndsBy: 20000n }, true)
  assert.deepEqual([e.k, e.payout, e.capped, e.startsRound], [3, 3n * E18 / 10n, false, false])
  assert.equal(e.mine, cd.sharesOf(e.payout, 3, cfg).last)
  e = cd.estimateShare({ ...base, deadline: 900n, roundEndsBy: 20000n }, true)
  assert.deepEqual([e.k, e.startsRound, e.freezesPrevious, e.payout], [1, true, true, cd.payoutOf(E18 - cd.payoutOf(E18, cfg), cfg)])
  e = cd.estimateShare({ ...base, deadline: 1500n, roundEndsBy: 2500n }, true)
  assert.equal(e.capped, true)
  assert.equal(e.mine, e.each, 'at the cap: no extra')
  assert.equal(cd.estimateShare(base, false), null)

  // what is due (as the contract's _due)
  const rounds = [{ frozen: false, settled: false }, { frozen: false, settled: false }]
  const s0 = { cfg: { ...base.cfg, idle: 100n, minPot: 0n }, rounds, potAvailable: E18, lastFinalizedAt: 0n }
  assert.deepEqual(cd.dueOf({ ...s0, now: 10n, deadline: 5n, lastCountedAt: 1n }), { settle: true, finalize: false })
  assert.equal(cd.dueOf({ ...s0, now: 10n, deadline: 50n, lastCountedAt: 1n }).settle, false)
  assert.equal(cd.dueOf({ ...s0, now: 10n, deadline: 50n, lastCountedAt: 1n, rounds: [{ frozen: true, settled: false }, rounds[1]] }).settle, true)
  assert.deepEqual(cd.dueOf({ ...s0, now: 100n, deadline: 0n, lastCountedAt: 1n }), { settle: false, finalize: false, finalizeFrom: 101n })
  assert.equal(cd.dueOf({ ...s0, now: 101n, deadline: 0n, lastCountedAt: 1n }).finalize, true)

  // the launch preview: the economics, and the honest notes in the user's framing
  const view = cd.countdownCreateView({ cfg: w.config, seed: w.seed, decimals: 18, symbol: 'WBNB', buyTaxPct: 3, sellTaxPct: 3, platformTaxPct: 0.5, dividendPct: 0 })
  assert.equal(view.poolGets.pctOfVolume, 2.5)
  assert.equal(view.roundPaysAtMost, '1 WBNB')
  assert.match(view.takingAllSlots.buys, /10 counted buys of 0\.05 WBNB = 0\.5 WBNB/)
  assert.match(view.takingAllSlots.buyTax, /about 0\.015 WBNB in buy tax at 3%/)
  assert.match(view.what, /own share of the pool tax into a reward for buyers/)
  const honest = view.honest.join(' ')
  assert.match(honest, /the dev included, can take several reward slots with several wallets/)
  assert.match(honest, /end time is public in advance.*order of the last block.*pays all its slots equally/)
  assert.match(honest, /only buys through the countdown module count/)
  assert.match(honest, /no holding check/)
  assert.match(view.seed, /0\.3 WBNB/)
  // --ref on a pool trade: the router call carries no invite tag, so the result never says it is attached
  const { refShown, POOL_NO_REF } = await import('../src/pool.js')
  const att = { attached: true, referrer: '0xabc', note: 'credited' }
  assert.deepEqual(refShown({ step: 'pool-buy', venue: 'pancakeswap' }, att), { attached: false, referrer: '0xabc', reason: POOL_NO_REF })
  assert.equal(refShown({ step: 'approve-quote', next: 'pool-buy' }, att).attached, false, 'the setup step before a pool buy')
  assert.equal(refShown({ success: false, step: 'pool-buy', error: 'x' }, att).attached, false)
  assert.deepEqual(refShown({ step: 'buy', via: 'router' }, att), att, 'a curve buy carries the tag')
  const off = { attached: false, reason: 'already traded' }
  assert.deepEqual(refShown({ step: 'pool-buy' }, off), off, 'a ref that was not attached keeps its own reason')
  assert.equal(refShown({ step: 'pool-buy' }, null), null)
  // wording the user ruled out, spelled backwards so it never appears in the source either
  const banned = new RegExp(`\\b(${['teb', 'steb', 'gnitteb', 'yrettol', 'topkcaj', 'elbmag', 'regaw'].map((w) => [...w].reverse().join('')).join('|')})\\b`, 'i')
  for (const text of [JSON.stringify(view), cd.CD_USAGE, cd.WHAT_IT_IS, cd.ONLY_GANG_BUYS]) assert.doesNotMatch(text, banned)
  assert.doesNotMatch(cd.ONLY_GANG_BUYS, /button|website/i)
}

// ---------------------------------------------------------------- the fake node
const GEN = gangGens(true)[0]
const PAD = lc(GEN.pad), FACTORY = lc(cd.countdownFactoryAddress(true)), WBNB = lc(V3_NETS.testnet.wbnb), ROUTER = lc(GEN.router)
assert.equal(FACTORY, lc('0x0f83ABC7d39C0d043d3f5612E304D9395B5fe582'), 'the testnet factory with maxRound')
assert.equal(cd.countdownFactoryAddress(false), '0xa1e3117a59104de7D97667cF22f9AB886a5f2957', 'mainnet: live')
assert.equal(gangGens(false)[0].handlerAdmin, '0xC833CEC2B283759003945C0Bf8C048aB1949Af76')
const VAN = lc(t(0x7a17)), HANDLER = t(0x4a4d), ADMIN = lc(GEN.handlerAdmin), ME = t(0xd3f), BUYER = t(0xb0b), PAIR = lc(t(0x9a12))
const FAKE = lc(t(0xfa4e)) // a contract that answers countdown-v1 but no factory listed it
const OLD = lc(t(0x01d0)) // a module of the superseded factory: listed, but by that factory, and its config() has another ABI
const OLD_FACTORY = lc(t(0x2be9))
const code = new Set([PAD, FACTORY, VAN, ADMIN, WBNB, PAIR, FAKE, ROUTER])
const modules = new Map(), tokens = new Map(), allTokens = []
const world = { now: 2_000_000_000n, allowance: 0n, quoteBal: 10n * E18, wouldCount: true, calls: [], hashes: [] }
const ABI = [...V3_EVENT_ABIS[0], ...CREATOR_FEE_ABI, ...GRAD_TARGET_ABI, ...VANITY_ABI, ...COUNTDOWN_ABI, ...COUNTDOWN_FACTORY_ABI, ...ROUTER_ABI,
  ...parseAbi([
    'function symbol() view returns (string)', 'function decimals() view returns (uint8)', 'function balanceOf(address) view returns (uint256)',
    'function allowance(address,address) view returns (uint256)', 'function moduleOf(address) view returns (address)', 'function isListed(address) view returns (bool)',
    'function owner() view returns (address)', 'function kindOf(address token) view returns (uint8)', 'function tokenCount() view returns (uint256)',
    'function allTokens(uint256) view returns (address)', 'function getReserves() view returns (uint112, uint112, uint32)', 'function token0() view returns (address)',
    'function owedOf(address token) view returns (uint256)', 'function graduationRemaining(address token) view returns (uint256)',
    'function tokenInitCodeHash(string,string,string,address,uint16,uint16,bool) view returns (bytes32)', 'function wbnb() view returns (address)', 'function pancakeRouter() view returns (address)',
    'function previewSellNextBlock(address token, uint256 amount) view returns (uint256)', 'function dexRouter() view returns (address)',
  ])]
const functions = new Map()
for (const f of ABI) if (f.type === 'function' && !functions.has(toFunctionSelector(f))) functions.set(toFunctionSelector(f), f)
const REVERT = { error: { code: 3, message: 'execution reverted', data: '0x' } }
const err = (sig) => ({ error: { code: 3, message: 'execution reverted', data: toFunctionSelector(sig) } })
const moduleAt = (dev, salt) => lc(`0x${keccak256(encodeAbiParameters(parseAbiParameters('address, bytes32'), [dev, salt])).slice(-40)}`)
const hashOf = (args) => keccak256(toHex(JSON.stringify(args, (_k, x) => (typeof x === 'bigint' ? x.toString() : x))))
const predicted = (salt, hash) => lc(getCreate2Address({ from: VAN, bytecodeHash: hash, salt: keccak256(encodeAbiParameters(parseAbiParameters('address, bytes32'), [ME, salt])) }))
const ROUND = (id, count, list) => [BigInt(id), count, false, false, 0n, list.map((buyer) => ({ buyer, tokens: 5n * E18 }))]

function answer(b) {
  if (b.method === 'eth_chainId') return { result: '0x61' }
  if (b.method === 'eth_getCode') return { result: code.has(lc(b.params[0])) ? '0x60' : '0x' }
  if (b.method === 'eth_blockNumber') return { result: '0x10' }
  if (b.method === 'eth_getBalance') return { result: toHex(10n * E18) }
  if (b.method === 'eth_getTransactionCount') return { result: toHex((world.nonce ?? { latest: 0, pending: 0 })[b.params[1] === 'pending' ? 'pending' : 'latest']) }
  if (b.method === 'eth_getBlockByNumber') {
    return { result: { number: '0x10', timestamp: toHex(world.now), hash: `0x${'11'.repeat(32)}`, parentHash: `0x${'22'.repeat(32)}`, transactions: [], gasLimit: '0x1', gasUsed: '0x0', difficulty: '0x0', totalDifficulty: '0x0', size: '0x0', nonce: '0x0000000000000000', logsBloom: `0x${'00'.repeat(256)}`, miner: zeroAddress, extraData: '0x', uncles: [] } }
  }
  assert.equal(b.method, 'eth_call', b.method)
  const { to, data, from } = b.params[0]
  const at = lc(to)
  const f = functions.get(data.slice(0, 10))
  if (!f) return REVERT
  const { args = [] } = decodeFunctionData({ abi: [f], data })
  const m = modules.get(at), tk = tokens.get(at)
  let result
  if (at === OLD) {
    // the superseded factory's module: it names its kind and its token, and nothing else of this ABI answers
    if (f.name === 'moduleType') return { result: encodeFunctionResult({ abi: [f], functionName: f.name, result: stringToHex('countdown-v1', { size: 32 }) }) }
    if (f.name === 'rewardToken') return { result: encodeFunctionResult({ abi: [f], functionName: f.name, result: world.oldToken }) }
    return REVERT
  }
  if (m || at === FAKE) {
    const mm = m ?? fakeModule
    world.calls.push({ at, fn: f.name, args, from })
    switch (f.name) {
      case 'moduleType': result = stringToHex('countdown-v1', { size: 32 }); break
      case 'config': result = mm.cfg; break
      case 'dev': result = mm.dev; break
      case 'rewardToken': result = mm.rewardToken; break
      case 'rewardQuote': result = WBNB; break
      case 'token': result = mm.token ?? zeroAddress; break
      case 'pot': case 'potAvailable': result = mm.pot; break
      case 'devOwed': result = mm.devOwedFake ?? 0n; break
      case 'reservedTotal': case 'claimTotal': case 'lastRoundId': case 'lastFinalizedAt': result = 0n; break
      case 'cur': result = 0; break
      case 'deadline': result = mm.deadline; break
      case 'lastCountedAt': result = mm.deadline ? mm.deadline - 1800n : 0n; break
      case 'currentRound': result = mm.deadline && world.now <= mm.deadline ? 1n : 0n; break
      case 'roundEndsBy': result = mm.deadline ? mm.deadline + 10_000n : 0n; break
      case 'previewWork': result = [!!mm.deadline && world.now > mm.deadline, 0n]; break
      case 'round': result = args[0] === 0 && mm.deadline ? ROUND(1, 2, [BUYER, ME]) : ROUND(0, 0, []); break
      case 'claimableOf': result = lc(args[0]) === lc(ME) ? mm.claimable ?? 0n : 0n; break
      case 'wouldCount': result = world.wouldCount && args[0] >= mm.cfg.minBuy; break
      case 'buyWithQuote': result = 1234n * E18; break
      case 'buy': result = 1234n * E18; break
      case 'claim': if (!(mm.claimable > 0n)) return err('NothingToClaim()'); result = mm.claimable; break
      case 'bind': if (!tokens.has(lc(args[0]))) return err('NotCurve()'); result = undefined; break
      case 'fund': if (!mm.token) return err('NotBound()'); result = undefined; break
      case 'settle': result = undefined; break
      default: return REVERT
    }
    return { result: encodeFunctionResult({ abi: [f], functionName: f.name, result }) }
  }
  switch (f.name) {
    // ---- the pad
    case 'vanityDeployer': if (at !== PAD) return REVERT; result = VAN; break
    case 'taxHandler': case 'recipientRegistry': case 'implementation': result = HANDLER; break
    case 'router': result = HANDLER; break
    case 'kindOf': result = at === PAD && tokens.has(lc(args[0])) ? 1 : 0; break
    case 'tokenCount': result = BigInt(allTokens.length); break
    case 'allTokens': result = allTokens[Number(args[0])]; break
    case 'curves': {
      const c = at === PAD ? tokens.get(lc(args[0])) : null
      result = c ? [c.creator, WBNB, 0n, 0n, 9n * E18, 3n * E18, !!c.graduated, 300, 300, 0, c.graduated ? PAIR : zeroAddress, zeroAddress]
        : [zeroAddress, zeroAddress, 0n, 0n, 0n, 0n, false, 0, 0, 0, zeroAddress, zeroAddress]
      break
    }
    case 'taxConfigOf': { const c = tokens.get(lc(args[0])); if (!c) return REVERT; result = [300, 300, 0, c.recipient]; break }
    case 'graduationRemaining': result = 0n; break
    case 'owedOf': result = 0n; break
    case 'createWithSalt': result = world.padSays ?? predicted(args[0], world.hashes.at(-1)); break
    case 'checkTaxConfigFor': case 'checkTaxConfig': result = [true, '']; break
    case 'isListed': result = modules.has(lc(args[0])) || lc(args[0]) === FAKE; break
    case 'owner': result = ADMIN; break
    case 'isAgent': case 'vanityEnabled': result = true; break
    case 'GRAD_BNB_TIERS': result = [6n, 9n, 12n, 15n].map((x) => x * E18); break
    case 'TARGET_GRAD_BNB': case 'graduationAmountOf': result = 9n * E18; break
    case 'graduationAmountFor': result = args[2]; break
    case 'PROTOCOL_FEE_BPS': result = 100n; break
    case 'PLATFORM_TAX_BPS': result = 50n; break
    case 'CREATOR_FEE_SHARE_BPS': result = 7000n; break
    case 'tokenInitCodeHash': result = hashOf(args); world.hashes.push(result); break
    // ---- the factory and the handler admin
    case 'predict': result = moduleAt(args[0], args[1]); break
    case 'create': world.calls.push({ at, fn: 'create', args }); result = moduleAt(ME, args.at(-1)); break
    case 'admin': result = ADMIN; break
    case 'moduleOf': result = modules.has(lc(args[0])) ? FACTORY : lc(args[0]) === OLD ? OLD_FACTORY : zeroAddress; break
    // ---- the pair, the router, the handler
    case 'getReserves': result = [1000n * E18 * 1000n, 10n * E18, 0]; break
    case 'token0': result = [...tokens.keys()].find((k) => tokens.get(k).graduated) ?? zeroAddress; break
    case 'wbnb': result = WBNB; break
    case 'pad': result = PAD; break
    case 'pancakeRouter': result = t(0xcafe); break
    case 'dexRouter': result = t(0xdead1); break
    case 'previewSellNextBlock': result = E18 / 100n; break
    // ---- ERC-20s
    case 'symbol': result = at === WBNB ? 'WBNB' : tk ? tk.symbol : 'X'; break
    case 'decimals': result = 18; break
    case 'balanceOf': result = at === WBNB ? world.quoteBal : tk ? (tk.balances.get(lc(args[0])) ?? 0n) : 0n; break
    case 'allowance': result = at === WBNB ? world.allowance : 2n ** 255n; break
    default: return REVERT
  }
  return { result: encodeFunctionResult({ abi: [f], functionName: f.name, result }) }
}
const fakeModule = { cfg: { window: 1800n, maxRound: 21600n, idle: 604800n, payoutBps: 3000, lastBps: 2000, devBps: 0, entries: 3, minBuy: BNB(0.01), minPot: 0n, maxPayout: E18 }, dev: ME, rewardToken: null, token: null, pot: E18, deadline: 0n }

const server = createServer((req, res) => {
  let body = ''
  req.on('data', (c) => (body += c))
  req.on('end', () => {
    const input = JSON.parse(body)
    const one = (b) => ({ jsonrpc: '2.0', id: b.id, ...answer(b) })
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify(Array.isArray(input) ? input.map(one) : one(input)))
  })
})
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
const rpc = `http://127.0.0.1:${server.address().port}`
process.env.GANG_TESTNET_RPC_URL = rpc
V3_NETS.testnet.rpcs = [rpc]

class Failed extends Error { constructor(error, details) { super(error); this.details = details ?? {} } }
let uploads = 0
const io = (flags) => ({
  opt: (key, fallback) => flags[key] ?? fallback,
  flag: (key) => Object.hasOwn(flags, key),
  out: (x) => x,
  fail: (error, details) => { throw new Failed(error, details) },
  summarize: () => assert.fail('raw calldata needs no wallet preview'),
  checkMeta: () => {},
  resolveLogo: async () => ({ logoURI: 'ipfs://logo' }),
  resolveMeta: async () => { uploads++; return { metaURI: 'ipfs://meta', metadata: { name: flags.name } } },
})
const notes = { step: (_ctx, tx, extra) => ({ success: true, ...extra, tx }), skipped: () => ({}), pool: {} }
const BASE = { name: 'Countdown', symbol: 'CDN', from: ME, testnet: true, calldata: true, 'buy-tax': '3', 'sell-tax': '3', 'countdown-reward': true, 'cd-max-payout': '1', 'cd-entries': '3', 'cd-seed': '0.2' }
const launch = (over = {}, drop = []) => {
  const flags = { ...BASE, ...over }
  for (const d of drop) delete flags[d]
  return runLaunch('v3', { io: io(flags), runV3, runFair: () => assert.fail('not a 打新 launch'), runBond: () => assert.fail('no bond'), padNotes: () => notes })
}
const refused = async (run, re) => {
  let got
  try { got = await run() } catch (e) { assert.ok(e instanceof Failed, e.stack); assert.match(e.message, re); return e }
  assert.fail(`not refused: ${JSON.stringify(got, (_k, v) => (typeof v === 'bigint' ? v.toString() : v)).slice(0, 400)}`)
}
const plan = () => JSON.parse(readFileSync(join(LAUNCH_DIR, readdirSync(LAUNCH_DIR).find((n) => n.endsWith('.json'))), 'utf8'))
const v3 = (sub, flags) => runV3(sub, { ...io({ testnet: true, calldata: true, from: ME, ...flags }), notes })
const countdown = (sub, flags) => runCountdown(sub, io({ testnet: true, calldata: true, from: ME, ...flags }))

try {
  // ---- what a launch refuses before any read
  await refused(() => launch({ floor: true }), /--floor does not go with --countdown-reward: a token has one tax recipient/)
  for (const f of ['buyback', 'lp', 'split', 'tax-cap', 'recipient', 'vault']) await refused(() => launch({ [f]: '5' }), new RegExp(`--${f} does not go with --countdown-reward`))
  await refused(() => launch({}, ['buy-tax', 'sell-tax']), /needs a taxed token/)
  await refused(() => launch({ dividend: '100' }), /--dividend 100 leaves nothing/)
  await refused(() => launch({}, ['cd-max-payout']), /--cd-max-payout <amount> is required/)
  await refused(() => launch({ 'grad-reward': '0.5' }), /--grad-reward and --countdown-reward can't go together in this CLI version/)
  {
    const { spawnSync } = await import('node:child_process')
    const r = spawnSync(process.execPath, [new URL('../src/index.js', import.meta.url).pathname, 'create', '--name', 'A', '--symbol', 'A', '--buy-tax', '3', '--sell-tax', '3', '--countdown-reward', '--cd-max-payout', '1', '--grad-reward', '0.5', '--testnet'], { encoding: 'utf8', env: { ...process.env, GANG_TELEMETRY: '0', GANG_UPDATE_CHECK: '0' } })
    assert.equal(r.status, 1)
    assert.match(JSON.parse(r.stdout).error, /--grad-reward and --countdown-reward can't go together in this CLI version/)
  }
  await refused(() => launch({ 'cd-max-round': '20m' }), /--cd-max-round must be/)
  await refused(() => launch({ 'cd-window': '1h' }, ['countdown-reward']), /go with --countdown-reward/)
  await refused(() => runLaunch('fair', { io: io({ ...BASE, fair: true }), runV3, runFair: null, runBond: null, padNotes: () => notes }), /--countdown-reward is for V3 tokens/)

  // ---- 1. the clone: for the token's address, with the Config in wei
  const clone = await launch()
  assert.deepEqual([clone.success, clone.step, clone.launch.stage], [true, 'countdown-module', 'countdown-module'])
  assert.deepEqual(clone.launch.steps, ['countdown-module', 'create', 'bind', 'seed'])
  assert.equal(uploads, 1)
  const call = decodeFunctionData({ abi: COUNTDOWN_FACTORY_ABI, data: clone.tx.data })
  assert.equal(call.functionName, 'create')
  assert.equal(lc(call.args[0]), clone.tokenWillBe)
  assert.ok(clone.tokenWillBe.endsWith('abcd'))
  assert.equal(lc(call.args[1]), WBNB)
  assert.deepEqual(call.args[2], { window: 3600n, maxRound: 21600n, idle: 2592000n, payoutBps: 3000, lastBps: 2000, devBps: 0, entries: 3, minBuy: BNB(0.05), minPot: BNB(0.1), maxPayout: E18 })
  assert.equal(clone.countdown.poolGets.pctOfVolume, 2.5)
  assert.match(clone.countdown.takingAllSlots.buys, /3 counted buys of 0\.05 WBNB = 0\.15 WBNB/)
  const p1 = plan()
  assert.deepEqual([p1.module, lc(p1.splitter), p1.countdown.token, p1.countdown.buyBps], ['countdown', lc(clone.module), clone.tokenWillBe, 300])
  const TOKEN = clone.tokenWillBe, MODULE = lc(clone.module)

  // not on chain yet
  assert.equal((await launch()).error, 'the countdown reward module is not on chain yet')
  // the clone lands (listed by the factory)
  code.add(MODULE)
  modules.set(MODULE, { cfg: call.args[2], dev: ME, rewardToken: getAddress(TOKEN), token: null, pot: 0n, deadline: 0n })

  // ---- 2. what decides the token's address, and the module's settings, can't change between runs
  await refused(() => launch({ 'sell-tax': '4' }), /cloned for a token with a 3% buy \/ 3% sell tax/)
  await refused(() => launch({ 'cd-payout': '40' }), /countdown reward module is set up like this .*not what the --cd-\* flags say now/)
  await refused(() => launch({ 'cd-min-buy': '0.06' }), /not what the --cd-\* flags say now/)
  await refused(() => launch({}, ['countdown-reward', 'cd-max-payout', 'cd-entries', 'cd-seed']), /this launch began with --countdown-reward .*the same --countdown-reward \/ --cd-\* settings/)

  // ---- 3. the create: the plan's salt and metadata, the module as the recipient
  const create = await launch()
  assert.deepEqual([create.success, create.step], [true, 'create'])
  const outer = decodeFunctionData({ abi: VANITY_ABI, data: create.tx.data })
  assert.equal(outer.args[0], p1.countdown.salt)
  const inner = decodeFunctionData({ abi: V3_EVENT_ABIS[0], data: outer.args[1] })
  assert.equal(lc(inner.args[6].recipient), MODULE)
  assert.equal(lc(create.countdownToken), TOKEN)
  assert.match(create.metadataFixed, /countdown reward module was cloned/)
  assert.equal(uploads, 1, 'nothing uploaded again')
  world.padSays = t(0xbad)
  await refused(() => launch(), /the pad would create this token at another address than the one its countdown reward module was cloned for/)
  world.padSays = null

  // the create lands at the planned address
  tokens.set(TOKEN, { creator: ME, symbol: 'CDN', recipient: getAddress(MODULE), balances: new Map() })
  allTokens.push(getAddress(TOKEN))
  code.add(TOKEN)

  // ---- 4. bind, then the seed: approve, fund
  const bind = await launch()
  assert.deepEqual([bind.step, bind.launch.stage], ['bind', 'bind'])
  assert.equal(decodeFunctionData({ abi: COUNTDOWN_ABI, data: bind.tx.data }).args[0].toLowerCase(), TOKEN)
  assert.match(bind.launch.next, /continues with the seed/)
  modules.get(MODULE).token = getAddress(TOKEN)
  const approve = await launch()
  assert.deepEqual([approve.step, approve.launch.stage, lc(approve.spender), approve.approve], ['approve-quote', 'seed', MODULE, '0.2'])
  world.allowance = BNB(0.2)
  const fund = await launch()
  assert.deepEqual([fund.step, lc(fund.tx.to), fund.amount], ['seed', MODULE, '0.2'])
  assert.equal(decodeFunctionData({ abi: COUNTDOWN_ABI, data: fund.tx.data }).args[0], BNB(0.2))
  // a fund still pending: no second one beside it
  world.nonce = { latest: 5, pending: 6 }
  await refused(() => launch(), /a tx of this wallet is still pending/)
  // nothing pending and the books show no seed: the fund never landed, so it is built again, with a warning
  world.nonce = { latest: 6, pending: 6 }
  modules.get(MODULE).pot = BNB(0.1) // less than the seed arrived (a stray transfer someone booked)
  await refused(() => launch(), /built a fund of the seed before.*0\.1 WBNB of 0\.2 arrived.*waiting for approval in the Binance App: approve only one.*--cd-seed-again/)
  assert.match((await launch({ 'cd-seed-again': true })).warning, /--cd-seed-again: a second fund of the seed \(the books show 0\.1 WBNB of 0\.2 arrived/)
  // the dev's part is not counted: a claimDev lowering devOwed never makes the seed look missing (or present)
  modules.get(MODULE).devOwedFake = BNB(1)
  assert.equal((await launch({ 'cd-seed-again': true })).step, 'seed', 'the dev\'s part is not the seed')
  modules.get(MODULE).devOwedFake = 0n
  // a changed --cd-seed is refused
  await refused(() => launch({ 'cd-seed': '0.3' }), /this launch's seed is 0\.2 WBNB, not the 0\.3/)
  // graduated before the seed was seen: never decided, never funded again
  tokens.get(TOKEN).graduated = true
  await refused(() => launch(), /graduated before this launch saw its seed land/)
  tokens.get(TOKEN).graduated = false
  // the seed lands: the books moved by at least the seed since the seed stage began
  modules.get(MODULE).pot = BNB(0.3)
  const done = await launch()
  assert.equal(done.launch.stage, 'done')
  assert.match(done.launch.seed, /done: 0\.3 WBNB arrived in the module's books since the seed stage began; it is not funded again/)
  assert.equal(done.countdown.state, 'not started')
  assert.equal(done.countdown.verified, true)

  // ---- 5. gang buy of the graduated token goes through its module
  tokens.get(TOKEN).graduated = true
  code.add(ROUTER)
  modules.get(MODULE).deadline = world.now + 600n
  world.allowance = 0n
  const ap = await v3('buy', { token: TOKEN, amount: '0.1', 'use-quote': true })
  assert.deepEqual([ap.step, lc(ap.spender), ap.then.function, ap.then.mustCount], ['approve-quote', MODULE, 'buyWithQuote', true])
  world.allowance = E18
  world.calls = []
  const buy = await v3('buy', { token: TOKEN, amount: '0.1', 'use-quote': true })
  assert.deepEqual([buy.success, buy.via, lc(buy.tx.to), buy.function, buy.mustCount], [true, 'countdown', MODULE, 'buyWithQuote', true])
  const bc = decodeFunctionData({ abi: COUNTDOWN_ABI, data: buy.tx.data })
  assert.deepEqual([bc.args[0], bc.args[3]], [BNB(0.1), true])
  assert.equal(bc.args[1], (1234n * E18 * 9900n) / 10_000n, 'minTokensOut: the simulation less 1%')
  assert.equal(buy.rewards.countdown.counts, true)
  assert.equal(buy.rewards.countdown.round.secondsLeft, 600)
  assert.equal(buy.rewards.countdown.round.countedSoFar, 2)
  assert.ok(buy.rewards.countdown.estimate.yourShareIfLast)
  // WBNB-quoted, paid in BNB: buy() with the value
  const bnb = await v3('buy', { token: TOKEN, amount: '0.1' })
  assert.deepEqual([bnb.function, bnb.tx.value, decodeFunctionData({ abi: COUNTDOWN_ABI, data: bnb.tx.data }).functionName], ['buy', String(BNB(0.1)), 'buy'])
  // --cd-uncounted: mustCount false
  const unc = await v3('buy', { token: TOKEN, amount: '0.1', 'cd-uncounted': true })
  assert.equal(decodeFunctionData({ abi: COUNTDOWN_ABI, data: unc.tx.data }).args[2], false)
  // a buy that would not count: refused with the reason (mustCount would revert it)
  const small = await v3('buy', { token: TOKEN, amount: '0.01' })
  assert.equal(small.success, false)
  assert.match(small.error, /would not count.*less than the 0\.05 WBNB minimum/)
  assert.match(small.hint, /--cd-uncounted/)
  assert.equal((await v3('buy', { token: TOKEN, amount: '0.01', 'cd-uncounted': true })).success, true)
  await refused(() => v3('buy', { token: TOKEN, amount: '0.1', ref: '0xabc' }), /--ref does not apply to a buy through the countdown reward module/)
  // the sell preview says sells don't touch slots
  tokens.get(TOKEN).balances.set(lc(ME), 10n * E18)
  const sell = await v3('sell', { token: TOKEN, amount: '1' })
  assert.match(sell.rewards.countdown.note, /never take out a buyer's slots and there is no holding check/)

  // ---- 6. gang countdown
  const st = await countdown('status', { token: TOKEN })
  assert.deepEqual([st.success, st.verified, st.state, st.rules.entries, st.rules.minBuy], [true, true, 'running', 3, '0.05'])
  assert.equal(st.round.latest.slotsOldestFirst.at(-1).you, true)
  await refused(() => countdown('claim', { token: TOKEN }), /nothing to claim for this wallet/)
  modules.get(MODULE).claimable = BNB(0.03)
  const cl = await countdown('claim', { token: TOKEN, to: BUYER })
  assert.deepEqual([cl.step, cl.amount, lc(decodeFunctionData({ abi: COUNTDOWN_ABI, data: cl.tx.data }).args[0])], ['countdown-claim', '0.03', lc(BUYER)])
  await refused(() => countdown('settle', { token: TOKEN }), /nothing to settle yet: the round runs until/)
  await refused(() => countdown('finalize', { token: TOKEN }), /a round is running/)
  await refused(() => countdown('claim-dev', { token: TOKEN }), /dev 0%/)
  modules.get(MODULE).deadline = world.now - 1n
  const se = await countdown('settle', { token: TOKEN })
  assert.equal(decodeFunctionData({ abi: COUNTDOWN_ABI, data: se.tx.data }).functionName, 'settle')
  await refused(() => countdown('nope', { token: TOKEN }), /usage: gang countdown/)

  // ---- 7. a module the factory did not make: never bought through, nothing written, only the warning
  const OTHER = lc(t(0x07e1abcd))
  fakeModule.rewardToken = getAddress(OTHER)
  tokens.set(OTHER, { creator: ME, symbol: 'OTH', recipient: getAddress(FAKE), graduated: false, balances: new Map() })
  const fst = await countdown('status', { token: OTHER })
  assert.deepEqual([fst.verified, fst.isThisTokensCountdown], [false, false])
  assert.match(fst.warning, /GangCountdownRewardFactory did not make it/)
  await refused(() => countdown('claim', { token: OTHER }), /did not make it/)
  // a module made by the factory but cloned for another token: this token has none
  const THIRD = lc(t(0x0333abcd))
  tokens.set(THIRD, { creator: ME, symbol: 'TRD', recipient: getAddress(MODULE), graduated: false, balances: new Map() })
  assert.match((await countdown('status', { token: THIRD })).warning, /cloned for another token/)

  // ---- 8. the superseded factory's module (testnet CDRT is one): provenance first, so its other ABI is never read; the
  // buy is a plain pool buy with the warning, info and status show only the warning
  const OLDTOKEN = lc(t(0x0444abcd))
  world.oldToken = getAddress(OLDTOKEN)
  tokens.set(OLDTOKEN, { creator: ME, symbol: 'OLD', recipient: getAddress(OLD), graduated: true, balances: new Map() })
  code.add(OLD)
  const ost = await countdown('status', { token: OLDTOKEN })
  assert.deepEqual([ost.success, ost.verified, ost.isThisTokensCountdown], [true, false, false])
  assert.match(ost.warning, /GangCountdownRewardFactory did not make it/)
  const oinfo = await v3('info', { token: OLDTOKEN })
  assert.equal(oinfo.countdown.isThisTokensCountdown, false)
  const obuy = await v3('buy', { token: OLDTOKEN, amount: '0.1' })
  // the plain GangRouter pool path (this fake node quotes no PancakeSwap path, so it stops at the quote)
  assert.deepEqual([obuy.step, obuy.via], ['pool-buy', undefined])
  assert.match(obuy.error, /PancakeSwap has no usable pool/)
  assert.match(obuy.rewards.countdown.warning, /did not make it/)
  await refused(() => v3('buy', { token: OLDTOKEN, amount: '0.1', 'cd-uncounted': true }), /--cd-uncounted applies to a token whose tax recipient is its countdown reward module/)

  // ---- 9. a factory whose admin() is not the network's pinned GangHandlerAdmin (an env naming a forged one): never verified
  const forged = (address, _abi, fn) => (fn === 'admin' ? t(0xf0f0) : FACTORY)
  assert.equal(await cd.countdownVerified(async (...a) => forged(...a), MODULE, FACTORY, GEN.handlerAdmin), false)
  assert.equal(await cd.countdownVerified(async (_a, _b, fn) => (fn === 'admin' ? GEN.handlerAdmin : FACTORY), MODULE, FACTORY, GEN.handlerAdmin), true)
  assert.equal(await cd.countdownVerified(async () => { throw new Error('rpc') }, MODULE, FACTORY, GEN.handlerAdmin), null)
  assert.equal(await cd.countdownVerified(async () => FACTORY, MODULE, FACTORY, null), false)

  // ---- 10. a plan begun with another factory: refused on resume
  rmSync(LAUNCH_DIR, { recursive: true, force: true })
  await launch({ symbol: 'CDN2' })
  const pf = join(LAUNCH_DIR, readdirSync(LAUNCH_DIR).find((n) => n.endsWith('.json')))
  writeFileSync(pf, JSON.stringify({ ...JSON.parse(readFileSync(pf, 'utf8')), factory: getAddress(OLD_FACTORY) }))
  await refused(() => launch({ symbol: 'CDN2' }), /cloned by the factory .* not by 0x0f83ABC7d39C0d043d3f5612E304D9395B5fe582 .*Add --restart/)

  console.log('countdown: ok')
} finally {
  server.close()
  rmSync(LAUNCH_DIR, { recursive: true, force: true })
}
