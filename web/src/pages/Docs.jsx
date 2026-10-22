import Cmd from '../components/Cmd.jsx'
import { GITHUB_CLI, LAUNCHPAD, short } from '../api.js'
import { useT, Lines } from '../i18n.jsx'
import {
  STOCKS_CHAIN_ID,
  STOCKS_EXPLORER,
  STOCKS_LAUNCHPAD,
  STOCKS_QUOTE,
  STOCKS_DIVIDEND_VAULT,
  stocksConfigured,
} from '../stocksConfig.js'

export default function Docs() {
  const { t } = useT()
  const ready = stocksConfigured()
  return (
    <main className="wrap doc">
      <h1>{t('g_title')}</h1>
      <Lines k="g_intro" />
      <h2>01 {t('g_s1')}</h2>
      <ol><li>{t('g_s1_1')}</li><li>{t('g_s1_2')}</li><li>{t('g_s1_3')}</li><li>{t('g_s1_4')}</li></ol>
      <h2>02 {t('g_s2')}</h2>
      <p>{t('g_s2_p')}</p>
      <p><a href={GITHUB_CLI} target="_blank" rel="noreferrer">{GITHUB_CLI}</a></p>
      <Cmd block>npx skills add binance/binance-skills-hub/skills/binance-web3/binance-agentic-wallet</Cmd>
      <Cmd block>npx skills add gangfun/gang-launchpad/skill</Cmd>
      <Cmd block>npm i -g @binance/agentic-wallet</Cmd>
      <Cmd block>npm i -g @gangfun/cli</Cmd>
      <Cmd block>npx @gangfun/cli preflight</Cmd>
      <Lines k="g_s2_then" />
      <h2>03 {t('g_s3')}</h2>
      <Cmd block>gang preflight</Cmd>
      <Lines k="g_s3_p" />
      <h2>04 {t('g_s4')}</h2>
      <Cmd block>gang list</Cmd>
      <Cmd block>gang quote --token 0x… --bnb 0.05</Cmd>
      <Cmd block>gang buy --token 0x… --bnb 0.05</Cmd>
      <Cmd block>gang execute --request-id …</Cmd>
      <Lines k="g_s4_p" />
      <div className="callout"><Lines k="g_cap" /></div>
      <h2>05 {t('g_s5')}</h2>
      <Cmd block>gang sell --token 0x… --all</Cmd>
      <Cmd block>gang sell --token 0x… --amount 1000000</Cmd>
      <Lines k="g_s5_p" />
      <h2>06 {t('g_s6')}</h2>
      <Cmd block>gang create --name "My Agent Coin" --symbol MAC</Cmd>
      <Cmd block>gang execute --request-id …</Cmd>
      <Cmd block>gang tx --hash 0x…</Cmd>
      <Lines k="g_s6_p" className="oneline" />
      <h2 id="stocks">07 {t('g_stocks')}</h2>
      <Lines k="g_stocks_intro" />
      <p><b>{t('g_stocks_quote')}</b> — {t('g_stocks_quote_p')}</p>
      <p><b>{t('g_stocks_tax')}</b> — {t('g_stocks_tax_p')}</p>
      <p><b>{t('g_stocks_flow')}</b> — {t('g_stocks_flow_p')}</p>
      <Cmd block>{'gang create --name "…" --symbol …   # agent path; quote = SPCXB / MockSPCXB on Chapel'}</Cmd>
      <Cmd block>gang execute --request-id …</Cmd>
      <Cmd block>{'gang buy --token 0x…   # curve priced in quote ERC-20, not BNB'}</Cmd>
      {ready && (
        <table><tbody>
          <tr><td>LaunchpadS</td><td><a href={`${STOCKS_EXPLORER}/address/${STOCKS_LAUNCHPAD}`} target="_blank" rel="noreferrer">{short(STOCKS_LAUNCHPAD)}</a></td></tr>
          <tr><td>quote · MockSPCXB</td><td><a href={`${STOCKS_EXPLORER}/address/${STOCKS_QUOTE}`} target="_blank" rel="noreferrer">{short(STOCKS_QUOTE)}</a></td></tr>
          {STOCKS_DIVIDEND_VAULT && (
            <tr><td>DividendVault</td><td><a href={`${STOCKS_EXPLORER}/address/${STOCKS_DIVIDEND_VAULT}`} target="_blank" rel="noreferrer">{short(STOCKS_DIVIDEND_VAULT)}</a></td></tr>
          )}
          <tr><td>chain</td><td>Chapel {STOCKS_CHAIN_ID}</td></tr>
        </tbody></table>
      )}
      <div className="callout"><Lines k="g_stocks_note" /></div>
      <h2 id="token-logos">08 token logos</h2>
      <p>See <code>docs/TOKEN_LOGO_METADATA.md</code> in the repo. Summary: <code>Launchpad.create(name, symbol)</code> and <code>LaunchToken</code> (plain ERC-20) have no URI/metadata field today. The site can store a logo off-chain via <code>POST /tokens/:addr/logo</code> after the token is indexed.</p>
      <h2>{t('g_rules')}</h2>
      <table><tbody>
        <tr><td>{t('r_who')}</td><td>{t('r_who_v')}</td></tr>
        <tr><td>{t('r_sell')}</td><td>{t('r_sell_v')}</td></tr>
        <tr><td>{t('r_cap')}</td><td>{t('r_cap_v')}</td></tr>
        <tr><td>{t('r_fee')}</td><td>{t('r_fee_v')}</td></tr>
        <tr><td>{t('r_lock')}</td><td>{t('r_lock_v')}</td></tr>
        <tr><td>{t('r_grad')}</td><td>{t('r_grad_v')}</td></tr>
        <tr><td>{t('r_contract')}</td><td><a href={`https://bscscan.com/address/${LAUNCHPAD}`} target="_blank" rel="noreferrer">{LAUNCHPAD}</a></td></tr>
      </tbody></table>
    </main>
  )
}
