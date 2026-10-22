import { useQuery } from '@tanstack/react-query'
import { useT } from '../i18n.jsx'
import Win from '../components/Win.jsx'
import Cmd from '../components/Cmd.jsx'
import ClaimDividend from '../components/ClaimDividend.jsx'
import ConnectBaw from '../components/ConnectBaw.jsx'
import {
  STOCKS_CHAIN_ID,
  STOCKS_EXPLORER,
  STOCKS_LAUNCHPAD,
  STOCKS_ADDR_ROWS,
  stocksConfigured,
} from '../stocksConfig.js'
import { api, short } from '../api.js'

export default function Stocks() {
  const { t } = useT()
  const ready = stocksConfigured()
  const stocks = useQuery({
    queryKey: ['stockTokens'],
    queryFn: () => api.stockTokens({ limit: 20 }),
    refetchInterval: 20_000,
  })
  const first = stocks.data?.items?.[0]
  return (
    <main className="wrap stocks-page">
      <section className="hero stocks-hero">
        <span className="tag">{t('stocks_tag', { chain: STOCKS_CHAIN_ID })}</span>
        <h1>{t('stocks_title')}</h1>
        <p className="muted stocks-lead">{t('stocks_lead')}</p>
        <div className="stocks-hero-actions"><ConnectBaw /></div>
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
          <Cmd block>{ready ? `baw / gang agent → LaunchpadS.create @ ${short(STOCKS_LAUNCHPAD)}` : 'VITE_STOCKS_LAUNCHPAD=0x… npm run dev'}</Cmd>
        </Win>
        <Win title={t('stocks_buy')}>
          <p className="muted">{t('stocks_buy_p')}</p>
          <Cmd block>{ready ? `# LaunchpadS @ ${short(STOCKS_LAUNCHPAD)}\n# buy on curve with whitelisted quote (BAW only)` : t('stocks_buy_placeholder')}</Cmd>
        </Win>
        <Win title={t('stocks_claim')}>
          {first?.address ? (
            <>
              <p className="muted">{t('stocks_claim_token', { symbol: first.symbol || short(first.address) })}</p>
              <ClaimDividend tokenAddress={first.address} />
            </>
          ) : (
            <ClaimDividend tokenAddress="" />
          )}
        </Win>
      </div>
    </main>
  )
}
