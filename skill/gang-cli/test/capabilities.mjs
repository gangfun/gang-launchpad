/**
 * `gang capabilities`: both lists stay complete (every MCP tool, every command gang_cli names and the help lists), every
 * entry has what a program needs, and failed results carry a short code.
 *
 *   node skill/gang-cli/test/capabilities.mjs
 */
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { capabilities, COMMANDS, SCHEMA_VERSION } from '../src/capabilities.js'
import { INSTRUCTIONS, TOOLS } from '../src/mcp.js'
import { codeOf } from '../src/telemetry.js'
import { VERSION } from '../src/version.js'

const CLI = fileURLToPath(new URL('../src/index.js', import.meta.url))
const gang = (...args) => {
  const r = spawnSync(process.execPath, [CLI, ...args], { encoding: 'utf8', env: { ...process.env, GANG_TELEMETRY: '0', GANG_UPDATE_CHECK: '0' } })
  return { status: r.status, stdout: r.stdout }
}

const doc = capabilities()
assert.equal(doc.schemaVersion, SCHEMA_VERSION)
assert.equal(doc.cli, VERSION)

// every MCP tool, in its order, with the MCP input schema
assert.deepEqual(doc.tools.map((t) => t.name), TOOLS.map((t) => t.name))
for (const t of doc.tools) {
  assert.deepEqual(t.input, TOOLS.find((x) => x.name === t.name).inputSchema, t.name)
  const read = TOOLS.find((x) => x.name === t.name).annotations.readOnlyHint === true
  if (read) assert.deepEqual([t.access, t.risk, t.needsUserConfirmation], ['read', 'none', false], t.name)
  else assert.notEqual(t.risk, 'none', t.name)
}
assert.equal(doc.tools.find((t) => t.name === 'gang_execute').needsUserConfirmation, true)
assert.equal(doc.tools.find((t) => t.name === 'gang_execute').access, 'execute')

// every entry is complete, and no command is listed twice
const VERSION_RE = /^\d+\.\d+\.\d+$/
for (const e of [...doc.tools, ...doc.commands]) {
  const id = e.name ?? e.command
  assert.ok(doc.access[e.access], `${id}: access ${e.access}`)
  assert.ok(doc.risk[e.risk], `${id}: risk ${e.risk}`)
  assert.match(e.sinceCli, VERSION_RE, id)
  assert.equal(typeof e.needsUserConfirmation, 'boolean', id)
  if (e.access === 'read') assert.equal(e.risk, 'none', id)
  else if (e.access === 'preview') assert.notEqual(e.risk, 'none', id)
}
assert.equal(new Set(COMMANDS.map((x) => x.command)).size, COMMANDS.length)

// every command gang_cli's description names is listed: "bond post|topup|…", "fly open-early|launch|invite", single words
const listed = new Set(COMMANDS.map((x) => x.command))
const desc = TOOLS.find((t) => t.name === 'gang_cli').description
for (const m of desc.matchAll(/(?<![\w-])(call-bond|bond|buyback|split|lp|combo|capped|fly|promote) ([a-z-]+(?:\|[a-z-]+)+)/g)) {
  for (const sub of m[2].split('|')) assert.ok(listed.has(`${m[1]} ${sub}`), `gang_cli names ${m[1]} ${sub}`)
}
for (const name of ['create', 'mint', 'withdraw', 'claim', 'release', 'quote', 'list', 'upload-logo', 'creator-fee', 'v3 income', 'version', 'capabilities']) {
  assert.ok(desc.includes(name), `gang_cli names ${name}`)
  assert.ok(listed.has(name), `listed: ${name}`)
}

// every listed command is in the help
const asked = gang('--help')
assert.equal(asked.status, 0, 'asking for the help is not a failure')
const help = asked.stdout
assert.equal(gang('no-such-command').status, 1)
for (const x of COMMANDS) {
  // the Mint Flywheel commands are listed once as gang fly <a|b|…>
  const words = x.command.split(' --')[0]
  const named = words.startsWith('fly ') ? words.slice(4) : `gang ${words}`
  assert.ok(help.includes(named), `in the help: ${x.command}`)
}

