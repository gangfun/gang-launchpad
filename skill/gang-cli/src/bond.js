import { createPublicClient, http, parseAbi, encodeFunctionData, decodeEventLog, formatUnits, parseUnits, isAddress, zeroAddress } from 'viem'
import { decimalsOf, fundingStep as fund, parseAmount, parseIntIn, parseNum, revertOf as revertIn, step, units, GAS_RESERVE } from './steps.js'
import { MERGED_ERRORS_ABI, MERGED_HINTS, NOT_ON_MAINNET, padNets } from './gangpad.js'
import { bawAddress } from './baw.js'

/**
 * `gang bond …` — GangBond (Agent 押金承诺, gang-launchpad src/gang/GangBond.sol): a creator of a GangLaunchpad token
 * (V3 after graduation, 打新 after launch) posts a bond in the token's quote and promises its creating address holds at
 * least X tokens until T. Below X, anyone can report it: the reporter gets 1%, the rest buys the token back from its
 * pair in small chunks and burns it. Settle (after T, balance still ≥ X) returns the whole bond to the creator.
 * One contract per network, no owner; it only reads the pad.
 *
 * Env: GANG_BOND (mainnet), GANG_TESTNET_BOND (testnet) override the addresses below.
 */

// script/DeployGangBond.s.sol. Testnet: 2026-10-28, block 139343409, over the set-10 pad (docs/TESTNET-GANG-BOND-2026-10-28.md).
// Mainnet: not deployed yet (GANG_BOND overrides either)
export const MAINNET_BOND = null
export const TESTNET_BOND = '0x587f563749A321624b5710d6D77010F183a65d7E'

export const BOND_ABI = parseAbi([
  'function post(address token, uint256 amount, uint256 holdAmount, uint64 deadline) payable',
  'function topUp(address token, uint256 amount) payable',
  'function raiseHold(address token, uint256 newHoldAmount)',
  'function extend(address token, uint64 newDeadline)',
  'function report(address token)',
  'function settle(address token)',
  'function burnChunk(address token, uint256 minTokensOut) returns (uint256 quoteIn, uint256 burned)',
  'function bondOf(address token) view returns ((address creator, address quote, uint32 round, uint8 state, uint64 postedAt, uint64 deadline, uint128 amount, uint128 holdAmount, uint128 burnLeft))',
  'function isViolated(address token) view returns (bool)',
  'function dumpValue(address token) view returns (uint256)',
  'function coverageBps(address token) view returns (uint256)',
  'function historyOf(address creator) view returns (uint32 posted, uint32 honored, uint32 slashed)',
  'function quoteDump(address token, uint256 holdAmount) view returns (uint256)',
  'function previewBurn(address token) view returns (bool ready, uint256 quoteIn, uint256 tokensOut)',
  'function MIN_DURATION() view returns (uint64)', 'function MAX_DURATION() view returns (uint64)',
  'function REPORTER_BPS() view returns (uint256)',
  'event BondPosted(address indexed token, address indexed creator, uint32 round, address quote, uint256 amount, uint256 holdAmount, uint64 deadline)',
  'event BondToppedUp(address indexed token, uint32 round, uint256 added, uint256 amount)',
  'event HoldRaised(address indexed token, uint32 round, uint256 holdAmount)',
  'event BondExtended(address indexed token, uint32 round, uint64 deadline)',
  'event BondReported(address indexed token, uint32 round, address indexed reporter, uint256 balance, uint256 reward, uint256 burnLeft)',
  'event BondSettled(address indexed token, uint32 round, address indexed creator, uint256 amount)',
  'event BondBurned(address indexed token, uint32 round, uint256 quoteIn, uint256 tokensBurned, uint256 burnLeft)',
  'error ZeroAddress()', 'error UnknownToken()', 'error NotTradable()', 'error NotCreator()', 'error BondLive()',
  'error NotActive()', 'error ZeroAmount()', 'error BadDuration()', 'error BadHold()', 'error BadValue()',
  'error FeeOnTransferQuote()', 'error NotViolated()', 'error Violated()', 'error NotDue()', 'error NothingToBurn()',
  'error BurnedThisBlock()', 'error Slippage()', 'error FlashSwapActive()',
  'error SafeCastOverflowedUintDowncast(uint8 bits, uint256 value)', 'error SafeERC20FailedOperation(address token)',
])

