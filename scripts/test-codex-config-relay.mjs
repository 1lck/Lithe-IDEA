#!/usr/bin/env node
import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { EventEmitter, once } from 'node:events';
import { PassThrough, Transform } from 'node:stream';
import { StringDecoder } from 'node:string_decoder';
import { runInNewContext } from 'node:vm';

const source = readFileSync(new URL('../rust/lithe-agent-host/src/codex-config-relay.cjs', import.meta.url), 'utf8');
const upstreamFixture = JSON.parse(readFileSync(new URL('../shared/fixtures/agent/acp-events-v1.json', import.meta.url), 'utf8')).upstream;
const contextFixture = upstreamFixture.codexContextReplay;

// All pipes and the native child are controlled doubles. No subprocess, clock
// sleep, developer CLI, provider key or network is needed for protocol tests.
function relay(t, platform = 'darwin', context = null, nativeRecovery = true, observationBase = null) {
  const child = Object.assign(new EventEmitter(), { stdin: new PassThrough(), stdout: new PassThrough(), signals: [], kill(signal) { this.signals.push(signal); this.emit('stopped'); } });
  const process = Object.assign(new EventEmitter(), {
    env: { CODEX_PATH: 'temporary-launcher', LITHE_CODEX_EXECUTABLE: 'fixture-codex', LITHE_CODEX_STREAM_RETRIES: '4',
      LITHE_CODEX_NATIVE_RECOVERY: nativeRecovery ? '1' : '0', ...(context ? { LITHE_CODEX_CONTEXT_URL: 'http://127.0.0.1:1234/fixture-capability' } : {}),
      ...(observationBase ? { LITHE_CODEX_OBSERVATION_BASE: observationBase } : {}) },
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
    if (name === 'node:http') return { request(url, options, receive) {
      const request = Object.assign(new EventEmitter(), { destroy() {}, end(body) {
        Promise.resolve().then(() => context(url, { ...options, body })).then(async reply => {
          const response = Object.assign(new EventEmitter(), { statusCode: reply.ok ? 200 : 503, destroy() {} });
          receive(response);
          response.emit('data', Buffer.from(JSON.stringify(await reply.json())));
          response.emit('end');
        }, () => request.emit('error', new Error('fixture offline')));
      } });
      return request;
    } };
    throw new Error(`Unexpected dependency ${name}`);
  },
  setTimeout(callback) { timers.push(callback); return { unref() {} }; } });
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

for (const platform of ['darwin', 'win32']) {
  test(`history replay returns only the armed native snapshot on ${platform}`, { timeout: 2000 }, async t => {
    const exchanges = [];
    const context = async (url, options) => {
      exchanges.push({ action: url.split('/').at(-1), payload: JSON.parse(options.body) });
      if (url.endsWith('/report')) r.process.emit('report');
      return { ok: true, async json() { return { ticket: 'load-ticket' }; } };
    };
    const r = relay(t, platform, context, false);
    const forwarded = once(r.child.stdin, 'data', { signal: AbortSignal.timeout(1000) });
    const request = structuredClone(contextFixture.resumeRequest);
    r.write(request);
    await forwarded;
    assert.deepEqual(r.input, [{ ...request, params: { ...request.params, excludeTurns: false } }]);
    // A live/old event before this resume is acknowledged cannot supply history.
    const usage = used => {
      const notification = structuredClone(contextFixture.notification);
      notification.params.tokenUsage.last.totalTokens = used;
      return notification;
    };
    r.notify(usage(999));
    r.notify(contextFixture.resumeResponse);
    const reported = once(r.process, 'report', { signal: AbortSignal.timeout(1000) });
    r.notify(usage(125300));
    await reported;
    r.notify(usage(200000));
    assert.deepEqual(exchanges, [{ action: 'capture', payload: { sessionId: 'session-a' } },
      { action: 'report', payload: { sessionId: 'session-a', ticket: 'load-ticket', used: 125300, size: 300000 } }]);
    assert.equal(r.launches[0][platform === 'win32' ? 1 : 2].env.LITHE_CODEX_CONTEXT_URL, undefined);
    const failure = { method: 'error', params: { error: { message: 'native subscription error' } } };
    r.notify(failure);
    assert.deepEqual(r.output.at(-1), failure, 'subscription recovery and errors remain native');
  });
}

test('unarmed loads and unavailable bridge preserve standard native resume', { timeout: 2000 }, async t => {
  for (const context of [async () => ({ ok: true, async json() { return null; } }), async () => { throw new Error('offline'); }]) {
    const r = relay(t, 'darwin', context);
    const forwarded = once(r.child.stdin, 'data', { signal: AbortSignal.timeout(1000) });
    const request = { id: 7, method: 'thread/resume', params: { threadId: 'session-a', excludeTurns: true } };
    r.write(request);
    await forwarded;
    assert.deepEqual(r.input, [request]);
  }
});

