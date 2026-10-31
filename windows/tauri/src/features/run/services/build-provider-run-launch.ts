import { awaitBuildPreparation } from "@/platform/build-provider-operation";
import type { ExtensionProcessOwner } from "@/extensions/run/extension-process-owner";
import type { BuildWorkspaceController } from "@/features/build/services/build-workspace-controller";
import type { BuildProviderLaunchInputs, BuildProviderRunReference } from "../types/run.types";
import type { resolveRunLaunch, startRunProcess, stopRunProcess } from "../api/run-host-api";

export interface PreparedNativeBuildRun {
  executable: string; arguments: string[]; workingDirectory: string; environment: Record<string, string>;
}
export interface BuildProviderRunRequest {
  workspaceId: string; root: string; configurationId: string; name: string;
  reference: BuildProviderRunReference; sessionId: string; executionId: string;
  debugPort?: number;
  runtimeExecutablePaths: Record<string, string>;
  isCurrent: () => boolean; onRevoked: () => void; onOutput: (text: string) => void; onReady: (launch: PreparedNativeBuildRun) => void;
}
export interface BuildProviderRunHandle { completion: Promise<void>; stop: () => Promise<void>; finished: () => void }
export interface BuildProviderRunPorts {
  workspace: (id: string, root: string) => BuildWorkspaceController | undefined;
  inputs: (root: string, configurationId: string, providerRoot: string) => Promise<BuildProviderLaunchInputs>;
  processes: Pick<ExtensionProcessOwner, "start" | "stopExecution" | "finished">;
  resolve: typeof resolveRunLaunch; start: typeof startRunProcess; stop: typeof stopRunProcess;
  unavailable: () => Error;
}

function sameReference(left: BuildProviderRunReference, right: BuildProviderRunReference): boolean {
  return left.pluginID === right.pluginID && left.buildSystemID === right.buildSystemID && left.root === right.root
    && left.projectID === right.projectID && left.targetID === right.targetID && left.run === right.run
    && (left.execution ?? "application") === (right.execution ?? "application")
    && JSON.stringify(left.userArguments) === JSON.stringify(right.userArguments);
}

/** Provider preparation hands a validated plan to the existing native Run
 * process and declarative-plugin owner. No build command or classpath is made here. */