const PAD_ABI = parseAbi([
  'function kindOf(address token) view returns (uint8)',
  'function curves(address token) view returns (address creator, address quote, uint128 realQuote, uint128 sold, uint128 gradAmt, uint128 virtualQuote, bool graduated, uint16 buyTaxBps, uint16 sellTaxBps, uint16 dividendBps, address pair, address refPair)',
  'function sales(address token) view returns (address creator, uint64 progressAt, uint16 capShares, uint16 holdBps, address quote, uint16 sold, bool launched, uint16 mintFeeBps, uint16 exitFeeBps, address gate, uint128 sharePrice, address pair, address refPool, uint16 markSold)',
])
const ERC20_ABI = parseAbi(['function balanceOf(address) view returns (uint256)', 'function symbol() view returns (string)'])

const HINTS = {
  NotTradable: 'a bond needs the PancakeSwap pair: a V3 token after graduation, a 打新 token after launch',
  UnknownToken: 'not a GangLaunchpad token (V3 or 打新): bonds cover only those',
  NotCreator: 'only the token\'s creator (curves / sales creator) can post, top up, raise X or extend',
  BondLive: 'this token already has a bond in force (active, or slashed with buy-back still running): one at a time',
  NotActive: 'no active bond on this token (none posted, already settled, or slashed)',
  BadDuration: '--days must give a deadline 7–90 days from now (extend: later than the current one, at most 90 days from now)',
  BadHold: '--hold must be above 0 and at most the creator\'s balance now (raise-hold: not below the current X)',
  BadValue: 'native BNB only for a WBNB-quoted token, exactly the bond amount',
  FeeOnTransferQuote: 'the quote takes a fee on transfer: it cannot be used for a bond',
  NotViolated: 'the creator still holds at least X: nothing to report',
  Violated: 'the creator holds less than X: the bond cannot be settled, only reported',
  NotDue: 'the deadline has not passed yet',
  NothingToBurn: 'no slashed bond with buy-back left on this token',
  BurnedThisBlock: 'a chunk was already bought for this token in this block: try the next block',
  Slippage: 'the buy-back would burn fewer tokens than the minimum: the price moved, re-run',
  FlashSwapActive: 'the token\'s pair is mid flash swap: settle cannot count tokens borrowed from it; send settle in its own tx',
}

const STATES = ['none', 'active', 'slashed', 'settled']
const BPS = 10_000n
const TOTAL_SUPPLY = 1_000_000_000n * 10n ** 18n
const DAY = 86_400
const MAX_UINT = 2n ** 256n - 1n

/** GangBond address of `testnet` / mainnet: env first, then the shipped one; null when not deployed there. */
export function bondAddress(testnet) {
  return (testnet ? process.env.GANG_TESTNET_BOND || TESTNET_BOND : process.env.GANG_BOND || MAINNET_BOND) || null
}

function bondCtx(testnet) {
  const net = padNets('v3')[testnet ? 'testnet' : 'mainnet']
  if (!net.pad) throw new Error(NOT_ON_MAINNET)
  const bond = bondAddress(testnet)
  if (!bond) throw new Error(`GangBond is not deployed on ${testnet ? 'the BSC testnet' : 'BSC mainnet'} in this CLI version: set ${testnet ? 'GANG_TESTNET_BOND' : 'GANG_BOND'} to its address`)
  const client = createPublicClient({ chain: net.chain, transport: http(net.rpc) })
  return { ...net, bond, client, read: (address, abi, functionName, args = []) => client.readContract({ address, abi, functionName, args }) }
}

/** --from, else the signed-in Agentic Wallet (as gang v3 / gang fair). */
const walletFor = (ctx, from) => {
  if (from) return from
  try { return bawAddress(ctx.chainId) } catch { return bawAddress('56') }
}

const revertOf = (e) => revertIn(e, [BOND_ABI, MERGED_ERRORS_ABI], { ...MERGED_HINTS, ...HINTS })

async function simulate(ctx, from, functionName, args, value = 0n) {
  try {
    const { result } = await ctx.client.simulateContract({ account: from, address: ctx.bond, abi: BOND_ABI, functionName, args, value })
    return { result }
  } catch (e) {
    const r = revertOf(e)
    return { failed: r ? { reverted: true, ...r } : { reverted: false, error: e.shortMessage || e.message.split('\n')[0] } }
  }
}

