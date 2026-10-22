import { useEffect, useState } from 'react'
import { useT } from '../i18n.jsx'
import { short } from '../api.js'
import { useBawWallet } from '../wallet/useBawWallet.js'
import { STOCKS_DIVIDEND_VAULT, STOCKS_EXPLORER, stocksConfigured } from '../stocksConfig.js'
import Cmd from './Cmd.jsx'

/**
 * Claim 币股 dividends via DividendVault.claim(token).
 * Connect must be BAW/Binance only. Agent path documented for baw CLI.
 */
export default function ClaimDividend({ tokenAddress }) {
  const { t } = useT()
  const w = useBawWallet()
  const [pending, setPending] = useState(null)
  const [tx, setTx] = useState(null)
  const token = (tokenAddress || '').toLowerCase()

  useEffect(() => {
    let alive = true
    ;(async () => {
      if (!w.account || !token) { setPending(null); return }
      const p = await w.readPending(token)
      if (alive) setPending(p)
    })()
    const id = setInterval(async () => {
      if (!w.account || !token) return
      const p = await w.readPending(token)
      if (alive) setPending(p)
    }, 12_000)
    return () => { alive = false; clearInterval(id) }
  }, [w.account, token, w.readPending])

  if (!stocksConfigured() || !STOCKS_DIVIDEND_VAULT) {
    return <p className="muted">{t('stocks_claim_placeholder')}</p>
  }

  const onClaim = async () => {
    setTx(null)
    if (!w.connected) {
      const ok = await w.connect()
      if (!ok) return
    }
    const hash = await w.claimDividend(token)
    if (hash) setTx(hash)
  }

  return (
    <div className="claim-div">
      <p className="muted">{t('stocks_claim_p')}</p>
      <p className="muted dim">{t('baw_only_hint')}</p>
      {!w.connected ? (
        <button type="button" className="btn" disabled={w.busy} onClick={w.connect}>
          {t('baw_connect')}
        </button>
      ) : (
        <div className="claim-row">
          <span className="dim">{short(w.account)}</span>
          <span className="num">
            {pending ? `${Number(pending.formatted).toPrecision(6)} quote` : '—'}
          </span>
          <button type="button" className="btn" disabled={w.busy || !(Number(pending?.formatted) > 0)} onClick={onClaim}>
            {w.busy ? t('loading') : t('stocks_claim_go')}
          </button>
        </div>
      )}
      {w.error && <p className="baw-err">{w.error}</p>}
      {tx && (
        <p className="ok">
          <a href={`${STOCKS_EXPLORER}/tx/${tx}`} target="_blank" rel="noreferrer">{short(tx)}</a>
        </p>
      )}
      <details className="baw-agent">
        <summary>{t('baw_cli_summary')}</summary>
        <Cmd block>{`# Agent / baw (Developer Mode)\nbaw contract-call preview --binanceChainId 97 --from <BAW> --to ${STOCKS_DIVIDEND_VAULT} --inputData $(cast calldata "claim(address)" ${token || '<TOKEN>'}) --json\nbaw contract-call execute --requestId <id> --json`}</Cmd>
      </details>
    </div>
  )
}
