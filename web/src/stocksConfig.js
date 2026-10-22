const trim = (v) => (v && String(v).trim()) || ''

export const STOCKS_CHAIN_ID = Number(import.meta.env.VITE_STOCKS_CHAIN_ID || 97)
export const STOCKS_RPC = trim(import.meta.env.VITE_STOCKS_RPC_URL) || 'https://bsc-testnet-rpc.publicnode.com'
export const STOCKS_LAUNCHPAD = trim(import.meta.env.VITE_STOCKS_LAUNCHPAD)
export const STOCKS_QUOTE = trim(import.meta.env.VITE_STOCKS_QUOTE)
export const STOCKS_DIVIDEND_VAULT = trim(import.meta.env.VITE_STOCKS_DIVIDEND_VAULT)
export const STOCKS_MIGRATOR = trim(import.meta.env.VITE_STOCKS_MIGRATOR)
export const STOCKS_EXPLORER = STOCKS_CHAIN_ID === 97
  ? 'https://testnet.bscscan.com'
  : 'https://bscscan.com'

export function stocksConfigured() {
  return !!(STOCKS_LAUNCHPAD && STOCKS_QUOTE)
}

export const STOCKS_ADDR_ROWS = [
  ['launchpad', STOCKS_LAUNCHPAD],
  ['quote (SPCXB)', STOCKS_QUOTE],
  ['dividend vault', STOCKS_DIVIDEND_VAULT],
  ['migrator', STOCKS_MIGRATOR],
].filter(([, v]) => v)
