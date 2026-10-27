import { parseAbi, encodeFunctionData, formatUnits, parseUnits, zeroAddress } from 'viem'
import { decimalsOf, isMissingFunction, poolSellQuote, ROUTER_ABI, routerDeadline, step, units, GAS_RESERVE } from './steps.js'

/**
 * PancakeSwap (V2 pool) buys and sells of a graduated / launched token through GangRouter — V3 and 打新 tokens
 * (`gang v3 buy|sell`, `gang fair buy|sell`) and V2 / Soft / U / S tokens (`gang buy|sell`), all the same way:
 *   poolBuyBNB(token, quote, minTokensOut, deadline) payable  path [WBNB, token] or [WBNB, quote, token]
 *   poolBuy(token, quote, quoteIn, minTokensOut, deadline)     path [quote, token]; approve quote → router first
 *   poolSell(token, quote, amountIn, minQuoteOut, deadline)    path [token, quote]; approve token → router first
 *   poolSellForBNB(token, quote, amountIn, minBnbOut, deadline) path [token, quote(, WBNB)], paid out as BNB
 * The token lands in / the proceeds go to the caller. Approvals are for this trade's amount only.
 * Minimums: a buy = Pancake getAmountsOut less the token's buy tax, less --slippage; a sell = the tax handler's
 * previewSellNextBlock (the sell tax and the chunk of held tax it sells first included, as of the next block), or
 * getAmountsOut less the sell tax when there is no handler quote (V2 tokens, untaxed V3), less --slippage.
 */

// Pancake V2 router per chain: getAmountsOut only (the router does the swap itself). A gang tax handler's dexRouter()
// is asked first, so the quote uses the same Pancake deployment the handler sells through.
const DEX_ROUTERS = {
  56: '0x10ED43C718714eb63d5aA57B78B54704E256024E',
  97: '0xD99D1c33F9fC3444f8101754aBC46c52416550D1',
}
const DEX_ABI = parseAbi(['function getAmountsOut(uint256 amountIn, address[] path) view returns (uint256[] amounts)'])
const HANDLER_DEX_ABI = parseAbi(['function dexRouter() view returns (address)'])
const ERC20_ABI = parseAbi([
  'function balanceOf(address) view returns (uint256)',
  'function allowance(address, address) view returns (uint256)',
  'function approve(address, uint256) returns (bool)',
  'function symbol() view returns (string)',
])
const WBNB_ABI = parseAbi(['function deposit() payable'])

/** Gas note on a taxed gang token's pool sell (it sells a chunk of the held tax right before it). */
export const POOL_SELL_GAS_NOTE = 'this sell needs about 700k gas (it also sells one chunk of the held tax first): let the wallet estimate gas, or give at least 750k; too little gas reverts with SwapBackOutOfGas'

const same = (a, b) => String(a).toLowerCase() === String(b).toLowerCase()
const minOf = (x, slippagePct) => (x * BigInt(Math.round((100 - slippagePct) * 100))) / 10_000n
const lessBps = (x, bps) => x - (x * BigInt(bps)) / 10_000n
const symbolOf = async (ctx, t) => { try { return await ctx.read(t, ERC20_ABI, 'symbol') } catch { return null } }

async function dexRouterOf(ctx, handler) {
  if (handler) {
    try {
      const r = await ctx.read(handler, HANDLER_DEX_ABI, 'dexRouter')
      if (r && r !== zeroAddress) return r
    } catch { /* no dexRouter (older / V2 handler): the chain's default */ }
  }
  return DEX_ROUTERS[Number(ctx.chainId)] || null
}

/** Last hop of Pancake getAmountsOut, or throws { poolError } when a pair on the path is missing / empty. */
async function amountOut(ctx, dex, amountIn, path) {
  try {
    const amounts = await ctx.read(dex, DEX_ABI, 'getAmountsOut', [amountIn, path])
    return amounts[amounts.length - 1]
  } catch (e) {
    const err = new Error(`PancakeSwap has no usable pool on the path ${path.join(' → ')}`)
    err.poolError = { path, detail: e.shortMessage || e.message.split('\n')[0] }
    throw err
  }
}

