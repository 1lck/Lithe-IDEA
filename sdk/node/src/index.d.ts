// Type declarations for the Lithe plugin backend SDK. Keep in sync with the
// `.mjs` sources; `sdk/node/test/support.test.mjs` checks the exported names.

/** Any value JSON can carry. */
export type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue };
export type JsonObject = { [key: string]: JsonValue };

export interface RunProcessOptions {
  cwd?: string;
  /** Replaces the environment when given; Lithe's process markers are carried over regardless. */
  env?: Record<string, string>;
  /** Aborting it ends the whole process tree and rejects with its reason. */
  signal?: AbortSignal;
  /** Captured bytes per stream; default 1 MiB. */
  maxOutputBytes?: number;
  onStdout?: (chunk: string) => void;
  onStderr?: (chunk: string) => void;
  /** Delay between the polite and forced stop; default 2000. */
  killGraceMilliseconds?: number;
}

export interface ProcessResult {
  exitCode: number | null;
  signal: string | null;
  stdout: string;
  stderr: string;
  truncated: boolean;
}

/** Shared by every handler. */
export interface RequestContext {
  /** Aborted when the host cancels the call, the call times out, the session ends, or the call has settled. */
  signal: AbortSignal;
  throwIfCancelled(): void;
  /** `runProcess` bound to this call: its tree ends when the call is cancelled or settles. */
  run(command: string, args?: string[], options?: RunProcessOptions): Promise<ProcessResult>;
  /** Writes a line to stderr, which the host keeps in its log. */
  log(...parts: unknown[]): void;
}

export interface ProgressReport {
  /** Cut to 1024 bytes. */
  message?: string;
  /** Rounded and clamped to 0-100. */
  percentage?: number;
}

export interface FunctionContext extends RequestContext {
  functionID: string;
  /** Opaque per-call ID chosen by Lithe. */
  operationID: string;
  /** Reports progress; ignored once the call has ended. */
  progress(report: ProgressReport): void;
}

export type FunctionHandler = (params: JsonObject, context: FunctionContext) => unknown | Promise<unknown>;
export type BuildHandler = (params: BuildRequestParams, context: RequestContext) => JsonObject | Promise<JsonObject>;

/** Params of `lithe/build/model` and `lithe/build/dependencies`. */
export interface BuildRequestParams {
  buildSystemID: string;
  root: string;
  options: JsonObject;
  optionArguments: string[];
  environment: Record<string, string>;
  /** Dependencies only: the selected project, or null for the workspace. */
  project?: { name: string; path: string } | null;
  [key: string]: unknown;
}

export interface Negotiated {
  functions: boolean;
  build: boolean;
}

export interface BackendOptions {
  name?: string;
  version?: string;
  /** Standard LSP server capabilities; `experimental.litheBuild` and `experimental.litheFunctions` are reserved. */
  capabilities?: JsonObject;
}

export interface ListenOptions {
  input?: NodeJS.ReadableStream;
  output?: NodeJS.WritableStream;
  errorOutput?: NodeJS.WritableStream;
  /** Defaults to `process.exit`; null only resolves the returned promise. */
  exit?: ((code: number) => void) | null;
}

export interface Backend {
  readonly negotiated: Negotiated;
  readonly initializeParams: JsonObject | null;
  readonly functionIDs: string[];
  readonly build: {
    model(handler: BuildHandler): Backend;
    dependencies(handler: BuildHandler): Backend;
  };
  function(id: string, handler: FunctionHandler): Backend;
  registerFunction(id: string, handler: FunctionHandler): Promise<void>;
  unregisterFunction(id: string): Promise<void>;
  onRequest(method: string, handler: (params: unknown, context: RequestContext) => unknown): Backend;
  onNotification(method: string, handler: (params: unknown) => unknown): Backend;
  onInitialize(hook: (event: { params: JsonObject; negotiated: Negotiated }) => unknown): Backend;
  onShutdown(hook: () => unknown): Backend;
  sendRequest(method: string, params?: unknown): Promise<unknown>;
  sendNotification(method: string, params?: unknown): void;
  log(...parts: unknown[]): void;
  listen(options?: ListenOptions): Promise<number>;
}

export function createBackend(options?: BackendOptions): Backend;

export class PluginError extends Error {
  constructor(code: string, message: string, options?: { cause?: unknown });
  readonly code: string;
}

export class PluginSdkError extends Error {
  readonly code: string;
}

export function runProcess(command: string, args?: string[], options?: RunProcessOptions): Promise<ProcessResult>;

export interface StateStore {
  readonly directory: string;
  read<T = JsonValue>(key: string, fallback?: T): T | undefined;
  write(key: string, value: JsonValue): void;
  delete(key: string): void;
}

export function openStateStore(directory: string, options?: { packageDirectory?: string | null }): StateStore;

export function isFunctionId(value: unknown): boolean;

export const LIMITS: Readonly<{
  maxFunctions: number;
  maxFunctionIdBytes: number;
  maxPluginErrorCodeBytes: number;
  maxMessageBytes: number;
  maxResultBytes: number;
}>;
