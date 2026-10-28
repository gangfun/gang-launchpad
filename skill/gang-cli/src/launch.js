import { createHash } from 'node:crypto'
import { mkdirSync, readdirSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { createPublicClient, http, parseAbi, formatUnits, zeroAddress } from 'viem'
import { DIR } from './notes.js'
import { padNets, NOT_ON_MAINNET } from './gangpad.js'
import { bondAddress, BOND_ABI } from './bond.js'
import { walletFor } from './fair.js'
import { parseAmount, parseIntIn } from './steps.js'

/**
 * One command for a launch: `gang create … --dev-buy <quote> [--bond <quote> [--bond-hold <tokens|N%|all>] --bond-days <7-90>]`
 * (V3) and `gang fair create … [--shares <n>] --bond <quote> [--bond-hold …] --bond-days <7-90>` (打新: the dev buys its
 * shares in the create itself). Each run builds the next tx, as every other multi-step command does (wrap / approve
 * steps in between): run it, execute, run the same command again.
 *
 * Progress comes from the chain, not from what was executed: a plan file keeps the wallet, the name / symbol and the
 * pad's token count before the create, and each run looks for a token this wallet created with that symbol since then
 * (none yet → the create; found and the dev holds none → the V3 dev buy; holds some and no bond → the bond; else done).
 * The plan is written only once the create preview succeeds, and a run that finds no token never builds a second
 * create on its own (the first may still be landing): `--restart` does. The plan keeps the token once found (no rescan
 * on later runs) and is marked done at the end: a done launch only reports, even if the dev's balance or the bond
 * changed since (no second buy, bond or create) — for 7 days, then the plan expires.
 */

const LAUNCH_DIR = process.env.GANG_LAUNCH_DIR || join(dirname(DIR), 'launch')
const TTL_MS = 7 * 24 * 3600_000
const PAD_ABI = parseAbi([
  'function tokenCount() view returns (uint256)',
  'function allTokens(uint256) view returns (address)',
  'function kindOf(address token) view returns (uint8)',
  'function curves(address token) view returns (address creator, address quote, uint128 realQuote, uint128 sold, uint128 gradAmt, uint128 virtualQuote, bool graduated, uint16 buyTaxBps, uint16 sellTaxBps, uint16 dividendBps, address pair, address refPair)',
  'function sales(address token) view returns (address creator, uint64 progressAt, uint16 capShares, uint16 holdBps, address quote, uint16 sold, bool launched, uint16 mintFeeBps, uint16 exitFeeBps, address gate, uint128 sharePrice, address pair, address refPool, uint16 markSold)',
])
const ERC20_ABI = parseAbi(['function balanceOf(address) view returns (uint256)', 'function symbol() view returns (string)'])
/** Flags only the chain reads; everything else goes to the step's own command. */
export const LAUNCH_FLAGS = ['dev-buy', 'bond', 'bond-hold', 'bond-days', 'restart']
const NOTE_FLAGS = ['note', 'conf', 'reveal-after']
/** `gang fair create --dev-buy`, with or without --bond (index.js stops the lone flag, runLaunch the chained one). */
export const FAIR_DEV_BUY = 'a 打新 dev buys its shares in the create itself: use --shares <n> (not --dev-buy)'

/** The run asks for a chained launch (`kind` 'v3' | 'fair'). */
export const isLaunch = (kind, flag) => flag('bond') || (kind === 'v3' && flag('dev-buy'))

const planPath = (key) => join(LAUNCH_DIR, `${createHash('sha256').update(key).digest('hex').slice(0, 32)}.json`)

function readPlan(key) {
  try {
    const p = JSON.parse(readFileSync(planPath(key), 'utf8'))
    return p.createdAt > Date.now() - TTL_MS ? p : null
  } catch { return null }
}

function writePlan(key, plan) {
  mkdirSync(LAUNCH_DIR, { recursive: true, mode: 0o700 })
  for (const name of readdirSync(LAUNCH_DIR)) {
    const f = join(LAUNCH_DIR, name)
    try { if (Date.now() - statSync(f).mtimeMs > TTL_MS) unlinkSync(f) } catch { /* gone */ }
  }
  const p = planPath(key)
  writeFileSync(`${p}.${process.pid}.tmp`, JSON.stringify({ ...plan, createdAt: Date.now() }), { mode: 0o600 })
  renameSync(`${p}.${process.pid}.tmp`, p)
}

/** An argv reader over `base` (the real one) with `over` replacing / adding flags; a value of undefined drops one. */
function argsWith(base, over, drop = []) {
  const has = (n) => (n in over ? over[n] !== undefined : !drop.includes(n) && base.flag(n))
  return {
    flag: has,
    opt: (n, def) => (n in over ? (over[n] === undefined ? def : String(over[n])) : drop.includes(n) ? def : base.opt(n, def)),
  }
}

/**
 * Entry. `kind` 'v3' | 'fair'. deps: { io (index.js PAD_IO: opt, flag, out, fail, …), runV3, runFair, runBond, padNotes }.
 */
export async function runLaunch(kind, { io, runV3, runFair, runBond, padNotes }) {
  const { opt, flag, out, fail } = io
  const testnet = flag('testnet')
  const net = padNets(kind)[testnet ? 'testnet' : 'mainnet']
  if (!net.pad) return fail(NOT_ON_MAINNET)
  const name = opt('name'), symbol = opt('symbol')
  if (!name || !symbol) fail('--name and --symbol are required')
  if (flag('follow')) fail('--follow does not apply to a launch')
  if (kind === 'fair' && flag('dev-buy')) fail(FAIR_DEV_BUY)

  // everything checked before the create, so a launch never stops half way on a bad flag
  const devBuy = kind === 'v3' && flag('dev-buy') ? parseAmount(fail, 'dev-buy', opt('dev-buy')) : null
  const bonding = flag('bond')
  if (!bonding && (flag('bond-hold') || flag('bond-days'))) fail('--bond-hold / --bond-days go with --bond <quote>')
  let bond = null
  if (bonding) {
    if (flag('cover')) fail('--cover needs the PancakeSwap pair: a launch bonds before it, so give --bond <quote>')
    if (kind === 'v3' && !devBuy) fail('a V3 launch with --bond needs --dev-buy <quote>: the creator holds nothing until it buys on the curve')
    if (!bondAddress(testnet)) fail(`GangBond is not deployed on ${testnet ? 'the BSC testnet' : 'BSC mainnet'} in this CLI version: drop --bond (and --bond-hold / --bond-days), or add --testnet`)
    const hold = String(opt('bond-hold', 'all')).trim()
    if (!(hold === 'all' || /^(\d+(\.\d*)?|\.\d+)%?$/.test(hold)) || /^0*(\.0*)?%?$/.test(hold)) {
      fail('--bond-hold must be all (everything the dev holds), a token amount, or N% of the supply', { got: opt('bond-hold') })
    }
    bond = { amount: parseAmount(fail, 'bond', opt('bond')), hold, days: parseIntIn(fail, 'bond-days', opt('bond-days'), 7, 90) }
  }

  const client = createPublicClient({ chain: net.chain, transport: http(net.rpc) })
  const read = (address, abi, functionName, args = []) => client.readContract({ address, abi, functionName, args })
  const me = walletFor({ chainId: net.chainId }, opt('from'))
  const key = [net.chainId, net.pad, me.toLowerCase(), kind, name, symbol].join('|')
  const steps = [kind === 'v3' ? 'create' : 'create (dev shares included)', ...(devBuy ? ['dev-buy'] : []), ...(bond ? ['bond'] : [])]
  const rerun = 're-run this same command after executing it'
  const tag = (stage, extra = {}) => ({ launch: { stage, steps, ...extra } })
  const withTag = (stage, extra) => (o) => out({ ...o, ...tag(stage, extra) })

  let plan = flag('restart') ? null : readPlan(key)

  // ---- create
  if (!plan) {
    const startCount = (await read(net.pad, PAD_ABI, 'tokenCount')).toString()
    const createIo = {
      ...io,
      ...argsWith(io, {}, LAUNCH_FLAGS),
      out: (o) => {
        // the plan starts with the create tx itself: a wrap / approve step before it (or a failed preview) leaves none,
        // so the next run builds the create again
        const created = o.success && o.step === 'create'
        if (created) writePlan(key, { kind, name, symbol, me, chainId: net.chainId, pad: net.pad, startCount })
        return out({
          ...o,
          ...tag('create', created ? { next: `${rerun}: it finds the new token and continues with ${steps[1] ?? 'nothing'}` } : o.success ? { next: `${rerun}: it then builds the create` } : {}),
        })
      },
    }
    if (kind === 'v3') return runV3('create', { ...createIo, notes: padNotes('v3', 'create') })
    return runFair('create', { ...createIo, notes: padNotes('fair', 'create') })
  }

  // ---- the token this plan created: kept in the plan once found, else looked up from the pad's list since the plan
  let token = plan.token ?? null
  if (!token) {
    const count = Number(await read(net.pad, PAD_ABI, 'tokenCount'))
    for (let i = Number(plan.startCount); i < count && !token; i++) {
      const t = await read(net.pad, PAD_ABI, 'allTokens', [BigInt(i)])
      const k = Number(await read(net.pad, PAD_ABI, 'kindOf', [t]))
      const creator = k === 1 ? (await read(net.pad, PAD_ABI, 'curves', [t]))[0] : k === 2 ? (await read(net.pad, PAD_ABI, 'sales', [t]))[0] : zeroAddress
      if (creator.toLowerCase() !== me.toLowerCase()) continue
      if ((await read(t, ERC20_ABI, 'symbol')) === symbol) token = t
    }
    if (token) {
      plan = { ...plan, token }
      writePlan(key, plan)
    }
  }
  if (!token) {
    return out({
      success: false, ...tag('create'), error: 'no token from this launch yet',
      hint: `if the create was executed, wait for it to land and ${rerun.replace(' after executing it', '')}; if it was not (or its preview failed), add --restart to build the create again`,
    })
  }

  // later steps carry no note (it went on the create) and take the token from the plan
  const stepIo = (over) => ({ ...io, ...argsWith(io, { ...over, token }, [...LAUNCH_FLAGS, ...NOTE_FLAGS, 'name', 'symbol']) })
  const bal = await read(token, ERC20_ABI, 'balanceOf', [me])

  // ---- done: the report only, whatever happened to the balance or the bond since
  const report = () => {
    const done = {
      success: true, ...tag('done', { token, again: 'this launch is done; running the command again only reports it. Another token with the same name / symbol: add --restart' }),
      token, name, symbol, devBalance: formatUnits(bal, 18), chainId: Number(net.chainId),
    }
    if (!bond) return out({ ...done, note: `launched: gang ${kind} info --token ${token}${testnet ? ' --testnet' : ''}` })
    return runBond('status', { ...stepIo({}), out: (o) => out({ ...done, bondStatus: o, note: `launched and bonded: gang bond status --token ${token}${testnet ? ' --testnet' : ''}` }) })
  }
  if (plan.done) return report()

  // ---- V3 dev buy (a 打新 dev already holds its shares' tokens)
  if (devBuy && bal === 0n) {
    return runV3('buy', {
      ...stepIo({ amount: devBuy }), out: withTag('dev-buy', { token, next: `${rerun}${bond ? ': it continues with the bond' : ': the launch is then done'}` }),
      notes: padNotes('v3', 'buy', { note: null }),
    })
  }

  // ---- bond
  if (bond) {
    const b = await read(bondAddress(testnet), BOND_ABI, 'bondOf', [token])
    if (Number(b.round) === 0) {
      const hold = bond.hold === 'all' ? formatUnits(bal, 18) : bond.hold
      return runBond('post', {
        ...stepIo({ amount: bond.amount, hold, days: bond.days, cover: undefined }),
        out: withTag('bond', { token, next: `${rerun}: it reports the launch` }),
      })
    }
  }

  // ---- every step done: mark the plan, so later runs only report (never a second buy, bond or create)
  writePlan(key, { ...plan, done: true })
  return report()
}
