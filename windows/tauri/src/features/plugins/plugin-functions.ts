import { invoke } from "@/platform/tauri-core";
import {
  PluginFunctionSession,
  functionFailure,
  type FunctionInput,
  type FunctionPorts,
  type FunctionState,
  type FunctionContext,
  type FunctionFailure,
} from "./plugin-function-session";

interface FunctionCleanupOwner {
  readonly title?: string;
  readonly key?: string;
  readonly input: Pick<FunctionInput, "pluginId" | "actionId" | "operationId">;
  readonly state: Pick<FunctionState, "phase" | "error">;
  cancel(): Promise<void>;
}
const owners = new Set<FunctionCleanupOwner>();
const webOwners = new Map<string, WebFunctionCleanupReceipt>();
interface CleanupRead {
  readers: number;
  receipt?: WebFunctionCleanupReceipt;
}
const cleanupReads = new Map<string, CleanupRead>();
const listeners = new Set<() => void>();
let revision = 0;
function changed() {
  revision++;
  for (const listener of listeners) listener();
}
export const pluginFunctionCleanup = {
  subscribe(listener: () => void) {
    listeners.add(listener);
    return () => {
      listeners.delete(listener);
    };
  },
  revision: () => revision,
  pending: () =>
    [...owners].filter(
      (owner) => owner.state.phase === "cleanupFailed" || owner.state.phase === "stopping",
    ),
};

/** A web request has no settings session. Keep its original native receipt
 * reachable until the original process owner confirms cleanup. */
class WebFunctionCleanupReceipt implements FunctionCleanupOwner {
  readonly input;
  state: Pick<FunctionState, "phase" | "error">;
  private task: Promise<void> | null = null;
  private released = false;
  constructor(
    readonly context: FunctionContext,
    error: FunctionFailure,
    private readonly retry: () => Promise<void>,
    readonly key: string,
  ) {
    this.input = {
      pluginId: context.pluginId,
      actionId: context.functionId || context.actionId,
      operationId: context.operationId,
    };
    this.state = { phase: "cleanupFailed", error };
  }
  failed(error: FunctionFailure) {
    if (this.released) return;
    this.state = { phase: this.task ? "stopping" : "cleanupFailed", error };
    owners.add(this);
    changed();
  }
  hasReleased() {
    return this.released;
  }
  cancel(): Promise<void> {
    if (this.released) return Promise.resolve();
    if (this.task) return this.task;
    this.state = { ...this.state, phase: "stopping" };
    changed();
    const task = Promise.resolve()
      .then(this.retry)
      .then(() => {
        this.released = true;
        owners.delete(this);
        if (webOwners.get(this.key) === this) webOwners.delete(this.key);
        changed();
      })
      .catch((error: unknown) => {
        this.state = { phase: "cleanupFailed", error: functionFailure(error) };
        changed();
      })
      .finally(() => {
        this.task = null;
      });
    this.task = task;
    return task;
  }
}

function cleanupKey(context: FunctionContext) {
  return JSON.stringify([context.window, context.windowIncarnation, context.operationId]);
}

export function retainWebFunctionCleanup(
  context: FunctionContext,
  error: FunctionFailure,
  retry: () => Promise<void>,
) {
  const key = cleanupKey(context);
  let owner = webOwners.get(key);
  if (!owner) {
    owner = new WebFunctionCleanupReceipt({ ...context }, error, retry, key);
    webOwners.set(key, owner);
  }
  const read = cleanupReads.get(key);
  if (read) read.receipt = owner;
  owner.failed(error);
  return owner;
}

/** Only in-flight reads retain the released receipt, so a delayed snapshot cannot
 * recreate a notice after successful cleanup without keeping lifetime tombstones. */
export function beginWebFunctionCleanupRead(context: FunctionContext) {
  const key = cleanupKey(context);
  let read = cleanupReads.get(key);
  if (!read) {
    read = { readers: 0, receipt: webOwners.get(key) };
    cleanupReads.set(key, read);
  }
  read.readers++;
  const currentRead = read;
  let released = false;
  return {
    retain(error: FunctionFailure, retry: () => Promise<void>) {
      if (released || currentRead.receipt?.hasReleased()) return;
      currentRead.receipt = retainWebFunctionCleanup(context, error, retry);
    },
    release() {
      if (released) return;
      released = true;
      currentRead.readers--;
      if (currentRead.readers === 0 && cleanupReads.get(key) === currentRead)
        cleanupReads.delete(key);
    },
  };
}

export function createPluginFunctionSession(
  input: FunctionInput,
  assertCurrent: () => void,
  publish: (state: FunctionState) => void,
  overrides: Partial<Pick<FunctionPorts, "prepare">> = {},
) {
  const ports: FunctionPorts = {
    prepare: (value) =>
      invoke("declarative_plugins_function_prepare", value as unknown as Record<string, unknown>),
    confirm: (operationId) => invoke("declarative_plugins_function_confirm", { operationId }),
    read: (operationId) => invoke("declarative_plugins_function_state", { operationId }),
    cancel: (operationId) => invoke("declarative_plugins_function_cancel", { operationId }),
    assertCurrent,
    wait: (signal) =>
      new Promise<void>((resolve) => {
        const done = () => {
          clearTimeout(timer);
          signal.removeEventListener("abort", done);
          resolve();
        };
        const timer = setTimeout(done, 150);
        signal.addEventListener("abort", done, { once: true });
        if (signal.aborted) done();
      }),
    deadline: (expired) => {
      const timer = setTimeout(expired, 180_000);
      return () => clearTimeout(timer);
    },
  };
  return new PluginFunctionSession(
    input,
    { ...ports, ...overrides },
    publish,
    (owner, retained) => {
      if (retained) owners.add(owner);
      else owners.delete(owner);
      changed();
    },
  );
}