export function startBuildProviderRun(request: BuildProviderRunRequest, ports: BuildProviderRunPorts): BuildProviderRunHandle {
  const reference = structuredClone(request.reference), controller = new AbortController(), pending = new Set<Promise<unknown>>();
  let stopTask: Promise<void> | undefined, stopFailure: unknown;
  const track = <T,>(task: Promise<T>): Promise<T> => {
    pending.add(task); const done = () => { pending.delete(task); }; void task.then(done, done); return task;
  };
  const wait = <T,>(task: Promise<T>) => awaitBuildPreparation(track(task), controller.signal);
  const assertCurrent = () => { controller.signal.throwIfAborted(); if (!request.isCurrent()) throw new DOMException("Aborted", "AbortError"); };
  const revoke = () => { controller.abort(); if (request.isCurrent()) request.onRevoked(); };
  const stopNative = (): Promise<void> => {
    if (stopTask) return stopTask;
    stopFailure = undefined;
    const task = Promise.resolve().then(() => ports.stop(request.sessionId, request.executionId)); stopTask = task;
    void task.catch(error => { if (stopTask === task) { stopTask = undefined; stopFailure = error; } }); return task;
  };
  const completion = ports.processes.start(request.executionId, request.workspaceId, reference.pluginID, async () => {
    assertCurrent();
    const workspace = ports.workspace(request.workspaceId, request.root);
    if (!workspace) throw ports.unavailable();
    await wait(workspace.ensureDetected()); assertCurrent();
    const entry = workspace.snapshot().entries.find(entry => entry.pluginID === reference.pluginID && entry.buildSystemID === reference.buildSystemID && entry.root === reference.root);
    if (!entry) throw ports.unavailable();
    const catalogCurrent = () => { assertCurrent(); if (!workspace.snapshot().entries.includes(entry)) throw ports.unavailable(); };
    const inputs = await wait(ports.inputs(request.root, request.configurationId, entry.root)); catalogCurrent();
    if (!inputs.reference || !sameReference(reference, inputs.reference) || inputs.buildSystemID !== reference.buildSystemID
      || inputs.provider !== reference.run || inputs.launchOptions.execution !== (reference.execution ?? "application")
      || Object.keys(inputs.optionOverrides).length) throw ports.unavailable();
    await workspace.modelPreparation.ensure(entry, controller.signal, text => { if (request.isCurrent()) request.onOutput(text); }); catalogCurrent();
    const operation = workspace.domain.prepareRun(entry, { run: reference.run, projectID: reference.projectID, targetID: reference.targetID,
      userArguments: [], launchOptions: { ...inputs.launchOptions,
        ...(request.debugPort !== undefined ? { debug: { runtime: "jvm" as const, port: request.debugPort } } : {}) } });
    const cancel = () => { workspace.domain.cancel(operation.operationID); };
    controller.signal.addEventListener("abort", cancel, { once: true });
    if (controller.signal.aborted) cancel();
    let offset = 0;
    const drain = () => {
      if (controller.signal.aborted || !request.isCurrent()) return;
      const value = workspace.domain.operationOutput(operation.operationID);
      if (!value || value.offset <= offset) return;
      request.onOutput(value.output.slice(Math.max(0, offset - (value.offset - value.output.length)))); offset = value.offset;
    };
    const unsubscribe = workspace.domain.subscribe(drain);
    try {
      const prepared = await wait(operation.completion); drain(); catalogCurrent();
      const executable = prepared.launch.executable.kind === "toolchain"
        ? { toolchain: prepared.launch.executable.value } : { command: prepared.launch.executable.value };
      const imported = prepared.languageImport?.kind === "maven" ? prepared.languageImport.mavenContext : undefined;
      const resolved = await wait(ports.resolve({ root: request.root, executable, workingDirectory: prepared.launch.workingDirectory,
        runtimeExecutablePaths: request.runtimeExecutablePaths,
        ...(imported ? { mavenExecutablePath: imported.mavenExecutablePath ?? undefined, mavenJavaHomePath: prepared.tool.environment.JAVA_HOME } : {}),
        environment: { ...prepared.tool.environment, ...prepared.launch.environment },
      }));
      const latest = await wait(ports.inputs(request.root, request.configurationId, entry.root));
      // Core returns a deterministic projection. Recheck launch fields too:
      // changing argv/cwd/environment need not change the saved target identity.
      if (!latest.reference || !sameReference(reference, latest.reference) || JSON.stringify(latest) !== JSON.stringify(inputs)) throw ports.unavailable();
      catalogCurrent(); await wait(prepared.validate()); catalogCurrent(); prepared.assertCurrent();
      const launch = { ...resolved, arguments: prepared.launch.arguments };
      request.onReady(launch); catalogCurrent();
      // The owner is already registered. A stop during native spawn waits for
      // its acknowledgement and then stops that exact execution, even if late.
      await track(ports.start({ sessionId: request.sessionId, executionId: request.executionId, title: request.name, ...launch }));
      try { catalogCurrent(); prepared.assertCurrent(); }
      catch (error) { await stopNative(); throw error; }
    } finally { unsubscribe(); controller.signal.removeEventListener("abort", cancel); }
  }, async () => {
    while (pending.size) await Promise.allSettled([...pending]);
    await stopNative();
  }, { cancel: revoke, stopOnFailedStart: true }).catch(async error => {
    // A failed IPC spawn may still have created a native session. Release its
    // owner only after exact-execution cleanup succeeds; failures remain retryable.
    if (stopFailure !== undefined) throw stopFailure;
    await stopNative(); ports.processes.finished(request.executionId); throw error;
  });
  return { completion, stop: () => ports.processes.stopExecution(request.executionId), finished: () => ports.processes.finished(request.executionId) };
}
