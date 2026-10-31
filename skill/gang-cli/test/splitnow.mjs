/**
 * gang buyback split / gang lp split (a buy-back or LP splitter's split(), anyone) without a chain: the preview's math
 * (splitPlan), the refusals, the "not one of ours" check (listedBy, atPad), and the pay-out command named in the
 * create note and the claim's --to note (payOutCmd, notThroughModule).
 */
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { notListed, splitPlan } from '../src/buyback.js'
import { notThroughModule, payOutCmd } from '../src/creatorfee.js'
import { atPad, GANG_GENS, listedBy } from '../src/gangpad.js'

const E18 = 10n ** 18n
const A = '0x00000000000000000000000000000000000000a1'
const M = '0x00000000000000000000000000000000000000b2'

// ---- splitPlan: the payee's part now, the share set aside, the left after
{
  const p = splitPlan({ unsplit: 77488247599611337n, bps: 5000, left: 0n, payee: A, part: 'buy-back', leftField: 'buybackLeft', symbol: 'MockSPCXB' })
  // the contract: toBuyback = incoming * bps / BPS (rounded down), the payee the rest
  assert.equal(p.splitting, '0.077488247599611337')
  assert.equal(p.setAside, '0.038744123799805668')
  assert.equal(p.toPayee, '0.038744123799805669')
  assert.equal(p.buybackLeftAfter, '0.038744123799805668')
  assert.equal(p.payee, A)
  assert.equal(p.setAsideFor, 'buy-back')
  assert.equal(p.quote, 'MockSPCXB')
  const l = splitPlan({ unsplit: E18, bps: 3000, left: E18 / 2n, payee: A, part: 'liquidity', leftField: 'lpLeft', symbol: null })
  assert.equal(l.toPayee, '0.7')
  assert.equal(l.setAside, '0.3')
  assert.equal(l.lpLeftAfter, '0.8')
  assert.equal(splitPlan({ unsplit: E18, bps: 0, left: 0n, payee: A, part: 'liquidity', leftField: 'lpLeft' }).toPayee, '1')
  assert.equal(splitPlan({ unsplit: E18, bps: 10000, left: 0n, payee: A, part: 'liquidity', leftField: 'lpLeft' }).toPayee, '0')
  // nothing waiting: refused, naming what is already set aside
  const none = splitPlan({ unsplit: 0n, bps: 5000, left: 3n * E18 / 100n, payee: A, part: 'buy-back', leftField: 'buybackLeft' })
  assert.match(none.error, /nothing waits to be split: no quote arrived since the last split \(buybackLeft 0\.03 is already set aside\)/)
  assert.match(splitPlan({ unsplit: 0n, bps: 5000, left: 0n, payee: A, part: 'buy-back', leftField: 'buybackLeft', unbound: true }).error, /not bound to a token yet/)
  assert.equal(splitPlan({ unsplit: 0n, bps: 5000, left: 0n, payee: A, part: 'buy-back', leftField: 'buybackLeft' }).error, 'nothing waits to be split: no quote arrived since the last split')
}

// ---- listedBy: GangHandlerAdmin.moduleOf through the pad's tax handler and its owner
{
  const PAD = GANG_GENS.testnet[0].pad
  const reads = []
  const ctx = (factory) => ({
    pad: PAD,
    read: async (address, _abi, fn, args = []) => {
      reads.push([address, fn, ...args])
      return { taxHandler: '0x00000000000000000000000000000000000000c3', owner: '0x00000000000000000000000000000000000000d4', moduleOf: factory }[fn]
    },
  })
  assert.equal(await listedBy(ctx(GANG_GENS.testnet[0].splitterFactory), M), GANG_GENS.testnet[0].splitterFactory)
  assert.deepEqual(reads.map((r) => r[1]), ['taxHandler', 'owner', 'moduleOf'])
  assert.equal(reads[0][0], PAD)
  assert.equal(reads[1][0], '0x00000000000000000000000000000000000000c3')
  assert.deepEqual(reads[2], ['0x00000000000000000000000000000000000000d4', 'moduleOf', M])
  assert.equal(await listedBy(ctx('0x0000000000000000000000000000000000000000'), M), null)
  // an RPC error is not "not ours": it is thrown
  await assert.rejects(listedBy({ pad: PAD, read: async () => { throw new Error('rpc down') } }, M), /rpc down/)
}

