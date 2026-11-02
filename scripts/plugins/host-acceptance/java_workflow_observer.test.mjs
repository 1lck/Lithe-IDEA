import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('./java_workflow_observer.js', import.meta.url), 'utf8');

function observer({ settleDeadline, options } = {}) {
  const callbacks = new Map(), forwarded = [], received = [];
  const invoke = Object.freeze(() => {});
  const fetch = function (...args) { forwarded.push(args); return Promise.resolve('real-transport-result'); };
  const window = { fetch, location: { href: 'http://tauri.localhost' }, __TAURI_INTERNALS__: { invoke, callbacks } };
  const context = vm.createContext({ window, URL,
    setTimeout: settleDeadline ? callback => { queueMicrotask(callback); return 1; } : setTimeout,
    clearTimeout: settleDeadline ? () => {} : clearTimeout });
  vm.runInContext(`(${source})(${JSON.stringify(options)})`, context, { timeout: 1000 });
  function dispatch(command, args, id) {
    callbacks.set(id, value => { received.push(value); return 'original-callback-result'; });
    callbacks.set(id + 1, value => { received.push(value); return 'original-error-result'; });
    const headers = new Map([['Tauri-Callback', String(id)], ['Tauri-Error', String(id + 1)]]);
    const options = { body: JSON.stringify(args), headers };
    return window.fetch(`http://ipc.localhost/${command}`, options);
  }
  return { window, callbacks, forwarded, received, invoke, fetch, dispatch };
}

test('native workflow reuses output observation and records real function calls under its own namespace', { timeout: 2000 }, async () => {
  const owner = observer({ options: { namespace: '__litheSettingsAcceptance', includePluginCommands: true } });
  const state = owner.window.__litheSettingsAcceptance;
  assert.equal(owner.window.__litheJavaWorkflow, undefined);
  await owner.dispatch('declarative_plugins_function_state', { operationId: 'native-one' }, 1);
  const value = { phase: 'succeeded', context: { operationId: 'native-one' } };
  owner.callbacks.get(1)(value);
  assert.equal(state.snapshot().calls[0].value.context.operationId, 'native-one');
  const stopped = await state.stop();
  assert.equal(stopped.pending, 0);
  assert.equal(stopped.originalInvokeRestored, true);
  assert.equal(owner.window.__litheSettingsAcceptance, undefined);
});

test('observes actual asynchronous Core reply without changing callback identity or arguments', { timeout: 2000 }, async () => {
  const owner = observer();
  const reply = JSON.stringify({ ok: true, data: { operationId: 'actual' } });
  const result = await owner.dispatch('core_execute', { request: JSON.stringify({ command: 'java.prepareLaunch',
    payload: { sessionId: 'java', environment: { SECRET: 'never record' } } }) }, 1);
  assert.equal(result, 'real-transport-result');
  assert.equal(owner.window.__litheJavaWorkflow.snapshot().calls[0].settled, false);
  assert.equal(owner.callbacks.get(1)(reply), 'original-callback-result');
  assert.equal(owner.received[0], reply);
  const snapshot = owner.window.__litheJavaWorkflow.snapshot();
  assert.equal(snapshot.calls[0].value.data.operationId, 'actual');
  assert.equal(JSON.stringify(snapshot).includes('SECRET'), false);
  assert.equal(JSON.stringify(snapshot).includes('never record'), false);
  const stopped = await owner.window.__litheJavaWorkflow.stop();
  assert.equal(stopped.pending, 0);
  assert.equal(stopped.callbackWrappersRetained, 0);
  assert.equal(stopped.originalInvokeRestored, true);
  assert.equal(owner.window.__TAURI_INTERNALS__.invoke, owner.invoke);
  assert.equal(owner.window.fetch, owner.fetch);
});

test('forwards actual native errors unchanged and unwraps platform routing only for evidence', { timeout: 2000 }, async () => {
  const owner = observer();
  await owner.dispatch('platform_invoke', { command: 'run_start_process', args: { args: { executable: 'java.exe', environment: { TOKEN: 'redact' } } } }, 5);
  const reason = { code: 'native-failure', message: 'refused' };
  assert.equal(owner.callbacks.get(6)(reason), 'original-error-result');
  assert.equal(owner.received[0], reason);
  const snapshot = owner.window.__litheJavaWorkflow.snapshot();
  assert.equal(snapshot.calls[0].command, 'run_start_process');
  assert.equal(snapshot.calls[0].args.args.executable, 'java.exe');
  assert.equal(JSON.stringify(snapshot).includes('TOKEN'), false);
  assert.equal(owner.forwarded.length, 1);
  assert.equal((await owner.window.__litheJavaWorkflow.stop()).originalInvokeRestored, true);
});

test('decode failure is reported while the original callback still receives the exact native value', { timeout: 2000 }, async () => {
  const owner = observer();
  await owner.dispatch('core_execute', { request: JSON.stringify({ command: 'lsp.waitEvents', payload: {} }) }, 10);
  assert.equal(owner.callbacks.get(10)('broken-json'), 'original-callback-result');
  assert.equal(owner.received[0], 'broken-json');
  assert.equal(owner.window.__litheJavaWorkflow.snapshot().errors.length, 1);
  assert.equal((await owner.window.__litheJavaWorkflow.stop()).pending, 0);
});

test('deadline restores unresolved native callbacks and forwards a late real reply', { timeout: 2000 }, async () => {
  const owner = observer({ settleDeadline: true });
  await owner.dispatch('core_execute', { request: JSON.stringify({ command: 'lsp.waitEvents', payload: {} }) }, 20);
  const stopped = await owner.window.__litheJavaWorkflow.stop();
  assert.equal(stopped.pending, 1);
  assert.equal(stopped.callbackWrappersRetained, 0);
  assert.equal(stopped.originalInvokeRestored, true);
  const late = JSON.stringify({ ok: true, data: { events: [] } });
  assert.equal(owner.callbacks.get(20)(late), 'original-callback-result');
  assert.equal(owner.received[0], late);
  assert.equal(stopped.calls[0].settled, false);
});

