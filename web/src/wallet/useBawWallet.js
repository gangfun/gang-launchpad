import { useCallback, useEffect, useState } from 'react'
import {
  createPublicClient, createWalletClient, custom, http, parseAbi, formatEther,
} from 'viem'
import { bscTestnet } from 'viem/chains'
import { BAW_ONLY_MSG, getBawProvider, listRejectedProviders, requestProviders } from './baw.js'
import { STOCKS_CHAIN_ID, STOCKS_DIVIDEND_VAULT, STOCKS_RPC } from '../stocksConfig.js'

const VAULT_ABI = parseAbi([
  'function pending(address token, address user) view returns (uint256)',
  'function claim(address token) returns (uint256)',
  'function quoteOf(address token) view returns (address)',
])

const CHAPEL = {
  ...bscTestnet,
  id: 97,
  rpcUrls: { default: { http: [STOCKS_RPC] } },
}

function publicClient() {
  return createPublicClient({ chain: CHAPEL, transport: http(STOCKS_RPC) })
}

export function useBawWallet() {
  const [account, setAccount] = useState(null)
  const [chainId, setChainId] = useState(null)
  const [error, setError] = useState(null)
  const [busy, setBusy] = useState(false)

  const refresh = useCallback(async () => {
    const provider = getBawProvider()
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
    requestProviders()
    refresh()
    const provider = getBawProvider()
    if (!provider?.on) return undefined
    const onAcc = () => refresh()
    const onChain = (cid) => setChainId(Number(cid))
    provider.on('accountsChanged', onAcc)
    provider.on('chainChanged', onChain)
    return () => {
      provider.removeListener?.('accountsChanged', onAcc)
      provider.removeListener?.('chainChanged', onChain)
    }
  }, [refresh])

  const connect = useCallback(async () => {
    setError(null)
    setBusy(true)
    try {
      requestProviders()
      await new Promise((r) => setTimeout(r, 150))
      const provider = getBawProvider()
      if (!provider) {
        const rejected = listRejectedProviders()
        setError(
          rejected.length
            ? `${BAW_ONLY_MSG}（已检测到：${rejected.slice(0, 3).join('、')}）`
            : `${BAW_ONLY_MSG}。请安装 Binance Wallet / 在 Binance App 内打开，或使用 baw CLI。`,
        )
        return null
      }
      // Guard: if user somehow has only MetaMask as default ethereum and no Binance flags
      if (provider.isMetaMask && !(provider.isBinance || provider.isBinanceWallet || provider.isBinanceW3W)) {
        setError(BAW_ONLY_MSG)
        return null
      }
      const accounts = await provider.request({ method: 'eth_requestAccounts' })
      const addr = accounts?.[0] ? String(accounts[0]).toLowerCase() : null
      if (!addr) {
        setError(BAW_ONLY_MSG)
        return null
      }
      let cid = Number(await provider.request({ method: 'eth_chainId' }))
      if (cid !== STOCKS_CHAIN_ID) {
        try {
          await provider.request({
            method: 'wallet_switchEthereumChain',
            params: [{ chainId: `0x${STOCKS_CHAIN_ID.toString(16)}` }],
          })
          cid = STOCKS_CHAIN_ID
        } catch (e) {
          if (e?.code === 4902) {
            await provider.request({
              method: 'wallet_addEthereumChain',
              params: [{
                chainId: `0x${STOCKS_CHAIN_ID.toString(16)}`,
                chainName: 'BNB Smart Chain Testnet',
                nativeCurrency: { name: 'tBNB', symbol: 'tBNB', decimals: 18 },
                rpcUrls: [STOCKS_RPC],
                blockExplorerUrls: ['https://testnet.bscscan.com'],
              }],
            })
            cid = STOCKS_CHAIN_ID
          } else {
            setError(`请切换到 Chapel (chain ${STOCKS_CHAIN_ID})`)
            return null
          }
        }
      }
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

  const disconnect = useCallback(() => {
    setAccount(null)
    setError(null)
  }, [])

  const readPending = useCallback(async (token) => {
    if (!STOCKS_DIVIDEND_VAULT || !account || !token) return null
    try {
      const raw = await publicClient().readContract({
        address: STOCKS_DIVIDEND_VAULT,
        abi: VAULT_ABI,
        functionName: 'pending',
        args: [token, account],
      })
      return { wei: raw, formatted: formatEther(raw) }
    } catch {
      return null
    }
  }, [account])

  const claimDividend = useCallback(async (token) => {
    setError(null)
    setBusy(true)
    try {
      if (!STOCKS_DIVIDEND_VAULT) throw new Error('DividendVault 未配置')
      const provider = getBawProvider()
      if (!provider) throw new Error(BAW_ONLY_MSG)
      const addr = account || (await connect())
      if (!addr) throw new Error(BAW_ONLY_MSG)
      const wallet = createWalletClient({
        account: addr,
        chain: CHAPEL,
        transport: custom(provider),
      })
      const hash = await wallet.writeContract({
        address: STOCKS_DIVIDEND_VAULT,
        abi: VAULT_ABI,
        functionName: 'claim',
        args: [token],
        chain: CHAPEL,
        account: addr,
      })
      await publicClient().waitForTransactionReceipt({ hash })
      return hash
    } catch (e) {
      const msg = e?.shortMessage || e?.message || String(e)
      if (/rejected|denied|User rejected/i.test(msg)) setError('已取消签名')
      else if (/NothingToClaim|0x/i.test(msg) && /revert/i.test(msg)) setError('暂无可领分红')
      else setError(msg)
      return null
    } finally {
      setBusy(false)
    }
  }, [account, connect])

  return {
    account,
    chainId,
    error,
    busy,
    connected: Boolean(account),
    connect,
    disconnect,
    refresh,
    readPending,
    claimDividend,
    vault: STOCKS_DIVIDEND_VAULT,
  }
}
