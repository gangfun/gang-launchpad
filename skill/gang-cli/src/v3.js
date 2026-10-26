import { createPublicClient, http, parseAbi, encodeFunctionData, decodeEventLog, formatUnits, parseUnits, isAddress, zeroAddress } from 'viem'
import { bsc, bscTestnet } from 'viem/chains'
import { decimalsOf, fundingStep as fund, parseAmount, parseNum, revertOf as revertIn, ROUTER_ABI as GANG_ROUTER_ABI, routerDeadline, step, units, viaRouter, GAS_RESERVE } from './steps.js'
import { API } from './discover.js'
import { UA } from './version.js'
import { walletFor } from './fair.js'

/**
 * `gang v3 …` — LaunchpadV3 (tax recipient): a token with its own buy / sell tax (1–5% each), a dividend share and a
 * whitelisted recipient (e.g. a partner's treasury) paid in the quote token. The platform keeps 0.5% of volume; the
 * curve's 1% fee is on top. Contracts: gang-launchpad src/launchpad-v3.
 * Only on BSC testnet until the audit (--testnet); mainnet answers "not deployed" until there is a pad.
 */
export const V3_NETS = {
  mainnet: {
    chainId: '56', chain: bsc, pad: process.env.GANG_V3_PAD || null, // no mainnet pad before the audit
    rpc: process.env.GANG_RPC_URL || 'https://bsc-dataseed.binance.org',
    wbnb: '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c', explorer: 'https://bscscan.com',
    router: process.env.GANG_ROUTER || null,
  },
  testnet: {
    chainId: '97', chain: bscTestnet, pad: process.env.GANG_V3_TESTNET_PAD || '0x4B6a0E82E7357719D6204E5d6197Ef2C71E08dc4',
    router: process.env.GANG_ROUTER_TESTNET || '0x8614b9d0D5f320a36dD83FDE900DcA3F425459E1',
    rpc: process.env.GANG_V3_TESTNET_RPC_URL || 'https://bsc-testnet-rpc.publicnode.com',
    wbnb: '0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd', explorer: 'https://testnet.bscscan.com',
  },
}

const TAX = '(uint16 buyTaxBps, uint16 sellTaxBps, uint16 dividendBps, address recipient)'
const PAD_ABI = parseAbi([
  `function create(string name, string symbol, string logoURI, string metaURI, address quote, address refPool, ${TAX} tax) returns (address)`,
  'function buy(address token, uint256 quoteIn, uint256 minTokensOut) returns (uint256)',
  'function sell(address token, uint256 tokensIn, uint256 minQuoteOut) returns (uint256)',
  `function checkTaxConfig(${TAX} tax) view returns (bool ok, string reason)`,
  'function curves(address token) view returns (address creator, address quote, uint128 realQuote, uint128 sold, uint128 gradAmt, uint128 virtualQuote, bool graduated, uint16 buyTaxBps, uint16 sellTaxBps, uint16 dividendBps, address pair, address refPair)',
  'function taxConfigOf(address token) view returns (uint16 buyTaxBps, uint16 sellTaxBps, uint16 dividendBps, address recipient)',
  'function isAgent(address account) view returns (bool)',
  'function walletRoom(address token, address buyer) view returns (uint256)',
  'function graduationRemaining(address token) view returns (uint256)',
  'function graduationAmountOf(address quote, address refPool) view returns (uint256)',
  'function router() view returns (address)',
  'function recipientRegistry() view returns (address)',
  'function PROTOCOL_FEE_BPS() view returns (uint256)',
  'function PLATFORM_TAX_BPS() view returns (uint256)',
  'error UnknownToken()', 'error AlreadyGraduated()', 'error ZeroAmount()', 'error GradAmtTooSmall()', 'error Slippage()',
  'error MigratorNotSet()', 'error ZeroAddress()', 'error NotAgent()', 'error WalletCapReached()', 'error RefPoolRequired()',
  'error NoBridgePool()', 'error BridgeNotWbnb()', 'error BadTaxConfig(string reason)',
  'error PoolNotFactory()', 'error QuoteNotInPool()', 'error PoolNoLiquidity()', 'error ThinReferencePool()', 'error NotContract()',
  'error UnknownPoolType()', 'error QuoteNotAllowed()', 'error RouterNeedsGate()', 'error V3FactoryNotSet()', 'error GradAmtZero()',
  'event Created(address indexed token, address indexed creator, string name, string symbol, string logoURI, address indexed quote, address refPair, uint256 gradAmt)',
  'event TaxConfigured(address indexed token, uint16 buyTaxBps, uint16 sellTaxBps, uint16 dividendBps, address indexed recipient)',
  'event Buy(address indexed token, address indexed buyer, uint256 quoteIn, uint256 protocolFee, uint256 tax, uint256 tokensOut, uint256 realQuote)',
  'event Sell(address indexed token, address indexed seller, uint256 tokensIn, uint256 protocolFee, uint256 tax, uint256 quoteOut, uint256 realQuote)',
  'event Graduated(address indexed token, address indexed pair, address quote, uint256 tokenAmount, uint256 quoteAmount)',
])
const TAX_ROUTER_ABI = parseAbi([
  'function owedOf(address token) view returns (uint256)',
  'function release(address token) returns (uint256)',
  'error NothingOwed()',
  'event TaxDistributed(address indexed token, uint8 phase, uint256 amount, uint256 toPlatform, uint256 toDividend, uint256 toRecipient)',
  'event TaxPaid(address indexed token, address indexed recipient, address indexed quote, uint256 amount)',
  'event TaxOwed(address indexed token, address indexed recipient, address indexed quote, uint256 amount)',
])
const REGISTRY_ABI = parseAbi([
  'function isListed(address recipient) view returns (bool)',
  'function entries(address recipient) view returns (bool listed, uint64 listedAt, string label)',
])
const ERC20_ABI = parseAbi([
  'function balanceOf(address) view returns (uint256)',
  'function symbol() view returns (string)',
])
const PAIR_ABI = parseAbi(['function getReserves() view returns (uint112, uint112, uint32)', 'function token0() view returns (address)'])

