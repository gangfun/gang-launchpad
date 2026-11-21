/**
 * gang buy|sell --handoff and gang handoff status (handoff.js) with a mocked chain: the link the page's parser takes,
 * the QR code round-trips, only open agent-window curve tokens on the built-in 3.0 pad, the wallet's checks, the
 * quote, and the read-only watch for the user's trade. Nothing is signed anywhere.
 *
 *   node skill/gang-cli/test/handoff.mjs
 */
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import qrcode from 'qrcode-generator'

const DIR = mkdtempSync(join(tmpdir(), 'gang-handoff-'))
process.env.GANG_HANDOFF_DIR = DIR
const h = await import('../src/handoff.js')
const CLI = fileURLToPath(new URL('../src/index.js', import.meta.url))

const TOKEN = '0x3333333333333333333333333333333333333333'
const QUOTE = '0x5555555555555555555555555555555555555555'
const WBNB = '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c'
const ME = '0x1111111111111111111111111111111111111111'
const ROUTER = '0xec9717E5C68b9F18fA76D3961C9Cd7e67b5E61e7'
const PAD = h.handoffPad()
const Z = '0x0000000000000000000000000000000000000000'
const E18 = 10n ** 18n
const NOW = 2_000_000_000

const throwsCode = async (fn, code, re) => {
  let err
  try { await fn() } catch (e) { err = e }
  assert.ok(err, `expected ${code}`)
  assert.equal(err.code, code, err.message)
  if (re) assert.match(err.message, re)
  return err
}

// a mocked BSC: the 3.0 pad's views, ERC-20s, logs and txs
const chain = () => ({
  creator: ME, quote: QUOTE, graduated: false, version: 3, openAt: NOW - 60, canTrade: true,
  buy: { out: 1000n * E18, spent: E18 / 2n, fee: E18 / 200n, quote: QUOTE }, sell: { out: E18 / 4n, fee: E18 / 400n, quote: QUOTE },
  balances: {}, native: 0n, block: 100n, logs: [], getLogs: [],
})
let c = chain()
const read = {
  readContract: async ({ address, functionName, args }) => {
    if (address.toLowerCase() === PAD.toLowerCase()) {
      if (functionName === 'curves') return [c.creator, c.quote, 0n, 0n, 0n, 0n, c.graduated, 0, 0, 0, Z, Z]
      if (functionName === 'tokenVersionOf') return c.version
      if (functionName === 'agentOpenAt') return c.openAt
      if (functionName === 'canTradeCurve') return c.canTrade
      if (functionName === 'tryBuy') return [Z, c.buy.quote, c.buy.out, c.buy.spent, c.buy.fee, 0n, 0n, args[3]]
      if (functionName === 'trySell') return [Z, c.sell.quote, c.sell.out, c.sell.fee]
    }
    if (functionName === 'decimals') return 18
    if (functionName === 'symbol') return address.toLowerCase() === TOKEN.toLowerCase() ? 'TOK' : 'ANTB'
    if (functionName === 'balanceOf') return c.balances[`${address.toLowerCase()}:${args[0].toLowerCase()}`] ?? 0n
    throw new Error(`unexpected ${functionName}`)
  },
  getBalance: async () => c.native,
  getBlockNumber: async () => c.block,
  // filters by the indexed args it is given, like a node; counts the calls
  getLogs: async ({ event, args, fromBlock, toBlock }) => {
    c.getLogs.push([event.name, fromBlock, toBlock])
    return c.logs.filter((l) => l.eventName === event.name && l.blockNumber >= fromBlock && l.blockNumber <= toBlock
      && Object.entries(args ?? {}).every(([k, v]) => String(l.args[k]).toLowerCase() === String(v).toLowerCase()))
  },
}
const bal = (token, who, v) => { c.balances[`${token.toLowerCase()}:${who.toLowerCase()}`] = v }
const B = (o) => h.buildHandoff({ read, now: () => NOW, token: TOKEN, ...o })

