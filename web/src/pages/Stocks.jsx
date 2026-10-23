import { useT } from '../i18n.jsx'
import Win from '../components/Win.jsx'
import Cmd from '../components/Cmd.jsx'
import {
  STOCKS_CHAIN_ID,
  STOCKS_EXPLORER,
  STOCKS_LAUNCHPAD,
  STOCKS_ADDR_ROWS,
  stocksConfigured,
} from '../stocksConfig.js'
import { short } from '../api.js'

export default function Stocks() {
  const { t } = useT()
  const ready = stocksConfigured()
  return (
    <main className="wrap stocks-page">
      <section className="hero stocks-hero">
        <span className="tag">{t('stocks_tag', { chain: STOCKS_CHAIN_ID })}</span>
        <h1>{t('stocks_title')}</h1>
        <p className="muted stocks-lead">{t('stocks_lead')}</p>
      </section>

      <Win title={t('stocks_contracts')}>
        {ready ? (
          <table className="stocks-addr">
            <tbody>
              {STOCKS_ADDR_ROWS.map(([label, addr]) => (
                <tr key={label}>
                  <td>{label}</td>
                  <td>
                    <a href={`${STOCKS_EXPLORER}/address/${addr}`} target="_blank" rel="noreferrer">{short(addr)}</a>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : (
          <p className="muted">{t('stocks_env_hint')}</p>
        )}
      </Win>

      <div className="stocks-actions">
        <Win title={t('stocks_create')}>
          <p className="muted">{t('stocks_create_p')}</p>
          <Cmd block>{ready ? `forge script script/stocks/DeployChapel.s.sol --rpc-url $CHAPEL_RPC_URL` : 'VITE_STOCKS_LAUNCHPAD=0x… npm run dev'}</Cmd>
        </Win>
        <Win title={t('stocks_buy')}>
          <p className="muted">{t('stocks_buy_p')}</p>
          <Cmd block>{ready ? `# LaunchpadS @ ${short(STOCKS_LAUNCHPAD)}\n# buy on curve with whitelisted quote` : t('stocks_buy_placeholder')}</Cmd>
        </Win>
        <Win title={t('stocks_claim')}>
          <p className="muted">{t('stocks_claim_p')}</p>
          <Cmd block>{ready ? `# DividendVault.claim(quote)` : t('stocks_claim_placeholder')}</Cmd>
        </Win>
      </div>
    </main>
  )
}
