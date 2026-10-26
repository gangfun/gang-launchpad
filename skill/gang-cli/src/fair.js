import { createPublicClient, http, parseAbi, encodeFunctionData, decodeEventLog, formatUnits, parseEther, isAddress, zeroAddress } from 'viem'
import { bsc, bscTestnet } from 'viem/chains'
import { bawAddress } from './baw.js'
import { fundingStep as fund, parseIntIn, parseNum, revertOf as revertIn, ROUTER_ABI, routerDeadline, step, units, viaRouter, GAS_RESERVE } from './steps.js'
import { API } from './discover.js'
import { UA } from './version.js'

/**
 * `gang fair …` — 打新 (fair mint): one fixed price per share both ways (mint buys at it, withdraw sells back at it);
 * the last share launches the token on PancakeSwap at that price. No deadline, no refund: a sale stays open until it
 * fills. Contracts: gang-launchpad src/fair-mint.
 * Only on BSC testnet for now (--testnet); mainnet answers "not deployed" until there is a pad.
 */
export const FAIR_NETS = {
  mainnet: {
    chainId: '56', chain: bsc, pad: process.env.GANG_FAIR_PAD || null, // no mainnet pad yet
    rpc: process.env.GANG_RPC_URL || 'https://bsc-dataseed.binance.org',
    wbnb: '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c', explorer: 'https://bscscan.com',
    router: process.env.GANG_ROUTER || null,
  },
  testnet: {
    chainId: '97', chain: bscTestnet, pad: process.env.GANG_FAIR_TESTNET_PAD || '0xf1438254098aA1E0A6Ac58b204CfBa68A2383017',
    router: process.env.GANG_ROUTER_TESTNET || '0x5627EeA369eEa6e4Cf50E67DabF1DF0ae75B13a5',
    rpc: process.env.GANG_FAIR_TESTNET_RPC_URL || 'https://bsc-testnet-rpc.publicnode.com',
    wbnb: '0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd', explorer: 'https://testnet.bscscan.com',
  },
}

const PAD_ABI = parseAbi([
  'function create(string name, string symbol, string logoURI, string metaURI, address quote, address refPool, (uint256 raiseBnb, uint16 capBps, uint16 holdBps, uint16 mintFeeBps, uint16 exitFeeBps) cfg, uint256 devShares) returns (address)',
  'function mint(address token, uint256 shares, uint256 minShares) returns (uint256)',
  'function withdraw(address token, uint256 shares) returns (uint256)',
  'function sales(address token) view returns (address creator, uint64 lastMintAt, uint16 capShares, uint16 holdBps, address quote, uint16 sold, bool launched, uint16 mintFeeBps, uint16 exitFeeBps, address gate, uint128 sharePrice, address pair, address refPool)',
  'function positions(address token, address user) view returns (uint16 shares)',
  'function previewWithdraw(address token, address user, uint256 shares) view returns (uint256 payout, uint256 fee)',
  'function exitFeeBpsOf(address token) view returns (uint256)',
  'function STALE_AFTER() view returns (uint256)',
  'function status(address token) view returns (uint8)',
  'function previewMint(address token, address user, uint256 shares) view returns (uint256 accepted, uint256 cost, uint256 fee)',
  'function previewCreate(address quote, address refPool, uint256 raiseBnb) view returns (uint256 raiseQuote, uint256 sharePrice)',
  'function checkConfig((uint256 raiseBnb, uint16 capBps, uint16 holdBps, uint16 mintFeeBps, uint16 exitFeeBps) cfg, uint256 devShares) pure returns (bool ok, string reason)',
  'function taxHandler() view returns (address)',
  'function dividendVault() view returns (address)',
  'function agentIdRegistry() view returns (address)',
  'function agentGateEnabled() view returns (bool)',
  'function TOKENS_PER_SHARE() view returns (uint256)',
  'function TOTAL_SHARES() view returns (uint256)',
  'error BadConfig(string reason)', 'error UnknownToken()', 'error NotMinting()', 'error ZeroAmount()',
  'error BadAmount()', 'error Slippage()', 'error WalletCapReached()', 'error NotAgent()', 'error OutOfGas()',
  'error MigratorNotSet()', 'error ZeroAddress()', 'error RefPoolRequired()', 'error NoBridgePool()', 'error BridgeNotWbnb()',
  'error PriceTooSmall()', 'error FeeOnTransferQuote()', 'error VaultFloorTooHigh()', 'error QuoteNotAllowed()',
  'error RouterNeedsGate()',
  'error PoolNotFactory()', 'error QuoteNotInPool()', 'error PoolNoLiquidity()', 'error ThinReferencePool()', 'error GradAmtZero()',
  'event Created(address indexed token, address indexed creator, string name, string symbol, string logoURI, address indexed quote, address refPool, uint256 raiseBnb, uint256 sharePrice, uint256 capShares, uint256 holdBps, uint256 mintFeeBps, uint256 exitFeeBps)',
  'event Minted(address indexed token, address indexed user, uint256 shares, uint256 cost, uint256 fee, uint256 userShares, uint256 sold)',
  'event Withdrawn(address indexed token, address indexed user, uint256 shares, uint256 payout, uint256 fee, uint256 userShares, uint256 sold)',
  'event Launched(address indexed token, address indexed pair, address quote, uint256 tokenAmount, uint256 quoteAmount)',
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
  'function symbol() view returns (string)',
])
const ERC721_ABI = parseAbi(['function balanceOf(address) view returns (uint256)'])

