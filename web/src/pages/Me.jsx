import { useCallback, useState } from 'react'
import { Link, Navigate, useNavigate } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { api, short } from '../api.js'
import { DIVIDEND_CHAIN_ID, DIVIDEND_VAULT } from '../dividendConfig.js'
import { useT } from '../i18n.jsx'
import { useActiveWallet } from '../wallet/useActiveWallet.js'
import Win from '../components/Win.jsx'
import Cmd from '../components/Cmd.jsx'
import ClaimDividend from '../components/ClaimDividend.jsx'

function ActivityList({ loading, items, empty, linkKey = 'token' }) {
  const { t } = useT()
  if (loading) return <p className="muted me-card-empty">{t('loading')}</p>
  if (!items?.length) return <p className="muted me-card-empty">{empty}</p>
  return (
    <ul className="me-list">
      {items.map((r) => {
        const addr = r[linkKey] || r.address || r.token
        const key = r.tx || `${addr}-${r.ts || r.address}`
        return (
          <li key={key}>
            <Link to={`/token/${addr}`}>{r.symbol || short(addr)}</Link>
            <span className="muted">{r.side || r.name || ''}</span>
          </li>
        )
      })}
    </ul>
  )
}

export default function Me() {
  const { t } = useT()
  const nav = useNavigate()
  const w = useActiveWallet()
  const [confirmOut, setConfirmOut] = useState(false)
  const [copied, setCopied] = useState(false)
  const addr = w.address
  const handle = w.handle
  const vault = DIVIDEND_VAULT

  const buys = useQuery({
    queryKey: ['me-buys', addr],
    queryFn: () => api.walletBuys(addr),
    enabled: !!addr,
  })
  const deploys = useQuery({
    queryKey: ['me-deploys', addr],
    queryFn: () => api.walletDeploys(addr),
    enabled: !!addr,
  })

  const doDisconnect = useCallback(async () => {
    await w.disconnect()
    setConfirmOut(false)
    nav('/')
  }, [w, nav])

  if (!w.ready) {
    return <main className="wrap me-page"><div className="empty">{t('loading')}</div></main>
  }
  if (!w.connected || !addr) return <Navigate to="/" replace />

  const steps = t('me_claim_agent_steps')
  const vaultTo = vault || '<VITE_DIVIDEND_VAULT>'
  const cliHowto = [
    `baw contract-call preview --binanceChainId ${DIVIDEND_CHAIN_ID} --from ${addr} --to ${vaultTo} --inputData <claim(token) calldata> --json`,
    'baw contract-call execute --requestId <id> --json',
  ].join('\n')

  return (
    <main className="wrap me-page">
      <div className="me-stack">
        <Win title={t('me_title')} right={<span className="tag dim">BAW</span>}>
          <div className="me-profile">
            <div className="me-profile-main">
              <div className="me-handle">{handle || 'BAW'}</div>
              <code className="me-addr-code" title={addr}>{short(addr)}</code>
              <button
                type="button"
                className="btn ghost baw-btn me-chip-btn"
                onClick={() => {
                  navigator.clipboard?.writeText(addr).then(() => {
                    setCopied(true)
                    setTimeout(() => setCopied(false), 1200)
                  })
                }}
              >
                {copied ? t('copied') : t('me_copy')}
              </button>
            </div>
            <button type="button" className="btn danger baw-btn me-chip-btn" onClick={() => setConfirmOut(true)}>
              {t('me_disconnect')}
            </button>
          </div>
        </Win>

        <Win title={t('me_claim')} right={<span className="tag">{t('me_claim_tag')}</span>}>
          <div className="me-claim-wrap">
            <ClaimDividend dense />
            <div className="me-claim-agent" data-agent-doc="me-claim-dividend">
              <h3 className="me-claim-agent-h">{t('me_claim_agent_title')}</h3>
              <ol className="me-claim-agent-ol">
                {(Array.isArray(steps) ? steps : []).map((line) => <li key={line}>{line}</li>)}
              </ol>
              <Cmd block>{cliHowto}</Cmd>
              <p className="muted me-claim-agent-note">{t('me_claim_agent_note')}</p>
            </div>
          </div>
        </Win>

        <div className="me-grid">
          <Win title={t('me_buys')} flush>
            <div className="me-card-body">
              <ActivityList loading={buys.isLoading} items={buys.data?.items} empty={t('me_empty')} linkKey="token" />
            </div>
          </Win>
          <Win title={t('me_deploys')} flush>
            <div className="me-card-body">
              <ActivityList loading={deploys.isLoading} items={deploys.data?.items} empty={t('me_empty')} linkKey="address" />
            </div>
          </Win>
        </div>
      </div>

      {confirmOut ? (
        <div
          className="baw-qr-modal"
          role="dialog"
          aria-modal="true"
          aria-label={t('me_disconnect_confirm')}
          onClick={(e) => { if (e.target === e.currentTarget) setConfirmOut(false) }}
        >
          <div className="baw-qr-card">
            <strong>{t('me_disconnect_confirm')}</strong>
            <div className="me-confirm-actions">
              <button type="button" className="btn ghost baw-btn" onClick={() => setConfirmOut(false)}>{t('me_cancel')}</button>
              <button type="button" className="btn danger baw-btn" onClick={doDisconnect}>{t('me_disconnect')}</button>
            </div>
          </div>
        </div>
      ) : null}
    </main>
  )
}
