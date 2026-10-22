import { useEffect, useRef } from 'react'
import { createChart, CandlestickSeries, HistogramSeries } from 'lightweight-charts'

const SUPPLY = 1e9
// lightweight-charts renders UTC; shift timestamps so the axis reads in the viewer's local time.
const TZ = -new Date().getTimezoneOffset() * 60
import { px, usd } from '../api.js'
const fmtUsd = (v) => (v >= 1e6 ? `$${(v / 1e6).toFixed(2)}M` : v >= 1e4 ? `$${(v / 1e3).toFixed(1)}K` : `$${v.toFixed(v >= 100 ? 0 : 2)}`)
const fmtBnb = (v) => px(v)

/** mode: 'mcap' (BNB FDV = price × 1e9) or 'price' (BNB per token) */
export default function Chart({ candles, mode = 'mcap', rate = 0 }) {
  const ref = useRef(null)
  const chart = useRef(null)
  const legend = useRef(null)
  useEffect(() => {
    if (!ref.current) return
    chart.current = createChart(ref.current, {
      layout: { background: { color: '#0E0E0E' }, textColor: '#5C5C5C', fontFamily: 'Geist Mono, monospace', fontSize: 11, attributionLogo: false },
      grid: { vertLines: { color: '#1A1A1A' }, horzLines: { color: '#1A1A1A' } },
      rightPriceScale: { borderColor: '#1F1F1F', scaleMargins: { top: 0.08, bottom: 0.22 } },
      timeScale: { borderColor: '#1F1F1F', timeVisible: true, secondsVisible: false, barSpacing: 10, minBarSpacing: 4, rightOffset: 6 },
      localization: { priceFormatter: (v) => (chart.current?._mode === 'mcap' ? fmtUsd(v) : fmtBnb(v)) },
      autoSize: true, crosshair: { mode: 0 },
      handleScale: { axisPressedMouseMove: { time: true, price: false }, mouseWheel: true, pinch: true },
    })
    chart.current._s = {
      c: chart.current.addSeries(CandlestickSeries, {
        upColor: '#0ECB81', downColor: '#F6465D', borderVisible: false, wickUpColor: '#0ECB81', wickDownColor: '#F6465D',
        priceFormat: { type: 'custom', formatter: (v) => (chart.current?._mode === 'mcap' ? fmtUsd(v) : fmtBnb(v)), minMove: 1e-12 },
        // Interval pad (not symmetric mid±half): price/mcap axis min never < 0 — matches DexScreener/GMGN/Binance spot
        autoscaleInfoProvider: (orig) => {
          const r = orig(); if (!r?.priceRange) return r
          const { minValue, maxValue } = r.priceRange
          const span = Math.max(0, maxValue - minValue)
          const mid = (minValue + maxValue) / 2
          // ~8% of span, floor 1.5% of mid for flat/tiny meme prices, absolute epsilon for ultra-small BNB
          const pad = Math.max(span * 0.08, Math.abs(mid) * 0.015, 1e-18)
          let min = Math.max(0, minValue - pad)
          let max = maxValue + pad
          if (max <= min) max = min + Math.max(pad, 1e-18)
          return { ...r, priceRange: { minValue: min, maxValue: max } }
        },
      }),
      v: chart.current.addSeries(HistogramSeries, { priceScaleId: 'vol', color: '#303030', priceFormat: { type: 'volume' }, lastValueVisible: false, priceLineVisible: false }),
    }
    chart.current.priceScale('vol').applyOptions({ scaleMargins: { top: 0.85, bottom: 0 } })
    // OHLC legend follows the crosshair; shows the last candle when idle
    const show = (d) => { if (!legend.current) return; if (!d) { legend.current.textContent = ''; return }
      const f = chart.current._mode === 'mcap' ? fmtUsd : fmtBnb
      legend.current.innerHTML = `<span>O ${f(d.open)}</span><span>H ${f(d.high)}</span><span>L ${f(d.low)}</span><span>C ${f(d.close)}</span><span>V ${d.vol.toFixed(4)} BNB</span>` }
    chart.current._show = show
    chart.current.subscribeCrosshairMove((p) => {
      const c = p.seriesData.get(chart.current._s.c); const v = p.seriesData.get(chart.current._s.v)
      if (c) show({ ...c, vol: v?.value ?? 0 }); else if (chart.current._last) show(chart.current._last)
    })
    return () => chart.current?.remove()
  }, [])
  useEffect(() => {
    const ch = chart.current, s = ch?._s; if (!s || !candles) return
    const k = mode === 'mcap' ? SUPPLY * (rate || 0) : 1
    ch._mode = mode
    if (mode === 'mcap' && !rate) return
    s.c.setData(candles.map((x) => ({ time: x.t + TZ, open: x.o * k, high: x.h * k, low: x.l * k, close: x.c * k })))
    s.v.setData(candles.map((x) => ({ time: x.t + TZ, value: x.v, color: x.c >= x.o ? 'rgba(14,203,129,.35)' : 'rgba(246,70,93,.35)' })))
    // Re-enable autoscale so any prior manual price zoom cannot leave a negative floor
    ch.priceScale('right').applyOptions({ autoScale: true })
    ch.timeScale().applyOptions({ barSpacing: 10, rightOffset: 6 })
    ch.timeScale().scrollToRealTime()
    const last = candles[candles.length - 1]
    ch._last = last ? { open: last.o * k, high: last.h * k, low: last.l * k, close: last.c * k, vol: last.v } : null
    ch._show(ch._last)
  }, [candles, mode, rate])
  return <><div className="chart" ref={ref} /><div className="legend" ref={legend} /></>
}
