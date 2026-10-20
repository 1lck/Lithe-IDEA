import { boundedText, ERROR_CODES, isPluginErrorCode } from './protocol.mjs';

/**
 * A failure a handler reports on purpose. Core ends the call with the stable
 * `plugin.function.failed` code and forwards `code` as `pluginErrorCode`, so
 * the plugin's own UI can tell its failures apart. Lithe never branches on it.
 */
export class PluginError extends Error {
  /**
   * @param {string} code Identifier of at most 64 bytes, such as `maven.snapshotLocked`.
   * @param {string} message User-facing text; Core keeps the first 1024 bytes.
   * @param {object} [options] `{ cause }`, kept for logs only.
   */
  constructor(code, message, options) {
    super(message, options);
    if (!isPluginErrorCode(code)) {
      throw new TypeError(
        `Plugin error code ${JSON.stringify(code)} must start with a letter, use letters, digits, ".", "_" or "-", and be at most 64 bytes.`,
      );
    }
    this.name = 'PluginError';
    this.code = code;
  }
}

/** An SDK usage error, raised synchronously to the plugin author. */
export class PluginSdkError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'PluginSdkError';
    this.code = code;
  }
}

/** True for the rejection an aborted `AbortSignal` produces. */
export function isAbort(error, signal) {
  return Boolean(signal?.aborted) && (error === signal.reason || error?.name === 'AbortError');
}

/**
 * The JSON-RPC error object for a handler failure. Only `PluginError` carries
 * a plugin code; any other exception becomes a generic internal error so that
 * stack traces and machine paths never reach the host's UI. A `PluginError`
 * message is shown to the user as written, so it must not contain them either.
 */
export function toResponseError(error, signal) {
  if (isAbort(error, signal)) {
    return { code: ERROR_CODES.requestCancelled, message: 'The request was cancelled.' };
  }
  if (error instanceof PluginError) {
    return {
      code: ERROR_CODES.requestFailed,
      message: boundedText(error.message),
      data: { code: error.code },
    };
  }
  // Unexpected exceptions often embed absolute paths (ENOENT) or internals;
  // the caller logs the details to stderr instead.
  return { code: ERROR_CODES.internalError, message: 'The plugin backend failed unexpectedly.' };
}
