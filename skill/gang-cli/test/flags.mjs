/**
 * Unknown flags on a create (flags.js): refused before anything is read, uploaded or sent, with the right flag named for
 * link typos; and every flag `gang help` lists for a create is one the check lets through.
 *
 *   node skill/gang-cli/test/flags.mjs
 */
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { createServer } from 'node:http'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'
import { CREATE_ACCEPTS, suggestFlag, unknownFlagError } from '../src/flags.js'

const CLI = fileURLToPath(new URL('../src/index.js', import.meta.url))
const hits = []
const server = createServer((req, res) => { hits.push(req.url); res.writeHead(404).end() })
await new Promise((r) => server.listen(0, '127.0.0.1', r))
const env = { ...process.env, GANG_API: `http://127.0.0.1:${server.address().port}/api`, GANG_TELEMETRY: '0', GANG_UPDATE_CHECK: '0', PATH: '/usr/bin:/bin' }
const run = async (cliArgs) => {
  try { return JSON.parse((await promisify(execFile)(process.execPath, [CLI, ...cliArgs], { env, encoding: 'utf8', timeout: 15_000 })).stdout) } catch (e) { return JSON.parse(e.stdout) }
}
const err = (argv) => unknownFlagError(argv, CREATE_ACCEPTS, 'gang create')

try {
  // --- the check ---
  assert.equal(err(['create', '--name', 'T', '--symbol', 'T', '--website', 'a.xyz', '--twitter', '@t', '--testnet']), null)
  assert.equal(err(['create', '--description', '--- launch day ---']), null) // a value, left to --description
  assert.match(err(['create', '--x', 'https://x.com/foo']), /^--x is not a flag of gang create: did you mean --twitter @handle/)
  for (const typo of ['twitter-url', 'x-url', 'X']) assert.match(err([`--${typo}`, 'a']), /did you mean --twitter/)
  for (const typo of ['website-url', 'url', 'site', 'homepage', 'webiste', 'Website']) assert.match(err([`--${typo}`, 'a']), /did you mean --website <URL>/)
  assert.match(err(['--qouta', '20']), /did you mean --quota\?/)
  assert.match(err(['--colour', 'red']), /see gang help for its flags\. Nothing was uploaded or sent/)
  assert.equal(err(['--website=https://a.xyz']), '--website=https://a.xyz: give the value after a space (--website https://a.xyz)')
  assert.match(err(['--name', 'T', '--to-bnb']), /^--to-bnb is not a flag/) // a flag of other commands, not of a create
  assert.equal(suggestFlag('zzzzzzzz', CREATE_ACCEPTS), null)

  // --- every create flag in gang help passes ---
  const help = (await promisify(execFile)(process.execPath, [CLI, 'help'], { env, encoding: 'utf8' }).catch((e) => e)).stdout
  const listed = new Set()
  let inCreate = false
  for (const line of help.split('\n')) {
    if (/^ {2}gang /.test(line)) inCreate = /^ {2}gang (create|v3 create|fair create|fly create)\b/.test(line)
    else if (!/^ {6,20}\S/.test(line)) { if (!/^ {21,}/.test(line)) inCreate = false; continue } // the description column
    if (inCreate) for (const m of line.matchAll(/--([a-z][a-z0-9-]*)/g)) listed.add(m[1])
  }
  assert.ok(listed.size > 40, `found ${listed.size} create flags in gang help`)
  for (const f of listed) assert.ok(CREATE_ACCEPTS.has(f), `gang help lists --${f} for a create, the check refuses it`)

  // --- through the CLI: every create path, before any request ---
  for (const [cmd, typo] of [[['create'], '--x'], [['v3', 'create'], '--website-url'], [['fair', 'create'], '--twitter-url'], [['fly', 'create'], '--site'], [['create', '--fly'], '--url']]) {
    const r = await run([...cmd, '--name', 'T', '--symbol', 'T', typo, 'https://a.xyz'])
    assert.equal(r.success, false)
    assert.match(r.error, new RegExp(`^${typo} is not a flag of gang ${cmd[0] === 'create' ? 'create' : `${cmd[0]} create`}: did you mean --(website|twitter)`))
  }
  assert.deepEqual(hits, []) // no upload, no API call
  // other commands are untouched: list still reads its own flags
  const list = await run(['list', '--kind', 'nope'])
  assert.doesNotMatch(list.error, /is not a flag/)

  console.log('flags: ok')
} finally {
  server.close()
}
