import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const __dir = path.dirname(fileURLToPath(import.meta.url))
const DEFAULT_DIR = path.join(__dir, '..', 'data', 'logos')

const MIME = {
  'image/png': 'png',
  'image/jpeg': 'jpg',
  'image/webp': 'webp',
  'image/gif': 'gif',
}

export function mediaDir() {
  const d = process.env.GANG_MEDIA_DIR || DEFAULT_DIR
  fs.mkdirSync(d, { recursive: true })
  return d
}

export function parseDataUrl(dataUrl) {
  const m = String(dataUrl || '').match(/^data:(image\/(?:png|jpeg|webp|gif));base64,([A-Za-z0-9+/=]+)$/)
  if (!m) return null
  const buf = Buffer.from(m[2], 'base64')
  if (buf.length < 32 || buf.length > 512 * 1024) return null
  return { mime: m[1], ext: MIME[m[1]], buf }
}

export function saveTokenLogo(address, { mime, ext, buf }) {
  const dir = mediaDir()
  const file = `${address.toLowerCase()}.${ext}`
  const full = path.join(dir, file)
  fs.writeFileSync(full, buf)
  return { file, mime, bytes: buf.length }
}

export function logoFilePath(address) {
  const dir = mediaDir()
  const base = address.toLowerCase()
  for (const ext of ['webp', 'png', 'jpg', 'jpeg', 'gif']) {
    const full = path.join(dir, `${base}.${ext}`)
    if (fs.existsSync(full)) return full
  }
  return null
}

export function initMediaTable(db) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS token_logos (
      address TEXT PRIMARY KEY,
      mime TEXT NOT NULL,
      file TEXT NOT NULL,
      updated_ts INTEGER NOT NULL
    );
  `)
}

export function setLogoRow(db, address, mime, file) {
  const ts = Math.floor(Date.now() / 1000)
  db.prepare(`
    INSERT INTO token_logos(address, mime, file, updated_ts) VALUES(?,?,?,?)
    ON CONFLICT(address) DO UPDATE SET mime=excluded.mime, file=excluded.file, updated_ts=excluded.updated_ts
  `).run(address.toLowerCase(), mime, file, ts)
}

export function getLogoMap(db, addresses) {
  const uniq = [...new Set((addresses || []).map((a) => String(a).toLowerCase()).filter(Boolean))]
  if (!uniq.length) return {}
  const placeholders = uniq.map(() => '?').join(',')
  const rows = db.prepare(`SELECT address, mime, file FROM token_logos WHERE address IN (${placeholders})`).all(...uniq)
  const out = {}
  for (const r of rows) out[r.address] = { mime: r.mime, file: r.file }
  return out
}
