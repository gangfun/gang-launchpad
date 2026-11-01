/**
 * share.js against a local fake gang.fun: the query it sends, one retry on 404 (not indexed yet), and what it drops.
 *
 *   node skill/gang-cli/test/share.mjs
 */
import assert from 'node:assert/strict'
import { createServer } from 'node:http'

const seen = []
let answers = []
const server = createServer((req, res) => {
  seen.push(req.url)
  const [status, body] = answers.shift() ?? [500, null]
  res.writeHead(status, { 'content-type': 'application/json' }).end(body == null ? '' : JSON.stringify(body))
})
await new Promise((r) => server.listen(0, '127.0.0.1', r))
process.env.GANG_API = `http://127.0.0.1:${server.address().port}/api`
const { shareFor } = await import('../src/share.js')
const tx = `0x${'ab'.repeat(32)}`, token = `0x${'12'.repeat(20)}`
const waits = []
const wait = async (ms) => { waits.push(ms) }
const body = { text: 'fadai (.ai) bought $X — note written before the trade → https://gang.fun/note/x?s=x', url: 'https://gang.fun/note/x?s=x', image: 'https://gang.fun/api/og/note/x.png' }

try {
  answers = [[200, body]]
  const s = await shareFor({ note: tx }, wait)
  assert.deepEqual({ ...s, note: undefined }, { ...body, note: undefined })
  assert.match(s.note, /never post/)
  assert.equal(seen.pop(), `/api/share?note=${tx}`)
  assert.deepEqual(waits, [])

  // not indexed yet: one retry after 3s
  answers = [[404, { error: 'not_indexed' }], [200, body]]
  assert.equal((await shareFor({ token, event: 'create' }, wait)).url, body.url)
  assert.deepEqual(seen.splice(0), [`/api/share?token=${token}&event=create`, `/api/share?token=${token}&event=create`])
  assert.deepEqual(waits.splice(0), [3000])

  // still not indexed, a 5xx, a body without text, nothing to share: dropped
  answers = [[404, null], [404, null]]
  assert.equal(await shareFor({ note: tx }, wait), null)
  assert.equal(seen.splice(0).length, 2)
  answers = [[503, null]]
  assert.equal(await shareFor({ note: tx }, wait), null)
  answers = [[200, { url: 'x' }]]
  assert.equal(await shareFor({ note: tx }, wait), null)
  seen.splice(0)
  assert.equal(await shareFor({}, wait), null)
  assert.equal(seen.length, 0)

  console.log('share: ok')
} finally {
  server.close()
}
