import { useState } from 'react'
import { Link } from 'react-router-dom'
import { api, API, short } from '../api.js'
import { useT } from '../i18n.jsx'
import Win from '../components/Win.jsx'

const ADDR_RE = /^0x[a-fA-F0-9]{40}$/

function readFileAsDataUrl(file) {
  return new Promise((resolve, reject) => {
    const r = new FileReader()
    r.onload = () => resolve(r.result)
    r.onerror = () => reject(new Error('read failed'))
    r.readAsDataURL(file)
  })
}

/** Dev-only logo upload — not a public launch entry. Uses POST /api/tokens/:addr/logo. */
export default function DevLogo() {
  const { t } = useT()
  const [addr, setAddr] = useState('')
  const [file, setFile] = useState(null)
  const [preview, setPreview] = useState('')
  const [status, setStatus] = useState('')
  const [busy, setBusy] = useState(false)

  const onFile = async (e) => {
    const f = e.target.files?.[0]
    setFile(f || null)
    setPreview('')
    if (!f) return
    try {
      const data = await readFileAsDataUrl(f)
      setPreview(String(data))
    } catch {
      setStatus(t('dev_logo_read_err'))
    }
  }

  const submit = async (e) => {
    e.preventDefault()
    const a = addr.trim().toLowerCase()
    if (!ADDR_RE.test(a)) {
      setStatus(t('dev_logo_bad_addr'))
      return
    }
    if (!preview?.startsWith('data:image/')) {
      setStatus(t('dev_logo_need_img'))
      return
    }
    setBusy(true)
    setStatus('')
    try {
      const res = await api.setTokenLogo(a, preview)
      setStatus(t('dev_logo_ok', { addr: short(a), url: res.logoUrl || `${API}/tokens/${a}/logo` }))
    } catch (err) {
      setStatus(t('dev_logo_fail', { err: String(err.message || err) }))
    } finally {
      setBusy(false)
    }
  }

  return (
    <main className="wrap">
      <div className="dev-banner" role="status">
        {t('dev_logo_banner')}
      </div>
      <section className="hero">
        <span className="tag">DEV</span>
        <h1>{t('dev_logo_title')}</h1>
        <p className="muted">{t('dev_logo_lead')}</p>
      </section>
      <Win title={t('dev_logo_form')}>
        <form className="dev-logo-form" onSubmit={submit}>
          <label>
            <span>{t('dev_logo_addr')}</span>
            <input
              value={addr}
              onChange={(e) => setAddr(e.target.value)}
              placeholder="0x…"
              spellCheck={false}
              autoComplete="off"
            />
          </label>
          <label>
            <span>{t('dev_logo_file')}</span>
            <input type="file" accept="image/png,image/jpeg,image/webp,image/gif" onChange={onFile} />
          </label>
          {preview && (
            <div className="dev-logo-preview">
              <img src={preview} alt="" width={96} height={96} />
              <span className="muted">{file?.name} · {Math.round((file?.size || 0) / 1024)} KB</span>
            </div>
          )}
          <button type="submit" disabled={busy}>{busy ? t('loading') : t('dev_logo_submit')}</button>
        </form>
        {status && <p className="dev-logo-status muted">{status}</p>}
        <p className="muted" style={{ marginTop: 12 }}>
          <Link to="/docs">{t('nav_guide')}</Link>
          {' · '}
          <Link to="/">{t('nav_markets')}</Link>
        </p>
      </Win>
    </main>
  )
}
