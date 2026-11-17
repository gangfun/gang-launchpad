/**
 * The graduation reward (冲毕业奖励, docs/SPEC-GRAD-REWARD-2026-11-17.md §13) against a local fake BSC testnet node (no
 * chain, no wallet):
 *   - --grad-reward / --gr-* parsing and its bounds;
 *   - gang create --grad-reward: the seed approved first (a wrap / approve step), then createWithSalt carrying
 *     createWithGradReward with the config (the minimum buy's default and the seed's floor at the token's own rate,
 *     the promoter share riding in the same call); refused on a pad without it, with it closed, and with the flags it
 *     does not take;
 *   - the buy / sell previews' rewards.gradReward (counts or not, entries a sell takes out);
 *   - gang grad-reward status / claim / refund-request / refund and their refusals.
 *
 *   node skill/gang-cli/test/gradreward.mjs
 */
import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { decodeFunctionData, encodeFunctionResult, getAddress, parseAbi, toFunctionSelector, zeroAddress } from 'viem'

process.env.GANG_TELEMETRY = '0'
const { runV3, V3_EVENT_ABIS, V3_NETS } = await import('../src/v3.js')
const { GRAD_PAD_ABI, gradBuyLine, gradSellLine, parseGradReward, runGradReward } = await import('../src/gradreward.js')
const { VANITY_ABI } = await import('../src/vanity.js')
const { PROMOTE_PAD_ABI } = await import('../src/promote.js')
const { CREATOR_FEE_ABI, GRAD_TARGET_ABI, gangGens, PAD3_GEN } = await import('../src/gangpad.js')

const lc = (a) => String(a).toLowerCase()
const t = (n) => getAddress(`0x${n.toString(16).padStart(40, '0')}`)
const PAD = lc(gangGens(true)[0].pad)
const ME = t(0xd3f), OTHER = t(0x0e1), VAN = t(0x7a17), HANDLER = t(0x4a4d), TOKEN = lc(t(0x70c))
const E18 = 10n ** 18n
const WBNB = lc(V3_NETS.testnet.wbnb)
const Q6 = lc(t(0x6666))

// ---- parsing
const p = (flags) => parseGradReward((k) => flags[k], (k) => Object.hasOwn(flags, k))
assert.deepEqual(p({ 'grad-reward': '0.5' }), { seed: '0.5', minBuy: null, entries: 10, lastBps: 3000, refundDays: 90 })
assert.deepEqual(p({ 'grad-reward': '1', 'gr-min-buy': '0.02', 'gr-entries': '20', 'gr-last': '0', 'gr-refund-days': '30' }),
  { seed: '1', minBuy: '0.02', entries: 20, lastBps: 0, refundDays: 30 })
assert.match(p({ 'grad-reward': '0' }).error, /positive amount/)
assert.match(p({ 'grad-reward': 'x' }).error, /needs the seed/)
assert.match(p({ 'grad-reward': '1', 'gr-entries': '21' }).error, /between 1 and 20/)
assert.match(p({ 'grad-reward': '1', 'gr-last': '51' }).error, /between 0 and 50/)
assert.match(p({ 'grad-reward': '1', 'gr-refund-days': '29' }).error, /between 30 and 180/)
assert.match(p({ 'grad-reward': '1', 'gr-min-buy': '-1' }).error, /--gr-min-buy/)

// ---- the fake node
const world = {
  vanity: true, open: true, hasGrad: true, wbnbBal: 10n * E18, allowance: 10n * E18, calls: [], gated: true,
  // the token's reward
  state: 1, pot: E18 / 2n, minBuy: E18 / 100n, seq: 3n, refundAt: 0n, refundPending: false, createdAt: 2_000_000_000n - 10n * 86_400n, refundAfter: 90n * 86_400n,
  gradAt: 0n, claimable: 0n, now: 2_000_000_000n,
  list: { buyers: [ME, OTHER, ME], seqs: [3n, 2n, 1n], spent: [E18 / 50n, E18 / 20n, E18 / 50n], valid: [true, true, false] },
}
const ERC20 = parseAbi(['function symbol() view returns (string)', 'function decimals() view returns (uint8)',
  'function balanceOf(address) view returns (uint256)', 'function allowance(address,address) view returns (uint256)',
  'function kindOf(address token) view returns (uint8)', 'function implementation() view returns (address)'])
