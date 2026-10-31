import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('./java_workflow_observer.js', import.meta.url), 'utf8');

function observer({ settleDeadline } = {}) {
  const callbacks = new Map(), forwarded = [], received = [];
  const invoke = Object.freeze(() => {});
  const fetch = function (...args) { forwarded.push(args); return Promise.resolve('real-transport-result'); };
  const window = { fetch, location: { href: 'http://tauri.localhost' }, __TAURI_INTERNALS__: { invoke, callbacks } };
  const context = vm.createContext({ window, URL,
    setTimeout: settleDeadline ? callback => { queueMicrotask(callback); return 1; } : setTimeout,
    clearTimeout: settleDeadline ? () => {} : clearTimeout });
  vm.runInContext(`(${source})()`, context, { timeout: 1000 });
  function dispatch(command, args, id) {
    callbacks.set(id, value => { received.push(value); return 'original-callback-result'; });
    callbacks.set(id + 1, value => { received.push(value); return 'original-error-result'; });
    const headers = new Map([['Tauri-Callback', String(id)], ['Tauri-Error', String(id + 1)]]);
    const options = { body: JSON.stringify(args), headers };
    return window.fetch(`http://ipc.localhost/${command}`, options);
  }
  return { window, callbacks, forwarded, received, invoke, fetch, dispatch };
}

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
