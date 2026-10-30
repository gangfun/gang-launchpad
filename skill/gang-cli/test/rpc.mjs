/**
 * The RPC node list (gangpad.js rpcTransport / rpcList) against local fake nodes: a rate-limited node, a hung one, a
 * working one. No chain.
 *
 *   node skill/gang-cli/test/rpc.mjs
 */
import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { createPublicClient, parseAbi } from 'viem'
import { bsc } from 'viem/chains'
import { MAINNET_RPCS, TESTNET_RPCS, padNets, rpcList, rpcTransport } from '../src/gangpad.js'

// a fake node: answer(body) → [status, json] or null to hang; counts the requests it got
const hits = {}
const servers = []
async function node(name, answer) {
  hits[name] = 0
  const s = createServer((req, res) => {
    let raw = ''
    req.on('data', (c) => (raw += c))
    req.on('end', () => {
      hits[name]++
      const body = JSON.parse(raw)
      const a = answer(body)
      if (!a) return // hung: never answers
      res.writeHead(a[0], { 'content-type': 'application/json' })
      res.end(JSON.stringify({ jsonrpc: '2.0', id: body.id, ...a[1] }))
    })
  })
  await new Promise((r) => s.listen(0, '127.0.0.1', r))
  servers.push(s)
  return `http://127.0.0.1:${s.address().port}`
}
const ok = (body) => [200, body.method === 'eth_call'
  ? { error: { code: 3, message: 'execution reverted: 0x', data: '0x' } }
  : { result: '0x10' }]

try {
  const limited = await node('limited', () => [429, { error: { code: -32005, message: 'rate limited' } }])
  const hung = await node('hung', () => null)
  const good = await node('good', ok)
  const good2 = await node('good2', ok)

  // rate-limited first: the call moves on to the good node, and the next call starts there (the limited node is not asked again)
  {
    const c = createPublicClient({ chain: bsc, transport: rpcTransport([limited, good, good2]) })
    assert.equal(await c.getBlockNumber({ cacheTime: 0 }), 16n)
    assert.equal(hits.limited, 1)
    assert.equal(hits.good, 1)
    assert.equal(await c.getBlockNumber({ cacheTime: 0 }), 16n)
    assert.equal(hits.limited, 1)
    assert.equal(hits.good, 2)
    assert.equal(hits.good2, 0)
    // a revert is the contract's answer: thrown from the node that gave it, the next node is not asked
    await assert.rejects(c.readContract({ address: '0x0000000000000000000000000000000000000001', abi: parseAbi(['function f() view returns (uint8)']), functionName: 'f' }), /reverted/)
    assert.equal(hits.good, 3)
    assert.equal(hits.good2, 0)
    // another client on the same list starts at the node that answered last
    const c2 = createPublicClient({ chain: bsc, transport: rpcTransport([limited, good, good2]) })
    await c2.getBlockNumber({ cacheTime: 0 })
    assert.equal(hits.limited, 1)
  }

  // hung first: one timeout (8 s), then the good node
  {
    const c = createPublicClient({ chain: bsc, transport: rpcTransport([hung, good2]) })
    const t = Date.now()
    assert.equal(await c.getBlockNumber({ cacheTime: 0 }), 16n)
    assert.ok(Date.now() - t >= 7_500 && Date.now() - t < 12_000, `took ${Date.now() - t} ms`)
    assert.equal(hits.hung, 1)
    const t2 = Date.now()
    await c.getBlockNumber({ cacheTime: 0 })
    assert.ok(Date.now() - t2 < 1_000)
    assert.equal(hits.hung, 1)
  }

  // every node down: the last node's error comes out (after one retry of the whole list)
  {
    const before = hits.limited
    const c = createPublicClient({ chain: bsc, transport: rpcTransport([limited, limited]) })
    await assert.rejects(c.getBlockNumber({ cacheTime: 0 }), /rate limited|429|HTTP request failed/i)
    assert.equal(hits.limited - before, 4)
  }

  // one URL: plain viem http (its own retries, no list)
  {
    const t = rpcTransport([good])({ chain: bsc })
    assert.equal(t.config.type, 'http')
  }

  // the variables: one URL or a comma list replaces the public nodes; unset / empty keeps them
  {
    assert.equal(rpcList(undefined), null)
    assert.equal(rpcList(' , '), null)
    assert.deepEqual(rpcList('https://a.example, https://b.example,'), ['https://a.example', 'https://b.example'])
    const keep = { ...process.env }
    try {
      delete process.env.GANG_RPC_URL
      delete process.env.GANG_TESTNET_RPC_URL
      assert.deepEqual(padNets('v3').mainnet.rpcs, MAINNET_RPCS)
      assert.deepEqual(padNets('fair').testnet.rpcs, TESTNET_RPCS)
      process.env.GANG_RPC_URL = 'https://mine.example'
      process.env.GANG_FAIR_TESTNET_RPC_URL = 'https://t1.example,https://t2.example'
      assert.deepEqual(padNets('v3').mainnet.rpcs, ['https://mine.example'])
      assert.deepEqual(padNets('fair').testnet.rpcs, ['https://t1.example', 'https://t2.example'])
    } finally {
      process.env = keep
    }
  }
} finally {
  for (const s of servers) s.closeAllConnections?.(), s.close()
}
console.log('rpc: ok')
