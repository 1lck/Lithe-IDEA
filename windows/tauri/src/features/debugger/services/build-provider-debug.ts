import type { ExtensionProcessOwner } from "@/extensions/run/extension-process-owner";
import { awaitBuildPreparation } from "@/platform/build-provider-operation";
import type { BuildProviderLaunchInputs, RunProcessInstance } from "@/features/run/types/run.types";
import type { DebugAdapterSessionInfo } from "../types/debugger.types";

export type ProviderDebugOptions = NonNullable<BuildProviderLaunchInputs["launchOptions"]["debug"]>;
export interface RegisteredConnectionPlan {
  pluginId: string; adapterID: string; configurationType: string; port: number; arguments: Record<string, unknown>;
  identity: unknown;
  adapter: { adapterID: string; transport: "stdio" | "tcpLanguageServer"; disabledCapabilities: string[] };
  languageId: string | null; command: string | null;
  launch: { serverPath: string; serverArgs: string[]; environment: Record<string, string>; initializationOptions?: unknown; workspaceConfiguration?: unknown };
}
export interface ProviderDebugRequest {
  workspaceId: string; root: string; name: string; configurationType: string; preferredAdapterID?: string;
  isCurrent: () => boolean; signal?: AbortSignal;
}
export interface ProviderDebugPorts {
  processes: Pick<ExtensionProcessOwner, "start" | "stopExecution" | "finished">;
  allocatePort: () => Promise<number>;
  plan: (request: ProviderDebugRequest, port: number) => Promise<RegisteredConnectionPlan>;
  validate: (plan: RegisteredConnectionPlan) => Promise<void>;
  startRun: (options: ProviderDebugOptions, assertCurrent: () => void, signal: AbortSignal) => Promise<RunProcessInstance | null>;
  stopRun: (instance: RunProcessInstance) => Promise<void>;
  watchRun?: (instance: RunProcessInstance, ended: () => void) => () => void;
  reportCleanupFailure?: (error: unknown) => void;
  waitForPort: (port: number, signal: AbortSignal) => Promise<void>;
  startAdapter: (plan: RegisteredConnectionPlan, onStarted: (session: DebugAdapterSessionInfo) => void, assertCurrent: () => void, signal: AbortSignal) => Promise<DebugAdapterSessionInfo>;
  stopAdapter: (id: string) => Promise<void>;
  onStarted: (session: DebugAdapterSessionInfo, instance: RunProcessInstance, stop: () => Promise<void>) => void;
  guard: () => (pluginId: string) => void;
  unavailable: () => Error;
}

/** The adapter package and exact Run execution have one owner from the first
 * await. Every late native acknowledgement drains before mutation may proceed. */
export function startBuildProviderDebug(request: ProviderDebugRequest, ports: ProviderDebugPorts) {
  const id = `build-debug:${crypto.randomUUID()}`, cancellation = new AbortController(), guard = ports.guard();
  const pending = new Set<Promise<unknown>>();
  let plan: RegisteredConnectionPlan | undefined, instance: RunProcessInstance | undefined, adapter: string | undefined;
  let cleanup: Promise<void> | undefined;
  let unwatch: (() => void) | undefined;
  const assertCurrent = () => {
    cancellation.signal.throwIfAborted();
    if (!request.isCurrent()) throw new DOMException("Aborted", "AbortError");
    if (plan) guard(plan.pluginId);
  };
  const wait = <T,>(task: Promise<T>) => {
    pending.add(task); const remove = () => { pending.delete(task); }; void task.then(remove, remove);
    return awaitBuildPreparation(task, cancellation.signal);
  };
  const release = () => {
    if (cleanup) return cleanup;
    cleanup = (async () => {
      unwatch?.(); unwatch = undefined;
      // Stop both even when one cleanup fails, retaining failed resources so a
      // retry cannot accidentally stop a replacement Run with the same tab ID.
      const results = await Promise.allSettled([
        adapter ? ports.stopAdapter(adapter).then(() => { adapter = undefined; }) : Promise.resolve(),
        instance ? ports.stopRun(instance).then(() => { instance = undefined; }) : Promise.resolve(),
      ]);
      const failure = results.find((result): result is PromiseRejectedResult => result.status === "rejected");
      if (failure) throw failure.reason;
    })();
    void cleanup.catch(() => { cleanup = undefined; }); return cleanup;
  };
  const stop = () => ports.processes.stopExecution(id);
  const abort = () => { cancellation.abort(); };
  request.signal?.addEventListener("abort", abort, { once: true });
  if (request.signal?.aborted) abort();
  const completion = ports.processes.start(id, request.workspaceId, "", async bind => {
    assertCurrent(); const port = await wait(ports.allocatePort()); assertCurrent();
    plan = await wait(ports.plan(request, port)); assertCurrent(); bind(plan.pluginId);
    if (plan.port !== port || plan.configurationType !== request.configurationType
        || (request.preferredAdapterID !== undefined && plan.adapterID !== request.preferredAdapterID)) throw ports.unavailable();
    await wait(ports.validate(plan)); assertCurrent();
    // Assign inside the tracked promise: cancellation can beat its IPC ack.
    const started = await wait(ports.startRun({ adapterID: plan.adapterID, configurationType: plan.configurationType,
      target: { kind: "connection", host: "127.0.0.1", port } }, assertCurrent, cancellation.signal).then(value => { instance = value ?? undefined; return value; }));
    assertCurrent(); if (!started) throw ports.unavailable();
    unwatch = ports.watchRun?.(started, () => {
      cancellation.abort();
      void stop().catch(error => ports.reportCleanupFailure?.(error));
    });
    assertCurrent();
    await wait(ports.validate(plan)); assertCurrent();
    await wait(ports.waitForPort(port, cancellation.signal)); assertCurrent();
    await wait(ports.validate(plan)); assertCurrent();
    const session = await wait(ports.startAdapter(plan, session => {
      adapter = session.id; assertCurrent(); ports.onStarted(session, started, stop);
    }, assertCurrent, cancellation.signal).then(session => { adapter = session.id; return session; }));
    assertCurrent(); await wait(ports.validate(plan)); assertCurrent();
  }, async () => {
    while (pending.size) await Promise.allSettled([...pending]);
    await release();
  }, { cancel: abort, stopOnFailedStart: true }).catch(async error => {
    while (pending.size) await Promise.allSettled([...pending]);
    await release(); ports.processes.finished(id); throw error;
  }).finally(() => { request.signal?.removeEventListener("abort", abort); });
  return { completion, stop };
}
