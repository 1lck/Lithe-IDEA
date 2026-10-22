// Wire constants and validation shared with Rust Core
// (rust/lithe-core/src/lsp/interface/plugin_function.rs and
// rust/lithe-core/src/vcs/). The SDK checks the same rules locally so a plugin author sees a mistake when registering a
// handler instead of as a refused session at runtime.

/** Protocol versions this SDK can answer. */
export const FUNCTIONS_VERSION = 1;
export const BUILD_VERSION = 1;
export const VCS_VERSION = 1;

export const METHODS = Object.freeze({
  initialize: 'initialize',
  initialized: 'initialized',
  shutdown: 'shutdown',
  exit: 'exit',
  cancelRequest: '$/cancelRequest',
  functionInvoke: 'lithe/function/invoke',
  functionRegister: 'lithe/function/register',
  functionUnregister: 'lithe/function/unregister',
  functionProgress: 'lithe/function/progress',
  buildModel: 'lithe/build/model',
  buildDependencies: 'lithe/build/dependencies',
  vcsExecution: 'lithe/vcs/execution',
});

/**
 * VCS-provider operations: the handler name a plugin declares, the request
 * Core sends for it, and the capability declaring the handler negotiates.
 * Contract: shared/contracts/vcs-provider-v1.md.
 */
export const VCS_OPERATIONS = Object.freeze({
  status: Object.freeze({ method: 'lithe/vcs/status', capability: 'status' }),
  baseContent: Object.freeze({ method: 'lithe/vcs/baseContent', capability: 'baseContent' }),
  history: Object.freeze({ method: 'lithe/vcs/history', capability: 'history' }),
  fileHistory: Object.freeze({ method: 'lithe/vcs/fileHistory', capability: 'fileHistory' }),
  annotate: Object.freeze({ method: 'lithe/vcs/annotate', capability: 'annotate' }),
  checkin: Object.freeze({ method: 'lithe/vcs/checkin', capability: 'checkin' }),
  rollback: Object.freeze({ method: 'lithe/vcs/rollback', capability: 'rollback' }),
  update: Object.freeze({ method: 'lithe/vcs/update', capability: 'update' }),
  fileOperation: Object.freeze({ method: 'lithe/vcs/fileOperation', capability: 'fileOperations' }),
  resolve: Object.freeze({ method: 'lithe/vcs/resolve', capability: 'conflicts' }),
  cleanup: Object.freeze({ method: 'lithe/vcs/cleanup', capability: 'cleanup' }),
});

/** Handlers every VCS provider must declare; Core refuses a provider without them. */
export const VCS_REQUIRED_OPERATIONS = Object.freeze(['status', 'baseContent', 'checkin', 'rollback']);

/**
 * The provider error codes Core passes on (`error.data.code`). Throw a
 * `PluginError` with one of them; any other code reaches the host as
 * `vcs.provider.failed`.
 */
export const VCS_ERRORS = Object.freeze({
  authenticationFailed: 'vcs.authentication.failed',
  conflict: 'vcs.conflict',
  outOfDate: 'vcs.outOfDate',
  toolUnavailable: 'vcs.tool.unavailable',
  workingCopyLocked: 'vcs.workingCopy.locked',
  workingCopyUnsupported: 'vcs.workingCopy.unsupported',
});

/** JSON-RPC and LSP error codes the SDK answers with. */
export const ERROR_CODES = Object.freeze({
  parseError: -32700,
  invalidRequest: -32600,
  methodNotFound: -32601,
  invalidParams: -32602,
  internalError: -32603,
  serverNotInitialized: -32002,
  requestFailed: -32000,
  requestCancelled: -32800,
});

export const LIMITS = Object.freeze({
  maxFunctions: 256,
  maxFunctionIdBytes: 128,
  maxPluginErrorCodeBytes: 64,
  maxMessageBytes: 1024,
  maxResultBytes: 1 << 20,
  maxVcsIdBytes: 32,
  maxExecutionErrorOutputBytes: 16 * 1024,
});

/** Dot-separated lowerCamelCase segments, for example `snapshot.refresh`. */
export function isFunctionId(value) {
  return (
    typeof value === 'string' &&
    value.length > 0 &&
    Buffer.byteLength(value) <= LIMITS.maxFunctionIdBytes &&
    value.split('.').every((segment) => /^[a-z][A-Za-z0-9]*$/.test(segment))
  );
}

/** A VCS ID: lowercase ASCII letters, digits, and `-`, starting with a letter, such as `svn`. */
export function isVcsId(value) {
  return typeof value === 'string' && value.length <= LIMITS.maxVcsIdBytes && /^[a-z][a-z0-9-]*$/.test(value);
}

/** The plugin error code alphabet Core forwards as `pluginErrorCode`. */
export function isPluginErrorCode(value) {
  return (
    typeof value === 'string' &&
    Buffer.byteLength(value) <= LIMITS.maxPluginErrorCodeBytes &&
    /^[A-Za-z][A-Za-z0-9._-]*$/.test(value)
  );
}

/** Cuts `value` to `limit` UTF-8 bytes without splitting a character. */
export function boundedText(value, limit = LIMITS.maxMessageBytes) {
  const text = String(value ?? '');
  if (Buffer.byteLength(text) <= limit) return text;
  let used = 0;
  let end = 0;
  for (const character of text) {
    const size = Buffer.byteLength(character);
    if (used + size > limit) break;
    used += size;
    end += character.length;
  }
  return text.slice(0, end);
}

/**
 * Methods reserved for the SDK. A plugin cannot install its own handler for
 * these, or send them to the host: the lifecycle belongs to the host's
 * session management, and `lithe/*` belongs to Lithe's typed contracts.
 */
export function isReservedMethod(method) {
  return (
    method === METHODS.initialize ||
    method === METHODS.initialized ||
    method === METHODS.shutdown ||
    method === METHODS.exit ||
    method === METHODS.cancelRequest ||
    method.startsWith('lithe/')
  );
}