const STATUS = ['none', 'minting', 'launched']
// what to tell the agent for each pad error
const HINTS = {
  BadConfig: 'a rule is out of bounds: see reason',
  NotAgent: 'this wallet holds no Agent ID; fair mint is Agent-only',
  NotMinting: 'the sale already launched: trade the token on PancakeSwap',
  WalletCapReached: 'this wallet already holds the per-wallet cap of shares',
  Slippage: 'fewer shares are left than --min-shares (someone filled first)',
  BadAmount: '--shares is more than this wallet holds in the sale',
  FeeOnTransferQuote: 'the quote token takes a fee on transfer; it cannot be used',
  RefPoolRequired: 'this quote needs --ref-pool (a Pancake pool pricing it)',
  PriceTooSmall: 'the raise in this quote is too small to split into 10,000 shares',
  QuoteNotAllowed: '--quote is not on gang\'s quote whitelist (WBNB, or a listed 18-decimal token with a fixed rate, such as USDT); leave it out to use WBNB',
  RouterNeedsGate: 'this sale has no Agent gate, so the router path is off; re-run with --use-wbnb to mint directly',
}

export function fairCtx(testnet) {
  const net = FAIR_NETS[testnet ? 'testnet' : 'mainnet']
  if (!net.pad) {
    throw new Error('fair mint is not deployed on BSC mainnet yet — add --testnet to use the BSC testnet deployment')
  }
  const client = createPublicClient({ chain: net.chain, transport: http(net.rpc) })
  return { ...net, client, read: (address, abi, functionName, args = []) => client.readContract({ address, abi, functionName, args }) }
}

const symbolOf = async (ctx, token) => { try { return await ctx.read(token, ERC20_ABI, 'symbol') } catch { return null } }

/** Wallet address on the fair chain; the Agentic Wallet's EVM address is the same on every chain, so 56 is the fallback. */
export function walletFor(ctx, from) {
  if (from) return from
  try { return bawAddress(ctx.chainId) } catch { return bawAddress('56') }
}

/** Revert name (+ BadConfig reason) of a failed eth_call, or null when it was the RPC. */
const revertOf = (e) => revertIn(e, [PAD_ABI, ROUTER_ABI], HINTS)

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
  const [creator, lastMintAt, capShares, holdBps, quote, sold, launched, mintFeeBps, exitFeeBps, gate, sharePrice, pair] = s
  const [st, exitNowBps, staleAfter] = await Promise.all([
    ctx.read(ctx.pad, PAD_ABI, 'status', [token]), ctx.read(ctx.pad, PAD_ABI, 'exitFeeBpsOf', [token]),
    ctx.read(ctx.pad, PAD_ABI, 'STALE_AFTER'),
  ])
  const status = STATUS[Number(st)]
  const left = 10_000 - Number(sold)
  return {
    token, status, creator, quote, quoteSymbol: await symbolOf(ctx, quote), gate,
    capShares: Number(capShares), holdPct: Number(holdBps) / 100, sold: Number(sold), totalShares: 10_000,
    // no deadline: what a fill still needs, and how long until withdraws stop paying the exit fee
    sharesLeft: left, minWalletsLeft: Math.ceil(left / Number(capShares)),
    lastMintAt: Number(lastMintAt), lastMintIso: new Date(Number(lastMintAt) * 1000).toISOString(),
    stale: !launched && Number(exitNowBps) === 0,
    exitFeeFreeIn: launched ? 0 : Math.max(0, Number(lastMintAt) + Number(staleAfter) - Math.floor(Date.now() / 1000)),
    mintFeePct: Number(mintFeeBps) / 100, exitFeePct: Number(exitFeeBps) / 100, exitFeeNowPct: Number(exitNowBps) / 100,
    exitFeeBps: Number(exitFeeBps),
    sharePriceRaw: sharePrice, sharePrice: await units(ctx, quote, sharePrice), launched,
    pair: pair === zeroAddress ? null : pair,
  }
}

