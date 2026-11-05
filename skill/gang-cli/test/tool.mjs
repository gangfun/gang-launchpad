/**
 * Tool tag ("gang" 06 + id) in calldata: written before the ref, the follow ref and the note suffix, read back from that
 * one place only; the other tags still read with it in front of them; a bad GANG_TOOL never fails the step.
 *
 *   node skill/gang-cli/test/tool.mjs
 */
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const dir = mkdtempSync(join(tmpdir(), 'gang-tool-'))
process.env.GANG_NOTES_DIR = join(dir, 'notes')
const { TOOL_MAGIC, followSuffix, hashesIn, makeNote, readFollowRef, readRef, readTool, refSuffix, toolInfo, toolSuffix, withNote, withTool } = await import('../src/notes.js')
const call = '0xa9059cbb' + '00'.repeat(64)
const ref = `0x${'ab'.repeat(20)}`
const noteTx = `0x${'12'.repeat(32)}`

try {
  // --- writing: 17 bytes, ASCII, zero-padded ---
  assert.equal(toolSuffix('ab'), `${TOOL_MAGIC}6162${'00'.repeat(10)}`)
  assert.equal(toolSuffix('watcher-bot1'), `${TOOL_MAGIC}${Buffer.from('watcher-bot1').toString('hex')}`)
  assert.equal(toolSuffix('watcher').length, 34)
  for (const bad of ['', 'a', '-ab', 'AB', 'a_b', 'a b', 'abcdefghijklm', '中文', null, undefined, 'a\0b']) {
    assert.throws(() => toolSuffix(bad), /bad tool id/, String(bad))
  }

  // --- reading, every combination with a ref, a follow ref and a note (v1, v2) ---
  const v1 = makeNote('because', '70'), v2 = makeNote('sealed reason', '60', '6h')
  for (const note of [null, v1, v2]) {
    for (const r of ['', refSuffix(ref)]) {
      for (const f of ['', followSuffix(noteTx)]) {
        const tagged = withNote(call + toolSuffix('watcher') + r + f, note)
        const label = `ref=${!!r} follow=${!!f} note=${note?.revealAfter ? 'v2' : note ? 'v1' : 'none'}`
        assert.equal(readTool(tagged), 'watcher', label)
        assert.equal(readTool(tagged.toUpperCase().replace('0X', '0x')), 'watcher', `any case ${label}`)
        // the older tags read the same with the tool in front of them
        assert.equal(readRef(tagged), r ? ref : null, label)
        assert.equal(readFollowRef(tagged), f ? noteTx : null, label)
        assert.deepEqual(hashesIn(tagged), note ? [note.hash] : [], label)
        assert.equal(readTool(withNote(call + r + f, note)), null, `no tool ${label}`)
      }
    }
  }

  // --- only the one place counts ---
  const t = toolSuffix('watcher')
  assert.equal(readTool(t + call), null) // at the start
  assert.equal(readTool(call + t + refSuffix(ref) + refSuffix(ref)), null) // two refs after it
  assert.equal(readTool(call + t + followSuffix(noteTx) + refSuffix(ref)), null) // tags in the wrong order
  assert.equal(readTool(call + t + '00'), null) // junk after it
  assert.equal(readTool(call + toolSuffix('first') + toolSuffix('second')), 'second') // the last one
  assert.equal(readTool(''), null)
  assert.equal(readTool(null), null)
  assert.equal(readTool('0x1234'), null)
  // not a canonical id: padding in the middle, upper-case bytes, a control byte, too short
  const raw = (ascii) => `${TOOL_MAGIC}${Buffer.from(ascii, 'latin1').toString('hex').padEnd(24, '0')}`
  for (const bad of ['a\0b', 'AB', 'a\x01b', 'a', '-ab']) assert.equal(readTool(call + raw(bad)), null, JSON.stringify(bad))
  assert.equal(readTool(call + `${TOOL_MAGIC}zz${'00'.repeat(11)}`), null)
  // the id "gang" can't be read as another tag: an id never holds a byte under 0x2d
  assert.deepEqual(hashesIn(call + toolSuffix('gang')), [])
  assert.equal(readTool(call + toolSuffix('gang')), 'gang')
  assert.equal(readRef(call + toolSuffix('gang')), null)

  // --- withTool: no id, nothing added or shown ---
  assert.equal(withTool(call, ''), call)
  assert.equal(withTool(call, undefined), call)
  assert.equal(toolInfo(), null)
  // a bad id: untagged, and the result says why
  assert.equal(withTool(call, 'NOT OK'), call)
  assert.equal(toolInfo().attached, false)
  assert.match(toolInfo().reason, /GANG_TOOL/)
  // a good id: tagged
  assert.equal(withTool(call, 'watcher'), call + toolSuffix('watcher'))
  assert.deepEqual(toolInfo(), { attached: true, id: 'watcher' })

  console.log('tool: ok')
} finally {
  rmSync(dir, { recursive: true, force: true })
}
