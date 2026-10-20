// The plugin backend session: one process the host starts from the plugin's
// manifest and talks to over stdio with the LSP base protocol. The SDK owns
// everything Lithe manages uniformly -- the lifecycle, protocol negotiation,
// cancellation, error codes, and the `lithe/*` namespace -- and leaves the
// plugin free to decide what its handlers do.
//
// Contract: shared/contracts/plugins/v1/README.md ("Build providers" and
// "Plugin functions").

import { format } from 'node:util';
import { encodeFrame, FrameDecoder, FramingError, MALFORMED } from './framing.mjs';
import { PluginSdkError, toResponseError } from './errors.mjs';
import { killAllProcesses, runProcess } from './process.mjs';
import {
  BUILD_VERSION,
  boundedText,
  ERROR_CODES,
  FUNCTIONS_VERSION,
  isFunctionId,
  isReservedMethod,
  LIMITS,
  METHODS,
} from './protocol.mjs';

/** Canonical result format of each typed build request. */
const BUILD_FORMATS = Object.freeze({
  [METHODS.buildModel]: 'litheBuildModel',
  [METHODS.buildDependencies]: 'litheDependencies',
});

/**
 * Creates a backend. Declare handlers, then call `listen()`.
 *
 * @param {object} [options]
 * @param {string} [options.name] Reported as `serverInfo.name` and used as the log prefix.
 * @param {string} [options.version] Reported as `serverInfo.version`.
 * @param {object} [options.capabilities] Standard LSP server capabilities, for a
 *   backend that is also a language server. `experimental.litheBuild` and
 *   `experimental.litheFunctions` are negotiated by the SDK and cannot be set here.
 */
export function createBackend(options = {}) {
  return new Backend(options);
}

class Backend {
  #name;
  #version;
  #capabilities;
  #functions = new Map();
  #buildHandlers = new Map();
  #requestHandlers = new Map();
  #notificationHandlers = new Map();
  #initializeHooks = [];
  #shutdownHooks = [];
  /** `idle` → `listening` → `initializing` → `ready` → `shuttingDown` → `exited`. */
  #phase = 'idle';
  #negotiated = Object.freeze({ functions: false, build: false });
  #initializeParams = null;
  /** Host requests being handled, by JSON-RPC ID. */
  #incoming = new Map();
  /** Requests this backend sent to the host, by JSON-RPC ID. */
  #outgoing = new Map();
  #nextRequestId = 1;
  /** Serializes register/unregister so the host sees them in call order. */
  #registrations = Promise.resolve();
  #output = null;
  #errorOutput = process.stderr;
  #finish = null;

  /** Typed build-provider handlers (`lithe/build/*`). */
  build;

  constructor({ name = 'lithe-plugin-backend', version, capabilities = {} } = {}) {
    const experimental = capabilities.experimental ?? {};
    if ('litheBuild' in experimental || 'litheFunctions' in experimental) {
      throw new PluginSdkError(
        'sdk.capabilities.reserved',
        'litheBuild and litheFunctions are negotiated by the SDK; declare handlers instead.',
      );
    }
    this.#name = String(name);
    this.#version = version === undefined ? undefined : String(version);
    this.#capabilities = capabilities;
    this.build = Object.freeze({
      /** Answers `lithe/build/model` with a `litheBuildModel` document. */
      model: (handler) => this.#declareBuild(METHODS.buildModel, handler),
      /** Answers `lithe/build/dependencies` with a `litheDependencies` document. */
      dependencies: (handler) => this.#declareBuild(METHODS.buildDependencies, handler),
    });
  }

  /** Protocols the host agreed to in `initialize`; both false before it. */
  get negotiated() {
    return this.#negotiated;
  }

  /** The host's `initialize` params, or null before it arrives. */
  get initializeParams() {
    return this.#initializeParams;
  }