const abi = [...V3_EVENT_ABIS[0], ...CREATOR_FEE_ABI, ...GRAD_TARGET_ABI, ...VANITY_ABI, ...GRAD_PAD_ABI, ...PROMOTE_PAD_ABI, ...ERC20]
const functions = new Map()
for (const f of abi.filter((x) => x.type === 'function')) functions.set(toFunctionSelector(f), f)
const revert = { error: { code: 3, message: 'execution reverted', data: '0x' } }
const err = (sig) => ({ error: { code: 3, message: 'execution reverted', data: toFunctionSelector(sig) } })

const view = () => ({
  state: world.state, pot: world.pot, minBuy: world.minBuy, entries: 10, lastBps: 3000, carryBps: 0, refundAfter: Number(world.refundAfter),
  createdAt: Number(world.createdAt), refundAt: Number(world.refundAt), gradAt: Number(world.gradAt), seq: world.seq, countdown: zeroAddress,
  claimed: 0n, carryOwed: world.carryOwed ?? 0n, settled: world.settled ?? false, valid: 0, validSpent: 0n, refundPending: world.refundPending,
})
const answer = (b) => {
  if (b.method === 'eth_chainId') return { result: '0x61' }
  if (b.method === 'eth_getCode') return { result: '0x' }
  if (b.method === 'eth_blockNumber') return { result: '0x100' }
  if (b.method === 'eth_getBalance') return { result: `0x${(10n * E18).toString(16)}` }
  if (b.method === 'eth_getBlockByNumber') {
    return { result: { number: '0x100', timestamp: `0x${world.now.toString(16)}`, hash: `0x${'11'.repeat(32)}`, parentHash: `0x${'22'.repeat(32)}`, transactions: [], baseFeePerGas: '0x0', gasLimit: '0x1', gasUsed: '0x0', difficulty: '0x0', logsBloom: `0x${'00'.repeat(256)}`, miner: zeroAddress, extraData: '0x', nonce: '0x0000000000000000', sha3Uncles: `0x${'00'.repeat(32)}`, size: '0x1', stateRoot: `0x${'00'.repeat(32)}`, receiptsRoot: `0x${'00'.repeat(32)}`, transactionsRoot: `0x${'00'.repeat(32)}`, uncles: [], totalDifficulty: '0x0' } }
  }
  assert.equal(b.method, 'eth_call')
  const { data, to, from } = b.params[0]
  const f = functions.get(data.slice(0, 10))
  if (!f) return revert
  const { args = [] } = decodeFunctionData({ abi: [f], data })
  const at = lc(to)
  let result
  if (at === WBNB) {
    if (f.name === 'balanceOf') result = world.wbnbBal
    else if (f.name === 'allowance') result = world.allowance
    else if (f.name === 'symbol') result = 'WBNB'
    else if (f.name === 'decimals') result = 18
    else return revert
    return { result: encodeFunctionResult({ abi: [f], functionName: f.name, result }) }
  }
  if (at === Q6) {
    if (f.name === 'balanceOf' || f.name === 'allowance') result = 10n ** 12n
    else if (f.name === 'symbol') result = 'USD6'
    else if (f.name === 'decimals') result = 6
    else return revert
    return { result: encodeFunctionResult({ abi: [f], functionName: f.name, result }) }
  }
  if (at !== PAD && f.name === 'kindOf') return { result: encodeFunctionResult({ abi: [f], functionName: f.name, result: 0 }) }
  if (at !== PAD && f.name !== 'tokenInitCodeHash') return revert
  switch (f.name) {
    case 'kindOf': result = lc(args[0]) === TOKEN ? 1 : 0; break
    case 'vanityDeployer': result = world.vanity ? VAN : zeroAddress; break
    case 'taxHandler': case 'router': case 'recipientRegistry': case 'implementation': result = HANDLER; break
    case 'gradRewardDeps': if (!world.hasGrad) return revert; result = [world.open, t(0xad), zeroAddress]; break
    case 'agentGateEnabled': result = world.gated; break
    case 'gradReward': if (!world.hasGrad) return revert; result = lc(args[0]) === TOKEN ? view() : { ...view(), state: 0 }; break
    case 'gradEntries': result = [world.list.buyers, world.list.seqs, world.list.spent, world.list.valid]; break
    case 'gradClaimable': result = world.state === 2 && lc(args[1]) === lc(ME) ? world.claimable : 0n; break
    case 'curves': result = [ME, WBNB, 0n, 0n, 9n * E18, 3n * E18, world.state !== 1, 0, 0, 0, zeroAddress, zeroAddress]; break
    case 'claimGradReward': if (world.state !== 2) return err('NotGradState()'); result = world.claimable; break
    case 'requestGradRefund': if (lc(from) !== lc(ME)) return err('NotCreator()'); result = undefined; break
    case 'gradRefund': result = world.pot; break
    case 'sweepGradReward': case 'settleGradReward': case 'cancelGradRefund': case 'retryCarry': result = undefined; break
    case 'createWithSalt': {
      const inner = decodeFunctionData({ abi: GRAD_PAD_ABI, data: args[1] })
      world.calls.push({ via: 'createWithSalt', fn: inner.functionName, args: inner.args })
      if (world.allowance < inner.args[8].seed) return { error: { code: 3, message: 'execution reverted: allowance', data: '0x' } }
      result = t(0x1abcd)
      break
    }
    case 'createWithGradReward': {
      world.calls.push({ via: 'direct', fn: f.name, args })
      if (world.vanity) return err('VanityContextRequired()')
      result = t(0x2abcd)
      break
    }
    case 'create': case 'createWithGradTarget': case 'createWithPromote': assert.fail('a --grad-reward create must go through createWithGradReward'); break
    case 'checkTaxConfigFor': case 'checkTaxConfig': result = [true, '']; break
    case 'isAgent': result = true; break
    case 'promoteOf': result = [0, 0]; break
    case 'GRAD_BNB_TIERS': result = [6n, 9n, 12n, 15n].map((x) => x * E18); break
    case 'TARGET_GRAD_BNB': case 'graduationAmountOf': result = 9n * E18; break
    case 'graduationAmountFor': result = lc(args[0]) === Q6 ? (args[2] * 10n ** 6n) / E18 : args[2]; break
    case 'PROTOCOL_FEE_BPS': result = 100n; break
    case 'PLATFORM_TAX_BPS': result = 50n; break
    case 'CREATOR_FEE_SHARE_BPS': result = 7000n; break
    case 'tokenInitCodeHash': result = `0x${'ab'.repeat(32)}`; break
    default: return revert
  }
  return { result: encodeFunctionResult({ abi: [f], functionName: f.name, result }) }
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
  resolveLogo: async () => ({ logoURI: 'ipfs://logo' }),
  resolveMeta: async () => ({ metaURI: 'ipfs://meta', metadata: { name: 'Grad' } }),
  notes: { step: (_ctx, tx, extra) => ({ success: true, ...extra, tx: { ...tx, value: String(tx.value ?? 0n) } }), skipped: () => ({}) },
})
const create = (extra) => runV3('create', io({ name: 'Grad', symbol: 'GRAD', from: ME, testnet: true, calldata: true, 'grad-reward': '0.5', ...extra }))
const refused = async (promise, re) => {
  await assert.rejects(promise, (e) => e instanceof Failed && re.test(e.message), String(re))
}

