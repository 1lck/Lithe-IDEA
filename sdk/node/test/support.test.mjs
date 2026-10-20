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

const posixOnly = { skip: process.platform === 'win32' && 'POSIX process groups' };

/** A Node one-liner that records its PID in `file` and runs until stopped. */
function recordsPidAndWaits(file) {
  return `require("fs").writeFileSync(${JSON.stringify(file)}, String(process.pid)); setInterval(() => {}, 1000);`;
}

/** Every PID a test tool recorded, so cleanup still finds it after the temporary directory is gone. */
const recordedPids = new Set();

function recordedPid(file) {
  if (!existsSync(file) || readFileSync(file, 'utf8').length === 0) return undefined;
  const pid = Number(readFileSync(file, 'utf8'));
  recordedPids.add(pid);
  return pid;
}

/** Kills recorded tools still alive, so a failed assertion leaves nothing behind. */
function killRecordedOnExit(t) {
  t.after(() => {
    for (const pid of recordedPids) {
      if (isAlive(pid)) process.kill(pid, 'SIGKILL');
    }
  });
}

test('a call that settles stops the tools its handler left running, and only those', posixOnly, async (t) => {
  const directory = temporaryDirectory(t);
  const failedSibling = join(directory, 'failed-sibling.pid');
  const floating = join(directory, 'floating.pid');
  const other = join(directory, 'other.pid');
  killRecordedOnExit(t);
  const startTool = (context, file) =>
    context.run(process.execPath, ['-e', recordsPidAndWaits(file)], { killGraceMilliseconds: 50 });
  const backend = createBackend()
    .function('parallel.fail', async (_params, context) => {
      const slow = startTool(context, failedSibling);
      await eventually(() => recordedPid(failedSibling) !== undefined, 'the sibling tool');
      await Promise.all([slow, context.run(join(directory, 'missing-tool'))]);
    })
    .function('floating.succeed', async (_params, context) => {
      startTool(context, floating);
      await eventually(() => recordedPid(floating) !== undefined, 'the floating tool');
      return 'done';
    })
    .function('other.run', (_params, context) => startTool(context, other));
  const host = new TestHost(backend);
  await host.initialize();
  const otherCall = host.request('lithe/function/invoke', { functionID: 'other.run', operationID: 'o' }, 40);
  await eventually(() => recordedPid(other) !== undefined, 'the other call’s tool');

  const failed = await host.request('lithe/function/invoke', { functionID: 'parallel.fail', operationID: 'f' });
  assert.equal(failed.error?.code, -32603);
  await eventually(() => !isAlive(recordedPid(failedSibling)), 'the failed call’s sibling tool to stop');
  const succeeded = await host.request('lithe/function/invoke', { functionID: 'floating.succeed', operationID: 's' });
  assert.equal(succeeded.result, 'done');
  await eventually(() => !isAlive(recordedPid(floating)), 'the unawaited tool to stop');

  // Another call's tool was not touched; it ends with its own call.
  assert.ok(isAlive(recordedPid(other)));
  host.notify('$/cancelRequest', { id: 40 });
  assert.equal((await otherCall).error.code, -32800);
  await eventually(() => runningProcessCount() === 0, 'the registry to drain');
  assert.equal(await host.close(), 1);
});

test('a tool that exits normally also ends the workers it left in its group', posixOnly, async (t) => {
  const directory = temporaryDirectory(t);
  const worker = join(directory, 'worker.pid');
  killRecordedOnExit(t);
  // The leader starts a background worker in its own group, waits until it
  // runs, and exits 0 without stopping it.
  const leader = `
    const { existsSync, readFileSync } = require("fs");
    const child = require("child_process").spawn(process.execPath, ["-e", ${JSON.stringify(recordsPidAndWaits(worker))}], { stdio: "ignore" });
    child.unref();
    const deadline = Date.now() + 5000;
    const wait = () => existsSync(${JSON.stringify(worker)}) && readFileSync(${JSON.stringify(worker)}, "utf8") ? process.exit(0)
      : Date.now() > deadline ? process.exit(2) : setTimeout(wait, 10);
    wait();`;
  const result = await runProcess(process.execPath, ['-e', leader]);
  assert.equal(result.exitCode, 0);
  assert.equal(runningProcessCount(), 0);
  await eventually(() => !isAlive(recordedPid(worker)), 'the worker to stop');
});


