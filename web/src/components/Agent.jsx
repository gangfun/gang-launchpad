import { short } from '../api.js'

/** Address + optional SPACE ID Agent handle (e.g. lazy.ai). */
export default function Agent({ address, handle, href, className }) {
  if (!address) return <span className={className || 'dim'}>—</span>
  const link = href || `https://bscscan.com/address/${address}`
  const label = handle || short(address)
  return (
    <a className={`agent ${className || ''}`} href={link} target="_blank" rel="noreferrer" title={address}>
      {handle ? <span className="handle">{handle}</span> : null}
      <span className={handle ? 'addr-sub' : ''}>{handle ? short(address) : label}</span>
    </a>
  )
}
