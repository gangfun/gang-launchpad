import { short } from '../api.js'
import { useT } from '../i18n.jsx'
import { useBawWallet } from '../wallet/useBawWallet.js'
import { BAW_ONLY_MSG } from '../wallet/baw.js'

/** Header connect — BAW / Binance Web3 Wallet only. */
export default function ConnectBaw({ compact = false }) {
  const { t } = useT()
  const w = useBawWallet()
  if (w.connected) {
    return (
      <div className="baw-connect on">
        <button type="button" className="btn ghost baw-btn" onClick={w.disconnect} title={w.account}>
          {compact ? short(w.account) : `${t('baw_connected')} ${short(w.account)}`}
        </button>
      </div>
    )
  }
  return (
    <div className="baw-connect">
      <button type="button" className="btn baw-btn" disabled={w.busy} onClick={w.connect}>
        {w.busy ? t('loading') : t('baw_connect')}
      </button>
      {w.error && <span className="baw-err" title={w.error}>{w.error === BAW_ONLY_MSG ? t('baw_only') : w.error}</span>}
    </div>
  )
}
