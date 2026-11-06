/**
 * Binance Agentic Wallet (BAW) / Binance Web3 Wallet — browser detection.
 *
 * Hard rule (Lazy TEST wave2): ONLY Binance family may connect for claim / trade / deploy signing.
 * Reject MetaMask, OKX, generic injected, WalletConnect others.
 *
 * Heuristic (documented in WALLET-BAW-TEST.md):
 * - EIP-6963 rdns: com.binance.wallet, com.binance.w3w, or starts with com.binance.
 * - Injected: window.binancew3w.ethereum, ethereum.isBinance / isBinanceWallet / isBinanceW3W
 * - In-app DApp browser: typeof window.binancew3w?.ethereum !== 'undefined'
 *
 * True Agentic CLI path remains `baw contract-call preview|execute` (agent skill) —
 * browser cannot drive baw binary; site exposes connect+claim when Binance provider is present.
 */

const BINANCE_RDNS = ['com.binance.wallet', 'com.binance.w3w']
const REJECT_RDNS = [
  'io.metamask', 'io.metamask.flask',
  'com.okex.wallet', 'com.okx.wallet',
  'com.coinbase.wallet', 'app.phantom',
]

const announced = new Map()

function onAnnounce(event) {
  const { info, provider } = event.detail ?? {}
  if (!info?.rdns || !provider) return
  announced.set(String(info.rdns).toLowerCase(), { info, provider })
}

export function startEip6963Discovery() {
  if (typeof window === 'undefined') return
  window.addEventListener('eip6963:announceProvider', onAnnounce)
  window.dispatchEvent(new Event('eip6963:requestProvider'))
}

export function requestProviders() {
  if (typeof window === 'undefined') return
  window.dispatchEvent(new Event('eip6963:requestProvider'))
}

function ethereumList(win) {
  const eth = win?.ethereum
  if (!eth) return []
  if (Array.isArray(eth.providers) && eth.providers.length) return eth.providers
  return [eth]
}

function isBinanceProvider(provider) {
  return Boolean(
    provider?.isBinance
    || provider?.isBinanceWallet
    || provider?.isBinanceW3W
    || provider?.isBinanceWeb3Wallet,
  )
}

function isRejectedProvider(provider) {
  if (!provider) return true
  if (isBinanceProvider(provider)) return false
  if (provider.isMetaMask && !isBinanceProvider(provider)) return true
  if (provider.isOkxWallet || provider.isOKXWallet || provider.isOKExWallet) return true
  if (provider.isCoinbaseWallet || provider.isPhantom) return true
  return false
}

function findBinanceFrom6963() {
  for (const want of BINANCE_RDNS) {
    const hit = announced.get(want)
    if (hit) return hit.provider
  }
  for (const [rdns, { provider }] of announced) {
    if (rdns.startsWith('com.binance.')) return provider
  }
  return undefined
}

/** Prefer EIP-6963 Binance, then binancew3w inject, then flagged ethereum. */
export function getBawProvider(win = typeof window === 'undefined' ? undefined : window) {
  if (!win) return undefined
  requestProviders()
  const from6963 = findBinanceFrom6963()
  if (from6963) return from6963
  const w3w = win.binancew3w?.ethereum || win.binancew3w
  if (w3w) return w3w
  if (win.BinanceChain) return win.BinanceChain
  return ethereumList(win).find(isBinanceProvider)
}

export function listRejectedProviders(win = typeof window === 'undefined' ? undefined : window) {
  if (!win) return []
  const out = []
  for (const [rdns, { info }] of announced) {
    if (REJECT_RDNS.some((r) => rdns === r || rdns.startsWith(`${r}.`)) || (!rdns.startsWith('com.binance.') && rdns !== 'com.binance.wallet')) {
      if (!rdns.startsWith('com.binance.')) out.push(info?.name || rdns)
    }
  }
  for (const p of ethereumList(win)) {
    if (isRejectedProvider(p) && !isBinanceProvider(p)) {
      out.push(p.isMetaMask ? 'MetaMask' : p.isOkxWallet || p.isOKXWallet ? 'OKX' : 'other')
    }
  }
  return [...new Set(out)]
}

export const BAW_ONLY_MSG = '仅支持 Binance Agentic Wallet'
export const BAW_ONLY_MSG_EN = 'Binance Agentic Wallet only'

export function isInBinanceDapp(win = typeof window === 'undefined' ? undefined : window) {
  return Boolean(win?.binancew3w?.ethereum)
}

startEip6963Discovery()
