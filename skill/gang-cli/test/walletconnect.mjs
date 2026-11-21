/**
 * --wallet wc (WalletConnect, wc.js) with a mocked sign client: the project ID only from the env and never printed, 0600
 * files, session expiry, the chain check (refused, never switched), what a request may call, the exact
 * eth_sendTransaction params, a request sent at most once, and every command but buy / sell refused.
 *
 *   node skill/gang-cli/test/walletconnect.mjs
 */
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { chmodSync, mkdirSync, mkdtempSync, readdirSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'
import { encodeFunctionData, parseAbi } from 'viem'

const DIR = mkdtempSync(join(tmpdir(), 'gang-wc-test-'))
process.env.GANG_WC_DIR = join(DIR, 'wc')
// a made-up ID of the right shape: the real one is never in this repo
const FAKE_ID = 'f00dfeedf00dfeedf00dfeedf00dfeed'
process.env.GANG_WC_PROJECT_ID = FAKE_ID
const wc = await import('../src/wc.js')

const CLI = fileURLToPath(new URL('../src/index.js', import.meta.url))
const env = { ...process.env, GANG_TELEMETRY: '0', GANG_UPDATE_CHECK: '0', GANG_API: 'http://127.0.0.1:1/api', GANG_RPC_URL: 'http://127.0.0.1:1', PATH: '/usr/bin:/bin' }
const run = async (argv, extraEnv = {}) => {
  let r
  try { r = await promisify(execFile)(process.execPath, [CLI, ...argv], { env: { ...env, ...extraEnv }, encoding: 'utf8', timeout: 20_000 }) } catch (e) { r = e }
  return { status: r.code ?? 0, out: JSON.parse(r.stdout), stdout: r.stdout, stderr: r.stderr }
}

const ME = '0x1111111111111111111111111111111111111111'
const OTHER = '0x2222222222222222222222222222222222222222'
const TOKEN = '0x3333333333333333333333333333333333333333'
const MODULE = '0x4444444444444444444444444444444444444444'
const PAD = '0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29' // mainnet 3.0 pad (gangpad.js)
const ROUTER = '0xec9717E5C68b9F18fA76D3961C9Cd7e67b5E61e7'
const WBNB = '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c'
const TARGETS = { pads: [PAD], routers: [ROUTER], wbnb: WBNB }
const ABI = parseAbi([
  'function approve(address spender, uint256 amount) returns (bool)',
  'function deposit() payable',
  'function buy(address token, uint256 quoteIn, uint256 minTokensOut) returns (uint256)',
  'function sell(address token, uint256 tokensIn, uint256 minQuoteOut) returns (uint256)',
  'function v3BuyBNB(address token, uint256 minTokensOut, uint256 deadline) payable returns (uint256)',
  'function poolSell(address token, address quote, uint256 amountIn, uint256 minQuoteOut, uint256 deadline) returns (uint256)',
  'function buy(uint256 minTokensOut, uint256 deadline, bool mustCount) payable returns (uint256)',
  'function transfer(address to, uint256 amount) returns (bool)',
  'function postBond(address token, uint256 amount) returns (bool)',
])
const call = (functionName, args) => encodeFunctionData({ abi: ABI, functionName, args })
const session = (chainId = 56, address = ME, over = {}) => ({ topic: 'topic-1', address, chainId, peer: { name: 'Test Wallet', url: 'https://wallet.example' }, createdAt: Date.now(), expiresAt: Date.now() + 3600_000, ...over })
const wcSession = (chainIds = [56], address = ME) => ({
  topic: 'topic-1', expiry: Math.floor(Date.now() / 1000) + 7 * 86400, peer: { metadata: { name: 'Test Wallet', url: 'https://wallet.example' } },
  namespaces: { eip155: { accounts: chainIds.map((c) => `eip155:${c}:${address}`), methods: ['eth_sendTransaction'], events: [] } },
})
const writeSession = (s) => { wc.writeJson(join(process.env.GANG_WC_DIR, 'session.json'), s) }
const throwsCode = async (fn, code, re) => {
  let err
  try { await fn() } catch (e) { err = e }
  assert.ok(err, `expected ${code}`)
  assert.equal(err.code, code, err.message)
  if (re) assert.match(err.message, re)
  return err
}
const mode = (p) => statSync(p).mode & 0o777

try {
  // --- the project ID: env only, checked, never printed
  // env first; else gang.fun's /walletconnect (mocked here), kept for the run only
  const noFetch = () => { throw new Error('fetched') }
  assert.equal(await wc.projectId({ env: { GANG_WC_PROJECT_ID: FAKE_ID }, fetchImpl: noFetch }), FAKE_ID)
  await throwsCode(() => wc.projectId({ env: { GANG_WC_PROJECT_ID: 'nope' }, fetchImpl: noFetch }), 'WC_NO_PROJECT_ID')
  const asked = []
  const SERVED = 'abcdef0123456789abcdef0123456789'
  const served = (body, ok = true) => async (url) => { asked.push(url); return { ok, json: async () => body } }
  const fresh = async () => import(`../src/wc.js?run=${Math.random()}`) // a new run: nothing resolved yet
  let m = await fresh()
  await throwsCode(() => m.projectId({ env: {}, fetchImpl: served({}, false), api: 'https://x.test/api' }), 'WC_NO_PROJECT_ID', /unavailable right now; set GANG_WC_PROJECT_ID or retry|unavailable right now: set GANG_WC_PROJECT_ID/)
  await throwsCode(() => m.projectId({ env: {}, fetchImpl: served({ projectId: 'short' }), api: 'https://x.test/api' }), 'WC_NO_PROJECT_ID')
  await throwsCode(() => m.projectId({ env: {}, fetchImpl: async () => { throw new Error('offline') }, api: 'https://x.test/api' }), 'WC_NO_PROJECT_ID')
  assert.equal(await m.projectId({ env: {}, fetchImpl: served({ projectId: SERVED }), api: 'https://x.test/api' }), SERVED)
  assert.equal(asked.at(-1), 'https://x.test/api/walletconnect')
  const n0 = asked.length
  assert.equal(await m.projectId({ env: {}, fetchImpl: served({ projectId: SERVED }) }), SERVED)
  assert.equal(asked.length, n0, 'fetched once per run')
  assert.equal(m.scrub(`bad ${SERVED}`, {}), 'bad <project id>', 'a served ID is scrubbed too')
  assert.equal(m.knownProjectId(), SERVED)
  m = await fresh()
  assert.equal(await m.projectId({ env: { GANG_API: 'https://y.test/api/' }, fetchImpl: served({ projectId: SERVED }) }), SERVED)
  assert.equal(asked.at(-1), 'https://y.test/api/walletconnect', 'follows GANG_API')
  assert.equal(wc.scrub(`wss://relay.walletconnect.org/?projectId=${FAKE_ID}&ua=x failed`), 'wss://relay.walletconnect.org/?projectId=<redacted>&ua=x failed')
  assert.equal(wc.scrub(`bad key ${FAKE_ID}`), 'bad key <project id>')
  assert.ok(!new wc.WcError(`relay refused ${FAKE_ID}`).message.includes(FAKE_ID))

  // --- files: dir 0700, files 0600
  const st = new wc.FileStorage(join(process.env.GANG_WC_DIR, 'store.json'))
  await st.setItem('wc@2:core:keychain', { k: 'v' })
  assert.deepEqual(await new wc.FileStorage(join(process.env.GANG_WC_DIR, 'store.json')).getItem('wc@2:core:keychain'), { k: 'v' })
  assert.equal(mode(process.env.GANG_WC_DIR), 0o700)
  assert.equal(mode(join(process.env.GANG_WC_DIR, 'store.json')), 0o600)
  await st.removeItem('wc@2:core:keychain')
  assert.deepEqual(await st.getKeys(), [])
  // a store this process no longer owns (forgotten by a disconnect meanwhile) is not written back
  const ghost = new wc.FileStorage(join(process.env.GANG_WC_DIR, 'ghost.json'), () => false)
  await ghost.setItem('k', 1)
  assert.ok(!readdirSync(process.env.GANG_WC_DIR).includes('ghost.json'))
  // keys only in a private directory of this user
  const loose = join(DIR, 'loose')
  mkdirSync(loose, { mode: 0o755 })
  chmodSync(loose, 0o755)
  wc.writeJson(join(loose, 'x.json'), {})
  assert.equal(mode(loose), 0o700, 'tightened to 0700')
  symlinkSync(loose, join(DIR, 'link'))
  await throwsCode(() => wc.writeJson(join(DIR, 'link', 'y.json'), {}), 'WC_ERROR', /not a plain directory/)

  // --- connect (mocked client): BSC account saved for 24 h at most; the wrong chain refused and dropped; a timeout
  let disconnected = null
  const connector = (chains, { approve = true } = {}) => ({
    connect: async (p) => {
      assert.deepEqual(p.optionalNamespaces.eip155.chains, ['eip155:56'])
      assert.deepEqual(p.optionalNamespaces.eip155.methods, ['eth_sendTransaction'])
      assert.equal(p.requiredNamespaces, undefined)
      return { uri: 'wc:abc@2?relay-protocol=irn&symKey=00', approval: () => (approve ? Promise.resolve(wcSession(chains)) : new Promise(() => {})) }
    },
    disconnect: async (p) => { disconnected = p },
  })
  let seenUri = null
  const s1 = await wc.connect({ chainId: 56, timeoutS: 5, client: connector([56]), onUri: (u) => { seenUri = u } })
  assert.equal(seenUri, 'wc:abc@2?relay-protocol=irn&symKey=00')
  assert.equal(s1.address, ME)
  assert.equal(s1.chainId, 56)
  assert.ok(new Date(s1.expiresAt).getTime() <= Date.now() + wc.SESSION_TTL_MS + 1000, 'a session lasts 24 h at most')
  assert.equal(mode(join(process.env.GANG_WC_DIR, 'session.json')), 0o600)
  assert.equal(wc.status().connected, true)
  assert.equal(wc.status().wallet, 'Test Wallet')
  await throwsCode(() => wc.connect({ chainId: 56, timeoutS: 5, client: connector([56]) }), 'WC_CONNECTED')
  wc.forget()
  await throwsCode(() => wc.connect({ chainId: 56, timeoutS: 5, client: connector([1]) }), 'WC_WRONG_CHAIN', /only on chain 1/)
  assert.equal(disconnected?.topic, 'topic-1', 'a session on the wrong chain is dropped at once')
  assert.equal(wc.status().connected, false)
  await throwsCode(() => wc.connect({ chainId: 56, timeoutS: 0.05, client: connector([56], { approve: false }) }), 'WC_TIMEOUT')
  await throwsCode(() => wc.connect({ chainId: 1, client: connector([1]) }), 'USAGE')
  // a pairing cancelled while it waited (gang wallet disconnect): the approval is dropped, nothing saved
  disconnected = null
  await throwsCode(() => wc.connect({ chainId: 56, timeoutS: 5, client: connector([56]), keep: () => false }), 'WC_REFUSED', /cancelled/)
  assert.equal(disconnected?.topic, 'topic-1')
  assert.equal(wc.status().connected, false)
  // another pairing still waiting (a live pid): one at a time
  wc.connectState.write({ state: 'pairing', uri: 'wc:x', chainId: 56, pid: process.ppid, startedAt: Date.now(), waitUntil: Date.now() + 60_000 })
  await throwsCode(() => wc.connect({ chainId: 56, timeoutS: 5, client: connector([56]) }), 'WC_CONNECTED', /already waiting/)
  assert.equal(wc.status().pending, true)
  wc.forget()

  // --- expiry: an expired session is forgotten with its keys
  writeSession(session(56, ME, { expiresAt: Date.now() - 1 }))
  writeFileSync(join(process.env.GANG_WC_DIR, 'store.json'), '{"k":1}', { mode: 0o600 })
  const exp = wc.readSession()
  assert.equal(exp.expired, true)
  assert.deepEqual(readdirSync(process.env.GANG_WC_DIR), [], 'session and sign-client keys deleted')
  assert.equal(wc.status().connected, false)

  // --- what a request may call
  const S = session()
  const approveStep = { success: true, step: 'approve-quote', approve: '0.5', token: TOKEN, tx: { chainId: 56, from: ME, to: TOKEN, data: call('approve', [PAD, 5n * 10n ** 17n]), value: '0' } }
  const a = wc.toRequest(approveStep, S, { targets: TARGETS })
  assert.match(a.id, /^wc-[0-9a-f]{24}$/)
  assert.deepEqual(a.shows.approves, { token: TOKEN, spender: PAD, amount: '0.5', amountRaw: '500000000000000000', exact: true })
  assert.equal(a.rec.expiresAt - a.rec.createdAt, wc.REQUEST_TTL_MS)
  const buyStep = { success: true, step: 'buy', token: TOKEN, spend: '0.5', quote: 'USDT', expectTokens: '1000', minTokensOut: '990', tx: { chainId: 56, from: ME, to: PAD, data: `${call('buy', [TOKEN, 5n * 10n ** 17n, 990n * 10n ** 18n])}deadbeef`, value: '0' } }
  const b = wc.toRequest(buyStep, S, { targets: TARGETS })
  assert.deepEqual(b.shows.trade, { side: 'buy', spend: '0.5', quote: 'USDT', expectTokens: '1000', minTokensOut: '990', minOutRaw: '990000000000000000000' })
  assert.equal(b.shows.token, TOKEN)
  assert.match(wc.describe(b.shows), /minimum out: 990 \(raw 990000000000000000000\)/)
  assert.match(wc.describe(a.shows), /approve exactly 0\.5/)
  const sellStep = { success: true, step: 'pool-sell', token: TOKEN, amount: '100', minOut: '0.1', tx: { chainId: 56, from: ME, to: ROUTER, data: call('poolSell', [TOKEN, WBNB, 100n, 1n, 9n]), value: '0' } }
  assert.equal(wc.toRequest(sellStep, S, { targets: TARGETS }).shows.trade.side, 'sell')
  const bnbBuy = { success: true, step: 'buy', tx: { chainId: 56, from: ME, to: ROUTER, data: call('v3BuyBNB', [TOKEN, 1n, 9n]), value: '1000' } }
  assert.equal(wc.toRequest(bnbBuy, S, { targets: TARGETS }).shows.valueBnb, '0.000000000000001')
  const cd = { success: true, step: 'pool-buy', module: MODULE, tx: { chainId: 56, from: ME, to: MODULE, data: call('buy', [1n, 9n, true]), value: '5' } }
  assert.equal(wc.toRequest(cd, S, { targets: TARGETS }).shows.function, 'buy')
  const wrap = { success: true, step: 'wrap-bnb', tx: { chainId: 56, from: ME, to: WBNB, data: call('deposit', []), value: '7' } }
  assert.deepEqual(wc.toRequest(wrap, S, { targets: TARGETS }).shows.wraps, { bnb: '0.000000000000000007' })
  // refused: unlimited and zero approvals
  await throwsCode(() => wc.toRequest({ ...approveStep, tx: { ...approveStep.tx, data: call('approve', [PAD, 2n ** 256n - 1n]) } }, S, { targets: TARGETS }), 'WC_ERROR', /unlimited/)
  await throwsCode(() => wc.toRequest({ ...approveStep, tx: { ...approveStep.tx, data: call('approve', [PAD, 0n]) } }, S, { targets: TARGETS }), 'WC_ERROR')
  // a token symbol can't put terminal control codes on the screen
  assert.ok(!/\u001b/.test(wc.describe({ ...b.shows, trade: { ...b.shows.trade, quote: 'X\u001b[2J' } })))
  // refused: anything but approve / wrap / buy / sell, unknown targets, BNB on a call that takes none, someone else's step
  await throwsCode(() => wc.toRequest({ ...buyStep, tx: { ...buyStep.tx, data: call('transfer', [OTHER, 1n]) } }, S, { targets: TARGETS }), 'AGENTIC_ONLY')
  await throwsCode(() => wc.toRequest({ ...buyStep, tx: { ...buyStep.tx, to: TOKEN, data: call('postBond', [TOKEN, 1n]) } }, S, { targets: TARGETS }), 'AGENTIC_ONLY')
  await throwsCode(() => wc.toRequest({ ...approveStep, tx: { ...approveStep.tx, data: call('approve', [OTHER, 1n]) } }, S, { targets: TARGETS }), 'WC_ERROR', /not a gang pad/)
  await throwsCode(() => wc.toRequest({ ...buyStep, tx: { ...buyStep.tx, to: OTHER } }, S, { targets: TARGETS }), 'WC_ERROR', /not a gang pad/)
  await throwsCode(() => wc.toRequest({ ...sellStep, tx: { ...sellStep.tx, to: PAD } }, S, { targets: TARGETS }), 'WC_ERROR')
  await throwsCode(() => wc.toRequest({ ...cd, module: undefined }, S, { targets: TARGETS }), 'WC_ERROR')
  await throwsCode(() => wc.toRequest({ ...wrap, tx: { ...wrap.tx, to: OTHER } }, S, { targets: TARGETS }), 'WC_ERROR')
  await throwsCode(() => wc.toRequest({ ...buyStep, tx: { ...buyStep.tx, value: '1' } }, S, { targets: TARGETS }), 'WC_ERROR', /BNB attached/)
  await throwsCode(() => wc.toRequest({ ...buyStep, tx: { ...buyStep.tx, from: OTHER } }, S, { targets: TARGETS }), 'WC_WRONG_WALLET')
  await throwsCode(() => wc.toRequest({ ...buyStep, tx: { ...buyStep.tx, chainId: 97 } }, S, { targets: TARGETS }), 'WC_WRONG_CHAIN')
  await throwsCode(() => wc.toRequest(buyStep, S, {}), 'WC_ERROR')

  // --- a request is sent at most once, and only while fresh
  wc.saveRequest(b.rec)
  assert.equal(mode(join(process.env.GANG_WC_DIR, 'requests', `${b.id}.json`)), 0o600)
  const claimed = wc.claimRequest(b.id)
  assert.equal(claimed.tx.to, PAD)
  await throwsCode(() => wc.claimRequest(b.id), 'WC_ALREADY_SENT')
  wc.saveRequest({ ...a.rec, expiresAt: Date.now() - 1 })
  await throwsCode(() => wc.claimRequest(a.id), 'WC_EXPIRED')
  await throwsCode(() => wc.claimRequest(a.id), 'WC_ALREADY_SENT')
  await throwsCode(() => wc.claimRequest('wc-nope'), 'USAGE')
  await throwsCode(() => wc.claimRequest(`wc-${'0'.repeat(24)}`), 'WC_NO_REQUEST')

  // --- sending: the exact params; the chain checked against the live session (never switched)
  const HASH = `0x${'ab'.repeat(32)}`
  const requests = []
  const sender = (chains = [56], answer = () => HASH) => ({
    session: { get: (topic) => { assert.equal(topic, 'topic-1'); return wcSession(chains) } },
    request: async (p) => { requests.push(p); return answer(p) },
  })
  const rec = { ...b.rec, tx: { ...b.rec.tx, gas: '750000' } }
  assert.equal(await wc.sendRequest(rec, S, { client: sender(), timeoutS: 60 }), HASH)
  assert.deepEqual(requests.at(-1), {
    topic: 'topic-1', chainId: 'eip155:56', expiry: 300,
    request: { method: 'eth_sendTransaction', params: [{ from: ME, to: PAD, data: buyStep.tx.data, value: '0x0', chainId: '0x38', gas: '0xb71b0' }] },
  })
  const n = requests.length
  await throwsCode(() => wc.sendRequest(rec, S, { client: sender([1]) }), 'WC_WRONG_CHAIN', /never switches/)
  await throwsCode(() => wc.sendRequest(rec, session(97), { client: sender([97]) }), 'WC_WRONG_CHAIN')
  await throwsCode(() => wc.sendRequest(rec, session(56, OTHER), { client: sender() }), 'WC_WRONG_WALLET')
  await throwsCode(() => wc.sendRequest(rec, { ...S, topic: 'other' }, { client: sender() }), 'WC_WRONG_WALLET')
  await throwsCode(() => wc.sendRequest({ ...rec, tx: { ...rec.tx, data: call('transfer', [OTHER, 1n]) } }, S, { client: sender() }), 'AGENTIC_ONLY')
  await throwsCode(() => wc.sendRequest(rec, S, { client: { session: { get: () => { throw new Error('No matching key') } }, request: () => HASH } }), 'WC_NO_SESSION')
  assert.equal(requests.length, n, 'nothing reaches the wallet when a check fails')
  await throwsCode(() => wc.sendRequest(rec, S, { client: sender([56], () => { throw Object.assign(new Error('User rejected'), { code: 5000 }) }) }), 'WC_REJECTED')
  // only the user's no means nothing went out: anything else after the request left may still be sent
  const rej = await throwsCode(() => wc.sendRequest(rec, S, { client: sender([56], () => { throw Object.assign(new Error('x'), { code: 4001 }) }) }), 'WC_REJECTED')
  assert.equal(rej.extra.requested, undefined)
  assert.equal((await throwsCode(() => wc.sendRequest(rec, S, { client: sender([56], () => '0x1234') }), 'WC_UNKNOWN')).extra.requested, true)
  assert.equal((await throwsCode(() => wc.sendRequest(rec, S, { client: sender([56], () => new Promise(() => {})), timeoutS: 0.05 }), 'WC_TIMEOUT', /Never resend/)).extra.requested, true)
  const relay = await throwsCode(() => wc.sendRequest(rec, S, { client: sender([56], () => { throw new Error(`relay ?projectId=${FAKE_ID} down`) }) }), 'WC_UNKNOWN', /projectId=<redacted>/)
  assert.equal(relay.extra.requested, true)
  assert.match(relay.message, /never resend/)
  // the request outlives our own wait
  await wc.sendRequest(rec, S, { client: sender(), timeoutS: 600 })
  assert.equal(requests.at(-1).expiry, 720)
  // at send time the stored tx is checked again against the known contracts: a tampered file is refused
  const nb = requests.length
  await throwsCode(() => wc.sendRequest({ ...rec, tx: { ...rec.tx, to: OTHER } }, S, { client: sender(), targets: TARGETS }), 'WC_ERROR', /not a gang pad/)
  assert.equal(requests.length, nb)
  const again = wc.recheck({ ...b.rec, shows: { lies: true } }, S, TARGETS)
  assert.deepEqual(again.shows, b.shows, 'shows rebuilt from the tx, never the file')
  assert.equal(wc.moduleOf(wc.toRequest(cd, S, { targets: TARGETS }).rec), MODULE)
  assert.equal(wc.moduleOf(b.rec), null)

  // --- CLI: --wallet wc on anything but buy / sell is refused before any read
  wc.forget()
  for (const argv of [
    ['create', '--name', 'T', '--symbol', 'T'], ['bond', 'post', '--token', TOKEN], ['call-bond', 'post', '--token', TOKEN],
    ['promote', 'buy', '--token', TOKEN, '--promoter', OTHER, '--amount', '1'], ['follow', `0x${'1'.repeat(64)}`, '--amount', '1'],
    ['mint', '--token', TOKEN, '--shares', '1'], ['withdraw', '--token', TOKEN, '--all'], ['v3', 'buy', '--token', TOKEN, '--amount', '1'],
    ['fly', 'mint', '--token', TOKEN], ['claim', '--token', TOKEN], ['weekly', 'apply'], ['execute', '--request-id', 'x'],
    ['floor', 'redeem', '--token', TOKEN], ['base', 'release', '--token', TOKEN], ['campaign', 'join'],
  ]) {
    const r = await run([...argv, '--wallet', 'wc'])
    assert.equal(r.status, 1, argv.join(' '))
    assert.equal(r.out.code, 'AGENTIC_ONLY', `${argv.join(' ')}: ${r.out.error}`)
    assert.match(r.out.error, /Binance Agentic Wallet/)
  }
  let r = await run(['buy', '--token', TOKEN, '--amount', '1', '--wallet', 'metamask'])
  assert.equal(r.out.code, 'USAGE')
  for (const v of ['buy', 'sell']) {
    r = await run([v, '--token', TOKEN, '--amount', '1', '--wallet=wc'])
    assert.equal(r.out.code, 'USAGE', `${v} --wallet=wc`)
    assert.match(r.out.error, /after a space/)
  }
  assert.equal(r.out.code, 'USAGE')
  r = await run(['buy', '--token', TOKEN, '--amount', '1', '--wallet', 'wc'])
  assert.equal(r.out.code, 'WC_NO_SESSION')
  for (const [f, code] of [[['--from', OTHER], 'USAGE'], [['--calldata'], 'USAGE'], [['--promoter', OTHER], 'AGENTIC_ONLY'], [['--follow', `0x${'1'.repeat(64)}`], 'AGENTIC_ONLY']]) {
    r = await run(['buy', '--token', TOKEN, '--amount', '1', '--wallet', 'wc', ...f])
    assert.equal(r.out.code, code, f[0])
  }
  for (const f of ['--break-bond', '--break-call-bond', '--settle-first', '--confirm-out']) {
    r = await run(['sell', '--token', TOKEN, '--all', '--wallet', 'wc', f])
    assert.equal(r.out.code, 'AGENTIC_ONLY', f)
  }
  // a session on mainnet: a testnet trade is refused (and the other way round), never switched
  writeSession(session(56))
  r = await run(['buy', '--token', TOKEN, '--amount', '1', '--wallet', 'wc', '--testnet'])
  assert.equal(r.out.code, 'WC_WRONG_CHAIN')
  assert.match(r.out.error, /never switches/)
  writeSession(session(97))
  r = await run(['sell', '--token', TOKEN, '--all', '--wallet', 'wc'])
  assert.equal(r.out.code, 'WC_WRONG_CHAIN')
  writeSession(session(56, ME, { expiresAt: Date.now() - 1 }))
  r = await run(['sell', '--token', TOKEN, '--all', '--wallet', 'wc'])
  assert.equal(r.out.code, 'WC_NO_SESSION')
  assert.match(r.out.error, /expired/)
  // gang wallet status / disconnect from the files; execute of an unknown wc request, before any network
  writeSession(session(56))
  r = await run(['wallet', 'status'])
  assert.deepEqual([r.out.connected, r.out.address, r.out.chainId, r.out.network], [true, ME, 56, 'BSC'])
  r = await run(['execute', '--request-id', `wc-${'0'.repeat(24)}`])
  assert.equal(r.out.code, 'WC_NO_REQUEST')
  r = await run(['wallet', 'connect'])
  assert.equal(r.out.code, 'WC_CONNECTED')
  r = await run(['wallet', 'connect'], { GANG_WC_PROJECT_ID: '', GANG_WC_DIR: join(DIR, 'none') })
  assert.equal(r.out.code, 'WC_NO_PROJECT_ID')
  assert.match(r.out.error, /unavailable right now/)
  r = await run(['wallet', 'nope'])
  assert.equal(r.out.code, 'USAGE')
  r = await run(['wallet', 'disconnect'], { GANG_WC_PROJECT_ID: '' })
  assert.equal(r.out.disconnected, true)
  assert.equal((await run(['wallet', 'status'])).out.connected, false)

  console.log('walletconnect: ok')
} finally {
  rmSync(DIR, { recursive: true, force: true })
}
