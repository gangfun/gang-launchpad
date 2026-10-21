import { useNavigate } from 'react-router-dom'
import { ago, px, short, usd, api } from '../api.js'
import { useQuery } from '@tanstack/react-query'
import { useT } from '../i18n.jsx'

export default function TokenTable({ rows, loading, error }) {
  const nav = useNavigate()
  const { t } = useT()
  const rate = useQuery({ queryKey: ['stats'], queryFn: api.stats }).data?.bnbUsd || 0
  if (loading) return <div className="empty">{t('loading')}</div>
  if (error) return <div className="empty err">{t('api_error')}</div>
  if (!rows?.length) return <div className="empty">{t('empty')}</div>
  return (
    <div className="market-scroll"><table>
      <thead><tr>
        <th>{t('col_token')}</th><th className="r">{t('col_mcap')}</th><th className="r">{t('col_price')}</th><th className="r">{t('col_vol')}</th><th className="r">{t('col_trades')}</th><th className="r">{t('col_holders')}</th><th>{t('col_curve')}</th><th className="r">{t('col_age')}</th>
      </tr></thead>
      <tbody>
        {rows.map((r) => (
          <tr key={r.address} onClick={() => nav(`/token/${r.address}`)} style={{ cursor: 'pointer' }}>
            <td className="tok"><span className="sym">{r.symbol}</span> <span className="name">{r.name} · {short(r.address)}</span></td>
            <td className="r num">{usd(r.fdvBnb * rate)}</td>
            <td className="r num">{px(r.priceBnb)}</td>
            <td className="r num">{usd((r.volume24hBnb || 0) * rate)}</td>
            <td className="r num">{r.trades24h ?? 0}</td>
            <td className="r num">{r.holders}</td>
            <td>{r.graduated ? <span className="badge grad">{t('graduated')}</span> : <><span className="pbar"><i style={{ width: `${Math.max(2, r.progressPct)}%` }} /></span><span className="dim">{r.progressPct}%</span></>}</td>
            <td className="r dim">{ago(r.lastTradeAt || r.createdAt)}</td>
          </tr>
        ))}
      </tbody>
    </table></div>
  )
}
