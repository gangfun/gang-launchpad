import { createPublicClient, http, parseAbi, encodeFunctionData, decodeErrorResult, decodeEventLog, formatUnits, parseEther, isAddress, zeroAddress } from 'viem'
import { bsc, bscTestnet } from 'viem/chains'
import { bawAddress, bawPreview } from './baw.js'
import { API } from './discover.js'
import { UA } from './version.js'

/**
 * `gang fair …` — 打新 (fair mint): fixed price per share, the last share launches the token on PancakeSwap at the
 * mint price; unfilled at the deadline → full refund. Contracts: gang-launchpad src/fair-mint.
 * Only on BSC testnet for now (--testnet); mainnet answers "not deployed" until there is a pad.
 */
export const FAIR_NETS = {
  mainnet: {
    chainId: '56', chain: bsc, pad: process.env.GANG_FAIR_PAD || null, // no mainnet pad yet
    rpc: process.env.GANG_RPC_URL || 'https://bsc-dataseed.binance.org',
    wbnb: '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c', explorer: 'https://bscscan.com',
  },
  testnet: {
    chainId: '97', chain: bscTestnet, pad: process.env.GANG_FAIR_TESTNET_PAD || '0x2f45c4814A540B0F6E9A25497DEc7B8C6CAA8963',
    rpc: process.env.GANG_FAIR_TESTNET_RPC_URL || 'https://bsc-testnet-rpc.publicnode.com',
    wbnb: '0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd', explorer: 'https://testnet.bscscan.com',
  },
}

const PAD_ABI = parseAbi([
  'function create(string name, string symbol, string logoURI, address quote, address refPool, (uint256 raiseBnb, uint16 capBps, uint32 duration, uint16 holdBps) cfg, uint256 devShares) returns (address)',
  'function mint(address token, uint256 shares, uint256 minShares) returns (uint256)',
  'function withdraw(address token, uint256 shares) returns (uint256)',
  'function refund(address token) returns (uint256)',
  'function sales(address token) view returns (address creator, uint64 deadline, uint16 capShares, uint16 holdBps, address quote, uint16 sold, bool launched, bool failed, address gate, uint128 sharePrice, uint128 escrowedFee, address pair, address refPool)',
  'function positions(address token, address user) view returns (uint16 shares, uint128 feePaid)',
  'function status(address token) view returns (uint8)',
  'function previewMint(address token, address user, uint256 shares) view returns (uint256 accepted, uint256 cost, uint256 fee)',
  'function previewCreate(address quote, address refPool, uint256 raiseBnb) view returns (uint256 raiseQuote, uint256 sharePrice)',
  'function checkConfig((uint256 raiseBnb, uint16 capBps, uint32 duration, uint16 holdBps) cfg, uint256 devShares) pure returns (bool ok, string reason)',
  'function taxHandler() view returns (address)',
  'function dividendVault() view returns (address)',
  'function agentIdRegistry() view returns (address)',
  'function agentGateEnabled() view returns (bool)',
  'function TOKENS_PER_SHARE() view returns (uint256)',
  'function TOTAL_SHARES() view returns (uint256)',
  'function FEE_BPS() view returns (uint256)',
  'error BadConfig(string reason)', 'error UnknownToken()', 'error NotMinting()', 'error NotFailed()', 'error ZeroAmount()',
  'error BadAmount()', 'error Slippage()', 'error WalletCapReached()', 'error NothingToRefund()', 'error NotAgent()',
  'error MigratorNotSet()', 'error ZeroAddress()', 'error RefPoolRequired()', 'error NoBridgePool()', 'error BridgeNotWbnb()',
  'error PriceTooSmall()', 'error FeeOnTransferQuote()', 'error VaultFloorTooHigh()',
  'error PoolNotFactory()', 'error QuoteNotInPool()', 'error PoolNoLiquidity()', 'error ThinReferencePool()', 'error GradAmtZero()',
  'event Created(address indexed token, address indexed creator, string name, string symbol, string logoURI, address indexed quote, address refPool, uint256 raiseBnb, uint256 sharePrice, uint256 capShares, uint256 deadline, uint256 holdBps)',
  'event Minted(address indexed token, address indexed user, uint256 shares, uint256 cost, uint256 fee, uint256 userShares, uint256 sold)',
  'event Withdrawn(address indexed token, address indexed user, uint256 shares, uint256 refund, uint256 fee, uint256 userShares, uint256 sold)',
  'event Launched(address indexed token, address indexed pair, address quote, uint256 tokenAmount, uint256 quoteAmount, uint256 feeToPlatform)',
  'event Failed(address indexed token, uint256 sold)',
  'event Refunded(address indexed token, address indexed user, uint256 amount)',
])
const HANDLER_ABI = parseAbi([
  'function isOut(address token, address user) view returns (bool)',
  'function eligibleShare(address token, address user) view returns (uint256)',
])
const VAULT_ABI = parseAbi([
  'function pending(address token, address user) view returns (uint256)',
  'function totalShares(address token) view returns (uint256)',
  'function claim(address token) returns (uint256)',
  'event DividendClaimed(address indexed token, address indexed user, uint256 amount)',
])
const ERC20_ABI = parseAbi([
  'function balanceOf(address) view returns (uint256)',
  'function allowance(address, address) view returns (uint256)',
  'function approve(address, uint256) returns (bool)',
  'function symbol() view returns (string)',
  'function decimals() view returns (uint8)',
])
const ERC721_ABI = parseAbi(['function balanceOf(address) view returns (uint256)'])
const WBNB_ABI = parseAbi(['function deposit() payable'])