// what to tell the agent for each pad error
const HINTS = {
  BadTaxConfig: 'a tax setting is out of bounds or the recipient is not on the whitelist: see reason',
  NotAgent: 'this wallet holds no Agent ID; V3 create and curve trades are Agent-only',
  WalletCapReached: 'this wallet already holds the per-wallet cap (1% of supply)',
  AlreadyGraduated: 'the token graduated; trade it on PancakeSwap',
  Slippage: 'the price moved past --slippage; re-run to re-quote',
  RefPoolRequired: 'a non-WBNB --quote needs --ref-pool: a Pancake V2 pair or V3 pool that holds the quote token',
  QuoteNotInPool: '--ref-pool does not contain the --quote token',
  ThinReferencePool: '--ref-pool is too shallow; pick the deepest pool for this quote',
  GradAmtTooSmall: 'the quote token is priced so high that the graduation amount rounds below the minimum',
  NothingOwed: 'the router owes this token\'s recipient nothing',
  QuoteNotAllowed: '--quote must be WBNB or an 18-decimal ERC-20 token (leave it out to use WBNB)',
  PoolNotFactory: '--ref-pool is not a PancakeSwap V2 pair / V3 pool',
  NotContract: '--ref-pool is not a contract',
  UnknownPoolType: '--ref-pool is not a PancakeSwap V2 pair / V3 pool',
  PoolNoLiquidity: '--ref-pool has no liquidity',
  V3FactoryNotSet: 'V3 pools are not enabled on this pad yet; use a Pancake V2 pair as --ref-pool',
  NoBridgePool: '--ref-pool pairs the quote with a token that has no bridge to WBNB here; pick a pool against WBNB (or USDT on mainnet)',
  BridgeNotWbnb: 'the bridge pool for this --ref-pool is misconfigured; pick a pool against WBNB',
  GradAmtZero: 'the quote token is priced so high that the target rounds to 0',
  RouterNeedsGate: 'the router path is off while the Agent gate is off; re-run with --use-wbnb to buy directly',
}

export function v3Ctx(testnet) {
  const net = V3_NETS[testnet ? 'testnet' : 'mainnet']
  if (!net.pad) throw new Error('LaunchpadV3 is not deployed on BSC mainnet yet (audit first) — add --testnet to use the BSC testnet deployment')
  const client = createPublicClient({ chain: net.chain, transport: http(net.rpc) })
  return { ...net, client, read: (address, abi, functionName, args = []) => client.readContract({ address, abi, functionName, args }) }
}