/** The token as the pad has it: kind, creator, quote, pair and whether it trades on PancakeSwap yet. null when not the pad's. */
async function marketOf(ctx, token) {
  const kind = Number(await ctx.read(ctx.pad, PAD_ABI, 'kindOf', [token]))
  if (kind === 1) {
    const [creator, quote, , , , , graduated, , , , pair] = await ctx.read(ctx.pad, PAD_ABI, 'curves', [token])
    return { kind: 'v3', creator, quote, pair, live: graduated }
  }
  if (kind === 2) {
    const s = await ctx.read(ctx.pad, PAD_ABI, 'sales', [token])
    return { kind: 'fair', creator: s[0], quote: s[4], pair: s[11], live: s[6] }
  }
  return null
}

const symbolOf = async (ctx, token) => { try { return await ctx.read(token, ERC20_ABI, 'symbol') } catch { return null } }
const pctOfBps = (bps) => Number(bps) / 100
const tokens = (x) => formatUnits(x, 18)
const same = (a, b) => String(a).toLowerCase() === String(b).toLowerCase()
const ceilDiv = (a, b) => (a + b - 1n) / b

/** Display tier of a coverage (bps): ≥ 100% full cover badge, 50–100% bond badge, below 50% no badge. */
const tierOf = (bps) => (bps >= BPS ? 'full' : bps >= 5_000n ? 'bond' : 'none')
const TIER_NOTE = { full: '押金全覆盖: dumping X now loses money (bond ≥ what the sale fetches)', bond: '押金: bond covers 50–100% of what dumping X fetches', none: 'below 50% coverage: no badge on gang.fun (bond and coverage still shown)' }

async function nowOf(ctx) {
  return Number((await ctx.client.getBlock()).timestamp)
}

/** The bond and everything around it, formatted; raw fields kept under `_raw` for the commands. */
async function bondView(ctx, token, m) {
  const b = await ctx.read(ctx.bond, BOND_ABI, 'bondOf', [token])
  const state = STATES[Number(b.state)] ?? String(b.state)
  const quote = b.quote === zeroAddress ? m.quote : b.quote
  const [dec, sym, now] = await Promise.all([decimalsOf(ctx, quote), symbolOf(ctx, quote), nowOf(ctx)])
  const q = (x) => formatUnits(x, dec)
  const creator = b.creator === zeroAddress ? m.creator : b.creator
  const [bal, history] = await Promise.all([
    ctx.read(token, ERC20_ABI, 'balanceOf', [creator]),
    ctx.read(ctx.bond, BOND_ABI, 'historyOf', [creator]),
  ])
  const v = {
    token, kind: m.kind, creator, state, round: Number(b.round), quote: sym || quote,
    creatorHistory: { posted: Number(history[0]), honored: Number(history[1]), slashed: Number(history[2]) },
  }
  const raw = { bond: b, bal, quote, dec, now }
  if (state === 'none') return { ...v, _raw: raw }
  Object.assign(v, {
    bond: q(b.amount), holdTokens: tokens(b.holdAmount), holdPctOfSupply: Number((b.holdAmount * 1_000_000n) / TOTAL_SUPPLY) / 10_000,
    creatorBalance: tokens(bal), headroomTokens: bal >= b.holdAmount ? tokens(bal - b.holdAmount) : `-${tokens(b.holdAmount - bal)}`,
    postedAt: new Date(Number(b.postedAt) * 1000).toISOString(), deadline: new Date(Number(b.deadline) * 1000).toISOString(),
  })
  if (state === 'active') {
    const [violated, dump, cov] = await Promise.all([
      ctx.read(ctx.bond, BOND_ABI, 'isViolated', [token]),
      ctx.read(ctx.bond, BOND_ABI, 'dumpValue', [token]),
      ctx.read(ctx.bond, BOND_ABI, 'coverageBps', [token]),
    ])
    const left = Number(b.deadline) - now
    Object.assign(v, {
      violated, dumpValue: q(dump), coveragePct: cov === MAX_UINT ? null : pctOfBps(cov), tier: tierOf(cov), tierNote: TIER_NOTE[tierOf(cov)],
      toFullCover: dump > b.amount ? q(dump - b.amount) : '0',
      ...(left > 0 ? { secondsLeft: left, daysLeft: Math.round((left / DAY) * 10) / 10 } : { pastDeadline: true }),
      ...(violated && { note: `the creator holds less than X: anyone can report it (gang bond report --token ${token}) and take 1% of the bond` }),
      ...(!violated && left <= 0 && { note: `past the deadline and X is held: anyone can settle it (gang bond settle --token ${token}); the bond goes back to the creator. Until then it can still be reported if the balance drops below X` }),
    })
    Object.assign(raw, { dump, cov })
  }
  if (state === 'slashed') {
    const [ready, quoteIn, tokensOut] = await ctx.read(ctx.bond, BOND_ABI, 'previewBurn', [token])
    Object.assign(v, {
      burnLeft: q(b.burnLeft), burnDone: b.burnLeft === 0n,
      ...(b.burnLeft > 0n && { nextChunk: ready ? { quoteIn: q(quoteIn), tokensOut: tokens(tokensOut) } : null, nextChunkNote: ready ? 'gang bond burn --token … buys this chunk now' : 'not ready: the first call after a slash records a price observation, then the buy-back waits 10 minutes and skips while the price is more than 2% above its average (after 20 minutes without a call it starts over)' }),
    })
  }
  return { ...v, _raw: raw }
}

