/** Windows: baw is an npm .cmd shim; the CLI runs the shim's script with node, never through a shell. */
import assert from 'node:assert/strict'
import { commandFor, shimEntry } from '../src/winbin.js'

const shim = (p) => `@ECHO off\r\nGOTO start\r\n:find_dp0\r\nSET dp0=%~dp0\r\nEXIT /b\r\n:start\r\nSETLOCAL\r\nCALL :find_dp0\r\n\r\nIF EXIST "%dp0%\\node.exe" (\r\n  SET "_prog=%dp0%\\node.exe"\r\n) ELSE (\r\n  SET "_prog=node"\r\n)\r\n\r\nendLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & "%_prog%"  "%dp0%\\${p}" %*\r\n`
const DIR = 'C:\\Users\\a b\\AppData\\Roaming\\npm'
const SHIM = `${DIR}\\baw.cmd`
const ENTRY = `${DIR}\\node_modules\\@binance\\agentic-wallet\\dist\\index.js`
const NODE = 'C:\\Program Files\\nodejs\\node.exe'
const opts = (files, extra = {}) => ({ platform: 'win32', node: NODE, env: { Path: `.;C:\\other;"${DIR}"` }, exists: (p) => files.includes(p), read: () => shim('node_modules\\@binance\\agentic-wallet\\dist\\index.js'), ...extra })

assert.equal(shimEntry(SHIM, shim('node_modules\\@binance\\agentic-wallet\\dist\\index.js')), ENTRY)
assert.equal(shimEntry(SHIM, shim('..\\..\\evil.js')), null)
assert.equal(shimEntry(SHIM, shim('node_modules\\..\\..\\..\\evil.js')), null)
assert.equal(shimEntry(SHIM, '@echo off\r\ncalc.exe'), null)

assert.equal(shimEntry('C:\\p\\baw.cmd', '"%~dp0\\node.exe"  "%~dp0\\global\\5\\node_modules\\b\\i.js" %*'), 'C:\\p\\global\\5\\node_modules\\b\\i.js')

const args = ['sign', 'a" & calc & %PATH%', '--json']
assert.deepEqual(commandFor('baw', args, opts([SHIM, ENTRY])), [NODE, [ENTRY, ...args]])
assert.deepEqual(commandFor('baw', args, opts([SHIM, ENTRY, 'C:\\other\\baw.exe'])), ['C:\\other\\baw.exe', args])
// nothing usable: the bare name, so execFile reports ENOENT as before; a relative PATH entry is never used
for (const o of [opts([]), opts([SHIM]), opts(['.\\baw.cmd', 'baw.exe']), opts([SHIM, ENTRY], { read: () => 'calc' }), opts([SHIM], { read: () => { throw new Error('EACCES') } }), opts([], { env: {} })]) {
  assert.deepEqual(commandFor('baw', args, o), ['baw', args])
}
assert.deepEqual(commandFor('baw', args, { platform: 'darwin' }), ['baw', args])
console.log('winbin ok')