const STATUS = ['none', 'minting', 'launched', 'failed']
// what to tell the agent for each pad error
const HINTS = {
  BadConfig: 'a rule is out of bounds: see reason',
  NotAgent: 'this wallet holds no Agent ID; fair mint is Agent-only',
  NotMinting: 'the sale is not open: it already launched, or its deadline passed (then `gang fair refund`)',
  NotFailed: 'refund only opens after the deadline of a sale that did not fill',
  WalletCapReached: 'this wallet already holds the per-wallet cap of shares',
  Slippage: 'fewer shares are left than --min-shares (someone filled first)',
  NothingToRefund: 'this wallet has no shares in this sale',
  BadAmount: '--shares is more than this wallet holds in the sale',
  FeeOnTransferQuote: 'the quote token takes a fee on transfer; it cannot be used',
  RefPoolRequired: 'this quote needs --ref-pool (a Pancake pool pricing it)',
  PriceTooSmall: 'the raise in this quote is too small to split into 10,000 shares',
}

export function fairCtx(testnet) {
  const net = FAIR_NETS[testnet ? 'testnet' : 'mainnet']
  if (!net.pad) {
    throw new Error('fair mint is not deployed on BSC mainnet yet — add --testnet to use the BSC testnet deployment')
  }
  const client = createPublicClient({ chain: net.chain, transport: http(net.rpc) })
  return { ...net, client, read: (address, abi, functionName, args = []) => client.readContract({ address, abi, functionName, args }) }
}

const units = async (ctx, token, amount) => {
  let d = 18
  try { d = Number(await ctx.read(token, ERC20_ABI, 'decimals')) } catch { /* 18 */ }
  return formatUnits(amount, d)
}
const symbolOf = async (ctx, token) => { try { return await ctx.read(token, ERC20_ABI, 'symbol') } catch { return null } }

/** Wallet address on the fair chain; the Agentic Wallet's EVM address is the same on every chain, so 56 is the fallback. */
export function walletFor(ctx, from) {
  if (from) return from
  try { return bawAddress(ctx.chainId) } catch { return bawAddress('56') }
}

