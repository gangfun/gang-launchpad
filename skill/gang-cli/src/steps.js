import { parseAbi, encodeFunctionData, decodeErrorResult, formatUnits, parseEther } from 'viem'
import { bawPreview } from './baw.js'

/**
 * Shared by `gang fair` and `gang v3` (each on its own chain via `ctx`: { chainId, client, read, wbnb }): revert decoding,
 * the write step (raw tx or baw preview), quote funding (wrap / approve), flag parsing and token units.
 */
const ERC20_ABI = parseAbi([
  'function balanceOf(address) view returns (uint256)',
  'function allowance(address, address) view returns (uint256)',
  'function approve(address, uint256) returns (bool)',
  'function decimals() view returns (uint8)',
])
const WBNB_ABI = parseAbi(['function deposit() payable'])

/**
 * GangRouter (gang-launchpad src/router): stateless entry in front of both cores. With native BNB it wraps, calls the
 * core for the caller and returns any refund as BNB — no wrap / approve round for WBNB-quoted tokens and sales.
 */
export const ROUTER_ABI = parseAbi([
  'function v3BuyBNB(address token, uint256 minTokensOut, uint256 deadline) payable returns (uint256)',
  'function fairMintBNB(address token, uint256 shares, uint256 minShares, uint256 deadline) payable returns (uint256)',
  'error Expired()', 'error NotDeployed()', 'error UnknownToken()', 'error NotWbnbQuote()', 'error NotEnoughValue()',
  'error OnlyWbnb()', 'error BnbTransferFailed()',
])
/** Router deadline: half an hour, for a preview that is executed a few minutes later. */
export const routerDeadline = () => BigInt(Math.floor(Date.now() / 1000) + 1800)
/** Native BNB kept back for gas on a router call, as `gang buy` keeps for wrap + approve + buy. */
export const GAS_RESERVE = parseEther('0.002')
/** The router path applies: a router on this chain, a WBNB quote, and no --use-wbnb. */
export const viaRouter = (ctx, quote, flag) => !!ctx.router && quote.toLowerCase() === ctx.wbnb.toLowerCase() && !flag('use-wbnb')

/** Token decimals, read once per ctx (18 when the token does not say). */
export async function decimalsOf(ctx, token) {
  ctx.decimals ??= new Map()
  const k = token.toLowerCase()
  if (!ctx.decimals.has(k)) {
    let d = 18
    try { d = Number(await ctx.read(token, ERC20_ABI, 'decimals')) } catch { /* 18 */ }
    ctx.decimals.set(k, d)
  }
  return ctx.decimals.get(k)
}
export const units = async (ctx, token, amount) => formatUnits(amount, await decimalsOf(ctx, token))

/** Revert name (+ the first arg, e.g. a reason string) of a failed call against any of `abis`, or null when it was the RPC. */
export function revertOf(e, abis, hints = {}) {
  const raw = e?.walk?.((x) => typeof x?.data === 'string' && x.data.startsWith('0x'))?.data
  if (raw && raw.length >= 10) {
    for (const abi of abis) {
      try {
        const d = decodeErrorResult({ abi, data: raw })
        return { error: d.errorName, ...(d.args?.length && { reason: d.args[0] }), hint: hints[d.errorName] }
      } catch { /* not this contract */ }
    }
  }
  const named = e?.walk?.((x) => x?.data?.errorName)?.data?.errorName
  if (named) return { error: named, hint: hints[named] }
  if (e?.walk?.((x) => x?.code === 3 || /revert/i.test(x?.details || x?.shortMessage || ''))) return { error: 'execution reverted' }
  return null
}

/**
 * A write step: either the raw tx (--calldata: no baw call; e.g. to sign elsewhere) or a baw preview.
 * Returns the object the command prints.
 */
export function step(ctx, { from, to, data, value = 0n }, extra, rawOnly, summarize) {
  if (rawOnly) {
    return { success: true, ...extra, tx: { chainId: Number(ctx.chainId), from, to, data, value: value.toString() } }
  }
  const p = bawPreview({ from, to, value, data, chainId: ctx.chainId })
  // only an error about the chain itself: a generic network failure is not a reason to fall back to --calldata
  if (!p.success && new RegExp(`binanceChainId|unsupported chain|chain not supported|chain(?:\\s*id)?\\W{0,3}${ctx.chainId}\\b`, 'i')
    .test(JSON.stringify(p.error || ''))) {
    return {
      success: false, ...extra, error: p.error,
      hint: `the Agentic Wallet may not sign on chain ${ctx.chainId}: re-run with --calldata to get the raw tx`,
    }
  }
  return summarize(p, extra)
}

