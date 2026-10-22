import { Link, useNavigate } from 'react-router-dom'
import { ago, usd, api, isOfficial } from '../api.js'
import { useQuery } from '@tanstack/react-query'
import { useT, Lines } from '../i18n.jsx'
import Cmd from './Cmd.jsx'
import TokenAvatar from './TokenAvatar.jsx'

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
          <Cmd block>npm i -g @gangfun/cli@0.1.3 --registry=https://npm.pkg.github.com</Cmd>
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
        {' · '}
        <Link to="/launch">{t('nav_launch')}</Link>
      </p>
    </div>
  )
}

const pancakeHref = (r) => `https://pancakeswap.finance/swap?outputCurrency=${r.address}&chain=bsc`

function Chip({ kind, children }) {
  return <span className={`chip chip-${kind}`}>{children}</span>
}

function MarketCard({ r, rate, t, onOpen }) {
  const mcap = usd(r.fdvBnb * rate)
  const vol = usd((r.volume24hBnb || 0) * rate)
  const age = ago(r.lastTradeAt || r.createdAt)
  const pct = r.graduated ? 100 : r.progressPct

  return (
    <button
      type="button"
      className="market-card"
      onClick={() => onOpen(r.address)}
    >
      <div className="market-card-head">
        <TokenAvatar symbol={r.symbol} address={r.address} logoUrl={r.logoUrl} size={52} className="market-card-av" />
        <div className="market-card-title">
          <div className="market-card-symrow">
            <span className="sym">{r.symbol}</span>
            <span className="market-card-chips">
              {isOfficial(r.address) && <Chip kind="official">{t('official')}</Chip>}
              {r.graduated && <Chip kind="grad">{t('graduated')}</Chip>}
            </span>
          </div>
          <span className="name">{r.name}</span>
        </div>
        <span className="market-card-age">{age}</span>
      </div>

      <div className="market-card-mcap">
        <span className="label">{t('col_mcap')}</span>
        <b className="num mcap-num">{mcap}</b>
      </div>

      <div className="market-card-metrics">
        <div>
          <span>{t('col_vol')}</span>
          <b className="num">{vol}</b>
        </div>
        <div>
          <span>{r.graduated ? t('col_curve') : t('k_progress')}</span>
          <b className="num">{r.graduated ? t('graduated') : `${pct}%`}</b>
        </div>
      </div>

      <div className="market-card-progress">
        {r.graduated
          ? (
            <a className="dex-link" href={pancakeHref(r)} target="_blank" rel="noreferrer" onClick={(e) => e.stopPropagation()}>
              {t('trade_on_pancake')} →
            </a>
          )
          : (
            <>
              <span className="pbar market-pbar"><i style={{ width: `${Math.max(2, pct)}%` }} /></span>
              <span className="progress-pct">{pct}%</span>
            </>
          )}
      </div>
    </button>
  )
}

export default function TokenTable({ rows, loading, error, listRef, onScroll, hasMore, loadingMore, onLoadMore }) {
  const nav = useNavigate()
  const { t } = useT()
  const rate = useQuery({ queryKey: ['stats'], queryFn: api.stats }).data?.bnbUsd || 0
  const open = (addr) => nav(`/token/${addr}`)
  if (loading) return <div className="empty">{t('loading')}</div>
  if (error) return <div className="empty err">{t('api_error')}</div>
  if (!rows?.length) return <ColdStart />
  return (
    <div className="list-scroll market-list" ref={listRef} onScroll={onScroll}>
      <div className="market-grid" role="list">
        {rows.map((r) => (
          <MarketCard key={r.address} r={r} rate={rate} t={t} onOpen={open} />
        ))}
      </div>
      {loadingMore && <div className="list-foot">{t('loading')}</div>}
      {hasMore && !loadingMore && (
        <button type="button" className="more discreet" onClick={onLoadMore}>{t('load_more')}</button>
      )}
    </div>
  )
}
