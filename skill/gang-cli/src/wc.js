/**
 * WalletConnect v2 (Reown) for `gang buy` / `gang sell --wallet wc`: the trade is built exactly as with --from <address>
 * --calldata, stored here as a request (requestId wc-…), and `gang execute --request-id wc-…` sends it to the user's own
 * wallet (MetaMask, OKX, …) with eth_sendTransaction. The user confirms every tx in that wallet; the CLI never holds a
 * key. Only approve / WBNB wrap / buy / sell calls are ever sent this way (ALLOWED below); every other write stays with the
 * Binance Agentic Wallet.
 *
 * The project ID comes only from GANG_WC_PROJECT_ID and is never printed (scrub). Everything kept on disk (the sign
 * client's keys and session, our session record, the pending requests) is under ~/.gang/wc (GANG_WC_DIR), the directory
 * 0700 and every file 0600. A session is used for SESSION_TTL_MS (24 h) at most, whatever the wallet granted.
 *
 * @walletconnect/sign-client and qrcode-terminal are imported only by the functions that need them, so every other
 * command starts as before.
 */
import { randomBytes } from 'node:crypto'
import { chmodSync, mkdirSync, openSync, closeSync, readFileSync, readdirSync, renameSync, rmSync, statSync, unlinkSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { decodeFunctionData, formatUnits, isAddress, isHex, parseAbi, toFunctionSelector, toHex } from 'viem'

export const SESSION_TTL_MS = 24 * 3600_000
export const REQUEST_TTL_MS = 10 * 60_000
export const CONNECT_TIMEOUT_S = { def: 300, min: 30, max: 1800 }
export const SEND_TIMEOUT_S = { def: 300, min: 60, max: 1800 }
export const NETWORKS = { 56: 'BSC', 97: 'BSC testnet' }
const METHODS = ['eth_sendTransaction']
const EVENTS = ['chainChanged', 'accountsChanged']
const METADATA = {
  name: 'gang CLI',
  description: 'gang.fun: trade a token from your own wallet; you confirm every transaction here',
  url: 'https://gang.fun',
  icons: ['https://gang.fun/favicon.ico'],
}

export const dir = () => process.env.GANG_WC_DIR || join(homedir(), '.gang', 'wc')
const file = (name) => join(dir(), name)
const STORE = 'store.json' // the sign client's own storage (keys, pairings, sessions)
const SESSION = 'session.json' // ours: { topic, address, chainId, peer, createdAt, expiresAt }
const CONNECT = 'connect.json' // a connect waiting for the wallet (gang wallet connect --no-wait)
const REQ_DIR = 'requests'

// ---------------------------------------------------------------- project ID: env only, never printed

/** The WalletConnect project ID from GANG_WC_PROJECT_ID (never from a file or a flag); throws without a valid one. */
export function projectId(env = process.env) {
  const id = String(env.GANG_WC_PROJECT_ID ?? '').trim()
  if (!id) throw new WcError('WalletConnect needs a project ID: set GANG_WC_PROJECT_ID (a WalletConnect / Reown Cloud project ID) in the environment', 'WC_NO_PROJECT_ID')
  if (!/^[0-9a-f]{32}$/i.test(id)) throw new WcError('GANG_WC_PROJECT_ID is not a WalletConnect project ID (32 hex characters)', 'WC_NO_PROJECT_ID')
  return id
}

/** `text` with the project ID (and any projectId= / auth= query value) taken out: for every message and error we print. */
export function scrub(text, env = process.env) {
  let s = String(text ?? '').replace(/([?&](?:projectId|auth)=)[^&\s"'`]+/gi, '$1<redacted>')
  const id = String(env.GANG_WC_PROJECT_ID ?? '').trim()
  if (id.length >= 8) s = s.split(id).join('<project id>')
  return s
}

export class WcError extends Error {
  constructor(message, code = 'WC_ERROR', extra = {}) {
    super(scrub(message))
    this.code = code
    this.extra = extra
  }
}

// ---------------------------------------------------------------- files: dir 0700, files 0600, atomic writes

function ensureDir(path = dir()) {
  mkdirSync(path, { recursive: true, mode: 0o700 })
  try { chmodSync(path, 0o700) } catch { /* not ours to change */ }
}
export function writeJson(path, obj) {
  ensureDir(join(path, '..'))
  const tmp = `${path}.${process.pid}.${randomBytes(4).toString('hex')}.tmp`
  writeFileSync(tmp, JSON.stringify(obj), { mode: 0o600 })
  chmodSync(tmp, 0o600)
  renameSync(tmp, path)
}
export function readJson(path) {
  try { return JSON.parse(readFileSync(path, 'utf8')) } catch { return null }
}
const remove = (path) => { try { rmSync(path, { force: true, recursive: true }) } catch { /* gone */ } }

/**
 * The sign client's IKeyValueStorage (keyvaluestorage-interface) in one 0600 JSON file, so a session made by
 * `gang wallet connect` can be used by a later `gang execute`. Written through on every change.
 */
export class FileStorage {
  constructor(path = file(STORE)) {
    this.path = path
    this.data = readJson(path) ?? {}
  }
  async getKeys() { return Object.keys(this.data) }
  async getEntries() { return Object.entries(this.data) }
  async getItem(key) { return this.data[key] }
  async setItem(key, value) { this.data[key] = value; writeJson(this.path, this.data) }
  async removeItem(key) { delete this.data[key]; writeJson(this.path, this.data) }
}

// ---------------------------------------------------------------- the sign client (lazy)

/** A SignClient on our file storage, with its logs and WalletConnect's own telemetry off. */
export async function signClient() {
  const id = projectId()
  ensureDir()
  let mod
  try { mod = await import('@walletconnect/sign-client') } catch (e) {
    throw new WcError(`the WalletConnect client is not installed (${e.code || e.message}): reinstall the CLI (npm i -g @gangfun/cli)`, 'WC_NOT_INSTALLED')
  }
  const SignClient = mod.SignClient ?? mod.default?.SignClient ?? mod.default
  try {
    return await SignClient.init({ projectId: id, metadata: METADATA, storage: new FileStorage(), logger: 'silent', telemetryEnabled: false })
  } catch (e) {
    throw new WcError(`could not start WalletConnect: ${e?.message || e}`, 'WC_NETWORK')
  }
}

/** Close the relay socket and timers so the process can exit. Never throws. */
export async function closeClient(client) {
  try { client?.core?.heartbeat?.stop?.() } catch { /* best effort */ }
  try { await client?.core?.relayer?.transportClose?.() } catch { /* best effort */ }
}

const withTimeout = (p, ms, onTimeout) => new Promise((resolve, reject) => {
  const t = setTimeout(() => reject(onTimeout()), ms)
  p.then((v) => { clearTimeout(t); resolve(v) }, (e) => { clearTimeout(t); reject(e) })
})

// ---------------------------------------------------------------- session

/** The wallet's address on `chainId` in a WalletConnect session (eip155 accounts "eip155:<chain>:<address>"), or null. */
export function accountOn(session, chainId) {
  const accounts = Object.values(session?.namespaces ?? {}).flatMap((n) => n?.accounts ?? [])
  for (const a of accounts) {
    const [ns, chain, address] = String(a).split(':')
    if (ns === 'eip155' && chain === String(chainId) && isAddress(address ?? '')) return address
  }
  return null
}
/** Every eip155 chain a session holds an account on. */
export const chainsOf = (session) => [...new Set(Object.values(session?.namespaces ?? {}).flatMap((n) => n?.accounts ?? [])
  .map((a) => String(a).split(':')).filter(([ns]) => ns === 'eip155').map(([, c]) => Number(c)))]

const shownSession = (s, now = Date.now()) => ({
  address: s.address, chainId: s.chainId, network: NETWORKS[s.chainId] ?? `chain ${s.chainId}`,
  wallet: s.peer?.name || null, ...(s.peer?.url && { walletUrl: s.peer.url }),
  connectedAt: new Date(s.createdAt).toISOString(), expiresAt: new Date(s.expiresAt).toISOString(),
  expiresInMin: Math.max(0, Math.round((s.expiresAt - now) / 60_000)),
})

/** Forget the session and every key the sign client kept (requests waiting to be sent go too). */
export function forget() {
  for (const name of [SESSION, STORE, CONNECT, REQ_DIR]) remove(file(name))
}

/**
 * Our session record, or { none } / { expired } (an expired one is forgotten at once: its keys are deleted, so nothing
 * can be sent with it any more).
 */
export function readSession(now = Date.now()) {
  const s = readJson(file(SESSION))
  if (!s || !s.topic || !isAddress(s.address ?? '')) return { none: true }
  if (!(s.expiresAt > now)) {
    forget()
    return { expired: true, expiredAt: new Date(s.expiresAt || 0).toISOString(), address: s.address }
  }
  return { session: s }
}

/** gang wallet status. */
export function status(now = Date.now()) {
  const r = readSession(now)
  if (r.session) return { success: true, connected: true, ...shownSession(r.session, now) }
  const c = readJson(file(CONNECT))
  if (c?.state === 'pairing' && c.waitUntil > now && pidAlive(c.pid)) {
    return {
      success: true, connected: false, pending: true, uri: c.uri, chainId: c.chainId, network: NETWORKS[c.chainId],
      waitingUntil: new Date(c.waitUntil).toISOString(),
      next: 'open the wallet app, scan the QR of this uri (or paste it), approve; then gang wallet status again',
    }
  }
  if (c?.state === 'failed') {
    return { success: true, connected: false, lastConnect: { failed: true, error: c.error, at: new Date(c.at).toISOString() }, next: 'gang wallet connect' }
  }
  return {
    success: true, connected: false, ...(r.expired && { expired: true, expiredAt: r.expiredAt }),
    next: 'gang wallet connect (add --testnet for BSC testnet)',
  }
}
const pidAlive = (pid) => {
  if (!Number.isInteger(pid)) return false
  try { process.kill(pid, 0); return true } catch (e) { return e.code === 'EPERM' }
}

/**
 * Start a session on `chainId` and wait for the wallet to approve it. onUri(uri) as soon as the pairing URI exists (print
 * it, draw its QR); keep() is asked once it is approved (false: drop it, unsaved). Refuses while a session is live or
 * another pairing waits: one wallet at a time. → our session record (saved).
 */
export async function connect({ chainId, timeoutS = CONNECT_TIMEOUT_S.def, onUri = () => {}, keep = () => true, client: given = null, now = () => Date.now() }) {
  if (!NETWORKS[chainId]) throw new WcError(`WalletConnect trades run on BSC (56) or BSC testnet (97), not ${chainId}`, 'USAGE')
  const live = readSession(now())
  if (live.session) {
    throw new WcError(`a wallet is connected already (${live.session.address} on ${NETWORKS[live.session.chainId]}): gang wallet disconnect first`, 'WC_CONNECTED')
  }
  // a gang wallet connect --no-wait still waiting in the background: one pairing at a time
  const pending = readJson(file(CONNECT))
  if (pending?.state === 'pairing' && pending.pid !== process.pid && pending.waitUntil > now() && pidAlive(pending.pid)) {
    throw new WcError('a connect is already waiting for the wallet (gang wallet status shows its uri): approve it there, or gang wallet disconnect to cancel it', 'WC_CONNECTED')
  }
  projectId() // before anything is written
  // a fresh store: no keys of an older (expired / disconnected) session stay around
  if (!given) forget()
  const client = given ?? await signClient()
  try {
    const chain = `eip155:${chainId}`
    let r
    try {
      r = await client.connect({ optionalNamespaces: { eip155: { chains: [chain], methods: METHODS, events: EVENTS } } })
    } catch (e) { throw new WcError(`could not reach the WalletConnect relay: ${e?.message || e}`, 'WC_NETWORK') }
    if (!r?.uri) throw new WcError('WalletConnect gave no pairing URI', 'WC_ERROR')
    await onUri(r.uri)
    let session
    try {
      session = await withTimeout(r.approval(), timeoutS * 1000, () => new WcError(`the wallet did not approve within ${timeoutS} s`, 'WC_TIMEOUT'))
    } catch (e) {
      if (e instanceof WcError) throw e
      throw new WcError(`the wallet did not connect: ${e?.message || e}`, 'WC_REFUSED')
    }
    const address = accountOn(session, chainId)
    // keep(): false once gang wallet disconnect cancelled the pairing meanwhile: the session is ended, not saved
    if (!keep()) {
      try { await client.disconnect({ topic: session.topic, reason: { code: 6000, message: 'User disconnected' } }) } catch { /* best effort */ }
      throw new WcError('the connect was cancelled (gang wallet disconnect) before the wallet approved it', 'WC_REFUSED')
    }
    if (!address) {
      try { await client.disconnect({ topic: session.topic, reason: { code: 5100, message: 'Unsupported chains' } }) } catch { /* best effort */ }
      const got = chainsOf(session)
      throw new WcError(`the wallet approved no account on ${NETWORKS[chainId]} (chain ${chainId})${got.length ? `, only on chain ${got.join(', ')}` : ''}: add the network in the wallet, then gang wallet connect again${chainId === 97 ? ' --testnet' : ''}`, 'WC_WRONG_CHAIN')
    }
    const t = now()
    const rec = {
      topic: session.topic, address, chainId,
      peer: { name: String(session.peer?.metadata?.name ?? '').slice(0, 80), url: String(session.peer?.metadata?.url ?? '').slice(0, 200) },
      createdAt: t, expiresAt: Math.min(t + SESSION_TTL_MS, Number(session.expiry) > 0 ? Number(session.expiry) * 1000 : Infinity),
    }
    writeJson(file(SESSION), rec)
    return shownSession(rec, t)
  } finally {
    if (!given) await closeClient(client)
  }
}

/** The connect-in-progress record `gang wallet connect --no-wait` keeps for `gang wallet status`. */
export const connectState = {
  path: () => file(CONNECT),
  read: () => readJson(file(CONNECT)),
  write: (rec) => writeJson(file(CONNECT), rec),
  clear: () => remove(file(CONNECT)),
}

/** gang wallet disconnect: tell the wallet (best effort, 10 s), then forget everything either way. */
export async function disconnect({ client: given = null } = {}) {
  // a pairing still waiting in the background loses its record below (forget), so it drops what it gets (connect keep)
  const s = readJson(file(SESSION))
  let told = false
  if (s?.topic) {
    let client = given
    try {
      client ??= await signClient()
      await withTimeout(client.disconnect({ topic: s.topic, reason: { code: 6000, message: 'User disconnected' } }), 10_000, () => new Error('timeout'))
      told = true
    } catch { /* the wallet may already have dropped it */ } finally {
      if (!given) await closeClient(client)
    }
  }
  forget()
  return { success: true, connected: false, disconnected: !!s?.topic, ...(s?.address && { address: s.address }), walletTold: told }
}

// ---------------------------------------------------------------- what may be sent: approve / wrap / buy / sell only

const ALLOWED_ABI = parseAbi([
  'function approve(address spender, uint256 amount) returns (bool)',
  'function deposit() payable',
  // GangLaunchpad V3 curve (v3.js PAD_ABI)
  'function buy(address token, uint256 quoteIn, uint256 minTokensOut) returns (uint256)',
  'function sell(address token, uint256 tokensIn, uint256 minQuoteOut) returns (uint256)',
  // GangRouter (steps.js ROUTER_ABI): curve buy in BNB, pool trades of graduated tokens
  'function v3Buy(address token, uint256 quoteIn, uint256 minTokensOut, uint256 deadline) returns (uint256)',
  'function v3BuyBNB(address token, uint256 minTokensOut, uint256 deadline) payable returns (uint256)',
  'function poolBuyBNB(address token, address quote, uint256 minTokensOut, uint256 deadline) payable returns (uint256)',
  'function poolBuy(address token, address quote, uint256 quoteIn, uint256 minTokensOut, uint256 deadline) returns (uint256)',
  'function poolSell(address token, address quote, uint256 amountIn, uint256 minQuoteOut, uint256 deadline) returns (uint256)',
  'function poolSellForBNB(address token, address quote, uint256 amountIn, uint256 minBnbOut, uint256 deadline) returns (uint256)',
  // a token's countdown reward module (countdown.js COUNTDOWN_ABI): the pool buy that counts
  'function buy(uint256 minTokensOut, uint256 deadline, bool mustCount) payable returns (uint256)',
  'function buyWithQuote(uint256 quoteIn, uint256 minTokensOut, uint256 deadline, bool mustCount) returns (uint256)',
])
// the arg that is the trade's floor, per function
const MIN_ARG = { buy: 'minTokensOut', sell: 'minQuoteOut', v3Buy: 'minTokensOut', v3BuyBNB: 'minTokensOut', poolBuyBNB: 'minTokensOut', poolBuy: 'minTokensOut', poolSell: 'minQuoteOut', poolSellForBNB: 'minBnbOut', buyWithQuote: 'minTokensOut' }

/** A tx's call → { functionName, args: { name: value } }, or null when it is not one ALLOWED_ABI lists. */
export function decodeAllowed(data) {
  if (!isHex(data ?? '') || data.length < 10) return null
  let d
  try { d = decodeFunctionData({ abi: ALLOWED_ABI, data }) } catch { return null }
  // two `buy` overloads with three inputs each: the selector tells them apart
  const sel = data.slice(0, 10).toLowerCase()
  const item = ALLOWED_ABI.find((x) => x.type === 'function' && toFunctionSelector(x) === sel)
  if (!item) return null
  const args = Object.fromEntries(item.inputs.map((inp, i) => [inp.name, d.args[i]]))
  return { functionName: d.functionName, args }
}

const big = (v) => (typeof v === 'bigint' ? v.toString() : v)
const same = (a, b) => typeof a === 'string' && typeof b === 'string' && a.toLowerCase() === b.toLowerCase()
const ROUTER_FNS = new Set(['v3Buy', 'v3BuyBNB', 'poolBuyBNB', 'poolBuy', 'poolSell', 'poolSellForBNB'])

/**
 * Every call goes to a contract gang knows on this chain: targets = { pads, routers, wbnb } (every GangLaunchpad
 * generation's pad and GangRouter). A countdown buy goes to the module the step named (o.module, read from the token's
 * tax recipient), and an approve only to one of those spenders. Throws WcError otherwise.
 */
function checkTarget(fn, to, args, countdownBuy, o, targets) {
  if (!targets) throw new WcError('internal: no known contracts to check the step against', 'WC_ERROR')
  const { pads = [], routers = [], wbnb } = targets
  const known = (list, a) => list.some((x) => same(x, a))
  const module = countdownBuy || (fn === 'approve' && o?.module) ? o?.module : null
  let ok
  if (fn === 'deposit') ok = same(to, wbnb)
  else if (countdownBuy) ok = isAddress(module ?? '') && same(to, module)
  else if (fn === 'buy' || fn === 'sell') ok = known(pads, to)
  else if (ROUTER_FNS.has(fn)) ok = known(routers, to)
  else if (fn === 'approve') ok = known(pads, args.spender) || known(routers, args.spender) || (isAddress(module ?? '') && same(args.spender, module))
  if (!ok) {
    throw new WcError(`refused: ${fn} ${fn === 'approve' ? `to spender ${args.spender}` : `on ${to}`} is not a gang pad, router or the token's countdown module`, 'WC_ERROR')
  }
}

/**
 * A built step (a --from … --calldata result of gang buy / sell) → the wallet request we keep and the fields the preview
 * shows instead of its raw tx. Throws WcError when the step is not one --wallet wc may send. `session` is ours.
 */
export function toRequest(o, session, { targets, now = Date.now(), id = `wc-${randomBytes(12).toString('hex')}` } = {}) {
  const tx = o?.tx
  if (!tx || typeof tx !== 'object') throw new WcError('nothing to send: this result carries no transaction', 'WC_ERROR')
  if (String(tx.from).toLowerCase() !== String(session.address).toLowerCase()) {
    throw new WcError(`the step was built for ${tx.from}, not the connected wallet ${session.address}`, 'WC_WRONG_WALLET')
  }
  if (Number(tx.chainId) !== Number(session.chainId)) {
    throw new WcError(`the step is on chain ${tx.chainId}, the connected wallet session on ${session.chainId}`, 'WC_WRONG_CHAIN')
  }
  if (!isAddress(tx.to ?? '')) throw new WcError('the step has no valid target address', 'WC_ERROR')
  const call = decodeAllowed(tx.data)
  if (!call) {
    throw new WcError('--wallet wc only sends approve, BNB wrap, buy and sell calls; this step is something else: use the Binance Agentic Wallet for it', 'AGENTIC_ONLY', { selector: String(tx.data ?? '').slice(0, 10) })
  }
  const value = BigInt(tx.value ?? 0)
  const fn = call.functionName
  const countdownBuy = (fn === 'buy' && 'mustCount' in call.args) || fn === 'buyWithQuote'
  // a call paid in BNB names it; nothing else may move native BNB
  if (value > 0n && !(['deposit', 'v3BuyBNB', 'poolBuyBNB'].includes(fn) || (fn === 'buy' && 'mustCount' in call.args))) {
    throw new WcError(`refused: ${fn} with ${formatUnits(value, 18)} BNB attached`, 'WC_ERROR')
  }
  checkTarget(fn, tx.to, call.args, countdownBuy, o, targets)
  const isApprove = call.functionName === 'approve'
  const min = MIN_ARG[call.functionName]
  const shows = {
    network: NETWORKS[session.chainId], chainId: Number(tx.chainId), from: tx.from, to: tx.to, function: call.functionName,
    args: Object.fromEntries(Object.entries(call.args).map(([k, v]) => [k, big(v)])),
    valueBnb: formatUnits(value, 18), step: o.step ?? null, token: o.token ?? null,
    ...(isApprove && { approves: { token: tx.to, spender: call.args.spender, amount: o.approve ?? null, amountRaw: call.args.amount.toString(), exact: true } }),
    ...(call.functionName === 'deposit' && { wraps: { bnb: formatUnits(value, 18) } }),
    ...(!isApprove && call.functionName !== 'deposit' && {
      trade: {
        side: /sell/i.test(call.functionName) ? 'sell' : 'buy',
        ...(o.spend != null && { spend: o.spend }), ...(o.amount != null && { amount: o.amount }), ...(o.quote && { quote: o.quote }),
        ...(o.expectTokens != null && { expectTokens: o.expectTokens }), ...(o.expectOut != null && { expectOut: o.expectOut }),
        ...(o.minTokensOut != null && { minTokensOut: o.minTokensOut }), ...(o.minOut != null && { minOut: o.minOut }),
        ...(min && call.args[min] != null && { minOutRaw: call.args[min].toString() }),
      },
    }),
  }
  const tx_ = { chainId: Number(tx.chainId), from: tx.from, to: tx.to, data: tx.data, value: value.toString(), ...(tx.gas && { gas: String(tx.gas) }) }
  return { id, rec: { requestId: id, tx: tx_, shows, createdAt: now, expiresAt: now + REQUEST_TTL_MS, topic: session.topic }, shows }
}

/** One line per field for the terminal (stderr), before the wallet is asked. */
export function describe(shows) {
  const l = [`WalletConnect request on ${shows.network} (chain ${shows.chainId}), from ${shows.from}`, `  call: ${shows.function} on ${shows.to}`]
  if (shows.token) l.push(`  token: ${shows.token}`)
  if (shows.approves) l.push(`  approve exactly ${shows.approves.amount ?? shows.approves.amountRaw} (raw ${shows.approves.amountRaw}) of ${shows.approves.token} to ${shows.approves.spender}`)
  if (shows.wraps) l.push(`  wrap ${shows.wraps.bnb} BNB into WBNB`)
  if (shows.trade) {
    const t = shows.trade
    l.push(`  ${t.side}: ${t.spend != null ? `spend ${t.spend}` : `amount ${t.amount}`}${t.quote ? ` (${t.quote})` : ''}`)
    const min = t.minTokensOut ?? t.minOut
    if (min != null || t.minOutRaw) l.push(`  minimum out: ${min ?? '?'}${t.minOutRaw ? ` (raw ${t.minOutRaw})` : ''}`)
  }
  if (shows.valueBnb !== '0') l.push(`  BNB sent with it: ${shows.valueBnb}`)
  l.push('  confirm it in your wallet app (or reject it there)')
  return l.join('\n')
}

// ---------------------------------------------------------------- requests waiting for gang execute

const reqPath = (id) => join(dir(), REQ_DIR, `${id}.json`)
const sentPath = (id) => join(dir(), REQ_DIR, `${id}.sent`)
const ID_RE = /^wc-[0-9a-f]{24}$/
export const isWcRequestId = (id) => typeof id === 'string' && id.startsWith('wc-')

export function saveRequest(rec, now = Date.now()) {
  ensureDir(join(dir(), REQ_DIR))
  // older than a day: gone (an unsent one expired long ago; a sent one has its hash in the result already)
  try {
    for (const name of readdirSync(join(dir(), REQ_DIR))) {
      const p = join(dir(), REQ_DIR, name)
      try { if (now - statSync(p).mtimeMs > 24 * 3600_000) unlinkSync(p) } catch { /* gone */ }
    }
  } catch { /* none */ }
  writeJson(reqPath(rec.requestId), rec)
}

/**
 * The request `id` for sending, claimed once: a second execute of the same id is refused, whatever happened to the
 * first (it may have reached the wallet). Throws WcError.
 */
export function claimRequest(id, now = Date.now()) {
  if (!ID_RE.test(String(id))) throw new WcError('not a WalletConnect request id (wc- + 24 hex)', 'USAGE')
  const rec = readJson(reqPath(id))
  if (!rec) throw new WcError('no such WalletConnect request on this machine (expired, or built elsewhere): run the same gang buy / sell --wallet wc again', 'WC_NO_REQUEST')
  let fd
  try { fd = openSync(sentPath(id), 'wx', 0o600) } catch (e) {
    if (e.code === 'EEXIST') {
      const sent = readJson(sentPath(id))
      throw new WcError('this request was already handed to the wallet once: never send it again. Check the wallet\'s activity (gang tx --hash <hash> if it has one), then build a new one if needed', 'WC_ALREADY_SENT', sent?.txHash ? { txHash: sent.txHash } : {})
    }
    throw e
  }
  closeSync(fd)
  if (!(rec.expiresAt > now)) {
    throw new WcError(`this request expired at ${new Date(rec.expiresAt).toISOString()} (they last ${REQUEST_TTL_MS / 60_000} min, so the price is fresh): run the same gang buy / sell --wallet wc again`, 'WC_EXPIRED')
  }
  return rec
}
export const markSent = (id, data) => { try { writeJson(sentPath(id), { ...data, at: Date.now() }) } catch { /* the claim itself already blocks a resend */ } }

// ---------------------------------------------------------------- sending

const REJECTED = /reject|denied|cancel|declin|user disapproved/i

/**
 * eth_sendTransaction of a stored request to the session's wallet; resolves with the tx hash once the user confirmed.
 * Refuses a session that is not on the request's chain (never switches it). Throws WcError (code WC_REJECTED when the
 * user said no, WC_TIMEOUT when no answer came: then it may still be sent, so never resend).
 */
export async function sendRequest(rec, session, { client: given = null, timeoutS = SEND_TIMEOUT_S.def } = {}) {
  const { tx } = rec
  if (session.topic !== rec.topic) throw new WcError('this request was built for another WalletConnect session: run the same gang buy / sell --wallet wc again', 'WC_WRONG_WALLET')
  if (String(tx.from).toLowerCase() !== String(session.address).toLowerCase()) throw new WcError(`the request is from ${tx.from}, the connected wallet is ${session.address}`, 'WC_WRONG_WALLET')
  if (Number(tx.chainId) !== Number(session.chainId)) throw new WcError(`the request is on chain ${tx.chainId}, the wallet session on ${session.chainId}`, 'WC_WRONG_CHAIN')
  // the call is checked again here: the request file is ours, but nothing but these calls ever leaves through WC
  if (!decodeAllowed(tx.data)) throw new WcError('--wallet wc only sends approve, BNB wrap, buy and sell calls', 'AGENTIC_ONLY')
  const client = given ?? await signClient()
  try {
    let live
    try { live = client.session.get(session.topic) } catch { live = null }
    if (!live) throw new WcError('the wallet ended this WalletConnect session: gang wallet connect again', 'WC_NO_SESSION')
    const acct = accountOn(live, tx.chainId)
    if (!acct || acct.toLowerCase() !== tx.from.toLowerCase()) {
      const got = chainsOf(live)
      throw new WcError(`the wallet session has no account ${tx.from} on ${NETWORKS[tx.chainId] ?? tx.chainId} (it holds chain ${got.join(', ') || 'none'}): switch the network in the wallet and reconnect (gang wallet disconnect, then gang wallet connect${Number(tx.chainId) === 97 ? ' --testnet' : ''}); gang never switches it for you`, 'WC_WRONG_CHAIN')
    }
    const params = {
      from: tx.from, to: tx.to, data: tx.data, value: toHex(BigInt(tx.value ?? 0)),
      ...(tx.gas && { gas: toHex(BigInt(tx.gas)) }),
    }
    let hash
    try {
      hash = await withTimeout(
        client.request({ topic: session.topic, chainId: `eip155:${tx.chainId}`, request: { method: 'eth_sendTransaction', params: [params] }, expiry: Math.max(300, timeoutS) }),
        timeoutS * 1000,
        () => new WcError(`no answer from the wallet within ${timeoutS} s: it may still send it. Never resend: check the wallet's activity first`, 'WC_TIMEOUT'))
    } catch (e) {
      if (e instanceof WcError) throw e
      const msg = String(e?.message ?? e)
      if (e?.code === 4001 || e?.code === 5000 || REJECTED.test(msg)) throw new WcError('the wallet rejected the request: nothing was sent', 'WC_REJECTED')
      throw new WcError(`the wallet answered with an error: ${msg}`, 'WC_ERROR')
    }
    if (typeof hash !== 'string' || !/^0x[0-9a-fA-F]{64}$/.test(hash)) {
      throw new WcError('the wallet answered without a tx hash: check its activity before trying again', 'WC_TIMEOUT', { answer: String(hash).slice(0, 80) })
    }
    return hash.toLowerCase()
  } finally {
    if (!given) await closeClient(client)
  }
}

// ---------------------------------------------------------------- terminal QR (lazy)

/** The pairing URI as a terminal QR code (text), or null when the QR module is missing. */
export async function qrText(uri) {
  let mod
  try { mod = await import('qrcode-terminal') } catch { return null }
  const q = mod.default ?? mod
  return new Promise((resolve) => q.generate(uri, { small: true }, (s) => resolve(s)))
}
