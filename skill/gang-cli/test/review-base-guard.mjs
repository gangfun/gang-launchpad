/** Review (base-v1 fix): index.js refuses --base with --promote-days / --vault / untaxed --promote before any chain read; --base-vest without --base is refused first. */
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
const ME = '0x0000000000000000000000000000000000000d3f'
const cli = (args) => { const r = spawnSync(process.execPath, [new URL('../src/index.js', import.meta.url).pathname, ...args], { env: { ...process.env, GANG_TELEMETRY: '0', GANG_TESTNET_RPC_URL: 'http://127.0.0.1:9' }, encoding: 'utf8', timeout: 60_000 }); return `${r.stdout}${r.stderr}` }
const common = ['create', '--name', 'B', '--symbol', 'B', '--testnet', '--calldata', '--from', ME, '--base', '5', '--base-vest', '30']
const pre = (out, re) => { assert.match(out, re, out); assert.doesNotMatch(out, /NETWORK|HTTP request failed/, out) }
pre(cli([...common, '--promote-days', '30']), /--promote-days: --base and --promote/)
pre(cli([...common, '--promote', '10']), /--base and --promote/)
pre(cli([...common, '--vault', '0x0000000000000000000000000000000000000a11']), /--base and --vault/)
pre(cli(['create', '--name', 'B', '--symbol', 'B', '--testnet', '--from', ME, '--base-vest', '30', '--promote', '5']), /--base-vest needs --base/)
console.log('review-base-guard: ok')
