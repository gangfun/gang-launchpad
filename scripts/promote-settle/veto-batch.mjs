#!/usr/bin/env node
// A Safe Transaction Builder batch that vetoes every root still in its dispute window under one factory, for when the
// settler's roots can't be trusted (spec §5). Read-only: it prints the batch; the Safe signs it.
//
//   RPC_URL=<node> node veto-batch.mjs --factory 0x… [--new-settler 0x…] [--module 0x…,0x…] [--min-left <hours> | --max-left <hours>] > batch.json
//
// --new-settler replaces the settler first, in the same batch. Without it a settler that still holds its key can post the
//   same root again the moment it is vetoed.
// --module limits it to those modules.
// --min-left / --max-left keep only roots with at least / less than that many hours left. A Safe batch is all or nothing:
//   one root taking effect before the signatures are in makes the whole batch revert, and with it every other veto. So
//   sign the roots close to their time in their own batch: run it once with --max-left and once with --min-left, same
//   number. A plain run warns when a root has under 6 hours left.
//
// Exits 1 printing no batch when a read fails: a batch that silently leaves a module out would look complete.
// Exits 3 when it could not do all that was asked: a root past its dispute window (the batch, if any, is still printed, and
// its description names the root), or nothing to do (no batch).
import { parseArgs } from 'node:util'
import { createPublicClient, encodeFunctionData, getAddress, http, parseAbi } from 'viem'

const { values: args } = parseArgs({ options: { factory: { type: 'string' }, module: { type: 'string' }, 'new-settler': { type: 'string' }, 'min-left': { type: 'string' }, 'max-left': { type: 'string' } } })
const hours = (name) => {
  if (args[name] === undefined) return null
  if (!/^\d+(\.\d+)?$/.test(args[name])) {
    console.error(`--${name} takes a number of hours`)
    process.exit(2)
  }
  return Math.round(Number(args[name]) * 3600)
}
const minLeft = hours('min-left')
const maxLeft = hours('max-left')
if (!args.factory || !process.env.RPC_URL || (minLeft !== null && maxLeft !== null)) {
  console.error('usage: RPC_URL=… node veto-batch.mjs --factory 0x… [--new-settler 0x…] [--module 0x…,0x…] [--min-left <hours> | --max-left <hours>]')
  process.exit(2)
}
const factory = getAddress(args.factory)
const newSettler = args['new-settler'] ? getAddress(args['new-settler']) : null
if (newSettler && BigInt(newSettler) === 0n) {
  console.error('--new-settler can\'t be the zero address: the factory refuses it, and the whole batch with it')
  process.exit(2)
}
const client = createPublicClient({ transport: http(process.env.RPC_URL, { retryCount: 5, batch: { batchSize: 100 } }) })
const FACTORY = parseAbi(['function modules() view returns (address[])', 'function owner() view returns (address)', 'function setSettler(address)'])
const MODULE = parseAbi(['function pendingRoot() view returns (bytes32)', 'function pendingActiveAt() view returns (uint64)', 'function factory() view returns (address)', 'function veto()'])
const read = (address, abi, functionName) => client.readContract({ address, abi, functionName })

const all = await read(factory, FACTORY, 'modules')
const owner = await read(factory, FACTORY, 'owner')
if (newSettler === owner) {
  console.error('--new-settler can\'t be the factory owner: whoever posts a root must not be the one who can veto it')
  process.exit(2)
}
const only = args.module ? new Set(args.module.split(',').map((a) => getAddress(a.trim()))) : null
for (const m of only ?? []) {
  if (!all.includes(m)) {
    console.error(`${m} is not a module of this factory`)
    process.exit(1)
  }
}
const { timestamp: now } = await client.getBlock({ blockTag: 'latest' })
const data = encodeFunctionData({ abi: MODULE, functionName: 'veto' })
const rows = []
const late = []
const left = []
for (const m of all) {
  if (only && !only.has(m)) continue
  const [root, activeAt] = await Promise.all([read(m, MODULE, 'pendingRoot'), read(m, MODULE, 'pendingActiveAt')])
  if (BigInt(root) === 0n) continue
  // past its window it can only take effect: a veto would revert and fail the whole batch
  if (activeAt <= now) {
    console.error(`${m}: root ${root} is past its dispute window, too late to veto`)
    late.push(`${m} ${root}`)
    continue
  }
  const secondsLeft = Number(activeAt - now)
  if ((minLeft !== null && secondsLeft < minLeft) || (maxLeft !== null && secondsLeft >= maxLeft)) {
    left.push(m)
    continue
  }
  rows.push({ m, root, activeAt: Number(activeAt) })
}
if (rows.length) {
  const soonest = Math.min(...rows.map((r) => r.activeAt))
  console.error(`${rows.length} root(s) to veto of ${all.length} module(s); the first takes effect at ${new Date(soonest * 1000).toISOString()}, sign before that: one root taking effect first makes the whole batch revert`)
  if (minLeft === null && maxLeft === null && soonest - Number(now) < 6 * 3600) {
    console.error('under 6 hours left on the first root: consider signing the close ones in their own batch, --max-left 6, and the rest with --min-left 6')
  }
} else console.error(`no root to veto in this batch, among ${all.length} module(s)`)
if (left.length) console.error(`${left.length} root(s) left out by --min-left / --max-left: run the other half too`)
if (!rows.length && !newSettler) {
  console.error('no batch printed')
  process.exit(3)
}
const setSettlerTx = newSettler && {
  to: factory, value: '0', data: encodeFunctionData({ abi: FACTORY, functionName: 'setSettler', args: [newSettler] }),
  contractMethod: { inputs: [{ internalType: 'address', name: 'settler_', type: 'address' }], name: 'setSettler', payable: false }, contractInputsValues: { settler_: newSettler },
}
console.log(JSON.stringify({
  version: '1.0',
  chainId: String(await client.getChainId()),
  createdAt: Number(now) * 1000,
  meta: {
    name: newSettler ? 'Replace the settler and veto promoter pool roots' : 'Veto promoter pool roots',
    description: `${newSettler ? `setSettler(${newSettler}) on factory ${factory}, then ` : ''}veto() on ${rows.length} module(s) of factory ${factory}. Roots: ${rows.map((r) => `${r.m} ${r.root}`).join('; ') || 'none'}.${late.length ? ` Past their dispute window, not in this batch: ${late.join('; ')}.` : ''}${left.length ? ` Left out by the time filter: ${left.join(', ')}.` : ''}`,
    txBuilderVersion: '1.16.5', createdFromSafeAddress: owner, createdFromOwnerAddress: '', checksum: '',
  },
  transactions: [...(setSettlerTx ? [setSettlerTx] : []), ...rows.map((r) => ({ to: r.m, value: '0', data, contractMethod: { inputs: [], name: 'veto', payable: false }, contractInputsValues: {} }))],
}, null, 2))
if (late.length) process.exit(3)
