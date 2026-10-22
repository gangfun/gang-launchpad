import { parseAbi, formatEther } from 'viem'

export const WBNB = '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c'
const PAIR_ABI = parseAbi([
  'function getReserves() view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast)',
  'function token0() view returns (address)',
  'function token1() view returns (address)',
])

const cache = new Map() // pair -> { at, data }; TTL 30s — shared by list/detail/search

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
