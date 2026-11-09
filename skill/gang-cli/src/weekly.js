/**
 * `gang weekly`: Gang's weekly launch event (gang.fun/weekly). Each week the team picks one application; the pick launches
 * on GangLaunchpad 3.0 (V3 curve) on Friday 20:00 UTC+8 from the wallet that applied, and is featured for 7 days: on the
 * gang.fun homepage, in gang.fun's X / TG posts and as the `event` row of `gang trending` / `preflight` / `list`. No
 * buy-back, no reward: attention only. An official event, not a recommendation.
 *
 *   gang weekly                          the issue open for applications, the current pick, past issues, my application
 *   gang weekly apply …                  preview the application; with --yes sign it with the Agent wallet and submit it
 *   gang weekly withdraw [--yes]         withdraw my application while applications are open
 *
 * The application is signed as EIP-712 typed data (domain "gang.fun weekly launch", chainId 56) by the baw wallet, which
 * proves the wallet applying is the one that will create. Its `contact` is only seen by the gang.fun team.
 */
import { keccak256, toBytes } from 'viem'
import { API, get as apiGet } from './discover.js'
import { baw, bawAddress, bawFailed, bawStatus } from './baw.js'
import { localTime } from './follow.js'
import { ipfsCid, ipfsUri } from './logo.js'
import { normalizeTwitter, normalizeWebsite } from './links.js'
import { UA } from './version.js'

export const WEEKLY_NOTE = "Gang's official weekly launch event, not a recommendation. Never buy from it on your own."
export const WEEKLY_URL = 'https://gang.fun/weekly'
export const WEEKLY_MODULES = ['buyback', 'lp', 'split', 'combo', 'capped', 'bond', 'dividend', 'promote', 'tax']
export const APPLY_FLAGS = ['name', 'symbol', 'logo', 'logo-file', 'file-logo', 'logo-uri', 'description', 'contact',
  'twitter', 'telegram', 'website', 'modules', 'issue', 'yes']

export const WEEKLY_DOMAIN = { name: 'gang.fun weekly launch', version: '1', chainId: 56 }
const DOMAIN_TYPE = [{ name: 'name', type: 'string' }, { name: 'version', type: 'string' }, { name: 'chainId', type: 'uint256' }]
export const WEEKLY_TYPES = {
  WeeklyApply: [{ name: 'wallet', type: 'address' }, { name: 'issue', type: 'string' }, { name: 'digest', type: 'bytes32' }, { name: 'expires', type: 'uint256' }],
  WeeklyWithdraw: [{ name: 'wallet', type: 'address' }, { name: 'issue', type: 'string' }, { name: 'expires', type: 'uint256' }],
}
const SIGN_TTL_S = 30 * 60 // the signature's expires: the server takes up to 1 hour ahead
const ISSUE_RE = /^\d{4}-\d{2}-\d{2}$/
const POST_TIMEOUT_MS = 20_000

/** JSON with object keys sorted at every level, arrays in order, no whitespace: what the digest hashes (server does the same). */
export function canonical(v) {
  if (Array.isArray(v)) return `[${v.map(canonical).join(',')}]`
  if (v && typeof v === 'object') {
    return `{${Object.keys(v).filter((k) => v[k] !== undefined).sort().map((k) => `${JSON.stringify(k)}:${canonical(v[k])}`).join(',')}}`
  }
  return JSON.stringify(v)
}

/** keccak256 of the canonical application, wallet in lower case. */
export const applicationDigest = (app) => keccak256(toBytes(canonical({ ...app, wallet: String(app.wallet).toLowerCase() })))

/** The typed data baw signs (eth_signTypedData_v4 shape: EIP712Domain included in types). */
export function typedData(primaryType, message) {
  return { types: { EIP712Domain: DOMAIN_TYPE, [primaryType]: WEEKLY_TYPES[primaryType] }, primaryType, domain: WEEKLY_DOMAIN, message }
}

