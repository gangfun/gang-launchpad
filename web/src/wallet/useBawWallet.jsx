import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react'
import { createPublicClient, http, parseAbi } from 'viem'
import { bsc } from 'viem/chains'
import {
  AGENT_ID,
  BAW_ONLY_MSG,
  BSC_CHAIN_ID,
  BSC_RPC,
  discoverProviders,
  displayHandle,
  getActiveProvider,
  getBawProvider,
  listRejectedProviders,
  requestProviders,
} from './baw.js'

const HANDLE_ABI = parseAbi(['function handleOf(address account) view returns (string)'])

const BawCtx = createContext(null)

function publicClient() {
  return createPublicClient({ chain: bsc, transport: http(BSC_RPC) })
}

async function lookupHandle(address) {
  const raw = await publicClient().readContract({
    address: AGENT_ID,
    abi: HANDLE_ABI,
    functionName: 'handleOf',
    args: [address],
  })
  return displayHandle(raw)
}

async function ensureBsc(provider) {
  let cid = Number(await provider.request({ method: 'eth_chainId' }))
  if (cid === BSC_CHAIN_ID) return cid
  try {
    await provider.request({
      method: 'wallet_switchEthereumChain',
      params: [{ chainId: '0x38' }],
    })
    return BSC_CHAIN_ID
  } catch (e) {
    if (e?.code === 4902) {
      await provider.request({
        method: 'wallet_addEthereumChain',
        params: [{
          chainId: '0x38',
          chainName: 'BNB Smart Chain',
          nativeCurrency: { name: 'BNB', symbol: 'BNB', decimals: 18 },
          rpcUrls: [BSC_RPC],
          blockExplorerUrls: ['https://bscscan.com'],
        }],
      })
      return BSC_CHAIN_ID
    }
    throw e
  }
}

function useBawWalletState() {
  const [account, setAccount] = useState(null)
  const [handle, setHandle] = useState(null)
  const [chainId, setChainId] = useState(null)
  const [error, setError] = useState(null)
  const [busy, setBusy] = useState(false)
  const [mode, setMode] = useState(null)
  const [ready, setReady] = useState(false)

  const refresh = useCallback(async () => {
    const provider = getActiveProvider()
    if (!provider) {
      setAccount(null)
      setChainId(null)
      return
    }
    try {
      const accounts = await provider.request({ method: 'eth_accounts' })
      const cid = await provider.request({ method: 'eth_chainId' })
      setAccount(accounts?.[0] ? String(accounts[0]).toLowerCase() : null)
      setChainId(Number(cid))
    } catch {
      setAccount(null)
    }
  }, [])

  useEffect(() => {
    let cancel = false
    ;(async () => {
      try {
        await discoverProviders(300)
        if (!cancel) await refresh()
      } finally {
        if (!cancel) setReady(true)
      }
    })()
    const tick = setInterval(() => { requestProviders() }, 2000)
    return () => {
      cancel = true
      clearInterval(tick)
    }
  }, [refresh])

  useEffect(() => {
    const provider = getActiveProvider()
    if (!provider?.on) return undefined
    const onAcc = () => refresh()
    const onChain = (cid) => setChainId(Number(cid))
    provider.on('accountsChanged', onAcc)
    provider.on('chainChanged', onChain)
    return () => {
      provider.removeListener?.('accountsChanged', onAcc)
      provider.removeListener?.('chainChanged', onChain)
    }
  }, [refresh, account, mode])

  useEffect(() => {
    if (!account) {
      setHandle(null)
      return undefined
    }
    let cancel = false
    lookupHandle(account).then((h) => {
      if (!cancel) setHandle(h)
    }).catch(() => {
      if (!cancel) setHandle(null)
    })
    return () => { cancel = true }
  }, [account])

  const connect = useCallback(async () => {
    setError(null)
    setBusy(true)
    try {
      let provider
      for (let i = 0; i < 8; i++) {
        await discoverProviders(i === 0 ? 400 : 200)
        provider = getBawProvider()
        if (provider) break
      }
      if (!provider) {
        const rejected = listRejectedProviders()
        setError(rejected.length ? `${BAW_ONLY_MSG}:${rejected.slice(0, 3).join(',')}` : BAW_ONLY_MSG)
        return null
      }
      if (provider.isMetaMask && !(provider.isBinance || provider.isBinanceWallet || provider.isBinanceW3W || provider.isBinanceWeb3Wallet)) {
        setError(`${BAW_ONLY_MSG}:MetaMask`)
        return null
      }
      const accounts = await provider.request({ method: 'eth_requestAccounts' })
      const addr = accounts?.[0] ? String(accounts[0]).toLowerCase() : null
      if (!addr) {
        setError(BAW_ONLY_MSG)
        return null
      }
      let cid = null
      try {
        cid = await ensureBsc(provider)
      } catch (e) {
        cid = Number(await provider.request({ method: 'eth_chainId' }).catch(() => 0))
        if (cid !== BSC_CHAIN_ID) setError(e?.message || 'Switch to BNB Smart Chain (56)')
      }
      setMode('inject')
      setAccount(addr)
      setChainId(cid)
      return addr
    } catch (e) {
      setError(e?.message || BAW_ONLY_MSG)
      return null
    } finally {
      setBusy(false)
    }
  }, [])

  const disconnect = useCallback(async () => {
    setMode(null)
    setAccount(null)
    setHandle(null)
    setError(null)
  }, [])

  const chipLabel = handle || (account ? `BAW ${account.slice(0, 6)}…${account.slice(-4)}` : null)

  return useMemo(() => ({
    account,
    handle,
    chipLabel,
    chainId,
    error,
    busy,
    mode,
    ready,
    connected: Boolean(account),
    connect,
    disconnect,
    refresh,
  }), [account, handle, chipLabel, chainId, error, busy, mode, ready, connect, disconnect, refresh])
}

export function BawWalletProvider({ children }) {
  const value = useBawWalletState()
  return <BawCtx.Provider value={value}>{children}</BawCtx.Provider>
}

export function useBawWallet() {
  const ctx = useContext(BawCtx)
  if (!ctx) throw new Error('useBawWallet must be used within BawWalletProvider')
  return ctx
}