/** Revert name (+ BadConfig reason) of a failed eth_call, or null when it was the RPC. */
function revertOf(e) {
  const raw = e?.walk?.((x) => typeof x?.data === 'string' && x.data.startsWith('0x'))?.data
  if (raw && raw.length >= 10) {
    try {
      const d = decodeErrorResult({ abi: PAD_ABI, data: raw })
      return { error: d.errorName, ...(d.args?.length && { reason: d.args[0] }), hint: HINTS[d.errorName] }
    } catch { /* not ours */ }
  }
  const named = e?.walk?.((x) => x?.data?.errorName)?.data?.errorName
  if (named) return { error: named, hint: HINTS[named] }
  if (e?.walk?.((x) => x?.code === 3 || /revert/i.test(x?.details || x?.shortMessage || ''))) return { error: 'execution reverted' }
  return null
}

/** Dry-run `data` from `from`; null when it would pass. */
async function dryRun(ctx, from, to, data, value = 0n) {
  try {
    await ctx.client.call({ account: from, to, data, value })
    return null
  } catch (e) {
    const r = revertOf(e)
    return r ? { reverted: true, ...r } : { reverted: false, error: e.shortMessage || e.message.split('\n')[0] }
  }
}

/** A sale as the pad stores it, plus derived fields. null when the token is not a fair-mint sale on this pad. */
export async function saleOf(ctx, token) {
  const s = await ctx.read(ctx.pad, PAD_ABI, 'sales', [token])
  if (s[0] === zeroAddress) return null
  const [creator, deadline, capShares, holdBps, quote, sold, launched, failed, gate, sharePrice, , pair] = s
  const status = STATUS[Number(await ctx.read(ctx.pad, PAD_ABI, 'status', [token]))]
  return {
    token, status, creator, quote, quoteSymbol: await symbolOf(ctx, quote), gate,
    deadline: Number(deadline), deadlineIso: new Date(Number(deadline) * 1000).toISOString(),
    secondsLeft: status === 'minting' ? Math.max(0, Number(deadline) - Math.floor(Date.now() / 1000)) : 0,
    capShares: Number(capShares), holdPct: Number(holdBps) / 100, sold: Number(sold), totalShares: 10_000,
    sharePriceRaw: sharePrice, sharePrice: await units(ctx, quote, sharePrice), launched, failed,
    pair: pair === zeroAddress ? null : pair,
  }
}

/**
 * A write step: either the raw tx (--calldata: no baw call; e.g. to sign elsewhere) or a baw preview.
 * Returns the object the command prints.
 */
function step(ctx, { from, to, data, value = 0n }, extra, rawOnly, summarize) {
  if (rawOnly) {
    return { success: true, ...extra, tx: { chainId: Number(ctx.chainId), from, to, data, value: value.toString() } }
  }
  const p = bawPreview({ from, to, value, data, chainId: ctx.chainId })
  // only an error about the chain itself: a generic network failure is not a reason to fall back to --calldata
  if (!p.success && new RegExp(`binanceChainId|unsupported chain|chain not supported|\\b${ctx.chainId}\\b`, 'i').test(JSON.stringify(p.error || ''))) {
    return {
      success: false, ...extra, error: p.error,
      hint: `the Agentic Wallet may not sign on chain ${ctx.chainId}: re-run with --calldata to get the raw tx`,
    }
  }
  return summarize(p, extra)
}

/** Quote funding for `need`: wrap BNB first (WBNB quote), then approve the pad. A step object, or null when ready. */
async function fundingStep(ctx, me, quote, need, sym, rawOnly, summarize) {
  const bal = await ctx.read(quote, ERC20_ABI, 'balanceOf', [me])
  if (bal < need) {
    if (quote.toLowerCase() !== ctx.wbnb.toLowerCase()) {
      return { success: false, error: `not enough ${sym || 'quote'}`, have: await units(ctx, quote, bal), need: await units(ctx, quote, need) }
    }
    const missing = need - bal
    const native = await ctx.client.getBalance({ address: me })
    if (native < missing) {
      return { success: false, error: 'not enough BNB', haveBnb: formatUnits(native, 18), needBnb: formatUnits(missing, 18) }
    }
    return step(ctx, { from: me, to: quote, data: encodeFunctionData({ abi: WBNB_ABI, functionName: 'deposit' }), value: missing },
      { step: 'wrap-bnb', wrap: formatUnits(missing, 18), note: 'after executing, re-run the same command' }, rawOnly, summarize)
  }
  const allowed = await ctx.read(quote, ERC20_ABI, 'allowance', [me, ctx.pad])
  if (allowed < need) {
    return step(ctx, { from: me, to: quote, data: encodeFunctionData({ abi: ERC20_ABI, functionName: 'approve', args: [ctx.pad, need] }) },
      { step: 'approve-quote', approve: await units(ctx, quote, need), spender: ctx.pad, note: 'after executing, re-run the same command' },
      rawOnly, summarize)
  }
  return null
}

