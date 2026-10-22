import { useCallback, useEffect, useRef, useState } from 'react'
import { useParams } from 'react-router-dom'
import { useInfiniteQuery, useQuery } from '@tanstack/react-query'
import { api, ago, bnb, px, tok, short, usd, isOfficial } from '../api.js'
import { useT } from '../i18n.jsx'
import Chart from '../components/Chart.jsx'
import Cmd from '../components/Cmd.jsx'
import Win from '../components/Win.jsx'
import Agent from '../components/Agent.jsx'
import TokenAvatar from '../components/TokenAvatar.jsx'
import ClaimDividend from '../components/ClaimDividend.jsx'

const TRADES_PAGE = 30
const HOLDERS_PAGE = 50

export default function Token() {
  const { t } = useT()
  const { address } = useParams()
  const [res, setRes] = useState('5m')
  const [mode, setMode] = useState('mcap')
  const [tradeSide, setTradeSide] = useState('all')
  const [tradeSort, setTradeSort] = useState('ts_desc')
  const listRef = useRef(null)
  const q = useQuery({ queryKey: ['token', address], queryFn: () => api.token(address), refetchInterval: 15_000 })
  const trades = useInfiniteQuery({
    queryKey: ['trades', address, tradeSide, tradeSort],
    queryFn: ({ pageParam }) => api.trades(address, { limit: TRADES_PAGE, offset: pageParam, side: tradeSide, sort: tradeSort }),
    initialPageParam: 0,
    getNextPageParam: (last) => (last?.hasMore ? last.nextOffset : undefined),
    refetchInterval: 15_000,
  })
  const loadMore = useCallback(() => {
    if (trades.hasNextPage && !trades.isFetchingNextPage) trades.fetchNextPage()
  }, [trades.hasNextPage, trades.isFetchingNextPage, trades.fetchNextPage])
  const onListScroll = useCallback((e) => {
    const el = e.currentTarget
    if (el.scrollHeight - el.scrollTop - el.clientHeight < 96) loadMore()
  }, [loadMore])
  // Reset scroll when filter/sort changes
  useEffect(() => { if (listRef.current) listRef.current.scrollTop = 0 }, [tradeSide, tradeSort])
  const holdersRef = useRef(null)
  const holders = useInfiniteQuery({
    queryKey: ['holders', address],
    queryFn: ({ pageParam }) => api.holders(address, { limit: HOLDERS_PAGE, offset: pageParam }),
    initialPageParam: 0,
    getNextPageParam: (last) => (last?.hasMore ? last.nextOffset : undefined),
    refetchInterval: 15_000,
  })
  const loadMoreHolders = useCallback(() => {
    if (holders.hasNextPage && !holders.isFetchingNextPage) holders.fetchNextPage()
  }, [holders.hasNextPage, holders.isFetchingNextPage, holders.fetchNextPage])
  const onHoldersScroll = useCallback((e) => {
    const el = e.currentTarget
    if (el.scrollHeight - el.scrollTop - el.clientHeight < 96) loadMoreHolders()
  }, [loadMoreHolders])
  const candles = useQuery({ queryKey: ['candles', address, res], queryFn: () => api.candles(address, res), refetchInterval: 15_000 })
  const rate = useQuery({ queryKey: ['stats'], queryFn: api.stats }).data?.bnbUsd || 0
  if (q.isLoading) return <main className="wrap"><div className="empty">{t('loading')}</div></main>
  if (q.isError) {
    const status = String(q.error?.message || '')
    const notFound = status === '404'
    return <main className="wrap"><div className={`empty${notFound ? '' : ' err'}`}>{t(notFound ? 'not_found' : 'api_error')}</div></main>
  }
  const d = q.data
  const pct = d.graduated ? 100 : d.progressPct
  const pk = d.pancake
  const tradeRows = trades.data?.pages.flatMap((p) => p.items || []) || []
  const holderRows = holders.data?.pages.flatMap((p) => p.items || []) || []
  return (
    <main className="wrap">
      <div className="ident">
        <TokenAvatar symbol={d.symbol} address={d.address} logoUrl={d.logoUrl} size={48} />
        <h1>{d.symbol}</h1><span className="name">{d.name}</span>
        <a className="addr" href={`${d.explorer || 'https://bscscan.com'}/token/${d.address}`} target="_blank" rel="noreferrer">{d.address}</a>
        <span className={`badge ${d.graduated ? 'grad' : 'yellow'}`}>{d.graduated ? t('graduated') : t('curve')}</span>
        {isOfficial(d.address) && <span className="badge official">{t('official')}</span>}
        <div className="spacer" />
        {d.graduated && <a className="btn" href={pk?.pancakeUrl || `https://pancakeswap.finance/swap?outputCurrency=${d.address}&chain=bsc`} target="_blank" rel="noreferrer">{t('trade_on_pancake')} →</a>}
      </div>

      <div className="meta-row">
        <span className="label">{t('k_creator')}</span>
        <Agent address={d.creator} handle={d.creatorHandle} href={d.creatorUrl || (d.creator && `https://bscscan.com/address/${d.creator}`)} />
        {d.graduated && d.pair && (
          <>
            <span className="sep">·</span>
            <span className="label">{t('k_pair')}</span>
            <a className="addr" href={`https://bscscan.com/address/${d.pair}`} target="_blank" rel="noreferrer">{short(d.pair)}</a>
          </>
        )}
      </div>

      <div className="kv">
        <div><span>{t('k_mcap')}</span><b>{usd(d.fdvBnb * rate)}</b><small>{bnb(d.fdvBnb, 2)} BNB</small></div>
        <div><span>{t('k_price')}</span><b>{px(d.priceBnb)} BNB</b><small>{usd(d.priceBnb * rate)}</small></div>
        <div><span>{t('k_raised')}</span><b>{d.graduated ? '20 / 20 BNB' : `${bnb(d.raisedBnb, 4)} / 20 BNB`}</b><small>{d.graduated ? t('graduated') : usd(d.raisedBnb * rate)}</small></div>
        <div><span>{t('k_vol')}</span><b>{usd((d.volume24hBnb || 0) * rate)}</b><small>{bnb(d.volume24hBnb || 0, 4)} BNB{d.graduated && d.volumeSource === 'dex' ? ` · ${t('vol_dex')}` : ''}</small></div>
        <div><span>{t('k_holders')}</span>
          <b>{d.holders ?? 0}</b>
          {d.graduated && d.holdersAgent != null && (
            <small>{t('holders_agent_split', { agent: d.holdersAgent, other: d.holdersOther })}</small>
          )}
        </div>
        <div><span>{t('k_created')}</span><b>{ago(d.createdAt)}</b></div>
      </div>
      <div className={`pwide${d.graduated ? ' done' : ''}`}><i style={{ width: `${Math.max(1, pct)}%` }} /><span>{t('k_progress')} {pct}%</span></div>
      {!d.graduated && pct >= 90 && <p className="muted tip">{t('near_grad_gas')}</p>}
      {d.graduated && <p className="muted tip">{t('holders_curve_note')}</p>}

      {d.graduated && (
        <div className="pancake-block">
        <Win title={t('k_pancake')}>
          <div className="pancake">
            {pk?.reserveBnb != null ? (
              <div className="kv pancake-kv">
                <div><span>{t('pancake_pair')}</span><b><a href={pk.pairUrl} target="_blank" rel="noreferrer">{short(pk.pair || d.pair)}</a></b><small><a href={pk.infoUrl} target="_blank" rel="noreferrer">info</a></small></div>
                <div><span>{t('pancake_reserves')}</span><b>{bnb(pk.reserveBnb, 4)} BNB</b><small>{tok(pk.reserveToken)} {d.symbol}</small></div>
                <div><span>{t('pancake_price')}</span><b>{px(pk.priceBnb)} BNB</b><small>{usd(pk.priceBnb * rate)}</small></div>
                <div><span>{t('pancake_trade')}</span><b><a href={pk.pancakeUrl} target="_blank" rel="noreferrer">PancakeSwap →</a></b></div>
              </div>
            ) : (
              <p className="muted">{t('pancake_no_reserves')}{' '}<a href={pk?.pancakeUrl || `https://pancakeswap.finance/swap?outputCurrency=${d.address}&chain=bsc`} target="_blank" rel="noreferrer">{t('trade_on_pancake')} →</a>
                {d.pair && <> · <a href={`https://bscscan.com/address/${d.pair}`} target="_blank" rel="noreferrer">{t('pancake_pair')} {short(d.pair)}</a></>}
              </p>
            )}
          </div>
        </Win>
        </div>
      )}

      <div className="work">
          <Win title={mode === 'mcap' ? t('k_mcap') : t('k_price')} flush bodyClass={d.graduated ? 'chart-body chart-body-grad' : 'chart-body'} right={<>
            <div className="seg">{['mcap', 'price'].map((m) => <button key={m} className={m === mode ? 'on' : ''} onClick={() => setMode(m)}>{t(`chart_${m}`)}</button>)}</div>
            <div className="seg">{['1m', '5m', '15m', '1h', '4h', '1d'].map((r) => <button key={r} className={r === res ? 'on' : ''} onClick={() => setRes(r)}>{r}</button>)}</div>
          </>}>
            {d.graduated && (
              <div className="chart-banner">
                <span className="chart-banner-text">{t('chart_curve_ended')}</span>
                <span className="chart-banner-links">
                  <a href={pk?.pancakeUrl || `https://pancakeswap.finance/swap?outputCurrency=${d.address}&chain=bsc`} target="_blank" rel="noreferrer">PancakeSwap</a>
                  {d.pair && <> · <a href={`https://dexscreener.com/bsc/${d.pair}`} target="_blank" rel="noreferrer">DexScreener</a></>}
                </span>
              </div>
            )}
            <div className="chart-plot">
              <Chart candles={candles.data} mode={mode} rate={rate} />
            </div>
          </Win>
          <Win title={t('buy_title')}>
            {d.track === 'stocks' ? (
              <div className="howto">
                <p className="muted">{t('stocks_buy_p')}</p>
                <Cmd block>{`# BAW / Agent only — no MetaMask\nbaw / gang → LaunchpadS buy ${d.address}`}</Cmd>
              </div>
            ) : d.graduated ? (
              <div className="grad-trade">
                <p className="muted">{t('sell_note')}</p>
                <a className="btn" href={pk?.pancakeUrl || `https://pancakeswap.finance/swap?outputCurrency=${d.address}&chain=bsc`} target="_blank" rel="noreferrer">{t('trade_on_pancake')} →</a>
                {d.pair && (
                  <a className="btn ghost" href={`https://dexscreener.com/bsc/${d.pair}`} target="_blank" rel="noreferrer">DexScreener →</a>
                )}
              </div>
            ) : (
              <div className="howto"><ol>
                <li><b>{t('step_install')}</b><Cmd block>npx skills add gangfun/gang-launchpad/skill</Cmd></li>
                <li><b>{t('step_preflight')}</b><Cmd block>gang preflight</Cmd></li>
                <li><b>{t('step_buy')}</b><Cmd block>{`gang buy --token ${d.address} --bnb 0.05`}</Cmd></li>
                <li><b>{t('step_sell')}</b><Cmd block>{`gang sell --token ${d.address} --all`}</Cmd></li>
              </ol></div>
            )}
          </Win>
          {d.track === 'stocks' && (
            <Win title={t('stocks_claim')}>
              <ClaimDividend tokenAddress={d.address} />
            </Win>
          )}
          <Win title={t('trades')} flush right={<>
            <div className="seg">
              {[['all', 'filter_all'], ['buy', 'filter_buy'], ['sell', 'filter_sell']].map(([v, k]) => (
                <button key={v} type="button" className={tradeSide === v ? 'on' : ''} onClick={() => setTradeSide(v)}>{t(k)}</button>
              ))}
            </div>
            <select className="sort-sel" value={tradeSort} onChange={(e) => setTradeSort(e.target.value)} aria-label={t('sort')}>
              <option value="ts_desc">{t('sort_newest')}</option>
              <option value="ts_asc">{t('sort_oldest')}</option>
              <option value="amount_desc">{t('sort_amount')}</option>
            </select>
          </>}>
            <div className="list-scroll" ref={listRef} onScroll={onListScroll}>
              {tradeRows.length === 0 && !trades.isLoading && <div className="empty">{t('no_trades')}</div>}
              {tradeRows.length > 0 && (
                <table>
                  <thead><tr><th>{t('side')}</th><th>{t('agent')}</th><th className="r">{t('bnb')}</th><th className="r">{t('tokens')}</th><th className="r">{t('k_mcap')}</th><th className="r">{t('age')}</th></tr></thead>
                  <tbody>{tradeRows.map((x) => (
                    <tr key={x.tx + x.side + x.ts}>
                      <td className={x.side === 'buy' ? 'up' : 'down'}>{x.side}</td>
                      <td><Agent address={x.trader} handle={x.traderHandle} href={`https://bscscan.com/tx/${x.tx}`} /></td>
                      <td className="r num">{bnb(x.bnb, 5)}</td><td className="r num">{tok(x.tokens)}</td><td className="r num">{usd(Number(x.price) * 1e9 * rate)}</td><td className="r dim">{ago(x.ts)}</td>
                    </tr>))}</tbody>
                </table>
              )}
              {trades.isFetchingNextPage && <div className="list-foot">{t('loading')}</div>}
              {trades.hasNextPage && !trades.isFetchingNextPage && (
                <button type="button" className="more discreet" onClick={loadMore}>{t('load_more')}</button>
              )}
            </div>
          </Win>
          <Win title={t('holders')} flush right={<span className="dim">{d.graduated ? t('holders_frozen') : t('holders_hint')}</span>}>
            <div className="list-scroll" ref={holdersRef} onScroll={onHoldersScroll}>
              {holderRows.length === 0 && !holders.isLoading && <div className="empty">{t('no_holders')}</div>}
              {holderRows.length > 0 && (
                <table><thead><tr><th>{t('agent')}</th><th className="r">{t('tokens')}</th><th className="r">%</th></tr></thead>
                  <tbody>{holderRows.map((h) => <tr key={h.holder}><td><Agent address={h.holder} handle={h.handle} /></td><td className="r num">{tok(h.balance)}</td><td className="r num">{h.pct}</td></tr>)}</tbody></table>
              )}
              {holders.isFetchingNextPage && <div className="list-foot">{t('loading')}</div>}
              {holders.hasNextPage && !holders.isFetchingNextPage && (
                <button type="button" className="more discreet" onClick={loadMoreHolders}>{t('load_more')}</button>
              )}
            </div>
          </Win>
      </div>
    </main>
  )
}