const symbolOf = async (ctx, token) => { try { return await ctx.read(token, ERC20_ABI, 'symbol') } catch { return null } }
const pct = (bps) => Number(bps) / 100
const VIRTUAL_TOKEN = 1_066_666_666_666_666_666_666_666_667n

/** Revert name (+ BadTaxConfig reason) of a failed call, or null when it was the RPC. */
const revertOf = (e) => revertIn(e, [PAD_ABI, TAX_ROUTER_ABI, GANG_ROUTER_ABI], HINTS)

/** eth_call `data` from `from`: { result } when it passes, { failed } with the revert (or RPC error) otherwise. */
async function simulate(ctx, from, to, abi, functionName, args, value = 0n) {
  try {
    const { result } = await ctx.client.simulateContract({ account: from, address: to, abi, functionName, args, value })
    return { result }
  } catch (e) {
    const r = revertOf(e)
    return { failed: r ? { reverted: true, ...r } : { reverted: false, error: e.shortMessage || e.message.split('\n')[0] } }
  }
}

/** A token's curve and tax as the pad stores them, plus the recipient's whitelist label. null when not a V3 token. */
export async function curveOf(ctx, token) {
  const c = await ctx.read(ctx.pad, PAD_ABI, 'curves', [token])
  const [creator, quote, realQuote, sold, gradAmt, virtualQuote, graduated, buyTaxBps, sellTaxBps, dividendBps, pair] = c
  if (creator === zeroAddress) return null
  // the recipient is not in curves(): it lives on the router's route, read back through taxConfigOf
  const [router, registry, remaining, tax] = await Promise.all([
    ctx.read(ctx.pad, PAD_ABI, 'router'), ctx.read(ctx.pad, PAD_ABI, 'recipientRegistry'),
    ctx.read(ctx.pad, PAD_ABI, 'graduationRemaining', [token]), ctx.read(ctx.pad, PAD_ABI, 'taxConfigOf', [token]),
  ])
  const recipient = tax[3] === zeroAddress ? null : tax[3]
  let label = null
  if (recipient) { try { label = (await ctx.read(registry, REGISTRY_ABI, 'entries', [recipient]))[2] || null } catch { /* unlisted */ } }
  const owed = await ctx.read(router, TAX_ROUTER_ABI, 'owedOf', [token])
  // graduation zeroes realQuote (it went into the pool): a graduated token is priced from the pair reserves
  let price = ((virtualQuote + realQuote) * 10n ** 18n) / (VIRTUAL_TOKEN - sold)
  if (graduated && pair !== zeroAddress) {
    const [[r0, r1], t0] = await Promise.all([ctx.read(pair, PAIR_ABI, 'getReserves'), ctx.read(pair, PAIR_ABI, 'token0')])
    const [rT, rQ] = t0.toLowerCase() === token.toLowerCase() ? [r0, r1] : [r1, r0]
    price = rT > 0n ? (rQ * 10n ** 18n) / rT : 0n
  }
  return {
    token, creator, quote, quoteSymbol: await symbolOf(ctx, quote), router, registry,
    graduated, pair: pair === zeroAddress ? null : pair,
    buyTaxPct: pct(buyTaxBps), sellTaxPct: pct(sellTaxBps), dividendPct: pct(dividendBps), recipient, recipientLabel: label,
    raised: await units(ctx, quote, graduated ? gradAmt : realQuote), graduationAt: await units(ctx, quote, gradAmt),
    toGraduation: await units(ctx, quote, remaining),
    progressPct: graduated ? 100 : gradAmt > 0n ? Number((realQuote * 10_000n) / gradAmt) / 100 : 0,
    priceQuote: await units(ctx, quote, price), priceFrom: graduated ? 'pool' : 'curve',
    owedToRecipient: await units(ctx, quote, owed), owedRaw: owed,
  }
}

/** `token` funding for `need` toward the pad (wrap BNB, then approve): a step object, or null when ready. */
const fundingStep = (ctx, me, token, need, sym, approveStep, rawOnly, summarize) =>
  fund(ctx, { me, token, need, spender: ctx.pad, sym, approveStep }, rawOnly, summarize)

