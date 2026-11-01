() => {
  'use strict';
  if (window.__litheJavaWorkflow) throw new Error('Java workflow observer already active');
  const internals = window.__TAURI_INTERNALS__, originalInvoke = internals.invoke;
  const originalFetch = window.fetch, pending = new Set(), registrations = [];
  const state = { calls: [], dropped: 0, errors: [] };
  const keep = value => JSON.parse(JSON.stringify(value, (key, item) =>
    ['environment', 'env', 'workspaceConfiguration', 'initializationOptions'].includes(key) ? undefined : item));
  const observed = function(input, options) {
    let call;
    try {
      const url = new URL(typeof input === 'string' ? input : input.url, window.location.href);
      const nativeCommand = decodeURIComponent(url.pathname.slice(1));
      if (url.hostname === 'ipc.localhost') {
        const body = JSON.parse(options.body);
        const command = nativeCommand === 'platform_invoke' ? body.command : nativeCommand;
        if (command === 'core_execute' || command === 'save_document_file' ||
            command.startsWith('run_') || command.startsWith('declarative_plugins_generator_') ||
            command.startsWith('declarative_plugins_build_')) {
          const args = nativeCommand === 'platform_invoke' ? body.args : body;
          call = { sequence: state.calls.length + state.dropped, command,
            args: command === 'core_execute' ? {} : keep(args), settled: false };
          if (command === 'core_execute') call.core = keep(JSON.parse(args.request));
          if (state.calls.length < 8192) state.calls.push(call); else state.dropped++;
          let finish;
          const completion = new Promise(resolve => { finish = resolve; });
          pending.add(completion);
          for (const [header, key] of [['Tauri-Callback', 'value'], ['Tauri-Error', 'error']]) {
            const id = Number(options.headers.get(header)), callback = internals.callbacks.get(id);
            if (typeof callback !== 'function') throw new Error('native IPC callback unavailable');
            const wrapper = function(value) {
              try {
                call[key] = key === 'error' ? String(value) :
                  keep(command === 'core_execute' && typeof value === 'string' ? JSON.parse(value) : value);
                call.settled = true;
              } catch (error) { state.errors.push(String(error)); }
              pending.delete(completion); finish();
              return callback.apply(this, arguments);
            };
            registrations.push({ id, callback, wrapper });
            internals.callbacks.set(id, wrapper);
          }
        }
      }
    } catch (error) { state.errors.push(String(error)); }
    // Observation cannot alter dispatch, native return values, errors or callbacks.
    return originalFetch.apply(this, arguments);
  };
  window.fetch = observed;
  if (window.fetch !== observed) throw new Error('native fetch observation unavailable');
  state.snapshot = () => ({ calls: state.calls, dropped: state.dropped, errors: state.errors });
  state.stop = async () => {
    if (internals.invoke !== originalInvoke || window.fetch !== observed)
      throw new Error('native transport changed while observing Java workflow');
    window.fetch = originalFetch;
    let deadline;
    try {
      await Promise.race([Promise.allSettled([...pending]),
        new Promise(resolve => { deadline = setTimeout(resolve, 10000); })]);
    } finally { clearTimeout(deadline); }
    // A continuous LSP event poll may outlive the observation deadline. Give
    // its original handlers back without cancelling or replacing the reply.
    // Never overwrite a handler another owner has already replaced/removed.
    for (const { id, callback, wrapper } of registrations) {
      if (internals.callbacks.get(id) === wrapper) internals.callbacks.set(id, callback);
    }
    const callbackWrappersRetained = registrations.filter(({ id, wrapper }) => internals.callbacks.get(id) === wrapper).length;
    delete window.__litheJavaWorkflow;
    return { ...state.snapshot(), pending: pending.size,
      callbackWrappersRetained,
      originalInvokeRestored: internals.invoke === originalInvoke && window.fetch === originalFetch };
  };
  window.__litheJavaWorkflow = state;
}