// ---- atPad: a module's own pad() picks its generation; an unknown pad is refused
{
  const ctx = { ...GANG_GENS.testnet[0], _tax: 1, fees: 1 }
  const older = GANG_GENS.testnet[2]
  assert.equal(atPad(ctx, older.pad.toLowerCase(), true), true)
  assert.equal(ctx.pad, older.pad)
  assert.equal(ctx.router, older.router)
  assert.equal(ctx._tax, undefined)
  assert.equal(atPad(ctx, A, true), false)
  assert.equal(ctx.pad, older.pad)
  assert.equal(atPad({ ...GANG_GENS.mainnet[0] }, GANG_GENS.testnet[0].pad, false), false)
  assert.match(notListed('buy-back splitter', true), /not one of the platform's buy-back splitters: no GangLaunchpad pad on the BSC testnet lists it/)
}

// ---- the pay-out command, by moduleType, in the claim's --to note and the create note
{
  assert.match(payOutCmd('buyback-burn-v4', M, ' --testnet'), new RegExp(`^gang buyback split --module ${M} --testnet \\(anyone\\) then pays the payee its part`))
  assert.match(payOutCmd('buyback-burn-v1', M), /^gang buyback split --module/)
  assert.match(payOutCmd('lp-burn-v1', M), /^gang lp split --module .*after graduation each keeper chunk splits first/)
  assert.match(payOutCmd('split-v1', M), /^gang split distribute --module .* the payees their shares$/)
  assert.match(payOutCmd('combo-v1', M), /^gang combo distribute --module/)
  assert.equal(payOutCmd('something-else', M), null)
  assert.equal(payOutCmd(null, M), null)
  const n = notThroughModule('buy-back splitter', { token: A, at: M, net: ' --testnet', kind: 'buyback' })
  assert.match(n, new RegExp(`--claim --to ${M}; gang buyback split --module ${M} --testnet \\(anyone\\)`))
  assert.match(notThroughModule('LP splitter', { at: M, kind: 'lp' }), /; gang lp split --module/)
  assert.match(notThroughModule('combined recipient', { at: M, kind: 'combo' }), /; gang combo distribute --module/)
  // no module address yet (the create preview before the clone): no pay-out command
  assert.doesNotMatch(notThroughModule('buy-back splitter', { kind: 'buyback' }), /split --module/)
}

// ---- refusals before any RPC, and the help
const cli = new URL('../src/index.js', import.meta.url).pathname
const gang = (...args) => {
  const r = spawnSync(process.execPath, [cli, ...args], { encoding: 'utf8', env: { ...process.env, GANG_UPDATE_CHECK: '0' } })
  return JSON.parse(r.stdout)
}
for (const cmd of ['buyback', 'lp']) {
  const both = gang(cmd, 'split', '--token', A, '--module', M, '--testnet')
  assert.equal(both.success, false)
  assert.match(both.error, /give --token \(its tax recipient is the splitter\) or --module, not both/)
  assert.match(gang(cmd, 'split', '--module', 'nope', '--testnet').error, /--module must be an? (buy-back|LP) splitter address/)
  assert.match(gang(cmd, 'nope').error, new RegExp(`usage: gang ${cmd} <[a-z|-]*\\|split`))
}
const help = spawnSync(process.execPath, [cli, 'help'], { encoding: 'utf8', env: { ...process.env, GANG_UPDATE_CHECK: '0' } }).stdout
for (const c of ['gang buyback split (--token <addr> | --module <splitter>)', 'gang lp split (--token <addr> | --module <splitter>)']) assert.ok(help.includes(c), `help mentions ${c}`)

console.log('splitnow: ok')