try {
  // the seed is pulled in the create: not enough WBNB → a wrap step; not approved → an approve step
  world.wbnbBal = 0n
  let r = await create({})
  assert.equal(r.step, 'wrap-bnb', JSON.stringify(r))
  assert.match(r.why, /pulls the 0\.5 WBNB reward pool/)
  world.wbnbBal = 10n * E18; world.allowance = 0n
  r = await create({})
  assert.equal(r.step, 'approve-quote', JSON.stringify(r))
  assert.equal(r.approve, '0.5')
  world.allowance = 10n * E18

  // abcd on: createWithSalt(salt, createWithGradReward(…, cfg)); defaults: 10 entries, 30%, 90 days, 0.01 BNB minimum
  world.calls = []
  r = await create({ grad: '6' })
  assert.equal(r.success, true, JSON.stringify(r))
  assert.equal(r.tx.value, '0')
  const outer = decodeFunctionData({ abi: VANITY_ABI, data: r.tx.data })
  assert.equal(outer.functionName, 'createWithSalt')
  const inner = decodeFunctionData({ abi: GRAD_PAD_ABI, data: outer.args[1] })
  assert.equal(inner.functionName, 'createWithGradReward')
  assert.equal(inner.args[7], 6n * E18)
  assert.deepEqual(inner.args[8], {
    seed: E18 / 2n, minBuy: E18 / 100n, entries: 10, lastBps: 3000, carryBps: 0, refundAfter: 90 * 86_400, promoteBps: 0, promoteWindow: 0,
  })
  assert.equal(r.gradReward.pool, '0.5 WBNB')
  assert.equal(r.gradReward.minBuy, '0.01 WBNB')
  assert.match(r.gradReward.split, /30% of the pool on top.*by what each spent/)
  assert.match(r.gradReward.refund, /90 days after the create.*7 days.*3 days/)
  assert.match(r.gradReward.notABet, /no randomness, no draw/)
  assert.match(r.gradReward.warning, /PERMANENT/)
  assert.match(r.gradReward.who, /it is on now/)
  assert.equal(r.addressSuffix, 'abcd')

  // the options and an untaxed --promote ride in the same create
  r = await create({ 'gr-min-buy': '0.05', 'gr-entries': '5', 'gr-last': '0', 'gr-refund-days': '30', promote: '20', 'promote-days': '30' })
  assert.equal(r.success, true, JSON.stringify(r))
  const cfg = decodeFunctionData({ abi: GRAD_PAD_ABI, data: decodeFunctionData({ abi: VANITY_ABI, data: r.tx.data }).args[1] }).args[8]
  assert.deepEqual(cfg, { seed: E18 / 2n, minBuy: E18 / 20n, entries: 5, lastBps: 0, carryBps: 0, refundAfter: 30 * 86_400, promoteBps: 2000, promoteWindow: 30 * 86_400 })
  assert.match(r.gradReward.split, /split the pool by what each spent/)

  // abcd off: createWithGradReward directly
  world.vanity = false; world.calls = []
  r = await create({})
  assert.equal(r.success, true, JSON.stringify(r))
  assert.equal(decodeFunctionData({ abi: GRAD_PAD_ABI, data: r.tx.data }).functionName, 'createWithGradReward')
  world.vanity = true

  // refusals before anything is built
  await refused(create({ 'grad-reward': '0.05' }), /at least 0\.1 WBNB/)
  await refused(create({ base: '5', 'base-vest': '30' }), /--grad-reward and --base/)
  await refused(create({ vault: t(0x7a) }), /--grad-reward and --vault/)
  await refused(create({ 'gr-entries': '0' }), /between 1 and 20/)
  await refused(runV3('create', io({ name: 'G', symbol: 'G', from: ME, testnet: true, calldata: true, 'gr-entries': '5' })), /goes with --grad-reward/)
  world.hasGrad = false; world.calls = []
  await refused(create({}), /no graduation reward yet/)
  assert.equal(world.calls.length, 0)
  world.hasGrad = true; world.open = false
  await refused(create({}), /closed/)
  world.open = true

  // ---- previews: rewards.gradReward
  const ctx = {
    gen: PAD3_GEN, pad: PAD, chainId: '97', client: { getBlock: async () => ({ timestamp: world.now }) },
    read: async (address, abi_, functionName, args = []) => {
      const f = abi_.find((x) => x.name === functionName)
      const res = answer({ method: 'eth_call', params: [{ to: address, data: (await import('viem')).encodeFunctionData({ abi: [f], functionName, args }) }] })
      if (res.error) throw new Error('reverted')
      return (await import('viem')).decodeFunctionResult({ abi: [f], functionName, data: res.result })
    },
  }
  let line = await gradBuyLine(ctx, TOKEN, WBNB, 'WBNB', ME, E18 / 50n, false)
  assert.equal(line.counts, true)
  assert.equal(line.pool, '0.5 WBNB')
  line = await gradBuyLine(ctx, TOKEN, WBNB, 'WBNB', ME, E18 / 1000n, false)
  assert.equal(line.counts, false)
  assert.match(line.why, /less than the 0\.01 WBNB minimum/)
  line = await gradBuyLine(ctx, TOKEN, WBNB, 'WBNB', ME, E18 / 1000n, true)
  assert.equal(line.counts, true, 'the graduating buy always counts')
  world.gated = false
  line = await gradBuyLine(ctx, TOKEN, WBNB, 'WBNB', ME, E18, false)
  assert.equal(line.counts, false)
  assert.match(line.why, /gate is off/)
  world.gated = true
  const sell = await gradSellLine(ctx, TOKEN, WBNB, 'WBNB', ME)
  assert.match(sell.warning, /pool 0\.5 WBNB/)
  assert.equal(sell.entriesLost, 1, 'only ME\'s valid entry (seq 3)')
  assert.equal(await gradSellLine(ctx, TOKEN, WBNB, 'WBNB', t(0x5ee)), null)

  // ---- gang grad-reward
  const gr = (sub, extra = {}) => runGradReward(sub, io({ token: TOKEN, testnet: true, calldata: true, from: ME, ...extra }))
  let s = await gr('status')
  assert.equal(s.success, true, JSON.stringify(s))
  assert.equal(s.state, 'on the curve')
  assert.equal(s.pool, '0.5')
  assert.equal(s.list.length, 3)
  assert.equal(s.list[0].you, true)
  assert.equal(s.list[2].valid, false)
  assert.match(s.notABet, /no draw/)
  await refused(gr('claim'), /not in the state/)
  await refused(gr('refund-request'), /too early/)
  await refused(gr('refund'), /no running refund request/)
  await refused(gr('refund-request', { from: OTHER }), /only the token's creator/)
  // after refundAfter: the request is built
  world.createdAt = world.now - 91n * 86_400n
  let w = await gr('refund-request')
  assert.equal(w.success, true, JSON.stringify(w))
  assert.equal(decodeFunctionData({ abi: GRAD_PAD_ABI, data: w.tx.data }).functionName, 'requestGradRefund')
  assert.match(w.note, /7-day notice/)
  // a running request: shown, refund refused until the notice is over, then built
  world.refundAt = world.now - 3n * 86_400n; world.refundPending = true
  s = await gr('status')
  assert.match(s.refund.note, /graduates before the creator takes it/)
  await refused(gr('refund'), /notice runs until/)
  world.refundAt = world.now - 8n * 86_400n
  w = await gr('refund')
  assert.equal(w.success, true, JSON.stringify(w))
  assert.match(w.note, /ends the reward for good/)
  world.refundAt = 0n; world.refundPending = false

  // graduated: claim
  world.state = 2; world.gradAt = world.now - 86_400n; world.claimable = E18 / 5n
  s = await gr('status')
  assert.equal(s.claimable, '0.2')
  assert.match(s.next, /gang grad-reward claim/)
  w = await gr('claim')
  assert.equal(w.success, true, JSON.stringify(w))
  assert.equal(w.amount, '0.2')
  assert.equal(decodeFunctionData({ abi: GRAD_PAD_ABI, data: w.tx.data }).functionName, 'claimGradReward')
  await refused(gr('sweep'), /180 days after graduation/)
  world.claimable = 0n
  await refused(gr('claim'), /no valid entry/)

  // settled already: no empty settle; the sweep once the window is over; nothing owed to retry
  world.settled = true
  await refused(gr('settle'), /already settled/)
  world.gradAt = world.now - 181n * 86_400n
  w = await gr('sweep')
  assert.equal(w.success, true, JSON.stringify(w))
  assert.match(w.note, /the creator 0x/)
  await refused(gr('retry-carry'), /no carry is owed/)
  // closed: said as such
  world.state = 4
  await refused(gr('claim'), /the reward is closed/)
  await refused(gr('settle'), /the reward is closed/)
  world.state = 1; world.settled = false; world.gradAt = 0n

  // a lapsed request is shown as lapsed, and a new one can be made; cancel a running one
  world.refundAt = world.now - 11n * 86_400n; world.refundPending = false
  s = await gr('status')
  assert.equal(s.refund.lapsed, true)
  w = await gr('refund-request')
  assert.equal(w.success, true)
  world.refundAt = world.now - 1n * 86_400n; world.refundPending = true
  w = await gr('refund-cancel')
  assert.equal(decodeFunctionData({ abi: GRAD_PAD_ABI, data: w.tx.data }).functionName, 'cancelGradRefund')
  world.refundAt = world.now - 8n * 86_400n
  w = await gr('refund')
  assert.ok(w.lapsesAt, 'the refund preview says until when it can land')
  world.refundAt = 0n; world.refundPending = false

  // an RPC failure is said, never read as "no reward" (a sell would otherwise void entries without a word)
  const broken = { ...ctx, read: async () => { throw new Error('rpc down') } }
  const bl = await gradBuyLine(broken, TOKEN, WBNB, 'WBNB', ME, E18, false)
  assert.match(bl.error, /could not read/)
  const sl = await gradSellLine(broken, TOKEN, WBNB, 'WBNB', ME)
  assert.match(sl.warning, /takes out your entries/)

  // a 6-decimal quote: the minimum's default and the seed's floor at the token's rate (9 units for 9 BNB)
  r = await create({ quote: Q6, 'grad-reward': '0.5' })
  assert.equal(r.success, true, JSON.stringify(r))
  const c6 = decodeFunctionData({ abi: GRAD_PAD_ABI, data: decodeFunctionData({ abi: VANITY_ABI, data: r.tx.data }).args[1] }).args[8]
  assert.equal(c6.seed, 500_000n)
  assert.equal(c6.minBuy, 10_000n, '0.01 BNB worth = 0.01 USD6')
  assert.equal(r.gradReward.minBuy, '0.01 USD6')
  await refused(create({ quote: Q6, 'grad-reward': '0.09' }), /at least 0\.1 USD6/)

  // a token without a reward
  await refused(runGradReward('status', io({ token: t(0x999), testnet: true })), /not a V3 curve token/)

  // the CLI's own refusals, before any chain read
  const cli = fileURLToPath(new URL('../src/index.js', import.meta.url))
  const gang = (...a) => JSON.parse(spawnSync(process.execPath, [cli, ...a], { env: { ...process.env, GANG_TELEMETRY: '0', GANG_UPDATE_CHECK: '0' }, encoding: 'utf8' }).stdout).error
  const c0 = ['create', '--name', 'A', '--symbol', 'A', '--grad-reward', '1']
  assert.match(gang(...c0, '--fair'), /leave --fair out/)
  assert.match(gang(...c0, '--fly'), /leave --fly out/)
  assert.match(gang(...c0, '--dev-buy', '0.1'), /stands alone/)
  assert.match(gang(...c0, '--bond', '0.1'), /stands alone/)
  assert.match(gang(...c0, '--buy-tax', '2', '--sell-tax', '2', '--promote', '10'), /promoter pool launch/)
  assert.match(gang('create', '--name', 'A', '--symbol', 'A', '--gr-last', '10'), /goes with --grad-reward/)
  assert.match(gang('fair', 'create', '--name', 'A', '--symbol', 'A', '--grad-reward', '1'), /leave --fair out/)

  console.log('gradreward: ok')
} finally { server.closeAllConnections(); server.close() }
