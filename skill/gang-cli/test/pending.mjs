/**
 * Trades waiting for Binance App approval: pending.js matching (offline), the previews record merge, and the CLI's
 * execute / tx --pending against a fake `baw` on PATH (no chain, no wallet).
 *
 *   node skill/gang-cli/test/pending.mjs
 */
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const dir = mkdtempSync(join(tmpdir(), 'gang-pending-'))
process.env.GANG_NOTES_DIR = join(dir, 'notes')
const { callPrint, matchPending } = await import('../src/pending.js')
const { rememberPreview, previewFor, pendingPreviews } = await import('../src/previews.js')
const h = (n) => `0x${String(n).padStart(64, '0')}`
const to = '0x15CFD2dc8278Fb87a1783ef42111618E20874365'

try {
  // --- matching ---
  {
    const at = Date.parse('2026-10-30T02:00:00Z')
    const iso = (ms) => new Date(ms).toISOString()
    const chain = {
      [h(1)]: { to, input: '0xAAAA', blockNumber: 105n }, // the approved call, after the pending block
      [h(2)]: { to, input: '0xbbbb', blockNumber: 103n }, // another trade
      [h(3)]: { to, input: '0xaaaa', blockNumber: 99n }, // the same call approved before: 20 s before the execute, an earlier block
      [h(4)]: null, // unreadable
    }
    const txOf = async (hash) => { if (!chain[hash]) throw new Error('rpc'); return chain[hash] }
    const rec = (requestId, data, extra = {}) => ({ requestId, pendingAt: at, pendingBlock: 100, print: callPrint(to, data), ...extra })
    const history = [
      { txHash: h(3), txTime: iso(at - 20_000), status: 'confirmed' },
      { txHash: h(4), txTime: iso(at + 5_000), status: 'confirmed' },
      { txHash: h(2), txTime: iso(at + 10_000), status: 'confirmed' },
      { txHash: h(5), txTime: iso(at + 15_000), status: 'pending' },
      { txHash: h(1), txTime: iso(at + 20_000), status: 'confirmed' },
    ]
    // the 2026-10-30 case: a withdraw of 1 share approved, then the same withdraw again; the first tx is not the second's
    const m = await matchPending([rec('r1', '0xaaaa'), rec('r2', '0xcccc')], history, txOf)
    assert.deepEqual(m.map((x) => [x.requestId, x.txHash]), [['r1', h(1)], ['r2', null]])
    // still waiting while only the earlier one is there
    assert.deepEqual((await matchPending([rec('r1', '0xaaaa')], history.filter((x) => x.txHash !== h(1)), txOf)).map((x) => x.txHash), [null])
    // the print ignores the case of the address and the calldata
    assert.equal(callPrint(to, '0xAAAA'), callPrint(to.toLowerCase(), '0xaaaa'))
    // one tx answers one record: two records of the same call take two txs; a tx an earlier run gave away is not reused
    const twice = await matchPending([rec('r1', '0xaaaa'), rec('r3', '0xaaaa')], history, txOf)
    assert.deepEqual(twice.map((x) => x.txHash), [h(1), null])
    assert.deepEqual((await matchPending([rec('r3', '0xaaaa')], history, txOf, [h(1)])).map((x) => x.txHash), [null])
    // no block recorded: only a tx sent after the execute
    const noBlock = await matchPending([rec('r4', '0xaaaa', { pendingBlock: null })], history, txOf)
    assert.deepEqual(noBlock.map((x) => x.txHash), [h(1)])
    const noBlockLate = await matchPending([rec('r5', '0xaaaa', { pendingBlock: null, pendingAt: at + 30_000 })], history, txOf)
    assert.deepEqual(noBlockLate.map((x) => x.txHash), [null])
  }

  // --- the record: each write merges, pendingPreviews lists the open ones ---
  {
    rememberPreview('q1', { print: 'p1', chainId: '56' })
    rememberPreview('q1', { kind: 'v3', noted: false })
    const r = previewFor('q1')
    assert.equal(r.print, 'p1')
    assert.equal(r.kind, 'v3')
    assert.equal(r.requestId, 'q1')
    const created = r.createdAt
    rememberPreview('q1', { pendingAt: 123 })
    assert.equal(previewFor('q1').createdAt, created)
    assert.deepEqual(pendingPreviews().map((x) => x.requestId), ['q1'])
    rememberPreview('q1', { txHash: h(9) })
    assert.deepEqual(pendingPreviews(), [])
  }

  // --- the CLI against a fake baw ---
  {
    const bin = join(dir, 'bin')
    execFileSync('mkdir', ['-p', bin])
    // execute answers $FAKE_STATUS; tx-history answers no confirmed tx
    writeFileSync(join(bin, 'baw'), `#!/bin/sh
case "$1 $2" in
  "contract-call execute") if [ "$FAKE_STATUS" = PENDING_CONFIRMATION ]; then echo '{"success":true,"data":{"status":"PENDING_CONFIRMATION","orderId":"o-1"}}'; else echo '{"success":true,"data":{"status":"SUCCESS","txHash":"${h(7)}"}}'; fi ;;
  "wallet tx-history") echo '{"success":true,"data":{"transactions":[],"hasMore":false}}' ;;
  *) echo '{"success":false,"error":"unexpected"}' ;;
esac
`)
    chmodSync(join(bin, 'baw'), 0o755)
    const cli = fileURLToPath(new URL('../src/index.js', import.meta.url))
    const run = (args, status = 'SUCCESS') => JSON.parse(execFileSync(process.execPath, [cli, ...args], {
      env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, FAKE_STATUS: status, GANG_UPDATE_CHECK: '0' }, encoding: 'utf8',
    }))

    // a setup step / bond preview (no kind): no "no note" reminder; a trade preview without a note: the reminder
    rememberPreview('step-1', { print: 'x', chainId: '56' })
    assert.equal(run(['execute', '--request-id', 'step-1']).agentNote, undefined)
    rememberPreview('trade-1', { print: 'y', chainId: '56', kind: 'v3', noted: false })
    assert.match(run(['execute', '--request-id', 'trade-1']).agentNote.hint, /^This trade carries no note/)

    // pending: marked, pointed at gang tx --pending, which says "waiting" until the wallet shows the tx
    rememberPreview('wd-1', { print: callPrint(to, '0xdead'), chainId: '56', kind: 'fair', noted: false })
    const ex = run(['execute', '--request-id', 'wd-1'], 'PENDING_CONFIRMATION')
    assert.equal(ex.pendingConfirmation, true)
    assert.match(ex.next, /gang tx --pending/)
    assert.equal(previewFor('wd-1').orderId, 'o-1')
    // the block it went pending at (null when the RPC could not answer: then matched by time)
    assert.ok(previewFor('wd-1').pendingBlock === null || previewFor('wd-1').pendingBlock > 0)
    const p = run(['tx', '--pending'])
    assert.deepEqual(p.pending.map((x) => [x.requestId, x.state, x.orderId]), [['wd-1', 'waiting', 'o-1']])
  }
} finally {
  rmSync(dir, { recursive: true, force: true })
}
console.log('pending: ok')