/**
 * What the wallet still has to do before `need` of `token` can be pulled by the router: a WBNB wrap when it is WBNB and
 * the wallet is short, then an approve for exactly `need`. [] when ready; { error } when it cannot pay.
 */
async function fundingOf(ctx, { me, token, need, spender, sym, approveStep }) {
  const bal = await ctx.read(token, ERC20_ABI, 'balanceOf', [me])
  const steps = []
  if (bal < need) {
    if (!same(token, ctx.wbnb)) {
      return { error: { error: `not enough ${sym || 'tokens'}`, have: await units(ctx, token, bal), need: await units(ctx, token, need) } }
    }
    const missing = need - bal
    const native = await ctx.client.getBalance({ address: me })
    if (native < missing + GAS_RESERVE) {
      return { error: { error: 'not enough BNB + WBNB (native BNB must also cover gas)', haveBnb: formatUnits(native, 18), needBnb: formatUnits(missing, 18), reserveForGas: formatUnits(GAS_RESERVE, 18) } }
    }
    steps.push({
      tx: { from: me, to: token, data: encodeFunctionData({ abi: WBNB_ABI, functionName: 'deposit' }), value: missing },
      meta: { step: 'wrap-bnb', wrap: formatUnits(missing, 18) },
    })
  }
  if ((await ctx.read(token, ERC20_ABI, 'allowance', [me, spender])) < need) {
    steps.push({
      tx: { from: me, to: token, data: encodeFunctionData({ abi: ERC20_ABI, functionName: 'approve', args: [spender, need] }) },
      meta: { step: approveStep, approve: await units(ctx, token, need), token, spender, note: 'only this trade\'s amount is approved' },
    })
  }
  return { steps }
}

/**
 * Pay a pool buy in native BNB? WBNB-quoted: yes unless --use-quote (or the curve's --use-wbnb); another quote: only
 * with --pay-bnb (path WBNB → quote → token).
 */
export const poolPayBnb = (ctx, quote, flag) =>
  (!quote || quote === zeroAddress || same(quote, ctx.wbnb) ? !flag('use-quote') && !flag('use-wbnb') : flag('pay-bnb'))

const rawTx = (ctx, { from, to, data, value = 0n }) => ({ chainId: Number(ctx.chainId), from, to, data, value: value.toString() })

/**
 * Build a PancakeSwap trade through GangRouter. Returns the object the command prints.
 *  p: { side: 'buy'|'sell', token, quote, me, amount (decimal string; sell: null with all), all, slippage,
 *       buyTaxBps, sellTaxBps, handler (gang tax handler or null), swapBackGas (taxed gang token: the 700k note),
 *       payBnb (buy), toBnb (sell), base (fields every step carries) }
 *  io: { rawOnly, summarize, revertOf } — revertOf(e) → { error, hint } | null
 */
