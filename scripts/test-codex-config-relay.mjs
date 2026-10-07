#!/usr/bin/env node
import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { EventEmitter, once } from 'node:events';
import { PassThrough, Transform } from 'node:stream';
import { StringDecoder } from 'node:string_decoder';
import { runInNewContext } from 'node:vm';

const source = readFileSync(new URL('../rust/lithe-agent-host/src/codex-config-relay.cjs', import.meta.url), 'utf8');

// All pipes and the native child are controlled doubles. No subprocess, clock
// sleep, developer CLI, provider key or network is needed for protocol tests.
function relay(t, platform = 'darwin') {
  const child = Object.assign(new EventEmitter(), { stdin: new PassThrough(), stdout: new PassThrough(), signals: [], kill(signal) { this.signals.push(signal); this.emit('stopped'); } });
  const process = Object.assign(new EventEmitter(), {
    env: { CODEX_PATH: 'temporary-launcher', LITHE_CODEX_EXECUTABLE: 'fixture-codex', LITHE_CODEX_STREAM_RETRIES: '4' },
    argv: ['node', 'fixture-launcher', 'app-server'], platform,
    stdin: new PassThrough(), stdout: new PassThrough(), stderr: new PassThrough(),
  });
  const input = [], output = [], errors = [], launches = [];
  child.stdin.on('data', bytes => input.push(JSON.parse(bytes.toString())));
  process.stdout.on('data', bytes => output.push(JSON.parse(bytes.toString())));
  process.stderr.on('data', bytes => errors.push(bytes.toString()));
  const timers = [];
  t.after(() => {
    for (const stream of [child.stdin, child.stdout, process.stdin, process.stdout, process.stderr]) stream.destroy();
    child.removeAllListeners(); process.removeAllListeners(); timers.length = 0;
  });
  runInNewContext(source, { process, require(name) {
    if (name === 'node:child_process') return { spawn(...args) { launches.push(args); return child; } };
    if (name === 'node:stream') return { Transform };
    if (name === 'node:string_decoder') return { StringDecoder };
    throw new Error(`Unexpected dependency ${name}`);
  }, setTimeout(callback) { timers.push(callback); return { unref() {} }; } });
  return { child, process, input, output, errors, launches,
    write(message) { process.stdin.write(JSON.stringify(message) + '\n'); },
    notify(message) { child.stdout.write(JSON.stringify(message) + '\n'); },
  };
}

test('start, resume and fork preserve routing and other settings while canonicalizing the retry budget', { timeout: 1000 }, t => {
  const r = relay(t);
  for (const method of ['thread/start', 'thread/resume', 'thread/fork']) {
    const config = { model: 'fixture-model', approval_policy: 'on-request', model_providers: {
      'custom-gateway': { name: 'Fixture', base_url: 'https://provider.example/v1', http_headers: { Authorization: 'Bearer fake-key' }, wire_api: 'responses', stream_max_retries: 100 },
      other: { stream_max_retries: 9 },
    }, features: { other_feature: true }, mcp_servers: { fixture: { command: 'fixture-mcp' } },
    'model_providers.custom-gateway.stream_max_retries': 100, 'model_providers.custom-gateway.request_max_retries': 100,
    'features.unbounded_connection_retries': true };
    r.write({ id: method, method, params: { config, cwd: 'fixture-workspace' } });
    const actual = r.input.at(-1);
    const expected = structuredClone(config);
    expected.model_providers['custom-gateway'].stream_max_retries = 4;
    expected.model_providers['custom-gateway'].request_max_retries = 0;
    expected.features.unbounded_connection_retries = false;
    delete expected['model_providers.custom-gateway.stream_max_retries'];
    delete expected['model_providers.custom-gateway.request_max_retries'];
    delete expected['features.unbounded_connection_retries'];
    assert.deepEqual(actual, { id: method, method, params: { config: expected, cwd: 'fixture-workspace' } });
  }
  assert.equal(r.launches[0][2].env.CODEX_PATH, 'fixture-codex');
  assert.equal(r.launches[0][2].env.LITHE_CODEX_EXECUTABLE, undefined);
});

test('unrelated requests and providers are unchanged', { timeout: 1000 }, t => {
  const r = relay(t);
  for (const message of [{ id: 1, method: 'turn/start', params: { input: [{ text: '模型说 401 或重连并不改变策略' }] } },
    { id: 2, method: 'thread/start', params: { config: { model_providers: { other: { stream_max_retries: 7 } } } } }]) {
    r.write(message); assert.deepEqual(r.input.at(-1), message);
  }
});

test('native failures keep structured detail, current turn ownership and monotonic sequence', { timeout: 1000 }, t => {
  const r = relay(t);
  r.notify({ method: 'turn/started', params: { threadId: 'thread-1', turn: { id: 'turn-1' } } });
  const native = { method: 'error', params: { threadId: 'thread-1', turnId: 'turn-1', willRetry: true, error: {
    message: 'Reconnecting... 1/4', additionalDetails: 'fixture HTTP failure', codexErrorInfo: { responseStreamDisconnected: { httpStatusCode: 401 } },
  } } };
  r.notify(native);
  const failure = JSON.parse(r.output.at(-1).params.error.message).litheCodexFailure;
  assert.deepEqual(failure, { message: 'fixture HTTP failure', codexErrorInfo: native.params.error.codexErrorInfo, turnId: 'turn-1', willRetry: true, activeTurn: true, sequence: 1 });
  r.notify({ method: 'turn/completed', params: { threadId: 'thread-1', turn: { id: 'turn-1' } } });
  r.notify(native);
  const late = JSON.parse(r.output.at(-1).params.error.message).litheCodexFailure;
  assert.equal(late.activeTurn, false); assert.equal(late.sequence, 2);
});

test('UTF-8 split between native chunks and normal tool replies stay intact', { timeout: 1000 }, t => {
  const r = relay(t);
  const message = { method: 'item/agentMessage/delta', params: { delta: '中文🙂' } };
  const bytes = Buffer.from(JSON.stringify(message) + '\n');
  for (const byte of bytes) r.child.stdout.write(Buffer.from([byte]));
  assert.deepEqual(r.output, [message]);
});

test('malformed protocol stops the owned child without exposing payload data', { timeout: 2000 }, async t => {
  const r = relay(t);
  const stopped = once(r.child, 'stopped', { signal: AbortSignal.timeout(1000) });
  r.child.stdout.write('private-non-json-payload\n');
  await stopped;
  assert.equal(r.process.exitCode, 1);
  assert.ok(r.child.signals.length > 0);
  assert.equal(r.errors.join(''), 'Codex protocol transport failed.\n');
  r.child.emit('close', 0);
  assert.equal(r.process.exitCode, 1, 'a normal child exit cannot erase transport failure');
});

test('Windows uses the upstream shell launcher for native npm cmd executables', { timeout: 1000 }, t => {
  const r = relay(t, 'win32');
  assert.equal(r.launches[0][0], '"fixture-codex" app-server');
  assert.equal(r.launches[0][1].shell, true);
});
