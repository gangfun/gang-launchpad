/**
 * Binance Wallet detection for gang.fun (BSC mainnet).
 *
 * Accept: Binance Wallet extension and in-app binancew3w.
 * Reject MetaMask, OKX, Coinbase, Phantom, and any other injected wallet.
 * Never fall through to window.ethereum when it is MetaMask.
 */

const BINANCE_RDNS_EXACT = ['com.binance.wallet', 'com.binance.w3w']
const REJECT_RDNS = [
  'io.metamask', 'io.metamask.flask',
  'com.okex.wallet', 'com.okx.wallet',
  'com.coinbase.wallet', 'app.phantom',
]

/** SPACE ID Agent ID registry on BSC — same contract as indexer handles.js AGENT_ID. */
export const AGENT_ID = '0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F'
export const BSC_CHAIN_ID = 56
export const BSC_RPC = 'https://bsc-rpc.publicnode.com'
export const BAW_ONLY_MSG = 'BAW_ONLY'

const announced = new Map()

function onAnnounce(event) {
  const { info, provider } = event.detail ?? {}
  if (!provider) return
  const rdns = info?.rdns ? String(info.rdns).toLowerCase() : ''
  const key = rdns || `name:${String(info?.name || 'unknown').toLowerCase()}`
  announced.set(key, { info: info || { name: 'unknown', rdns: key }, provider })
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

/** Re-request EIP-6963 and wait briefly for late announces (extension race). */
export async function discoverProviders(ms = 400) {
  requestProviders()
  await new Promise((r) => setTimeout(r, ms))
  requestProviders()
  await new Promise((r) => setTimeout(r, 100))
}

function ethereumList(win) {
  const eth = win?.ethereum
  if (!eth) return []
  if (Array.isArray(eth.providers) && eth.providers.length) return eth.providers
  return [eth]
}

function isBinanceProvider(provider) {
  if (!provider) return false
  return Boolean(
    provider.isBinance
    || provider.isBinanceWallet
    || provider.isBinanceW3W
    || provider.isBinanceWeb3Wallet
    || provider.isBn
    || provider.bnb
  )
}

function isMetaMaskOnly(provider) {
  if (!provider?.isMetaMask) return false
  if (isBinanceProvider(provider)) return false
  return true
}

function isRejectedProvider(provider) {
  if (!provider) return true
  if (isBinanceProvider(provider)) return false
  if (isMetaMaskOnly(provider)) return true
  if (provider.isOkxWallet || provider.isOKXWallet || provider.isOKExWallet) return true
  if (provider.isCoinbaseWallet || provider.isPhantom) return true
  return false
}

function rdnsLooksBinance(rdns) {
  if (!rdns) return false
  const r = String(rdns).toLowerCase()
  if (BINANCE_RDNS_EXACT.includes(r)) return true
  return r.includes('binance')
}

function nameLooksBinance(name) {
  return /binance/i.test(String(name || ''))
}

function findBinanceFrom6963() {
  for (const want of BINANCE_RDNS_EXACT) {
    const hit = announced.get(want)
    if (hit) return hit.provider
  }
  for (const [key, { info, provider }] of announced) {
    if (rdnsLooksBinance(info?.rdns || key) || nameLooksBinance(info?.name)) return provider
  }
  return undefined
}

/**
 * Prefer EIP-6963 Binance → binancew3w → BinanceChain → providers[] with isBinance*.
 * Never return a MetaMask-default ethereum.
 */
export function getBawProvider(win = typeof window === 'undefined' ? undefined : window) {
  if (!win) return undefined
  requestProviders()

  const from6963 = findBinanceFrom6963()
  if (from6963) return from6963

  const w3w = win.binancew3w?.ethereum || win.binancew3w
  if (w3w) return w3w

  if (win.BinanceChain) return win.BinanceChain
  if (win.bnb?.ethereum) return win.bnb.ethereum
  if (win.binance?.ethereum) return win.binance.ethereum

  const listed = ethereumList(win)
  const flagged = listed.find(isBinanceProvider)
  if (flagged) return flagged

  if (listed.length === 1) {
    const only = listed[0]
    if (!isRejectedProvider(only) && !isMetaMaskOnly(only)) return only
  }

  return undefined
}

export function listRejectedProviders(win = typeof window === 'undefined' ? undefined : window) {
  if (!win) return []
  const out = []
  for (const [, { info }] of announced) {
    const rdns = String(info?.rdns || '').toLowerCase()
    if (rdnsLooksBinance(rdns) || nameLooksBinance(info?.name)) continue
    if (
      REJECT_RDNS.some((r) => rdns === r || rdns.startsWith(`${r}.`))
      || rdns.startsWith('io.metamask')
      || /metamask|okx|okex|coinbase|phantom/i.test(info?.name || '')
    ) {
      out.push(info?.name || rdns)
    }
  }
  for (const p of ethereumList(win)) {
    if (isRejectedProvider(p) && !isBinanceProvider(p)) {
      out.push(p.isMetaMask ? 'MetaMask' : p.isOkxWallet || p.isOKXWallet ? 'OKX' : 'other')
    }
  }
  return [...new Set(out)]
}

/** Display form: on-chain handle is bare ("lazy"); UI shows "lazy.ai". */
export function displayHandle(raw) {
  if (!raw) return null
  const h = String(raw).trim()
  if (!h) return null
  return h.includes('.') ? h : `${h}.ai`
}

startEip6963Discovery()

/** Injected Binance OR the active WalletConnect session. */
let wcOverride = null
export function setWcOverrideProvider(provider) {
  wcOverride = provider || null
}
export function getActiveProvider(win = typeof window === 'undefined' ? undefined : window) {
  if (wcOverride) return wcOverride
  return getBawProvider(win)
}
