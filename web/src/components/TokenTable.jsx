import { Link, useNavigate } from 'react-router-dom'
import { ago, px, short, usd, api, isOfficial } from '../api.js'
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
      </p>
    </div>
  )
}

const pancakeHref = (r) => `https://pancakeswap.finance/swap?outputCurrency=${r.address}&chain=bsc`

function MarketCard({ r, rate, t, onOpen }) {
  return (
    <button
      type="button"
      className="market-card"
      onClick={() => onOpen(r.address)}
    >
      <div className="market-card-top">
        <TokenAvatar symbol={r.symbol} address={r.address} size={44} />
        <div className="market-card-id">
          <div className="market-card-sym">
            <span className="sym">{r.symbol}</span>
            {isOfficial(r.address) && <span className="badge official">{t('official')}</span>}
            {r.graduated && <span className="badge grad">{t('graduated')}</span>}
          </div>
          <span className="name">{r.name}</span>
        </div>
        <span className="market-card-age dim">{ago(r.lastTradeAt || r.createdAt)}</span>
      </div>
      <div className="market-card-stats">
        <div>
          <span>{t('col_mcap')}</span>
          <b className="num">{usd(r.fdvBnb * rate)}</b>
        </div>
        <div>
          <span>{t('col_vol')}</span>
          <b className="num">{usd((r.volume24hBnb || 0) * rate)}</b>
        </div>
        <div className="market-card-foot">
          {r.graduated
            ? <a className="dex-link" href={pancakeHref(r)} target="_blank" rel="noreferrer" onClick={(e) => e.stopPropagation()}>{t('trade_on_pancake')} →</a>
            : (
              <>
                <span className="pbar"><i style={{ width: `${Math.max(2, r.progressPct)}%` }} /></span>
                <span className="dim">{r.progressPct}%</span>
              </>
            )}
        </div>
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