/**
 * `token` funding for `need` toward `spender`: wrap BNB first (WBNB), then approve. A step object, or null when ready.
 * approveStep names the approve step in the output (`approve-quote` for a quote, `approve` for selling a token).
 */
export async function fundingStep(ctx, { me, token, need, spender, sym, approveStep = 'approve-quote' }, rawOnly, summarize) {
  const bal = await ctx.read(token, ERC20_ABI, 'balanceOf', [me])
  if (bal < need) {
    if (token.toLowerCase() !== ctx.wbnb.toLowerCase()) {
      return { success: false, error: `not enough ${sym || 'quote'}`, have: await units(ctx, token, bal), need: await units(ctx, token, need) }
    }
    const missing = need - bal
    const native = await ctx.client.getBalance({ address: me })
    if (native < missing) {
      return { success: false, error: 'not enough BNB', haveBnb: formatUnits(native, 18), needBnb: formatUnits(missing, 18) }
    }
    return step(ctx, { from: me, to: token, data: encodeFunctionData({ abi: WBNB_ABI, functionName: 'deposit' }), value: missing },
      { step: 'wrap-bnb', wrap: formatUnits(missing, 18), note: 'after executing, re-run the same command' }, rawOnly, summarize)
  }
  if ((await ctx.read(token, ERC20_ABI, 'allowance', [me, spender])) < need) {
    return step(ctx, { from: me, to: token, data: encodeFunctionData({ abi: ERC20_ABI, functionName: 'approve', args: [spender, need] }) },
      { step: approveStep, approve: await units(ctx, token, need), ...(approveStep !== 'approve-quote' && { token }), spender, note: 'after executing, re-run the same command' },
      rawOnly, summarize)
  }
  return null
}

export const parseNum = (fail, name, raw, min, max) => {
  const n = Number(raw)
  if (raw == null || !Number.isFinite(n) || n < min || n > max) fail(`--${name} must be a number between ${min} and ${max}`, { got: raw })
  return n
}
export const parseIntIn = (fail, name, raw, min, max) => {
  const n = Number(raw)
  if (!Number.isInteger(n) || n < min || n > max) fail(`--${name} must be an integer between ${min} and ${max}`, { got: raw })
  return n
}
/** A positive decimal amount flag (e.g. --amount 0.5), as written: callers scale it with the token's decimals. */
export const parseAmount = (fail, name, raw) => {
  if (raw == null || !/^(\d+(\.\d*)?|\.\d+)$/.test(String(raw).trim()) || !(Number(raw) > 0)) {
    fail(`--${name} must be a positive number (e.g. 0.5)`, { got: raw ?? null })
  }
  return String(raw).trim()
}

/**
 * Reference pool `create` uses when --ref-pool is left out: mainnet USDT → Pancake V3 USDT/WBNB 0.01% (the deepest;
 * its 30-min TWAP prices the graduation target / raise). Other quotes need an explicit --ref-pool.
 */
const DEFAULT_REF_POOLS = {
  56: { '0x55d398326f99059ff775485246999027b3197955': '0x172fcD41E0913e95784454622d1c3724f546f849' },
}
export const defaultRefPool = (chainId, quote) => DEFAULT_REF_POOLS[Number(chainId)]?.[String(quote || '').toLowerCase()] || null

/** The shared dividend vault (V3 and 打新). */
export const VAULT_ABI = parseAbi([
  'function pending(address token, address user) view returns (uint256)',
  'function pendingUnits(address token, address user) view returns (uint256)',
  'function shares(address token, address user) view returns (uint256)',
  'function claim(address token) returns (uint256)',
  'error NothingToClaim()', 'error UnknownToken()',
  'event DividendClaimed(address indexed token, address indexed user, uint256 amount)',
])

/**
 * The pool-tax handler of a graduated V3 / launched 打新 token (TaxHandlerV3 / HolderRewardHandler, PostGradHandlerBase).
 * The tax is held in the token and sold in chunks: each token has one budget per block, at most 0.5% of the pair's token
 * side as it stood at the block's first chunk, shared by the chunk a taxed sell triggers (≤ 25% of that sell) and the
 * keeper; no chunk sells more than 2% below that block-start price.
 */
export const POOL_HANDLER_ABI = parseAbi([
  'function previewSellNextBlock(address token, uint256 amountIn) view returns (uint256 quoteOut, uint256 chunk)',
  'function previewSell(address token, uint256 amountIn) view returns (uint256 quoteOut, uint256 chunk)',
  'function accruedTax(address token) view returns (uint256)',
  'function maxChunk(address token) view returns (uint256)',
  'function windowOf(address token) view returns (uint64 blockNumber, uint96 used)',
  'function CHUNK_MAX_BPS() view returns (uint256)',
  'function MAX_PRICE_DROP_BPS() view returns (uint256)',
])

