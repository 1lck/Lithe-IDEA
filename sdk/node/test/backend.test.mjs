import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { createBackend, isFunctionId, PluginError, PluginSdkError } from '../src/index.mjs';
import { gate, TestHost, withTimeout } from './harness.mjs';

const fixture = JSON.parse(
  readFileSync(new URL('../../../shared/contracts/plugins/v1/fixtures/function-protocol.json', import.meta.url), 'utf8'),
);

function functionBackend() {
  return createBackend({ name: 'test-backend', version: '1.0.0' })
    .function('snapshot.refresh', (params) => ({ echoed: params }))
    .function('install.prepare', () => undefined);
}

test('initialize answers the protocols the host offered, with sorted functions', async () => {
  const backend = functionBackend();
  backend.build.model(() => ({ projects: [] }));
  const host = new TestHost(backend);
  const { result } = await host.initialize();
  assert.deepEqual(result.capabilities.experimental, {
    litheBuild: { version: 1 },
    litheFunctions: { version: 1, functions: [{ id: 'install.prepare' }, { id: 'snapshot.refresh' }] },
  });
  assert.deepEqual(result.serverInfo, { name: 'test-backend', version: '1.0.0' });
  assert.deepEqual(backend.negotiated, { functions: true, build: true });
  assert.equal(await host.close(), 1);
});

test('a host that offers nothing gets no Lithe capabilities, and a backend without build handlers never claims litheBuild', async () => {
  const quiet = new TestHost(functionBackend());
  assert.deepEqual((await quiet.initialize({})).result.capabilities.experimental, {});
  await quiet.close();

  const other = new TestHost(functionBackend());
  const answer = (await other.initialize({ litheBuild: { versions: [1] }, litheFunctions: { versions: [2] } })).result;
  assert.deepEqual(answer.capabilities.experimental, {});
  await other.close();
});

test('function IDs follow the shared contract, including the fixture cases', () => {
  for (const id of ['snapshot.refresh', 'install.prepare', 'a', 'x1.y2Z']) assert.ok(isFunctionId(id), id);
  for (const id of ['', 'Not-Valid', 'snapshot..refresh', '1abc', 'a_b', 'é', 'a'.repeat(129)]) {
    assert.ok(!isFunctionId(id), id);
  }
  // Every ID the fixture accepts must also be accepted locally, and the
  // fixture's malformed ID refused, so the SDK never declares what Core rejects.
  for (const testCase of fixture.negotiation) {
    const ids = testCase.capabilities.experimental?.litheFunctions?.functions?.map(({ id }) => id) ?? [];
    if (testCase.name.includes('malformed')) {
      assert.ok(ids.some((id) => !isFunctionId(id)), testCase.name);
    } else if (testCase.expected.functions) {
      assert.ok(ids.every(isFunctionId), testCase.name);
    }
  }
  assert.throws(() => createBackend().function('Bad-ID', () => {}), (error) => error.code === 'sdk.function.invalidID');
  assert.throws(
    () => createBackend().function('a', () => {}).function('a', () => {}),
    (error) => error.code === 'sdk.function.duplicate',
  );
});

test('the lifecycle and the lithe namespace stay reserved for the SDK', async () => {
  const backend = createBackend();
  for (const method of ['initialize', 'shutdown', 'exit', '$/cancelRequest', 'lithe/build/model', 'lithe/anything']) {
    assert.throws(() => backend.onRequest(method, () => {}), PluginSdkError, method);
  }
  assert.throws(
    () => createBackend({ capabilities: { experimental: { litheFunctions: { version: 1 } } } }),
    (error) => error.code === 'sdk.capabilities.reserved',
  );
  const host = new TestHost(backend);
  await host.initialize();
  // A backend never asks the host to dispatch a domain operation or a function.
  for (const method of ['lithe/function/invoke', 'lithe/build/model', 'lithe/host/process.run']) {
    assert.throws(() => backend.sendRequest(method, {}), (error) => error.code === 'sdk.method.reserved', method);
  }
  await host.close();
});

test('requests before initialize are refused with ServerNotInitialized', async () => {
  const host = new TestHost(functionBackend());
  const response = await host.request('lithe/function/invoke', { functionID: 'snapshot.refresh', operationID: 'op', params: {} });
  assert.equal(response.error.code, -32002);
  await host.close();
});

test('an invocation returns its result; undefined becomes null', async () => {
  const host = new TestHost(functionBackend());
  await host.initialize();
  const response = await host.request('lithe/function/invoke', {
    functionID: 'snapshot.refresh',
    operationID: 'op-1',
    params: { project: 'app' },
  });
  assert.deepEqual(response.result, { echoed: { project: 'app' } });
  const empty = await host.request('lithe/function/invoke', { functionID: 'install.prepare', operationID: 'op-2' });
  assert.equal(empty.result, null);
  const unknown = await host.request('lithe/function/invoke', { functionID: 'missing', operationID: 'op-3' });
  assert.equal(unknown.error.code, -32602);
  await host.close();
});

