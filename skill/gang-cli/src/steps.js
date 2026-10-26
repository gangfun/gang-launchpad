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
