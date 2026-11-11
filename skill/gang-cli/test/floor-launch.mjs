/**
 * The floor launch's state machine and `gang floor`'s gates against a local fake BSC testnet node (no chain, no wallet).
 *
 * A floor module is cloned for ONE token address, before the token exists; a token created anywhere else pays its tax
 * into a module that can never bind. So, run after run of the same `gang create … --floor` command:
 *   1. the clone is built for the address the final metadata and tax rates give, and the plan keeps that address, the
 *      salt and the metadata;
 *   2. a changed tax rate, fee or cap is refused before the create; an unread factory check is retried, never --restart;
 *   3. the create carries the plan's salt and metadata (never a fresh salt), is refused when the pad would put the token
 *      elsewhere, and is refused when the plan lost its token address;
 *   4. a create that has not landed is built again as it was (never --restart); once landed, the token is the one at
 *      the planned address — not another token of the same wallet and symbol;
 *   5. bind takes that token.
 * And `gang floor`: only a module the factory made, cloned for this very token, is shown with its numbers or written to;
 * a redemption that would break the creator's bond is refused; a redemption with no pool price to compare says so.
 *
 *   node skill/gang-cli/test/floor-launch.mjs
 */
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import {
  decodeFunctionData, encodeAbiParameters, encodeFunctionResult, getAddress, getCreate2Address, keccak256, parseAbi,
  parseAbiParameters, stringToHex, toFunctionSelector, toHex, zeroAddress,
} from 'viem'

const LAUNCH_DIR = mkdtempSync(join(tmpdir(), 'gang-floor-launch-'))
process.env.GANG_LAUNCH_DIR = LAUNCH_DIR // read when launch.js loads
process.env.GANG_TELEMETRY = '0'
const { runLaunch } = await import('../src/launch.js')
const { runV3, V3_EVENT_ABIS, V3_NETS } = await import('../src/v3.js')
const { runFloor, FLOOR_ABI, FLOOR_FACTORY_ABI, TESTNET_FLOOR_FACTORY, UNCHECKED_NOTE, UNVERIFIED_NOTE } = await import('../src/floor.js')
const { VANITY_ABI } = await import('../src/vanity.js')
const { BOND_ABI } = await import('../src/bond.js')
const { CALL_BOND_ABI } = await import('../src/callbond.js')
const { CREATOR_FEE_ABI, GRAD_TARGET_ABI, gangGens } = await import('../src/gangpad.js')
const { decodeLogs, firstByModuleType } = await import('../src/chain.js')
const { LP_EVENT_ABIS } = await import('../src/lp.js')
const { PROMOTE_EVENT_ABIS } = await import('../src/promote.js')
const { FLOOR_EVENT_ABIS } = await import('../src/floor.js')

const lc = (a) => String(a).toLowerCase()
const t = (n) => getAddress(`0x${n.toString(16).padStart(40, '0')}`)
const GEN = gangGens(true)[0]
const PAD = lc(GEN.pad), FACTORY = lc(TESTNET_FLOOR_FACTORY), WBNB = lc(V3_NETS.testnet.wbnb)
const VAN = lc(t(0x7a17)), HANDLER = t(0x4a4d), ADMIN = lc(t(0xad41)), ME = t(0xd3f), KOL = t(0x501), PAIR = t(0x9a12)

// ---- the fake node's world
const DIAMOND = lc(t(0xd1a))
const code = new Set([PAD, FACTORY, VAN, ADMIN, WBNB, DIAMOND])
const modules = new Map() // address → { dev, floorToken, quote, cap, payBps, fee, payees, shares, token, listed }
const tokens = new Map() // address → { creator, symbol, recipient, graduated, balances: Map }
const allTokens = []
const world = { moduleOfFails: false, padSays: null, bond: null, treasury: 0n, poolQuote: false, receipt: null }
let hashes = []

const ABI = [...V3_EVENT_ABIS[0], ...CREATOR_FEE_ABI, ...GRAD_TARGET_ABI, ...VANITY_ABI, ...FLOOR_ABI, ...FLOOR_FACTORY_ABI, ...BOND_ABI, ...CALL_BOND_ABI,
  ...parseAbi([
    'function symbol() view returns (string)', 'function decimals() view returns (uint8)', 'function totalSupply() view returns (uint256)',
    'function balanceOf(address) view returns (uint256)', 'function allowance(address,address) view returns (uint256)',
    'function moduleOf(address) view returns (address)', 'function implementation() view returns (address)', 'function kindOf(address token) view returns (uint8)', 'function tokenCount() view returns (uint256)', 'function allTokens(uint256) view returns (address)',
    'function taxConfigOf(address token) view returns (uint16 buyTaxBps, uint16 sellTaxBps, uint16 dividendBps, address recipient)',
  ])]