test('progress echoes the operation ID, is bounded, and stops once the call ended', async () => {
  const release = gate();
  let late;
  const backend = createBackend().function('long.task', async (_params, context) => {
    context.progress({ message: 'x'.repeat(2000), percentage: 140.4 });
    context.progress({ message: 'half', percentage: 49.6 });
    late = context.progress;
    await release.opened;
    return 'done';
  });
  const host = new TestHost(backend);
  await host.initialize();
  const response = host.request('lithe/function/invoke', { functionID: 'long.task', operationID: 'wire-7' });
  const first = await host.waitFor((message) => message.method === 'lithe/function/progress');
  assert.equal(first.params.operationID, 'wire-7');
  assert.equal(first.params.message.length, 1024);
  assert.equal(first.params.percentage, 100);
  const second = await host.waitFor((message) => message.params?.message === 'half');
  assert.equal(second.params.percentage, 50);
  release.open();
  assert.equal((await response).result, 'done');
  late({ message: 'too late' });
  await host.close();
  assert.ok(!host.messages.some((message) => message.params?.message === 'too late'));
});

test('a PluginError carries its code; other failures hide their details', async () => {
  const backend = createBackend()
    .function('locked', () => {
      throw new PluginError('maven.snapshotLocked', 'Snapshot is locked.');
    })
    .function('crash', () => {
      throw new Error('ENOENT: no such file, open /Users/someone/secret');
    });
  const host = new TestHost(backend);
  await host.initialize();
  const locked = await host.request('lithe/function/invoke', { functionID: 'locked', operationID: 'a' });
  assert.deepEqual(locked.error, { code: -32000, message: 'Snapshot is locked.', data: { code: 'maven.snapshotLocked' } });
  const crash = await host.request('lithe/function/invoke', { functionID: 'crash', operationID: 'b' });
  assert.equal(crash.error.code, -32603);
  assert.ok(!crash.error.message.includes('/Users/'));
  assert.equal(crash.error.data, undefined);
  assert.throws(() => new PluginError('bad code!', 'x'), TypeError);
  await host.close();
});

test('$/cancelRequest aborts the handler and answers RequestCancelled', async () => {
  const started = gate();
  let observed;
  const backend = createBackend().function('wait.forever', (_params, { signal }) => {
    started.open();
    return new Promise((_, reject) => {
      signal.addEventListener('abort', () => {
        observed = true;
        reject(signal.reason);
      });
    });
  });
  const host = new TestHost(backend);
  await host.initialize();
  const response = host.request('lithe/function/invoke', { functionID: 'wait.forever', operationID: 'c' }, 41);
  await withTimeout(started.opened, 'the handler to start');
  host.notify('$/cancelRequest', { id: 41 });
  assert.equal((await response).error.code, -32800);
  assert.ok(observed);
  await host.close();
});

test('registerFunction and unregisterFunction go through the host, all or nothing', async () => {
  const backend = createBackend();
  const host = new TestHost(backend);
  await host.initialize();

  const registering = backend.registerFunction('late.one', () => 'late');
  const register = await host.waitFor((message) => message.method === 'lithe/function/register');
  assert.deepEqual(register.params, { functions: [{ id: 'late.one' }] });
  host.send({ id: register.id, result: null });
  await registering;
  const call = await host.request('lithe/function/invoke', { functionID: 'late.one', operationID: 'd' });
  assert.equal(call.result, 'late');

  // A refused registration leaves no handler behind.
  const refused = backend.registerFunction('other.one', () => 0);
  const second = await host.waitFor((message) => message.params?.functions?.[0]?.id === 'other.one');
  host.send({ id: second.id, error: { code: -32602, message: 'No.', data: { code: 'plugin.function.invalidRegistration' } } });
  await assert.rejects(refused, (error) => error.code === 'plugin.function.invalidRegistration');
  assert.deepEqual(backend.functionIDs, ['late.one']);

  const unregistering = backend.unregisterFunction('late.one');
  const unregister = await host.waitFor((message) => message.method === 'lithe/function/unregister');
  assert.deepEqual(unregister.params, { ids: ['late.one'] });
  host.send({ id: unregister.id, result: null });
  await unregistering;
  assert.deepEqual(backend.functionIDs, []);
  await host.close();
});

test('build handlers get the canonical format stamped, and a wrong format fails', async () => {
  const backend = createBackend();
  backend.build.model(({ root }) => ({ projects: [{ name: 'app', path: root }] }));
  backend.build.dependencies(() => ({ format: 'litheBuildModel', projects: [] }));
  const host = new TestHost(backend);
  await host.initialize();
  const model = await host.request('lithe/build/model', { buildSystemID: 'sample', root: '.' });
  assert.deepEqual(model.result, { format: 'litheBuildModel', version: 1, projects: [{ name: 'app', path: '.' }] });
  const dependencies = await host.request('lithe/build/dependencies', { buildSystemID: 'sample', root: '.' });
  assert.equal(dependencies.error.code, -32603);
  await host.close();
});