// and the other way: a command the help shows is listed, is a tool's, or is an older name. A new write command fails here
const TOOL_COMMANDS = new Set(['preflight', 'trending', 'hot', 'new', 'near-grad', 'info', 'status', 'portfolio', 'notes', 'agents', 'watch', 'buy', 'sell', 'follow', 'execute', 'tx', 'mcp', 'help'])
const firstWords = new Set(COMMANDS.map((x) => x.command.split(' ')[0]))
for (const [, cmd, sub] of help.matchAll(/(?:^ {2}|\| )gang ([a-z][a-z0-9-]*)(?: ([a-z][a-z0-9-]*))?/gm)) {
  if (TOOL_COMMANDS.has(cmd) || cmd === 'token' || cmd === 'fair') continue // gang fair and gang token are older names
  assert.ok(firstWords.has(cmd) || (cmd === 'v3' && sub !== 'income'), `listed: gang ${cmd}`)
  if (['bond', 'call-bond', 'buyback', 'split', 'lp', 'combo', 'capped'].includes(cmd) && sub) assert.ok(listed.has(`${cmd} ${sub}`), `listed: gang ${cmd} ${sub}`)
}

// gang fly's subcommands: the help lists them once, and each is an older name or listed here
const flySubs = help.match(/gang fly <([^>]*\|[^>]*)>/)[1].replace(/\s/g, '').split('|')
const OLDER_NAMES = new Set(['list', 'info', 'status', 'create', 'mint', 'withdraw', 'buy', 'sell', 'claim', 'release', 'tx'])
for (const sub of flySubs) assert.ok(OLDER_NAMES.has(sub) || listed.has(`fly ${sub}`), `listed: gang fly ${sub}`)

// no read entry can send anything without saying so
for (const t of doc.tools) {
  const urlInput = Object.entries(t.input.properties ?? {}).find(([, v]) => v.pattern?.includes('https?'))
  if (t.access === 'read' && urlInput) assert.equal(t.riskIf?.[urlInput[0]]?.needsUserConfirmation, true, `${t.name}: ${urlInput[0]} sends data`)
}
assert.equal(doc.commands.find((x) => x.command === 'creator-fee --claim --to').risk, 'high')
assert.equal(doc.commands.find((x) => x.command === 'upload-logo').needsUserConfirmation, true)
assert.equal(doc.tools.find((t) => t.name === 'gang_sell').riskIf.breakBond.risk, 'high')

// the instructions a host shows up front: some hosts cut them near 2,000 characters
assert.ok(INSTRUCTIONS.length < 2000, `instructions are ${INSTRUCTIONS.length} characters`)

// the command prints the same document, as one JSON object
const printed = gang('capabilities')
assert.equal(printed.status, 0)
assert.deepEqual(JSON.parse(printed.stdout), JSON.parse(JSON.stringify(doc)))

// a failed result: success false, exit 1, a code a program can branch on, the message for people
const bad = gang('buy', '--token', 'nonsense', '--amount', '1')
assert.equal(bad.status, 1)
const failed = JSON.parse(bad.stdout)
assert.equal(failed.success, false)
assert.equal(failed.code, 'USAGE')
assert.equal(typeof failed.error, 'string')

// a failure that doesn't go through fail() exits 1 too
const unreachable = spawnSync(process.execPath, [CLI, 'list', '--kind', 'fair'], { encoding: 'utf8', env: { ...process.env, GANG_TELEMETRY: '0', GANG_UPDATE_CHECK: '0', GANG_API: 'http://127.0.0.1:1' } })
if (JSON.parse(unreachable.stdout).success === false) assert.equal(unreachable.status, 1)

// what each code means, from the messages the CLI really prints
const CODES = [
  ['this wallet holds no Agent ID; V3 create is Agent-only', 'NO_AGENT_ID'],
  ['the inviter holds no Agent ID, so its invite would not count; leave --ref out', 'ERROR'],
  ['post-launch minting needs the Agent ID gate, which this pad has off right now', 'ERROR'],
  ["could not read the token's kind (RPC error)", 'NETWORK'],
  ['fetch failed', 'NETWORK'],
  ['open-early needs at least 3000 shares', 'ERROR'],
  ['--slippage must be a number between 0 and 50', 'USAGE'],
  ['pass exactly one of --amount or --all', 'USAGE'],
  ['give --token or --module, not both', 'USAGE'],
  ['gang combo bind needs --token', 'USAGE'],
  ['use either --all or --amount', 'USAGE'],
  ['execution reverted', 'REVERT'],
  ['NotAgent', 'NotAgent'],
  ['Risk control refused (code 351806)', '351806'],
  ['something else', 'ERROR'],
]
for (const [error, code] of CODES) assert.equal(codeOf({ error }), code, error)
assert.equal(codeOf({ error: 'x', reason: 'not_found' }), 'not_found')
console.log(`capabilities: ${doc.tools.length} tools, ${doc.commands.length} commands, ok`)
