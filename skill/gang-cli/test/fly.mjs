/**
 * 持续打新 (fly) without a chain: the market row and its next command (discover.js), a fly holding in gang portfolio, and
 * the create / bond / buyback flags refused before any RPC (index.js). The on-chain commands are covered by the
 * testnet / anvil runs listed in the CLI's release notes.
 *
 *   node skill/gang-cli/test/fly.mjs
 */
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { normalize, rank } from '../src/discover.js'
import { _test } from '../src/portfolio.js'
import { FLY_PRESETS, inviteLink } from '../src/fly.js'

const t = (n) => `0x${String(n).padStart(40, '0')}`
const now = Math.floor(Date.now() / 1000)

// a fly row reads like a 打新 one; a launched sale with post-launch minting still points at gang mint
const row = (n, status, extra = {}) => ({
  address: t(n), symbol: `F${n}`, track: 'fly', status, graduated: status === 'launched', sold: 2500, sharePrice: String(2e15),
  raiseQuote: String(20e18), sharesLeft: 7500, minWalletsLeft: 750, quoteSymbol: 'WBNB', quoteDecimals: 18, createdAt: now - 60,
  postMint: true, baseQuota: 10, inviteBonus: 1, trades24h: 3, ...extra,
})
const minting = normalize(row(1, 'minting'))
assert.deepEqual([minting.track, minting.raised, minting.graduationTarget, minting.sharesLeft, minting.postMint, minting.baseQuota], ['fly', 5, 20, 7500, true, 10])
const [m] = rank([minting], 'new')
assert.equal(m.next, `gang mint --token ${t(1)} --shares <n>`)
const [live] = rank([normalize(row(2, 'launched'))], 'new', { includeGraduated: true })
assert.equal(live.next, `gang mint --token ${t(2)} --shares <n>`)
const [plain] = rank([normalize(row(3, 'launched', { postMint: false }))], 'new', { includeGraduated: true })
assert.match(plain.next, /^gang buy --token/)
// filled: waits for its launch; refund-only: sell back
assert.equal(rank([normalize(row(8, 'filled'))], 'new')[0].next, `gang info --token ${t(8)}`)
assert.equal(rank([normalize(row(9, 'refund'))], 'new')[0].next, `gang withdraw --token ${t(9)} --all`)

// portfolio: before launch the value is the sell-back; after it the pool, the reward and the quota left
const pos = (n) => ({ track: 'fly', address: t(n), symbol: `F${n}`, quoteSymbol: 'WBNB', quoteUsd: 600, costQuote: '0.03', balance: '1000000' })
const pre = _test.holdingOf(pos(4), 'fly', { sale: { launched: false }, position: { preShares: 10, balance: '1000000', sellBackAll: '0.0297' } })
assert.deepEqual([pre.status, pre.shares, pre.value, pre.next], ['minting', 10, 0.0297, [`gang withdraw --token ${t(4)} --all`]])
// filled, sell-back closed: launch is next, not a withdraw that would be refused
const full = _test.holdingOf(pos(10), 'fly', { sale: { launched: false, status: 'filled', sellBackOpen: false }, position: { preShares: 10, balance: '1000000' } })
assert.deepEqual([full.status, full.sellBackOpen, full.next], ['filled', false, [`gang fly launch --token ${t(10)}`]])
const post = _test.holdingOf(pos(5), 'fly', {
  sale: { launched: true },
  position: { preShares: 10, balance: '1000000', poolSellAll: { expectOut: '0.05' }, pendingReward: '0.001', reward: 'earning', sellableBeforeOut: '400000', quotaLeft: 5 },
})
assert.deepEqual([post.status, post.value, post.claimable, post.reward, post.sellableBeforeOut, post.quotaLeft],
  ['launched', 0.05, 0.001, 'earning', '400000', 5])
assert.deepEqual(post.next, [`gang sell --token ${t(5)} --all`, `gang claim --token ${t(5)}`])

// the J preset is the spec's template; the invite link is the site's token page with ?ref=
assert.deepEqual(FLY_PRESETS.j, {
  raise: 20, quota: 10, invite: 1, maxPerTx: 10, hold: 60, mintFee: 1, exitFee: 1, devCut: 10, buyPct: 30, sellTax: 2,
  launchDelay: 60, window: 600, capMul: 1, postMint: true, tier: 'standard', supplyCap: 100,
})
assert.equal(inviteLink(t(6), t(7)), `https://gang.fun/token/${t(6)}?ref=${t(7)}`)

// refused before any RPC or wallet call
const gang = (...args) => {
  const r = spawnSync(process.execPath, [new URL('../src/index.js', import.meta.url).pathname, ...args], {
    encoding: 'utf8', env: { ...process.env, GANG_UPDATE_CHECK: '0', PATH: '' },
  })
  return JSON.parse(r.stdout)
}
const refused = (args, re) => {
  const r = gang(...args)
  assert.equal(r.success, false, args.join(' '))
  assert.match(r.error, re, args.join(' '))
}
refused(['create', '--fly', '--name', 'A', '--symbol', 'A', '--bond', '1'], /no GangBond/)
refused(['create', '--fly', '--name', 'A', '--symbol', 'A', '--buyback', '50'], /buy-back splitter/)
refused(['create', '--fly', '--name', 'A', '--symbol', 'A', '--dev-buy', '1'], /--dev-buy/)
refused(['fly', 'create', '--name', 'A', '--symbol', 'A', '--bond', '1'], /no GangBond/)
refused(['create', '--fly', '--name', 'A', '--symbol', 'A', '--buy-tax', '2'], /buy tax is fixed at 1%/)
refused(['create', '--fly', '--name', 'A', '--symbol', 'A', '--shares', '2'], /--dev-shares/)
refused(['create', '--fly', '--name', 'A', '--symbol', 'A', '--cap', '1'], /--quota/)
refused(['create', '--fly', '--fair', '--name', 'A', '--symbol', 'A'], /not both/)
refused(['create', '--name', 'A', '--symbol', 'A', '--quota', '10'], /add --fly/)
refused(['create', '--fair', '--name', 'A', '--symbol', 'A', '--invite-bonus', '1'], /add --fly/)
refused(['fly', 'nope'], /usage: gang fly/)
// the alias takes the same create checks as gang create --fly
refused(['fly', 'create', '--name', 'A', '--symbol', 'A', '--shares', '5'], /--dev-shares/)
refused(['fly', 'create', '--name', 'A', '--symbol', 'A', '--buy-tax', '2'], /buy tax is fixed/)

console.log('fly: ok')
