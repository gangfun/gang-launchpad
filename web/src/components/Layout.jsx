import { NavLink, Outlet } from 'react-router-dom'
import { useT, LANGS } from '../i18n.jsx'
import { LAUNCHPAD, short } from '../api.js'
import Search from './Search.jsx'
import Logo from './Logo.jsx'

export default function Layout() {
  const { t, lang, setLang } = useT()
  return (
    <>
      <header className="bar"><div className="wrap">
        <NavLink to="/" className="logo"><Logo /></NavLink>
        <nav className="nav">
          <NavLink to="/" end>{t('nav_markets')}</NavLink>
          <NavLink to="/docs">{t('nav_guide')}</NavLink>
          <a href="https://github.com/gangfun/cli" target="_blank" rel="noreferrer">{t('nav_github')}</a>
        </nav>
        <div className="spacer" />
        <Search />
        <div className="lang">{LANGS.map(([k, label]) => <button key={k} className={k === lang ? 'on' : ''} onClick={() => setLang(k)}>{label}</button>)}</div>
      </div></header>
      <Outlet />
      <footer className="footer"><div className="wrap">
        <span>gang.fun</span>
        <a href={`https://bscscan.com/address/${LAUNCHPAD}`} target="_blank" rel="noreferrer">{short(LAUNCHPAD)}</a>
      </div></footer>
    </>
  )
}