test('invalid counts and events after a new turn cannot become history reports', { timeout: 2000 }, async t => {
  const reports = [];
  const r = relay(t, 'darwin', async (url, options) => {
    if (url.endsWith('/report')) reports.push(JSON.parse(options.body));
    return { ok: true, async json() { return { ticket: 'load-ticket' }; } };
  });
  const forwarded = once(r.child.stdin, 'data', { signal: AbortSignal.timeout(1000) });
  r.write({ id: 1, method: 'thread/resume', params: { threadId: 'session-a' } });
  await forwarded;
  r.notify({ id: 1, result: { thread: { id: 'session-a' } } });
  for (const [used, size] of [[-1, 100], [1.5, 100], [true, 100], [1, 0], [Number.MAX_SAFE_INTEGER + 1, 100]]) {
    r.notify({ method: 'thread/tokenUsage/updated', params: { threadId: 'session-a', tokenUsage: { last: { totalTokens: used }, modelContextWindow: size } } });
  }
  r.notify({ method: 'turn/started', params: { threadId: 'session-a', turn: { id: 'new-turn' } } });
  r.notify({ method: 'thread/tokenUsage/updated', params: { threadId: 'session-a', tokenUsage: { last: { totalTokens: 1 }, modelContextWindow: 100 } } });
  assert.deepEqual(reports, []);
});

test('subscription observation requires native unrestricted routing and preserves account replies', { timeout: 1000 }, t => {
  const base = 'http://127.0.0.1:1234/lithe-fixture/backend-api/codex';
  const r = relay(t, 'darwin', null, false, base);
  const thread = () => ({ id: 2, method: 'thread/start', params: { config: {
    model_provider: 'openai', openai_base_url: base, chatgpt_base_url: 'https://chatgpt.com/backend-api/', features: { apps: true },
  } } });
  r.write(thread());
  assert.equal(r.input.at(-1).params.config.openai_base_url, '', 'Unknown routing keeps the native default');
  for (const routing of [null, { backendOrigin: 'https://chatgpt.com', accountRoutingOverride: 'us' },
    { backendOrigin: 'https://gov.chatgpt.com', accountRoutingOverride: 'NO_CONSTRAINT' }]) {
    r.write({ id: 1, method: 'account/read', params: { refreshToken: false } });
    const response = { id: 1, result: { account: { type: 'chatgpt', email: 'person@example.test' }, workspaceRouting: routing } };
    r.notify(response);
    assert.deepEqual(r.output.at(-1), response);
    r.write(thread());
    assert.equal(r.input.at(-1).params.config.openai_base_url, '', 'Managed or unsupported routing keeps direct inference');
  }
  r.write({ id: 3, method: 'account/read' });
  r.notify({ ...structuredClone(upstreamFixture.codexSubscriptionObservation.accountRead), id: 3 });
  const request = thread();
  r.write(request);
  assert.deepEqual(r.input.at(-1), request, 'Only the confirmed unrestricted account may use the proxy');
  assert.equal(r.launches[0][2].env.LITHE_CODEX_OBSERVATION_BASE, undefined);
  r.notify({ method: 'account/updated', params: {} });
  assert.equal(r.child.signals.length, 1, 'Changing identity closes the observed connection before another request');
  r.write(thread());
  assert.equal(r.input.at(-1).params.config.openai_base_url, '');
});

test('stale or failed account reads cannot enable subscription observation', { timeout: 1000 }, t => {
  const base = 'http://127.0.0.1:1234/lithe-fixture/backend-api/codex';
  const r = relay(t, 'win32', null, false, base);
  r.write({ id: 1, method: 'account/read' });
  r.write({ id: 2, method: 'account/read' });
  r.notify({ id: 1, result: { account: { type: 'chatgpt' }, workspaceRouting: { backendOrigin: 'https://chatgpt.com', accountRoutingOverride: 'NO_CONSTRAINT' } } });
  r.notify({ id: 2, error: { code: -1, message: 'fixture discovery failure' } });
  for (const method of ['thread/start', 'thread/resume', 'thread/fork']) {
    r.write({ id: method, method, params: { config: { openai_base_url: base } } });
    assert.equal(r.input.at(-1).params.config.openai_base_url, '');
  }
});

for (const platform of ['darwin', 'win32']) {
  for (const notification of ['account/updated', 'account/login/completed']) {
    test(`account changes invalidate pending route discovery on ${platform}: ${notification}`, { timeout: 1000 }, t => {
      const base = 'http://127.0.0.1:1234/lithe-fixture/backend-api/codex';
      const r = relay(t, platform, null, false, base);
      const account = id => ({ ...structuredClone(upstreamFixture.codexSubscriptionObservation.accountRead), id });
      const thread = method => ({ id: method, method, params: { config: { openai_base_url: base } } });
      r.write({ id: 1, method: 'account/read' });
      const changed = { method: notification, params: { email: 'person@example.test' } };
      r.notify(changed);
      assert.deepEqual(r.output.at(-1), changed, 'Native account notifications remain unchanged');
      // The email can stay the same when the workspace changes. Only a fresh
      // routing query may authorize the new workspace, never this late reply.
      r.notify(account(1));
      assert.deepEqual(r.output.at(-1), account(1));
      for (const method of ['thread/start', 'thread/resume', 'thread/fork']) {
        r.write(thread(method));
        assert.equal(r.input.at(-1).params.config.openai_base_url, '', 'The previous account cannot authorize observation');
      }
      assert.deepEqual(r.child.signals, [], 'Unobserved native sessions remain connected');
      r.write({ id: 2, method: 'account/read' });
      r.notify(account(2));
      for (const method of ['thread/start', 'thread/resume', 'thread/fork']) {
        const request = thread(method);
        r.write(request);
        assert.deepEqual(r.input.at(-1), request, 'Fresh native discovery can authorize observation');
      }
      r.notify(changed);
      assert.equal(r.child.signals.length, 1, 'The existing observed connection still closes on an account change');
    });
  }
}