  /** IDs of the functions this backend currently serves, sorted. */
  get functionIDs() {
    return [...this.#functions.keys()].sort();
  }

  /**
   * Declares a plugin function offered from the start, in the `initialize`
   * answer. To add one later, use `registerFunction`.
   *
   * @param {string} id Dot-separated lowerCamelCase segments, such as `snapshot.refresh`.
   * @param {(params: object, context: object) => unknown} handler
   */
  function(id, handler) {
    if (!this.#beforeAnswer()) {
      throw new PluginSdkError('sdk.function.lateDeclaration', 'After initialize, add functions with registerFunction().');
    }
    this.#checkNewFunction(id, handler);
    this.#functions.set(id, handler);
    return this;
  }

  /** Handles a standard LSP request, for a backend that is also a language server. */
  onRequest(method, handler) {
    this.#declareHandler(this.#requestHandlers, method, handler);
    return this;
  }

  /** Handles a standard LSP notification. */
  onNotification(method, handler) {
    this.#declareHandler(this.#notificationHandlers, method, handler);
    return this;
  }

  /** Runs before the `initialize` answer, with `{ params, negotiated }`. */
  onInitialize(hook) {
    this.#initializeHooks.push(hook);
    return this;
  }

  /** Runs on `shutdown`, after running calls were cancelled. */
  onShutdown(hook) {
    this.#shutdownHooks.push(hook);
    return this;
  }

  /**
   * Adds a function. Before the `initialize` answer (including from an
   * `onInitialize` hook) it joins the initial list; afterwards the host must
   * accept it first.
   */
  registerFunction(id, handler) {
    if (this.#beforeAnswer()) {
      return settle(() => {
        this.#checkNewFunction(id, handler);
        this.#functions.set(id, handler);
      });
    }
    return this.#queueRegistration(async () => {
      this.#requireFunctions();
      this.#checkNewFunction(id, handler);
      // Installed before the request: the host may invoke it as soon as its
      // registry changed, before this backend reads the reply.
      this.#functions.set(id, handler);
      try {
        await this.#request(METHODS.functionRegister, { functions: [{ id }] });
      } catch (error) {
        this.#functions.delete(id);
        throw error;
      }
    });
  }

  /** Withdraws a function. The host ends its running calls as revoked. */
  unregisterFunction(id) {
    if (this.#beforeAnswer()) {
      return settle(() => {
        if (!this.#functions.delete(id)) {
          throw new PluginSdkError('sdk.function.unknown', `Function ${id} is not registered.`);
        }
      });
    }
    return this.#queueRegistration(async () => {
      this.#requireFunctions();
      if (!this.#functions.has(id)) {
        throw new PluginSdkError('sdk.function.unknown', `Function ${id} is not registered.`);
      }
      await this.#request(METHODS.functionUnregister, { ids: [id] });
      this.#functions.delete(id);
      for (const call of this.#incoming.values()) {
        if (call.functionID === id) call.controller.abort();
      }
    });
  }

  /** Sends a standard LSP request to the host. `lithe/*` methods are reserved. */
  sendRequest(method, params) {
    this.#checkOutgoing(method);
    return this.#request(method, params);
  }

  /** Sends a standard LSP notification to the host. `lithe/*` methods are reserved. */
  sendNotification(method, params) {
    this.#checkOutgoing(method);
    this.#write({ jsonrpc: '2.0', method, ...(params === undefined ? {} : { params }) });
  }

  /** Writes a diagnostic line to stderr, which the host keeps in its log. */
  log(...parts) {
    this.#errorOutput.write(`[${this.#name}] ${format(...parts)}\n`);
  }

  /**
   * Serves the host until it sends `exit` or closes the input stream, and
   * resolves with the process exit code. With the default `exit`, the process
   * then exits with that code.
   *
   * @param {object} [io]
   * @param {NodeJS.ReadableStream} [io.input] Defaults to stdin.
   * @param {NodeJS.WritableStream} [io.output] Defaults to stdout.
   * @param {NodeJS.WritableStream} [io.errorOutput] Defaults to stderr.
   * @param {((code: number) => void) | null} [io.exit] Defaults to `process.exit`; null only resolves.
   */
  listen({ input = process.stdin, output = process.stdout, errorOutput = process.stderr, exit = (code) => process.exit(code) } = {}) {
    if (this.#phase !== 'idle') {
      throw new PluginSdkError('sdk.listen.repeated', 'A backend listens once.');
    }
    this.#phase = 'listening';
    this.#output = output;
    this.#errorOutput = errorOutput;
    if (output === process.stdout) redirectConsole(errorOutput);

    return new Promise((resolve) => {
      this.#finish = (code) => {
        if (this.#phase === 'exited') return;
        this.#phase = 'exited';
        this.#abortAll();
        killAllProcesses();
        for (const pending of this.#outgoing.values()) {
          pending.reject(new PluginSdkError('sdk.session.closed', 'The session ended.'));
        }
        this.#outgoing.clear();
        input.off?.('data', onData);
        resolve(code);
        exit?.(code);
      };
      const decoder = new FrameDecoder();
      const onData = (chunk) => {
        let messages;
        try {
          messages = decoder.push(chunk);
        } catch (error) {
          if (!(error instanceof FramingError)) throw error;
          this.log('Ending the session:', error.message);
          this.#finish(1);
          return;
        }
        for (const message of messages) this.#dispatch(message);
      };
      input.on('data', onData);
      input.once('end', () => this.#finish(this.#phase === 'shuttingDown' ? 0 : 1));
      input.once('error', () => this.#finish(1));
    });
  }

  #dispatch(message) {
    if (message === MALFORMED) {
      this.#respond(null, undefined, { code: ERROR_CODES.parseError, message: 'The message is not valid JSON.' });
      return;
    }
    // Valid JSON that is not a message object, such as `null` or a batch.
    if (typeof message !== 'object' || message === null || Array.isArray(message)) {
      this.#respond(null, undefined, { code: ERROR_CODES.invalidRequest, message: 'The message is not a JSON-RPC object.' });
      return;
    }
    const hasID = message.id !== undefined && message.id !== null;
    if (typeof message.method !== 'string') {
      if (hasID) this.#settleOutgoing(message);
      return;
    }
    if (hasID) {
      this.#handleRequest(message);
    } else {
      this.#handleNotification(message);
    }
  }

  #handleRequest({ id, method, params }) {
    if (method === METHODS.initialize) {
      void this.#initialize(id, params ?? {});
      return;
    }
    if (method === METHODS.shutdown) {
      void this.#shutdown(id);
      return;
    }
    if (this.#phase === 'listening' || this.#phase === 'initializing') {
      this.#respond(id, undefined, { code: ERROR_CODES.serverNotInitialized, message: 'The backend is not initialized.' });
      return;
    }
    if (this.#phase !== 'ready') {
      this.#respond(id, undefined, { code: ERROR_CODES.invalidRequest, message: 'The backend is shutting down.' });
      return;
    }
    if (method === METHODS.functionInvoke) {
      this.#invokeFunction(id, params ?? {});
      return;
    }
    const build = this.#buildHandlers.get(method);
    if (build && this.#negotiated.build) {
      this.#run(id, null, (context) => build(params ?? {}, context), (result) => buildResult(method, result));
      return;
    }
    const handler = this.#requestHandlers.get(method);
    if (handler) {
      this.#run(id, null, (context) => handler(params, context), (result) => result ?? null);
      return;
    }
    this.#respond(id, undefined, { code: ERROR_CODES.methodNotFound, message: `Unsupported method: ${method}` });
  }

  #handleNotification({ method, params }) {
    if (method === METHODS.exit) {
      this.#finish(this.#phase === 'shuttingDown' ? 0 : 1);
      return;
    }
    if (method === METHODS.cancelRequest) {
      this.#incoming.get(requestKey(params?.id))?.controller.abort();
      return;
    }
    if (this.#phase !== 'ready' || method === METHODS.initialized) return;
    const handler = this.#notificationHandlers.get(method);
    if (!handler) return;
    Promise.resolve()
      .then(() => handler(params))
      .catch((error) => this.log(`Notification ${method} failed:`, error));
  }

  async #initialize(id, params) {
    if (this.#phase !== 'listening') {
      this.#respond(id, undefined, { code: ERROR_CODES.invalidRequest, message: 'initialize was already received.' });
      return;
    }
    this.#phase = 'initializing';
    this.#initializeParams = params;
    const offered = params.capabilities?.experimental ?? {};
    const offers = (entry, version) => Array.isArray(entry?.versions) && entry.versions.includes(version);
    this.#negotiated = Object.freeze({
      functions: offers(offered.litheFunctions, FUNCTIONS_VERSION),
      build: this.#buildHandlers.size > 0 && offers(offered.litheBuild, BUILD_VERSION),
    });
    try {
      for (const hook of this.#initializeHooks) {
        await hook({ params, negotiated: this.#negotiated });
      }
    } catch (error) {
      this.log('initialize failed:', error);
      if (this.#phase === 'initializing') this.#phase = 'listening';
      this.#respond(id, undefined, toResponseError(error));
      return;
    }
    // A shutdown or exit that arrived while a hook ran ended the session;
    // finishing initialize must not reopen it.
    if (this.#phase !== 'initializing') {
      this.#respond(id, undefined, { code: ERROR_CODES.invalidRequest, message: 'The session ended during initialize.' });
      return;
    }
    if (!this.#negotiated.functions && this.#functions.size > 0) {
      this.log('The host did not offer litheFunctions version 1; functions stay unavailable.');
    }
    const experimental = { ...(this.#capabilities.experimental ?? {}) };
    if (this.#negotiated.build) experimental.litheBuild = { version: BUILD_VERSION };
    if (this.#negotiated.functions) {
      experimental.litheFunctions = {
        version: FUNCTIONS_VERSION,
        functions: this.functionIDs.map((functionID) => ({ id: functionID })),
      };
    }
    this.#phase = 'ready';
    this.#respond(id, {
      capabilities: { ...this.#capabilities, experimental },
      serverInfo: { name: this.#name, ...(this.#version ? { version: this.#version } : {}) },
    });
  }

  async #shutdown(id) {
    if (this.#phase !== 'ready' && this.#phase !== 'listening' && this.#phase !== 'initializing') {
      this.#respond(id, undefined, { code: ERROR_CODES.invalidRequest, message: 'shutdown was already received.' });
      return;
    }
    this.#phase = 'shuttingDown';
    this.#abortAll();
    for (const hook of this.#shutdownHooks) {
      try {
        await hook();
      } catch (error) {
        this.log('A shutdown hook failed:', error);
      }
    }
    killAllProcesses();
    this.#respond(id, null);
  }

  #invokeFunction(id, { functionID, operationID, params }) {
    const handler = this.#negotiated.functions ? this.#functions.get(functionID) : undefined;
    if (!handler) {
      this.#respond(id, undefined, { code: ERROR_CODES.invalidParams, message: `Function ${functionID} is not registered.` });
      return;
    }
    let reporting = true;
    const progress = ({ message, percentage } = {}) => {
      if (!reporting) return;
      const report = { operationID };
      if (message !== undefined) report.message = boundedText(message);
      if (Number.isFinite(percentage)) report.percentage = Math.min(100, Math.max(0, Math.round(percentage)));
      this.#write({ jsonrpc: '2.0', method: METHODS.functionProgress, params: report });
    };
    this.#run(
      id,
      functionID,
      (context) => handler(params ?? {}, { ...context, functionID, operationID, progress }),
      functionResult,
      () => {
        reporting = false;
      },
    );
  }

  /** Runs one handler with its own cancellation and answers exactly once. */
  #run(id, functionID, invoke, shape, onSettled) {
    const controller = new AbortController();
    const key = requestKey(id);
    this.#incoming.set(key, { controller, functionID });
    const { signal } = controller;
    const context = {
      signal,
      throwIfCancelled: () => signal.throwIfAborted(),
      run: (command, args, options = {}) => {
        const running = runProcess(command, args, {
          ...options,
          signal: options.signal ? AbortSignal.any([signal, options.signal]) : signal,
        });
        // A tool the handler did not await is stopped when the call ends; its
        // rejection then must not end the backend as an unhandled rejection.
        running.catch(() => {});
        return running;
      },
      log: (...parts) => this.log(...parts),
    };
    Promise.resolve()
      .then(() => invoke(context))
      .then(
        (value) => {
          signal.throwIfAborted();
          return { result: shape(value) };
        },
        (error) => {
          if (!signal.aborted) this.log(`${functionID ? `Function ${functionID}` : 'A request'} failed:`, error);
          return { error: toResponseError(error, signal) };
        },
      )
      .catch((error) => {
        // Shaping the result failed, for example a build result in another format.
        if (!signal.aborted) this.log('The result could not be sent:', error);
        return { error: toResponseError(error, signal) };
      })
      .then(({ result, error }) => {
        onSettled?.();
        this.#incoming.delete(key);
        // Work belongs to its call: tools still running when the handler
        // settled, such as the siblings of a failed `Promise.all`, end now.
        // Other calls have their own controllers and keep running.
        controller.abort(new PluginSdkError('sdk.call.ended', 'The call ended.'));
        this.#respond(id, result, error);
      });
  }

  #declareBuild(method, handler) {
    if (this.#phase !== 'idle') {
      throw new PluginSdkError('sdk.build.lateDeclaration', 'Declare build handlers before listen().');
    }
    if (typeof handler !== 'function') throw new TypeError('A build handler must be a function.');
    this.#buildHandlers.set(method, handler);
    return this;
  }

  #declareHandler(handlers, method, handler) {
    if (typeof method !== 'string' || isReservedMethod(method)) {
      throw new PluginSdkError('sdk.method.reserved', `${method} is managed by the SDK and Lithe.`);
    }
    if (typeof handler !== 'function') throw new TypeError('A handler must be a function.');
    handlers.set(method, handler);
  }

  #checkNewFunction(id, handler) {
    if (!isFunctionId(id)) {
      throw new PluginSdkError(
        'sdk.function.invalidID',
        `Function ID ${JSON.stringify(id)} must be dot-separated lowerCamelCase segments of at most 128 bytes.`,
      );
    }
    if (typeof handler !== 'function') throw new TypeError('A function handler must be a function.');
    if (this.#functions.has(id)) {
      throw new PluginSdkError('sdk.function.duplicate', `Function ${id} is already declared.`);
    }
    if (this.#functions.size >= LIMITS.maxFunctions) {
      throw new PluginSdkError('sdk.function.limit', `A backend serves at most ${LIMITS.maxFunctions} functions.`);
    }
  }

  /** True until the `initialize` answer fixes the initial function list. */
  #beforeAnswer() {
    return this.#phase === 'idle' || this.#phase === 'listening' || this.#phase === 'initializing';
  }

  #requireFunctions() {
    if (this.#phase !== 'ready' || !this.#negotiated.functions) {
      throw new PluginSdkError('sdk.functions.unavailable', 'The host has not negotiated plugin functions.');
    }
  }

  #queueRegistration(change) {
    const next = this.#registrations.then(change);
    this.#registrations = next.catch(() => {});
    return next;
  }

  #checkOutgoing(method) {
    if (typeof method !== 'string' || isReservedMethod(method)) {
      throw new PluginSdkError(
        'sdk.method.reserved',
        `${method} is reserved. A backend never asks the host to run a domain operation or a function.`,
      );
    }
    if (this.#phase !== 'ready') {
      throw new PluginSdkError('sdk.session.notReady', 'The session is not initialized.');
    }
  }

  #request(method, params) {
    const id = `sdk-${this.#nextRequestId++}`;
    return new Promise((resolve, reject) => {
      this.#outgoing.set(id, { resolve, reject, method });
      this.#write({ jsonrpc: '2.0', id, method, ...(params === undefined ? {} : { params }) });
    });
  }

  #settleOutgoing({ id, result, error }) {
    const pending = this.#outgoing.get(id);
    if (!pending) return;
    this.#outgoing.delete(id);
    if (error) {
      const failure = new PluginSdkError(error.data?.code ?? 'sdk.host.error', error.message ?? `${pending.method} failed.`);
      failure.rpcCode = error.code;
      pending.reject(failure);
    } else {
      pending.resolve(result ?? null);
    }
  }

  #abortAll() {
    for (const call of this.#incoming.values()) call.controller.abort();
  }

  #respond(id, result, error) {
    if (this.#phase === 'exited') return;
    try {
      this.#write(error ? { jsonrpc: '2.0', id, error } : { jsonrpc: '2.0', id, result: result ?? null });
    } catch (failure) {
      // A result JSON cannot encode, such as a BigInt or a cycle, must not
      // become an unhandled rejection that ends the whole session.
      this.log('The result could not be encoded:', failure);
      this.#write({ jsonrpc: '2.0', id, error: toResponseError(failure) });
    }
  }

  #write(message) {
    if (!this.#output || this.#phase === 'exited') return;
    this.#output.write(encodeFrame(message));
  }
}

