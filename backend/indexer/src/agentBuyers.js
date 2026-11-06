import { parseAbi } from 'viem'
import { AGENT_ID } from './handles.js'

const AGENT_ABI = parseAbi(['function balanceOf(address account) view returns (uint256)'])

export function seedBuyersFromTrades(db) {
  db.prepare(`
    INSERT OR IGNORE INTO curve_buyers(address, first_buy_ts)
    SELECT trader, MIN(ts) FROM trades WHERE side='buy' GROUP BY trader
  `).run()
}

export function noteCurveBuyer(db, address, ts) {
  if (!address) return
  const a = address.toLowerCase()
  db.prepare(`
    INSERT INTO curve_buyers(address, first_buy_ts) VALUES(?,?)
    ON CONFLICT(address) DO UPDATE SET
      first_buy_ts=CASE WHEN excluded.first_buy_ts < curve_buyers.first_buy_ts OR curve_buyers.first_buy_ts IS NULL
        THEN excluded.first_buy_ts ELSE curve_buyers.first_buy_ts END
  `).run(a, ts)
}

export function countAgentBuyers(db) {
  return Number(db.prepare('SELECT COUNT(*) AS n FROM curve_buyers WHERE is_agent=1').get()?.n || 0)
}

/**
 * Mark curve buyers as agents when SPACE ID registry balanceOf > 0 (same as Launchpad isAgent).
 * Re-checks stale rows so wallets that transfer their Agent ID drop out of the count.
 */
export async function refreshAgentBuyers(db, client, { limit = 80, maxAgeSec = 3600, log = console.log } = {}) {
  seedBuyersFromTrades(db)
  const now = Math.floor(Date.now() / 1000)
  const cutoff = now - maxAgeSec
  const agentRecheck = now - 600
  const need = db.prepare(`
    SELECT address FROM curve_buyers
    WHERE checked_ts < CASE WHEN is_agent=1 THEN ? ELSE ? END
    ORDER BY checked_ts ASC
    LIMIT ?
  `).all(agentRecheck, cutoff, limit).map((r) => r.address)
  if (!need.length) return 0

  const upd = db.prepare('UPDATE curve_buyers SET is_agent=?, checked_ts=? WHERE address=?')
  try {
    const results = await client.multicall({
      contracts: need.map((address) => ({
        address: AGENT_ID,
        abi: AGENT_ABI,
        functionName: 'balanceOf',
        args: [address],
      })),
      allowFailure: true,
    })
    let agents = 0
    for (let i = 0; i < need.length; i++) {
      const r = results[i]
      const isAgent = r.status === 'success' && r.result > 0n ? 1 : 0
      upd.run(isAgent, now, need[i])
      if (isAgent) agents++
    }
    if (need.length) log(`agent buyers: checked ${need.length}, agents ${agents}, total ${countAgentBuyers(db)}`)
  } catch (e) {
    log('agent buyer multicall failed:', e.message)
  }
  return need.length
}
