import { useCallback, useEffect, useState } from 'react'
import { createPortal } from 'react-dom'
import { Link } from 'react-router-dom'
import { useT } from '../i18n.jsx'
import { BAW_ONLY_MSG } from '../wallet/baw.js'
import { useActiveWallet } from '../wallet/useActiveWallet.js'
import { useAgentWallet } from '../wallet/useAgentWallet.jsx'
import { useBawWallet } from '../wallet/useBawWallet.jsx'

function formatClock(msLeft) {
  const total = Math.max(0, Math.ceil(msLeft / 1000))
  const m = Math.floor(total / 60)
  const ss = String(total % 60).padStart(2, '0')
  return `${m}:${ss}`
}

/** Live m:ss from sign-in expire_at (ms epoch). Poll refreshes that timestamp. */
function QrTtl({ expireAt }) {
  const { t } = useT()
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(id)
  }, [])
  const end = Number(expireAt) || 0
  if (!end) return null
  const clock = formatClock(end - now)
  const left = String(t('wallet_qr_ttl_left')).replace('{time}', clock)
  return (
    <p className="baw-qr-ttl muted" aria-live="polite">
      {t('wallet_qr_ttl_hint')}
      {' · '}
      {left}
    </p>
  )
}

/** Inject (Binance extension) + Agent sign-in QR. Chip is the .ai handle and opens /me. */
export default function ConnectBaw({ compact = false }) {
  const { t } = useT()
  const active = useActiveWallet()
  const agent = useAgentWallet()
  const baw = useBawWallet()
  const [qrOpen, setQrOpen] = useState(false)
  const [qrDataUrl, setQrDataUrl] = useState(null)

  const closeQr = useCallback(() => {
    setQrOpen(false)
    setQrDataUrl(null)
    if (!agent.connected) agent.cancelSignin()
  }, [agent])

  const paintQr = useCallback(async (signinUrl) => {
    if (!signinUrl || !String(signinUrl).startsWith('https:')) {
      setQrDataUrl(null)
      return
    }
    try {
      const QRCode = (await import('qrcode')).default
      const url = await QRCode.toDataURL(signinUrl, {
        width: 280,
        margin: 2,
        color: { dark: '#000000', light: '#ffffff' },
      })
      setQrDataUrl(url)
    } catch {
      setQrDataUrl(null)
    }
  }, [])

  const openQr = useCallback(async () => {
    setQrOpen(true)
    setQrDataUrl(null)
    const data = await agent.beginSignin()
    if (data?.signin_url) {
      if (!String(data.signin_url).startsWith('https:')) {
        agent.cancelSignin()
        setQrOpen(false)
        return
      }
      await paintQr(data.signin_url)
    }
  }, [agent, paintQr])

  useEffect(() => {
    if (agent.connected && qrOpen) {
      setQrOpen(false)
      setQrDataUrl(null)
    }
  }, [agent.connected, qrOpen])

  useEffect(() => {
    if (!qrOpen) return undefined
    const onKey = (e) => { if (e.key === 'Escape') closeQr() }
    document.addEventListener('keydown', onKey)
    const prev = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    return () => {
      document.removeEventListener('keydown', onKey)
      document.body.style.overflow = prev
    }
  }, [qrOpen, closeQr])

  if (active.connected && active.address) {
    const chip = active.handle || `BAW ${active.address.slice(0, 6)}…${active.address.slice(-4)}`
    return (
      <div className="baw-connect on">
        <Link to="/me" className="btn ghost baw-btn" title={active.handle ? `${active.handle} · ${active.address}` : active.address}>
          {compact ? chip : `${t('baw_connected')} ${chip}`}
        </Link>
      </div>
    )
  }

  const err = baw.error
  const isBawOnly = Boolean(err && (err === BAW_ONLY_MSG || String(err).startsWith(`${BAW_ONLY_MSG}:`) || String(err).startsWith(BAW_ONLY_MSG)))
  const errVisible = !err ? null : (isBawOnly ? t('baw_only') : err)
  const expired = agent.status === 'expired'
  const failed = agent.status === 'failed'

  const modal = qrOpen && typeof document !== 'undefined'
    ? createPortal(
      <div
        className="baw-qr-modal"
        role="dialog"
        aria-modal="true"
        aria-label={t('baw_qr_title')}
        onClick={(e) => { if (e.target === e.currentTarget) closeQr() }}
      >
        <div className={`baw-qr-card${expired ? ' is-expired' : ''}${failed ? ' is-failed' : ''}`}>
          <div className="baw-qr-head">
            <strong>{t('baw_qr_title')}</strong>
            <button type="button" className="btn ghost baw-btn" onClick={closeQr}>{t('baw_qr_close')}</button>
          </div>
          {agent.stub !== false ? (
            <p className="stub-banner" role="status">{t('wallet_stub_banner')}</p>
          ) : null}
          {!expired && !failed ? <p className="baw-qr-copy">{t('baw_qr_scan')}</p> : null}
          {!expired && !failed ? <QrTtl expireAt={agent.signin?.expire_at} /> : null}
          <div className={`baw-qr-stage${expired ? ' expired' : ''}`}>
            {qrDataUrl && !failed ? (
              <img className="baw-qr-img" src={qrDataUrl} alt="" width={260} height={260} />
            ) : (
              <div className="baw-qr-loading">
                {failed ? (agent.error || t('wallet_failed')) : t('baw_qr_waiting')}
              </div>
            )}
            {expired ? (
              <div className="baw-qr-expired-overlay" role="status">
                <div className="baw-expired-title">{t('wallet_expired_title')}</div>
                <p className="baw-expired-body">{t('wallet_expired_body')}</p>
                <button type="button" className="btn baw-btn" onClick={openQr} disabled={agent.status === 'loading'}>
                  {agent.status === 'loading' ? t('loading') : t('wallet_get_new_code')}
                </button>
              </div>
            ) : null}
          </div>
          {!expired && agent.signin?.pairing_code ? (
            <p className="pairing-code">
              <span className="muted">{t('wallet_pairing_label')}</span>
              {' '}<code>{agent.signin.pairing_code}</code>
            </p>
          ) : null}
          {!expired && agent.signin?.signin_url?.startsWith('https:') ? (
            <p className="agent-open-links">
              <a href={agent.signin.signin_url} target="_blank" rel="noreferrer">{t('wallet_open_signin')}</a>
            </p>
          ) : null}
          {!expired && !failed && (agent.status === 'pending' || agent.status === 'loading') ? (
            <p className="poll-status muted">{t('wallet_polling')}</p>
          ) : null}
          {failed ? (
            <div className="baw-expired-actions">
              <p className="baw-err baw-qr-err">{agent.error || t('wallet_failed')}</p>
              <button type="button" className="btn baw-btn" onClick={openQr} disabled={agent.status === 'loading'}>
                {agent.status === 'loading' ? t('loading') : t('wallet_get_new_code')}
              </button>
            </div>
          ) : null}
          {!expired && !failed && agent.stub !== false ? (
            <div className="stub-actions">
              <button type="button" className="btn ghost baw-btn" onClick={() => agent.simulateConnect()} disabled={!agent.signin?.uid}>
                {t('wallet_simulate')}
              </button>
            </div>
          ) : null}
          {agent.error && !failed && !expired ? <p className="baw-err baw-qr-err">{agent.error}</p> : null}
        </div>
      </div>,
      document.body,
    )
    : null

  return (
    <div className="baw-connect">
      <button type="button" className="btn baw-btn" disabled={baw.busy} onClick={baw.connect} title={t('baw_only_hint')}>
        {baw.busy ? t('loading') : (compact ? t('connect_short') : t('baw_connect'))}
      </button>
      <button type="button" className="btn ghost baw-btn baw-qr-btn" disabled={agent.busy && !qrOpen} onClick={openQr} title={t('baw_qr_scan')}>
        {t('baw_qr')}
      </button>
      {errVisible && !qrOpen ? <span className="baw-err" title={err}>{errVisible}</span> : null}
      {modal}
    </div>
  )
}
