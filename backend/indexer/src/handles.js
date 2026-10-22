import { createPublicClient, http, fallback, parseAbi } from 'viem'
import { bsc, bscTestnet } from 'viem/chains'

export const AGENT_ID = '0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F'
const HANDLE_ABI = parseAbi(['function handleOf(address account) view returns (string)'])

export function makeClient(rpcUrls) {
  const urls = (rpcUrls && rpcUrls.length ? rpcUrls : ['https://bsc-rpc.publicnode.com', 'https://bsc.publicnode.com']).filter(Boolean)
  const transport = urls.length > 1
    ? fallback(urls.map((u) => http(u, { retryCount: 2, retryDelay: 800 })), { rank: true, retryCount: 3 })
    : http(urls[0], { retryCount: 3, retryDelay: 800 })
  return createPublicClient({ chain: bsc, transport })
}

/** Chapel / BSC testnet client for stocks pair OHLCV. */
export function makeStocksClient(rpcUrls) {
  const urls = (rpcUrls && rpcUrls.length ? rpcUrls : [
    'https://bsc-testnet-rpc.publicnode.com',
    'https://data-seed-prebsc-1-s1.binance.org:8545',
  ]).filter(Boolean)
  const transport = urls.length > 1
    ? fallback(urls.map((u) => http(u, { retryCount: 2, retryDelay: 800, timeout: 20_000 })), { rank: false })
    : http(urls[0], { retryCount: 3, retryDelay: 800, timeout: 20_000 })
  return createPublicClient({ chain: bscTestnet, transport })
}

/** Display form: on-chain handle is bare ("lazy"); UI shows "lazy.ai". */
export function displayHandle(raw) {
  if (!raw) return null
  const h = String(raw).trim()
  if (!h) return null
  return h.includes('.') ? h : `${h}.ai`
}

export function getHandleMap(db, addrs) {
  const uniq = [...new Set((addrs || []).filter(Boolean).map((a) => a.toLowerCase()))]
  if (!uniq.length) return {}
  const out = {}
  const stmt = db.prepare('SELECT address, handle FROM handles WHERE address=?')
  for (const a of uniq) {
    const row = stmt.get(a)
    if (row && row.handle) out[a] = displayHandle(row.handle)
  }
  return out
}

/** Resolve missing / stale handles in background. Never throws to caller. */
export async function refreshHandles(db, client, { limit = 40, maxAgeSec = 86400, log = console.log } = {}) {
  const now = Math.floor(Date.now() / 1000)
  const cutoff = now - maxAgeSec
  // Prefer addresses we actually show: creators, recent traders, holders.
  // Collect candidates then filter in JS (sqlite UNION + ORDER BY is awkward).
  const candidates = new Set()
  for (const r of db.prepare('SELECT lower(creator) AS a FROM tokens WHERE creator IS NOT NULL').all()) if (r.a) candidates.add(r.a)
  for (const r of db.prepare('SELECT lower(trader) AS a FROM trades ORDER BY id DESC LIMIT 800').all()) if (r.a) candidates.add(r.a)
  for (const r of db.prepare("SELECT lower(holder) AS a FROM holders WHERE balance!='0'").all()) if (r.a) candidates.add(r.a)
  const fresh = new Set(db.prepare('SELECT address FROM handles WHERE checked_ts > ?').all(cutoff).map((r) => r.address))
  const need = [...candidates].filter((a) => a && !a.startsWith('0x0000000000000000000000000000000000000000') && !fresh.has(a)).slice(0, limit)
  if (!need.length) return 0

  const upsert = db.prepare(
    'INSERT INTO handles(address, handle, checked_ts) VALUES(?,?,?) ON CONFLICT(address) DO UPDATE SET handle=excluded.handle, checked_ts=excluded.checked_ts',
  )
  let ok = 0
  // Batch via multicall (viem); fall back to serial on failure.
  try {
    const results = await client.multicall({
      contracts: need.map((address) => ({
        address: AGENT_ID,
        abi: HANDLE_ABI,
        functionName: 'handleOf',
        args: [address],
      })),
      allowFailure: true,
    })
    for (let i = 0; i < need.length; i++) {
      const r = results[i]
      const handle = r.status === 'success' && typeof r.result === 'string' ? r.result.trim() : ''
      upsert.run(need[i], handle, now)
      if (handle) ok++
    }
  } catch (e) {
    log('handle multicall failed, serial:', e.message)
    for (const address of need) {
      try {
        const handle = (await client.readContract({
          address: AGENT_ID, abi: HANDLE_ABI, functionName: 'handleOf', args: [address],
        }) || '').trim()
        upsert.run(address, handle, now)
        if (handle) ok++
      } catch {
        upsert.run(address, '', now) // mark checked so we don't spin
      }
    }
  }
  if (need.length) log(`handles: checked ${need.length}, named ${ok}`)
  return need.length
}
