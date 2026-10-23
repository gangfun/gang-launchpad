import { useCallback } from 'react'
import { useAgentWallet } from './useAgentWallet.jsx'
import { useBawWallet } from './useBawWallet.jsx'

/** Agent web sign-in wins over an injected Binance provider when both are connected. */
export function useActiveWallet() {
  const agent = useAgentWallet()
  const baw = useBawWallet()
  const viaAgent = Boolean(agent.connected && agent.address)
  const address = (viaAgent ? agent.address : baw.account) || null
  const handle = viaAgent ? (agent.chipLabel || null) : (baw.chipLabel || null)
  const disconnect = useCallback(async () => {
    if (agent.connected) await agent.disconnect()
    if (baw.connected) await baw.disconnect()
  }, [agent, baw])
  return {
    address,
    handle,
    connected: Boolean(address),
    ready: agent.sessionReady && baw.ready,
    disconnect,
  }
}
