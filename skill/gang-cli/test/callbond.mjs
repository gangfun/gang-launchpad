/**
 * gang call-bond (GangCallBond, docs/SPEC-AGENT-CALLS-2026-11-09.md §5): argument parsing, the forfeit split, the Merkle
 * leaf and proof the contract checks, the 有担保 label check and the sell guard. No network.
 *
 *   node skill/gang-cli/test/callbond.mjs
 */
import assert from 'node:assert/strict'
import { encodeAbiParameters, keccak256, concat, parseEther } from 'viem'
import {
  callBondAddress, callBondGuard, forfeitSplit, labelCheck, leafOf, parseFor, parseHold, rootFromProof, LABEL_WINDOW, MAX_DURATION, MIN_DURATION,
} from '../src/callbond.js'
import { GANG_GENS } from '../src/gangpad.js'
import { followPromoter } from '../src/promote.js'

// ---- --for
assert.equal(parseFor('48h'), 48 * 3600)
assert.equal(parseFor('2d'), 2 * 86400)
assert.equal(parseFor('7d'), MAX_DURATION)
assert.equal(parseFor('168h'), MAX_DURATION)
assert.equal(MIN_DURATION, 48 * 3600)
for (const bad of ['47h', '1d', '8d', '169h', '48', '', undefined, '2w', '-48h']) assert.throws(() => parseFor(bad), /--for/, String(bad))

// ---- --hold
const bal = parseEther('1000')
assert.deepEqual(parseHold(undefined, bal), { hold: bal, all: true })
assert.deepEqual(parseHold('all', bal), { hold: bal, all: true })
assert.deepEqual(parseHold('100%', bal), { hold: bal, all: true })
assert.deepEqual(parseHold('50%', bal), { hold: parseEther('500'), all: false })
assert.deepEqual(parseHold('1000', bal), { hold: bal, all: true })
assert.deepEqual(parseHold('12.5', bal), { hold: parseEther('12.5'), all: false })
for (const bad of ['0%', '101%', 'half', '-1', '1e3']) assert.throws(() => parseHold(bad, bal), /--hold/, bad)

// ---- the forfeit split: 1% / 50% / 49%; the caller's own report burns the 1% too; it always adds up
{
  const a = parseEther('1')
  assert.deepEqual(forfeitSplit(a), { reward: parseEther('0.01'), burned: parseEther('0.5'), pool: parseEther('0.49') })
  assert.deepEqual(forfeitSplit(a, true), { reward: 0n, burned: parseEther('0.51'), pool: parseEther('0.49') })
  for (const x of [1n, 99n, 101n, 12345678901234567n, parseEther('3.333333333333333333')]) {
    for (const self of [false, true]) {
      const s = forfeitSplit(x, self)
      assert.equal(s.reward + s.burned + s.pool, x)
      assert.ok(s.burned >= x / 2n)
    }
  }
}

// ---- the leaf: OpenZeppelin StandardMerkleTree's double hash of abi.encode(contract, chainId, id, account, amount)
{
  const contract = '0xBE2B8519278E9D31B6c4040bAd35f727fD5d2A70'
  const account = '0x8a2c1ddbdc5d0acc4588481bf9ab502f916b3468'
  const want = keccak256(keccak256(encodeAbiParameters(
    [{ type: 'address' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'address' }, { type: 'uint256' }],
    [contract, 97n, 1n, account, 1470000000000000n],
  )))
  assert.equal(leafOf(contract, 97, 1n, account, 1470000000000000n), want)
  assert.notEqual(leafOf(contract, 56, 1n, account, 1470000000000000n), want, 'the chain id is in the leaf')
  assert.notEqual(leafOf(contract, 97, 2n, account, 1470000000000000n), want, 'the bond id is in the leaf')

  // a two-leaf tree, sorted pairs (OpenZeppelin MerkleProof)
  const other = leafOf(contract, 97, 1n, '0x0b57ac8516765e4a4e49ca4aafc903720908f684', 2940000000000000n)
  const root = BigInt(want) < BigInt(other) ? keccak256(concat([want, other])) : keccak256(concat([other, want]))
  assert.equal(rootFromProof(want, [other]), root)
  assert.equal(rootFromProof(other, [want]), root)
  assert.equal(rootFromProof(want, []), want)
}

// ---- 有担保: the whole balance, within 10 minutes of the note, no sell since, deadline ≥ note + 48 h
{
  const t0 = 1_800_000_000
  const ok = { holdAll: true, noteTime: t0, now: t0 + 60, duration: MIN_DURATION, soldSince: false }
  assert.deepEqual(labelCheck(ok), { bonded: true })
  assert.equal(labelCheck({ ...ok, now: t0 + LABEL_WINDOW }).bonded, true)
  const late = labelCheck({ ...ok, now: t0 + LABEL_WINDOW + 1 })
  assert.equal(late.bonded, false)
  assert.ok(late.why.some((w) => /10 minutes/.test(w)))
  // posted 5 minutes after the note for exactly 48 h: the deadline is still ≥ note + 48 h
  assert.equal(labelCheck({ ...ok, now: t0 + 300 }).bonded, true)
  assert.ok(labelCheck({ ...ok, holdAll: false }).why.includes('hold is not the whole balance'))
  assert.ok(labelCheck({ ...ok, soldSince: true }).why.some((w) => /sold/.test(w)))
  assert.equal(labelCheck({ ...ok, noteTime: null }).bonded, false)
}

