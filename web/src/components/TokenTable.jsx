import { Link, useNavigate } from 'react-router-dom'
import { ago, usd, api, isOfficial, short } from '../api.js'
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
          <Cmd block>npm i -g @gangfun/cli@0.1.4</Cmd>
          <Cmd block>npx @gangfun/cli preflight</Cmd>
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
        <Link to="/docs#stocks">{t('track_stocks')}</Link>
      </p>
    </div>
  )
}

const pancakeHref = (r) => `https://pancakeswap.finance/swap?outputCurrency=${r.address}&chain=bsc`

function Chip({ kind, children }) {
  return <span className={`chip chip-${kind}`}>{children}</span>
}

function MarketCard({ r, rate, t, onOpen }) {
  const isStock = r.track === 'stocks'
  const mcap = isStock
    ? (r.pairLabel || `${r.symbol || '?'}/${r.quoteSymbol || 'SPCXB'}`)
    : (!(r.fdvBnb > 0) ? '—' : usd(r.fdvBnb * rate))
  const vol = isStock || !((r.volume24hBnb || 0) > 0) ? '—' : usd((r.volume24hBnb || 0) * rate)
  const age = isStock
    ? (r.lastTradeAt || r.createdAt ? ago(r.lastTradeAt || r.createdAt) : t('stocks_chapel'))
    : ago(r.lastTradeAt || r.createdAt)
  const pct = r.graduated ? 100 : r.progressPct

  return (
    <button
      type="button"
      className={`market-card${isStock ? ' market-card-stocks' : ''}`}
      onClick={() => onOpen(r)}
    >
      <div className="market-card-top">
        <TokenAvatar symbol={r.symbol} address={r.address} logoUrl={r.logoUrl} size={36} className="market-card-av" />
        <div className="market-card-id">
          <div className="market-card-symrow">
            <span className="sym">{r.symbol}</span>
            {isStock && <Chip kind="stocks">{t('track_stocks')}</Chip>}
            {isOfficial(r.address) && <Chip kind="official">{t('official')}</Chip>}
            {r.graduated && <Chip kind="grad">{t('graduated')}</Chip>}
          </div>
          <span className="name">{r.name}</span>
        </div>
        <span className="market-card-age">{age}</span>
      </div>

      <div className="market-card-mcap">
        <b className="num mcap-num">{mcap}</b>
        <span className="label">{isStock ? t('stocks_pair') : t('col_mcap')}</span>
      </div>

      {isStock ? (
        <div className="market-card-meta">
          <div className="meta-cell">
            <span>{t('stocks_quote')}</span>
            <b className="num">{r.quoteLabel || r.quoteSymbol || '—'}</b>
          </div>
          <div className="meta-cell meta-right">
            <span>{t('stocks_tax')}</span>
            <b className="num">{r.taxBps ? `${(r.taxBps / 100).toFixed(0)}% · ${r.divSplit || '50/50'}` : '—'}</b>
          </div>
        </div>
      ) : (
        <div className="market-card-meta">
          <div className="meta-cell">
            <span>{t('col_vol')}</span>
            <b className="num">{vol}</b>
          </div>
          <div className="meta-cell meta-right">
            <span>{r.graduated ? t('col_curve') : t('k_progress')}</span>
            <b className="num">{r.graduated ? t('graduated') : `${pct}%`}</b>
          </div>
        </div>
      )}

      <div className="market-card-foot">
        {isStock ? (
          <span className="stocks-foot">
            {r.dividendVault
              ? `${t('stocks_div_vault')} ${short(r.dividendVault)}`
              : t('stocks_div_pending')}
            {r.pair ? ` · pair ${short(r.pair)}` : ''}
            {r.quoteAddress ? ` · ${r.quoteLabel || r.quoteSymbol}/${short(r.quoteAddress)}` : ''}
          </span>
        ) : r.graduated ? (
          <a className="dex-link" href={pancakeHref(r)} target="_blank" rel="noreferrer" onClick={(e) => e.stopPropagation()}>
            {t('trade_on_pancake')} →
          </a>
        ) : (
          <span className="pbar market-pbar"><i style={{ width: `${Math.max(2, pct || 0)}%` }} /></span>
        )}
      </div>
    </button>
  )
}

export default function TokenTable({ rows, loading, error, listRef, onScroll, hasMore, loadingMore, onLoadMore, emptyHint }) {
  const nav = useNavigate()
  const { t } = useT()
  const rate = useQuery({ queryKey: ['stats'], queryFn: api.stats }).data?.bnbUsd || 0
  const open = (r) => {
    nav(`/token/${r.address}`)
  }
  if (loading) return <div className="empty">{t('loading')}</div>
  if (error) return <div className="empty err">{t('api_error')}</div>
  if (!rows?.length) {
    if (emptyHint) return <div className="empty muted">{emptyHint}</div>
    return <ColdStart />
  }
  return (
    <div className="list-scroll market-list" ref={listRef} onScroll={onScroll}>
      <div className="market-grid" role="list">
        {rows.map((r) => (
          <MarketCard key={`${r.track || 'main'}:${r.address}`} r={r} rate={rate} t={t} onOpen={open} />
        ))}
      </div>
      {loadingMore && <div className="list-foot">{t('loading')}</div>}
      {hasMore && !loadingMore && (
        <button type="button" className="more discreet" onClick={onLoadMore}>{t('load_more')}</button>
      )}
    </div>
  )
}