const functions = new Map()
for (const f of ABI) if (f.type === 'function' && !functions.has(toFunctionSelector(f))) functions.set(toFunctionSelector(f), f)
const hashOf = (args) => keccak256(toHex(JSON.stringify(args, (_k, x) => (typeof x === 'bigint' ? x.toString() : x))))
const predicted = (salt, hash) => lc(getCreate2Address({ from: VAN, bytecodeHash: hash, salt: keccak256(encodeAbiParameters(parseAbiParameters('address, bytes32'), [ME, salt])) }))
const moduleAt = (dev, salt) => lc(`0x${keccak256(encodeAbiParameters(parseAbiParameters('address, bytes32'), [dev, salt])).slice(-40)}`)
const REVERT = { error: { code: 3, message: 'execution reverted', data: '0x' } }
/** A zero value of an ABI output type (for structs this test only sets a few fields of). */
const zeroOf = (o) => (o.type === 'tuple' ? Object.fromEntries(o.components.map((c) => [c.name, zeroOf(c)]))
  : o.type === 'address' ? zeroAddress : o.type === 'bool' ? false : o.type === 'string' ? '' : o.type.startsWith('bytes') ? '0x' + '00'.repeat(Number(o.type.slice(5) || 0))
    : o.type.endsWith(']') ? [] : 0n)