const parseNum = (fail, name, raw, min, max) => {
  const n = Number(raw)
  if (raw == null || !Number.isFinite(n) || n < min || n > max) fail(`--${name} must be a number between ${min} and ${max}`, { got: raw })
  return n
}
const parseIntIn = (fail, name, raw, min, max) => {
  const n = Number(raw)
  if (!Number.isInteger(n) || n < min || n > max) fail(`--${name} must be an integer between ${min} and ${max}`, { got: raw })
  return n
}
const tokenArg = (opt, fail) => {
  const t = opt('token')
  if (!isAddress(t ?? '')) fail('--token must be the sale\'s token address (0x…)', { got: t ?? null })
  return t
}

/** Live position of `me` in a sale (reward fields once launched). */
async function positionOf(ctx, token, me, sale) {
  const [shares, feePaid] = await ctx.read(ctx.pad, PAD_ABI, 'positions', [token, me])
  const tps = await ctx.read(ctx.pad, PAD_ABI, 'TOKENS_PER_SHARE')
  const baseline = BigInt(shares) * tps
  const pos = {
    shares: Number(shares), mintFeePaid: await units(ctx, sale.quote, feePaid), baselineTokens: formatUnits(baseline, 18),
  }
  if (!sale.launched || !shares) return pos
  const [handler, vault] = await Promise.all([ctx.read(ctx.pad, PAD_ABI, 'taxHandler'), ctx.read(ctx.pad, PAD_ABI, 'dividendVault')])
  const [out, weight, pending, total, bal] = await Promise.all([
    ctx.read(handler, HANDLER_ABI, 'isOut', [token, me]),
    ctx.read(handler, HANDLER_ABI, 'eligibleShare', [token, me]),
    ctx.read(vault, VAULT_ABI, 'pending', [token, me]),
    ctx.read(vault, VAULT_ABI, 'totalShares', [token]),
    ctx.read(token, ERC20_ABI, 'balanceOf', [me]),
  ])
  const line = (baseline * BigInt(Math.round(sale.holdPct * 100))) / 10_000n
  return {
    ...pos,
    balance: formatUnits(bal, 18),
    reward: out ? 'out' : 'earning',
    holdLineTokens: formatUnits(line, 18),
    sellableBeforeOut: !out && bal > line ? formatUnits(bal - line, 18) : '0',
    poolSharePct: total > 0n ? Number((weight * 1_000_000n) / total) / 10_000 : 0,
    pendingReward: await units(ctx, sale.quote, pending),
    ...(out && { note: 'out for good: fell below the hold line once; buying back does not restore it' }),
  }
}

/**
 * Entry for `gang fair <sub>`. io: { args, opt, flag, out, fail, summarize } from index.js
 * (summarize = summarizePreview, so previews look like every other command's).
 */
const SUBS = ['list', 'info', 'status', 'create', 'mint', 'withdraw', 'refund', 'claim', 'tx']
const USAGE = 'usage: gang fair <list|info|status|create|mint|withdraw|refund|claim|tx> [--testnet] — see gang help'