/** baw's { signature: r‖s hex, signatureRecovery: '00' | '01' } → a 65-byte 0x signature with v = 27 / 28. */
export function joinSignature(sig, recovery) {
  const rs = String(sig ?? '').replace(/^0x/, '')
  if (!/^[0-9a-fA-F]{128}$/.test(rs)) {
    // some answers carry the full 65 bytes already
    if (/^[0-9a-fA-F]{130}$/.test(rs)) return `0x${rs}`
    throw new Error('baw returned no signature')
  }
  const rec = Number.parseInt(String(recovery ?? '0'), 16)
  if (!(rec >= 0 && rec <= 1) && !(rec === 27 || rec === 28)) throw new Error(`baw returned an unknown signature recovery ${recovery}`)
  return `0x${rs}${(rec >= 27 ? rec : 27 + rec).toString(16)}`
}

/**
 * Sign typed data with the baw wallet: preview, then execute. A signature that waits for the Binance App is polled for up
 * to ~2 minutes. → 0x signature.
 */
export function bawSignTyped(wallet, td, { sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms) } = {}) {
  const message = JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_signTypedData_v4', params: [wallet, JSON.stringify(td)] })
  const p = baw(['sign-message', 'preview', '--binanceChainId', '56', '--signType', 'EIP712', '--message', message])
  if (!p.success) throw bawFailed('sign-message preview', p.error)
  let r = baw(['sign-message', 'execute', '--requestId', p.data.requestId])
  if (!r.success) throw bawFailed('sign-message execute', r.error)
  for (let i = 0; r.data?.status !== 'COMPLETED' && r.data?.orderId && i < 40; i++) {
    if (['FAILED', 'REJECTED', 'CANCELLED', 'EXPIRED'].includes(r.data.status)) throw new Error(`the signature was ${r.data.status.toLowerCase()} in the wallet`)
    sleep(3000)
    const q = baw(['sign-message', 'result', '--order-id', r.data.orderId])
    if (q.success) r = q
  }
  if (r.data?.status !== 'COMPLETED') throw Object.assign(new Error('the signature was not completed: approve it in the Binance App if it asks, then run the same command again'), { retryable: true })
  return joinSignature(r.data.signature, r.data.signatureRecovery)
}

