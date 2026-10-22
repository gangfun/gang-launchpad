const trim = (v) => (v && String(v).trim()) || ''

export const STOCKS_CHAIN_ID = Number(import.meta.env.VITE_STOCKS_CHAIN_ID || 97)
export const STOCKS_RPC = trim(import.meta.env.VITE_STOCKS_RPC_URL) || 'https://bsc-testnet-rpc.publicnode.com'
export const STOCKS_LAUNCHPAD = trim(import.meta.env.VITE_STOCKS_LAUNCHPAD)
/** Chapel test quote = MockSPCXB; product name still SPCXB. Accept either env key. */
export const STOCKS_QUOTE = trim(import.meta.env.VITE_STOCKS_QUOTE)
  || trim(import.meta.env.VITE_STOCKS_MOCK_SPCXB)
export const STOCKS_DIVIDEND_VAULT = trim(import.meta.env.VITE_STOCKS_DIVIDEND_VAULT)
export const STOCKS_MIGRATOR = trim(import.meta.env.VITE_STOCKS_MIGRATOR)
export const STOCKS_EXPLORER = STOCKS_CHAIN_ID === 97
  ? 'https://testnet.bscscan.com'
  : 'https://bscscan.com'

export const STOCKS_QUOTE_SYMBOL = 'SPCXB'
export const STOCKS_TAX_BPS = 100
export const STOCKS_DIV_SPLIT = '50/50'

export function stocksConfigured() {
  return !!(STOCKS_LAUNCHPAD && STOCKS_QUOTE)
}

export const STOCKS_ADDR_ROWS = [
  ['launchpad', STOCKS_LAUNCHPAD],
  ['quote (SPCXB)', STOCKS_QUOTE],
  ['dividend vault', STOCKS_DIVIDEND_VAULT],
  ['migrator', STOCKS_MIGRATOR],
].filter(([, v]) => v)

/**
 * Chapel env → market-list placeholders (no fake mcap/vol).
 * Shown under 币股 / 全部 until a stocks indexer exists.
 */
export function stockTrackPlaceholders() {
  if (!stocksConfigured()) return []
  return [{
    address: STOCKS_LAUNCHPAD,
    track: 'stocks',
    placeholder: true,
    symbol: 'LaunchpadS',
    name: 'Chapel stocks curve',
    quoteSymbol: STOCKS_QUOTE_SYMBOL,
    quoteAddress: STOCKS_QUOTE,
    quoteLabel: STOCKS_CHAIN_ID === 97 ? 'MockSPCXB' : 'SPCXB',
    taxBps: STOCKS_TAX_BPS,
    divSplit: STOCKS_DIV_SPLIT,
    dividendVault: STOCKS_DIVIDEND_VAULT || null,
    fdvBnb: 0,
    volume24hBnb: 0,
    progressPct: 0,
    graduated: false,
    createdAt: null,
    lastTradeAt: null,
    logoUrl: null,
    creator: null,
  }]
}
