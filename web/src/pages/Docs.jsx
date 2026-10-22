import Cmd from '../components/Cmd.jsx'
import { GITHUB_CLI, LAUNCHPAD } from '../api.js'
import { useT, Lines } from '../i18n.jsx'

export default function Docs() {
  const { t } = useT()
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
      <Cmd block>npm i -g @gangfun/cli@0.1.3 --registry=https://npm.pkg.github.com</Cmd>
      <Cmd block>npm i -g github:gangfun/cli</Cmd>
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
