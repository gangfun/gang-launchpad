import { parseAbi, parseAbiItem } from 'viem'
import { AGENT_ID } from './handles.js'

const ZERO = '0x0000000000000000000000000000000000000000'
const DEAD = '0x000000000000000000000000000000000000dead'
const TRANSFER = parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 value)')
const ERC20_ABI = parseAbi(['function balanceOf(address account) view returns (uint256)'])
const AGENT_ABI = parseAbi(['function balanceOf(address account) view returns (uint256)'])

const resultCache = new Map() // token -> { at, data }
/** token -> { lastBlock: bigint|null, addresses: Set<string> } */
const scanState = new Map()

const LOG_CHUNK = 2500n
const BLOCKS_PER_SYNC = 18_000n

function excludeSet(token, pair) {
  return new Set([ZERO, DEAD, token?.toLowerCase(), pair?.toLowerCase()].filter(Boolean))
}

async function estimateGradBlock(client, graduatedTs) {
  const head = await client.getBlockNumber()
  const headBlk = await client.getBlock({ blockNumber: head })
  const age = Math.max(0, Number(headBlk.timestamp) - Number(graduatedTs || 0))
  let fromBlock = head > 0n ? head - BigInt(Math.ceil(age / 0.45) + 400) : 0n
  if (fromBlock < 0n) fromBlock = 0n
  return { head, fromBlock }
}

/** Incremental Transfer scan; mutates `candidates` and persists progress in scanState. */
async function syncTransferCandidates(client, token, pair, graduatedTs, candidates) {
  const tok = token.toLowerCase()
  const exclude = excludeSet(tok, pair)
  let state = scanState.get(tok)
  if (!state) {
    state = { lastBlock: null, addresses: new Set() }
    scanState.set(tok, state)
  }
  for (const a of state.addresses) if (!exclude.has(a)) candidates.add(a)

  const { head, fromBlock: gradFrom } = await estimateGradBlock(client, graduatedTs)
  let from = state.lastBlock != null ? state.lastBlock + 1n : gradFrom
  if (from > head) return

  const cap = from + BLOCKS_PER_SYNC > head ? head : from + BLOCKS_PER_SYNC
  let span = LOG_CHUNK
  while (from <= cap) {
    const to = from + span - 1n > cap ? cap : from + span - 1n
    try {
      const logs = await client.getLogs({
        address: tok,
        event: TRANSFER,
        fromBlock: from,
        toBlock: to,
      })
      for (const l of logs) {
        const fromA = l.args.from?.toLowerCase()
        const toA = l.args.to?.toLowerCase()
        if (fromA && !exclude.has(fromA)) {
          candidates.add(fromA)
          state.addresses.add(fromA)
        }
        if (toA && !exclude.has(toA)) {
          candidates.add(toA)
          state.addresses.add(toA)
        }
      }
      from = to + 1n
      if (span < LOG_CHUNK) span = span * 2n > LOG_CHUNK ? LOG_CHUNK : span * 2n
    } catch (e) {
      const msg = e.message || ''
      if (/limit|range|too many|exceed/i.test(msg) && span > 80n) {
        span /= 2n
        continue
      }
      break
    }
  }
  state.lastBlock = cap
}

async function countHolders(client, token, candidates) {
  const tok = token.toLowerCase()
  const addrs = [...candidates]
  if (!addrs.length) return { holders: 0, holdersAgent: 0, holdersOther: 0 }

  const withBalance = []
  for (let i = 0; i < addrs.length; i += 200) {
    const chunk = addrs.slice(i, i + 200)
    const bals = await client.multicall({
      contracts: chunk.map((address) => ({
        address: tok,
        abi: ERC20_ABI,
        functionName: 'balanceOf',
        args: [address],
      })),
      allowFailure: true,
    })
    for (let j = 0; j < chunk.length; j++) {
      const r = bals[j]
      if (r.status === 'success' && r.result > 0n) withBalance.push(chunk[j])
    }
  }

  let holdersAgent = 0
  for (let i = 0; i < withBalance.length; i += 200) {
    const chunk = withBalance.slice(i, i + 200)
    const agents = await client.multicall({
      contracts: chunk.map((address) => ({
        address: AGENT_ID,
        abi: AGENT_ABI,
        functionName: 'balanceOf',
        args: [address],
      })),
      allowFailure: true,
    })
    for (let j = 0; j < chunk.length; j++) {
      const r = agents[j]
      if (r.status === 'success' && r.result > 0n) holdersAgent++
    }
  }

  const holders = withBalance.length
  return {
    holders,
    holdersAgent,
    holdersOther: Math.max(0, holders - holdersAgent),
  }
}

/**
 * Live holder counts for graduated tokens: balanceOf > 0, excluding pair/burn/zero.
 * Agent vs other via SPACE ID Agent ID registry balanceOf > 0.
 */
export async function getGraduatedHolderStats(db, client, { token, pair, graduatedTs }) {
  if (!client || !token) return null
  const tok = token.toLowerCase()
  const hit = resultCache.get(tok)
  if (hit && Date.now() - hit.at < 45_000) return hit.data

  const exclude = excludeSet(tok, pair)
  const candidates = new Set()
  for (const r of db.prepare("SELECT lower(holder) AS h FROM holders WHERE token=? AND balance!='0'").all(tok)) {
    if (r.h && !exclude.has(r.h)) candidates.add(r.h)
  }

  try {
    await syncTransferCandidates(client, tok, pair, graduatedTs, candidates)
  } catch {
    // DB-backed candidates only
  }

  const data = await countHolders(client, tok, candidates)
  resultCache.set(tok, { at: Date.now(), data })
  return data
}
