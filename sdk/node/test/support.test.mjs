import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { encodeFrame, FrameDecoder, FramingError } from '../src/framing.mjs';
import { createBackend, openStateStore, runProcess } from '../src/index.mjs';
import { runningProcessCount } from '../src/process.mjs';
import { gate, TestHost, WAIT_MILLISECONDS, withTimeout } from './harness.mjs';

function temporaryDirectory(t) {
  const directory = mkdtempSync(join(tmpdir(), 'lithe-sdk-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  return directory;
}

/** Bounded poll of an OS-level fact the test cannot be notified about. */
async function eventually(check, description) {
  const deadline = Date.now() + WAIT_MILLISECONDS;
  while (!check()) {
    if (Date.now() > deadline) throw new Error(`Timed out waiting for ${description}.`);
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

function isAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

test('frames split across chunks, or several in one chunk, decode in order', () => {
  const decoder = new FrameDecoder();
  const bytes = Buffer.concat([encodeFrame({ id: 1, text: 'é✓' }), encodeFrame({ id: 2 })]);
  const messages = [];
  for (let index = 0; index < bytes.length; index += 3) {
    messages.push(...decoder.push(bytes.subarray(index, index + 3)));
  }
  assert.deepEqual(messages, [{ id: 1, text: 'é✓' }, { id: 2 }]);
  assert.throws(() => new FrameDecoder().push(Buffer.from('Content-Length: 999999999999\r\n\r\n')), FramingError);
  assert.throws(() => new FrameDecoder().push(Buffer.from('X-Other: 1\r\n\r\n')), FramingError);
});

test('runProcess captures output and resolves a non-zero exit', async () => {
  const result = await runProcess(process.execPath, ['-e', 'process.stdout.write("out"); process.stderr.write("err"); process.exit(3)']);
  assert.deepEqual(
    { exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr, truncated: result.truncated },
    { exitCode: 3, stdout: 'out', stderr: 'err', truncated: false },
  );
  const limited = await runProcess(process.execPath, ['-e', 'process.stdout.write("x".repeat(100))'], { maxOutputBytes: 10 });
  assert.equal(limited.stdout, 'xxxxxxxxxx');
  assert.ok(limited.truncated);
});

test('cancelling a call ends the process tree it started', { skip: process.platform === 'win32' && 'POSIX process groups' }, async (t) => {
  const directory = temporaryDirectory(t);
  const grandchildPid = join(directory, 'grandchild.pid');
  // The child starts a grandchild that ignores SIGTERM, so only the group's
  // forced stop can end it.
  const grandchild = `process.on("SIGTERM", () => {}); require("fs").writeFileSync(${JSON.stringify(grandchildPid)}, String(process.pid)); setInterval(() => {}, 1000);`;
  const child = `require("child_process").spawn(process.execPath, ["-e", ${JSON.stringify(grandchild)}], { stdio: "ignore" }); setInterval(() => {}, 1000);`;
  const started = gate();
  const backend = createBackend().function('tool.run', async (_params, context) => {
    const running = context.run(process.execPath, ['-e', child], { killGraceMilliseconds: 50 });
    started.open();
    return running;
  });
  const host = new TestHost(backend);
  await host.initialize();
  const response = host.request('lithe/function/invoke', { functionID: 'tool.run', operationID: 'g' }, 7);
  await withTimeout(started.opened, 'the tool to start');
  await eventually(() => existsSync(grandchildPid) && readFileSync(grandchildPid, 'utf8').length > 0, 'the grandchild');
  const pid = Number(readFileSync(grandchildPid, 'utf8'));
  host.notify('$/cancelRequest', { id: 7 });
  assert.equal((await response).error.code, -32800);
  await eventually(() => !isAlive(pid), 'the grandchild to be stopped');
  await eventually(() => runningProcessCount() === 0, 'the registry to drain');
  await host.close();
});

test('closing the session ends tools still running', { skip: process.platform === 'win32' && 'POSIX process groups' }, async (t) => {
  const directory = temporaryDirectory(t);
  const childPid = join(directory, 'child.pid');
  const started = gate();
  const backend = createBackend().function('tool.run', (_params, context) => {
    const running = context.run(process.execPath, [
      '-e',
      `process.on("SIGTERM", () => {}); require("fs").writeFileSync(${JSON.stringify(childPid)}, String(process.pid)); setInterval(() => {}, 1000);`,
    ]);
    started.open();
    return running;
  });
  const host = new TestHost(backend);
  await host.initialize();
  // No reply is awaited: the session ends while the call is still running.
  host.send({ id: 8, method: 'lithe/function/invoke', params: { functionID: 'tool.run', operationID: 'h' } });
  await withTimeout(started.opened, 'the tool to start');
  await eventually(() => existsSync(childPid) && readFileSync(childPid, 'utf8').length > 0, 'the child');
  const pid = Number(readFileSync(childPid, 'utf8'));
  assert.equal(await host.close(), 1);
  await eventually(() => !isAlive(pid), 'the child to be killed');
});

test('the state store writes atomically and survives reopening', (t) => {
  const directory = join(temporaryDirectory(t), 'workspace-state');
  const store = openStateStore(directory, { packageDirectory: null });
  assert.equal(store.read('snapshot', 'none'), 'none');
  store.write('snapshot', { generation: 1 });
  store.write('snapshot', { generation: 2 });
  assert.deepEqual(openStateStore(directory, { packageDirectory: null }).read('snapshot'), { generation: 2 });
  assert.deepEqual(readdirSync(directory), ['snapshot.json']);
  writeFileSync(join(directory, 'broken.json'), '{');
  assert.equal(store.read('broken', null), null);
  store.delete('snapshot');
  store.delete('snapshot');
  assert.equal(store.read('snapshot'), undefined);
  for (const key of ['', '../escape', 'a/b', 'x.tmp', '.hidden']) {
    assert.throws(() => store.write(key, 1), (error) => error.code === 'sdk.state.invalidKey', key);
  }
});

test('the state store refuses the read-only plugin package', (t) => {
  const root = temporaryDirectory(t);
  const packageDirectory = join(root, 'package');
  mkdirSync(packageDirectory);
  writeFileSync(join(packageDirectory, 'plugin.json'), '{}');
  assert.throws(
    () => openStateStore(join(packageDirectory, 'state'), { packageDirectory }),
    (error) => error.code === 'sdk.state.readOnlyPackage',
  );
  // Refused before anything was created inside the package.
  assert.ok(!existsSync(join(packageDirectory, 'state')));
  assert.throws(() => openStateStore('relative/state'), (error) => error.code === 'sdk.state.invalidDirectory');
  assert.ok(openStateStore(join(root, 'state'), { packageDirectory }));
});

test('the type declarations name exactly the runtime exports', async () => {
  const runtime = Object.keys(await import('../src/index.mjs')).sort();
  const declarations = readFileSync(new URL('../src/index.d.ts', import.meta.url), 'utf8');
  const declared = [...declarations.matchAll(/^export (?:function|class|const) (\w+)/gm)].map((match) => match[1]);
  assert.deepEqual([...new Set(declared)].sort(), runtime);
});
