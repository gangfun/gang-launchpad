/** Deterministic 1-letter avatar from symbol + address hue. */
export default function TokenAvatar({ symbol, address, size = 40 }) {
  const letter = (symbol || '?').slice(0, 1).toUpperCase()
  const hue = address ? parseInt(address.slice(2, 8), 16) % 360 : 0
  return (
    <span
      className="tok-avatar"
      style={{ '--av-hue': hue, width: size, height: size, fontSize: size * 0.42 }}
      aria-hidden
    >
      {letter}
    </span>
  )
}
