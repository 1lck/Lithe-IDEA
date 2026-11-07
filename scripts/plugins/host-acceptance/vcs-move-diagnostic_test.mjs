// Offline deterministic assertions. No installed SVN, network, or product.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { assertObservation, bounded, finalize } from './vcs-move-diagnostic-worker.mjs';

const source = { path: 'source.txt', kind: 'file', identity: { ino: '1' },
  sha256: createHash('sha256').update(Buffer.from('source-original\0bytes\r\n')).digest('hex') };
const target = { path: 'target.txt', kind: 'file', identity: { ino: '2' }, sha256: 'intruder' };
const directory = { path: 'target.txt', kind: 'directory', identity: { ino: '3' } };
const state = (tree, entries) => ({ tree, statusXml: '<status>' + Object.entries(entries)
  .map(([path, item]) => `<entry path="${path}"><wc-status item="${item}"/></entry>`).join('') + '</status>' });
const failed = { error: { message: 'svn: E155033: obstruction' } };
const success = { result: {} };

test('missing leaf checks exact endpoint and both WC schedules without granting safety', () => {
  const before = state([source], { 'source.txt': 'normal' });
  const after = state([{ ...source, path: 'target.txt' }], { 'source.txt': 'deleted', 'target.txt': 'added' });
  assert.equal(assertObservation('missing-leaf', before, after, success).safetyPass, false);
  assert.throws(() => assertObservation('missing-leaf', before, { ...after, tree: [{ ...source, path: 'target.txt/source.txt' }] }, success));
  assert.throws(() => assertObservation('missing-leaf', before, { ...after, statusXml: '' }, success));
});

test('file obstruction requires unchanged source and target identities AND added WC schedule', () => {
  const before = state([source, target], { 'source.txt': 'normal', 'target.txt': 'unversioned' });
  const after = state([source, target], { 'source.txt': 'normal', 'target.txt': 'added' });
  const result = assertObservation('target-file', before, after, failed);
  assert.equal(result.wcMetadataChanged, true); assert.equal(result.safetyPass, false);
  assert.throws(() => assertObservation('target-file', before, before, failed));
  assert.throws(() => assertObservation('target-file', before, { ...after, tree: [source, { ...target, identity: { ino: 'replacement' } }] }, failed));
  assert.throws(() => assertObservation('target-file', before, { ...after, tree: [{ ...source, sha256: 'corrupt' }, target] }, failed));
  assert.throws(() => assertObservation('target-file', before, after, success));
});

test('directory obstruction records successful reply as wrong endpoint counterexample', () => {
  const before = state([source, directory], {});
  const after = state([directory, { ...source, path: 'target.txt/source.txt' }],
    { 'source.txt': 'deleted', 'target.txt/source.txt': 'added' });
  const result = assertObservation('target-directory', before, after, success);
  assert.equal(result.exactLeaf, false); assert.equal(result.safetyPass, false);
  assert.throws(() => assertObservation('target-directory', before, { ...after, tree: [{ ...directory, identity: { ino: 'new' } }, after.tree[1]] }, success));
  assert.throws(() => assertObservation('target-directory', before, after, failed));
});

test('injected watchdog fires and clears its timer without wall clock sleeps', async () => {
  let fire, cleared;
  const timers = { setTimeout(callback, ms) { assert.equal(ms, 10); fire = callback; return 7; },
    clearTimeout(id) { cleared = id; } };
  const pending = bounded(new Promise(() => {}), 10, 'case', timers);
  fire(); await assert.rejects(pending, /case deadline/); assert.equal(cleared, 7);
  assert.equal(await bounded(Promise.resolve('done'), 10, 'case', timers), 'done');
  assert.equal(cleared, 7);
});

test('assertion and snapshot errors still run every outer finally cleanup and preserve evidence', async () => {
  const record = {}, order = [];
  try { assert.fail('injected endpoint assertion'); }
  catch (error) { record.error = error.message; }
  finally {
    await finalize(record, {
      final() { order.push('snapshot'); throw Error('SVN status exception'); },
      socketCleanup() { order.push('sockets'); throw Error('socket failure'); },
      processCleanup() { order.push('job-owned-provider'); return { exited: true }; },
    });
  }
  assert.deepEqual(order, ['snapshot', 'sockets', 'job-owned-provider']);
  assert.match(record.error, /endpoint/); assert.match(record.finalError, /status/);
  assert.match(record.socketCleanupError, /socket/); assert.equal(record.processCleanup.exited, true);
});
