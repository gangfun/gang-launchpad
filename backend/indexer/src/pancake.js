import { parseAbi, formatEther, parseAbiItem } from 'viem'

export const WBNB = '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c'
const PAIR_ABI = parseAbi([
  'function getReserves() view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast)',
  'function token0() view returns (address)',
  'function token1() view returns (address)',
])
const SWAP_EVENT = parseAbiItem(
  'event Swap(address indexed sender, uint256 amount0In, uint256 amount1In, uint256 amount0Out, uint256 amount1Out, address indexed to)',
)

const cache = new Map() // pair -> { at, data }; TTL 30s — shared by list/detail/search
const ohlcvCache = new Map() // `${pair}:${res}` -> { at, candles }

/** Best-effort Pancake V2 pair snapshot. Returns null on any failure. */
export async function readPair(client, pair, token) {
  if (!pair || !client) return null
  const key = pair.toLowerCase()
  const hit = cache.get(key)
  if (hit && Date.now() - hit.at < 30_000) return hit.data // 30s in-memory TTL
  try {
    const [token0, token1, reserves] = await Promise.all([
      client.readContract({ address: pair, abi: PAIR_ABI, functionName: 'token0' }),
      client.readContract({ address: pair, abi: PAIR_ABI, functionName: 'token1' }),
      client.readContract({ address: pair, abi: PAIR_ABI, functionName: 'getReserves' }),
    ])
    const [r0, r1] = reserves
    const t0 = token0.toLowerCase()
    const t1 = token1.toLowerCase()
    const tok = token.toLowerCase()
    const wbnb = WBNB.toLowerCase()
    let reserveToken, reserveBnb
    if (t0 === tok && t1 === wbnb) { reserveToken = r0; reserveBnb = r1 }
    else if (t1 === tok && t0 === wbnb) { reserveToken = r1; reserveBnb = r0 }
    else { reserveToken = t0 === tok ? r0 : r1; reserveBnb = t0 === tok ? r1 : r0 }
    // price in BNB per token (both 18 decimals on Gang tokens + WBNB)
    const priceBnb = reserveToken > 0n
      ? Number(reserveBnb) / Number(reserveToken)
      : 0
    const data = {
      pair: key,
      token0: t0,
      token1: t1,
      reserveToken: formatEther(reserveToken),
      reserveBnb: formatEther(reserveBnb),
      priceBnb,
      fdvBnb: priceBnb * 1e9,
      pancakeUrl: `https://pancakeswap.finance/swap?outputCurrency=${tok}&chain=bsc`,
      pairUrl: `https://bscscan.com/address/${key}`,
      infoUrl: `https://pancakeswap.finance/info/v2/pairs/${key}`,
    }
    cache.set(key, { at: Date.now(), data })
    return data
  } catch {
    return null
  }
}

/**
 * Resample OHLCV bars into coarser buckets (open=first, close=last, h/l extrema, v sum).
 * Used so one GT 1m base serves 5m/15m/1h/4h/1d without per-interval upstream calls.
 */
export function resampleCandles(candles, resSec) {
  if (!candles?.length) return []
  const sec = Math.max(1, Number(resSec) || 60)
  if (sec <= 60) {
    // Already 1m (or finer): snap to exact 1m buckets in case upstream drifts
    const out = []
    let cur = null
    for (const c of candles) {
      const t = Math.floor(c.t / 60) * 60
      if (!cur || cur.t !== t) {
        if (cur) out.push(cur)
        cur = { t, o: c.o, h: c.h, l: c.l, c: c.c, v: c.v || 0 }
      } else {
        cur.h = Math.max(cur.h, c.h)
        cur.l = Math.min(cur.l, c.l)
        cur.c = c.c
        cur.v += c.v || 0
      }
    }
    if (cur) out.push(cur)
    return out
  }
  const out = []
  let cur = null
  for (const c of candles) {
    const t = Math.floor(c.t / sec) * sec
    if (!cur || cur.t !== t) {
      if (cur) out.push(cur)
      cur = { t, o: c.o, h: c.h, l: c.l, c: c.c, v: c.v || 0 }
    } else {
      cur.h = Math.max(cur.h, c.h)
      cur.l = Math.min(cur.l, c.l)
      cur.c = c.c
      cur.v += c.v || 0
    }
  }
  if (cur) out.push(cur)
  return out
}