function answer(b) {
  if (b.method === 'eth_chainId') return { result: '0x61' }
  if (b.method === 'eth_getCode') return { result: code.has(lc(b.params[0])) ? '0x60' : '0x' }
  if (b.method === 'eth_blockNumber') return { result: '0x10' }
  if (b.method === 'eth_getBalance') return { result: '0x0' }
  if (b.method === 'eth_getBlockByNumber') {
    return { result: { number: '0x10', timestamp: toHex(1_800_000_000), hash: `0x${'11'.repeat(32)}`, parentHash: `0x${'22'.repeat(32)}`, transactions: [], gasLimit: '0x1', gasUsed: '0x0', difficulty: '0x0', totalDifficulty: '0x0', size: '0x0', nonce: '0x0000000000000000', logsBloom: `0x${'00'.repeat(256)}`, miner: zeroAddress, extraData: '0x', uncles: [] } }
  }
  if (b.method === 'eth_getTransactionReceipt') return { result: world.receipt }
  assert.equal(b.method, 'eth_call', b.method)
  const { to, data } = b.params[0]
  const at = lc(to)
  const f = functions.get(data.slice(0, 10))
  if (!f) return REVERT
  // a contract of someone else whose fallback reverts with a reason (a diamond without that facet)
  if (at === DIAMOND) return { error: { code: 3, message: 'execution reverted: no facet', data: `0x08c379a0${encodeAbiParameters(parseAbiParameters('string'), ['no facet']).slice(2)}` } }
  const { args = [] } = decodeFunctionData({ abi: [f], data })
  const m = modules.get(at), tk = tokens.get(at)
  let result
  switch (f.name) {
    // ---- the pad
    case 'vanityDeployer': if (at !== PAD) return REVERT; result = VAN; break
    case 'taxHandler': case 'router': case 'recipientRegistry': case 'migrator': case 'implementation': result = HANDLER; break
    case 'kindOf': result = at === PAD && tokens.has(lc(args[0])) ? 1 : 0; break
    case 'tokenCount': result = BigInt(allTokens.length); break
    case 'allTokens': result = allTokens[Number(args[0])]; break
    case 'curves': {
      const c = at === PAD ? tokens.get(lc(args[0])) : null
      result = c ? [c.creator, WBNB, 0n, 0n, 0n, 0n, !!c.graduated, 300, 300, c.dividendBps ?? 0, c.graduated ? PAIR : zeroAddress, zeroAddress]
        : [zeroAddress, zeroAddress, 0n, 0n, 0n, 0n, false, 0, 0, 0, zeroAddress, zeroAddress]
      break
    }
    case 'taxConfigOf': { const c = tokens.get(lc(args[0])); if (!c) return REVERT; result = [300, 300, c.dividendBps ?? 0, c.recipient]; break }
    case 'createWithSalt': result = world.padSays ?? predicted(args[0], hashes.at(-1).hash); break
    case 'checkTaxConfigFor': case 'checkTaxConfig': result = [true, '']; break
    case 'isAgent': case 'agentGateEnabled': case 'vanityEnabled': result = true; break
    case 'GRAD_BNB_TIERS': result = [6n, 9n, 12n, 15n].map((x) => x * 10n ** 18n); break
    case 'TARGET_GRAD_BNB': case 'graduationAmountOf': result = 9n * 10n ** 18n; break
    case 'graduationAmountFor': result = args[2]; break
    case 'PROTOCOL_FEE_BPS': result = 100n; break
    case 'PLATFORM_TAX_BPS': result = 50n; break
    case 'CREATOR_FEE_SHARE_BPS': result = 7000n; break
    // ---- the vanity deployer
    case 'tokenInitCodeHash': result = hashOf(args); hashes.push({ args, hash: result }); break
    // ---- the floor factory and the handler admin
    case 'predict': result = moduleAt(args[0], args[1]); break
    case 'create': result = moduleAt(ME, args.at(-1)); break
    case 'admin': result = ADMIN; break
    case 'moduleOf': if (world.moduleOfFails) return { error: { code: -32000, message: 'rpc down' } }; result = modules.get(lc(args[0]))?.listed ? FACTORY : zeroAddress; break
    // ---- a floor module (only where one is on chain)
    case 'moduleType': if (!m) return REVERT; result = stringToHex('floor-v1', { size: 32 }); break
    case 'pad': result = PAD; break
    case 'dev': if (!m) return REVERT; result = m.dev; break
    case 'floorToken': if (!m) return REVERT; result = m.floorToken; break
    case 'token': if (!m) return REVERT; result = m.token ?? zeroAddress; break
    case 'quote': if (!m) return REVERT; result = m.token ? m.quote : zeroAddress; break
    case 'floorQuote': if (!m) return REVERT; result = m.quote; break
    case 'gangQuote': result = zeroAddress; break
    case 'capAmount': if (!m) return REVERT; result = m.cap; break
    case 'payBps': if (!m) return REVERT; result = m.payBps; break
    case 'redeemFeeBps': if (!m) return REVERT; result = m.fee; break
    case 'payeesOf': if (!m) return REVERT; result = [m.payees, m.shares]; break
    case 'treasuryHeld': case 'treasury': if (!m) return REVERT; result = world.treasury; break
    case 'floorSupply': if (!m) return REVERT; result = 10n ** 27n; break
    case 'floorPrice': if (!m) return REVERT; result = (world.treasury * 10n ** 18n) / 10n ** 27n; break
    case 'previewRedeem': { if (!m) return REVERT; const gross = (args[0] * world.treasury) / 10n ** 27n; const fee = (gross * BigInt(m.fee)) / 10_000n; result = [gross - fee, fee]; break }
    case 'paidTotal': case 'payeesPending': case 'unsplit': case 'lastPaidAt': case 'undistributed': case 'owedTotal': case 'owedOf':
      if (!m && f.name !== 'owedOf') return REVERT; result = 0n; break
    case 'previewWork': result = [false, 0n]; break
    case 'keeperServes': result = true; break
    case 'bind': case 'redeem': case 'split': case 'distribute': if (!m) return REVERT; result = f.outputs.length ? 0n : undefined; break
    // ---- bonds
    case 'bondOf': {
      if (f.inputs.length === 1 && f.inputs[0].type === 'address') { result = { ...zeroOf(f.outputs[0]), ...(world.bond ?? {}) }; break }
      result = zeroOf(f.outputs[0]); break
    }
    case 'activeBondOf': result = 0n; break
    // ---- ERC-20s
    case 'symbol': result = at === WBNB ? 'WBNB' : tk ? tk.symbol : 'X'; break
    case 'decimals': result = 18; break
    case 'totalSupply': result = 10n ** 27n; break
    case 'balanceOf': result = tk ? (tk.balances.get(lc(args[0])) ?? 0n) : 0n; break
    case 'allowance': result = 2n ** 255n; break
    default: return REVERT
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

// ---- the CLI's io: `fail` throws, as the real one exits
class Failed extends Error { constructor(error, details) { super(error); this.details = details ?? {} } }
let uploads = 0
const io = (flags) => ({
  opt: (key, fallback) => flags[key] ?? fallback,
  flag: (key) => Object.hasOwn(flags, key),
  out: (x) => x,
  fail: (error, details) => { throw new Failed(error, details) },
  summarize: () => assert.fail('raw calldata needs no wallet preview'),
  checkMeta: () => {},
  resolveLogo: async () => ({ logoURI: 'ipfs://logo' }),
  resolveMeta: async () => { uploads++; return { metaURI: `ipfs://meta-${flags.description ?? 'one'}`, metadata: { name: flags.name } } },
})
const notes = { step: (_ctx, tx, extra) => ({ success: true, ...extra, tx }), skipped: () => ({}) }
const BASE = { name: 'Floor', symbol: 'FLR', from: ME, testnet: true, calldata: true, 'buy-tax': '3', 'sell-tax': '3', floor: true, 'redeem-fee': '2', 'tax-cap': '20', 'tax-cap-share': '50', split: `self:70,${KOL}:30` }
const launch = (over = {}, drop = []) => {
  const flags = { ...BASE, ...over }
  for (const d of drop) delete flags[d]
  return runLaunch('v3', { io: io(flags), runV3, runFair: () => assert.fail('not a 打新 launch'), runBond: () => assert.fail('no bond'), padNotes: () => notes })
}
const refused = async (run, re) => {
  let got
  try { got = await run() } catch (e) { assert.ok(e instanceof Failed, e.stack); assert.match(e.message, re); return e }
  assert.fail(`not refused: ${JSON.stringify(got).slice(0, 300)}`)
}
const planFile = () => join(LAUNCH_DIR, readdirSync(LAUNCH_DIR).find((n) => n.endsWith('.json')))
const plan = () => JSON.parse(readFileSync(planFile(), 'utf8'))
const floorCmd = (sub, flags) => runFloor(sub, { ...io({ testnet: true, calldata: true, from: ME, ...flags }) })

try {
  // ---- 1. the clone: for the address the final metadata gives, kept in the plan with its salt
  const clone = await launch()
  assert.deepEqual([clone.success, clone.step, clone.launch.stage], [true, 'floor-module', 'floor-module'])
  assert.equal(uploads, 1, 'the metadata is uploaded once, at the clone')
  assert.ok(clone.tokenWillBe.endsWith('abcd'))
  assert.equal(hashes[0].args[2], '', 'a probe before any upload')
  assert.equal(hashes.at(-1).args[2], 'ipfs://meta-one')
  assert.deepEqual(hashes.at(-1).args.slice(3), [HANDLER, 300, 300, false])
  const cloneCall = decodeFunctionData({ abi: FLOOR_FACTORY_ABI, data: clone.tx.data })
  assert.equal(cloneCall.functionName, 'create')
  assert.equal(lc(cloneCall.args[0]), clone.tokenWillBe, 'cloned for the token\'s address')
  assert.deepEqual(cloneCall.args.slice(1, 5), [getAddress(WBNB), 20n * 10n ** 18n, 5_000, 200])
  assert.deepEqual([cloneCall.args[5], cloneCall.args[6]], [[ME, KOL], [7_000, 3_000]])
  assert.deepEqual(clone.treasuryGets.untilCap, { pctOfVolume: 1.25 })
  const p1 = plan()
  assert.deepEqual([p1.module, lc(p1.splitter), p1.floor.token, p1.floor.metaURI, p1.floor.buyBps, p1.floor.sellBps], ['floor', lc(clone.module), clone.tokenWillBe, 'ipfs://meta-one', 300, 300])
  assert.equal(predicted(p1.floor.salt, hashes.at(-1).hash), clone.tokenWillBe)
  const TOKEN = clone.tokenWillBe, MODULE = lc(clone.module)

  // not executed yet: nothing is built on top of a module that is not there, and nothing is uploaded again
  const waiting = await launch()
  assert.deepEqual([waiting.success, waiting.error], [false, 'the floor module is not on chain yet'])
  assert.equal(uploads, 1)

  // the clone lands
  code.add(MODULE)
  modules.set(MODULE, { dev: ME, floorToken: getAddress(TOKEN), quote: getAddress(WBNB), cap: 20n * 10n ** 18n, payBps: 5_000, fee: 200, payees: [ME, KOL], shares: [7_000, 3_000], token: null, listed: true })

  // ---- 2. what decides the token's address, and the module's terms, can't change between runs
  await refused(() => launch({ 'sell-tax': '4' }), /cloned for a token with a 3% buy \/ 3% sell tax \(the rates decide the token's address\)/)
  await refused(() => launch({ 'redeem-fee': '1' }), /this launch's floor module is set up like this .* not what --redeem-fee \/ --tax-cap/)
  await refused(() => launch({ 'tax-cap': '21' }), /not what --redeem-fee \/ --tax-cap/)
  await refused(() => launch({}, ['floor', 'redeem-fee', 'tax-cap', 'tax-cap-share', 'split']), /this launch began with --floor .*run it again with the same --floor/)
  // the factory check unread: retried, never "--restart" (that would clone another module for another address)
  world.moduleOfFails = true
  const unread = await refused(() => launch(), /could not check this launch's floor module against its factory \(RPC error\)/)
  assert.equal(unread.details.retry, 'same command again')
  assert.doesNotMatch(unread.message, /--restart/)
  world.moduleOfFails = false
  // a module the factory did not list is not built on
  modules.get(MODULE).listed = false
  await refused(() => launch(), /not an unbound floor module of this wallet/)
  modules.get(MODULE).listed = true

  // ---- 3. the create: the plan's salt and metadata, whatever the flags say now
  hashes = []
  const create = await launch({ description: 'changed-later' })
  assert.deepEqual([create.success, create.step, create.launch.stage], [true, 'create', 'create'])
  assert.equal(uploads, 1, 'nothing is uploaded again: the metadata is the plan\'s')
  const createCall = decodeFunctionData({ abi: VANITY_ABI, data: create.tx.data })
  assert.equal(createCall.functionName, 'createWithSalt')
  assert.equal(createCall.args[0], p1.floor.salt, 'the salt the module\'s token address came from, never a fresh one')
  const inner = decodeFunctionData({ abi: V3_EVENT_ABIS[0], data: createCall.args[1] })
  assert.deepEqual([inner.args[0], inner.args[1], inner.args[2], inner.args[3]], ['Floor', 'FLR', 'ipfs://logo', 'ipfs://meta-one'])
  assert.equal(lc(inner.args[6].recipient), MODULE, 'the module is the recipient')
  assert.deepEqual([create.tokenIfNext, lc(create.floorToken), lc(create.recipient)], [TOKEN, TOKEN, MODULE])
  assert.match(create.metadataFixed, /fixed when the floor module was cloned/)
  assert.equal(plan().floor.token, TOKEN, 'the plan keeps the token address through the create')
  assert.equal(create.warning, undefined)

  // the pad itself would put this call elsewhere: nothing is built
  world.padSays = t(0xbad)
  const elsewhere = await refused(() => launch(), /the pad would create this token at another address than the one its floor module was cloned for/)
  assert.equal(lc(elsewhere.details.padSays), lc(t(0xbad)))
  world.padSays = null
  // a plan that lost its token address never builds a create without it
  const kept = readFileSync(planFile(), 'utf8')
  const { floor: _lost, ...rest } = JSON.parse(kept)
  writeFileSync(planFile(), JSON.stringify(rest))
  await refused(() => launch(), /plan has no token address for its floor module: add --restart/)
  writeFileSync(planFile(), kept)

  // ---- 4. a create that did not land is built again as it was: the same salt, no --restart
  const again = await launch()
  assert.deepEqual([again.success, again.step], [true, 'create'])
  assert.equal(decodeFunctionData({ abi: VANITY_ABI, data: again.tx.data }).args[0], p1.floor.salt)
  assert.match(again.warning, /built this create before and its token is not on chain yet.*executing this one too can only revert/, 'said: an agent re-running until done must not send it twice')
  // another token of this wallet with the same symbol lands meanwhile: it is not this launch's token
  const STRAY = lc(t(0x57a1))
  tokens.set(STRAY, { creator: ME, symbol: 'FLR', recipient: MODULE, balances: new Map() })
  allTokens.push(getAddress(STRAY))
  code.add(STRAY)
  const stillCreate = await launch()
  assert.equal(stillCreate.step, 'create', 'a same-symbol token elsewhere is not taken for this launch\'s')
  assert.equal(plan().token, undefined)

  // the create lands, at the planned address
  tokens.set(TOKEN, { creator: ME, symbol: 'FLR', recipient: getAddress(MODULE), balances: new Map([[lc(ME), 5_000n * 10n ** 18n]]) })
  allTokens.push(getAddress(TOKEN))
  code.add(TOKEN)

  // ---- 5. bind: that token
  const bind = await launch()
  assert.deepEqual([bind.success, bind.step, lc(bind.token)], [true, 'bind', TOKEN])
  assert.deepEqual(decodeFunctionData({ abi: FLOOR_ABI, data: bind.tx.data }).args.map(lc), [TOKEN])
  assert.equal(lc(plan().token), TOKEN)
  // changed terms after the create are still refused
  await refused(() => launch({ 'redeem-fee': '0' }), /not what --redeem-fee/)
  modules.get(MODULE).token = getAddress(TOKEN)
  const done = await launch()
  assert.deepEqual([done.success, done.launch.stage, lc(done.token)], [true, 'done', TOKEN])
  assert.equal(done.floor.verified, true)
  assert.equal(plan().done, true)
  world.moduleOfFails = true
  const doneUnread = await launch()
  assert.deepEqual([doneUnread.launch.stage, doneUnread.floor.verified, doneUnread.floor.warning, 'treasury' in doneUnread.floor], ['done', null, UNCHECKED_NOTE, false])
  world.moduleOfFails = false

  // ---- a floor module can't be named by hand: the token would land elsewhere and pay a module that can never bind it
  const byHand = { name: 'Other', symbol: 'OTH', from: ME, testnet: true, calldata: true, 'buy-tax': '3', 'sell-tax': '3', recipient: getAddress(MODULE) }
  const before = uploads
  await refused(() => runV3('create', { ...io(byHand), notes }), /^--recipient is a floor module: a token can't name one by hand\. .*Leave --recipient out and add --floor/)
  assert.equal(uploads, before, 'refused before anything is uploaded')
  // a plain contract, or a wallet, is still a recipient as before
  const plain = await runV3('create', { ...io({ ...byHand, recipient: KOL }), notes })
  assert.deepEqual([plain.success, plain.step], [true, 'create'])
  // a contract that reverts on moduleType() with a reason is no module either: accepted, not "RPC error, retry" for ever
  const partner = await runV3('create', { ...io({ ...byHand, recipient: getAddress(DIAMOND) }), notes })
  assert.deepEqual([partner.success, partner.step, lc(partner.recipient)], [true, 'create', DIAMOND])

  // ---- gang floor: what is shown, and what is built
  const st = await floorCmd('status', { token: TOKEN })
  assert.deepEqual([st.success, st.verified, st.state, lc(st.token)], [true, true, 'before-graduation', TOKEN])
  assert.ok('treasury' in st && 'floorPerToken' in st)
  // the stray token pays the same module: it has no floor — only the warning, no numbers, no call
  const stray = await floorCmd('status', { token: STRAY })
  assert.deepEqual([stray.isThisTokensFloor, stray.claims, 'treasury' in stray, 'floorPerToken' in stray, 'next' in stray, 'floor' in stray], [false, 'floor-v1', false, false, false, false])
  assert.match(stray.warning, /cloned for another token .*this token has NO floor/)
  await refused(() => floorCmd('redeem', { token: STRAY, amount: '1' }), /cloned for another token/)
  await refused(() => floorCmd('distribute', { token: STRAY }), /cloned for another token/)
  // not made by the factory: the same, whatever the contract says about itself
  modules.get(MODULE).listed = false
  const fake = await floorCmd('status', { token: TOKEN })
  assert.deepEqual([fake.verified, fake.isThisTokensFloor, fake.warning, 'treasury' in fake, 'floorToken' in fake], [false, false, UNVERIFIED_NOTE, false, false])
  for (const sub of ['redeem', 'distribute', 'release', 'set-payee', 'bind']) await refused(() => floorCmd(sub, { token: TOKEN, amount: '1', to: KOL }), /GangFloorModuleFactory did not make it/)
  modules.get(MODULE).listed = true
  // the check unread: nothing shown, nothing built, and not called "not made by the factory"
  world.moduleOfFails = true
  const unchecked = await floorCmd('status', { token: TOKEN })
  assert.deepEqual([unchecked.verified, unchecked.warning, 'treasury' in unchecked], [null, UNCHECKED_NOTE, false])
  const retry = await refused(() => floorCmd('redeem', { token: TOKEN, amount: '1' }), /could not check whether GangFloorModuleFactory made this module/)
  assert.equal(retry.details.retry, 'same command again')
  world.moduleOfFails = false

  // ---- redeem
  await refused(() => floorCmd('redeem', { token: TOKEN, amount: '1' }), /has not graduated/)
  tokens.get(TOKEN).graduated = true
  world.treasury = 10n ** 18n
  await refused(() => floorCmd('redeem', { token: TOKEN }), /--amount <tokens> required/)
  // the module holds less of the quote than its books say (here: none of it): distribute only records the shortfall
  const short = await floorCmd('distribute', { token: TOKEN })
  assert.deepEqual([short.success, short.step, short.shortfall, short.holds, short.books, short.pushedNow], [true, 'distribute', '1', '0', '1', '0'])
  assert.match(short.warning, /1 less than its books/)
  assert.match(short.note, /only records the shortfall/)
  const over = await refused(() => floorCmd('redeem', { token: TOKEN, amount: '6000' }), /^not enough tokens$/)
  assert.deepEqual(over.details, { have: '5000', need: '6000' })
  await refused(() => floorCmd('redeem', { token: TOKEN, amount: '1', to: MODULE }), /--to cannot be the floor module itself/)
  const r = await floorCmd('redeem', { token: TOKEN, amount: '1000' })
  assert.deepEqual([r.success, r.step, r.irreversible, r.redeems], [true, 'redeem', true, '1000'])
  const rc = decodeFunctionData({ abi: FLOOR_ABI, data: r.tx.data })
  const expectOut = (1000n * 10n ** 18n * 10n ** 18n / 10n ** 27n) * 98n / 100n
  assert.deepEqual(rc.args, [1000n * 10n ** 18n, expectOut, ME], 'the minimum is the previewed amount itself')
  assert.equal(lc(r.tx.to), MODULE)
  // no pool price to compare with: said as a warning, not buried in the note
  assert.equal(r.sellingInThePoolInstead, null)
  assert.match(r.warning, /the pool price could not be read, so this redemption is NOT compared with a sale/)
  const all = await floorCmd('redeem', { token: TOKEN, amount: 'all', slippage: '1', to: KOL })
  const ac = decodeFunctionData({ abi: FLOOR_ABI, data: all.tx.data })
  assert.equal(ac.args[0], 5_000n * 10n ** 18n)
  assert.equal(ac.args[2], KOL)
  assert.ok(ac.args[1] < (5_000n * 10n ** 18n * 10n ** 18n / 10n ** 27n) * 98n / 100n, '--slippage lowers the minimum')

  // the creator's bond: a redemption is a sell — one that would break it is refused, as gang sell refuses it
  world.bond = { state: 1, creator: ME, holdAmount: 4_500n * 10n ** 18n, amount: 10n ** 18n, quote: getAddress(WBNB), deadline: 1_900_000_000n }
  const broke = await floorCmd('redeem', { token: TOKEN, amount: '1000' })
  assert.equal(broke.success, false)
  assert.match(broke.error, /leaves 4000 tokens, below the bonded X \(4500\).*You lose the whole bond/)
  assert.match(broke.redeemingCountsAsSelling, /for a bond it is a sell/)
  assert.equal(broke.maxSellKeepingBond, '500')
  const within = await floorCmd('redeem', { token: TOKEN, amount: '400' })
  assert.deepEqual([within.success, within.bondCheck.headroomAfter], [true, '100'])
  const accepted = await floorCmd('redeem', { token: TOKEN, amount: '1000', 'break-bond': true })
  assert.deepEqual([accepted.success, accepted.bondCheck.brokeBond], [true, true])
  world.bond = null

  // ---- gang tx: Split with three amounts is three kinds' event; the emitting module's own names are used
  const SPLIT = FLOOR_ABI.find((x) => x.type === 'event' && x.name === 'Split')
  const { encodeEventTopics } = await import('viem')
  const topic = encodeEventTopics({ abi: [SPLIT] })[0]
  const log = (address) => ({ address, topics: [topic], data: encodeAbiParameters(parseAbiParameters('uint256, uint256, uint256'), [10n, 7n, 3n]) })
  const kinds = { [lc(t(0xf1))]: 'floor-v1', [lc(t(0x1b))]: 'lp-burn-v1', [lc(t(0x9c))]: 'promote-pool-v1', [lc(t(0xbb))]: 'buyback-burn-v4', [lc(t(0x0dd))]: 'something-else-v9' }
  const fakeClient = { readContract: async ({ address }) => { const k = kinds[lc(address)]; if (!k) throw new Error('rpc'); return stringToHex(k, { size: 32 }) } }
  const logs = [log(t(0xf1)), log(t(0x1b)), log(t(0x9c)), log(t(0xbb)), log(t(0xdead)), log(t(0x0dd))]
  const BB = [parseAbi(['event Split(uint256 incoming, uint256 toBuyback, uint256 toDev)'])]
  const byType = (k) => ({ 'lp-burn-v1': LP_EVENT_ABIS, 'promote-pool-v1': PROMOTE_EVENT_ABIS, 'floor-v1': FLOOR_EVENT_ABIS })[k] ?? (String(k ?? '').startsWith('buyback-burn-') ? BB : null)
  const ALL = [...LP_EVENT_ABIS, ...FLOOR_EVENT_ABIS, ...PROMOTE_EVENT_ABIS] // the order gang tx tries them in
  const evs = decodeLogs(logs, ALL, await firstByModuleType(fakeClient, logs, topic, byType))
  assert.deepEqual(evs.map(({ event, contract: _c, units: _u, ...rest }) => [event, rest]), [
    ['Split', { incoming: '10', toTreasury: '7', toPayees: '3' }],
    ['Split', { incoming: '10', toLp: '7', toDev: '3' }],
    ['Split', { incoming: '10', toEscrow: '7', toDev: '3' }],
    ['Split', { incoming: '10', toBuyback: '7', toDev: '3' }],
    ['Split', { kindUnread: true, incoming: '10', firstPart: '7', secondPart: '3' }], // kind unread: no kind's names are guessed
    ['Split', { kindUnread: true, incoming: '10', firstPart: '7', secondPart: '3' }], // a kind this CLI does not know
  ])
  // without it, a floor module's treasury would read as "to the pool" and its payees as "the dev"
  assert.deepEqual(Object.keys(decodeLogs([logs[0]], ALL)[0]).slice(3), ['incoming', 'toLp', 'toDev'])
  // and the command itself, end to end: gang tx on a receipt whose Split comes from the floor module of this test
  const HASH = `0x${'ab'.repeat(32)}`
  world.receipt = {
    transactionHash: HASH, transactionIndex: '0x0', blockHash: `0x${'11'.repeat(32)}`, blockNumber: '0x10', from: ME, to: getAddress(MODULE), contractAddress: null,
    cumulativeGasUsed: '0x1', gasUsed: '0x1', effectiveGasPrice: '0x1', logsBloom: `0x${'00'.repeat(256)}`, status: '0x1', type: '0x0',
    logs: [{ ...log(getAddress(MODULE)), blockHash: `0x${'11'.repeat(32)}`, blockNumber: '0x10', transactionHash: HASH, transactionIndex: '0x0', logIndex: '0x0', removed: false }],
  }
  const cli = new URL('../src/index.js', import.meta.url).pathname
  const { stdout } = await promisify(execFile)(process.execPath, [cli, 'tx', '--hash', HASH, '--testnet'], { env: { ...process.env, GANG_UPDATE_CHECK: '0', GANG_TELEMETRY: '0', GANG_TESTNET_RPC_URL: rpc } })
  const txOut = JSON.parse(stdout)
  assert.equal(txOut.success, true, stdout)
  assert.deepEqual(txOut.events.map(({ event, incoming, toTreasury, toPayees, toLp }) => [event, incoming, toTreasury, toPayees, toLp]), [['Split', '10', '7', '3', undefined]])

  console.log('floor-launch: ok')
} finally {
  server.closeAllConnections()
  server.close()
  rmSync(LAUNCH_DIR, { recursive: true, force: true })
}