/** The pad's fee constants: the curve fee on every curve trade, the platform's part of every tax (bps of volume). */
async function feesOf(ctx) {
  ctx.fees ??= Promise.all([ctx.read(ctx.pad, PAD_ABI, 'PROTOCOL_FEE_BPS'), ctx.read(ctx.pad, PAD_ABI, 'PLATFORM_TAX_BPS')])
    .then(([curve, platform]) => ({ curveFeePct: pct(curve), platformTaxPct: pct(platform) }))
  return ctx.fees
}

const addrArg = (opt, fail, name, what) => {
  const v = opt(name)
  if (!isAddress(v ?? '')) fail(`--${name} must be ${what} (0x…)`, { got: v ?? null })
  return v
}
const parseSlippage = (fail, raw) => parseNum(fail, 'slippage', raw, 0, 50)
const minOf = (x, slippagePct) => (x * BigInt(Math.round((100 - slippagePct) * 100))) / 10_000n

const SUBS = ['list', 'info', 'create', 'buy', 'sell', 'income', 'release', 'tx']
const USAGE = 'usage: gang v3 <list|info|create|buy|sell|income|release|tx> [--testnet] — see gang help'

/**
 * Entry for `gang v3 <sub>`. io: { opt, flag, out, fail, summarize, resolveLogo, checkMeta, resolveMeta } from index.js
 * (summarize = summarizePreview, so previews look like every other command's).
 */
