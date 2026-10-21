export const API = import.meta.env.VITE_API_URL || 'http://127.0.0.1:8787'
export const LAUNCHPAD = import.meta.env.VITE_LAUNCHPAD || '0x86854E8ee7D438ca9B52407DCF92D1616385dDcc'
const get = (p) => fetch(`${API}${p}`).then((r) => { if (!r.ok) throw new Error(`${r.status}`); return r.json() })
export const api = {
  stats: () => get('/stats'),
  tokens: (sort, limit = 20) => get(`/tokens?sort=${sort}&limit=${limit}`),
  token: (a) => get(`/tokens/${a}`),
  trades: (a, limit = 50) => get(`/tokens/${a}/trades?limit=${limit}`),
  holders: (a, limit = 20) => get(`/tokens/${a}/holders?limit=${limit}`),
  candles: (a, res) => get(`/tokens/${a}/candles?res=${res}`),
  search: (q) => get(`/search?q=${encodeURIComponent(q)}`),
}
export const short = (a) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : '')
export const ago = (ts) => { if (!ts) return '—'; const s = Math.max(1, Math.floor(Date.now() / 1000 - ts)); return s < 60 ? `${s}s` : s < 3600 ? `${Math.floor(s / 60)}m` : s < 86400 ? `${Math.floor(s / 3600)}h` : `${Math.floor(s / 86400)}d` }
export const bnb = (v, d = 4) => Number(v).toLocaleString('en-US', { maximumFractionDigits: d })
/** DEX-style small number: 0.0000000625 -> 0.0₈625 */
export const px = (v) => {
  const n = Number(v); if (!n) return '0'
  if (n >= 1) return n.toLocaleString('en-US', { maximumFractionDigits: 4 })
  const s = n.toFixed(18).replace(/0+$/, ''); const m = s.match(/^0\.(0*)(\d+)$/); if (!m) return s
  const zeros = m[1].length, digits = m[2].slice(0, 4)
  return zeros >= 3 ? `0.0${String(zeros).replace(/\d/g, (d) => '₀₁₂₃₄₅₆₇₈₉'[d])}${digits}` : `0.${m[1]}${digits}`
}
/** compact USD: 4642 -> $4.64K */
export const usd = (v) => { const n = Number(v); if (!(n > 0)) return '—'; if (n >= 1e9) return `$${(n / 1e9).toFixed(2)}B`; if (n >= 1e6) return `$${(n / 1e6).toFixed(2)}M`; if (n >= 1e4) return `$${(n / 1e3).toFixed(1)}K`; if (n >= 1) return `$${n.toLocaleString('en-US', { maximumFractionDigits: 2 })}`; return `$${px(n)}` }
export const tok = (v) => Number(v).toLocaleString('en-US', { maximumFractionDigits: 0 })