/**
 * What selling `amountIn` of `token` into its pool pays (after the sell tax, the chunk it triggers sold first), for the
 * seller's amountOutMin: `previewSellNextBlock` — the tx lands in a later block, with a fresh chunk budget — and
 * `previewSell` (this block) on handlers from before it. null when neither answers.
 */
export async function poolSellQuote(ctx, handler, token, amountIn) {
  for (const fn of ['previewSellNextBlock', 'previewSell']) {
    try {
      const [out, chunk] = await ctx.read(handler, POOL_HANDLER_ABI, fn, [token, amountIn])
      return { out, chunk, quotedWith: fn }
    } catch { /* older handler / RPC: try the next */ }
  }
  return null
}

/**
 * The swap-back state of a graduated token: tax held and not sold yet, the per-block budget (0.5% of the pool's token
 * side now) and what is left of it in the latest block (a new block starts a fresh one). Handlers from before the
 * per-block budget (one chunk per block) have no windowOf: `budget: 'one chunk per block (older handler)'`.
 */
export async function swapBackState(ctx, handler, token, reserveToken) {
  const [unsold, left, win, chunkBps, dropBps] = await Promise.all([
    ctx.read(handler, POOL_HANDLER_ABI, 'accruedTax', [token]).catch(() => null),
    ctx.read(handler, POOL_HANDLER_ABI, 'maxChunk', [token]).catch(() => null),
    ctx.read(handler, POOL_HANDLER_ABI, 'windowOf', [token]).catch(() => null),
    ctx.read(handler, POOL_HANDLER_ABI, 'CHUNK_MAX_BPS').catch(() => 50n),
    ctx.read(handler, POOL_HANDLER_ABI, 'MAX_PRICE_DROP_BPS').catch(() => null),
  ])
  if (unsold == null) return null
  const base = { unsoldTaxTokens: formatUnits(unsold, 18) }
  if (!win) return { ...base, budget: 'one chunk per block (older handler)' }
  return {
    ...base,
    budgetPerBlockTokens: formatUnits((reserveToken * chunkBps) / 10_000n, 18),
    leftInLatestBlockTokens: left == null ? null : formatUnits(left, 18),
    lastChunkBlock: Number(win[0]) || null,
    ...(dropBps != null && { pausesBelowBlockStartPct: Number(dropBps) / 100 }),
    note: `per block, at most ${Number(chunkBps) / 100}% of the pool's token side of the held tax is sold in total (sells' chunks and the keeper together); `
      + `no chunk sells when the price is more than ${dropBps != null ? Number(dropBps) / 100 : 2}% below where the block started. A new block starts a fresh budget.`,
  }
}

/** Hint for selling a graduated / launched token on PancakeSwap with a pool quote `q` (poolSellQuote) as amountOutMin. */
export const POOL_SELL_HINT = 'sell on PancakeSwap with swapExactTokensForTokensSupportingFeeOnTransferTokens (the token takes its sell tax in the transfer) and minOut as amountOutMin; '
  + 'the quote includes the small chunk of tax the handler sells right before a sell and assumes the tx lands in a new block (previewSellNextBlock). '
  + 'Let the wallet estimate gas, or give at least 750k: a sell that triggers a chunk uses about 660k (about 330k without), and too little gas reverts with SwapBackOutOfGas'

/**
 * `me`'s dividend / holder reward on a V3 or 打新 token from the shared vault: `pending` = settled quote, claimable now; `pendingUnits` = tax
 * already credited to `me` when it was paid (in tax tokens) whose batch is not sold yet — it becomes claimable quote
 * once sold, and is valued here at `priceRaw` (quote wei per token) as an estimate only. Vaults from before the
 * tax-time crediting have no pendingUnits: those report null.
 */
export async function dividendOf(ctx, vault, token, me, quote, priceRaw) {
  const [pending, share, unitsRaw] = await Promise.all([
    ctx.read(vault, VAULT_ABI, 'pending', [token, me]),
    ctx.read(vault, VAULT_ABI, 'shares', [token, me]),
    ctx.read(vault, VAULT_ABI, 'pendingUnits', [token, me]).catch(() => null),
  ])
  return {
    claimable: await units(ctx, quote, pending), claimableRaw: pending,
    dividendShare: formatUnits(share, 18),
    creditedUnsoldTokens: unitsRaw == null ? null : formatUnits(unitsRaw, 18),
    creditedUnsoldEstimate: unitsRaw == null || !priceRaw ? null : await units(ctx, quote, (unitsRaw * priceRaw) / 10n ** 18n),
    ...(unitsRaw > 0n && { note: 'creditedUnsold: tax credited to you when it was paid, claimable once that batch is sold (estimate at the current price)' }),
  }
}