export async function runV3(sub, { opt, flag, out, fail, summarize, resolveLogo, checkMeta, resolveMeta }) {
  if (!SUBS.includes(sub)) return fail(USAGE, { got: sub ?? null })
  // agent notes are matched to the server's V2 / Soft trades; V3 txs are not matched there yet
  if (flag('note') || flag('follow')) return fail('--note / --follow are not supported on gang v3 yet: the server cannot match them to a V3 tx; leave them out')
  const testnet = flag('testnet')
  const net = testnet ? ' --testnet' : ''
  const rawOnly = flag('calldata')

  if (sub === 'list' || sub === 'income') {
    const recipient = sub === 'income' ? addrArg(opt, fail, 'recipient', 'the tax recipient address') : null
    const status = opt('status', 'all')
    if (sub === 'list' && !['curve', 'graduated', 'all'].includes(status)) fail('--status must be curve, graduated or all')
    const path = recipient ? `/v3/recipients/${recipient.toLowerCase()}?limit=20` : `/v3/tokens?status=${status}&limit=30`
    const r = await fetch(`${API}${path}`, { headers: { 'user-agent': UA }, signal: AbortSignal.timeout(10_000) })
      .then((x) => (x.ok ? x.json() : { error: x.status })).catch((e) => ({ error: e.message }))
    if (r.error) return out({ success: false, error: `gang.fun V3 data unavailable (${r.error})`, hint: `use gang v3 info --token <addr>${net} for one token (reads the chain)` })
    // the quote's own decimals from gang.fun (18 when an older server does not send them)
    const f = (x, d) => (x == null ? null : formatUnits(BigInt(x), d ?? 18))
    if (recipient) {
      return out({
        success: true, recipient, label: r.label, whitelist: r.whitelist ?? (r.listed ? 'listed' : null), chainId: r.chainId,
        totals: (r.totals || []).map((x) => ({ quote: x.symbol || x.quote, paid: f(x.paid, x.decimals) })),
        tokens: (r.tokens || []).map((x) => ({ token: x.token, symbol: x.symbol, quote: x.quoteSymbol, paid: f(x.paid, x.quoteDecimals), payments: x.payments, lastPaidAt: x.lastPaidAt })),
        recentPayments: (r.payments?.items || []).map((x) => ({ token: x.token, amount: f(x.amount, x.decimals), ts: x.ts, tx: x.tx })),
      })
    }
    return out({ success: true, status, items: (r.items || []).map((x) => ({
      token: x.address, symbol: x.symbol, buyTaxPct: pct(x.buyTaxBps), sellTaxPct: pct(x.sellTaxBps), dividendPct: pct(x.dividendBps),
      recipient: x.recipient, recipientLabel: x.recipientLabel, quote: x.quoteSymbol, progressPct: x.progressPct, graduated: x.graduated,
      chainId: x.chainId, link: `https://gang.fun/token/${x.address}`,
    })) })
  }

  let ctx
  try { ctx = v3Ctx(testnet) } catch (e) { return fail(e.message) }

  if (sub === 'info') {
    const token = addrArg(opt, fail, 'token', 'a V3 token address')
    const c = await curveOf(ctx, token)
    if (!c) return fail('not a LaunchpadV3 token on this pad', { token, chainId: ctx.chainId })
    const { owedRaw: _raw, ...pub } = c
    return out({ success: true, chainId: Number(ctx.chainId), ...(await feesOf(ctx)), ...pub })
  }

  if (sub === 'create') {
    const name = opt('name'), symbol = opt('symbol')
    if (!name || !symbol) fail('--name and --symbol are required')
    checkMeta() // a bad --website / --twitter / --description fails here, before any chain read or upload
    if (!flag('buy-tax') || !flag('sell-tax')) fail('--buy-tax and --sell-tax are required (each 1–5, in %; e.g. --buy-tax 2 --sell-tax 2)')
    const buyTax = parseNum(fail, 'buy-tax', opt('buy-tax'), 1, 5)
    const sellTax = parseNum(fail, 'sell-tax', opt('sell-tax'), 1, 5)
    const dividend = parseNum(fail, 'dividend', opt('dividend', '0'), 0, 100)
    // everything to holders needs no recipient; otherwise the recipient gets the rest and must be whitelisted
    const recipient = dividend === 100 && !flag('recipient') ? zeroAddress : addrArg(opt, fail, 'recipient', 'a whitelisted tax recipient')
    const quote = flag('quote') ? opt('quote') : ctx.wbnb
    const refPool = flag('ref-pool') ? opt('ref-pool') : zeroAddress
    if (!isAddress(quote ?? '') || !isAddress(refPool ?? '')) fail('--quote / --ref-pool must be 0x addresses')
    const tax = { buyTaxBps: Math.round(buyTax * 100), sellTaxBps: Math.round(sellTax * 100), dividendBps: Math.round(dividend * 100), recipient }
    const [ok, reason] = await ctx.read(ctx.pad, PAD_ABI, 'checkTaxConfig', [tax])
    if (!ok) fail(`tax setting refused: ${reason}`, { hint: HINTS.BadTaxConfig, tax: { buyTax, sellTax, dividend, recipient } })
    const me = walletFor(ctx, opt('from'))
    if (!(await ctx.read(ctx.pad, PAD_ABI, 'isAgent', [me]))) fail('this wallet holds no Agent ID; V3 create is Agent-only', { wallet: me })
    // like LaunchpadV2: WBNB → 15 BNB; a fixed rate in QuoteRegistry; else --ref-pool prices the target
    let gradAmt
    try { gradAmt = await ctx.read(ctx.pad, PAD_ABI, 'graduationAmountOf', [quote, refPool]) } catch (e) {
      return fail('cannot price the graduation target in this quote', revertOf(e) || { detail: e.shortMessage || e.message })
    }
    const createData = (logoURI, metaURI) =>
      encodeFunctionData({ abi: PAD_ABI, functionName: 'create', args: [name, symbol, logoURI, metaURI, quote, refPool, tax] })
    // the logo / metadata strings never decide a revert: dry-run without them, so a create that would fail uploads nothing
    const dry = await simulate(ctx, me, ctx.pad, PAD_ABI, 'create', [name, symbol, '', '', quote, refPool, tax])
    if (dry.failed) return out({ success: false, step: 'create', ...dry.failed })
    const logo = await resolveLogo()
    const meta = await resolveMeta({ name, symbol, logoURI: logo.logoURI })
    let label = null
    if (recipient !== zeroAddress) {
      const reg = await ctx.read(ctx.pad, PAD_ABI, 'recipientRegistry')
      try { label = (await ctx.read(reg, REGISTRY_ABI, 'entries', [recipient]))[2] || null } catch { /* checked above */ }
    }
    const rest = 100 - dividend
    const fees = await feesOf(ctx)
    return out(step(ctx, { from: me, to: ctx.pad, data: createData(logo.logoURI, meta.metaURI) }, {
      step: 'create', chainId: Number(ctx.chainId), name, symbol, logoURI: logo.logoURI, ...(logo.uploaded && { uploaded: true }),
      metaURI: meta.metaURI, metadata: meta.metadata,
      quote: (await symbolOf(ctx, quote)) || quote, graduationAt: await units(ctx, quote, gradAmt),
      ...(refPool !== zeroAddress && quote.toLowerCase() !== String(ctx.wbnb).toLowerCase() && { refPool }),
      buyTaxPct: buyTax, sellTaxPct: sellTax, dividendPct: dividend,
      recipient: recipient === zeroAddress ? null : recipient, recipientLabel: label, tokenIfNext: dry.result,
      split: `of each ${buyTax}% buy / ${sellTax}% sell tax: ${fees.platformTaxPct}% of volume to the platform, then ${dividend}% of the rest to holders, ${rest}% to the recipient in the quote`
        + (dividend > 0 ? '; while no holder has 10,000+ tokens (e.g. the first buys), the holders\' part goes to the recipient too' : ''),
      note: `tax rates and recipient are fixed at create. The curve also takes its ${fees.curveFeePct}% fee on every trade. tokenIfNext changes if another create lands first: the real address is the Created event from \`gang v3 tx --hash …\`.`,
    }, rawOnly, summarize))
  }

  if (sub === 'buy') {
    const token = addrArg(opt, fail, 'token', 'a V3 token address')
    const c = await curveOf(ctx, token)
    if (!c) return fail('not a LaunchpadV3 token on this pad', { token })
    if (c.graduated) return fail('token already graduated; trade it on PancakeSwap', { pair: c.pair })
    const me = walletFor(ctx, opt('from'))
    if (!(await ctx.read(ctx.pad, PAD_ABI, 'isAgent', [me]))) fail('this wallet holds no Agent ID; curve trades are Agent-only', { wallet: me })
    if ((await ctx.read(ctx.pad, PAD_ABI, 'walletRoom', [token, me])) === 0n) fail(HINTS.WalletCapReached)
    if (!flag('amount') && !flag('bnb')) fail('--amount <quote to spend> required (fee and tax included)')
    const raw = parseAmount(fail, flag('amount') ? 'amount' : 'bnb', opt('amount') ?? opt('bnb'))
    const quoteIn = parseUnits(raw, await decimalsOf(ctx, c.quote))
    const slippage = parseSlippage(fail, opt('slippage', '1'))
    const extra = (tokensOut, minOut) => ({
      step: 'buy', chainId: Number(ctx.chainId), token, spend: raw, quote: c.quoteSymbol, expectTokens: formatUnits(tokensOut, 18),
      minTokensOut: formatUnits(minOut, 18), buyTaxPct: c.buyTaxPct,
    })
    // WBNB-quoted: pay native BNB through the router in one tx (it wraps; tokens land in this wallet, refunds come back as BNB)
    if (viaRouter(ctx, c.quote, flag)) {
      const native = await ctx.client.getBalance({ address: me })
      if (native < quoteIn + GAS_RESERVE) {
        fail('not enough BNB for this buy (native BNB must also cover gas)', {
          haveBnb: formatUnits(native, 18), needBnb: raw, reserveForGas: formatUnits(GAS_RESERVE, 18), hint: 'add --use-wbnb to pay from WBNB instead',
        })
      }
      const sim = await simulate(ctx, me, ctx.router, GANG_ROUTER_ABI, 'v3BuyBNB', [token, 0n, routerDeadline()], quoteIn)
      if (sim.failed) return out({ success: false, step: 'buy', via: 'router', ...sim.failed })
      const minOut = minOf(sim.result, slippage)
      const data = encodeFunctionData({ abi: GANG_ROUTER_ABI, functionName: 'v3BuyBNB', args: [token, minOut, routerDeadline()] })
      return out(step(ctx, { from: me, to: ctx.router, data, value: quoteIn }, {
        ...extra(sim.result, minOut), via: 'router', curveFeePct: (await feesOf(ctx)).curveFeePct,
        note: 'paid in BNB through GangRouter; spend includes the curve fee and the buy tax; at the 1% wallet cap the excess comes back as BNB',
      }, rawOnly, summarize))
    }
    const pre = await fundingStep(ctx, me, c.quote, quoteIn, c.quoteSymbol, 'approve-quote', rawOnly, summarize)
    if (pre) return out(pre)
    const sim = await simulate(ctx, me, ctx.pad, PAD_ABI, 'buy', [token, quoteIn, 0n])
    if (sim.failed) return out({ success: false, step: 'buy', ...sim.failed })
    const minOut = minOf(sim.result, slippage)
    return out(step(ctx, { from: me, to: ctx.pad, data: encodeFunctionData({ abi: PAD_ABI, functionName: 'buy', args: [token, quoteIn, minOut] }) }, {
      ...extra(sim.result, minOut), curveFeePct: (await feesOf(ctx)).curveFeePct,
      note: 'spend includes the curve fee and the buy tax; at the 1% wallet cap the excess is refunded',
    }, rawOnly, summarize))
  }

  if (sub === 'sell') {
    const token = addrArg(opt, fail, 'token', 'a V3 token address')
    const c = await curveOf(ctx, token)
    if (!c) return fail('not a LaunchpadV3 token on this pad', { token })
    if (c.graduated) return fail('token already graduated; sell on PancakeSwap', { pair: c.pair })
    const me = walletFor(ctx, opt('from'))
    const bal = await ctx.read(token, ERC20_ABI, 'balanceOf', [me])
    if (bal === 0n) fail('no balance to sell')
    if (flag('all') === !!opt('amount')) fail('pass exactly one of --amount <tokens> or --all')
    const amount = flag('all') ? bal : parseUnits(parseAmount(fail, 'amount', opt('amount')), 18)
    if (amount > bal) fail('amount exceeds balance', { balance: formatUnits(bal, 18) })
    const slippage = parseSlippage(fail, opt('slippage', '1'))
    const pre = await fundingStep(ctx, me, token, amount, c.quoteSymbol, 'approve', rawOnly, summarize)
    if (pre) return out(pre)
    const sim = await simulate(ctx, me, ctx.pad, PAD_ABI, 'sell', [token, amount, 0n])
    if (sim.failed) return out({ success: false, step: 'sell', ...sim.failed })
    const minOut = minOf(sim.result, slippage)
    return out(step(ctx, { from: me, to: ctx.pad, data: encodeFunctionData({ abi: PAD_ABI, functionName: 'sell', args: [token, amount, minOut] }) }, {
      step: 'sell', chainId: Number(ctx.chainId), token, amount: formatUnits(amount, 18), quote: c.quoteSymbol,
      expectOut: await units(ctx, c.quote, sim.result), minOut: await units(ctx, c.quote, minOut), sellTaxPct: c.sellTaxPct,
      curveFeePct: (await feesOf(ctx)).curveFeePct, note: 'expectOut is after the curve fee and the sell tax',
    }, rawOnly, summarize))
  }

  if (sub === 'release') {
    const token = addrArg(opt, fail, 'token', 'a V3 token address')
    const c = await curveOf(ctx, token)
    if (!c) return fail('not a LaunchpadV3 token on this pad', { token })
    if (c.owedRaw === 0n) return fail('nothing owed: every tax payment reached the recipient', { recipient: c.recipient })
    const me = walletFor(ctx, opt('from'))
    const sim = await simulate(ctx, me, c.router, TAX_ROUTER_ABI, 'release', [token])
    if (sim.failed) return out({ success: false, step: 'release', ...sim.failed, hint: 'the recipient may still refuse transfers of this quote; try again later' })
    return out(step(ctx, { from: me, to: c.router, data: encodeFunctionData({ abi: TAX_ROUTER_ABI, functionName: 'release', args: [token] }) }, {
      step: 'release', chainId: Number(ctx.chainId), token, recipient: c.recipient, recipientLabel: c.recipientLabel,
      amount: c.owedToRecipient, quote: c.quoteSymbol, note: 'anyone may release; the quote goes to the recipient, not to the caller',
    }, rawOnly, summarize))
  }

  if (sub === 'tx') {
    const hash = opt('hash')
    if (!/^0x[0-9a-fA-F]{64}$/.test(hash ?? '')) fail('--hash must be a tx hash')
    const r = await ctx.client.waitForTransactionReceipt({ hash, timeout: 120_000 })
    const events = []
    for (const log of r.logs) {
      for (const abi of [PAD_ABI, TAX_ROUTER_ABI]) {
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
