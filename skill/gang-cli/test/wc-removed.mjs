/**
 * 0.50.1 removed 0.50.0's WalletConnect signing: every way into it (gang wallet …, --wallet, a wc-… request id) is
 * refused with code REMOVED before anything is read or sent, pointing at --from <address> --calldata; ~/.gang/wc is
 * left alone; and nothing of it is left in the package.
 *
 *   node skill/gang-cli/test/wc-removed.mjs
 */
import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { TOOLS } from '../src/mcp.js'
import { capabilities } from '../src/capabilities.js'

const ROOT = fileURLToPath(new URL('..', import.meta.url))
const CLI = join(ROOT, 'src', 'index.js')
const HOME = mkdtempSync(join(tmpdir(), 'gang-wc-removed-'))
// a leftover ~/.gang/wc from 0.50.0: never read, never touched
mkdirSync(join(HOME, '.gang', 'wc'), { recursive: true })
writeFileSync(join(HOME, '.gang', 'wc', 'session.json'), '{"topic":"x"}')
const env = {
  ...process.env, HOME, GANG_TELEMETRY: '0', GANG_UPDATE_CHECK: '0', GANG_API: 'http://127.0.0.1:1/api', GANG_RPC_URL: 'http://127.0.0.1:1', PATH: '/usr/bin:/bin',
}
const run = (...argv) => {
  const r = spawnSync(process.execPath, [CLI, ...argv], { env, encoding: 'utf8', timeout: 15_000 })
  return { status: r.status, out: JSON.parse(r.stdout) }
}

try {
  const T = '0x0000000000000000000000000000000000000001'
  for (const argv of [
    ['wallet', 'connect'], ['wallet', 'connect', '--testnet', '--no-wait'], ['wallet', 'status'], ['wallet', 'disconnect'], ['wallet'],
    ['buy', '--token', T, '--amount', '1', '--wallet', 'wc'], ['sell', '--token', T, '--all', '--wallet', 'wc'], ['buy', '--token', T, '--amount', '1', '--wallet=wc'],
    ['create', '--name', 'X', '--symbol', 'X', '--wallet', 'wc'], ['execute', '--request-id', `wc-${'0'.repeat(24)}`],
  ]) {
    const r = run(...argv)
    assert.equal(r.status, 1, argv.join(' '))
    assert.equal(r.out.code, 'REMOVED', argv.join(' '))
    assert.match(r.out.error, /^WalletConnect was removed in 0\.50\.1; trade from your own wallet on gang\.fun's token page, or build the tx with --from <address> --calldata$/)
    assert.match(r.out.hint, /~\/\.gang\/wc .*delete/)
  }
  // the leftover state is ignored, not deleted
  assert.equal(readFileSync(join(HOME, '.gang', 'wc', 'session.json'), 'utf8'), '{"topic":"x"}')
  // a normal execute id is not caught by it
  assert.notEqual(run('execute', '--request-id', 'abc').out.code, 'REMOVED')
  // the help says so, and the --from --calldata path is still there
  const help = spawnSync(process.execPath, [CLI, '--help'], { env, encoding: 'utf8' }).stdout
  assert.match(help, /WalletConnect signing \(gang wallet, --wallet wc\) was removed in 0\.50\.1/)
  assert.match(help, /--from <your 0x>\s+--calldata prints the approve tx/)
  assert.doesNotMatch(help, /gang wallet connect|GANG_WC_/)
  // no WalletConnect in the MCP tools, the capabilities, the dependencies or the package
  assert.ok(!TOOLS.some((t) => /wallet_/.test(t.name) || 'wallet' in (t.inputSchema.properties ?? {})))
  assert.ok(!JSON.stringify(capabilities()).includes('walletconnect') && !JSON.stringify(capabilities()).includes('wallet connect'))
  const pkg = JSON.parse(readFileSync(join(ROOT, 'package.json'), 'utf8'))
  assert.deepEqual(Object.keys(pkg.dependencies), ['viem'])
  assert.equal(pkg.devDependencies, undefined)
  assert.equal(pkg.engines.node, '>=18')
  assert.ok(!readFileSync(join(ROOT, 'package-lock.json'), 'utf8').includes('walletconnect'))
  const packed = JSON.parse(execFileSync('npm', ['pack', '--dry-run', '--json', '--ignore-scripts'], { cwd: ROOT, encoding: 'utf8', env: { ...process.env, npm_config_loglevel: 'silent' } }))[0]
  const files = packed.files.map((f) => f.path)
  assert.ok(files.includes('src/index.js'))
  assert.ok(!files.some((f) => /wc\.js$|vendor|shrinkwrap/.test(f)), files.join(', '))
  for (const f of files.filter((x) => x.endsWith('.js'))) {
    assert.ok(!/@walletconnect|qrcode-terminal|eth_sendTransaction/.test(readFileSync(join(ROOT, f), 'utf8')), f)
  }
  console.log(`wc-removed: ok (${files.length} files packed)`)
} finally {
  rmSync(HOME, { recursive: true, force: true })
}
