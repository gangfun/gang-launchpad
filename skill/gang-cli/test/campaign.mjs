/**
 * gang campaign: the sign-up typed data, the summaries, and the CLI against a local fake gang.fun and a fake `baw` that
 * signs with a test key (no chain, no wallet): status, the join preview, --yes (the server recovers the signer), refusals.
 *
 *   node skill/gang-cli/test/campaign.mjs
 */
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { createServer } from 'node:http'
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'
import { recoverTypedDataAddress } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'

const { joinTypedData, summary, mineOf, noteFor, joinClosed, takesJoin, isCash, hasCash, kindOf, signUpOf, wholeU, rewardsOf, CAMPAIGN_NOTE_CASH,
  isBuyReward, noSignUp, tokensOf, buyRulesOf, buyMineOf, CAMPAIGN_NOTE_BUY, estimateNoteOf, priceWords, CAMPAIGN_DOMAIN, CAMPAIGN_NOTE, CAMPAIGN_NOTE_CLOSED, CAMPAIGN_NOTE_LIST } = await import('../src/campaign.js')
const CLI = fileURLToPath(new URL('../src/index.js', import.meta.url))
const dir = mkdtempSync(join(tmpdir(), 'gang-campaign-'))

// a throwaway test key (anvil's account #1), never a real wallet
const KEY = '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d'
const acct = privateKeyToAccount(KEY)
const now = Math.floor(Date.now() / 1000)

