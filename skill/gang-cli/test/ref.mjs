/**
 * Invite tag ("gang" 05 + referrer) in calldata: written before the follow ref and the note suffix, read back from that
 * one place only, next to readFollowRef; and `gang invite` against a local fake gang.fun.
 *
 *   node skill/gang-cli/test/ref.mjs
 */
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { createServer } from 'node:http'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'

const dir = mkdtempSync(join(tmpdir(), 'gang-ref-'))
process.env.GANG_NOTES_DIR = join(dir, 'notes')
const { refSuffix, readRef, followSuffix, readFollowRef, makeNote, withNote, REF_MAGIC } = await import('../src/notes.js')
const CLI = fileURLToPath(new URL('../src/index.js', import.meta.url))
const ref = `0x${'ab'.repeat(20)}`, other = `0x${'cd'.repeat(20)}`
const noteTx = `0x${'12'.repeat(32)}`
const call = '0xa9059cbb' + '00'.repeat(64) // some calldata

const routes = {}
const server = createServer((req, res) => {
  const r = routes[req.url]
  if (!r) return res.writeHead(404).end()
  res.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify(r))
})
await new Promise((r) => server.listen(0, '127.0.0.1', r))
const run = async (cliArgs) => {
  const env = { ...process.env, GANG_API: `http://127.0.0.1:${server.address().port}/api`, GANG_TELEMETRY: '0', GANG_UPDATE_CHECK: '0', PATH: '/usr/bin:/bin' }
  try { return JSON.parse((await promisify(execFile)(process.execPath, [CLI, ...cliArgs], { env, encoding: 'utf8' })).stdout) } catch (e) { return JSON.parse(e.stdout) }
}

try {
  // --- writing ---
  assert.equal(refSuffix(ref), `${REF_MAGIC}${'ab'.repeat(20)}`)
  assert.equal(refSuffix(ref.toUpperCase().replace('0X', '0x')), `${REF_MAGIC}${'ab'.repeat(20)}`) // lower-cased
  assert.throws(() => refSuffix('0x1234'))
  assert.throws(() => refSuffix(null))

  // --- reading, every combination with a follow ref and a note (v1, v2) ---
  const v1 = makeNote('because', '70'), v2 = makeNote('sealed reason', '60', '6h')
  const follow = followSuffix(noteTx)
  for (const note of [null, v1, v2]) {
    for (const withFollowRef of [false, true]) {
      const tail = (withFollowRef ? follow : '') // [calldata][ref][follow][note]
      const both = withNote(call + refSuffix(ref) + tail, note)
      assert.equal(readRef(both), ref, `ref, follow=${withFollowRef}, note=${note?.revealAfter ? 'v2' : note ? 'v1' : 'none'}`)
      assert.equal(readFollowRef(both), withFollowRef ? noteTx : null) // the follow ref still reads with a ref before it
      assert.equal(readRef(withNote(call + tail, note)), null) // no ref
    }
  }
  // only the one place counts: a ref anywhere else (after the note, before two follow refs, at the start) is ignored
  assert.equal(readRef(withNote(call, v1) + refSuffix(ref)), ref) // a ref last with nothing after it is in its place…
  assert.equal(readRef(call + refSuffix(ref) + withNote('', v1).slice(0, 10) + follow), null) // …junk between ref and follow is not
  assert.equal(readRef(call + refSuffix(ref) + follow + follow), null)
  assert.equal(readRef(refSuffix(ref) + call), null)
  // a ref right at the end of the input (no follow, no note) reads; the last one wins
  assert.equal(readRef(call + refSuffix(other) + refSuffix(ref)), ref)
  assert.equal(readRef(''), null)
  assert.equal(readRef(`${REF_MAGIC}zz${'ab'.repeat(19)}`), null)

  // --- gang invite ---
  routes['/api/ref/lazy.ai'] = { referrer: ref, invited: 12, qualified: 4, thisWeek: { invited: 3, qualified: 1 }, byToken: [{ token: other, symbol: 'AAA', invited: 12, qualified: 4 }] }
  const inv = await run(['invite', '--who', 'lazy.ai'])
  assert.equal(inv.success, true)
  assert.equal(inv.link, `https://gang.fun/start?ref=${ref}`)
  assert.deepEqual(inv.stats, { invited: 12, qualified: 4, thisWeek: { invited: 3, qualified: 1 }, byToken: routes['/api/ref/lazy.ai'].byToken })
  const withToken = await run(['invite', '--who', 'lazy.ai', '--token', other])
  assert.equal(withToken.link, `https://gang.fun/start?ref=${ref}&token=${other}`)
  // no stats yet: an address still gets its link
  const fresh = await run(['invite', '--who', other])
  assert.equal(fresh.success, true)
  assert.equal(fresh.link, `https://gang.fun/start?ref=${other}`)
  assert.equal(fresh.stats, null)
  // an unknown handle can't make a link
  const unknown = await run(['invite', '--who', 'nobody.ai'])
  assert.equal(unknown.success, false)
  // --ref only on buy / mint / follow
  const sell = await run(['sell', '--token', other, '--all', '--ref', ref])
  assert.equal(sell.success, false)
  assert.match(sell.error, /--ref .*buy \/ mint \/ follow only/) // refused before any RPC

  console.log('ref: ok')
} finally {
  server.close()
  rmSync(dir, { recursive: true, force: true })
}