export async function poolTrade(ctx, p, { rawOnly, summarize, revertOf }) {
  const { side, token, me, slippage, base = {} } = p
  const quote = !p.quote || p.quote === zeroAddress ? ctx.wbnb : p.quote
  const quoteWbnb = same(quote, ctx.wbnb)
  const failOut = (o) => ({ success: false, ...base, ...o })
  if (!ctx.router) {
    return failOut({ error: 'no GangRouter address for this network in this CLI version', hint: `set ${Number(ctx.chainId) === 56 ? 'GANG_ROUTER' : 'GANG_TESTNET_ROUTER'} to the GangRouter proxy, or trade on PancakeSwap directly` })
  }
  // an eth_call to an address without code "passes": refuse a router that is not a contract on this chain
  const code = await ctx.client.getCode({ address: ctx.router }).catch(() => null)
  if (code === undefined || code === '0x') return failOut({ error: `the GangRouter address ${ctx.router} has no contract on chain ${ctx.chainId}`, hint: 'check GANG_ROUTER / GANG_TESTNET_ROUTER' })
  const dex = await dexRouterOf(ctx, p.handler)
  if (!dex) return failOut({ error: `no PancakeSwap router known on chain ${ctx.chainId}` })
  const quoteSymbol = (await symbolOf(ctx, quote)) || quote
  const deadline = routerDeadline()
  let call, value = 0n, pull = null, fields
  try {
    if (side === 'buy') {
      const payBnb = !!p.payBnb
      const amountIn = parseUnits(p.amount, payBnb ? 18 : await decimalsOf(ctx, quote))
      const path = payBnb ? (quoteWbnb ? [ctx.wbnb, token] : [ctx.wbnb, quote, token]) : [quote, token]
      const gross = await amountOut(ctx, dex, amountIn, path)
      const expect = lessBps(gross, p.buyTaxBps || 0)
      const minOut = minOf(expect, slippage)
      if (payBnb) {
        const native = await ctx.client.getBalance({ address: me })
        if (native < amountIn + GAS_RESERVE) {
          return failOut({
            step: 'pool-buy', error: 'not enough BNB for this buy (native BNB must also cover gas)',
            haveBnb: formatUnits(native, 18), needBnb: p.amount, reserveForGas: formatUnits(GAS_RESERVE, 18),
            ...(quoteWbnb && { hint: 'add --use-quote to pay from WBNB instead' }),
          })
        }
        call = { functionName: 'poolBuyBNB', args: [token, quote, minOut, deadline] }
        value = amountIn
      } else {
        call = { functionName: 'poolBuy', args: [token, quote, amountIn, minOut, deadline] }
        pull = { token: quote, need: amountIn, sym: quoteSymbol, approveStep: 'approve-quote' }
      }
      fields = {
        step: 'pool-buy', venue: 'pancakeswap', via: 'router', router: ctx.router, function: call.functionName,
        spend: p.amount, payWith: payBnb ? 'BNB' : quoteSymbol, quote: quoteSymbol, path,
        expectTokensBeforeTax: formatUnits(gross, 18), buyTaxPct: (p.buyTaxBps || 0) / 100,
        expectTokens: formatUnits(expect, 18), minTokensOut: formatUnits(minOut, 18), slippagePct: slippage,
        deadline: Number(deadline), quotedWith: 'getAmountsOut',
        note: `the tokens go straight to ${me}; minTokensOut = getAmountsOut less the ${(p.buyTaxBps || 0) / 100}% buy tax, less --slippage (the buy reverts below it)`,
      }
    } else {
      const bal = await ctx.read(token, ERC20_ABI, 'balanceOf', [me])
      if (bal === 0n) return failOut({ step: 'pool-sell', error: 'no balance to sell', wallet: me })
      const amount = p.all ? bal : parseUnits(p.amount, 18)
      if (amount > bal) return failOut({ step: 'pool-sell', error: 'amount exceeds balance', balance: formatUnits(bal, 18) })
      // the handler's quote includes the chunk of held tax sold right before the sell; 0 = no pair on the token (untaxed)
      const q = p.handler ? await poolSellQuote(ctx, p.handler, token, amount) : null
      let quoteOut, quotedWith
      if (q && q.out > 0n) {
        quoteOut = q.out; quotedWith = q.quotedWith
      } else {
        quoteOut = await amountOut(ctx, dex, lessBps(amount, p.sellTaxBps || 0), [token, quote])
        quotedWith = 'getAmountsOut'
      }
      const toBnb = !!p.toBnb
      const path = toBnb && !quoteWbnb ? [token, quote, ctx.wbnb] : [token, quote]
      const out = toBnb && !quoteWbnb ? await amountOut(ctx, dex, quoteOut, [quote, ctx.wbnb]) : quoteOut
      const minOut = minOf(out, slippage)
      call = toBnb
        ? { functionName: 'poolSellForBNB', args: [token, quote, amount, minOut, deadline] }
        : { functionName: 'poolSell', args: [token, quote, amount, minOut, deadline] }
      pull = { token, need: amount, sym: null, approveStep: 'approve' }
      fields = {
        step: 'pool-sell', venue: 'pancakeswap', via: 'router', router: ctx.router, function: call.functionName,
        amount: formatUnits(amount, 18), receive: toBnb ? 'BNB' : quoteSymbol, quote: quoteSymbol, path,
        sellTaxPct: (p.sellTaxBps || 0) / 100, expectOut: formatUnits(out, toBnb ? 18 : await decimalsOf(ctx, quote)),
        minOut: formatUnits(minOut, toBnb ? 18 : await decimalsOf(ctx, quote)), slippagePct: slippage,
        deadline: Number(deadline), quotedWith,
        ...(toBnb && !quoteWbnb && { expectQuoteBeforeBnb: await units(ctx, quote, quoteOut) }),
        gas: p.swapBackGas ? POOL_SELL_GAS_NOTE : 'let the wallet estimate gas',
        note: quotedWith === 'getAmountsOut'
          ? `minOut = getAmountsOut of the amount less the ${(p.sellTaxBps || 0) / 100}% sell tax, less --slippage (the sell reverts below it)`
          : `minOut = the tax handler's ${quotedWith} (sell tax and the chunk of held tax sold first included, as of the next block)${toBnb && !quoteWbnb ? ', then getAmountsOut quote → WBNB' : ''}, less --slippage (the sell reverts below it)`,
      }
    }
  } catch (e) {
    if (e.poolError) {
      // a BNB leg through a non-WBNB quote needs a WBNB/quote pool on Pancake as well
      const bnbLeg = !quoteWbnb && (side === 'buy' ? p.payBnb : p.toBnb)
      return failOut({
        step: `pool-${side}`, error: e.message, ...e.poolError,
        ...(bnbLeg && { hint: `no WBNB/${quoteSymbol} pool to route through: ${side === 'buy' ? 'drop --pay-bnb to pay with the quote' : 'drop --to-bnb to receive the quote'}` }),
      })
    }
    throw e
  }

  const swap = { from: me, to: ctx.router, data: encodeFunctionData({ abi: ROUTER_ABI, ...call }), value }
  const pre = pull ? await fundingOf(ctx, { me, ...pull, spender: ctx.router }) : { steps: [] }
  if (pre.error) return failOut({ step: fields.step, ...pre.error })
  const extra = { chainId: Number(ctx.chainId), token, ...base }

  if (pre.steps.length) {
    if (rawOnly) {
      // raw txs: every step in order (the swap is not simulated: it needs the steps before it on-chain)
      const steps = [...pre.steps.map((s) => ({ ...s.meta, tx: rawTx(ctx, s.tx) })), { step: fields.step, function: fields.function, tx: rawTx(ctx, swap) }]
      return {
        success: true, ...extra, ...fields, step: steps[0].step, steps, tx: steps[0].tx,
        note: `send the ${steps.length} txs in steps[] in order (tx = the first); the ${fields.step} is not simulated until the ${steps.slice(0, -1).map((s) => s.step).join(' / ')} is mined. ${fields.note}`,
      }
    }
    const first = pre.steps[0]
    return step(ctx, first.tx, {
      ...extra, ...first.meta, next: fields.step,
      then: { function: fields.function, ...(side === 'buy' ? { spend: fields.spend, minTokensOut: fields.minTokensOut } : { amount: fields.amount, minOut: fields.minOut }) },
      note: `${first.meta.note ? `${first.meta.note}. ` : ''}after executing, re-run the same command for the ${pre.steps.length > 1 ? 'next step' : fields.step}`,
    }, false, summarize)
  }

  // eth_call the swap: a revert names the reason (router / pool / token) and builds no preview
  try {
    await ctx.client.call({ account: me, to: swap.to, data: swap.data, value: swap.value })
  } catch (e) {
    const r = revertOf(e)
    const missing = isMissingFunction(e)
    return failOut({
      ...extra, ...fields, ...(r ? { reverted: true, ...r } : { reverted: false, error: e.shortMessage || e.message.split('\n')[0] }),
      ...(missing && { hint: `the router at ${ctx.router} has no ${call.functionName} (not upgraded to the pool-trade version yet): wait for the router upgrade, or trade on PancakeSwap directly` }),
      ...(rawOnly && { tx: rawTx(ctx, swap), txNote: 'not sent: the simulation failed; shown for inspection only' }),
    })
  }
  return step(ctx, swap, { ...extra, ...fields }, rawOnly, summarize)
}
