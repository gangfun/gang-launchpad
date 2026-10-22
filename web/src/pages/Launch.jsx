import { useCallback, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { useT } from '../i18n.jsx'
import { api } from '../api.js'
import Cmd from '../components/Cmd.jsx'
import Win from '../components/Win.jsx'
import TokenAvatar from '../components/TokenAvatar.jsx'

const ADDR_RE = /^0x[a-fA-F0-9]{40}$/

function readFileAsDataUrl(file) {
  return new Promise((resolve, reject) => {
    const r = new FileReader()
    r.onload = () => resolve(r.result)
    r.onerror = () => reject(new Error('read failed'))
    r.readAsDataURL(file)
  })
}

export default function Launch() {
  const { t } = useT()
  const [name, setName] = useState('')
  const [symbol, setSymbol] = useState('')
  const [preview, setPreview] = useState(null)
  const [tokenAddr, setTokenAddr] = useState('')
  const [status, setStatus] = useState(null)
  const [busy, setBusy] = useState(false)

  const createCmd = useMemo(() => {
    const n = name.trim() || 'My Agent Coin'
    const s = symbol.trim().toUpperCase() || 'MAC'
    return `gang create --name "${n.replace(/"/g, '\\"')}" --symbol ${s}`
  }, [name, symbol])

  const onPick = useCallback(async (e) => {
    const file = e.target.files?.[0]
    if (!file) return
    if (!/^image\/(png|jpeg|webp|gif)$/i.test(file.type)) {
      setStatus({ err: t('launch_logo_type') })
      return
    }
    if (file.size > 512 * 1024) {
      setStatus({ err: t('launch_logo_size') })
      return
    }
    setPreview(await readFileAsDataUrl(file))
    setStatus(null)
  }, [t])

  const onRegisterLogo = useCallback(async () => {
    const addr = tokenAddr.trim().toLowerCase()
    if (!ADDR_RE.test(addr)) {
      setStatus({ err: t('launch_addr_invalid') })
      return
    }
    if (!preview) {
      setStatus({ err: t('launch_logo_missing') })
      return
    }
    setBusy(true)
    setStatus(null)
    try {
      const res = await api.setTokenLogo(addr, preview)
      setStatus({ ok: t('launch_logo_ok'), href: `/token/${res.address || addr}` })
    } catch (e) {
      setStatus({ err: t('launch_logo_fail') })
    } finally {
      setBusy(false)
    }
  }, [preview, tokenAddr, t])

  return (
    <main className="wrap launch-page">
      <section className="hero launch-hero">
        <span className="tag">{t('launch_tag')}</span>
        <h1>{t('launch_title')}</h1>
        <p className="muted launch-lead">{t('launch_lead')}</p>
      </section>

      <div className="launch-grid">
        <Win title={t('launch_form_title')}>
          <div className="launch-form">
            <label className="launch-field">
              <span>{t('launch_name')}</span>
              <input value={name} onChange={(e) => setName(e.target.value)} placeholder="My Agent Coin" autoComplete="off" />
            </label>
            <label className="launch-field">
              <span>{t('launch_symbol')}</span>
              <input value={symbol} onChange={(e) => setSymbol(e.target.value.toUpperCase())} placeholder="MAC" maxLength={12} autoComplete="off" />
            </label>
            <div className="launch-logo-pick">
              <span className="label">{t('launch_logo_label')}</span>
              <div className="launch-logo-row">
                <TokenAvatar symbol={symbol || '?'} address={tokenAddr || '0x0'} logoUrl={preview} size={64} />
                <label className="btn launch-file">
                  {t('launch_logo_choose')}
                  <input type="file" accept="image/png,image/jpeg,image/webp,image/gif" onChange={onPick} hidden />
                </label>
              </div>
              <p className="dim launch-hint">{t('launch_logo_hint')}</p>
            </div>
          </div>
        </Win>

        <Win title={t('launch_steps_title')}>
          <ol className="launch-steps">
            <li>
              <b>{t('launch_step_cli')}</b>
              <Cmd block>{createCmd}</Cmd>
              <Cmd block>gang execute --request-id …</Cmd>
              <Cmd block>gang tx --hash 0x…</Cmd>
            </li>
            <li>
              <b>{t('launch_step_addr')}</b>
              <input
                className="launch-addr"
                value={tokenAddr}
                onChange={(e) => setTokenAddr(e.target.value)}
                placeholder="0x…"
                spellCheck={false}
                autoComplete="off"
              />
            </li>
            <li>
              <b>{t('launch_step_logo')}</b>
              <button type="button" className="btn" disabled={busy || !preview} onClick={onRegisterLogo}>
                {busy ? t('loading') : t('launch_register_logo')}
              </button>
              {status?.ok && (
                <p className="launch-status ok">
                  {status.ok}
                  {status.href && <Link to={status.href}>{t('launch_view_token')}</Link>}
                </p>
              )}
              {status?.err && <p className="launch-status err">{status.err}</p>}
            </li>
          </ol>
          <p className="dim launch-feasibility">
            <Link to="/docs#token-logos">{t('launch_metadata_link')}</Link>
          </p>
        </Win>
      </div>
    </main>
  )
}