try {
  // --- the link: canonical amounts the page's parser takes (plain decimal, ≤ 13 + 18 digits, > 0, ≤ 1e12)
  assert.equal(h.linkAmount('.5', 18).text, '0.5')
  assert.equal(h.linkAmount('0.050', 18).text, '0.05')
  assert.equal(h.linkAmount(' 7 ', 6).units, 7_000_000n)
  // more decimals than the token has: refused, never rounded (trailing zeros are fine)
  assert.equal(h.linkAmount('0.1234560', 6).text, '0.123456')
  for (const bad of ['0', '1e3', '-1', 'abc', '0x10', '1,5', '', '1000000000001', '0.0000001', '0.1234567']) {
    await throwsCode(() => h.linkAmount(bad, 6), 'USAGE')
  }
  assert.equal(h.tradeLink({ token: TOKEN.toLowerCase(), side: 'buy', amount: '0.05', from: ME }),
    `https://gang.fun/token/${TOKEN}?trade=buy&amount=0.05&from=${ME}`)
  assert.equal(h.tradeLink({ token: TOKEN, side: 'sell', amount: 'all' }), `https://gang.fun/token/${TOKEN}?trade=sell&amount=all`)

  // --- the QR text is that link: read back from the half blocks, every module matches the generator's
  const link = h.tradeLink({ token: TOKEN, side: 'buy', amount: '0.05', from: ME })
  const text = await h.qrText(link)
  const q = qrcode(0, 'M'); q.addData(link, 'Byte'); q.make()
  const n = q.getModuleCount(), pad = 4
  const rows = text.split('\n')
  assert.equal(rows.length, Math.ceil((n + 2 * pad) / 2))
  assert.equal(rows[0], '█'.repeat(n + 2 * pad), 'a light quiet zone of 4 modules')
  for (let r = -pad; r < n + pad; r++) {
    for (let col = -pad; col < n + pad; col++) {
      const ch = rows[Math.floor((r + pad) / 2)][col + pad]
      const top = (r + pad) % 2 === 0
      const lightHere = top ? (ch === '█' || ch === '▀') : (ch === '█' || ch === '▄')
      const want = r < 0 || col < 0 || r >= n || col >= n ? true : !q.isDark(r, col)
      assert.equal(lightHere, want, `module ${r},${col}`)
    }
  }

  // --- only what the page's box serves
  c = { ...chain(), creator: Z }
  await throwsCode(() => B({ side: 'buy', amount: '0.5' }), 'HANDOFF_NOT_SERVED', /not on that pad/)
  c = { ...chain(), graduated: true }
  await throwsCode(() => B({ side: 'buy', amount: '0.5' }), 'HANDOFF_NOT_SERVED', /graduated.*any DEX/)
  c = { ...chain(), openAt: 0 }
  await throwsCode(() => B({ side: 'buy', amount: '0.5' }), 'HANDOFF_NOT_SERVED', /agent only.*Agentic Wallet/)
  c = { ...chain(), openAt: NOW + 600 }
  const notOpen = await throwsCode(() => B({ side: 'buy', amount: '0.5' }), 'HANDOFF_NOT_SERVED', /agent only until/)
  assert.equal(notOpen.extra.why, 'not_open')
  c = { ...chain(), canTrade: false }
  await throwsCode(() => B({ side: 'buy', amount: '0.5', from: ME }), 'HANDOFF_NOT_SERVED', /can't trade this token/)
  c = { ...chain(), buy: { ...chain().buy, out: 0n } }
  await throwsCode(() => B({ side: 'buy', amount: '0.5' }), 'HANDOFF_NOT_SERVED', /would not fill/)
  c = { ...chain(), buy: { ...chain().buy, quote: WBNB } }
  await throwsCode(() => B({ side: 'buy', amount: '0.5' }), 'ERROR', /another quote/)

  // --- a buy: quoted at the page's 3%, the wallet's balance checked, the start of the watch kept
  c = chain()
  await throwsCode(() => B({ side: 'buy', amount: '0.5', from: ME }), 'NO_FUNDS')
  bal(QUOTE, ME, E18)
  c.block = 500n
  const r = await B({ side: 'buy', amount: '0.5', from: ME })
  assert.equal(r.success, true)
  assert.equal(r.signed, false)
  assert.equal(r.link, `https://gang.fun/token/${TOKEN}?trade=buy&amount=0.5&from=${ME}`)
  assert.ok(r.qr.includes('█'))
  assert.deepEqual([r.quoted.expectTokens, r.quoted.minTokensOut, r.quoted.slippagePct], ['1000', '970', 3])
  assert.equal(r.funds.have, '1')
  assert.equal(r.sinceBlock, 500)
  assert.match(r.note, /Do not say it happened until gang handoff status/)
  assert.match(r.steps[0], /币安 App → Web3 钱包 → 发现/)
  assert.equal(r.next, `gang handoff status --token ${TOKEN} --from ${ME} [--timeout 10m]`)
  assert.equal(r.quoted.refund, undefined)
  // a buy that graduates the token spends less: the refund is said
  c.buy = { ...c.buy, spent: E18 / 4n }
  assert.equal((await B({ side: 'buy', amount: '0.5', from: ME })).quoted.refund, '0.25')
  c = chain()
  bal(QUOTE, ME, E18)
  // a WBNB-quoted token is paid in BNB (and its gas)
  c = { ...chain(), quote: WBNB, buy: { ...chain().buy, quote: Z } }
  c.native = E18 / 2n
  await throwsCode(() => B({ side: 'buy', amount: '0.5', from: ME }), 'NO_FUNDS', /BNB must also cover gas/)
  c.native = E18
  assert.equal((await B({ side: 'buy', amount: '0.5', from: ME })).quoteSymbol, 'BNB')
  await throwsCode(() => B({ side: 'buy', all: true }), 'USAGE')

  // --- a sell: --amount or --all, within the balance
  c = chain()
  await throwsCode(() => B({ side: 'sell' }), 'USAGE')
  await throwsCode(() => B({ side: 'sell', all: true, amount: '1' }), 'USAGE')
  await throwsCode(() => B({ side: 'sell', amount: '5', from: ME }), 'NO_FUNDS')
  bal(TOKEN, ME, 10n * E18)
  const s = await B({ side: 'sell', amount: '5', from: ME })
  assert.equal(s.link, `https://gang.fun/token/${TOKEN}?trade=sell&amount=5&from=${ME}`)
  assert.deepEqual([s.quoted.expectOut, s.quoted.minOut], ['0.25', '0.2425'])
  assert.equal((await B({ side: 'sell', all: true, from: ME })).quoted.amount, '10')
  const anon = await B({ side: 'sell', all: true })
  assert.equal(anon.link, `https://gang.fun/token/${TOKEN}?trade=sell&amount=all`)
  assert.match(anon.quoted.note, /pass --from/)

  // --- the watch: the wallet's trades since the handoff, by the events' indexed token and trader (on 3.0 the trader is
  // always the tx sender, router-paid buys included)
  c = chain()
  bal(TOKEN, ME, 0n)
  c.block = 1000n
  bal(QUOTE, ME, E18)
  await B({ side: 'buy', amount: '0.5', from: ME })
  let st = await h.handoffStatus({ read, token: TOKEN, from: ME })
  assert.deepEqual([st.traded, st.sinceBlock], [false, 1000])
  assert.match(st.note, /no trade by this wallet yet/)
  // someone else's trade, and ours from before the handoff, don't count
  c.logs.push({ eventName: 'Buy', blockNumber: 1001n, transactionHash: '0xaa', args: { token: TOKEN, buyer: '0x9999999999999999999999999999999999999999', tokensOut: 1n } })
  c.logs.push({ eventName: 'Buy', blockNumber: 999n, transactionHash: '0xbb', args: { token: TOKEN, buyer: ME, tokensOut: 1n } })
  c.block = 1002n
  assert.equal((await h.handoffStatus({ read, token: TOKEN, from: ME })).traded, false)
  // ours (a Buy and its TradeV1 in the same tx count once)
  c.logs.push({ eventName: 'Buy', blockNumber: 1002n, transactionHash: '0xcc', args: { token: TOKEN, buyer: ME, quoteIn: 5n, tokensOut: 7n } })
  c.logs.push({ eventName: 'TradeV1', blockNumber: 1002n, transactionHash: '0xcc', args: { token: TOKEN, trader: ME, isBuy: true, quoteAmount: 5n, tokenAmount: 7n } })
  st = await h.handoffStatus({ read, token: TOKEN, from: ME })
  assert.equal(st.traded, true)
  assert.deepEqual(st.trades.map((t) => [t.side, t.txHash, t.block, t.quoteAmountRaw, t.tokenAmountRaw]), [['buy', '0xcc', 1002, '5', '7']])
  assert.match(st.next, /gang tx --hash 0xcc/)
  // a TradeV1 sell counts too
  c.logs.push({ eventName: 'TradeV1', blockNumber: 1002n, transactionHash: '0xdd', args: { token: TOKEN, trader: ME, isBuy: false, quoteAmount: 3n, tokenAmount: 4n } })
  assert.ok((await h.handoffStatus({ read, token: TOKEN, from: ME })).trades.some((t) => t.side === 'sell' && t.txHash === '0xdd'))
  // waiting: each round scans only the new blocks, and it stops once the trade shows
  c.logs = []
  c.getLogs = []
  let polls = 0
  const waited = h.handoffStatus({ read, token: TOKEN, from: ME, timeoutS: 60, pollMs: 1, sleep: async () => {
    polls += 1
    c.block += 1n
    if (polls === 3) c.logs.push({ eventName: 'Sell', blockNumber: c.block, transactionHash: '0xee', args: { token: TOKEN, seller: ME, tokensIn: 1n, quoteOut: 1n } })
  } })
  const w = await waited
  assert.equal(w.traded, true)
  assert.equal(polls, 3)
  const ranges = c.getLogs.filter(([name]) => name === 'Sell').map(([, a, b]) => [Number(a), Number(b)])
  assert.deepEqual(ranges, [[1000, 1002], [1003, 1003], [1004, 1004], [1005, 1005]], 'no rescans')
  // the start and balance can come from the caller (--wait), not the record
  assert.equal((await h.handoffStatus({ read, token: TOKEN, from: ME, since: 1005n, balanceAtHandoff: '0' })).sinceBlock, 1005)
  // a balance change with no log found is said, not claimed as a trade
  c.logs = []
  bal(TOKEN, ME, 5n)
  st = await h.handoffStatus({ read, token: TOKEN, from: ME })
  assert.deepEqual([st.traded, st.balanceChanged], [false, true])
  assert.match(st.note, /balance changed/)
  // a record over a day old is not used: an old trade would look like this one
  await throwsCode(() => h.handoffStatus({ read, token: TOKEN, from: ME, now: () => Date.now() + 25 * 3600_000 }), 'USAGE', /over a day old/)
  // needs the wallet; and a start: the handoff's record or --since
  await throwsCode(() => h.handoffStatus({ read, token: TOKEN }), 'USAGE', /--from/)
  await throwsCode(() => h.handoffStatus({ read, token: TOKEN, from: '0x2222222222222222222222222222222222222222' }), 'USAGE', /--since/)
  assert.equal((await h.handoffStatus({ read, token: TOKEN, from: '0x2222222222222222222222222222222222222222', since: 1000n })).sinceBlock, 1000)

  // --- CLI: what a handoff refuses, before any read
  const env = { ...process.env, GANG_TELEMETRY: '0', GANG_UPDATE_CHECK: '0', GANG_API: 'http://127.0.0.1:1/api', GANG_RPC_URL: 'http://127.0.0.1:1', PATH: '/usr/bin:/bin' }
  const run = (...argv) => { const x = spawnSync(process.execPath, [CLI, ...argv], { env, encoding: 'utf8', timeout: 15_000 }); return { status: x.status, out: JSON.parse(x.stdout) } }
  for (const [f, re] of [[['--note', 'hi'], /sends no note/], [['--slippage', '2'], /slippage itself/], [['--testnet'], /mainnet only/], [['--calldata'], /builds no tx/], [['--ref', ME], /no invite tag/], [['--promoter', ME], /promoter binding/]]) {
    const x = run('buy', '--token', TOKEN, '--amount', '1', '--handoff', ...f)
    assert.equal(x.status, 1, f[0])
    assert.match(x.out.error, re, f[0])
  }
  assert.match(run('buy', '--token', TOKEN, '--amount', '1', '--handoff', '--wait').out.error, /--wait needs --from/)
  assert.equal(run('handoff').out.code, 'USAGE')
  assert.equal(run('handoff', 'status', '--token', TOKEN, '--from', ME, '--since', 'x').out.code, 'USAGE')
  assert.match(run('handoff', 'status', '--token', TOKEN, '--from', ME, '--timeout', '2h').out.error, /at most 30m/)
  console.log('handoff: ok')
} finally {
  rmSync(DIR, { recursive: true, force: true })
}