/** Quote funding for `need` toward the pad (wrap BNB, then approve): a step object, or null when ready. */
const fundingStep = (ctx, me, quote, need, sym, rawOnly, summarize) =>
  fund(ctx, { me, token: quote, need, spender: ctx.pad, sym }, rawOnly, summarize)

const tokenArg = (opt, fail) => {
  const t = opt('token')
  if (!isAddress(t ?? '')) fail('--token must be the sale\'s token address (0x…)', { got: t ?? null })
  return t
}

/** Live position of `me` in a sale (reward fields once launched). */
async function positionOf(ctx, token, me, sale) {
  const shares = await ctx.read(ctx.pad, PAD_ABI, 'positions', [token, me])
  const tps = await ctx.read(ctx.pad, PAD_ABI, 'TOKENS_PER_SHARE')
  const baseline = BigInt(shares) * tps
  const pos = { shares: Number(shares), baselineTokens: formatUnits(baseline, 18) }
  if (!sale.launched && shares) {
    const [payout] = await ctx.read(ctx.pad, PAD_ABI, 'previewWithdraw', [token, me, BigInt(shares)])
    pos.sellBackAll = await units(ctx, sale.quote, payout) // what `gang fair withdraw --all` pays now
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
const SUBS = ['list', 'info', 'status', 'create', 'mint', 'withdraw', 'claim', 'tx']
const USAGE = 'usage: gang fair <list|info|status|create|mint|withdraw|claim|tx> [--testnet] — see gang help'

export async function runFair(sub, { opt, flag, out, fail, summarize, resolveLogo, checkMeta, resolveMeta }) {
  if (!SUBS.includes(sub)) return fail(USAGE, { got: sub ?? null })
  // agent notes are matched to curve trades / creates on the server; fair-mint txs are not indexed there yet
  if (flag('note') || flag('follow')) return fail('--note / --follow are not supported on gang fair yet: the server cannot match them to a fair-mint tx; leave them out')
  const testnet = flag('testnet')
  const rawOnly = flag('calldata')
  if (sub === 'list') {
    const status = opt('status', 'minting')
    if (!['minting', 'launched', 'all'].includes(status)) fail('--status must be minting, launched or all')
    const r = await fetch(`${API}/fair/sales?status=${status}&limit=30`, { headers: { 'user-agent': UA }, signal: AbortSignal.timeout(10_000) })
      .then((x) => (x.ok ? x.json() : { error: x.status })).catch((e) => ({ error: e.message }))
    if (r.error) return out({ success: false, error: `gang.fun fair list unavailable (${r.error})`, hint: `use gang fair info --token <addr>${testnet ? ' --testnet' : ''} for one sale` })
    return out({ success: true, status, items: (r.items || []).map((x) => ({
      token: x.address, symbol: x.symbol, status: x.status, sold: x.sold, participants: x.participants,
      sharePrice: x.sharePrice && formatUnits(BigInt(x.sharePrice), 18), quote: x.quoteSymbol, chainId: x.chainId,
      sharesLeft: x.sharesLeft ?? null, minWalletsLeft: x.minWalletsLeft ?? null, lastMintAt: x.lastMintAt ?? null, stale: x.stale ?? null,
      link: `https://gang.fun/mint/${x.address}`,
    })) })
  }

  let ctx
  try { ctx = fairCtx(testnet) } catch (e) { return fail(e.message) }

  if (sub === 'info' || sub === 'status') {
    const token = tokenArg(opt, fail)
    const sale = await saleOf(ctx, token)
    if (!sale) return fail('not a fair-mint sale on this pad', { token, chainId: ctx.chainId })
    const { sharePriceRaw: _raw, exitFeeBps: _exit, ...pub } = sale
    if (sub === 'info') return out({ success: true, chainId: Number(ctx.chainId), ...pub })
    const me = walletFor(ctx, opt('from'))
    return out({ success: true, chainId: Number(ctx.chainId), wallet: me, sale: pub, position: await positionOf(ctx, token, me, sale) })
  }

  if (sub === 'create') {
    const name = opt('name'), symbol = opt('symbol')
    if (!name || !symbol) fail('--name and --symbol are required')
    checkMeta() // a bad --website / --twitter / --description fails here, before any wrap / approve round or upload
    const raise = parseNum(fail, 'raise', opt('raise', '15'), 5, 50)
    if (flag('hours')) fail('--hours was removed: a fair-mint sale has no deadline and stays open until it fills')
    const capPct = parseNum(fail, 'cap', opt('cap', '0.5'), 0.25, 0.5)
    const holdPct = parseNum(fail, 'hold', opt('hold', '50'), 30, 80)
    const mintFeePct = parseNum(fail, 'mint-fee', opt('mint-fee', '1'), 1, 3)
    const exitFeePct = parseNum(fail, 'exit-fee', opt('exit-fee', '1'), 1, 2)
    const devShares = parseIntIn(fail, 'shares', opt('shares', '1'), 1, Math.round(capPct * 200))
    const quote = flag('quote') ? opt('quote') : ctx.wbnb
    const refPool = flag('ref-pool') ? opt('ref-pool') : zeroAddress
    if (!isAddress(quote ?? '') || !isAddress(refPool ?? '')) fail('--quote / --ref-pool must be 0x addresses')
    const cfg = {
      raiseBnb: parseEther(String(raise)), capBps: Math.round(capPct * 100),
      holdBps: Math.round(holdPct * 100), mintFeeBps: Math.round(mintFeePct * 100), exitFeeBps: Math.round(exitFeePct * 100),
    }
    const [ok, reason] = await ctx.read(ctx.pad, PAD_ABI, 'checkConfig', [cfg, BigInt(devShares)])
    if (!ok) fail(`rule out of bounds: ${reason}`)
    let priced
    try { priced = await ctx.read(ctx.pad, PAD_ABI, 'previewCreate', [quote, refPool, cfg.raiseBnb]) } catch (e) {
      return fail('cannot price the raise in this quote', revertOf(e) || { detail: e.shortMessage || e.message })
    }
    const [raiseQuote, sharePrice] = priced
    const sym = await symbolOf(ctx, quote)
    const fee = (sharePrice * BigInt(devShares) * BigInt(cfg.mintFeeBps)) / 10_000n
    const need = sharePrice * BigInt(devShares) + fee
    const me = walletFor(ctx, opt('from'))
    const pre = await fundingStep(ctx, me, quote, need, sym, rawOnly, summarize)
    if (pre) return out(pre)
    // logoURI is permanent on-chain: same handling as `gang create` (--logo file upload, other hosts copied to gang.fun).
    // Done after the setup steps so a wrap / approve round does not upload the image twice.
    const createData = (logoURI, metaURI) => encodeFunctionData({
      abi: PAD_ABI, functionName: 'create', args: [name, symbol, logoURI, metaURI, quote, refPool, cfg, BigInt(devShares)],
    })
    // the logo / metadata strings never decide a revert: dry-run without them, so a create that would fail uploads nothing
    const dry = await dryRun(ctx, me, ctx.pad, createData('', ''))
    if (dry) return out({ success: false, step: 'create', ...dry })
    const logo = await resolveLogo()
    const meta = await resolveMeta({ name, symbol, logoURI: logo.logoURI })
    const data = createData(logo.logoURI, meta.metaURI)
    return out(step(ctx, { from: me, to: ctx.pad, data }, {
      step: 'create', chainId: Number(ctx.chainId), name, symbol, logoURI: logo.logoURI, ...(logo.uploaded && { uploaded: true }),
      metaURI: meta.metaURI, metadata: meta.metadata, quote: sym || quote,
      raise: await units(ctx, quote, raiseQuote), sharePrice: await units(ctx, quote, sharePrice),
      capShares: cfg.capBps * 2, minWallets: Math.ceil(10_000 / (cfg.capBps * 2)), holdPct, mintFeePct, exitFeePct, devShares,
      devCost: await units(ctx, quote, need),
      note: 'no deadline: the sale stays open until all 10,000 shares are minted, then launches. Minters can sell shares back at the mint price (minus the exit fee; none once no one has minted for 7 days). The mint fee is the platform\'s and is not returned.',
    }, rawOnly, summarize))
  }

  if (sub === 'mint') {
    const token = tokenArg(opt, fail)
    const want = parseIntIn(fail, 'shares', opt('shares'), 1, 10_000)
    const sale = await saleOf(ctx, token)
    if (!sale) return fail('not a fair-mint sale on this pad', { token })
    if (sale.status !== 'minting') return fail(`sale is ${sale.status}, not minting`, { hint: 'it launched: trade the token on PancakeSwap' })
    const me = walletFor(ctx, opt('from'))
    if (sale.gate !== zeroAddress && (await ctx.read(sale.gate, ERC721_ABI, 'balanceOf', [me])) === 0n) {
      return fail('this wallet holds no Agent ID; fair mint is Agent-only', { wallet: me })
    }
    const [accepted, cost, fee] = await ctx.read(ctx.pad, PAD_ABI, 'previewMint', [token, me, BigInt(want)])
    if (accepted === 0n) return fail('no shares available to this wallet (cap reached or sold out)', { capShares: sale.capShares })
    const minShares = flag('min-shares') ? parseIntIn(fail, 'min-shares', opt('min-shares'), 1, Number(accepted)) : Number(accepted)
    const need = cost + fee
    const fills = sale.sold + Number(accepted) === 10_000
    const extra = {
      step: 'mint', chainId: Number(ctx.chainId), token, shares: Number(accepted), ...(Number(accepted) < want && { truncatedFrom: want }),
      cost: await units(ctx, sale.quote, cost), fee: await units(ctx, sale.quote, fee), feePct: sale.mintFeePct, quote: sale.quoteSymbol,
      soldAfter: sale.sold + Number(accepted), ...(fills && { launches: 'this mint fills the sale and launches the token (higher gas)' }),
      ...(!fills && { minWalletsLeftAfter: Math.ceil((10_000 - sale.sold - Number(accepted)) / sale.capShares) }),
      note: `the ${sale.mintFeePct}% mint fee goes to the platform and is not returned; selling back later pays the mint price minus the exit fee`,
    }
    // WBNB sale: pay native BNB through the router in one tx (it wraps; the position is still this wallet's)
    if (viaRouter(ctx, sale.quote, flag)) {
      const native = await ctx.client.getBalance({ address: me })
      if (native < need + GAS_RESERVE) {
        return fail('not enough BNB for this mint (native BNB must also cover gas)', {
          haveBnb: formatUnits(native, 18), needBnb: formatUnits(need, 18), reserveForGas: formatUnits(GAS_RESERVE, 18), hint: 'add --use-wbnb to pay from WBNB instead',
        })
      }
      const data = encodeFunctionData({ abi: ROUTER_ABI, functionName: 'fairMintBNB', args: [token, accepted, BigInt(minShares), routerDeadline()] })
      const dry = await dryRun(ctx, me, ctx.router, data, need)
      if (dry) return out({ success: false, step: 'mint', via: 'router', ...dry })
      return out(step(ctx, { from: me, to: ctx.router, data, value: need }, { ...extra, via: 'router', payBnb: formatUnits(need, 18) }, rawOnly, summarize))
    }
    const pre = await fundingStep(ctx, me, sale.quote, need, sale.quoteSymbol, rawOnly, summarize)
    if (pre) return out(pre)
    const data = encodeFunctionData({ abi: PAD_ABI, functionName: 'mint', args: [token, accepted, BigInt(minShares)] })
    const dry = await dryRun(ctx, me, ctx.pad, data)
    if (dry) return out({ success: false, step: 'mint', ...dry })
    return out(step(ctx, { from: me, to: ctx.pad, data }, extra, rawOnly, summarize))
  }

  if (sub === 'withdraw') {
    const token = tokenArg(opt, fail)
    const sale = await saleOf(ctx, token)
    if (!sale) return fail('not a fair-mint sale on this pad', { token })
    if (sale.status !== 'minting') return fail(`sale is ${sale.status}: withdraw only while minting`)
    const me = walletFor(ctx, opt('from'))
    const held = await ctx.read(ctx.pad, PAD_ABI, 'positions', [token, me])
    if (!held) return fail('this wallet has no shares in this sale')
    const shares = flag('all') ? Number(held) : parseIntIn(fail, 'shares', opt('shares'), 1, Number(held))
    const [payout, fee] = await ctx.read(ctx.pad, PAD_ABI, 'previewWithdraw', [token, me, BigInt(shares)])
    const data = encodeFunctionData({ abi: PAD_ABI, functionName: 'withdraw', args: [token, BigInt(shares)] })
    const dry = await dryRun(ctx, me, ctx.pad, data)
    if (dry) return out({ success: false, step: 'withdraw', ...dry })
    return out(step(ctx, { from: me, to: ctx.pad, data }, {
      step: 'withdraw', chainId: Number(ctx.chainId), token, shares,
      receive: await units(ctx, sale.quote, payout), exitFee: await units(ctx, sale.quote, fee), quote: sale.quoteSymbol,
      exitFeePct: sale.exitFeeNowPct,
      note: sale.stale
        ? `no mint for 7 days: no exit fee, the full mint price back; the ${sale.mintFeePct}% paid at mint is not returned`
        : `mint price − ${sale.exitFeeNowPct}% exit fee (none once no one has minted for 7 days); the ${sale.mintFeePct}% paid at mint is not returned`,
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