/**
 * DEX OHLCV in BNB-per-token (same unit as curve candles).
 * Fetch GT 1m once per pair (cached), resample to requested interval so
 * 1m/5m/15m/1h/4h/1d actually differ and switching stays fast under GT rate limits.
 * Returns [] on failure (caller stitches live price; swap fallback is optional/slow).
 */
export async function fetchDexOhlcv(pair, resSec, { limit = 500 } = {}) {
  if (!pair) return []
  const sec = Math.max(1, Number(resSec) || 60)
  const key = `${pair.toLowerCase()}:${sec}`
  const hit = ohlcvCache.get(key)
  if (hit && Date.now() - hit.at < 20_000) return hit.candles

  const base = await fetchDexOhlcvBase(pair)
  if (!base.length) return []
  const candles = resampleCandles(base, sec)
  const sliced = limit > 0 ? candles.slice(-Math.min(limit, 1000)) : candles
  ohlcvCache.set(key, { at: Date.now(), candles: sliced })
  return sliced
}

/** One GT minute/aggregate=1 pull per pair; shared by all chart intervals. */
async function fetchDexOhlcvBase(pair) {
  const key = `${pair.toLowerCase()}:base1m`
  const hit = ohlcvCache.get(key)
  if (hit && Date.now() - hit.at < 20_000) return hit.candles

  const url = `https://api.geckoterminal.com/api/v2/networks/bsc/pools/${pair.toLowerCase()}/ohlcv/minute?aggregate=1&limit=1000&currency=token`
  try {
    const r = await fetch(url, { headers: { accept: 'application/json' }, signal: AbortSignal.timeout(6000) })
    if (!r.ok) return []
    const j = await r.json()
    const list = j?.data?.attributes?.ohlcv_list
    if (!Array.isArray(list) || !list.length) return []
    // GT returns newest-first: [ts, o, h, l, c, vol_quote]
    const candles = list
      .map(([t, o, h, l, c, v]) => ({
        t: Number(t),
        o: Number(o), h: Number(h), l: Number(l), c: Number(c),
        v: Number(v) || 0,
      }))
      .filter((c) => c.t > 0 && c.c > 0 && Number.isFinite(c.c))
      .reverse()
    ohlcvCache.set(key, { at: Date.now(), candles })
    return candles
  } catch {
    return []
  }
}

/** Sum quote (WBNB) volume from GT 1m candles over the last 24h. */
export async function sumDexVolume24hBnb(pair) {
  if (!pair) return null
  const base = await fetchDexOhlcvBase(pair)
  if (!base.length) return null
  const cut = Math.floor(Date.now() / 1000) - 86400
  let sum = 0
  for (const c of base) {
    if (c.t >= cut) sum += c.v || 0
  }
  return sum
}

/**
 * Fallback: recent Pancake V2 Swap logs → OHLCV (BNB per token).
 * Soft-launch friendly — capped block span so public RPC stays happy.
 */
