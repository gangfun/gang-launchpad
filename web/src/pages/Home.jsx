import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useInfiniteQuery, useQuery } from '@tanstack/react-query'
import { api, usd, isOfficial } from '../api.js'
import { useT, Lines } from '../i18n.jsx'
import TokenTable from '../components/TokenTable.jsx'
import Cmd from '../components/Cmd.jsx'
import Win from '../components/Win.jsx'
import AgentBuyersCounter from '../components/AgentBuyersCounter.jsx'
import { stocksConfigured } from '../stocksConfig.js'

const TABS = ['hot', 'new', 'progress', 'graduated']
const TRACKS = ['all', 'main', 'stocks']
const PAGE = 24

/** 「最热」: pin official GANG first (API also pins; this is belt-and-suspenders). */
function pinOfficialHot(rows, tab) {
  if (!rows?.length || tab !== 'hot') return rows
  const i = rows.findIndex((r) => isOfficial(r.address))
  if (i <= 0) return rows
  const next = rows.slice()
  const [row] = next.splice(i, 1)
  next.unshift(row)
  return next
}

export default function Home() {
  const { t } = useT()
  const [tab, setTab] = useState('hot')
  const [track, setTrack] = useState('all')
  const listRef = useRef(null)
  const stats = useQuery({ queryKey: ['stats'], queryFn: api.stats, refetchInterval: 20_000 })
  const wantMain = track === 'all' || track === 'main'
  const wantStocks = track === 'all' || track === 'stocks'
  const q = useInfiniteQuery({
    queryKey: ['tokens', tab],
    queryFn: ({ pageParam }) => api.tokens(tab, { limit: PAGE, offset: pageParam }),
    initialPageParam: 0,
    getNextPageParam: (last) => (last?.hasMore ? last.nextOffset : undefined),
    refetchInterval: 30_000,
    enabled: wantMain,
  })
  const sq = useQuery({
    queryKey: ['stock-tokens'],
    queryFn: () => api.stockTokens({ limit: 100 }),
    refetchInterval: 30_000,
    enabled: wantStocks,
  })
  const stockRows = useMemo(() => {
    if (!wantStocks) return []
    return (sq.data?.items || []).map((r) => ({ ...r, track: 'stocks' }))
  }, [wantStocks, sq.data])
  const mainRows = useMemo(() => {
    if (!wantMain) return []
    const raw = pinOfficialHot(q.data?.pages.flatMap((p) => p.items || []) || [], tab)
    return raw.map((r) => ({ ...r, track: 'main' }))
  }, [q.data, tab, wantMain])
  const rows = useMemo(() => {
    if (track === 'stocks') return stockRows
    if (track === 'main') return mainRows
    return [...stockRows, ...mainRows]
  }, [track, stockRows, mainRows])
  const loadMore = useCallback(() => {
    if (!wantMain) return
    if (q.hasNextPage && !q.isFetchingNextPage) q.fetchNextPage()
  }, [wantMain, q.hasNextPage, q.isFetchingNextPage, q.fetchNextPage])
  const onListScroll = useCallback((e) => {
    const el = e.currentTarget
    if (el.scrollHeight - el.scrollTop - el.clientHeight < 96) loadMore()
  }, [loadMore])
  useEffect(() => { if (listRef.current) listRef.current.scrollTop = 0 }, [tab, track])
  const apiDown = (wantMain && (q.isError || stats.isError)) || (wantStocks && track === 'stocks' && sq.isError)
  const emptyHint = track === 'stocks' && !stocksConfigured() && !stockRows.length
    ? t('stocks_env_hint')
    : track === 'stocks' && !sq.isLoading && !stockRows.length
      ? t('stocks_empty')
      : null
  return (
    <main className="wrap">
      <section className="hero">
        <div className="hero-grid">
          <div className="hero-main">
            <span className="tag">BNB Chain · Binance Agentic Wallet</span>
            <h1>{t('hero_1')}</h1>
            <Lines k="hero_2" className="hero-lines" />
            <Cmd>npx skills add gangfun/gang-launchpad/skill</Cmd>
          </div>
          <aside className="hero-aside">
            <AgentBuyersCounter
              value={stats.data?.agentBuyers}
              loading={stats.isLoading}
              error={stats.isError}
            />
          </aside>
        </div>
        <div className="stats">
          <div className="stat"><b>{stats.isError ? '!' : (stats.data?.tokens ?? '—')}</b><span>{t('stat_tokens')}</span></div>
          <div className="stat"><b>{stats.isError ? '!' : (stats.data?.graduated ?? '—')}</b><span>{t('stat_graduated')}</span></div>
          <div className="stat"><b>{stats.isError ? '!' : (stats.data ? usd(stats.data.vol24 * stats.data.bnbUsd) : '—')}</b><span>{t('stat_vol')}</span></div>
          <div className="stat"><b>{stats.isError ? '!' : (stats.data?.trades ?? '—')}</b><span>{t('stat_trades')}</span></div>
        </div>
      </section>
      <Win
        title={t('nav_markets')}
        flush
        right={(
          <div className="market-toolbar">
            <div className="tabs track-tabs">
              {TRACKS.map((k) => (
                <button key={k} type="button" className={track === k ? 'on' : ''} onClick={() => setTrack(k)}>
                  {t(`track_${k}`)}
                </button>
              ))}
            </div>
            {wantMain && (
              <div className="tabs">
                {TABS.map((k) => (
                  <button key={k} type="button" className={tab === k ? 'on' : ''} onClick={() => setTab(k)}>
                    {t(`tab_${k}`)}
                  </button>
                ))}
              </div>
            )}
          </div>
        )}
      >
        <TokenTable
          rows={rows}
          loading={(wantMain && q.isLoading) || (track === 'stocks' && sq.isLoading)}
          error={apiDown ? (q.error || stats.error || sq.error) : null}
          listRef={listRef}
          onScroll={onListScroll}
          hasMore={wantMain && !!q.hasNextPage}
          loadingMore={wantMain && q.isFetchingNextPage}
          onLoadMore={loadMore}
          emptyHint={emptyHint}
        />
      </Win>
    </main>
  )
}
