import { API } from '../api.js'

function logoSrc(logoUrl) {
  if (!logoUrl) return null
  if (logoUrl.startsWith('http') || logoUrl.startsWith('data:')) return logoUrl
  return `${API}${logoUrl}`
}

/** Token avatar: custom logo when indexed, else deterministic letter tile. */
export default function TokenAvatar({ symbol, address, logoUrl, size = 40, className = '' }) {
  const src = logoSrc(logoUrl)
  const letter = (symbol || '?').slice(0, 1).toUpperCase()
  const hue = address ? parseInt(address.slice(2, 8), 16) % 360 : 0
  if (src) {
    return (
      <span
        className={`tok-avatar tok-avatar-img ${className}`.trim()}
        style={{ width: size, height: size }}
      >
        <img src={src} alt="" width={size} height={size} loading="lazy" decoding="async" />
      </span>
    )
  }
  return (
    <span
      className={`tok-avatar ${className}`.trim()}
      style={{ '--av-hue': hue, width: size, height: size, fontSize: size * 0.42 }}
      aria-hidden
    >
      {letter}
    </span>
  )
}
