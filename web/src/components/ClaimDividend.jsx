import { useCallback, useEffect, useMemo, useState } from 'react'
import { createPublicClient, createWalletClient, custom, encodeFunctionData, formatEther, http, parseAbi } from 'viem'
import { bsc } from 'viem/chains'
import { short } from '../api.js'
import {
  DIVIDEND_EXPLORER,
  DIVIDEND_RPC,
  DIVIDEND_VAULT,
  dividendConfigured,
  dividendTokens,
} from '../dividendConfig.js'
import { useT } from '../i18n.jsx'
import { getActiveProvider } from '../wallet/baw.js'
import { useActiveWallet } from '../wallet/useActiveWallet.js'
import Cmd from './Cmd.jsx'

const VAULT_ABI = parseAbi([
  'function pending(address token, address user) view returns (uint256)',
  'function claim(address token) returns (uint256)',
])

function rpc() {
  return createPublicClient({ chain: bsc, transport: http(DIVIDEND_RPC) })
}

/**
 * In-page dividend claim. Reads and sends only when VITE_DIVIDEND_VAULT is set.
 * Chain is BSC mainnet (viem bsc / chainId 56). No hardcoded vault address.
 */
export default function ClaimDividend({ dense = false }) {
  const { t } = useT()
  const w = useActiveWallet()
  const user = w.address
  const vault = DIVIDEND_VAULT
  const configured = dividendConfigured()
  const tokenRows = useMemo(() => dividendTokens(), [])
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState(null)
  const [tx, setTx] = useState(null)
  const [pendingMap, setPendingMap] = useState({})
  const [active, setActive] = useState(tokenRows[0]?.address || null)

  const refreshPending = useCallback(async () => {
    if (!user || !configured || !tokenRows.length) {
      setPendingMap({})
      return
    }
    const client = rpc()
    const next = {}
    await Promise.all(tokenRows.map(async (r) => {
      try {
        const raw = await client.readContract({
          address: vault,
          abi: VAULT_ABI,
          functionName: 'pending',
          args: [r.address, user],
        })
        next[r.address] = { wei: raw, formatted: formatEther(raw) }
      } catch {
        next[r.address] = null
      }
    }))
    setPendingMap(next)
  }, [user, configured, vault, tokenRows])

  useEffect(() => {
    if (!configured) return undefined
    refreshPending()
    const id = setInterval(refreshPending, 15_000)
    return () => clearInterval(id)
  }, [refreshPending, configured])

  const claimCalldata = useCallback((token) => encodeFunctionData({
    abi: VAULT_ABI,
    functionName: 'claim',
    args: [token],
  }), [])

  const onClaim = async (token) => {
    setErr(null)
    setTx(null)
    setBusy(true)
    setActive(token)
    try {
      if (!user) throw new Error(t('me_claim_need_baw'))
      if (!configured) throw new Error(t('me_claim_unconfigured'))
      const pend = pendingMap[token]
      if (!(Number(pend?.formatted) > 0)) throw new Error(t('me_claim_nothing'))
      const provider = getActiveProvider()
      if (!provider?.request) {
        setTx('cli')
        return
      }
      try {
        const wallet = createWalletClient({ account: user, chain: bsc, transport: custom(provider) })
        const hash = await wallet.writeContract({
          address: vault,
          abi: VAULT_ABI,
          functionName: 'claim',
          args: [token],
          chain: bsc,
          account: user,
        })
        setTx(hash)
        await refreshPending()
      } catch (e) {
        if (/rejected|denied|User rejected/i.test(String(e?.message || e))) {
          setErr(t('me_claim_cancelled'))
          return
        }
        setTx('cli')
      }
    } catch (e) {
      setErr(e?.shortMessage || e?.message || String(e))
    } finally {
      setBusy(false)
    }
  }

  if (!configured) {
    return (
      <div className={`claim-div me-claim${dense ? ' me-claim-dense' : ''}`}>
        <p className="muted me-claim-one">{t('me_claim_hint_short')}</p>
        <p className="muted">{t('me_claim_unconfigured')}</p>
      </div>
    )
  }

  if (!user) return <p className="muted me-claim-one">{t('me_claim_need_baw')}</p>

  const cliToken = active || tokenRows[0]?.address || ''
  const cliData = cliToken ? claimCalldata(cliToken) : '0x'

  return (
    <div className={`claim-div me-claim${dense ? ' me-claim-dense' : ''}`}>
      <p className="muted me-claim-one">{dense ? t('me_claim_hint_short') : t('me_claim_hint')}</p>
      <p className="muted dim">{short(vault)}</p>
      {!tokenRows.length ? <p className="muted">{t('me_claim_no_tokens')}</p> : null}
      <ul className="me-claim-list">
        {tokenRows.map((r) => {
          const pend = pendingMap[r.address]
          const amt = pend ? Number(pend.formatted) : 0
          return (
            <li key={r.address} className="me-claim-row">
              <div className="me-claim-meta">
                <strong>{r.symbol || short(r.address)}</strong>
                <code className="dim">{short(r.address)}</code>
                <span className="num">{pend ? `${amt > 0 ? amt.toPrecision(6) : '0'}` : '—'}</span>
              </div>
              <button
                type="button"
                className="btn baw-btn"
                disabled={busy || !(amt > 0)}
                onClick={() => onClaim(r.address)}
              >
                {busy && active === r.address ? t('loading') : t('me_claim_go')}
              </button>
            </li>
          )
        })}
      </ul>
      {err ? <p className="baw-err">{err}</p> : null}
      {tx && tx !== 'cli' ? (
        <p className="ok">
          <a href={`${DIVIDEND_EXPLORER}/tx/${tx}`} target="_blank" rel="noreferrer">{short(tx)}</a>
        </p>
      ) : null}
      {tx === 'cli' && cliToken ? (
        <div className="me-claim-cli" role="status">
          <p className="muted">{t('me_claim_cli_lead')}</p>
          <Cmd block>{`baw contract-call preview --binanceChainId 56 --from ${user} --to ${vault} --inputData ${cliData} --json
baw contract-call execute --requestId <id> --json`}</Cmd>
        </div>
      ) : null}
    </div>
  )
}