test('records actual build preparation and approved execution separately without inventing JDT build evidence', { timeout: 2000 }, async () => {
  const owner = observer();
  try {
    await owner.dispatch('platform_invoke', { command: 'declarative_plugins_build_prepare_model', args: {
      workspaceRoot: 'C:/generated/maven', pluginId: 'org.example.maven', buildSystemId: 'maven',
      environment: { SECRET: 'never record' },
    } }, 30);
    const prepared = { operationId: 'actual-model', executesProjectCode: true, mayUseNetwork: true };
    assert.equal(owner.callbacks.get(30)(prepared), 'original-callback-result');
    await owner.dispatch('declarative_plugins_build_load_model', { operationId: 'actual-model' }, 32);
    const loaded = { generation: 4, workspaceRoot: 'C:/generated/maven', instances: [] };
    owner.callbacks.get(32)(loaded);
    await owner.dispatch('declarative_plugins_build_authorize_provider_language', { operationId: 'actual-provider' }, 34);
    const failure = { code: 'plugin.build.staleContext' };
    owner.callbacks.get(35)(failure);
    const calls = owner.window.__litheJavaWorkflow.snapshot().calls;
    assert.deepEqual(Array.from(calls, call => call.command), [
      'declarative_plugins_build_prepare_model', 'declarative_plugins_build_load_model', 'declarative_plugins_build_authorize_provider_language',
    ]);
    assert.equal(calls[1].args.operationId, calls[0].value.operationId);
    assert.equal(calls[2].settled, true);
    assert.equal(owner.received[0], prepared);
    assert.equal(owner.received[1], loaded);
    assert.equal(owner.received[2], failure);
    assert.equal(JSON.stringify(calls).includes('SECRET'), false);
    assert.equal(calls.some(call => call.core?.command === 'java.prepareLaunch'), false);
    assert.equal(owner.forwarded.length, 3);
  } finally {
    assert.equal((await owner.window.__litheJavaWorkflow.stop()).originalInvokeRestored, true);
  }
});

test('restores unresolved build callbacks without replacing a later owner handler', { timeout: 2000 }, async () => {
  const owner = observer({ settleDeadline: true });
  await owner.dispatch('declarative_plugins_build_execute_run', { operationId: 'actual-run' }, 40);
  const laterOwner = () => 'later-owner';
  owner.callbacks.set(40, laterOwner);
  const stopped = await owner.window.__litheJavaWorkflow.stop();
  assert.equal(stopped.pending, 1);
  assert.equal(stopped.calls[0].settled, false);
  assert.equal(stopped.callbackWrappersRetained, 0);
  assert.equal(owner.callbacks.get(40), laterOwner);
  assert.equal(owner.window.fetch, owner.fetch);
});

test('observes real window build events unchanged and restores the listener callback', { timeout: 2000 }, async () => {
  const owner = observer();
  const received = [], listener = event => received.push(event);
  owner.callbacks.set(90, listener);
  try {
    await owner.dispatch('plugin:event|listen', { event: 'declarative-build-output', handler: 90,
      target: { kind: 'Window', label: 'main' } }, 50);
    const event = { payload: { operationId: 'real', pluginId: 'independent-build', generation: 7,
      type: 'terminal', terminal: { kind: 'cancelled' } } };
    owner.callbacks.get(90)(event);
    assert.equal(received[0], event);
    const observed = owner.window.__litheJavaWorkflow.snapshot().events[0];
    assert.equal(observed.operationId, 'real');
    assert.equal(observed.terminal.kind, 'cancelled');
    const stopped = await owner.window.__litheJavaWorkflow.stop();
    assert.equal(stopped.callbackWrappersRetained, 0);
    assert.equal(owner.callbacks.get(90), listener);
    owner.callbacks.get(90)({ payload: { operationId: 'late' } });
    assert.equal(stopped.events.length, 1);
    assert.equal(received.length, 2);
  } finally {
    if (owner.window.__litheJavaWorkflow) await owner.window.__litheJavaWorkflow.stop();
  }
});

test('window listener fanout records each native chunk once while preserving repeated real output', { timeout: 2000 }, async () => {
  const owner = observer();
  let deliveries = 0;
  const target = { kind: 'Window', label: 'main' };
  owner.callbacks.set(100, () => deliveries++);
  owner.callbacks.set(101, () => deliveries++);
  try {
    await owner.dispatch('plugin:event|listen', { event: 'declarative-build-output', handler: 100, target }, 60);
    await owner.dispatch('plugin:event|listen', { event: 'declarative-build-output', handler: 101, target }, 62);
    const event = { payload: { operationId: 'actual', type: 'chunk', text: 'same real text' } };
    for (let index = 0; index < 2; index++) {
      owner.callbacks.get(100)(event);
      owner.callbacks.get(101)(event);
    }
    assert.equal(deliveries, 4);
    assert.equal(owner.window.__litheJavaWorkflow.snapshot().events.length, 2);
    owner.callbacks.delete(100);
    owner.callbacks.get(101)({ payload: { operationId: 'actual', type: 'terminal', terminal: { kind: 'succeeded' } } });
    assert.equal(owner.window.__litheJavaWorkflow.snapshot().events.length, 3);
  } finally {
    assert.equal((await owner.window.__litheJavaWorkflow.stop()).callbackWrappersRetained, 0);
  }
});