export async function runFair(sub, { opt, flag, out, fail, summarize, resolveLogo }) {
  if (!SUBS.includes(sub)) return fail(USAGE, { got: sub ?? null })
  // agent notes are matched to curve trades / creates on the server; fair-mint txs are not indexed there yet
  if (flag('note') || flag('follow')) return fail('--note / --follow are not supported on gang fair yet: the server cannot match them to a fair-mint tx; leave them out')
  const testnet = flag('testnet')
  const rawOnly = flag('calldata')
  if (sub === 'list') {
    const status = opt('status', 'minting')
    if (!['minting', 'launched', 'failed', 'all'].includes(status)) fail('--status must be minting, launched, failed or all')
    const r = await fetch(`${API}/fair/sales?status=${status}&limit=30`, { headers: { 'user-agent': UA }, signal: AbortSignal.timeout(10_000) })
      .then((x) => (x.ok ? x.json() : { error: x.status })).catch((e) => ({ error: e.message }))
    if (r.error) return out({ success: false, error: `gang.fun fair list unavailable (${r.error})`, hint: `use gang fair info --token <addr>${testnet ? ' --testnet' : ''} for one sale` })
    return out({ success: true, status, items: (r.items || []).map((x) => ({
      token: x.address, symbol: x.symbol, status: x.status, sold: x.sold, participants: x.participants,
      sharePrice: x.sharePrice && formatUnits(BigInt(x.sharePrice), 18), quote: x.quoteSymbol, deadline: x.deadline, chainId: x.chainId,
      link: `https://gang.fun/mint/${x.address}`,
    })) })
  }

  let ctx
  try { ctx = fairCtx(testnet) } catch (e) { return fail(e.message) }

  if (sub === 'info' || sub === 'status') {
    const token = tokenArg(opt, fail)
    const sale = await saleOf(ctx, token)
    if (!sale) return fail('not a fair-mint sale on this pad', { token, chainId: ctx.chainId })
    const { sharePriceRaw: _raw, ...pub } = sale
    if (sub === 'info') return out({ success: true, chainId: Number(ctx.chainId), ...pub })
    const me = walletFor(ctx, opt('from'))
    return out({ success: true, chainId: Number(ctx.chainId), wallet: me, sale: pub, position: await positionOf(ctx, token, me, sale) })
  }

  if (sub === 'create') {
    const name = opt('name'), symbol = opt('symbol')
    if (!name || !symbol) fail('--name and --symbol are required')
    const raise = parseNum(fail, 'raise', opt('raise', '15'), 5, 50)
    const capPct = parseNum(fail, 'cap', opt('cap', '0.5'), 0.1, 0.5)
    const hours = parseNum(fail, 'hours', opt('hours', '24'), 1, 72)
    const holdPct = parseNum(fail, 'hold', opt('hold', '50'), 30, 80)
    const devShares = parseIntIn(fail, 'shares', opt('shares', '1'), 1, Math.round(capPct * 200))
    const quote = flag('quote') ? opt('quote') : ctx.wbnb
    const refPool = flag('ref-pool') ? opt('ref-pool') : zeroAddress
    if (!isAddress(quote ?? '') || !isAddress(refPool ?? '')) fail('--quote / --ref-pool must be 0x addresses')
    const cfg = { raiseBnb: parseEther(String(raise)), capBps: Math.round(capPct * 100), duration: Math.round(hours * 3600), holdBps: Math.round(holdPct * 100) }
    const [ok, reason] = await ctx.read(ctx.pad, PAD_ABI, 'checkConfig', [cfg, BigInt(devShares)])
    if (!ok) fail(`rule out of bounds: ${reason}`)
    let priced
    try { priced = await ctx.read(ctx.pad, PAD_ABI, 'previewCreate', [quote, refPool, cfg.raiseBnb]) } catch (e) {
      return fail('cannot price the raise in this quote', revertOf(e) || { detail: e.shortMessage || e.message })
    }
    const [raiseQuote, sharePrice] = priced
    const sym = await symbolOf(ctx, quote)
    const fee = (sharePrice * BigInt(devShares) * 100n) / 10_000n
    const need = sharePrice * BigInt(devShares) + fee
    const me = walletFor(ctx, opt('from'))
    const pre = await fundingStep(ctx, me, quote, need, sym, rawOnly, summarize)
    if (pre) return out(pre)
    // logoURI is permanent on-chain: same handling as `gang create` (--logo file upload, other hosts copied to gang.fun).
    // Done after the setup steps so a wrap / approve round does not upload the image twice.
    const logo = await resolveLogo()
    const data = encodeFunctionData({ abi: PAD_ABI, functionName: 'create', args: [name, symbol, logo.logoURI, quote, refPool, cfg, BigInt(devShares)] })
    const dry = await dryRun(ctx, me, ctx.pad, data)
    if (dry) return out({ success: false, step: 'create', ...dry })
    return out(step(ctx, { from: me, to: ctx.pad, data }, {
      step: 'create', chainId: Number(ctx.chainId), name, symbol, logoURI: logo.logoURI, ...(logo.uploaded && { uploaded: true }), quote: sym || quote,
      raise: await units(ctx, quote, raiseQuote), sharePrice: await units(ctx, quote, sharePrice),
      capShares: cfg.capBps * 2, minWallets: Math.ceil(10_000 / (cfg.capBps * 2)), hours, holdPct, devShares,
      devCost: await units(ctx, quote, need),
    }, rawOnly, summarize))
  }

  if (sub === 'mint') {
    const token = tokenArg(opt, fail)
    const want = parseIntIn(fail, 'shares', opt('shares'), 1, 10_000)
    const sale = await saleOf(ctx, token)
    if (!sale) return fail('not a fair-mint sale on this pad', { token })
    if (sale.status !== 'minting') return fail(`sale is ${sale.status}, not minting`, { hint: sale.status === 'failed' ? `gang fair refund --token ${token}${testnet ? ' --testnet' : ''}` : undefined })
    const me = walletFor(ctx, opt('from'))
    if (sale.gate !== zeroAddress && (await ctx.read(sale.gate, ERC721_ABI, 'balanceOf', [me])) === 0n) {
      return fail('this wallet holds no Agent ID; fair mint is Agent-only', { wallet: me })
    }
    const [accepted, cost, fee] = await ctx.read(ctx.pad, PAD_ABI, 'previewMint', [token, me, BigInt(want)])
    if (accepted === 0n) return fail('no shares available to this wallet (cap reached or sold out)', { capShares: sale.capShares })
    const minShares = flag('min-shares') ? parseIntIn(fail, 'min-shares', opt('min-shares'), 1, Number(accepted)) : Number(accepted)
    const need = cost + fee
    const pre = await fundingStep(ctx, me, sale.quote, need, sale.quoteSymbol, rawOnly, summarize)
    if (pre) return out(pre)
    const data = encodeFunctionData({ abi: PAD_ABI, functionName: 'mint', args: [token, accepted, BigInt(minShares)] })
    const dry = await dryRun(ctx, me, ctx.pad, data)
    if (dry) return out({ success: false, step: 'mint', ...dry })
    const fills = sale.sold + Number(accepted) === 10_000
    return out(step(ctx, { from: me, to: ctx.pad, data }, {
      step: 'mint', chainId: Number(ctx.chainId), token, shares: Number(accepted), ...(Number(accepted) < want && { truncatedFrom: want }),
      cost: await units(ctx, sale.quote, cost), fee: await units(ctx, sale.quote, fee), quote: sale.quoteSymbol,
      soldAfter: sale.sold + Number(accepted), ...(fills && { launches: 'this mint fills the sale and launches the token (higher gas)' }),
    }, rawOnly, summarize))
  }

  if (sub === 'withdraw') {
    const token = tokenArg(opt, fail)
    const sale = await saleOf(ctx, token)
    if (!sale) return fail('not a fair-mint sale on this pad', { token })
    if (sale.status !== 'minting') return fail(`sale is ${sale.status}: withdraw only while minting`)
    const me = walletFor(ctx, opt('from'))
    const [held] = await ctx.read(ctx.pad, PAD_ABI, 'positions', [token, me])
    if (!held) return fail('this wallet has no shares in this sale')
    const shares = flag('all') ? Number(held) : parseIntIn(fail, 'shares', opt('shares'), 1, Number(held))
    const principal = sale.sharePriceRaw * BigInt(shares)
    const data = encodeFunctionData({ abi: PAD_ABI, functionName: 'withdraw', args: [token, BigInt(shares)] })
    const dry = await dryRun(ctx, me, ctx.pad, data)
    if (dry) return out({ success: false, step: 'withdraw', ...dry })
    return out(step(ctx, { from: me, to: ctx.pad, data }, {
      step: 'withdraw', chainId: Number(ctx.chainId), token, shares,
      receive: await units(ctx, sale.quote, principal - principal / 100n), quote: sale.quoteSymbol,
      note: 'principal − 1%; the 1% paid at mint is not returned',
    }, rawOnly, summarize))
  }

  if (sub === 'refund') {
    const token = tokenArg(opt, fail)
    const sale = await saleOf(ctx, token)
    if (!sale) return fail('not a fair-mint sale on this pad', { token })
    if (sale.status !== 'failed') return fail(`sale is ${sale.status}: refund opens after a deadline passes without a fill`)
    const me = walletFor(ctx, opt('from'))
    const [held, feePaid] = await ctx.read(ctx.pad, PAD_ABI, 'positions', [token, me])
    if (!held) return fail('this wallet has nothing to refund in this sale')
    const data = encodeFunctionData({ abi: PAD_ABI, functionName: 'refund', args: [token] })
    const dry = await dryRun(ctx, me, ctx.pad, data)
    if (dry) return out({ success: false, step: 'refund', ...dry })
    return out(step(ctx, { from: me, to: ctx.pad, data }, {
      step: 'refund', chainId: Number(ctx.chainId), token, shares: Number(held),
      receive: await units(ctx, sale.quote, sale.sharePriceRaw * BigInt(held) + feePaid), quote: sale.quoteSymbol,
    }, rawOnly, summarize))
  }

  if (sub === 'claim') {
    const token = tokenArg(opt, fail)
    const sale = await saleOf(ctx, token)
    if (!sale) return fail('not a fair-mint sale on this pad', { token })
    const me = walletFor(ctx, opt('from'))
    const vault = await ctx.read(ctx.pad, PAD_ABI, 'dividendVault')
    const pending = await ctx.read(vault, VAULT_ABI, 'pending', [token, me])
    if (pending === 0n) return fail('nothing to claim yet', { hint: `gang fair status --token ${token}${testnet ? ' --testnet' : ''}` })
    const data = encodeFunctionData({ abi: VAULT_ABI, functionName: 'claim', args: [token] })
    return out(step(ctx, { from: me, to: vault, data }, {
      step: 'claim', chainId: Number(ctx.chainId), token, amount: await units(ctx, sale.quote, pending), quote: sale.quoteSymbol,
    }, rawOnly, summarize))
  }

  if (sub === 'tx') {
    const hash = opt('hash')
    if (!/^0x[0-9a-fA-F]{64}$/.test(hash ?? '')) fail('--hash must be a tx hash')
    const r = await ctx.client.waitForTransactionReceipt({ hash, timeout: 120_000 })
    const events = []
    for (const log of r.logs) {
      for (const abi of [PAD_ABI, VAULT_ABI]) {
        try {
          const ev = decodeEventLog({ abi, data: log.data, topics: log.topics })
          events.push({ event: ev.eventName, ...Object.fromEntries(Object.entries(ev.args).map(([k, v]) => [k, typeof v === 'bigint' ? v.toString() : v])) })
          break
        } catch { /* other contract / event */ }
      }
    }
    return out({ success: true, chainId: Number(ctx.chainId), hash, status: r.status, block: Number(r.blockNumber), events, explorer: `${ctx.explorer}/tx/${hash}` })
  }

  return fail(USAGE, { got: sub })
}