/** Runs `change` now and reports its outcome as a promise. */
function settle(change) {
  try {
    change();
    return Promise.resolve();
  } catch (error) {
    return Promise.reject(error);
  }
}

/** The JSON-RPC ID as a map key; numbers and strings never collide. */
function requestKey(id) {
  return `${typeof id}:${id}`;
}

/**
 * Stamps the canonical format on a build result, so a handler can return the
 * plain document. A result in another format is a backend bug: Core would
 * refuse it as `plugin.build.invalidOutput`, so it fails here with a clear log.
 */
function buildResult(method, result) {
  const expected = BUILD_FORMATS[method];
  if (result === null || typeof result !== 'object' || Array.isArray(result)) {
    throw new PluginSdkError('sdk.build.invalidResult', `${method} must return a ${expected} object.`);
  }
  if (result.format !== undefined && result.format !== expected) {
    throw new PluginSdkError('sdk.build.invalidResult', `${method} returned format ${result.format}, not ${expected}.`);
  }
  if (result.version !== undefined && result.version !== 1) {
    throw new PluginSdkError('sdk.build.invalidResult', `${method} returned version ${result.version}, not 1.`);
  }
  return { ...result, format: expected, version: 1 };
}

/**
 * A function result as the JSON value Core accepts. A value JSON cannot
 * encode, or one over Core's 1 MiB limit, fails here as a backend bug with a
 * log line, instead of breaking the response frame or being refused by Core.
 */
function functionResult(result) {
  let encoded;
  try {
    encoded = JSON.stringify(result ?? null);
  } catch (error) {
    throw new PluginSdkError('sdk.function.invalidResult', `The result is not JSON: ${error.message}`);
  }
  if (encoded === undefined) {
    throw new PluginSdkError('sdk.function.invalidResult', 'The result is not a JSON value.');
  }
  if (Buffer.byteLength(encoded) > LIMITS.maxResultBytes) {
    throw new PluginSdkError('sdk.function.invalidResult', `The result exceeds ${LIMITS.maxResultBytes} bytes.`);
  }
  return result ?? null;
}

/**
 * Sends `console.log`, `info`, and `debug` to stderr. Stdout carries the
 * protocol; a stray line there would corrupt the stream and end the session.
 */
function redirectConsole(errorOutput) {
  const write = (...parts) => errorOutput.write(`${format(...parts)}\n`);
  console.log = write;
  console.info = write;
  console.debug = write;
}