export async function fetchSwapOhlcv(client, { pair, token, fromTs, resSec, maxBlocks = 8000n }) {
  if (!client || !pair || !token) return []
  try {
    const meta = await readPair(client, pair, token)
    if (!meta?.token0) return []
    const tokIs0 = meta.token0 === token.toLowerCase()
    const head = await client.getBlockNumber()
    const headBlock = await client.getBlock({ blockNumber: head })
    const headTs = Number(headBlock.timestamp)
    const age = Math.max(0, headTs - (fromTs || headTs))
    // BSC ~0.45s post-Lorenz; pad so we don't start after graduation
    const est = BigInt(Math.ceil(age / 0.45) + 200)
    let fromBlock = head > est ? head - est : 0n
    if (head - fromBlock > maxBlocks) fromBlock = head - maxBlocks

    const swaps = []
    let span = 500n
    let from = fromBlock
    while (from <= head) {
      const to = from + span - 1n > head ? head : from + span - 1n
      try {
        const logs = await client.getLogs({
          address: pair,
          event: SWAP_EVENT,
          fromBlock: from,
          toBlock: to,
        })
        for (const l of logs) {
          const a = l.args
          let bnbIn = 0n, bnbOut = 0n, tokIn = 0n, tokOut = 0n
          if (tokIs0) {
            tokIn = a.amount0In; tokOut = a.amount0Out
            bnbIn = a.amount1In; bnbOut = a.amount1Out
          } else {
            tokIn = a.amount1In; tokOut = a.amount1Out
            bnbIn = a.amount0In; bnbOut = a.amount0Out
          }
          let price = 0, vol = 0
          if (tokOut > 0n && bnbIn > 0n) {
            price = Number(bnbIn) / Number(tokOut)
            vol = Number(formatEther(bnbIn))
          } else if (tokIn > 0n && bnbOut > 0n) {
            price = Number(bnbOut) / Number(tokIn)
            vol = Number(formatEther(bnbOut))
          }
          if (!(price > 0)) continue
          const ts = Number((await client.getBlock({ blockNumber: l.blockNumber })).timestamp)
          swaps.push({ ts, price, vol })
        }
        from = to + 1n
        if (span < 2000n) span = span * 2n > 2000n ? 2000n : span * 2n
      } catch (e) {
        const msg = e.message || ''
        if (/limit|range|too many|exceed/i.test(msg) && span > 50n) {
          span /= 2n
          continue
        }
        break
      }
    }
    if (!swaps.length) return []
    swaps.sort((a, b) => a.ts - b.ts)
    const out = []
    let cur = null
    for (const s of swaps) {
      const t = Math.floor(s.ts / resSec) * resSec
      if (!cur || cur.t !== t) {
        if (cur) out.push(cur)
        const o = cur ? cur.c : s.price
        cur = { t, o, h: Math.max(o, s.price), l: Math.min(o, s.price), c: s.price, v: s.vol }
      } else {
        cur.h = Math.max(cur.h, s.price)
        cur.l = Math.min(cur.l, s.price)
        cur.c = s.price
        cur.v += s.vol
      }
    }
    if (cur) out.push(cur)
    return out
  } catch {
    return []
  }
}

/** Push live spot into the rightmost bucket so mcap Y-axis matches header FDV. */
export function stitchLivePrice(candles, livePrice, resSec) {
  if (!(livePrice > 0) || !candles?.length) return candles || []
  const out = candles.slice()
  const nowBucket = Math.floor(Date.now() / 1000 / resSec) * resSec
  const last = out[out.length - 1]
  if (last.t === nowBucket) {
    out[out.length - 1] = {
      ...last,
      h: Math.max(last.h, livePrice),
      l: Math.min(last.l, livePrice),
      c: livePrice,
    }
  } else if (nowBucket > last.t) {
    out.push({
      t: nowBucket,
      o: last.c,
      h: Math.max(last.c, livePrice),
      l: Math.min(last.c, livePrice),
      c: livePrice,
      v: 0,
    })
  }
  return out
}

/**
 * Merge bonding-curve candles with post-graduation DEX candles.
 * Curve kept for t < gradBucket; DEX from gradBucket onward; live stitch last.
 */
export function mergeCurveAndDex(curve, dex, graduatedTs, resSec, livePrice) {
  const gradBucket = Math.floor((graduatedTs || 0) / resSec) * resSec
  const before = (curve || []).filter((c) => c.t < gradBucket)
  const after = (dex || []).filter((c) => c.t >= gradBucket)
  const merged = before.slice()
  for (const c of after) {
    if (merged.length && merged[merged.length - 1].t === c.t) merged[merged.length - 1] = c
    else merged.push(c)
  }
  // If DEX empty but we have curve + live, still extend past graduation
  if (!after.length && livePrice > 0 && graduatedTs) {
    const last = merged[merged.length - 1]
    const nowBucket = Math.floor(Date.now() / 1000 / resSec) * resSec
    if (!last || last.t < gradBucket) {
      const o = last ? last.c : livePrice
      merged.push({
        t: gradBucket,
        o,
        h: Math.max(o, livePrice),
        l: Math.min(o, livePrice),
        c: livePrice,
        v: 0,
      })
    }
    if (nowBucket > gradBucket && (!merged.length || merged[merged.length - 1].t < nowBucket)) {
      const prev = merged[merged.length - 1]
      merged.push({
        t: nowBucket,
        o: prev.c,
        h: Math.max(prev.c, livePrice),
        l: Math.min(prev.c, livePrice),
        c: livePrice,
        v: 0,
      })
    }
  }
  return stitchLivePrice(merged, livePrice, resSec)
}