/** --telegram as typed (@name, name, t.me/… link) → https://t.me/<name> ('' when empty). Throws bad_telegram. */
export function normalizeTelegram(raw) {
  const s = String(raw ?? '').trim()
  if (!s) return ''
  const bad = () => new Error(`bad_telegram: --telegram takes a TG handle (@name) or a t.me link (got ${JSON.stringify(s)})`)
  const handle = /^@?([A-Za-z0-9_]{4,32})$/.exec(s)
  if (handle) return `https://t.me/${handle[1]}`
  let u
  try { u = new URL(/^https?:\/\//i.test(s) ? s : `https://${s}`) } catch { throw bad() }
  if (!['https:', 'http:'].includes(u.protocol) || u.username || u.password || u.port || !['t.me', 'www.t.me', 'telegram.me'].includes(u.hostname)) throw bad()
  const path = u.pathname.replace(/\/+$/, '')
  if (!/^(?:\/\+?[A-Za-z0-9_-]{1,64}){1,2}$/.test(path)) throw bad()
  return `https://t.me${path}`
}

const chars = (s) => [...String(s ?? '')].length

/**
 * The application's fields from the flags (without wallet / issue / logo), or throws Error('bad_field: …').
 * Limits as gang.fun checks them; optional links left out when not given.
 */
export function applicationFields({ opt, flag }) {
  const bad = (field, why) => Object.assign(new Error(`bad_field: --${field} ${why}`), { field })
  const val = (name) => (flag(name) ? opt(name) : undefined)
  const need = (name) => {
    const v = val(name)
    if (v == null || String(v).startsWith('--') || !String(v).trim()) throw bad(name, 'is required')
    return String(v).trim()
  }
  const name = need('name'); if (chars(name) > 32) throw bad('name', 'is at most 32 characters')
  const symbol = need('symbol'); if (chars(symbol) > 12 || /\s/.test(symbol)) throw bad('symbol', 'is at most 12 characters, no spaces')
  const description = need('description'); if (chars(description) > 500) throw bad('description', 'is at most 500 characters')
  const contact = need('contact'); if (chars(contact) > 64) throw bad('contact', 'is at most 64 characters')
  const f = { name, symbol, description, contact }
  const link = (flagName, norm) => {
    const v = val(flagName)
    if (v === undefined) return undefined
    if (v == null || String(v).startsWith('--')) throw bad(flagName, 'needs a value')
    try { return norm(v) || undefined } catch (e) { throw bad(flagName, e.message.replace(/^bad_\w+: --[\w-]+ /, '')) }
  }
  const x = link('twitter', normalizeTwitter); if (x) f.x = x
  const tg = link('telegram', normalizeTelegram); if (tg) f.tg = tg
  const website = link('website', normalizeWebsite); if (website) f.website = website
  if (flag('modules')) {
    const raw = opt('modules')
    if (raw == null || raw.startsWith('--')) throw bad('modules', `needs a list, e.g. lp,buyback (from ${WEEKLY_MODULES.join(', ')})`)
    const list = [...new Set(raw.split(',').map((m) => m.trim().toLowerCase()).filter(Boolean))]
    const unknown = list.filter((m) => !WEEKLY_MODULES.includes(m))
    if (unknown.length) throw bad('modules', `knows ${WEEKLY_MODULES.join(', ')} (got ${unknown.join(', ')})`)
    if (list.length) f.modules = list
  }
  return f
}

/** IssueView times → local text next to the unix seconds. */
const TIME_KEYS = ['applyOpensAt', 'applyClosesAt', 'opensAt', 'closesAt', 'teaserAt', 'launchAt', 'detectUntil', 'featuredUntil', 'until']
export function withTimes(v) {
  if (!v || typeof v !== 'object') return v ?? null
  const o = { ...v }
  for (const k of TIME_KEYS) if (Number.isFinite(o[k]) && o[k] > 0) o[`${k}Local`] = localTime(o[k])
  if (o.token?.address) o.token = { ...o.token, link: `https://gang.fun/token/${o.token.address}` }
  return o
}

/** `event` of GET /trending → the row the CLI prints first (null when absent or malformed). */
export function eventRow(e) {
  if (!e || e.kind !== 'weekly-launch' || !e.issue) return null
  return withTimes({
    kind: 'weekly-launch', issue: e.issue, number: e.number ?? null, status: e.status ?? null,
    name: e.name ?? null, symbol: e.symbol ?? null, creatorHandle: e.creatorHandle ?? null,
    launchAt: e.launchAt ?? null, until: e.until ?? null,
    token: e.token?.address ? { address: e.token.address, symbol: e.token.symbol ?? e.symbol ?? null, progressPct: e.token.progressPct ?? null } : null,
    url: WEEKLY_URL, note: WEEKLY_NOTE,
  })
}

async function post(path, body) {
  let r
  try {
    r = await fetch(`${API}${path}`, {
      method: 'POST', headers: { 'content-type': 'application/json', accept: 'application/json', 'user-agent': UA },
      body: JSON.stringify(body), signal: AbortSignal.timeout(POST_TIMEOUT_MS),
    })
  } catch (e) {
    throw Object.assign(new Error(`gang API unreachable (${API}${path}): ${e.cause?.message || e.message}`), { retryable: true })
  }
  let j = null
  try { j = await r.json() } catch { /* below */ }
  if (!r.ok || !j?.ok) {
    const code = j?.error || `http_${r.status}`
    throw Object.assign(new Error(`gang.fun refused it: ${j?.message || code}`), { apiCode: code, field: j?.field, retryable: r.status >= 500 || r.status === 429 })
  }
  return j
}

const SIGN_IN = 'sign in to baw (baw auth signin): the application is signed by the wallet that will create the token'

/** runWeekly(sub, io): io = { opt, flag, out, fail, resolveLogo } from index.js. */
export async function runWeekly(sub, { opt, flag, out, fail, resolveLogo }) {
  const signedIn = () => { try { return bawStatus() === 'CONNECTED' } catch { return false } }
  const wallet = () => { try { return bawAddress() } catch (e) { return fail(`${SIGN_IN} (${e.message})`) } }
  const board = async () => {
    let b
    try { b = await apiGet('/weekly', undefined, '') } catch (e) { fail(e.message, { retry: 'same command again' }) }
    if (!b) fail(`gang.fun has no weekly launch event yet (${API}/weekly)`, { retry: 'later' })
    return b
  }
  const issueArg = (b) => {
    const i = flag('issue') ? opt('issue') : b.apply?.issue
    if (!i || !ISSUE_RE.test(i)) fail('--issue takes the issue\'s Friday date, e.g. 2026-11-13', { got: i ?? null })
    return i
  }
  const mine = async (issue, w) => {
    if (!w) return null
    try { return await apiGet(`/weekly/application?${new URLSearchParams({ issue, wallet: w.toLowerCase() })}`, undefined, '') } catch { return null }
  }

  if (sub === undefined || sub === 'status' || sub.startsWith('--')) {
    const b = await board()
    const me = signedIn() ? wallet() : null
    const my = b.apply?.issue && me ? await mine(b.apply.issue, me) : null
    return out({
      success: true,
      apply: withTimes(b.apply), current: withTimes(b.current), past: (b.past || []).map(withTimes), rules: b.rules ?? null,
      ...(me && { mine: my ? { issue: my.issue, status: my.status, symbol: my.symbol, submittedAtLocal: localTime(my.submittedAt) } : null }),
      url: WEEKLY_URL, note: WEEKLY_NOTE,
      next: b.apply?.open ? 'gang weekly apply --name … --symbol … --logo ./logo.png --description "…" --contact @you  (preview; add --yes to sign and submit)' : null,
    })
  }

  if (sub === 'apply') {
    const unknown = Object.keys(Object.fromEntries(process.argv.slice(4).filter((a) => a.startsWith('--')).map((a) => [a.slice(2), 1])))
      .filter((f) => !APPLY_FLAGS.includes(f))
    if (unknown.length) fail(`gang weekly apply does not take --${unknown[0]} (it takes --${APPLY_FLAGS.join(', --')})`)
    if (flag('keep-logo-uri')) fail('--keep-logo-uri: the logo must be on gang.fun (gang upload-logo, or --logo ./file.png)')
    let fields
    try { fields = applicationFields({ opt, flag }) } catch (e) { fail(e.message, e.field ? { field: e.field } : {}) }
    if (!flag('logo') && !flag('logo-file') && !flag('file-logo') && !flag('logo-uri')) fail('bad_field: --logo ./file.png (or --logo-uri <gang.fun logo URL>) is required', { field: 'logo' })
    const b = await board()
    const issue = issueArg(b)
    const open = b.apply?.issue === issue && b.apply.open
    if (!open) fail(`applications for ${issue} are not open${b.apply?.issue ? ` (open next: ${b.apply.issue}, ${localTime(b.apply.opensAt)} – ${localTime(b.apply.closesAt)})` : ''}`, { apply: withTimes(b.apply) })
    if (!signedIn()) fail(SIGN_IN)
    // gang.fun refuses a wallet without an Agent ID (no_agent_id); the create gate checks it again at launch
    const w = wallet()
    const rules = b.rules ?? {}
    const preview = {
      issue, number: b.apply.number ?? null, wallet: w, ...fields, logo: flag('logo-uri') ? opt('logo-uri') : (opt('logo') || opt('logo-file') || opt('file-logo')),
    }
    const terms = [
      `If picked, launch it on ${rules.pad || 'GangLaunchpad 3.0 V3 curve'} from ${w} with symbol ${fields.symbol} on ${localTime(b.apply.launchAt) ?? 'Friday 20:00 UTC+8'} (gang create …).`,
      `The pin is withdrawn early if the creator sells more than ${((rules.revokeSellBps ?? 2000) / 100).toFixed(0)}% of their holding during the 7-day featured week.`,
      'No buy-back and no reward: the event pays in attention (gang.fun homepage, X / TG posts, the CLI trending row).',
      'Only the gang.fun team sees --contact; everything else may be shown publicly once picked.',
    ]
    if (!flag('yes')) {
      return out({
        success: true, preview: true, application: preview, terms, url: WEEKLY_URL,
        note: 'Nothing was signed or sent. Show this to the user; only on their OK run the same command with --yes (it uploads a local logo, signs with the Agent wallet and submits). Re-applying replaces the earlier application while applications are open.',
      })
    }
    const logo = await resolveLogo()
    const cid = ipfsCid(logo.logoURI || '')
    if (!cid) fail('the logo must be on gang.fun\'s IPFS bucket: use --logo ./file.png or --logo-uri with a gang upload-logo URL', { got: logo.logoURI || null })
    const application = { issue, wallet: w.toLowerCase(), ...fields, logo: ipfsUri(cid) }
    const expires = Math.floor(Date.now() / 1000) + SIGN_TTL_S
    let signature
    try {
      signature = bawSignTyped(w, typedData('WeeklyApply', { wallet: w, issue, digest: applicationDigest(application), expires }))
    } catch (e) { fail(e.message, e.retryable ? { retry: 'same command again' } : {}) }
    let r
    try { r = await post('/weekly/apply', { application, expires, signature }) } catch (e) {
      fail(e.message, { ...(e.apiCode && { apiCode: e.apiCode }), ...(e.field && { field: e.field }), ...(e.retryable && { retry: 'same command again' }) })
    }
    return out({
      success: true, issue, status: r.status ?? 'pending', replaced: !!r.replaced, application: { ...application, logoUrl: logo.upload?.url ?? null },
      ...(logo.uploaded && { logoUploaded: logo.upload?.url ?? true }),
      note: 'Submitted. The team picks one application on Thursday 12:00 UTC+8 and contacts the pick; the pick goes public Thursday 20:00. Check with gang weekly.',
      url: WEEKLY_URL,
    })
  }

  if (sub === 'withdraw') {
    const b = await board()
    const issue = issueArg(b)
    if (!signedIn()) fail(SIGN_IN)
    const w = wallet()
    const my = await mine(issue, w)
    if (!my) fail(`no application from ${w} for ${issue}`)
    if (!flag('yes')) {
      return out({ success: true, preview: true, withdraw: { issue, wallet: w, status: my.status, symbol: my.symbol }, note: 'Nothing was signed or sent. On the user\'s OK run the same command with --yes.' })
    }
    const expires = Math.floor(Date.now() / 1000) + SIGN_TTL_S
    let signature
    try { signature = bawSignTyped(w, typedData('WeeklyWithdraw', { wallet: w, issue, expires })) } catch (e) { fail(e.message, e.retryable ? { retry: 'same command again' } : {}) }
    let r
    try { r = await post('/weekly/withdraw', { issue, wallet: w.toLowerCase(), expires, signature }) } catch (e) {
      fail(e.message, { ...(e.apiCode && { apiCode: e.apiCode }), ...(e.retryable && { retry: 'same command again' }) })
    }
    return out({ success: true, issue, status: r.status ?? 'withdrawn' })
  }

  fail(`unknown gang weekly command: ${sub} (gang weekly | gang weekly apply … | gang weekly withdraw)`)
}
