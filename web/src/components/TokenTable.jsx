import { Link, useNavigate } from 'react-router-dom'
import { ago, px, short, usd, api, isOfficial } from '../api.js'
import { useQuery } from '@tanstack/react-query'
import { useT, Lines } from '../i18n.jsx'
import Cmd from './Cmd.jsx'

function ColdStart() {
  const { t } = useT()
  return (
    <div className="cold">
      <div className="cold-title">{t('cold_title')}</div>
      <Lines k="cold_lines" className="cold-lines" />
      <ol className="cold-steps">
        <li>
          <b>{t('cold_install')}</b>
          <Cmd block>npx skills add gangfun/gang-launchpad/skill</Cmd>
          <Cmd block>npm i -g github:gangfun/cli</Cmd>
        </li>
        <li>
          <b>{t('cold_preflight')}</b>
          <Cmd block>gang preflight</Cmd>
        </li>
        <li>
          <b>{t('cold_create')}</b>
          <Cmd block>{'gang create --name "…" --symbol …'}</Cmd>
          <Cmd block>gang execute --request-id …</Cmd>
          <Cmd block>gang tx --hash 0x…</Cmd>
        </li>
      </ol>
      <p className="cold-docs">
        <Link to="/docs">{t('cold_docs')}</Link>
      </p>
    </div>
  )
}

function RowCells({ r, rate, t }) {
  return (
    <>
      <td className="tok"><span className="sym">{r.symbol}</span>{isOfficial(r.address) && <> <span className="badge official">{t('official')}</span></>} <span className="name">{r.name} · {short(r.address)}</span></td>
      <td className="r num">{usd(r.fdvBnb * rate)}</td>
      <td className="r num">{px(r.priceBnb)}</td>
      <td className="r num">{usd((r.volume24hBnb || 0) * rate)}</td>
      <td className="r num">{r.trades24h ?? 0}</td>
      <td className="r num">{r.holders}</td>
      <td>{r.graduated ? <span className="badge grad">{t('graduated')}</span> : <><span className="pbar"><i style={{ width: `${Math.max(2, r.progressPct)}%` }} /></span><span className="dim">{r.progressPct}%</span></>}</td>
      <td className="r dim">{ago(r.lastTradeAt || r.createdAt)}</td>
    </>
  )
}

export default function TokenTable({ rows, loading, error }) {
  const nav = useNavigate()
  const { t } = useT()
  const rate = useQuery({ queryKey: ['stats'], queryFn: api.stats }).data?.bnbUsd || 0
  if (loading) return <div className="empty">{t('loading')}</div>
  if (error) return <div className="empty err">{t('api_error')}</div>
  if (!rows?.length) return <ColdStart />
  return (
    <>
      <div className="market-scroll"><table>
        <thead><tr>
          <th>{t('col_token')}</th><th className="r">{t('col_mcap')}</th><th className="r">{t('col_price')}</th><th className="r">{t('col_vol')}</th><th className="r">{t('col_trades')}</th><th className="r">{t('col_holders')}</th><th>{t('col_curve')}</th><th className="r">{t('col_age')}</th>
        </tr></thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.address} onClick={() => nav(`/token/${r.address}`)} style={{ cursor: 'pointer' }}>
              <RowCells r={r} rate={rate} t={t} />
            </tr>
          ))}
        </tbody>
      </table></div>
      <div className="market-cards" role="list">
        {rows.map((r) => (
          <button
            type="button"
            key={r.address}
            className="mcard"
            role="listitem"
            onClick={() => nav(`/token/${r.address}`)}
          >
            <div className="mcard-head">
              <span className="sym">{r.symbol}</span>
              {isOfficial(r.address) && <span className="badge official">{t('official')}</span>}
              <span className="name">{r.name} · {short(r.address)}</span>
            </div>
            <div className="mcard-metrics">
              <div><span>{t('col_mcap')}</span><b className="num">{usd(r.fdvBnb * rate)}</b></div>
              <div><span>{t('col_price')}</span><b className="num">{px(r.priceBnb)}</b></div>
              <div className="mcard-curve">
                {r.graduated
                  ? <span className="badge grad">{t('graduated')}</span>
                  : <><span className="pbar"><i style={{ width: `${Math.max(2, r.progressPct)}%` }} /></span><span className="dim">{r.progressPct}%</span></>}
              </div>
            </div>
          </button>
        ))}
      </div>
    </>
  )
}
