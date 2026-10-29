import { NavLink, Outlet } from 'react-router-dom'
import { useT, LANGS } from '../i18n.jsx'
import { LAUNCHPAD, short } from '../api.js'
import Search from './Search.jsx'
import Logo from './Logo.jsx'
import { XLink } from './SocialIcon.jsx'
import ConnectBaw from './ConnectBaw.jsx'
import { BawWalletProvider } from '../wallet/useBawWallet.jsx'
import { AgentWalletProvider } from '../wallet/useAgentWallet.jsx'

const X_URL = 'https://x.com/gangfunmeme'
const GITHUB = 'https://github.com/gangfun/gang-launchpad'

export default function Layout() {
  return (
    <BawWalletProvider>
      <AgentWalletProvider>
        <LayoutFrame />
      </AgentWalletProvider>
    </BawWalletProvider>
  )
}

function LayoutFrame() {
  const { t, lang, setLang } = useT()
  return (
    <>
      <header className="bar"><div className="wrap">
        <NavLink to="/" className="logo"><Logo /></NavLink>
        <nav className="nav">
          <NavLink to="/" end>{t('nav_markets')}</NavLink>
          <NavLink to="/docs">{t('nav_guide')}</NavLink>
          <a href={GITHUB} target="_blank" rel="noreferrer">{t('nav_github')}</a>
          <XLink href={X_URL} className="soc-link" label={t('social_x_a11y')} />
        </nav>
        <div className="spacer" />
        <Search />
        <ConnectBaw compact />
        <div className="lang">{LANGS.map(([k, label]) => <button key={k} className={k === lang ? 'on' : ''} onClick={() => setLang(k)}>{label}</button>)}</div>
      </div></header>
      <Outlet />
      <footer className="footer"><div className="wrap">
        <span>gang.fun</span>
        <span className="footer-links">
          <a href={GITHUB} target="_blank" rel="noreferrer">{t('nav_github')}</a>
          <XLink href={X_URL} className="soc-link" label={t('social_x_a11y')} />
          <a href={`https://bscscan.com/address/${LAUNCHPAD}`} target="_blank" rel="noreferrer">{short(LAUNCHPAD)}</a>
        </span>
      </div></footer>
    </>
  )
}