test('a build result cannot replace the version the SDK stamps', async () => {
  const backend = createBackend();
  backend.build.model(() => ({ version: 2, projects: [] }));
  backend.build.dependencies(() => ({ version: 1, dependencies: [] }));
  const host = new TestHost(backend);
  await host.initialize();
  const model = await host.request('lithe/build/model', { buildSystemID: 'sample', root: '.' });
  assert.equal(model.error.code, -32603);
  const dependencies = await host.request('lithe/build/dependencies', { buildSystemID: 'sample', root: '.' });
  assert.deepEqual(dependencies.result, { format: 'litheDependencies', version: 1, dependencies: [] });
  await host.close();
});

test('a result JSON cannot encode, or one over 1 MiB, fails the call and the session continues', async () => {
  const cycle = {};
  cycle.self = cycle;
  const backend = createBackend()
    .function('result.bigint', () => 1n)
    .function('result.cycle', () => cycle)
    .function('result.symbol', () => Symbol('value'))
    .function('result.large', () => 'x'.repeat(1 << 20))
    .function('result.fine', () => ({ ok: true }));
  backend.build.model(() => ({ projects: [{ name: 'app', path: '.', size: 1n }] }));
  const host = new TestHost(backend);
  await host.initialize();
  let operation = 0;
  for (const functionID of ['result.bigint', 'result.cycle', 'result.symbol', 'result.large']) {
    const response = await host.request('lithe/function/invoke', { functionID, operationID: `op-${operation++}` });
    assert.equal(response.error?.code, -32603, functionID);
  }
  const model = await host.request('lithe/build/model', { buildSystemID: 'sample', root: '.' });
  assert.equal(model.error?.code, -32603);
  const fine = await host.request('lithe/function/invoke', { functionID: 'result.fine', operationID: 'op-last' });
  assert.deepEqual(fine.result, { ok: true });
  assert.equal(await host.close(), 1);
});

test('build requests are refused when the host did not negotiate litheBuild', async () => {
  const backend = createBackend();
  backend.build.model(() => ({ projects: [] }));
  const host = new TestHost(backend);
  await host.initialize({ litheFunctions: { versions: [1] } });
  const model = await host.request('lithe/build/model', { buildSystemID: 'sample', root: '.' });
  assert.equal(model.error.code, -32601);
  await host.close();
});

test('shutdown cancels running calls and runs hooks; exit after shutdown is code 0', async () => {
  const started = gate();
  const order = [];
  const backend = createBackend()
    .function('wait.forever', (_params, { signal }) => {
      started.open();
      return new Promise((_, reject) => signal.addEventListener('abort', () => reject(signal.reason)));
    })
    .onShutdown(() => order.push('hook'));
  const host = new TestHost(backend);
  await host.initialize();
  const call = host.request('lithe/function/invoke', { functionID: 'wait.forever', operationID: 'e' });
  await withTimeout(started.opened, 'the handler to start');
  const shutdown = await host.request('shutdown');
  assert.equal(shutdown.result, null);
  assert.equal((await call).error.code, -32800);
  assert.deepEqual(order, ['hook']);
  const after = await host.request('lithe/function/invoke', { functionID: 'wait.forever', operationID: 'f' });
  assert.equal(after.error.code, -32600);
  host.notify('exit');
  assert.equal(await withTimeout(host.done, 'exit'), 0);
});

test('exit without shutdown, or a closed input, ends with code 1', async () => {
  const host = new TestHost(createBackend());
  await host.initialize();
  host.notify('exit');
  assert.equal(await withTimeout(host.done, 'exit'), 1);
  assert.equal(await new TestHost(createBackend()).close(), 1);
});

test('a malformed body is answered with a parse error and the session continues', async () => {
  const host = new TestHost(functionBackend());
  const body = Buffer.from('{not json');
  host.input.write(Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`), body]));
  const parseError = await host.waitFor((message) => message.error?.code === -32700);
  assert.equal(parseError.id, null);
  assert.ok((await host.initialize()).result);
  await host.close();
});

test('registering from an initialize hook joins the initial list without a request', async () => {
  const backend = createBackend().function('a.one', () => 1);
  backend.onInitialize(() => {
    void backend.registerFunction('b.two', () => 2);
    void backend.unregisterFunction('a.one');
  });
  const host = new TestHost(backend);
  const { result } = await host.initialize();
  assert.deepEqual(result.capabilities.experimental.litheFunctions.functions, [{ id: 'b.two' }]);
  assert.ok(!host.messages.some((message) => message.method?.startsWith('lithe/function/')));
  await host.close();
});

test('runtime registration needs the negotiated protocol', async () => {
  const backend = createBackend();
  const host = new TestHost(backend);
  await host.initialize({});
  await assert.rejects(backend.registerFunction('late.one', () => 1), (error) => error.code === 'sdk.functions.unavailable');
  await host.close();
});