// ---- addresses: built in on testnet, not on mainnet; the env overrides
assert.equal(callBondAddress(true), '0xBE2B8519278E9D31B6c4040bAd35f727fD5d2A70')
assert.equal(callBondAddress(false), '0x6d6e4A36e9a231cCc932151cdbFb087Cf3860c3D')
assert.equal(GANG_GENS.testnet[0].callBond, '0xBE2B8519278E9D31B6c4040bAd35f727fD5d2A70')

// ---- the sell guard against a running call bond (a mock 3.0 ctx on the testnet pad)
{
  const pad = GANG_GENS.testnet[0].pad
  const token = '0x00000000000000000000000000000000000000aa'
  const me = '0x00000000000000000000000000000000000000bb'
  const mk = ({ id = 7n, hold = parseEther('100'), balance = parseEther('150'), deadline = 4_000_000_000n, fail = false }) => ({
    pad,
    read: async (address, abi, fn) => {
      if (fail) throw new Error('rpc down')
      if (fn === 'activeBondOf') return id
      if (fn === 'bondOf') return { hold, deadline, caller: me, token, state: 1 }
      if (fn === 'balanceOf') return balance
      throw new Error(`unexpected read ${fn}`)
    },
  })
  const g = (ctx, amount, breakBond = false) => callBondGuard(ctx, { token, me, amount, testnet: true, breakBond })
  assert.equal(await g(mk({ id: 0n }), parseEther('150')), null, 'no running bond: nothing to check')
  const fine = await g(mk({}), parseEther('50'))
  assert.equal(fine.info.callBondCheck.headroomAfter, '0')
  const refused = await g(mk({}), parseEther('50.000000000000000001'))
  assert.ok(refused.refuse, 'below hold: refused')
  assert.equal(refused.refuse.maxSellKeepingBond, '50')
  const broke = await g(mk({}), parseEther('60'), true)
  assert.equal(broke.info.callBondCheck.brokeBond, true)
  const late = await g(mk({ deadline: 1n }), parseEther('60'))
  assert.match(late.refuse.error, /settle it first/)
  assert.ok((await g(mk({ fail: true }), 1n)).refuse, 'an unread bond never lets a sell through')
  assert.equal(await g(mk({ fail: true }), 1n, true), null, '--break-bond skips the check')
  // another pad (an older generation's token): no call bond there
  assert.equal(await callBondGuard({ ...mk({}), pad: GANG_GENS.testnet[1].pad }, { token, me, amount: parseEther('150'), testnet: true }), null)
}

// ---- a follow binds the note's author as promoter (spec §4), only when the pad would bind them
{
  const token = '0x00000000000000000000000000000000000000aa'
  const me = '0x00000000000000000000000000000000000000bb'
  const author = '0x00000000000000000000000000000000000000Cc'
  const creator = '0x00000000000000000000000000000000000000dd'
  const noteTx = `0x${'11'.repeat(32)}`
  const mk = ({ share = 2000, canBind = true, agent = true, bound = '0x0000000000000000000000000000000000000000', traded = false, txFails = false } = {}) => ({
    pad: '0x00000000000000000000000000000000000000ee',
    client: { getTransaction: async () => { if (txFails) throw new Error('rpc'); return { from: author } } },
    read: async (address, abi, fn) => {
      if (fn === 'promoteOf') return [share, 30 * 86400]
      if (fn === 'bindingOf') return [bound, 0, traded]
      if (fn === 'canBind') return canBind
      if (fn === 'isAgent') return agent
      throw new Error(`unexpected read ${fn}`)
    },
  })
  const yes = await followPromoter(mk(), { token, me, noteTx, creator })
  assert.equal(yes.promoter.toLowerCase(), author.toLowerCase())
  assert.equal(yes.sharePct, 20)
  assert.equal(yes.windowDays, 30)
  assert.equal(await followPromoter(mk({ share: 0 }), { token, me, noteTx, creator }), null, 'no terms: a plain follow')
  const traded = await followPromoter(mk({ canBind: false, traded: true }), { token, me, noteTx, creator })
  assert.equal(traded.attached, false)
  assert.equal(traded.promoter, undefined, 'a refused binding never names a promoter to bind')
  const own = await followPromoter(mk({ canBind: false }), { token, me, noteTx, creator: author })
  assert.equal(own.attached, false, "the token's creator can't be a promoter")
  // an unread answer never falls through to a plain first buy (it could never bind later): the CLI refuses instead
  assert.equal((await followPromoter(mk({ txFails: true }), { token, me, noteTx, creator })).unread, true)
  const down = { ...mk(), read: async () => { throw new Error('rpc down') } }
  assert.equal((await followPromoter(down, { token, me, noteTx, creator })).unread, true)
}

console.log('callbond: ok')
