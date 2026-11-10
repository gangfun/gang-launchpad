import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useInfiniteQuery, useQuery } from '@tanstack/react-query'
import { api, isOfficial } from '../api.js'
import { useT, Lines } from '../i18n.jsx'
import TokenTable from '../components/TokenTable.jsx'
import Cmd from '../components/Cmd.jsx'
import Win from '../components/Win.jsx'
import AgentBuyersCounter from '../components/AgentBuyersCounter.jsx'

const TABS = ['hot', 'new', 'progress', 'graduated']
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
  const listRef = useRef(null)
  const stats = useQuery({ queryKey: ['stats'], queryFn: api.stats, refetchInterval: 20_000 })
  const q = useInfiniteQuery({
    queryKey: ['tokens', tab],
    queryFn: ({ pageParam }) => api.tokens(tab, { limit: PAGE, offset: pageParam }),
    initialPageParam: 0,
    getNextPageParam: (last) => (last?.hasMore ? last.nextOffset : undefined),
    refetchInterval: 30_000,
  })
  const rows = useMemo(
    () => pinOfficialHot(q.data?.pages.flatMap((p) => p.items || []) || [], tab),
    [q.data, tab],
  )
  const loadMore = useCallback(() => {
    if (q.hasNextPage && !q.isFetchingNextPage) q.fetchNextPage()
  }, [q.hasNextPage, q.isFetchingNextPage, q.fetchNextPage])
  const onListScroll = useCallback((e) => {
    const el = e.currentTarget
    if (el.scrollHeight - el.scrollTop - el.clientHeight < 96) loadMore()
  }, [loadMore])
  useEffect(() => { if (listRef.current) listRef.current.scrollTop = 0 }, [tab])
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
      </section>
      <Win title={t('nav_markets')} flush right={<div className="tabs">{TABS.map((k) => <button key={k} className={tab === k ? 'on' : ''} onClick={() => setTab(k)}>{t(`tab_${k}`)}</button>)}</div>}>
        <TokenTable
          rows={rows}
          loading={q.isLoading}
          error={q.isError ? q.error : null}
          listRef={listRef}
          onScroll={onListScroll}
          hasMore={!!q.hasNextPage}
          loadingMore={q.isFetchingNextPage}
          onLoadMore={loadMore}
        />
      </Win>
    </main>
  )
}
