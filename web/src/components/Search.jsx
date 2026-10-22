import { useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { api, short } from '../api.js'
import { useT } from '../i18n.jsx'

const isAddr = (s) => /^0x[0-9a-fA-F]{40}$/.test(s.trim())

export default function Search() {
  const { t } = useT()
  const nav = useNavigate()
  const [q, setQ] = useState('')
  const [rows, setRows] = useState([])
  const [open, setOpen] = useState(false)
  const [sel, setSel] = useState(0)
  const box = useRef(null)

  useEffect(() => {
    const s = q.trim()
    if (s.length < 2) { setRows([]); return }
    const h = setTimeout(() => api.search(s).then((r) => { setRows(r); setSel(0); setOpen(true) }).catch(() => setRows([])), 150)
    return () => clearTimeout(h)
  }, [q])
  useEffect(() => {
    const onDoc = (e) => { if (!box.current?.contains(e.target)) setOpen(false) }
    document.addEventListener('mousedown', onDoc); return () => document.removeEventListener('mousedown', onDoc)
  }, [])

  const go = (addr) => { setQ(''); setOpen(false); nav(`/token/${addr.toLowerCase()}`) }
  const onKey = (e) => {
    if (e.key === 'Enter') { if (isAddr(q)) go(q); else if (rows[sel]) go(rows[sel].address) }
    else if (e.key === 'ArrowDown') { setSel((i) => Math.min(rows.length - 1, i + 1)); e.preventDefault() }
    else if (e.key === 'ArrowUp') { setSel((i) => Math.max(0, i - 1)); e.preventDefault() }
    else if (e.key === 'Escape') setOpen(false)
  }
  return (
    <div className="search" ref={box}>
      <input value={q} onChange={(e) => setQ(e.target.value)} onFocus={() => rows.length && setOpen(true)} onKeyDown={onKey} placeholder={t('search_ph')} spellCheck={false} />
      {open && q.trim().length >= 2 && (
        <div className="dd">
          {rows.length === 0 && !isAddr(q) && <button disabled className="dim">{t('no_results')}</button>}
          {rows.length === 0 && isAddr(q) && <button onClick={() => go(q)}>{short(q)} <span className="dim">→</span></button>}
          {rows.map((r, i) => <button key={r.address} className={i === sel ? 'on' : ''} onMouseEnter={() => setSel(i)} onClick={() => go(r.address)}>{r.symbol} {r.graduated && <span className="badge grad">{t('graduated')}</span>} <span className="dim">{r.name} · {short(r.address)}</span></button>)}
        </div>
      )}
    </div>
  )
}