test('streamed output keeps a character split across chunks whole', async (t) => {
  const directory = temporaryDirectory(t);
  const released = join(directory, 'released');
  // The child writes "a" and the first byte of "中", waits until the parent
  // saw that chunk, then writes the other two bytes, so "中" spans two chunks.
  const child = `
    const { existsSync } = require("fs");
    process.stdout.write(Buffer.from([0x61, 0xe4]));
    const deadline = Date.now() + 5000;
    const wait = () => existsSync(${JSON.stringify(released)}) ? process.stdout.write(Buffer.from([0xb8, 0xad]))
      : Date.now() > deadline ? process.exit(2) : setTimeout(wait, 10);
    wait();`;
  const streamed = [];
  const result = await runProcess(process.execPath, ['-e', child], {
    onStdout: (text) => {
      streamed.push(text);
      writeFileSync(released, '');
    },
  });
  assert.equal(result.exitCode, 0);
  assert.equal(result.stdout, 'a中');
  assert.deepEqual(streamed, ['a', '中']);
});

test('the state store refuses a value JSON would drop and keeps the stored one', (t) => {
  const store = openStateStore(join(temporaryDirectory(t), 'state'), { packageDirectory: null });
  store.write('snapshot', { generation: 8 });
  for (const value of [undefined, () => 1, Symbol('value'), 1n]) {
    assert.throws(() => store.write('snapshot', value), (error) => error.code === 'sdk.state.invalidValue' || error instanceof TypeError);
  }
  assert.deepEqual(store.read('snapshot'), { generation: 8 });
});

test('a header over 8 KiB is refused also when the whole frame arrives at once', () => {
  const header = `Content-Length: 2\r\nX-Padding: ${'x'.repeat(9000)}\r\n\r\n{}`;
  assert.throws(() => new FrameDecoder().push(Buffer.from(header)), FramingError);
});

test('a JSON value that is not a message object is refused and the session continues', async () => {
  const host = new TestHost(createBackend().function('ping', () => 'pong'));
  await host.initialize();
  host.input.write(encodeFrame(null));
  const refused = await host.waitFor((message) => message.id === null && message.error, 'the refusal');
  assert.equal(refused.error.code, -32600);
  const answered = await host.request('lithe/function/invoke', { functionID: 'ping', operationID: 'p' });
  assert.equal(answered.result, 'pong');
  await host.close();
});

test('a shutdown during a slow initialize hook keeps the session closed', async () => {
  const hook = gate();
  const backend = createBackend()
    .function('ping', () => 'pong')
    .onInitialize(() => hook.opened);
  const host = new TestHost(backend);
  const initializing = host.request('initialize', {
    processId: null,
    rootUri: 'file:///workspace',
    capabilities: { experimental: { litheFunctions: { versions: [1] } } },
  });
  const early = await host.request('lithe/function/invoke', { functionID: 'ping', operationID: 'early' });
  assert.equal(early.error.code, -32002);
  assert.equal((await host.request('shutdown')).result, null);
  hook.open();
  assert.equal((await initializing).error?.code, -32600);
  const late = await host.request('lithe/function/invoke', { functionID: 'ping', operationID: 'late' });
  assert.equal(late.error.code, -32600);
  host.notify('exit');
  assert.equal(await withTimeout(host.done, 'the backend to exit'), 0);
});

test('a replaced environment still carries the host process markers', async (t) => {
  const saved = { scope: process.env.LITHE_PROCESS_SCOPE, backend: process.env.LITHE_PLUGIN_BACKEND_SCOPE };
  t.after(() => {
    for (const [name, value] of [['LITHE_PROCESS_SCOPE', saved.scope], ['LITHE_PLUGIN_BACKEND_SCOPE', saved.backend]]) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
  });
  process.env.LITHE_PROCESS_SCOPE = 'instance-1';
  process.env.LITHE_PLUGIN_BACKEND_SCOPE = 'backend-1';
  const print = 'process.stdout.write(JSON.stringify([process.env.LITHE_PROCESS_SCOPE, process.env.LITHE_PLUGIN_BACKEND_SCOPE, process.env.PLUGIN_VALUE]))';
  // A plugin can neither drop nor forge the markers.
  const result = await runProcess(process.execPath, ['-e', print], {
    env: { PLUGIN_VALUE: 'kept', LITHE_PLUGIN_BACKEND_SCOPE: 'forged' },
  });
  assert.deepEqual(JSON.parse(result.stdout), ['instance-1', 'backend-1', 'kept']);
});