/** --hold: a token amount, or N% of the total supply (1,000,000,000). */
function parseHold(fail, raw) {
  const s = String(raw ?? '').trim()
  if (s.endsWith('%')) {
    const n = Number(s.slice(0, -1))
    if (!(n > 0 && n <= 100)) fail('--hold as a percentage must be above 0 and at most 100 (of the total supply)', { got: raw ?? null })
    return (TOTAL_SUPPLY * BigInt(Math.round(n * 10_000))) / 1_000_000n
  }
  return parseUnits(parseAmount(fail, 'hold', raw), 18)
}

const tokenArg = (opt, fail) => {
  const v = opt('token')
  if (!isAddress(v ?? '')) fail('--token must be a GangLaunchpad token address (0x…)', { got: v ?? null })
  return v
}

/** The pay side of post / topUp: BNB for a WBNB quote (value; --use-wbnb pays WBNB), otherwise approve to GangBond first. */
async function payment(ctx, me, quote, amount, sym, useWbnb, rawOnly, summarize) {
  if (same(quote, ctx.wbnb) && !useWbnb) {
    const native = await ctx.client.getBalance({ address: me })
    if (native < amount + GAS_RESERVE) {
      return { pre: { success: false, error: 'not enough BNB for this bond (native BNB must also cover gas)', haveBnb: formatUnits(native, 18), needBnb: formatUnits(amount, 18), reserveForGas: formatUnits(GAS_RESERVE, 18), hint: 'add --use-wbnb to pay from WBNB instead' } }
    }
    return { value: amount }
  }
  const pre = await fund(ctx, { me, token: quote, need: amount, spender: ctx.bond, sym, approveStep: 'approve-quote' }, rawOnly, summarize)
  return pre ? { pre } : { value: 0n }
}

const CLI_ONLY = 'the CLI refuses sells that would break the bond (gang v3 sell / gang fair sell), but a sell on the PancakeSwap site or another wallet is not stopped: it breaks the bond and anyone can report it'

// notes and follows are for trades and creates (gang.fun matches them to those txs); a bond tx carries none
const NOTE_FLAGS = ['note', 'conf', 'reveal-after', 'follow']

const SUBS = ['post', 'topup', 'raise-hold', 'extend', 'status', 'report', 'settle', 'burn', 'tx']
const USAGE = 'usage: gang bond <post|topup|raise-hold|extend|status|report|settle|burn|tx> --token <addr> [--testnet] — see gang help'

