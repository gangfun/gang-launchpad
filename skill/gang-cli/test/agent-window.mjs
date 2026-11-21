/**
 * The agent window (docs/SPEC-AGENT-WINDOW-2026-11-20.md) against a local fake BSC testnet node (no chain, no wallet):
 *   - --agent-window parsing and its bounds; refused with --fair / --fly and outside a create, before any RPC;
 *   - gang create --agent-window: createWithAgentWindow(minutes, createWithSalt(salt, <the curve create>)) with abcd on,
 *     around the entry itself with it off; the preview's agentWindow; refused on a pad without
 *     MAX_AGENT_WINDOW_MINUTES() before anything is uploaded; a create without it unchanged;
 *   - gang info / gang status: agentWindow (no window, before openAt, open; a pad without the window shows none);
 *   - gang buy / gang sell previews: a wallet without an Agent ID refused before openAt and served after it; an open
 *     token's buy names no 1% cap; a graduation reward's E-4 warning and only Agent ID buys counting once open.
 *
 *   node skill/gang-cli/test/agent-window.mjs
 */
import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { execFile, spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { decodeFunctionData, encodeFunctionResult, getAddress, maxUint256, parseAbi, toEventSignature, toFunctionSelector, zeroAddress } from 'viem'

process.env.GANG_TELEMETRY = '0'
const { runV3, V3_EVENT_ABIS, V3_NETS } = await import('../src/v3.js')
const { AGENT_WINDOW_ABI, formatLeft, parseAgentWindow, windowCreateView, wrapCreate } = await import('../src/agentwindow.js')
const { GRAD_PAD_ABI } = await import('../src/gradreward.js')
const { VANITY_ABI } = await import('../src/vanity.js')
const { BASE_PAD_ABI } = await import('../src/base.js')
const { PROMOTE_PAD_ABI } = await import('../src/promote.js')
const { CREATOR_FEE_ABI, GRAD_TARGET_ABI, gangGens } = await import('../src/gangpad.js')

const lc = (a) => String(a).toLowerCase()
const t = (n) => getAddress(`0x${n.toString(16).padStart(40, '0')}`)
const PAD = lc(gangGens(true)[0].pad)
const ME = t(0xd3f), PLAIN = t(0x0e1), VAN = t(0x7a17), HANDLER = t(0x4a4d), TOKEN = lc(t(0x70c))
const E18 = 10n ** 18n
const WBNB = lc(V3_NETS.testnet.wbnb)
const NOW = 2_000_000_000

// ---- parsing and words
assert.deepEqual(parseAgentWindow('1'), { minutes: 1 })
assert.deepEqual(parseAgentWindow('1440'), { minutes: 1440 })
assert.deepEqual(parseAgentWindow(' 90 '), { minutes: 90 })
for (const bad of ['0', '1441', '65535', '1.5', '60m', '1h', '-5', '', undefined, 'x']) assert.match(parseAgentWindow(bad).error ?? '', /1–1440/, `--agent-window ${bad}`)
assert.equal(formatLeft(0), '0s')
assert.equal(formatLeft(45), '45s')
assert.equal(formatLeft(200), '3m 20s')
assert.equal(formatLeft(3900), '1h 5m')
assert.equal(formatLeft(86_400 + 60), '1d 1m')
{
  const v = windowCreateView(90)
  assert.equal(v.minutes, 90)
  assert.match(v.openAt, /90 minutes \(1h 30m\) after the create block/)
  assert.match(v.untilOpen, /only Agent ID holders.*1% wallet cap/)
  assert.match(v.afterOpen, /any wallet.*contracts.*NO 1% wallet cap/)
  assert.match(v.warning, /IRREVERSIBLE.*nobody can change, extend or cancel/)
  assert.equal(v.gradReward, undefined)
  const g = windowCreateView(1, { gradReward: true, vault: true, promote: true })
  assert.match(g.openAt, /^1 minute after/)
  assert.match(g.gradReward, /one large buyer/)
  assert.match(g.vault, /can't lock/)
  assert.match(g.promote, /without binding/)
}
// gang tx decodes AgentWindowSet; the signatures are the contract's (src/gang/interfaces/IGangAgentWindow.sol)
assert.ok(V3_EVENT_ABIS.includes(AGENT_WINDOW_ABI))
assert.equal(toEventSignature(AGENT_WINDOW_ABI.find((x) => x.name === 'AgentWindowSet')), 'AgentWindowSet(address,uint40)')
for (const [fn, sig] of [['createWithAgentWindow', 'createWithAgentWindow(uint16,bytes)'], ['agentOpenAt', 'agentOpenAt(address)'],
  ['agentWindowOpen', 'agentWindowOpen(address)'], ['canTradeCurve', 'canTradeCurve(address,address)'], ['walletCapOn', 'walletCapOn(address)'],
  ['MIN_AGENT_WINDOW_MINUTES', 'MIN_AGENT_WINDOW_MINUTES()'], ['MAX_AGENT_WINDOW_MINUTES', 'MAX_AGENT_WINDOW_MINUTES()']]) {
  assert.equal(toFunctionSelector(AGENT_WINDOW_ABI.find((x) => x.name === fn)), toFunctionSelector(`function ${sig}`), fn)
}

// ---- refused before any RPC (a dead node: nothing is read)
const CLI = fileURLToPath(new URL('../src/index.js', import.meta.url))
const dead = (...a) => {
  const r = spawnSync(process.execPath, [CLI, ...a], { encoding: 'utf8', env: { ...process.env, GANG_TELEMETRY: '0', GANG_UPDATE_CHECK: '0', GANG_TESTNET_RPC_URL: 'http://127.0.0.1:1' } })
  try { return JSON.parse(r.stdout) } catch { return { raw: r.stdout + r.stderr } }
}
const refusedCli = (a, re) => {
  const o = dead(...a)
  assert.equal(o.success, false, `${a.join(' ')} → ${JSON.stringify(o).slice(0, 300)}`)
  assert.match(String(o.error), re, a.join(' '))
}
const base = ['create', '--name', 'W', '--symbol', 'W', '--from', ME, '--testnet', '--calldata']
refusedCli([...base, '--fair', '--agent-window', '30'], /leave --fair out/)
refusedCli(['fair', 'create', '--name', 'W', '--symbol', 'W', '--from', ME, '--testnet', '--agent-window', '30'], /leave --fair out/)
refusedCli([...base, '--fly', '--agent-window', '30'], /leave --fly out/)
refusedCli([...base, '--agent-window', '0'], /1–1440/)
refusedCli([...base, '--agent-window', '1441'], /1–1440/)
refusedCli([...base, '--agent-window', '2h'], /1–1440/)
refusedCli([...base, '--agent-windwo', '30'], /agent-window/)
refusedCli(['buy', '--token', ME, '--amount', '1', '--from', ME, '--testnet', '--agent-window', '30'], /only applies when creating a token/)

// ---- the fake node
const world = {
  vanity: true, hasWindow: true, calls: [], logo: 0,
  // the token: openAt 0 = none
  openAt: 0, gated: true, capOn: true, agents: new Set([lc(ME)]), wbnbBal: 10n * E18, allowance: 10n * E18, balance: 5n * E18,
  grad: false, windowRpcDown: false, values: [],
}
const ERC20 = parseAbi(['function symbol() view returns (string)', 'function decimals() view returns (uint8)',
  'function balanceOf(address) view returns (uint256)', 'function allowance(address,address) view returns (uint256)',
  'function kindOf(address token) view returns (uint8)', 'function implementation() view returns (address)',
  'function owedOf(address token) view returns (uint256)'])
const abi = [...V3_EVENT_ABIS[0], ...CREATOR_FEE_ABI, ...GRAD_TARGET_ABI, ...VANITY_ABI, ...GRAD_PAD_ABI, ...PROMOTE_PAD_ABI, ...AGENT_WINDOW_ABI, ...BASE_PAD_ABI, ...ERC20]
const functions = new Map()
for (const f of abi.filter((x) => x.type === 'function')) if (!functions.has(toFunctionSelector(f))) functions.set(toFunctionSelector(f), f)
const revert = { error: { code: 3, message: 'execution reverted', data: '0x' } }
const err = (sig) => ({ error: { code: 3, message: 'execution reverted', data: toFunctionSelector(sig) } })
const isOpen = () => world.openAt !== 0 && NOW >= world.openAt
const canTrade = (who) => !world.gated || isOpen() || world.agents.has(lc(who))
const gradView = () => ({
  state: world.grad ? 1 : 0, pot: E18 / 2n, minBuy: E18 / 100n, entries: 10, lastBps: 3000, carryBps: 0, refundAfter: 90 * 86_400,
  createdAt: NOW - 86_400, refundAt: 0, gradAt: 0, seq: 1n, countdown: zeroAddress, claimed: 0n, carryOwed: 0n, settled: false, valid: 0, validSpent: 0n, refundPending: false,
})
const CREATES = ['create', 'createWithGradTarget', 'createWithPromote', 'createWithVault', 'createWithGradReward', 'createWithBase']
const runCreate = (data, from, via) => {
  const f = functions.get(data.slice(0, 10))
  if (f?.name === 'createWithSalt') {
    const { args } = decodeFunctionData({ abi: [f], data })
    const inner = functions.get(args[1].slice(0, 10))
    world.calls.push({ via: [...via, 'createWithSalt'], fn: inner?.name })
    return t(0x1abcd)
  }
  if (!CREATES.includes(f?.name)) return null
  world.calls.push({ via, fn: f.name })
  if (world.vanity) return 'vanity'
  return t(0x2abcd)
}
const answer = (b) => {
  if (b.method === 'eth_chainId') return { result: '0x61' }
  if (b.method === 'eth_getCode') return { result: '0x' }
  if (b.method === 'eth_blockNumber') return { result: '0x100' }
  if (b.method === 'eth_getBalance') return { result: `0x${(10n * E18).toString(16)}` }
  if (b.method === 'eth_getBlockByNumber') {
    return { result: { number: '0x100', timestamp: `0x${NOW.toString(16)}`, hash: `0x${'11'.repeat(32)}`, parentHash: `0x${'22'.repeat(32)}`, transactions: [], baseFeePerGas: '0x0', gasLimit: '0x1', gasUsed: '0x0', difficulty: '0x0', logsBloom: `0x${'00'.repeat(256)}`, miner: zeroAddress, extraData: '0x', nonce: '0x0000000000000000', sha3Uncles: `0x${'00'.repeat(32)}`, size: '0x1', stateRoot: `0x${'00'.repeat(32)}`, receiptsRoot: `0x${'00'.repeat(32)}`, transactionsRoot: `0x${'00'.repeat(32)}`, uncles: [], totalDifficulty: '0x0' } }
  }
  assert.equal(b.method, 'eth_call', b.method)
  const { data, to, from } = b.params[0]
  const f = functions.get(data.slice(0, 10))
  if (!f) return revert
  const { args = [] } = decodeFunctionData({ abi: [f], data })
  const at = lc(to)
  let result
  const enc = () => ({ result: encodeFunctionResult({ abi: [f], functionName: f.name, result }) })
  if (at === WBNB) {
    if (f.name === 'balanceOf') result = world.wbnbBal
    else if (f.name === 'allowance') result = world.allowance
    else if (f.name === 'symbol') result = 'WBNB'
    else if (f.name === 'decimals') result = 18
    else return revert
    return enc()
  }
  if (at === TOKEN) {
    if (f.name === 'balanceOf') result = world.balance
    else if (f.name === 'allowance') result = maxUint256
    else if (f.name === 'symbol') result = 'WIN'
    else if (f.name === 'decimals') result = 18
    else return revert
    return enc()
  }
  if (at === lc(HANDLER) && f.name === 'owedOf') { result = 0n; return enc() }
  if (at !== PAD && f.name === 'kindOf') { result = 0; return enc() }
  if (at !== PAD && f.name === 'implementation') { result = t(0x1111); return enc() }
  if (at !== PAD && f.name !== 'tokenInitCodeHash') return revert
  const window = ['agentOpenAt', 'agentWindowOpen', 'canTradeCurve', 'walletCapOn', 'MIN_AGENT_WINDOW_MINUTES', 'MAX_AGENT_WINDOW_MINUTES', 'createWithAgentWindow']
  if (window.includes(f.name) && !world.hasWindow) return revert
  // a node failing on the window's reads (not a missing function): -32603
  if (window.includes(f.name) && world.windowRpcDown) return { error: { code: -32603, message: 'internal error' } }
  switch (f.name) {
    case 'MIN_AGENT_WINDOW_MINUTES': result = 1; break
    case 'MAX_AGENT_WINDOW_MINUTES': result = 1440; break
    case 'agentOpenAt': result = lc(args[0]) === TOKEN ? world.openAt : 0; break
    case 'agentWindowOpen': result = lc(args[0]) === TOKEN && isOpen(); break
    case 'walletCapOn': result = world.capOn && !(lc(args[0]) === TOKEN && isOpen()); break
    case 'canTradeCurve': result = canTrade(args[1]); break
    case 'createWithAgentWindow': {
      if (args[0] < 1 || args[0] > 1440) return err('BadAgentWindow()')
      const made = runCreate(args[1], from, ['createWithAgentWindow'])
      if (made === null) return err('BadAgentWindowCall()')
      if (made === 'vanity') return err('VanityContextRequired()')
      world.calls.at(-1).minutes = args[0]
      world.values.push(BigInt(b.params[0].value ?? 0))
      result = made
      break
    }
    case 'previewBaseCost': result = 149n * E18 / 1000n; break
    case 'baseDeps': case 'baseVaultImpl': result = t(0xba5e); break
    case 'createWithSalt': case 'create': case 'createWithGradTarget': {
      const made = runCreate(data, from, [])
      if (made === 'vanity') return err('VanityContextRequired()')
      result = made
      break
    }
    case 'kindOf': result = lc(args[0]) === TOKEN ? 1 : 0; break
    case 'vanityDeployer': result = world.vanity ? VAN : zeroAddress; break
    case 'taxHandler': case 'router': case 'recipientRegistry': case 'implementation': result = HANDLER; break
    case 'agentGateEnabled': result = world.gated; break
    case 'isAgent': result = world.agents.has(lc(args[0])); break
    case 'walletRoom': result = world.capOn && !isOpen() ? 10_000_000n * E18 : maxUint256; break
    case 'curves': result = [ME, WBNB, E18, 50_000_000n * E18, 6n * E18, 3n * E18, false, 0, 0, 0, zeroAddress, zeroAddress]; break
    case 'graduationRemaining': result = 5n * E18; break
    case 'taxConfigOf': result = [0, 0, 0, zeroAddress]; break
    case 'gradTargetOf': result = 6n * E18; break
    case 'gradReward': result = lc(args[0]) === TOKEN ? gradView() : { ...gradView(), state: 0 }; break
    case 'gradEntries': result = [[], [], [], []]; break
    case 'promoteOf': result = [0, 0]; break
    case 'bindingOf': result = [zeroAddress, 0, false]; break
    case 'buy': if (!canTrade(from)) return err('NotAgent()'); result = 1_000_000n * E18; break
    case 'sell': if (!canTrade(from)) return err('NotAgent()'); result = E18 / 100n; break
    case 'checkTaxConfigFor': case 'checkTaxConfig': result = [true, '']; break
    case 'GRAD_BNB_TIERS': result = [6n, 9n, 12n, 15n].map((x) => x * E18); break
    case 'TARGET_GRAD_BNB': case 'graduationAmountOf': result = 9n * E18; break
    case 'graduationAmountFor': result = args[2]; break
    case 'PROTOCOL_FEE_BPS': result = 100n; break
    case 'PLATFORM_TAX_BPS': result = 50n; break
    case 'CREATOR_FEE_SHARE_BPS': result = 7000n; break
    case 'creatorFeeOf': result = 0n; break
    case 'tokenVersionOf': result = 1; break
    case 'dividendVault': result = t(0xd17); break
    case 'tokenInitCodeHash': result = `0x${'ab'.repeat(32)}`; break
    default: return revert
  }
  return enc()
}
const server = createServer((req, res) => {
  let body = ''
  req.on('data', (c) => (body += c))
  req.on('end', () => {
    const input = JSON.parse(body)
    const one = (b) => ({ jsonrpc: '2.0', id: b.id, ...answer(b) })
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify(Array.isArray(input) ? input.map(one) : one(input)))
  })
})
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
const rpc = `http://127.0.0.1:${server.address().port}`
process.env.GANG_TESTNET_RPC_URL = rpc
V3_NETS.testnet.rpcs = [rpc]

class Failed extends Error {}
const io = (flags) => ({
  opt: (key, fallback) => flags[key] ?? fallback,
  flag: (key) => Object.hasOwn(flags, key),
  out: (x) => x,
  fail: (error, details) => { throw new Failed(`${error} ${JSON.stringify(details ?? {})}`) },
  summarize: () => assert.fail('raw calldata needs no wallet preview'),
  checkMeta: () => {},
  resolveLogo: async () => { world.logo++; return { logoURI: 'ipfs://logo' } },
  resolveMeta: async () => ({ metaURI: 'ipfs://meta', metadata: { name: 'Win' } }),
  notes: {
    step: (_ctx, tx, extra) => ({ success: true, ...extra, tx: { ...tx, value: String(tx.value ?? 0n) } }),
    skipped: () => ({}), follow: async () => null, priced: async () => null, following: false, pool: {},
  },
})
const create = (extra) => runV3('create', io({ name: 'Win', symbol: 'WIN', from: ME, testnet: true, calldata: true, ...extra }))
const run = (sub, extra) => runV3(sub, io({ token: TOKEN, testnet: true, calldata: true, ...extra }))
const refused = async (promise, re) => {
  await assert.rejects(promise, (e) => e instanceof Failed && re.test(e.message), String(re))
}

try {
  // ---- create: abcd on → createWithAgentWindow(60, createWithSalt(salt, createWithGradTarget(…)))
  world.calls = []
  let r = await create({ grad: '6', 'agent-window': '60' })
  assert.equal(r.success, true, JSON.stringify(r))
  assert.equal(r.step, 'create')
  let outer = decodeFunctionData({ abi: AGENT_WINDOW_ABI, data: r.tx.data })
  assert.equal(outer.functionName, 'createWithAgentWindow')
  assert.equal(outer.args[0], 60)
  const salted = decodeFunctionData({ abi: VANITY_ABI, data: outer.args[1] })
  assert.equal(salted.functionName, 'createWithSalt')
  const entry = decodeFunctionData({ abi: V3_EVENT_ABIS[0], data: salted.args[1] })
  assert.equal(entry.functionName, 'createWithGradTarget')
  assert.equal(entry.args[0], 'Win')
  assert.equal(entry.args[3], 'ipfs://meta')
  assert.equal(r.tx.to.toLowerCase(), PAD)
  assert.equal(r.tx.value, '0')
  assert.equal(r.addressSuffix, 'abcd')
  // the dry run went through the same wrapper (the pad's own checks ran inside it)
  assert.deepEqual(world.calls.map((c) => [c.via.join('>'), c.fn, c.minutes]), [['createWithAgentWindow>createWithSalt', 'createWithGradTarget', 60]])
  assert.equal(r.agentWindow.minutes, 60)
  assert.match(r.agentWindow.untilOpen, /only Agent ID holders/)
  assert.match(r.agentWindow.afterOpen, /contracts.*NO 1% wallet cap/)
  assert.match(r.agentWindow.warning, /IRREVERSIBLE/)
  assert.match(r.note, /Agent window: 60 min/)

  // abcd off: the entry itself inside the wrapper
  world.vanity = false; world.calls = []
  r = await create({ 'agent-window': '1440' })
  assert.equal(r.success, true, JSON.stringify(r))
  outer = decodeFunctionData({ abi: AGENT_WINDOW_ABI, data: r.tx.data })
  assert.equal(outer.args[0], 1440)
  assert.equal(decodeFunctionData({ abi: V3_EVENT_ABIS[0], data: outer.args[1] }).functionName, 'create')
  assert.equal(r.tokenIfNext, t(0x2abcd))
  world.vanity = true

  // without --agent-window: the create is as before, no wrapper, no agentWindow
  world.calls = []
  r = await create({ grad: '6' })
  assert.equal(decodeFunctionData({ abi: VANITY_ABI, data: r.tx.data }).functionName, 'createWithSalt')
  assert.equal(r.agentWindow, undefined)
  assert.doesNotMatch(r.note, /Agent window/)
  assert.deepEqual(world.calls.map((c) => c.via.join('>')), ['createWithSalt'])
  assert.equal(wrapCreate(5, r.tx.data).slice(0, 10), toFunctionSelector('function createWithAgentWindow(uint16,bytes)'))

  // --base: the BNB the create takes rides on the wrapper (payable), in the dry run and in the tx
  world.calls = []; world.values = []
  r = await create({ base: '5', 'base-vest': '30', 'agent-window': '15' })
  if (r.success) {
    outer = decodeFunctionData({ abi: AGENT_WINDOW_ABI, data: r.tx.data })
    assert.equal(outer.args[0], 15)
    assert.equal(decodeFunctionData({ abi: BASE_PAD_ABI, data: decodeFunctionData({ abi: VANITY_ABI, data: outer.args[1] }).args[1] }).functionName, 'createWithBase')
    assert.equal(r.tx.value, String(149n * E18 / 1000n))
    assert.deepEqual(world.values, [149n * E18 / 1000n], 'the dry run sent the base cost through the wrapper')
  } else assert.fail(`--base --agent-window: ${JSON.stringify(r)}`)

  // a pad not upgraded for it (mainnet before its upgrade): refused, nothing simulated or uploaded
  world.hasWindow = false; world.calls = []; world.logo = 0
  await refused(create({ 'agent-window': '60' }), /no agent window yet.*drop --agent-window/)
  assert.equal(world.calls.length, 0)
  assert.equal(world.logo, 0)
  // a launch in one command asks the pad before any module clone or upload (launch.js)
  {
    const cli = (...a) => new Promise((resolve) => execFile(process.execPath, [CLI, ...a], { env: { ...process.env, GANG_TELEMETRY: '0', GANG_UPDATE_CHECK: '0', GANG_TESTNET_RPC_URL: rpc, HOME: '/nonexistent-gang-test-home' } }, (_e, stdout) => resolve(JSON.parse(stdout))))
    const o = await cli('create', '--name', 'Win', '--symbol', 'WIN', '--from', ME, '--testnet', '--calldata', '--dev-buy', '0.01', '--agent-window', '30')
    assert.equal(o.success, false, JSON.stringify(o))
    assert.match(o.error, /no agent window yet.*drop --agent-window/)
    assert.equal(world.calls.length, 0)
  }
  world.hasWindow = true
  await refused(create({ 'agent-window': '0' }), /1–1440/)
  // a revert inside the wrapper comes back as the pad's error
  world.agents.delete(lc(ME))
  await refused(create({ 'agent-window': '60' }), /no Agent ID; V3 create is Agent-only/)
  world.agents.add(lc(ME))

  // ---- gang info: a pad without the window shows nothing; no window; before openAt; open
  world.hasWindow = false
  r = await run('info', {})
  assert.equal(r.success, true, JSON.stringify(r))
  assert.equal(r.agentWindow, undefined)
  world.hasWindow = true
  r = await run('info', {})
  assert.equal(r.agentWindow.set, false)
  assert.match(r.agentWindow.note, /only Agent ID holders.*for good/)
  world.openAt = NOW + 600
  r = await run('info', {})
  assert.equal(r.agentWindow.set, true)
  assert.equal(r.agentWindow.open, false)
  assert.equal(r.agentWindow.opensIn, '10m')
  assert.equal(r.agentWindow.secondsLeft, 600)
  assert.equal(r.agentWindow.walletCap, true)
  assert.equal(r.agentWindow.openAt, new Date((NOW + 600) * 1000).toISOString())
  assert.match(r.agentWindow.status, /agent only for 10m more/)
  assert.match(r.agentWindow.rule, /nobody .* can change, extend or cancel/)
  assert.equal(r.agentWindow.raw, undefined)
  world.openAt = NOW - 60
  r = await run('info', {})
  assert.equal(r.agentWindow.open, true)
  assert.equal(r.agentWindow.opensIn, undefined)
  assert.equal(r.agentWindow.walletCap, false)
  assert.match(r.agentWindow.status, /open to every wallet.*no 1% wallet cap/)
  assert.equal(r.agentWindow.gradReward, undefined)
  world.grad = true
  r = await run('info', {})
  assert.match(r.agentWindow.gradReward, /one large buyer/)
  world.grad = false

  // ---- gang status: whether this wallet may trade the curve now
  world.openAt = NOW + 600
  r = await run('status', { from: PLAIN })
  assert.equal(r.agentWindow.youCanTrade, false)
  r = await run('status', { from: ME })
  assert.equal(r.agentWindow.youCanTrade, true)
  world.openAt = NOW - 60
  r = await run('status', { from: PLAIN })
  assert.equal(r.agentWindow.youCanTrade, true)
  assert.equal(r.agentWindow.walletCap, false)

  // ---- gang buy: no Agent ID before openAt → refused with when it opens; after → a plain buy with no cap
  world.openAt = NOW + 600
  await refused(run('buy', { from: PLAIN, amount: '0.1', 'use-wbnb': true }), /agent only until .*10m from now.*any wallet can buy/)
  r = await run('buy', { from: ME, amount: '0.1', 'use-wbnb': true })
  assert.equal(r.success, true, JSON.stringify(r))
  assert.equal(r.agentWindow.open, false)
  assert.equal(r.agentWindow.walletCap, true)
  assert.match(r.note, /at the 1% wallet cap the excess is refunded/)
  world.openAt = NOW - 60
  r = await run('buy', { from: PLAIN, amount: '0.1', 'use-wbnb': true })
  assert.equal(r.success, true, JSON.stringify(r))
  assert.equal(decodeFunctionData({ abi: V3_EVENT_ABIS[0], data: r.tx.data }).functionName, 'buy')
  assert.equal(r.agentWindow.open, true)
  assert.equal(r.agentWindow.walletCap, false)
  assert.match(r.agentWindow.note, /no 1% wallet cap/)
  assert.match(r.note, /no 1% wallet cap on this open token/)
  assert.doesNotMatch(r.note, /at the 1% wallet cap/)
  assert.notEqual(r.cutBy, 'wallet cap')
  // a token with no window: as before (no Agent ID → refused; no agentWindow in the preview)
  world.openAt = 0
  await refused(run('buy', { from: PLAIN, amount: '0.1', 'use-wbnb': true }), /no Agent ID; curve trades are Agent-only/)
  r = await run('buy', { from: ME, amount: '0.1', 'use-wbnb': true })
  assert.equal(r.agentWindow, undefined)

  // graduation reward on an open token: E-4 warned; a wallet without an Agent ID does not count
  world.grad = true; world.openAt = NOW - 60
  r = await run('buy', { from: PLAIN, amount: '0.1', 'use-wbnb': true })
  assert.equal(r.rewards.gradReward.counts, false)
  assert.match(r.rewards.gradReward.why, /only Agent ID wallets' buys count/)
  assert.match(r.rewards.gradReward.openWarning, /one large buyer/)
  r = await run('buy', { from: ME, amount: '0.1', 'use-wbnb': true })
  assert.equal(r.rewards.gradReward.counts, true)
  assert.match(r.rewards.gradReward.openWarning, /one large buyer/)
  // in the window: warned about what opening means
  world.openAt = NOW + 600
  r = await run('buy', { from: ME, amount: '0.1', 'use-wbnb': true })
  assert.match(r.rewards.gradReward.openWarning, /after this token opens/)
  world.grad = false

  // a node failing on the window reads: info says it could not read it; a buy falls back to the pad's isAgent
  world.windowRpcDown = true; world.openAt = NOW - 60
  r = await run('info', {})
  assert.match(r.agentWindow.error, /could not read the token's agent window/)
  r = await run('buy', { from: ME, amount: '0.1', 'use-wbnb': true })
  assert.equal(r.success, true, JSON.stringify(r))
  assert.equal(r.agentWindow, undefined)
  await refused(run('buy', { from: PLAIN, amount: '0.1', 'use-wbnb': true }), /no Agent ID/)
  world.windowRpcDown = false

  // ---- gang sell: the same rule (--break-bond / --break-call-bond: this fake node has no GangBond / GangCallBond to read)
  world.openAt = NOW + 600
  await refused(run('sell', { from: PLAIN, all: true, 'break-bond': true, 'break-call-bond': true }), /agent only until .*any wallet can sell/)
  r = await run('sell', { from: ME, all: true, 'break-bond': true, 'break-call-bond': true })
  assert.equal(r.success, true, JSON.stringify(r))
  assert.equal(r.agentWindow.open, false)
  world.openAt = NOW - 60
  r = await run('sell', { from: PLAIN, all: true, 'break-bond': true, 'break-call-bond': true })
  assert.equal(r.success, true, JSON.stringify(r))
  assert.equal(decodeFunctionData({ abi: V3_EVENT_ABIS[0], data: r.tx.data }).functionName, 'sell')
  assert.deepEqual([r.agentWindow.open, r.agentWindow.walletCap], [true, false])
  world.openAt = 0
  r = await run('sell', { from: ME, all: true, 'break-bond': true, 'break-call-bond': true })
  assert.equal(r.agentWindow, undefined)
} finally {
  server.close()
}
console.log('agent window: ok')
