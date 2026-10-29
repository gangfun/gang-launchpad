import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react'
import {
  AGENT_SIGNIN_POLL_MS,
  AGENT_SIGNIN_TIMEOUT_MS,
  agentApi,
} from './agentApi.js'

const AgentWalletContext = createContext(null)

/**
 * Binance Agent Wallet session. Header chip and /me share this provider.
 * Production default is real mode (stub false) so the QR modal stays quiet
 * until a BFF explicitly reports a stub session.
 */
function useAgentWalletState() {
  const [csrf, setCsrf] = useState(null)
  const [status, setStatus] = useState('idle')
  const [address, setAddress] = useState(null)
  const [signin, setSignin] = useState(null)
  const [error, setError] = useState(null)
  const [stubNote, setStubNote] = useState(null)
  const [noTestnet, setNoTestnet] = useState(true)
  const [stub, setStub] = useState(false)
  const [mode, setMode] = useState('real')
  const [handle, setHandle] = useState(null)
  const [aiDomain, setAiDomain] = useState(null)
  const [sessionReady, setSessionReady] = useState(false)
  const pollRef = useRef(null)
  const startedAt = useRef(0)
  const statusRef = useRef(status)
  useEffect(() => { statusRef.current = status }, [status])

  const stopPoll = useCallback(() => {
    if (pollRef.current) {
      clearInterval(pollRef.current)
      pollRef.current = null
    }
  }, [])

  const refreshSession = useCallback(async () => {
    try {
      const data = await agentApi.getSession()
      setCsrf(data.csrf_token || null)
      setStubNote(data.stub_note || null)
      setNoTestnet(data.no_testnet !== false)
      setStub(data.stub !== false)
      setMode(data.mode || (data.stub === false ? 'real' : 'stub'))
      if (data.session?.status === 'connected' && data.session.address) {
        setStatus('connected')
        setAddress(data.session.address)
        const h = data.session.handle || data.session.aiDomain || null
        setHandle(h)
        setAiDomain(data.session.aiDomain || h)
      } else if (statusRef.current !== 'pending') {
        setStatus('idle')
        setAddress(null)
        setHandle(null)
        setAiDomain(null)
      }
      return data
    } catch (e) {
      setError(e.message)
      return null
    } finally {
      setSessionReady(true)
    }
  }, [])

  useEffect(() => {
    refreshSession()
    return stopPoll
  }, []) // eslint-disable-line react-hooks/exhaustive-deps

  const beginSignin = useCallback(async () => {
    setError(null)
    setSignin(null)
    setStatus('loading')
    stopPoll()
    try {
      let tok = csrf
      if (!tok) {
        const s = await agentApi.getSession()
        tok = s.csrf_token
        setCsrf(tok)
        setStubNote(s.stub_note || null)
        setNoTestnet(s.no_testnet !== false)
        setStub(s.stub !== false)
        setMode(s.mode || (s.stub === false ? 'real' : 'stub'))
      }
      const data = await agentApi.beginSignin(tok)
      const s2 = await agentApi.getSession()
      if (s2?.csrf_token) setCsrf(s2.csrf_token)
      setStub(data.stub !== false)
      setMode(data.mode || (data.stub === false ? 'real' : 'stub'))
      setStubNote(data.stub_note || null)
      const expireAt = Number(data.expire_at) || (Date.now() + AGENT_SIGNIN_TIMEOUT_MS)
      setSignin({
        uid: data.uid,
        signin_url: data.signin_url,
        pairing_code: data.pairing_code,
        mobile_url: data.mobile_url,
        expire_at: expireAt,
        stub: data.stub,
      })
      setStatus('pending')
      startedAt.current = Date.now()
      const uid = data.uid
      pollRef.current = setInterval(async () => {
        try {
          const polled = await agentApi.pollSignin(uid)
          const expireAt = Number(polled.expire_at) || 0
          if (expireAt > 0) {
            setSignin((prev) => (prev ? { ...prev, expire_at: expireAt } : prev))
          }
          const timedOut =
            Date.now() - startedAt.current > AGENT_SIGNIN_TIMEOUT_MS
            || (expireAt > 0 && Date.now() > expireAt)
          if (timedOut || polled.status === 'expired') {
            stopPoll()
            setStatus('expired')
            return
          }
          if (polled.status === 'connected') {
            stopPoll()
            setStatus('connected')
            setAddress(polled.address || polled.session?.address || null)
            const h = polled.handle || polled.session?.handle || polled.aiDomain || polled.session?.aiDomain || null
            setHandle(h)
            setAiDomain(polled.aiDomain || polled.session?.aiDomain || h)
            setSignin((prev) => (prev ? { ...prev, status: 'connected' } : prev))
            refreshSession().catch(() => {})
          } else if (polled.status === 'expired' || polled.status === 'cancelled' || polled.status === 'failed') {
            stopPoll()
            setStatus(polled.status)
          }
        } catch (e) {
          setError(e.message)
        }
      }, AGENT_SIGNIN_POLL_MS)
      return data
    } catch (e) {
      setStatus('failed')
      setError(e.message)
      return null
    }
  }, [csrf, stopPoll, refreshSession])

  const simulateConnect = useCallback(async () => {
    if (!signin?.uid || !csrf) return null
    try {
      const data = await agentApi.simulateSignin(signin.uid, csrf)
      stopPoll()
      setStatus('connected')
      setAddress(data.address)
      return data
    } catch (e) {
      setError(e.message)
      return null
    }
  }, [signin, csrf, stopPoll])

  const disconnect = useCallback(async () => {
    stopPoll()
    try {
      if (csrf) await agentApi.disconnect(csrf)
    } catch { /* ignore */ }
    setStatus('idle')
    setAddress(null)
    setHandle(null)
    setAiDomain(null)
    setSignin(null)
    await refreshSession()
  }, [csrf, stopPoll, refreshSession])

  const cancelSignin = useCallback(() => {
    stopPoll()
    setSignin(null)
    setStatus(address ? 'connected' : 'idle')
  }, [stopPoll, address])

  const chipLabel = handle
    ? (String(handle).includes('.') ? String(handle) : `${handle}.ai`)
    : (address ? `BAW ${address.slice(0, 6)}…${address.slice(-4)}` : null)

  return useMemo(() => ({
    status,
    address,
    handle,
    aiDomain,
    chipLabel,
    connected: status === 'connected' && Boolean(address),
    sessionReady,
    signin,
    error,
    stubNote,
    stub,
    mode,
    noTestnet,
    busy: status === 'loading' || status === 'pending',
    beginSignin,
    simulateConnect,
    disconnect,
    cancelSignin,
    refreshSession,
  }), [
    status, address, handle, aiDomain, chipLabel, sessionReady, signin, error,
    stubNote, stub, mode, noTestnet, beginSignin, simulateConnect, disconnect,
    cancelSignin, refreshSession,
  ])
}

export function AgentWalletProvider({ children }) {
  const value = useAgentWalletState()
  return (
    <AgentWalletContext.Provider value={value}>
      {children}
    </AgentWalletContext.Provider>
  )
}

export function useAgentWallet() {
  const ctx = useContext(AgentWalletContext)
  if (!ctx) throw new Error('useAgentWallet must be used within AgentWalletProvider')
  return ctx
}
