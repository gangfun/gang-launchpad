import { useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { api, bnb, usd, isOfficial } from '../api.js'
import { useT, Lines } from '../i18n.jsx'
import TokenTable from '../components/TokenTable.jsx'
import Cmd from '../components/Cmd.jsx'
import Win from '../components/Win.jsx'

const TABS = ['hot', 'new', 'progress', 'graduated']

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
  const stats = useQuery({ queryKey: ['stats'], queryFn: api.stats })
  const q = useQuery({ queryKey: ['tokens', tab], queryFn: () => api.tokens(tab, 50) })
  const rows = useMemo(() => pinOfficialHot(q.data, tab), [q.data, tab])
  const apiDown = q.isError || stats.isError
  return (
    <main className="wrap">
      <section className="hero">
        <span className="tag">BNB Chain · Binance Agentic Wallet</span>
        <h1>{t('hero_1')}</h1>
        <Lines k="hero_2" className="hero-lines" />
        <Cmd>npx skills add gangfun/gang-launchpad/skill</Cmd>
        <div className="stats">
          <div className="stat"><b>{stats.isError ? '!' : (stats.data?.tokens ?? '—')}</b><span>{t('stat_tokens')}</span></div>
          <div className="stat"><b>{stats.isError ? '!' : (stats.data?.graduated ?? '—')}</b><span>{t('stat_graduated')}</span></div>
          <div className="stat"><b>{stats.isError ? '!' : (stats.data ? usd(stats.data.vol24 * stats.data.bnbUsd) : '—')}</b><span>{t('stat_vol')}</span></div>
          <div className="stat"><b>{stats.isError ? '!' : (stats.data?.trades ?? '—')}</b><span>{t('stat_trades')}</span></div>
        </div>
      </section>
      <Win title={t('nav_markets')} flush right={<div className="tabs">{TABS.map((k) => <button key={k} className={tab === k ? 'on' : ''} onClick={() => setTab(k)}>{t(`tab_${k}`)}</button>)}</div>}>
        <TokenTable rows={rows} loading={q.isLoading} error={apiDown ? (q.error || stats.error) : null} />
      </Win>
    </main>
  )
}