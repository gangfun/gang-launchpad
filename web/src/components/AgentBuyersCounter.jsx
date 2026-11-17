import { useEffect, useRef, useState } from 'react'
import { useT } from '../i18n.jsx'

function easeOutCubic(t) {
  return 1 - (1 - t) ** 3
}

/** Live count-up for distinct .ai wallets that have bought on the curve. */
export default function AgentBuyersCounter({ value, loading, error }) {
  const { t } = useT()
  const [display, setDisplay] = useState(0)
  const fromRef = useRef(0)
  const rafRef = useRef(null)

  useEffect(() => {
    if (value == null || Number.isNaN(Number(value))) return
    const target = Math.max(0, Math.floor(Number(value)))
    const from = fromRef.current
    if (target === from) return
    if (rafRef.current) cancelAnimationFrame(rafRef.current)
    const start = performance.now()
    const dur = Math.min(1400, 400 + Math.abs(target - from) * 35)
    const tick = (now) => {
      const p = Math.min(1, (now - start) / dur)
      const next = Math.round(from + (target - from) * easeOutCubic(p))
      setDisplay(next)
      if (p < 1) rafRef.current = requestAnimationFrame(tick)
      else {
        fromRef.current = target
        setDisplay(target)
      }
    }
    rafRef.current = requestAnimationFrame(tick)
    return () => { if (rafRef.current) cancelAnimationFrame(rafRef.current) }
  }, [value])

  const shown = error ? '!' : loading && value == null ? '—' : display.toLocaleString('en-US')

  return (
    <div className="hero-agent-counter" aria-live="polite">
      <span className="hero-agent-counter__live" aria-hidden="true" />
      <p className="hero-agent-counter__label">{t('hero_agent_buyers_label')}</p>
      <p className="hero-agent-counter__num">{shown}</p>
      <p className="hero-agent-counter__hint">{t('hero_agent_buyers_hint')}</p>
    </div>
  )
}