// --- pure parts ---
{
  const td = joinTypedData(acct.address, 'agent-season', 123)
  assert.deepEqual(CAMPAIGN_DOMAIN, { name: 'gang.fun campaign', version: '1', chainId: 56 })
  assert.deepEqual(td.domain, CAMPAIGN_DOMAIN)
  assert.equal(td.primaryType, 'CampaignJoin')
  assert.deepEqual(td.types.CampaignJoin, [{ name: 'wallet', type: 'address' }, { name: 'campaign', type: 'string' }, { name: 'expires', type: 'uint256' }])
  assert.deepEqual(td.types.EIP712Domain.map((x) => x.name), ['name', 'version', 'chainId'])
  const { EIP712Domain, ...types } = td.types
  const sig = await acct.signTypedData({ domain: td.domain, types, primaryType: td.primaryType, message: td.message })
  assert.equal(await recoverTypedDataAddress({ domain: td.domain, types, primaryType: td.primaryType, message: td.message, signature: sig }), acct.address)
}
{
  const s = summary({
    slug: 'agent-season', title: { zh: '入帮季', en: 'Agent Season' }, status: 'live', window: { start: now - 10, end: now + 10 },
    tickets: { total: 250, holders: 180, prizes_now: 2 },
    lottery: { status: 'drawn', snapshot_hash: '0xab', target_block: 7, winners: [{ i: 0, r: '5', wallet: '0x1', prize_u: 500 }] },
  })
  assert.equal(s.title, 'Agent Season')
  assert.deepEqual(s.tickets, { total: 250, holders: 180, prizesNow: 2 })
  assert.deepEqual(s.lottery, { status: 'drawn', snapshotHash: '0xab', targetBlock: 7, winners: [{ wallet: '0x1', prizeU: 500 }] })
  assert.equal(s.url, 'https://gang.fun/campaign/agent-season')
  assert.equal(summary({ slug: 'x', title: 'Plain', status: 'ended', window: { start: 1, end: 2, ended_at: 3 } }).title, 'Plain')
  assert.equal(mineOf(null), null)
  const m = mineOf({ wallet: '0xa', status: 'entered', tickets: { base: 1, revisit: 1, invite: 3, total: 5 }, joined_at: now, won: false })
  assert.deepEqual(m.tickets, { base: 1, revisit: 1, invite: 3, total: 5 })
  assert.equal(m.joined, true)
  assert.equal(mineOf({ wallet: '0xb' }).tickets.total, 0)
}
assert.match(CAMPAIGN_NOTE, /never trade only to earn campaign rewards or tickets/i)
// sign-up closed by the config: the note says so, keeps the safety rule and never sends to `campaign join`
for (const n of [CAMPAIGN_NOTE_CLOSED, CAMPAIGN_NOTE_LIST]) {
  assert.match(n, /never trade only to earn campaign rewards or tickets/i)
  assert.match(n, /never on your own/i)
  assert.match(n, /user's decision, previewed and confirmed/)
  assert.doesNotMatch(n, /campaign join|same base ticket/)
}
assert.match(CAMPAIGN_NOTE_CLOSED, /sign-up is closed/)
assert.match(CAMPAIGN_NOTE_CLOSED, /as the campaign's rules say \(see notice/)
assert.doesNotMatch(CAMPAIGN_NOTE_CLOSED, /GANG 3\.0|any amount/, 'no campaign-specific rule in the CLI: the notice carries it')
assert.match(CAMPAIGN_NOTE_CLOSED, /signed up earlier keep/)
assert.equal(joinClosed({ rules: { ticket: { join: false } } }), true)
assert.equal(joinClosed({ rules: { ticket: {} } }), true, 'no join key = closed (the server refuses a join without it)')
assert.equal(joinClosed({ rules: {} }), true)
assert.equal(joinClosed({ rules: { ticket: { join: true } } }), false)
assert.equal(takesJoin({ status: 'live', tickets: {}, rules: { ticket: {} } }), false, 'no join key')
assert.equal(noteFor({ rules: { ticket: { join: true } } }), CAMPAIGN_NOTE)
assert.equal(takesJoin({ status: 'live', tickets: {}, rules: { ticket: { join: true } } }), true)
assert.equal(takesJoin({ status: 'live', tickets: {}, rules: { ticket: { join: false } } }), false, 'sign-up closed')
assert.equal(takesJoin({ status: 'live', tickets: null, rules: { ticket: { join: true } } }), false, 'no tickets')
assert.equal(takesJoin({ status: 'ended', tickets: {}, rules: { ticket: { join: true } } }), false, 'not live')
assert.equal(takesJoin(null), false)
assert.equal(noteFor({ rules: { ticket: { join: false } } }), CAMPAIGN_NOTE_CLOSED)
{
  const s = summary({ slug: 'x', status: 'live', window: {}, rules: { ticket: { join: false }, page: { notice_en: '  Sign-up closed.  ' } } })
  assert.equal(s.notice, 'Sign-up closed.'); assert.equal(s.signUp, 'closed')
  const o = summary({ slug: 'x', status: 'live', window: {}, rules: { ticket: { join: true }, page: { notice_en: 7 } } })
  assert.equal(o.notice, undefined); assert.equal(o.signUp, undefined)
}

const LIVE_T = { slug: 'tix', status: 'live', window: {}, tickets: { total: 1 }, rules: { ticket: { enabled: true, join: true } } }

// --- campaigns with cash rewards (0.47.0+): no tickets, an amount per wallet, no sign-up ---
const CASH = {
  now, slug: 'cash-one', type: 'onboarding', title: { en: 'Cash One' }, status: 'live',
  window: { start: now - 3600, end: now + 86400 }, tickets: null, lottery: null,
  rules: {
    count: { tracks: ['v3', 'fair'], pads: ['0x2bebed4be8c8f46c17776c71d7a6a45dbc5cab29', '0x000000000000000000000000000000000000abcd'], quotes: ['0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c', '0x55d398326f99059ff775485246999027b3197955'], kinds: ['buy', 'mint'] },
    require_agent_id: true,
    new_user: { cash: true, threshold_u: 0.95, revisit_min_u: 0.95, revisit_after_s: 86400, revisit_within_s: 7 * 86400, tiers: [{ slots: 100, first_u: 1, revisit_u: 0.5 }, { slots: 400, first_u: 0.5, revisit_u: 0.25 }] },
    invite: null, ticket: null, dev_board: { metric: 'revisited_new_wallets', prizes_u: [30, 20, 10], min_count: 3 }, payout: { user_asset: 'GANG', dev_asset: 'GANG' },
  },
  slots: { open: 500, total: 500, entered: 12, waitlist: 0, left: 488 },
  periods: [{ id: 1 }, { id: 2 }],
}
{
  // the smallest whole U at or above the real threshold (6 decimals): never shown lower than it is
  for (const [u, w] of [[0.95, 1], [1, 1], [1.004, 2], [1.05, 2], [0.004, 1], [0, 0], [1.0000001, 1], [1.2, 2], [0.1 + 0.2, 1], [3 * 1.1, 4]]) assert.equal(wholeU(u), w, `wholeU(${u})`)
  assert.equal(wholeU(null), null)
  assert.equal(isCash(CASH), true); assert.equal(kindOf(CASH), 'cash'); assert.equal(signUpOf(CASH), 'none')
  assert.equal(isCash({ status: 'live', tickets: {}, rules: { new_user: { cash: false }, ticket: { join: true } } }), false)
  assert.equal(kindOf({ tickets: {}, rules: { ticket: { join: true } } }), 'tickets')
  assert.equal(signUpOf({ tickets: {}, rules: { ticket: { join: true } } }), 'open')
  assert.equal(takesJoin(CASH), false)
  assert.equal(noteFor(CASH), CAMPAIGN_NOTE_CASH)
  assert.match(CAMPAIGN_NOTE_CASH, /No sign-up/); assert.match(CAMPAIGN_NOTE_CASH, /sells never count/)
  assert.match(CAMPAIGN_NOTE_CASH, /never trade only to earn campaign rewards or tickets/i); assert.match(CAMPAIGN_NOTE_CASH, /never on your own/i)
  const rw = rewardsOf(CASH)
  assert.equal(rw.asset, 'GANG')
  assert.equal(rw.entry.minU, 1); assert.match(rw.entry.text, /≥1 U/); assert.doesNotMatch(rw.entry.text, /0\.95/)
  assert.match(rw.counts, /buys and mints only \(sells never count\), net of fees/)
  assert.deepEqual(rw.counted, {
    kinds: ['buy', 'mint'], tracks: ['v3', 'fair'], agentId: true,
    pads: [{ address: '0x2bebed4be8c8f46c17776c71d7a6a45dbc5cab29', name: 'GangLaunchpad 3.0' }, { address: '0x000000000000000000000000000000000000abcd', name: null }],
    quotes: [{ address: '0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c', symbol: 'WBNB' }, { address: '0x55d398326f99059ff775485246999027b3197955', symbol: 'USDT' }],
  })
  assert.equal(rw.who.newWalletsOnly, true); assert.equal(rw.who.agentId, true)
  assert.match(rw.entry.text, /^a new wallet \(its first Gang trade is in the window; one that traded on Gang before gets nothing\) holding an Agent ID/)
  assert.match(rw.entry.text, /on GangLaunchpad 3\.0 or 0x0+abcd/); assert.match(rw.entry.text, /paid in WBNB or USDT/)
  assert.match(rw.entry.text, /of GangLaunchpad curve tokens or 打新 fair mint/)
  {
    const any = rewardsOf({ ...CASH, rules: { ...CASH.rules, count: { kinds: ['buy'] }, require_agent_id: false } })
    assert.deepEqual({ ...any.counted }, { kinds: ['buy'], tracks: null, pads: null, quotes: null, agentId: false }, 'null = any')
    assert.doesNotMatch(any.entry.text, /Agent ID| on GangLaunchpad| on 0x|paid in/); assert.match(any.counts, /^buys only/)
  }
  assert.deepEqual(rw.perWallet, [{ slots: 100, firstU: 1, comeBackU: 0.5 }, { slots: 400, firstU: 0.5, comeBackU: 0.25 }])
  assert.deepEqual({ ...rw.comeBack, text: undefined }, { minU: 1, after: '1 d', within: '7 d', text: undefined })
  assert.match(rw.comeBack.text, /≥1 U from 1 d to 7 d after/)
  assert.deepEqual(rw.slots, { total: 500, open: 500, left: 488, entered: 12 })
  assert.deepEqual(rw.devBoard, { prizesU: [30, 20, 10], perPeriod: true, periods: 2, asset: 'GANG', metric: 'revisited_new_wallets', minCount: 3 })
  for (const t of [rw.counts, rw.entry.text, rw.comeBack.text]) assert.doesNotMatch(t, /\bsell(s)? count/i)
  const s = summary(CASH)
  assert.equal(s.kind, 'cash'); assert.equal(s.signUp, 'none'); assert.deepEqual(s.rewards, rw); assert.equal(s.tickets, undefined)
  assert.equal(rewardsOf(LIVE_T), null, 'a ticket campaign has no rewards block')
  const t = summary(LIVE_T)
  assert.equal(t.kind, 'tickets'); assert.equal(t.rewards, undefined); assert.equal(t.signUp, undefined)
  const m = mineOf({ wallet: '0xa', status: 'entered', slot: 7, tier: 1, amount_u: 1.234, first_u: 1, revisit_u: 0.5, earned_u: 1.5, paid: 1, revisit: { due_from: now, due_until: now + 60, min_u: 0.95, done: false } }, CASH)
  assert.deepEqual({ ...m.cash, comeBack: { ...m.cash.comeBack, from: !!m.cash.comeBack.from, until: !!m.cash.comeBack.until } },
    { status: 'entered', slot: 7, tier: 1, amountU: 1.234, firstU: 1, comeBackU: 0.5, comeBack: { from: true, until: true, minU: 1, done: false }, earnedU: 1.5, paidU: 1, asset: 'GANG' })
  // both: tickets and cash per wallet → kind cash+tickets, both blocks, the ticket sign-up
  const BOTH = { ...CASH, tickets: { total: 3, holders: 2, prizes_now: 1 }, lottery: { status: 'open' }, rules: { ...CASH.rules, ticket: { enabled: true, join: true } } }
  assert.equal(kindOf(BOTH), 'cash+tickets'); assert.equal(hasCash(BOTH), true); assert.equal(isCash(BOTH), false)
  assert.equal(signUpOf(BOTH), 'open'); assert.equal(takesJoin(BOTH), true); assert.equal(noteFor(BOTH), CAMPAIGN_NOTE)
  const sb = summary(BOTH)
  assert.equal(sb.kind, 'cash+tickets'); assert.deepEqual(sb.tickets, { total: 3, holders: 2, prizesNow: 1 }); assert.equal(sb.rewards.entry.minU, 1); assert.equal(sb.signUp, undefined)
  const mb = mineOf({ wallet: '0xa', status: 'entered', tickets: { base: 1, total: 1 } }, BOTH)
  assert.equal(mb.tickets.base, 1); assert.equal(mb.cash.status, 'entered')
  assert.equal(mineOf({ wallet: '0xa', status: 'entered' }, LIVE_T).cash, undefined, 'ticket campaign: no cash progress')
  assert.equal(mineOf({ wallet: '0xa', status: 'pending' }, CASH).cash.comeBack, null)
}

// --- buy-reward campaigns (type buy_reward, 0.48.0+): a token reward per period by counted buys, no sign-up ---
const E18 = '000000000000000000'
const BUY = {
  now, slug: 'buy-week', type: 'buy_reward', title: { zh: '买入奖励', en: 'Buy Week' }, status: 'live', notice: { zh: '第 2 期进行中', en: '  Period 2 is live.  ' },
  window: { start: now - 86400, end: now + 6 * 86400, ended_at: null }, version: 2,
  reward: { token: '0x000000000000000000000000000000000000beef', symbol: 'GANG', decimals: 18, total_units: `1000000${E18}` },
  rules: {
    cap_u_per_wallet_period: 50, token_share_cap_bps: 2000, creator_share_cap_bps: 3000, min_token_age_s: 3600, exclude_own_tokens: true,
    include_mints: false, quotes: [{ address: '0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c', symbol: 'WBNB' }, { address: '0x55d398326f99059ff775485246999027b3197955', symbol: 'USDT' }],
    pads: ['0x2bebed4be8c8f46c17776c71d7a6a45dbc5cab29'], agent_id: true, new_only: { before: now - 86400 }, mode: 'net_held', payout: 'end_only', price_source: 'settle_snapshot',
  },
  periods: [
    { id: 1, start: now - 86400, end: now, units: `500000${E18}`, status: 'frozen', published: null },
    { id: 2, start: now, end: now + 86400, units: `500000${E18}`, status: 'live', wallets: 7, published: null },
  ],
  current_period: 2, versions: [{ version: 1 }, { version: 2 }],
}
{
  assert.equal(isBuyReward(BUY), true); assert.equal(isBuyReward(CASH), false); assert.equal(isBuyReward(LIVE_T), false)
  assert.equal(kindOf(BUY), 'buy'); assert.equal(signUpOf(BUY), 'none'); assert.equal(noSignUp(BUY), true)
  assert.equal(hasCash(BUY), false); assert.equal(isCash(BUY), false); assert.equal(takesJoin(BUY), false)
  assert.equal(takesJoin({ ...BUY, tickets: { total: 1 }, rules: { ...BUY.rules, ticket: { join: true } } }), false, 'a buy-reward campaign never takes a sign-up')
  assert.equal(kindOf({ ...CASH, type: undefined }), 'cash', 'missing type = onboarding')
  assert.equal(noteFor(BUY), CAMPAIGN_NOTE_BUY)
  assert.match(CAMPAIGN_NOTE_BUY, /public, versioned rules/); assert.match(CAMPAIGN_NOTE_BUY, /not investment advice/)
  assert.match(CAMPAIGN_NOTE_BUY, /never trades only to earn campaign rewards, and never on its own/)
  assert.match(CAMPAIGN_NOTE_BUY, /user's decision, previewed and confirmed/); assert.match(CAMPAIGN_NOTE_BUY, /No sign-up/)
  assert.doesNotMatch(CAMPAIGN_NOTE_BUY, /campaign join|gang buy/)
  assert.equal(tokensOf(`1000000${E18}`, 18), '1000000'); assert.equal(tokensOf('1500000', 6), '1.5'); assert.equal(tokensOf('12', 0), '12')
  assert.equal(tokensOf(null, 18), null); assert.equal(tokensOf('1.5', 18), null); assert.equal(tokensOf('-1', 18), null)
  for (const d of [null, undefined, '', -1, 1.5, 'x']) assert.equal(tokensOf('1', d), null, `decimals ${d}: never guessed`)
  assert.equal(summary({ ...BUY, reward: { ...BUY.reward, decimals: null } }).reward.decimals, null)
  assert.equal(summary({ ...BUY, reward: { ...BUY.reward, decimals: null } }).reward.total, null)
  const r = buyRulesOf(BUY)
  assert.equal(r.mode, 'net_held'); assert.equal(r.includeMints, false); assert.equal(r.capUPerWalletPeriod, 50)
  assert.equal(r.tokenShareCapBps, 2000); assert.equal(r.creatorShareCapBps, 3000); assert.equal(r.minTokenAge, '1 h')
  assert.equal(r.excludeOwnTokens, true); assert.equal(r.agentId, true); assert.ok(r.newOnly.before); assert.equal(r.payout, 'end_only'); assert.equal(r.priceSource, 'settle_snapshot')
  assert.deepEqual(r.pads, [{ address: '0x2bebed4be8c8f46c17776c71d7a6a45dbc5cab29', name: 'GangLaunchpad 3.0' }])
  assert.deepEqual(r.quotes.map((q) => q.symbol), ['WBNB', 'USDT'])
  const t = r.text.join(' ')
  // end_only (the default): held at settlement after the campaign end; a sell any time before then takes it out
  assert.equal(r.counts, 'net buys on GangLaunchpad 3.0, paid in WBNB or USDT, still held at settlement after the campaign ends: a sell or transfer any time before then takes that amount back out')
  assert.doesNotMatch(r.counts, /mints|withdrawal|end of each period/, 'no mints: no withdrawals')
  assert.equal(buyRulesOf({ ...BUY, rules: { ...BUY.rules, payout: undefined } }).counts, r.counts, 'no payout key: end_only')
  const pp = buyRulesOf({ ...BUY, rules: { ...BUY.rules, include_mints: true, payout: 'per_period' } })
  assert.match(pp.counts, /^net buys and mints on .*, still held at the end of each period: a sell, transfer or withdrawal before then takes that amount back out$/)
  assert.match(t, /valued in U\. Prices: U values at the settlement snapshot's prices\./, 'price source in words')
  assert.equal(priceWords('pool_twap'), 'pool twap'); assert.equal(priceWords(''), null); assert.equal(priceWords(null), null)
  assert.match(t, /At most 50 U counted per wallet per period/)
  assert.match(t, /buyers of one token together earn at most 20% of a period's reward; buyers of all of one creator's tokens together at most 30%/)
  assert.match(t, /at least 1 h old/); assert.match(t, /own tokens .* do not count/); assert.match(t, /Agent ID/)
  assert.match(t, /paid once after the campaign ends/); assert.match(t, /New wallets only \(no Gang trade before \d{4}-/)
  const g = buyRulesOf({ ...BUY, rules: { ...BUY.rules, mode: 'gross_buys', include_mints: false, pads: null, quotes: [], min_token_age_s: 0, exclude_own_tokens: false, agent_id: false, new_only: { before: now - 86400 }, payout: 'per_period' } })
  assert.match(g.counts, /^buys on Gang, as made \(gross/); assert.doesNotMatch(g.counts, /mints|withdrawals/)
  assert.equal(g.pads, null); assert.equal(g.quotes, null); assert.equal(g.minTokenAge, null); assert.ok(g.newOnly.before)
  assert.match(g.text.join(' '), /New wallets only \(no Gang trade before \d{4}-/); assert.match(g.text.join(' '), /paid after each period/)
  assert.doesNotMatch(g.text.join(' '), /old\.|own tokens|Agent ID/)
  const s = summary(BUY)
  assert.equal(s.kind, 'buy'); assert.equal(s.type, 'buy_reward'); assert.equal(s.signUp, 'none'); assert.equal(s.title, 'Buy Week')
  assert.equal(s.notice, 'Period 2 is live.'); assert.equal(s.version, 2); assert.equal(s.currentPeriod, 2)
  assert.deepEqual(s.reward, { token: '0x000000000000000000000000000000000000beef', symbol: 'GANG', decimals: 18, total: '1000000', totalUnits: `1000000${E18}` })
  assert.deepEqual(s.rules, r); assert.equal(s.tickets, undefined); assert.equal(s.rewards, undefined)
  assert.deepEqual(s.periods.map((p) => [p.id, p.status, p.reward, p.wallets]), [[1, 'frozen', '500000', undefined], [2, 'live', '500000', 7]])
  assert.match(s.periods[0].start, /^\d{4}-\d\d-\d\d \d\d:\d\d UTC/, 'local times')
  // the wallet: counted U vs cap and an estimate before publishing; units and tx after (API shape: est_units a string,
  // '0' when none; estimate a boolean)
  const PUB = { ...BUY, periods: [{ ...BUY.periods[0], status: 'published', published: { at: now, payees: 2, units: `500000${E18}` } }, BUY.periods[1]] }
  const m = mineOf({ wallet: '0xa', type: 'buy_reward', status: 'eligible', reward: BUY.reward, updated_at: now, periods: [
    { id: 1, start: now - 86400, end: now, counted_u: 50, raw_u: 80, cap_u: 50, est_units: '0', estimate: false, units: `2000${E18}`, tx_hash: '0xt1' },
    { id: 2, start: now, end: now + 86400, counted_u: 12.5, raw_u: 12.5, cap_u: 50, est_units: '1234500000000000000000', estimate: true, units: null, tx_hash: null },
  ] }, PUB)
  assert.ok(m.updatedAt); assert.equal(m.estimateNote, estimateNoteOf(BUY))
  // the estimate note follows the rules: withdrawals only when mints count; gross_buys: sells do not lower it
  assert.match(estimateNoteOf(BUY), /can go down \(sells or transfers before settlement, other wallets' counted buys\)/)
  assert.doesNotMatch(estimateNoteOf(BUY), /withdraw/)
  assert.match(estimateNoteOf({ rules: { ...BUY.rules, include_mints: true } }), /\(sells, transfers or withdrawals before settlement, other wallets' counted buys\)/)
  assert.match(estimateNoteOf({ rules: { ...BUY.rules, mode: 'gross_buys' } }), /can go down \(other wallets' counted buys\)/)
  assert.doesNotMatch(estimateNoteOf({ rules: { ...BUY.rules, mode: 'gross_buys' } }), /sell|transfer|withdraw/)
  for (const x of [BUY, { rules: { mode: 'gross_buys' } }]) assert.match(estimateNoteOf(x), /current prices; the final count uses the settlement snapshot/)
  assert.equal(m.status, 'eligible'); assert.match(m.statusText, /^eligible/); assert.equal(m.symbol, 'GANG'); assert.equal(m.tickets, undefined)
  assert.deepEqual({ ...m.periods[0], start: undefined, end: undefined }, { id: 1, start: undefined, end: undefined, countedU: 50, rawU: 80, capU: 50, reward: '2000', units: `2000${E18}`, txHash: '0xt1' })
  assert.deepEqual({ ...m.periods[1], start: undefined, end: undefined }, { id: 2, start: undefined, end: undefined, countedU: 12.5, rawU: 12.5, capU: 50, estimatedReward: '1234.5', estimate: true })
  // published, but the wallet has no units in it: 0, never an estimate
  const z = mineOf({ wallet: '0xa', status: 'eligible', reward: BUY.reward, periods: [{ id: 1, counted_u: 3, cap_u: 50, est_units: `9${E18}`, estimate: true, units: null, tx_hash: null }] }, PUB)
  assert.deepEqual([z.periods[0].reward, z.periods[0].units, z.periods[0].why, z.periods[0].estimate, z.periods[0].estimatedReward], ['0', '0', 'no payout to this wallet in the published results', undefined, undefined])
  assert.equal(z.estimateNote, undefined)
  for (const st of ['not_new', 'not_agent', 'excluded', 'pending']) assert.ok(mineOf({ wallet: '0xa', status: st, periods: [] }, BUY).statusText, st)
  assert.match(mineOf({ wallet: '0xa', status: 'not_new', periods: [] }, BUY).statusText, /earns nothing/)
}

// --- the CLI against a fake gang.fun and a fake baw ---
const LIVE = {
  now, slug: 'agent-season', type: 'onboarding', title: { zh: '入帮季', en: 'Agent Season' }, status: 'live',
  window: { start: now - 3600, end: now + 86400 }, tickets: { total: 10, holders: 8, prizes_now: 1 }, lottery: { status: 'open' },
  rules: { ticket: { enabled: true, min_u: 0, join: true } },
}
let campaigns = { 'agent-season': LIVE }
let live = [{ slug: 'agent-season' }]
let walletRow = null
let payouts = null
let payoutReads = 0
let joinAnswer = { status: 200, body: { ok: true, wallet: acct.address.toLowerCase(), joined_at: now, tickets: 1 } }
const posted = []
const server = createServer((req, res) => {
  const url = new URL(req.url, 'http://x')
  const send = (code, body) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)) }
  if (req.method === 'GET' && url.pathname === '/api/campaigns') return send(200, { now, items: live })
  if (req.method === 'GET' && /^\/api\/campaigns\/[a-z0-9-]+\/payouts$/.test(url.pathname) && ++payoutReads) return payouts ? send(200, payouts) : send(404, { error: 'not_found' })
  let m = /^\/api\/campaigns\/([a-z0-9-]+)\/wallet\/(0x[0-9a-f]{40})$/.exec(url.pathname)
  if (req.method === 'GET' && m) return walletRow ? send(200, { wallet: m[2], ...walletRow }) : send(404, { error: 'not_found' })
  m = /^\/api\/campaigns\/([a-z0-9-]+)$/.exec(url.pathname)
  if (req.method === 'GET' && m) return campaigns[m[1]] ? send(200, campaigns[m[1]]) : send(404, { error: 'not_found' })
  m = /^\/api\/campaigns\/([a-z0-9-]+)\/join$/.exec(url.pathname)
  if (req.method === 'POST' && m) {
    let b = ''
    req.on('data', (c) => { b += c })
    req.on('end', () => { posted.push({ slug: m[1], body: JSON.parse(b) }); send(joinAnswer.status, joinAnswer.body) })
    return
  }
  send(404, { error: 'not_found' })
})
await new Promise((r) => server.listen(0, '127.0.0.1', r))
const base = `http://127.0.0.1:${server.address().port}`

// fake baw: signed in as the test key's address; sign-message preview stores the message, execute signs it like baw
const bin = join(dir, 'bin')
mkdirSync(bin)
const signer = join(dir, 'sign.mjs')
writeFileSync(signer, `import { readFileSync } from 'node:fs'
import { privateKeyToAccount } from ${JSON.stringify(fileURLToPath(new URL('../node_modules/viem/_esm/accounts/index.js', import.meta.url)))}
const m = JSON.parse(readFileSync(process.argv[2], 'utf8'))
const td = JSON.parse(m.params[1]); const { EIP712Domain, ...types } = td.types
const sig = await privateKeyToAccount(${JSON.stringify(KEY)}).signTypedData({ domain: td.domain, types, primaryType: td.primaryType, message: td.message })
console.log(JSON.stringify({ success: true, data: { orderId: 'o1', status: 'COMPLETED', signature: sig.slice(2, 130), signatureRecovery: sig.slice(130) === '1b' ? '00' : '01' } }))
`)
writeFileSync(join(bin, 'baw'), `#!/bin/sh
case "$1 $2" in
  "wallet status") echo '{"success":true,"data":{"status":"CONNECTED"}}' ;;
  "wallet address") echo '{"success":true,"data":{"addresses":[{"binanceChainId":"56","address":"${acct.address}"}]}}' ;;
  "sign-message preview") printf '%s' "$8" > "${dir}/msg.json"; echo '{"success":true,"data":{"requestId":"r1","requireConfirmation":false}}' ;;
  "sign-message execute") "${process.execPath}" "${signer}" "${dir}/msg.json" ;;
  *) echo '{"success":false,"error":{"message":"unexpected"}}'; exit 1 ;;
esac
`)
chmodSync(join(bin, 'baw'), 0o755)
const run = async (cliArgs, { withBaw = true } = {}) => {
  const env = {
    ...process.env, GANG_API: `${base}/api`, GANG_TELEMETRY: '0', GANG_UPDATE_CHECK: '0',
    PATH: withBaw ? `${bin}:/usr/bin:/bin` : '/usr/bin:/bin',
  }
  try { return JSON.parse((await promisify(execFile)(process.execPath, [CLI, ...cliArgs], { env, encoding: 'utf8' })).stdout) } catch (e) { return JSON.parse(e.stdout) }
}

try {
  // status: the only live campaign, signed out, then signed in with no row
  let r = await run(['campaign'], { withBaw: false })
  assert.equal(r.success, true)
  assert.equal(r.campaign.slug, 'agent-season')
  assert.equal(r.mine, undefined)
  assert.equal(r.next, 'gang campaign join agent-season')
  r = await run(['campaign', 'agent-season'])
  assert.equal(r.campaign.tickets.prizesNow, 1)
  r = await run(['campaign', 'Bad Slug'])
  assert.equal(r.success, false)
  r = await run(['campaign', 'AGENT-SEASON'])
  assert.equal(r.campaign.slug, 'agent-season', 'slugs are case-insensitive')
  r = await run(['campaign', 'agent-season', 'join'])
  assert.equal(r.success, false); assert.match(r.error, /unexpected "join"/)
  r = await run(['campaign', 'nope'])
  assert.equal(r.success, false); assert.match(r.error, /no campaign nope/)

  // join: signed out → refused; preview signs nothing; --yes signs and posts a signature the server can recover
  r = await run(['campaign', 'join'], { withBaw: false })
  assert.equal(r.success, false); assert.match(r.error, /sign in to baw/)
  r = await run(['campaign', 'join'])
  assert.equal(r.preview, true)
  assert.equal(r.join.wallet, acct.address.toLowerCase())
  assert.match(r.signs, /no transaction/)
  assert.equal(r.confirm, 'gang campaign join agent-season --yes', 'confirm names the campaign that was previewed')
  assert.equal(posted.length, 0, 'a preview sends nothing')
  r = await run(['campaign', 'join', 'agent-season', '--yes'])
  assert.equal(r.success, true, JSON.stringify(r))
  assert.equal(r.joined, true)
  assert.equal(r.tickets, 1)
  assert.equal(posted.length, 1)
  const p = posted[0]
  assert.equal(p.slug, 'agent-season')
  assert.equal(p.body.wallet, acct.address.toLowerCase())
  assert.ok(p.body.expires > now && p.body.expires <= now + 3600 + 60, 'expires within the hour the server takes')
  const td = joinTypedData(acct.address, 'agent-season', p.body.expires)
  const { EIP712Domain, ...types } = td.types
  assert.equal(await recoverTypedDataAddress({ domain: td.domain, types, primaryType: td.primaryType, message: td.message, signature: p.body.signature }), acct.address)

  // the server refuses: its code comes through
  joinAnswer = { status: 403, body: { error: 'not_agent', message: 'this wallet holds no Agent ID' } }
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.success, false); assert.equal(r.code, 'NO_AGENT_ID'); assert.equal(r.apiCode, 'not_agent')
  joinAnswer = { status: 409, body: { error: 'not_new', message: 'this wallet traded on Gang before the campaign' } }
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.success, false); assert.equal(r.apiCode, 'not_new')
  joinAnswer = { status: 400, body: { error: 'expired', message: 'signature expired' } }
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.success, false); assert.equal(r.retry, 'same command again', 'expired: running it again signs anew')
  joinAnswer = { status: 200, body: { ok: true, wallet: acct.address.toLowerCase(), joined_at: now, tickets: 0 } }
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.tickets, 0, 'a count of 0 is kept')

  // the wallet row says not_new: refused before anything is signed
  walletRow = { status: 'not_new', tickets: { base: 0, revisit: 0, invite: 2, total: 2 } }
  let n = posted.length
  r = await run(['campaign'])
  assert.equal(r.next, undefined, 'no sign-up hint for an old wallet')
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.success, false); assert.equal(r.apiCode, 'not_new'); assert.equal(posted.length, n)
  walletRow = { status: 'excluded', tickets: { base: 0, revisit: 0, invite: 0, total: 0 } }
  r = await run(['campaign'])
  assert.equal(r.next, undefined)
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.success, false); assert.equal(r.apiCode, 'not_eligible'); assert.equal(posted.length, n, 'nothing signed or sent')
  walletRow = null

  // sign-up closed by the campaign's config (rules.ticket.join = false): no hint, no signature, the notice comes through
  const NOTICE = 'Free sign-up is closed: the base ticket now comes from a first buy or mint on GANG 3.0.'
  campaigns = { 'agent-season': { ...LIVE, rules: { ticket: { enabled: true, join: false }, page: { notice_en: NOTICE } } } }
  r = await run(['campaign'], { withBaw: false })
  assert.equal(r.success, true)
  assert.equal(r.next, undefined, 'no next once the sign-up closed (and never one that points to a trade)')
  assert.equal(r.campaign.notice, NOTICE); assert.equal(r.campaign.signUp, 'closed')
  assert.equal(r.note, CAMPAIGN_NOTE_CLOSED)
  r = await run(['campaign'])
  assert.equal(r.next, undefined); assert.equal(r.note, CAMPAIGN_NOTE_CLOSED)
  for (const a of [['campaign', 'join'], ['campaign', 'join', '--yes']]) {
    r = await run(a)
    assert.equal(r.success, false); assert.equal(r.apiCode, 'closed'); assert.equal(r.code, 'ERROR')
    assert.match(r.error, /sign-up for agent-season is closed/); assert.match(r.error, /signed up earlier keep their ticket/)
    assert.match(r.error, /Nothing was signed or sent/); assert.match(r.error, /gang\.fun\/campaign\/agent-season/)
    assert.doesNotMatch(r.error, /GANG 3\.0/)
    assert.equal(r.preview, undefined); assert.equal(r.confirm, undefined, 'nothing to confirm or sign')
    assert.equal(r.campaign.notice, NOTICE)
    assert.equal(posted.length, n)
  }
  r = await run(['campaign', 'join'], { withBaw: false })
  assert.equal(r.apiCode, 'closed', 'closed is said before asking to sign in')
  // an earlier sign-up keeps its ticket
  walletRow = { status: 'entered', tickets: { base: 1, revisit: 0, invite: 0, total: 1 }, joined_at: now - 60 }
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.success, true); assert.equal(r.alreadyJoined, true); assert.equal(r.mine.tickets.base, 1); assert.equal(posted.length, n)
  // joined but excluded afterwards: not eligible, never alreadyJoined
  walletRow = { status: 'excluded', tickets: { base: 0, revisit: 0, invite: 0, total: 0 }, joined_at: now - 60 }
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.success, false); assert.equal(r.apiCode, 'not_eligible'); assert.equal(r.alreadyJoined, undefined); assert.equal(posted.length, n)
  walletRow = null
  campaigns = { 'agent-season': LIVE }

  // the server closed it after the CLI read the open config: 409 closed comes back as the same clear refusal
  joinAnswer = { status: 409, body: { error: 'closed', message: 'sign-up is closed' } }
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.success, false); assert.equal(r.apiCode, 'closed'); assert.equal(r.code, 'ERROR')
  assert.match(r.error, /sign-up for agent-season is closed/); assert.equal(r.retry, undefined)
  assert.match(r.error, /signed up earlier keep their ticket/); assert.match(r.error, /never trade only to earn campaign rewards or tickets/i)
  n = posted.length

  // already joined: no second signature; a base ticket from a trade is said in the preview
  walletRow = { status: 'none', tickets: { base: 1, revisit: 0, invite: 0, total: 1 }, joined_at: now }
  const before = posted.length
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.alreadyJoined, true); assert.equal(posted.length, before)
  walletRow = { status: 'entered', tickets: { base: 1, revisit: 0, invite: 0, total: 1 } }
  r = await run(['campaign', 'join'])
  assert.equal(r.alreadyHasBaseTicket, true)
  r = await run(['campaign'])
  assert.equal(r.mine.tickets.total, 1); assert.equal(r.next, undefined)

  // not live: no sign-up; a wallet that joined still reads alreadyJoined, an excluded one is refused
  campaigns = { 'agent-season': { ...LIVE, status: 'ended' } }
  walletRow = { status: 'entered', tickets: { base: 1, revisit: 0, invite: 0, total: 1 }, joined_at: now - 60 }
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.success, true); assert.equal(r.alreadyJoined, true)
  walletRow = { status: 'excluded', tickets: { base: 0, revisit: 0, invite: 0, total: 0 }, joined_at: now - 60 }
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.success, false); assert.equal(r.apiCode, 'not_eligible')
  walletRow = null
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.success, false); assert.match(r.error, /not open for sign-up/)
  // two live campaigns: status lists both; join without a slug takes the one whose sign-up is open
  const OPEN = (slug) => ({ ...LIVE, slug })
  const SHUT = (slug) => ({ ...LIVE, slug, rules: { ticket: { enabled: true, join: false } } })
  live = [{ slug: 'a' }, { slug: 'b' }]
  campaigns = { a: OPEN('a'), b: SHUT('b') }
  r = await run(['campaign'])
  assert.equal(r.success, true); assert.deepEqual(r.live.map((x) => x.slug), ['a', 'b'])
  assert.equal(r.note, CAMPAIGN_NOTE_LIST)
  n = posted.length
  r = await run(['campaign', 'join'])
  assert.equal(r.success, true, JSON.stringify(r)); assert.equal(r.preview, true)
  assert.equal(r.join.campaign, 'a'); assert.equal(r.confirm, 'gang campaign join a --yes')
  campaigns = { a: SHUT('a'), b: OPEN('b') }
  joinAnswer = { status: 200, body: { ok: true, wallet: acct.address.toLowerCase(), joined_at: now, tickets: 1 } }
  n = posted.length
  // --yes signs at once: with several live it needs the slug the preview's confirm named
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.success, false); assert.equal(r.code, 'USAGE'); assert.deepEqual(r.campaigns, ['b']); assert.equal(posted.length, n)
  r = await run(['campaign', 'join'])
  assert.equal(r.confirm, 'gang campaign join b --yes')
  r = await run(['campaign', 'join', 'b', '--yes'])
  assert.equal(r.success, true, JSON.stringify(r)); assert.equal(r.joined, true); assert.equal(posted.at(-1).slug, 'b')
  n = posted.length
  // both open: asks for one, listing only those that take a sign-up
  live = [{ slug: 'a' }, { slug: 'b' }, { slug: 'c' }]
  campaigns = { a: OPEN('a'), b: OPEN('b'), c: SHUT('c') }
  r = await run(['campaign', 'join'])
  assert.equal(r.success, false); assert.deepEqual(r.campaigns, ['a', 'b']); assert.match(r.error, /name one/)
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.success, false); assert.deepEqual(r.campaigns, ['a', 'b']); assert.equal(r.code, 'USAGE')
  assert.equal(posted.length, n, 'nothing signed or sent')
  // none open (one closed, one without tickets): says so, nothing signed
  live = [{ slug: 'a' }, { slug: 'b' }]
  campaigns = { a: SHUT('a'), b: { ...OPEN('b'), tickets: null } }
  r = await run(['campaign', 'join', '--yes'])
  assert.equal(r.success, false); assert.equal(r.apiCode, 'closed'); assert.deepEqual(r.campaigns, ['a', 'b'])
  assert.match(r.error, /no live gang\.fun campaign takes a free sign-up/); assert.match(r.error, /never trade only to earn campaign rewards or tickets/i)
  assert.equal(r.preview, undefined); assert.equal(posted.length, n)
  // one live campaign that takes no sign-up: the same refusal shape (apiCode closed, live slugs in campaigns)
  live = [{ slug: 'a' }]
  r = await run(['campaign', 'join'])
  assert.equal(r.success, false); assert.match(r.error, /sign-up for a is closed/)
  assert.equal(r.apiCode, 'closed'); assert.equal(r.code, 'ERROR'); assert.deepEqual(r.campaigns, ['a'])
  campaigns = { a: { ...OPEN('a'), rules: { ticket: { enabled: true } } } }
  r = await run(['campaign', 'join'])
  assert.equal(r.apiCode, 'closed', 'a config without ticket.join takes no sign-up'); assert.deepEqual(r.campaigns, ['a'])
  campaigns = { a: { ...OPEN('a'), tickets: null } }
  r = await run(['campaign', 'join'])
  assert.equal(r.success, false); assert.equal(r.apiCode, 'closed'); assert.deepEqual(r.campaigns, ['a'])
  assert.match(r.error, /no live gang\.fun campaign takes a free sign-up/); assert.equal(posted.length, n)
  // with a slug, no campaigns list
  r = await run(['campaign', 'join', 'a'])
  assert.equal(r.success, false); assert.equal(r.campaigns, undefined)
  campaigns = { 'agent-season': LIVE }
  // a campaign with cash rewards: status shows rewards and the wallet's cash progress; join signs nothing (no_signup)
  campaigns = { 'cash-one': CASH, a: OPEN('a') }
  live = [{ slug: 'cash-one' }]
  walletRow = { status: 'entered', slot: 3, amount_u: 2.5, earned_u: 1, paid: 0, revisit: { due_from: now + 86400, due_until: now + 7 * 86400, min_u: 0.95, done: false } }
  r = await run(['campaign'])
  assert.equal(r.success, true); assert.equal(r.campaign.kind, 'cash'); assert.equal(r.campaign.signUp, 'none')
  assert.equal(r.campaign.rewards.entry.minU, 1); assert.equal(r.mine.cash.slot, 3); assert.equal(r.mine.cash.asset, 'GANG')
  assert.equal(r.next, undefined, 'no sign-up hint for a cash campaign'); assert.equal(r.note, CAMPAIGN_NOTE_CASH)
  n = posted.length
  for (const a of [['campaign', 'join', 'cash-one'], ['campaign', 'join', 'cash-one', '--yes'], ['campaign', 'join']]) {
    r = await run(a)
    assert.equal(r.success, false); assert.equal(r.apiCode, 'no_signup'); assert.equal(r.code, 'ERROR')
    assert.match(r.error, /^this campaign has no sign-up \(cash-one\): counted trades are recorded automatically/); assert.match(r.error, /Nothing was signed or sent/)
    assert.match(r.error, /never trade only to earn campaign rewards or tickets/i); assert.doesNotMatch(r.error, /trading normally counts/)
    assert.doesNotMatch(r.error, /sign-up for .* is closed/, 'not the ticket campaign closed message')
    assert.equal(posted.length, n)
  }
  assert.deepEqual(r.campaigns, ['cash-one'], 'no slug: the live slugs listed')
  // the list: each row with its kind and sign-up
  live = [{ slug: 'cash-one' }, { slug: 'a' }]
  r = await run(['campaign'])
  assert.deepEqual(r.live.map((x) => [x.slug, x.kind, x.signUp]), [['cash-one', 'cash', 'none'], ['a', 'tickets', 'open']])
  // join without a slug skips the cash campaign
  walletRow = null
  r = await run(['campaign', 'join'])
  assert.equal(r.preview, true); assert.equal(r.join.campaign, 'a')
  // none takes a sign-up and one is a cash campaign: the refusal points to rewards or tickets
  campaigns = { 'cash-one': CASH, a: SHUT('a') }
  r = await run(['campaign', 'join'])
  assert.equal(r.apiCode, 'closed'); assert.match(r.error, /shows how its rewards or tickets work/)
  live = [{ slug: 'a' }, { slug: 'b' }]
  campaigns = { a: SHUT('a'), b: SHUT('b') }
  r = await run(['campaign', 'join'])
  assert.match(r.error, /shows how its tickets come/, 'ticket campaigns only: tickets wording')
  // a buy-reward campaign: summary, rules, the wallet's progress; never a next, and join signs nothing
  campaigns = { 'buy-week': BUY, a: OPEN('a') }
  live = [{ slug: 'buy-week' }]
  walletRow = null
  const okBuy = (x) => {
    assert.equal(x.success, true, JSON.stringify(x)); assert.equal(x.note, CAMPAIGN_NOTE_BUY); assert.equal(x.next, undefined, 'never a next (and never one to buy)')
    assert.equal(x.campaign.kind, 'buy'); assert.equal(x.campaign.signUp, 'none'); assert.equal(x.campaign.reward.total, '1000000')
  }
  r = await run(['campaign'], { withBaw: false })
  okBuy(r); assert.equal(r.mine, undefined); assert.equal(r.campaign.currentPeriod, 2); assert.equal(r.campaign.periods[1].wallets, 7)
  assert.match(r.campaign.rules.text.join(' '), /still held at settlement after the campaign ends: a sell or transfer any time before then/)
  walletRow = { type: 'buy_reward', status: 'eligible', reward: BUY.reward, periods: [
    { id: 1, start: now - 86400, end: now, counted_u: 20, raw_u: 20, cap_u: 50, est_units: `400${E18}`, estimate: true, units: null, tx_hash: null },
    { id: 2, start: now, end: now + 86400, counted_u: 50, raw_u: 75, cap_u: 50, est_units: `900${E18}`, estimate: true, units: null, tx_hash: null },
  ] }
  r = await run(['campaign', 'buy-week'])
  okBuy(r); assert.equal(r.mine.wallet, acct.address.toLowerCase()); assert.equal(r.mine.status, 'eligible'); assert.equal(r.mine.estimateNote, estimateNoteOf(BUY))
  assert.deepEqual(r.mine.periods.map((p) => [p.id, p.countedU, p.rawU, p.capU, p.estimatedReward, p.estimate, p.reward]), [[1, 20, 20, 50, '400', true, undefined], [2, 50, 75, 50, '900', true, undefined]])
  walletRow = { type: 'buy_reward', status: 'not_new', reward: BUY.reward, periods: [{ id: 2, counted_u: 0, raw_u: 30, cap_u: 50, est_units: '0', estimate: true, units: null, tx_hash: null }] }
  r = await run(['campaign', 'buy-week'])
  okBuy(r); assert.equal(r.mine.status, 'not_new'); assert.match(r.mine.statusText, /earns nothing/); assert.equal(r.mine.periods[0].estimatedReward, '0')
  assert.equal(payoutReads, 0, 'nothing published: the payout list is not read')
  // published: units and tx come from the wallet row (the payout list is never read)
  campaigns = { 'buy-week': { ...BUY, status: 'ended', current_period: null, periods: [{ ...BUY.periods[0], status: 'published', published: { at: now + 60, payees: 3, units: `500000${E18}` } }, { ...BUY.periods[1], status: 'live', wallets: undefined }] } }
  walletRow = { type: 'buy_reward', status: 'eligible', reward: BUY.reward, periods: [{ id: 1, counted_u: 20, raw_u: 20, cap_u: 50, est_units: '0', estimate: false, units: null, tx_hash: null }, { id: 2, counted_u: 5, cap_u: 50, est_units: `10${E18}`, estimate: true, units: null, tx_hash: null }] }
  payouts = { items: [{ period: 1, wallet: acct.address.toLowerCase(), units: `400${E18}`, amount: '400', tx_hash: '0xpaid' }] }
  walletRow.periods[0] = { ...walletRow.periods[0], units: `400${E18}`, tx_hash: '0xpaid' }
  r = await run(['campaign', 'buy-week'])
  assert.equal(r.success, true); assert.equal(r.next, undefined); assert.equal(r.note, CAMPAIGN_NOTE_BUY)
  assert.deepEqual(r.campaign.periods[0].published.reward, '500000'); assert.equal(r.campaign.periods[0].published.payees, 3)
  assert.equal(r.mine.periods[0].reward, '400'); assert.equal(r.mine.periods[0].txHash, '0xpaid'); assert.equal(r.mine.periods[0].estimate, undefined)
  assert.equal(r.mine.periods[1].estimatedReward, '10'); assert.equal(payoutReads, 0)
  walletRow = { ...walletRow, periods: [{ id: 1, counted_u: 20, cap_u: 50, est_units: '0', estimate: false, units: `401${E18}`, tx_hash: '0xrow' }] }
  r = await run(['campaign', 'buy-week'])
  assert.equal(r.mine.periods[0].reward, '401'); assert.equal(r.mine.periods[0].txHash, '0xrow', 'the wallet row is trusted')
  // published and the row has no units (even with a payout listed elsewhere): 0, not an estimate
  walletRow = { ...walletRow, periods: [{ id: 1, counted_u: 2, cap_u: 50, est_units: `5${E18}`, estimate: true, units: null, tx_hash: null }] }
  r = await run(['campaign', 'buy-week'])
  assert.equal(r.mine.periods[0].reward, '0'); assert.equal(r.mine.periods[0].why, 'no payout to this wallet in the published results'); assert.equal(r.mine.periods[0].estimate, undefined)
  assert.equal(payoutReads, 0, 'the payout list is never read')
  payouts = null
  // join: refused before anything is signed, with a slug, with --yes, and without a slug
  campaigns = { 'buy-week': BUY, a: OPEN('a') }
  n = posted.length
  for (const a of [['campaign', 'join', 'buy-week'], ['campaign', 'join', 'buy-week', '--yes'], ['campaign', 'join']]) {
    r = await run(a)
    assert.equal(r.success, false); assert.equal(r.apiCode, 'no_signup'); assert.equal(r.code, 'ERROR')
    assert.match(r.error, /^this campaign has no sign-up \(buy-week\)/); assert.match(r.error, /Nothing was signed or sent/)
    assert.match(r.error, /never trade only to earn campaign rewards or tickets/i); assert.equal(r.preview, undefined); assert.equal(r.confirm, undefined)
    assert.equal(r.note, CAMPAIGN_NOTE_BUY); assert.equal(posted.length, n)
  }
  // the list with mixed types: each row with its kind and sign-up; join without a slug skips the buy-reward campaign
  campaigns = { 'buy-week': BUY, 'cash-one': CASH, a: OPEN('a') }
  live = [{ slug: 'buy-week' }, { slug: 'cash-one' }, { slug: 'a' }]
  walletRow = null
  r = await run(['campaign'])
  assert.deepEqual(r.live.map((x) => [x.slug, x.kind, x.signUp]), [['buy-week', 'buy', 'none'], ['cash-one', 'cash', 'none'], ['a', 'tickets', 'open']])
  assert.equal(r.note, CAMPAIGN_NOTE_LIST)
  r = await run(['campaign', 'join'])
  assert.equal(r.preview, true); assert.equal(r.join.campaign, 'a')
  live = [{ slug: 'buy-week' }, { slug: 'b' }]
  campaigns = { 'buy-week': BUY, b: SHUT('b') }
  r = await run(['campaign', 'join'])
  assert.equal(r.apiCode, 'closed'); assert.match(r.error, /shows how its rewards or tickets work/); assert.equal(r.note, CAMPAIGN_NOTE_BUY); assert.equal(posted.length, n)

  live = []
  r = await run(['campaign'])
  assert.equal(r.success, true); assert.deepEqual(r.live, [])
  r = await run(['campaign', 'join'])
  assert.equal(r.success, false); assert.match(r.error, /no gang.fun campaign is live/)
} finally {
  server.close()
  rmSync(dir, { recursive: true, force: true })
}
console.log('campaign: ok')
