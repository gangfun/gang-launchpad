import { parseAbi, encodeFunctionData, decodeErrorResult, formatUnits, zeroAddress } from 'viem'
import { client, fmtTok } from './chain.js'
import { get } from './discover.js'

/**
 * Tax dividends of the V2 / S / U tracks (`gang dividends`, `gang claim`). Each taxed token is registered in one
 * DividendVault (`quoteOf(token)` != 0 there) and pays its holders in that quote token; `pending(token, user)` is what
 * `claim(token)` sends now. The indexer's dividendVault / v2DividendVault fields name only the V2 and S vaults (tokens
 * paid from the U vault carry the same two), so every vault is read for every token.
 * V3 / 打新 dividends live in the shared vault of the gang launchpad: `gang v3 claim` / `gang fair claim`.
 */
export const DIVIDEND_VAULTS = [
  { rail: 'V2', address: '0x5e2Dd1D439b251d64B4147D8947445f83f3A2D62' },
  { rail: 'S', address: '0x41E42A6E8b81794AD6589A02545Fdf9d4963B06C' },
  { rail: 'U', address: '0x2E95280a3bCbB4a6b41D92B0CaEE3E9fc6c72F38' },
]

const VAULT_ABI = parseAbi([
  'function pending(address token, address user) view returns (uint256)',
  'function quoteOf(address token) view returns (address)',
  'function shares(address token, address user) view returns (uint256)',
  'function claim(address token) returns (uint256)',
  'error UnknownToken()',
  'error NothingToClaim()',
])
const ERC20_ABI = parseAbi([
  'function balanceOf(address) view returns (uint256)',
  'function symbol() view returns (string)',
  'function decimals() view returns (uint8)',
])

// one eth_call per ~120 reads (68 B of calldata each) instead of one per read; the public RPC rate-limits bursts
const many = async (contracts) => {
  const out = []
  for (let i = 0; i < contracts.length; i += 600) {
    out.push(...(await client.multicall({ contracts: contracts.slice(i, i + 600), allowFailure: true, batchSize: 8192 })))
  }
  return out
}
const ok = (r) => (r?.status === 'success' ? r.result : null)

/**
 * Taxed tokens to check: `only` alone (any token, indexed or not), else every V2-track row of gang.fun with taxed !== false.
 * → [{ address (lower case), symbol | null }]
 */
export async function taxedTokens(only) {
  if (only) return [{ address: only.toLowerCase(), symbol: null }]
  const rows = []
  const seen = new Set()
  for (let offset = 0, page = 0; page < 20; page++) {
    const d = await get(`/stocks/tokens?limit=200&offset=${offset}`, null, 'Check one token on-chain with --token <addr>')
    if (!d) throw new Error('gang API 404 on /stocks/tokens. Check one token on-chain with --token <addr>')
    for (const r of d.items || []) {
      const a = String(r.address || '').toLowerCase()
      if (r.taxed === false || !a || seen.has(a)) continue
      seen.add(a)
      rows.push({ address: a, symbol: r.symbol || null })
    }
    if (!d.hasMore || d.nextOffset == null || !d.items?.length) break
    offset = d.nextOffset
  }
  return rows
}

/**
 * `user`'s position in every vault for each of `tokens`. A token is kept when the wallet holds some or a vault owes it
 * something. → [{ token, symbol, balance, balanceRaw, vaults: [{ rail, vault, quote, quoteSymbol, pending, pendingRaw,
 * share, earning }], claimableRaw }]; `vaults` = where the token is registered, plus any other vault owing it something.
 */
export async function dividendsOf(user, tokens) {
  const V = DIVIDEND_VAULTS
  const first = await many(tokens.flatMap((t) => [
    { address: t.address, abi: ERC20_ABI, functionName: 'balanceOf', args: [user] },
    ...V.map((v) => ({ address: v.address, abi: VAULT_ABI, functionName: 'pending', args: [t.address, user] })),
  ]))
  const per = V.length + 1
  const kept = []
  tokens.forEach((t, i) => {
    const [bal, ...pend] = first.slice(i * per, (i + 1) * per).map(ok)
    if ((bal ?? 0n) > 0n || pend.some((p) => (p ?? 0n) > 0n)) kept.push({ ...t, bal: bal ?? 0n, pend: pend.map((p) => p ?? 0n) })
  })
  if (!kept.length) return []

  // only the kept rows: which vault each is registered in (its quote), the share that earns there, and a symbol if missing
  const second = await many(kept.flatMap((t) => [
    ...V.map((v) => ({ address: v.address, abi: VAULT_ABI, functionName: 'quoteOf', args: [t.address] })),
    ...V.map((v) => ({ address: v.address, abi: VAULT_ABI, functionName: 'shares', args: [t.address, user] })),
    { address: t.address, abi: ERC20_ABI, functionName: 'symbol' },
  ]))
  const per2 = V.length * 2 + 1
  const rows = kept.map((t, i) => {
    const r = second.slice(i * per2, (i + 1) * per2).map(ok)
    return { ...t, quotes: r.slice(0, V.length), shares: r.slice(V.length, V.length * 2), symbol: t.symbol || r[per2 - 1] }
  })

  const quotes = [...new Set(rows.flatMap((t) => t.quotes).filter((q) => q && q !== zeroAddress).map((q) => q.toLowerCase()))]
  const meta = await many(quotes.flatMap((q) => [
    { address: q, abi: ERC20_ABI, functionName: 'symbol' },
    { address: q, abi: ERC20_ABI, functionName: 'decimals' },
  ]))
  const quoteMeta = new Map(quotes.map((q, i) => [q, { symbol: ok(meta[i * 2]), decimals: ok(meta[i * 2 + 1]) }]))

  return rows.map((t) => {
    const vaults = []
    V.forEach((v, j) => {
      const quote = t.quotes[j] && t.quotes[j] !== zeroAddress ? t.quotes[j] : null
      const raw = t.pend[j]
      if (!quote && raw === 0n) return
      const m = quote ? quoteMeta.get(quote.toLowerCase()) : null
      const share = t.shares[j] ?? 0n
      vaults.push({
        rail: v.rail, vault: v.address, quote, quoteSymbol: m?.symbol ?? null,
        // a quote without readable decimals() is shown in raw units
        pending: m?.decimals != null ? formatUnits(raw, Number(m.decimals)) : `${raw} (raw units)`, pendingRaw: raw,
        share: fmtTok(share), earning: share > 0n,
      })
    })
    return {
      token: t.address, symbol: t.symbol ?? null, balance: fmtTok(t.bal), balanceRaw: t.bal,
      vaults, claimableRaw: t.pend.reduce((a, b) => a + b, 0n),
    }
  })
}

export const claimData = (token) => encodeFunctionData({ abi: VAULT_ABI, functionName: 'claim', args: [token] })

/** eth_call claim(token) from `user`: null when it would pass, else the revert name (or the RPC's words). */
export async function dryClaim(user, vault, token) {
  try {
    await client.call({ account: user, to: vault, data: claimData(token) })
    return null
  } catch (e) {
    const raw = e?.walk?.((x) => typeof x?.data === 'string' && x.data.startsWith('0x'))?.data
    if (raw && raw.length >= 10) {
      try { return { reverted: true, error: decodeErrorResult({ abi: VAULT_ABI, data: raw }).errorName } } catch { /* not the vault's */ }
    }
    return { reverted: false, error: e.shortMessage || e.message.split('\n')[0] }
  }
}