/** Entry for `gang bond <sub>`. io: { opt, flag, out, fail, summarize } from index.js. */
export async function runBond(sub, { opt, flag, out, fail, summarize }) {
  if (!SUBS.includes(sub)) return fail(USAGE, { got: sub ?? null })
  const noteFlag = NOTE_FLAGS.find((f) => flag(f))
  if (noteFlag) return fail(`--${noteFlag}: gang bond takes no notes or follows (they go on trades and creates); leave it out`)
  const testnet = flag('testnet')
  const net = testnet ? ' --testnet' : ''
  const rawOnly = flag('calldata')
  let ctx
  try { ctx = bondCtx(testnet) } catch (e) { return fail(e.message) }
  const chainId = Number(ctx.chainId)

  if (sub === 'tx') {
    const hash = opt('hash')
    if (!/^0x[0-9a-fA-F]{64}$/.test(hash ?? '')) fail('--hash must be a tx hash')
    const r = await ctx.client.waitForTransactionReceipt({ hash, timeout: 120_000 })
    const events = []
    for (const log of r.logs) {
      if (!same(log.address, ctx.bond)) continue
      try {
        const ev = decodeEventLog({ abi: BOND_ABI, data: log.data, topics: log.topics })
        events.push({ event: ev.eventName, ...Object.fromEntries(Object.entries(ev.args).map(([k, v]) => [k, typeof v === 'bigint' ? v.toString() : v])) })
      } catch { /* not a bond event */ }
    }
    return out({ success: true, chainId, hash, status: r.status, block: Number(r.blockNumber), events, explorer: `${ctx.explorer}/tx/${hash}` })
  }

  const token = tokenArg(opt, fail)
  const m = await marketOf(ctx, token)
  if (!m) return fail('not a GangLaunchpad token (V3 or 打新) on this network: bonds cover only those', { token, chainId })
  const view = await bondView(ctx, token, m)
  const { _raw: raw, ...pub } = view
  const b = raw.bond
  const qf = (x) => formatUnits(x, raw.dec)
  let wallet = null
  const me = () => (wallet ??= walletFor(ctx, opt('from')))
  const send = (functionName, args, extra, value = 0n) =>
    step(ctx, { from: me(), to: ctx.bond, data: encodeFunctionData({ abi: BOND_ABI, functionName, args }), value }, { chainId, token, bondContract: ctx.bond, ...extra }, rawOnly, summarize)

  if (sub === 'status') {
    return out({ success: true, chainId, bondContract: ctx.bond, ...pub, ...(!m.live && { note: `the token is not on PancakeSwap yet (${m.kind === 'v3' ? 'not graduated' : 'not launched'}): a bond can be posted after that` }) })
  }

  if (sub === 'report') {
    if (view.state !== 'active') return fail(HINTS.NotActive, { ...pub })
    if (!view.violated) return fail(HINTS.NotViolated, { creatorBalance: view.creatorBalance, holdTokens: view.holdTokens })
    const sim = await simulate(ctx, me(), 'report', [token])
    if (sim.failed) return out({ success: false, step: 'report', ...sim.failed })
    const self = same(me(), b.creator)
    const rewardBps = await ctx.read(ctx.bond, BOND_ABI, 'REPORTER_BPS')
    const reward = self ? 0n : (b.amount * rewardBps) / BPS
    return out(send('report', [token], {
      step: 'report', creator: b.creator, creatorBalance: view.creatorBalance, holdTokens: view.holdTokens, bond: view.bond, quote: view.quote,
      reward: qf(reward), rewardPct: self ? 0 : pctOfBps(rewardBps), burnAfter: qf(b.amount - reward),
      note: self ? 'the creator reporting itself gets no reward: the whole bond goes to buy-back' : `you get ${pctOfBps(rewardBps)}% of the bond; the rest buys the token back from its pair in chunks and burns it (gang bond burn)`,
    }))
  }

  if (sub === 'settle') {
    if (view.state !== 'active') return fail(HINTS.NotActive, { ...pub })
    if (raw.now < Number(b.deadline)) return fail(HINTS.NotDue, { deadline: view.deadline, secondsLeft: Number(b.deadline) - raw.now })
    if (view.violated) return fail(HINTS.Violated, { creatorBalance: view.creatorBalance, holdTokens: view.holdTokens, hint: `gang bond report --token ${token}${net}` })
    const sim = await simulate(ctx, me(), 'settle', [token])
    if (sim.failed) return out({ success: false, step: 'settle', ...sim.failed })
    return out(send('settle', [token], { step: 'settle', creator: b.creator, refund: view.bond, quote: view.quote, note: 'the bond goes back to the creator, whoever sends this' }))
  }

  if (sub === 'burn') {
    if (view.state !== 'slashed' || b.burnLeft === 0n) return fail(HINTS.NothingToBurn, { state: view.state, ...(view.burnLeft && { burnLeft: view.burnLeft }) })
    const slippage = parseNum(fail, 'slippage', opt('slippage', '1'), 0, 50)
    const [ready, quoteIn, tokensOut] = await ctx.read(ctx.bond, BOND_ABI, 'previewBurn', [token])
    // not ready: the call only records / waits. If a chunk has become buyable by the time it lands, the max minimum
    // makes it revert (Slippage) instead of buying unchecked: re-run for a priced preview
    const minOut = ready ? (tokensOut * BigInt(Math.round((100 - slippage) * 100))) / BPS : MAX_UINT
    const sim = await simulate(ctx, me(), 'burnChunk', [token, minOut])
    if (sim.failed) return out({ success: false, step: 'burn', ...sim.failed })
    return out(send('burnChunk', [token, minOut], {
      step: 'burn', burnLeft: view.burnLeft, quote: view.quote,
      ...(ready ? { chunkQuoteIn: qf(quoteIn), expectBurnTokens: tokens(tokensOut), minBurnTokens: tokens(minOut), slippagePct: slippage }
        : { note: 'no chunk this time: the call records the price observation (first call after a slash) or waits for the 10-minute average / a price no more than 2% above it. It is cheap; the platform keeper also calls it every 10 minutes. If a chunk becomes buyable before it lands, it reverts (Slippage) rather than buy without a minimum: re-run then' }),
    }))
  }

  // creator commands
  if (!m.live) return fail(HINTS.NotTradable, { token, kind: m.kind })
  if (!same(me(), m.creator)) return fail(HINTS.NotCreator, { wallet: me(), creator: m.creator })

  if (sub === 'post') {
    if (view.state === 'active' || (view.state === 'slashed' && b.burnLeft > 0n)) return fail(HINTS.BondLive, { ...pub })
    if (!flag('hold')) fail('--hold <tokens or N% of supply> required: the creator\'s balance must stay at least this until the deadline')
    if (flag('amount') === flag('cover')) fail('pass exactly one of --amount <quote> or --cover <coverage %> (e.g. --cover 100 for full cover)')
    const hold = parseHold(fail, opt('hold'))
    const days = parseIntIn(fail, 'days', opt('days'), 7, 90)
    if (hold > raw.bal) fail('--hold is above the creator\'s balance now', { hold: tokens(hold), balance: tokens(raw.bal) })
    const dump = await ctx.read(ctx.bond, BOND_ABI, 'quoteDump', [token, hold])
    const amount = flag('amount') ? parseUnits(parseAmount(fail, 'amount', opt('amount')), raw.dec)
      : ceilDiv(dump * BigInt(Math.round(parseNum(fail, 'cover', opt('cover'), 1, 1000) * 100)), BPS)
    if (amount === 0n) fail('the bond rounds to 0')
    // the contract checks 7–90 days against the block that mines it: an hour of slack below 90 days keeps --days 7 valid
    const deadline = BigInt(raw.now + days * DAY + (days < 90 ? 3600 : 0))
    const pay = await payment(ctx, me(), raw.quote, amount, view.quote, flag('use-wbnb'), rawOnly, summarize)
    if (pay.pre) return out(pay.pre)
    const sim = await simulate(ctx, me(), 'post', [token, amount, hold, deadline], pay.value)
    if (sim.failed) return out({ success: false, step: 'post', ...sim.failed })
    const cov = dump === 0n ? null : (amount * BPS) / dump
    return out(send('post', [token, amount, hold, deadline], {
      step: 'post', bond: qf(amount), quote: view.quote, payWith: pay.value ? 'BNB' : view.quote,
      holdTokens: tokens(hold), holdPctOfSupply: Number((hold * 1_000_000n) / TOTAL_SUPPLY) / 10_000, creatorBalance: tokens(raw.bal),
      days, deadline: new Date(Number(deadline) * 1000).toISOString(),
      dumpValue: qf(dump), coveragePct: cov == null ? null : pctOfBps(cov), tier: cov == null ? 'full' : tierOf(cov),
      toFullCover: dump > amount ? qf(dump - amount) : '0',
      warning: `until settled after the deadline, keep at least ${tokens(hold)} tokens in ${m.creator}: below that anyone can report it, the reporter takes 1% and the rest of the bond buys back and burns the token. There is no early withdrawal. ${CLI_ONLY}`,
    }, pay.value))
  }

  if (view.state !== 'active') return fail(HINTS.NotActive, { ...pub })

  if (sub === 'topup') {
    if (flag('amount') === flag('cover')) fail('pass exactly one of --amount <quote> or --cover <target coverage %>')
    let amount
    if (flag('amount')) amount = parseUnits(parseAmount(fail, 'amount', opt('amount')), raw.dec)
    else {
      const target = ceilDiv(raw.dump * BigInt(Math.round(parseNum(fail, 'cover', opt('cover'), 1, 1000) * 100)), BPS)
      if (target <= b.amount) return fail(`the bond already covers ${view.coveragePct}%: nothing to add for --cover ${opt('cover')}`, { bond: view.bond, dumpValue: view.dumpValue })
      amount = target - b.amount
    }
    const pay = await payment(ctx, me(), raw.quote, amount, view.quote, flag('use-wbnb'), rawOnly, summarize)
    if (pay.pre) return out(pay.pre)
    const sim = await simulate(ctx, me(), 'topUp', [token, amount], pay.value)
    if (sim.failed) return out({ success: false, step: 'topup', ...sim.failed })
    const total = b.amount + amount
    const cov = raw.dump === 0n ? null : (total * BPS) / raw.dump
    return out(send('topUp', [token, amount], {
      step: 'topup', add: qf(amount), bondAfter: qf(total), quote: view.quote, payWith: pay.value ? 'BNB' : view.quote,
      dumpValue: view.dumpValue, coveragePct: cov == null ? null : pctOfBps(cov), tier: cov == null ? 'full' : tierOf(cov), deadline: view.deadline,
      note: 'a bond can only grow: nothing comes back before settle',
    }, pay.value))
  }

  if (sub === 'raise-hold') {
    if (!flag('hold')) fail('--hold <tokens or N% of supply> required')
    const hold = parseHold(fail, opt('hold'))
    if (hold < b.holdAmount) fail('--hold is below the current X: X can only go up', { holdTokens: view.holdTokens })
    if (hold > raw.bal) fail('--hold is above the creator\'s balance now', { balance: view.creatorBalance })
    const sim = await simulate(ctx, me(), 'raiseHold', [token, hold])
    if (sim.failed) return out({ success: false, step: 'raise-hold', ...sim.failed })
    const dump = await ctx.read(ctx.bond, BOND_ABI, 'quoteDump', [token, hold])
    const cov = dump === 0n ? null : (b.amount * BPS) / dump
    return out(send('raiseHold', [token, hold], {
      step: 'raise-hold', holdBefore: view.holdTokens, holdAfter: tokens(hold), creatorBalance: view.creatorBalance,
      dumpValueAfter: qf(dump), coveragePctAfter: cov == null ? null : pctOfBps(cov), deadline: view.deadline,
      note: 'X can only go up; a higher X means dumping it fetches more, so the same bond covers less',
    }))
  }

  if (sub === 'extend') {
    const days = parseIntIn(fail, 'days', opt('days'), 1, 90)
    const deadline = BigInt(Number(b.deadline) + days * DAY)
    if (Number(deadline) > raw.now + 90 * DAY) fail('the new deadline would be more than 90 days from now', { deadline: view.deadline, maxDays: Math.floor((raw.now + 90 * DAY - Number(b.deadline)) / DAY) })
    const sim = await simulate(ctx, me(), 'extend', [token, deadline])
    if (sim.failed) return out({ success: false, step: 'extend', ...sim.failed })
    return out(send('extend', [token, deadline], {
      step: 'extend', deadlineBefore: view.deadline, deadlineAfter: new Date(Number(deadline) * 1000).toISOString(), coveragePct: view.coveragePct,
    }))
  }

  return fail(USAGE, { got: sub })
}

