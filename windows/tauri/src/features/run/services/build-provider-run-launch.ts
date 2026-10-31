import { awaitBuildPreparation } from "@/platform/build-provider-operation";
import type { ExtensionProcessOwner } from "@/extensions/run/extension-process-owner";
import type { BuildWorkspaceController } from "@/features/build/services/build-workspace-controller";
import { BuildModelPreparationOwner } from "@/features/build/services/build-model-preparation-owner";
import type { BuildProviderLaunchInputs, BuildProviderRunReference } from "../types/run.types";
import type { resolveRunLaunch, startRunProcess, stopRunProcess } from "../api/run-host-api";

export interface PreparedNativeBuildRun {
  executable: string; arguments: string[]; workingDirectory: string; environment: Record<string, string>;
}
export interface BuildProviderRunRequest {
  workspaceId: string; root: string; configurationId: string; name: string;
  reference?: BuildProviderRunReference;
  source?: { buildSystemID: string; root: string; provider: string; execution: "application" | "service" | "task" };
  sessionId: string; executionId: string;
  debugPort?: number;
  runtimeExecutablePaths: Record<string, string>;
  isCurrent: () => boolean; onRevoked: () => void; onOutput: (text: string) => void; onReady: (launch: PreparedNativeBuildRun) => void;
}
export interface BuildProviderRunHandle { completion: Promise<void>; stop: () => Promise<void>; finished: () => void | Promise<void> }
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
  const reference = request.reference && structuredClone(request.reference), source = request.source && structuredClone(request.source);
  const identity = reference ?? source, controller = new AbortController(), pending = new Set<Promise<unknown>>();
  let cleanupGeneration = 0;
  const cleanups: Array<() => Promise<void>> = [];
  const ownCleanup = (release: () => Promise<void>) => {
    let action: (() => Promise<void>) | undefined = release;
    let task: Promise<void> | undefined, failedAt: number | undefined, failure: unknown;
    const run = () => {
      if (task) return task;
      if (failedAt === cleanupGeneration) return Promise.reject(failure);
      const generation = cleanupGeneration;
      const started = Promise.resolve().then(action); task = started;
      void started.then(() => { action = undefined; failedAt = undefined; failure = undefined; },
        error => { if (task === started) { task = undefined; failedAt = generation; failure = error; } });
      return started;
    };
    cleanups.push(run); return run;
  };
  const cleanup = async () => {
    const outcomes = await Promise.allSettled(cleanups.map(run => run()));
    const failed = outcomes.find((outcome): outcome is PromiseRejectedResult => outcome.status === "rejected");
    if (failed) throw failed.reason;
  };
  const track = <T,>(task: Promise<T>): Promise<T> => {
    pending.add(task); const done = () => { pending.delete(task); }; void task.then(done, done); return task;
  };
  const wait = <T,>(task: Promise<T>) => awaitBuildPreparation(track(task), controller.signal);
  const assertCurrent = () => { controller.signal.throwIfAborted(); if (!request.isCurrent()) throw new DOMException("Aborted", "AbortError"); };
  const revoke = () => { cleanupGeneration++; controller.abort(); if (request.isCurrent()) request.onRevoked(); };
  const stopNative = ownCleanup(() => ports.stop(request.sessionId, request.executionId));
  const completion = ports.processes.start(request.executionId, request.workspaceId, reference?.pluginID ?? "", async bindExtension => {
    assertCurrent();
    if (!identity || Boolean(reference) === Boolean(source)) throw ports.unavailable();
    const workspace = ports.workspace(request.workspaceId, request.root);
    if (!workspace) throw ports.unavailable();
    await wait(workspace.ensureDetected(true)); assertCurrent();
    if (workspace.snapshot().status === "failed") throw new Error(workspace.snapshot().error ?? ports.unavailable().message);
    const entries = workspace.snapshot().entries.filter(entry => (!reference || entry.pluginID === reference.pluginID)
      && entry.buildSystemID === identity.buildSystemID && entry.root === identity.root);
    if (entries.length !== 1) throw ports.unavailable();
    const entry = entries[0]!;
    bindExtension(entry.pluginID);
    const catalogCurrent = () => { assertCurrent(); if (!workspace.snapshot().entries.includes(entry)) throw ports.unavailable(); };
    const inputs = await wait(ports.inputs(request.root, request.configurationId, entry.root)); catalogCurrent();
    if (inputs.buildSystemID !== identity.buildSystemID || Boolean(reference) !== Boolean(inputs.reference)
      || (reference && (!inputs.reference || !sameReference(reference, inputs.reference) || inputs.provider !== reference.run
        || inputs.launchOptions.execution !== (reference.execution ?? "application")))
      || (source && (inputs.provider !== source.provider || inputs.launchOptions.execution !== source.execution))) throw ports.unavailable();
    const scope = workspace.domain.createRunScope(entry, inputs, request.configurationId), models = new BuildModelPreparationOwner(scope.domain, scope.requiredOptions);
    const release = ownCleanup(async () => { models.dispose(); await scope.dispose(); });
    try {
      await models.ensure(scope.instance, controller.signal, text => { if (request.isCurrent()) request.onOutput(text); }); catalogCurrent();
      const operation = scope.domain.prepareConfigurationRun(scope.instance, { ...inputs, launchOptions: { ...inputs.launchOptions,
        ...(request.debugPort !== undefined ? { debug: { runtime: "jvm" as const, port: request.debugPort } } : {}) } });
      const cancel = () => { scope.domain.cancel(operation.operationID); };
      controller.signal.addEventListener("abort", cancel, { once: true });
      if (controller.signal.aborted) cancel();
      let offset = 0;
      const drain = () => {
        if (controller.signal.aborted || !request.isCurrent()) return;
        const value = scope.domain.operationOutput(operation.operationID);
        if (!value || value.offset <= offset) return;
        request.onOutput(value.output.slice(Math.max(0, offset - (value.offset - value.output.length)))); offset = value.offset;
      };
      const unsubscribe = scope.domain.subscribe(drain);
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
        if (JSON.stringify(latest) !== JSON.stringify(inputs)) throw ports.unavailable();
        catalogCurrent(); await wait(prepared.validate()); catalogCurrent(); prepared.assertCurrent();
        const launch = { ...resolved, arguments: prepared.launch.arguments };
        request.onReady(launch); catalogCurrent();
        // The owner is already registered. A stop during native spawn waits for
        // its acknowledgement and then stops that exact execution, even if late.
        await track(ports.start({ sessionId: request.sessionId, executionId: request.executionId, title: request.name, ...launch }));
        try { catalogCurrent(); prepared.assertCurrent(); }
        catch (error) { await stopNative(); throw error; }
      } finally { unsubscribe(); controller.signal.removeEventListener("abort", cancel); }
    } finally { await release(); }
  }, async () => {
    while (pending.size) await Promise.allSettled([...pending]);
    await cleanup();
  }, { cancel: revoke, stopOnFailedStart: true }).catch(async error => {
    // A failed IPC spawn may still have created a native session. Release its
    // owner only after exact-execution cleanup succeeds; failures remain retryable.
    await cleanup(); ports.processes.finished(request.executionId); throw error;
  });
  return { completion, stop: () => ports.processes.stopExecution(request.executionId), finished: async () => {
    // Native exit can precede the spawn acknowledgement. The Run owner keeps
    // private source leases until preparation and all cleanup have settled.
    await completion.then(() => {}, () => {}); await cleanup(); ports.processes.finished(request.executionId);
  } };
}
