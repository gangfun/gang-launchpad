/** /me dividend claim. BSC mainnet. Vault address is env-only — no testnet default. */

export const DIVIDEND_CHAIN_ID = 56
export const DIVIDEND_RPC = String(import.meta.env.VITE_DIVIDEND_RPC || 'https://bsc-rpc.publicnode.com').trim()
export const DIVIDEND_EXPLORER = 'https://bscscan.com'

function isAddress(v) {
  return /^0x[a-fA-F0-9]{40}$/.test(String(v || '').trim())
}

/** Empty when VITE_DIVIDEND_VAULT is unset or not an address. */
export const DIVIDEND_VAULT = isAddress(import.meta.env.VITE_DIVIDEND_VAULT)
  ? String(import.meta.env.VITE_DIVIDEND_VAULT).trim()
  : ''

export function dividendConfigured() {
  return Boolean(DIVIDEND_VAULT)
}

/** Optional VITE_DIVIDEND_TOKENS: "0xabc:SYMBOL,0xdef". */
export function dividendTokens() {
  return String(import.meta.env.VITE_DIVIDEND_TOKENS || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean)
    .map((part) => {
      const [address, symbol] = part.split(':')
      const addr = (address || '').trim()
      if (!isAddress(addr)) return null
      return { address: addr.toLowerCase(), symbol: (symbol || '').trim() }
    })
    .filter(Boolean)
}
