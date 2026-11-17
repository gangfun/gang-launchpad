import assert from 'node:assert/strict'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { countAgentBuyers, noteCurveBuyer, refreshAgentBuyers, seedBuyersFromTrades } from './agentBuyers.js'
import { openDb } from './db.js'

function fresh() {
  return openDb(join(mkdtempSync(join(tmpdir(), 'gang-ab-')), 't.db'))
}

function insertBuy(db, trader, ts, tx) {
  db.prepare(`
    INSERT INTO trades(token,side,trader,bnb,fee,tokens,real_bnb,price,block,ts,tx,log_index)
    VALUES('0xtok','buy',?,?, '0','1','1','1',1,?,?,0)
  `).run(trader, '1', ts, tx)
}

test('agentBuyers counts only checked Agent ID holders', async () => {
  const db = fresh()
  insertBuy(db, '0xabc', 100, '0xtx1')
  insertBuy(db, '0xagent', 120, '0xtx2')
  noteCurveBuyer(db, '0xABC', 50)
  assert.equal(countAgentBuyers(db), 0)

  const client = {
    async multicall({ contracts }) {
      return contracts.map((c) => ({
        status: 'success',
        result: String(c.args[0]).toLowerCase() === '0xagent' ? 1n : 0n,
      }))
    },
  }
  const n = await refreshAgentBuyers(db, client, { log() {} })
  assert.ok(n >= 2)
  assert.equal(countAgentBuyers(db), 1)

  const earliest = db.prepare('SELECT first_buy_ts FROM curve_buyers WHERE address=?').get('0xabc')
  assert.equal(earliest.first_buy_ts, 50)

  seedBuyersFromTrades(db)
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM curve_buyers').get().n, 2)
})

test('refresh drops wallets that no longer hold an Agent ID', async () => {
  const db = fresh()
  const now = Math.floor(Date.now() / 1000)
  db.prepare('INSERT INTO curve_buyers(address, is_agent, checked_ts, first_buy_ts) VALUES(?,?,?,?)')
    .run('0xagent', 1, now - 1000, 10)
  const client = {
    async multicall() {
      return [{ status: 'success', result: 0n }]
    },
  }
  await refreshAgentBuyers(db, client, { log() {}, maxAgeSec: 3600 })
  assert.equal(countAgentBuyers(db), 0)
})
