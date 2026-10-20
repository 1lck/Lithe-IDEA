import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { TestHost } from './harness.mjs';

const sampleBackend = fileURLToPath(new URL('../examples/sample-build/backend/main.mjs', import.meta.url));

/** Starts the sample backend on a workspace with two quick projects, as Lithe would. */
async function startSample(t) {
  const root = mkdtempSync(join(tmpdir(), 'lithe-sample-build-'));
  const workspace = join(root, 'workspace');
  const state = join(root, 'state');
  const quick = ['node', '-e', 'process.exit(0)'];
  for (const name of ['app', 'lib']) mkdirSync(join(workspace, name), { recursive: true });
  mkdirSync(state);
  writeFileSync(
    join(workspace, 'lithe-sample.json'),
    JSON.stringify({ projects: [{ name: 'app', path: 'app', build: quick }, { name: 'lib', path: 'lib', build: quick }] }),
  );
  const child = spawn(process.execPath, [sampleBackend, '--state', state], { stdio: 'pipe' });
  t.after(() => {
    child.kill();
    rmSync(root, { recursive: true, force: true });
  });
  const host = new TestHost(child);
  await host.initialize(undefined, pathToFileURL(workspace).href);
  return host;
}

function build(host, operationID, params) {
  return host.request('lithe/function/invoke', { functionID: 'workspace.build', operationID, params });
}

test('overlapping workspace builds record consecutive snapshot generations', async (t) => {
  const host = await startSample(t);
  // Both calls are in flight before either tool finishes.
  const [first, second] = await Promise.all([build(host, 'op-1', {}), build(host, 'op-2', {})]);
  assert.deepEqual([first.result.generation, second.result.generation].sort(), [1, 2]);
  const latest = await host.request('lithe/function/invoke', { functionID: 'snapshot.read', operationID: 'op-3' });
  assert.equal(latest.result.generation, 2);
  await host.close();
});

test('a selection naming an unknown project fails instead of building nothing', async (t) => {
  const host = await startSample(t);
  for (const [operationID, projects, code] of [
    ['op-1', ['typo'], 'sample.unknownProject'],
    ['op-2', ['app', 'typo'], 'sample.unknownProject'],
    ['op-3', [], 'sample.selection'],
    ['op-4', 'app', 'sample.selection'],
  ]) {
    const response = await build(host, operationID, { projects });
    assert.equal(response.error?.data?.code, code, JSON.stringify(projects));
  }
  const snapshot = await host.request('lithe/function/invoke', { functionID: 'snapshot.read', operationID: 'op-5' });
  assert.equal(snapshot.result, null);
  const selected = await build(host, 'op-6', { projects: ['lib'] });
  assert.deepEqual(selected.result.projects, [{ name: 'lib', exitCode: 0 }]);
  await host.close();
});