/**
 * Sell protection for the creator's own sells (gang v3 sell / gang fair sell in the pool). `p`: { token, me, amount,
 * breakBond, settleFirst, testnet }. Returns null when there is nothing to guard (no GangBond on this network, no active
 * bond, not the creator), else one of:
 * - { refuse: {…} } — the sell would leave less than X before the deadline (no --break-bond), or after the deadline
 *   before settle (no --settle-first): print it as the failure;
 * - { settleStep: {…} } — --settle-first after the deadline: send this settle first, then re-run the sell;
 * - { info: {…} } — go on, with these fields added to the preview (headroom after the sell, or the --break-bond warning).
 */
export async function bondGuard(ctx, p, rawOnly, summarize) {
  const addr = bondAddress(p.testnet)
  if (!addr) return null
  let b
  try { b = await ctx.read(addr, BOND_ABI, 'bondOf', [p.token]) } catch (e) {
    // never let an unread bond pass a sell that may break it
    if (p.breakBond) return null
    return { refuse: { error: 'cannot read this token\'s GangBond, so the sell is not checked against a bond', bondContract: addr, detail: e.shortMessage || e.message.split('\n')[0], hint: 're-run; --break-bond skips the check' } }
  }
  if (Number(b.state) !== 1 || !same(b.creator, p.me)) return null
  let bal, block, dec
  try {
    ;[bal, block, dec] = await Promise.all([ctx.read(p.token, ERC20_ABI, 'balanceOf', [p.me]), ctx.client.getBlock(), decimalsOf(ctx, b.quote)])
  } catch (e) {
    if (p.breakBond) return null
    return { refuse: { error: 'RPC error while checking the sell against your bond', bondContract: addr, detail: e.shortMessage || e.message.split('\n')[0], hint: 're-run; set GANG_RPC_URL / GANG_TESTNET_RPC_URL if the RPC keeps failing' } }
  }
  const after = bal > p.amount ? bal - p.amount : 0n
  const pastDeadline = Number(block.timestamp) >= Number(b.deadline)
  const base = {
    bondContract: addr, holdTokens: tokens(b.holdAmount), balanceBefore: tokens(bal), balanceAfter: tokens(after),
    bond: formatUnits(b.amount, dec), deadline: new Date(Number(b.deadline) * 1000).toISOString(),
  }
  if (after >= b.holdAmount) {
    return { info: { bondCheck: { ...base, headroomAfter: tokens(after - b.holdAmount), ...(pastDeadline && { note: 'past the deadline: settle the bond (gang bond settle) to get it back; until then it can still be reported if the balance drops below X' }) } } }
  }
  const net = p.testnet ? ' --testnet' : ''
  if (pastDeadline && bal >= b.holdAmount) {
    if (!p.settleFirst) {
      return { refuse: { error: `the bond is past its deadline but not settled: this sell leaves ${tokens(after)} tokens, below X (${tokens(b.holdAmount)}), and anyone could report it before you settle`, ...base, hint: `run gang bond settle --token ${p.token}${net} first, or add --settle-first to this sell` } }
    }
    const data = encodeFunctionData({ abi: BOND_ABI, functionName: 'settle', args: [p.token] })
    return { settleStep: step(ctx, { from: p.me, to: addr, data }, { step: 'settle', chainId: Number(ctx.chainId), token: p.token, refund: base.bond, ...base, note: 'settle first (the bond comes back to you); after executing, re-run the same sell' }, rawOnly, summarize) }
  }
  const lost = formatUnits(b.amount, dec)
  const consequence = `anyone can report it, the reporter takes 1% and the rest of the ${lost} bond buys back and burns the token`
  const warning = bal < b.holdAmount
    ? `the bond is already broken: you hold ${tokens(bal)} tokens, below the bonded X (${tokens(b.holdAmount)}), so ${consequence}. Selling more does not change that; buying back to X before anyone reports does`
    : `this sell leaves ${tokens(after)} tokens, below the bonded X (${tokens(b.holdAmount)}) before the bond is settled: ${consequence}. You lose the whole bond`
  if (!p.breakBond) return { refuse: { error: warning, ...base, maxSellKeepingBond: tokens(bal > b.holdAmount ? bal - b.holdAmount : 0n), hint: 'sell at most maxSellKeepingBond, or add --break-bond once the user accepts losing the bond' } }
  return { info: { bondCheck: { ...base, warning, brokeBond: true } } }
}
