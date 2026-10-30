import type { pluginPlanGuard } from "@/features/plugins/declarative-plugin-lifecycle";
import type { buildCore } from "@/platform/build-core-api";
import type { windowsBuildProviders } from "@/platform/build-provider-sessions";
import { awaitBuildPreparation } from "@/platform/build-provider-operation";
import type { CoreBuildProviderTarget } from "@/platform/lsp-core-adapter";

export interface BuildProject {
  id: string; name: string; path: string; parentID?: string;
  displayName?: string; properties: Record<string, string>;
}

export interface BuildModel {
  projects: BuildProject[];
  targets: Array<{ id: string; projectID: string; name: string; path: string; tags: string[]; properties: Record<string, string> }>;
  tasks: Array<{ id: string; projectID: string; name: string; path: string; template: string;
    execution: "task" | "service"; properties: Record<string, string> }>;
  contentRoots: Array<{ projectID: string; path: string; kind: string }>;
  optionValues: Record<string, string[]>;
  truncated?: boolean;
}

export interface BuildToolContext {
  manifest: Record<string, unknown>;
  identity?: unknown;
  pluginDirectory: string;
  workspaceStateDirectory: string;
  tool: { executable: string };
  environment: Record<string, string>;
  executesProjectCode: boolean;
}

export interface BuildInstance {
  pluginID: string; buildSystemID: string; root: string;
  options: Record<string, unknown>;
}

export interface BuildOperation {
  id: string;
  instance: BuildInstance;
  phase: "preparing" | "running" | "succeeded" | "failed" | "cancelled";
  output: string;
  exitCode?: number;
  error?: string;
}

export interface BuildTestSelection {
  projectID?: string; suite?: string; case?: string;
  selectorKind?: string; selectors?: string[]; userArguments?: string[];
}

export interface BuildNativeConfiguration {
  format: "litheBuildConfiguration";
  version: 1;
  sources: Array<{
    id: string; scope: "installation" | "user" | "workspace"; uri: string; revision: string; writable: boolean;
    rootElement: { name: string; namespace: string };
    fields: Array<{ id: string; kind: "text" | "file" | "directory" | "boolean" | "stringList";
      value: unknown; effectiveValue: unknown; effectiveSource: string; path: string[]; itemElement?: string }>;
  }>;
}

interface BuildWork {
  record: BuildOperation;
  current: () => void;
  context: string;
  tool: BuildToolContext;
  signal: AbortSignal;
  native: <T>(task: Promise<T>) => Promise<T>;
  retainCleanup: (release: () => Promise<unknown>) => Promise<unknown>;
  perform: (command: string, request: Record<string, unknown>) => Promise<unknown>;
  decode: <R extends Record<string, unknown>>(command: string, request: Record<string, unknown>, includeContext?: boolean) => Promise<R>;
}

export interface WorkspacePorts {
  core: typeof buildCore;
  providers: Pick<typeof windowsBuildProviders, "send" | "stop">;
  tools: (target: CoreBuildProviderTarget, root: string, checkVersions: boolean) => Promise<BuildToolContext>;
  guard: typeof pluginPlanGuard;
  translate: (key: string) => string;
  configurationFiles?: {
    prepare: (target: CoreBuildProviderTarget, root: string, operationID: string, snapshot: BuildNativeConfiguration, edits: BuildNativeConfigurationEdits) => Promise<boolean>;
    commit: (operationID: string) => Promise<void>;
    cancel: (operationID: string) => Promise<void>;
  };
}

export interface BuildNativeConfigurationEdits { sourceID: string; revision: string; values: Record<string, unknown> }

const MAX_OUTPUT_CHARACTERS = 500_000;
const MAX_COMPLETED_OPERATIONS = 50;

function owner(instance: BuildInstance): string {
  return JSON.stringify([instance.pluginID, instance.buildSystemID, instance.root]);
}
function revoked(message: string): Error & { code: string } {
  return Object.assign(new Error(message), { code: "cancelled" });
}

function fingerprint(value: unknown): string {
  const ordered = (value: unknown): unknown => Array.isArray(value) ? value.map(ordered)
    : value && typeof value === "object" ? Object.fromEntries(Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([key, value]) => [key, ordered(value)])) : value;
  return JSON.stringify(ordered(value));
}

/** Workspace state for Provider-backed domain operations. Core and the backend
 * own every project/goal/report fact. Product admission remains closed until
 * the remaining model sources and UI consumers have migrated. */
export class WindowsBuildProviderWorkspace {
  private readonly listeners = new Set<() => void>();
  private publicationRevision = 0;
  private publicationQueued = false;
  private disposed = false;
  private readonly revisions = new Map<string, number>();
  private readonly models = new Map<string, BuildModel>();
  private readonly modelInputs = new Map<string, { options: string; context: string; current: () => void }>();
  private readonly configurations = new Map<string, { snapshot: string; context: string; options: string; current: () => void }>();
  private readonly cleanupFailures = new Map<() => Promise<unknown>, unknown>();
  private readonly pendingTasks = new Set<Promise<unknown>>();
  private readonly controllers = new Map<string, { controller: AbortController; instance: string }>();
  private readonly records = new Map<string, BuildOperation>();
  private readonly targets = new Map<string, CoreBuildProviderTarget>();

  constructor(readonly workspacePath: string, private readonly ports: WorkspacePorts) {}

  private message(key: string): string { return this.ports.translate(`build.errors.${key}`); }
  private revoked(): Error & { code: string } { return revoked(this.message("inputsChanged")); }

  subscribe = (listener: () => void): (() => void) => { this.listeners.add(listener); return () => { this.listeners.delete(listener); }; };
  snapshotRevision = (): number => this.publicationRevision;
  operation(id: string): BuildOperation | undefined {
    const record = this.records.get(id); return record && structuredClone(record);
  }
  operationSummary(id: string): Omit<BuildOperation, "output"> | undefined {
    const record = this.records.get(id);
    if (!record) return undefined;
    const { output: _, ...summary } = record;
    return structuredClone(summary);
  }
  operationSummaries(): Array<Omit<BuildOperation, "output">> {
    return [...this.records.values()].map(({ output: _, ...record }) => structuredClone(record));
  }
  private changed(): void {
    if (this.publicationQueued) return;
    this.publicationQueued = true;
    // One Core event drain can deliver many progress chunks. Notify the
    // product once after the drain; its view selects only one output record.
    queueMicrotask(() => {
      this.publicationQueued = false; this.publicationRevision++;
      for (const listener of this.listeners) listener();
    });
  }

  operations(): BuildOperation[] { return [...this.records.values()].map(record => structuredClone(record)); }
  model(instance: BuildInstance): BuildModel | undefined {
    const inputs = this.modelInputs.get(owner(instance));
    if (!inputs || inputs.options !== fingerprint(instance.options)) return undefined;
    try { inputs.current(); } catch { return undefined; }
    const model = this.models.get(owner(instance)); return model && structuredClone(model);
  }
  invalidate(instance: BuildInstance): void {
    const key = owner(instance);
    this.revisions.set(key, (this.revisions.get(key) ?? 0) + 1);
    this.models.delete(key);
    this.modelInputs.delete(key);
    this.configurations.delete(key);
    for (const pending of this.controllers.values()) if (pending.instance === key) pending.controller.abort(this.revoked());
    this.changed();
  }
  cancel(id: string): boolean {
    const pending = this.controllers.get(id);
    if (!pending) return false;
    pending.controller.abort(this.revoked()); return true;
  }

  loadModel(instance: BuildInstance) {
    this.invalidate(instance);
    return this.begin<BuildModel>(instance, false, async operation => {
      const result = await operation.perform("build.modelPlan", { refresh: true });
      const decoded = await operation.decode<{ model: BuildModel }>("build.decodeModel", { result });
      operation.current();
      const selected = operation.record.instance;
      this.models.set(owner(selected), structuredClone(decoded.model));
      this.modelInputs.set(owner(selected), { options: fingerprint(selected.options), context: operation.context, current: operation.current });
      return decoded.model;
    }, false);
  }

  dependencies(instance: BuildInstance, projectID?: string) {
    return this.begin<{ dependencies: { project: string; dependencies: unknown[]; truncated: boolean } }>(instance, false, async operation => {
      const project = this.project(operation.record.instance, projectID);
      const result = await operation.perform("build.dependencyPlan", { project });
      return await operation.decode("build.decodeDependencies", { result, project: project?.path });
    });
  }

  readConfiguration(instance: BuildInstance, allowProjectTool = false) {
    return this.begin<BuildNativeConfiguration>(instance, false, async operation => {
      if (operation.tool.executesProjectCode && !allowProjectTool) {
        throw Object.assign(new Error(this.message("projectToolRequiresAction")), { code: "build.configuration.projectToolRequiresAction" });
      }
      const result = await operation.perform("build.configurationPlan", { refresh: true });
      const decoded = await operation.decode<{ configuration: BuildNativeConfiguration }>("build.decodeConfiguration", { result }, false);
      this.rememberConfiguration(operation, decoded.configuration);
      return decoded.configuration;
    }, false);
  }

  saveConfiguration(instance: BuildInstance, snapshot: BuildNativeConfiguration, edits: BuildNativeConfigurationEdits) {
    const savedSnapshot = structuredClone(snapshot), savedEdits = structuredClone(edits);
    return this.begin<BuildNativeConfiguration>(instance, false, async operation => {
      const selected = operation.record.instance, key = owner(selected), previous = this.configurations.get(key);
      if (!previous || previous.snapshot !== fingerprint(savedSnapshot) || previous.context !== operation.context
        || previous.options !== fingerprint(selected.options)) throw this.revoked();
      previous.current();
      const files = this.ports.configurationFiles;
      if (!files) throw new Error(this.message("unsupportedSource"));
      const target = { workspacePath: this.workspacePath, pluginId: selected.pluginID, buildSystemId: selected.buildSystemID };
      const preparing = files.prepare(target, selected.root, operation.record.id, savedSnapshot, savedEdits);
      try {
        const changed = await operation.native(preparing);
        operation.current();
        if (!changed) return savedSnapshot;
        const committing = files.commit(operation.record.id).then(() => this.nativeConfigurationChanged(selected, operation.record.id));
        await operation.native(committing);
        operation.current();
        const result = await operation.perform("build.configurationPlan", { refresh: true });
        const decoded = await operation.decode<{ configuration: BuildNativeConfiguration }>("build.decodeConfiguration", { result }, false);
        this.rememberConfiguration(operation, decoded.configuration);
        return decoded.configuration;
      } finally {
        // Cancellation can precede a native prepare reply. Retain that reply
        // and cancel only after it finishes, so a late token cannot leak XML.
        const cleanup = operation.retainCleanup(() => preparing.then(() => files.cancel(operation.record.id), () => files.cancel(operation.record.id)));
        if (!operation.signal.aborted) await cleanup;
      }
    }, false);
  }

  private nativeConfigurationChanged(selected: BuildInstance, savingOperationID: string): void {
    // User/installation settings may be inherited by sibling roots. Even if
    // the caller cancelled while atomic publication was already in progress,
    // its completed write must invalidate facts read before publication.
    const keys = new Set([...this.models.keys(), ...this.configurations.keys(), ...[...this.controllers.values()].map(pending => pending.instance)]
      .filter(key => { const [plugin, system] = JSON.parse(key); return plugin === selected.pluginID && system === selected.buildSystemID; }));
    for (const key of keys) { this.models.delete(key); this.modelInputs.delete(key); this.configurations.delete(key); }
    for (const [id, pending] of this.controllers) {
      if (id !== savingOperationID && keys.has(pending.instance)) pending.controller.abort(this.revoked());
    }
    this.changed();
  }

  private rememberConfiguration(operation: BuildWork, snapshot: BuildNativeConfiguration): void {
    operation.current();
    const selected = operation.record.instance;
    this.configurations.set(owner(selected), { snapshot: fingerprint(snapshot), context: operation.context,
      options: fingerprint(selected.options), current: operation.current });
  }

  executeTask(instance: BuildInstance, task: string, projectID?: string, userArguments: string[] = []) {
    const argumentsSnapshot = [...userArguments];
    return this.begin<Record<string, unknown>>(instance, true, async operation => {
      const project = this.project(operation.record.instance, projectID);
      return await this.execution(operation, await operation.perform("build.taskPlan", { task, project, userArguments: argumentsSnapshot }), project);
    });
  }

  executeModelTask(instance: BuildInstance, taskID: string, userArguments: string[] = []) {
    const argumentsSnapshot = [...userArguments];
    return this.begin(instance, true, async operation => {
      const task = this.models.get(owner(operation.record.instance))?.tasks.find(task => task.id === taskID);
      if (!task) throw new Error(this.message("missingProject"));
      const project = this.project(operation.record.instance, task.projectID);
      const result = await operation.perform("build.taskPlan", { task: task.template, modelTask: task, project, userArguments: argumentsSnapshot });
      return await this.execution(operation, result, project);
    });
  }

  discoverTests(instance: BuildInstance) {
    return this.begin(instance, false, async operation => {
      const result = await operation.perform("build.testDiscoveryPlan", { refresh: true });
      return await operation.decode("build.decodeTestDiscovery", { result });
    });
  }

  executeTests(instance: BuildInstance, selection: BuildTestSelection = {}) {
    const snapshot = structuredClone(selection);
    return this.begin(instance, true, async operation => {
      const project = this.project(operation.record.instance, snapshot.projectID);
      const { projectID: _, ...filters } = snapshot;
      const result = await operation.perform("build.testPlan", { ...filters, project,
        projects: this.models.get(owner(operation.record.instance))!.projects.map(project => project.path) });
      return await this.execution(operation, result, project, snapshot.suite, true);
    });
  }

  private async execution(operation: BuildWork, value: unknown, project?: BuildProject, suite?: string, requiresTests = false) {
    const result = value as { exitCode?: unknown; output?: unknown; testResults?: unknown };
    if (!Number.isSafeInteger(result?.exitCode) || (result.exitCode as number) < -2147483648
      || (result.exitCode as number) > 2147483647 || typeof result.output !== "string") throw new Error(this.message("invalidExecutionResult"));
    operation.record.exitCode = result.exitCode as number;
    operation.record.output = result.output.slice(-MAX_OUTPUT_CHARACTERS);
    if (requiresTests && result.testResults === undefined) throw new Error(this.message("invalidExecutionResult"));
    const diagnostics = await operation.decode("build.decodeDiagnostics", { output: result.output });
    let tests;
    if (result.testResults !== undefined) tests = await operation.decode("build.decodeTestResults", {
      project: project?.path, projects: this.models.get(owner(operation.record.instance))?.projects.map(project => project.path) ?? [],
      output: result.output, result: result.testResults, suite,
    });
    return { ...result, ...diagnostics, ...(tests ?? {}) };
  }

  private project(instance: BuildInstance, id?: string): BuildProject | undefined {
    if (!id) return undefined;
    const model = this.models.get(owner(instance));
    const project = model?.projects.find(project => project.id === id);
    if (!project || model?.truncated) throw new Error(this.message("missingProject"));
    return project;
  }

  private begin<T>(instance: BuildInstance, checkVersions: boolean, body: (operation: BuildWork) => Promise<T>, needsModel = true) {
    if (this.disposed) throw this.revoked();
    const snapshot = structuredClone(instance), key = owner(snapshot), revision = this.revisions.get(key) ?? 0;
    const guard = this.ports.guard(), controller = new AbortController(), id = crypto.randomUUID();
    const record: BuildOperation = { id, instance: snapshot, phase: "preparing", output: "" };
    this.controllers.set(id, { controller, instance: key }); this.records.set(id, record);
    const target = { workspacePath: this.workspacePath, pluginId: snapshot.pluginID, buildSystemId: snapshot.buildSystemID };
    this.targets.set(JSON.stringify(target), target);
    this.changed();
    const current = () => {
      controller.signal.throwIfAborted();
      try { guard(snapshot.pluginID); } catch { throw this.revoked(); }
      if (this.disposed || (this.revisions.get(key) ?? 0) !== revision) throw this.revoked();
    };
    const completion = (async () => {
      try {
        current();
        const model = this.model(snapshot);
        if (needsModel && (!model || model.truncated)) throw new Error(this.message("incompleteModel"));
        const context = await this.owned(this.ports.tools(target, snapshot.root, checkVersions), controller.signal);
        current();
        if (context.manifest.id !== snapshot.pluginID) throw new Error(this.message("wrongPlugin"));
        const contextIdentity = fingerprint(context);
        if (needsModel && this.modelInputs.get(key)?.context !== contextIdentity) {
          this.invalidate(snapshot); throw this.revoked();
        }
        const base = { root: snapshot.root, options: snapshot.options, pluginDirectory: context.pluginDirectory,
          workspaceStateDirectory: context.workspaceStateDirectory, tool: { ...context.tool, environment: context.environment } };
        const decode = async <R extends Record<string, unknown>>(command: string, request: Record<string, unknown>, includeContext = true) => {
          current();
          const result = await this.owned(this.ports.core<R>(command, context.manifest, snapshot.buildSystemID, {
            ...(includeContext ? { workspaceRoot: this.workspacePath, root: snapshot.root, options: snapshot.options } : {}), ...request,
          }, this.workspacePath), controller.signal);
          current(); return result;
        };
        const perform = async (command: string, request: Record<string, unknown>) => {
          current();
          const result = await this.owned(this.ports.core<{ plan: { provider?: { method: string; params: Record<string, unknown> } } }>(command,
            context.manifest, snapshot.buildSystemID, { ...base, ...request }, this.workspacePath), controller.signal);
          current();
          const provider = result.plan.provider;
          if (!provider) throw new Error(this.message("unsupportedSource"));
          record.phase = "running";
          this.changed();
          // Task plans have no tool hints. Apply the same native selection as
          // model queries, preserving Core's option environment precedence.
          const params = { ...provider.params, tool: context.tool,
            environment: { ...context.environment, ...(provider.params.environment as Record<string, string> ?? {}) } };
          const value = await this.owned(this.ports.providers.send(target, { ...provider, params, timeoutMilliseconds: checkVersions ? 600_000 : 120_000,
            signal: controller.signal, onProgress: value => {
              try { current(); } catch { return; }
              if (!value || typeof value !== "object") return;
              const progress = value as { output?: unknown; message?: unknown };
              const text = typeof progress.output === "string" ? progress.output : typeof progress.message === "string" ? progress.message + "\n" : "";
              record.output = (record.output + text).slice(-MAX_OUTPUT_CHARACTERS);
              this.changed();
            } }), controller.signal);
          current(); return value;
        };
        const value = await body({ record, current, perform, decode, context: contextIdentity, tool: context,
          signal: controller.signal, native: task => this.owned(task, controller.signal), retainCleanup: release => this.retainCleanup(release) });
        current(); record.phase = record.exitCode !== undefined && record.exitCode !== 0 ? "failed" : "succeeded";
        return value;
      } catch (error) {
        const configurationError = {
          "build.configuration.conflict": "native.nativeConfigurationDiskConflict",
          "build.configuration.readOnly": "native.nativeConfigurationSourceReadOnly",
          "build.configuration.unreadable": "native.nativeConfigurationFileRequired",
          "build.configuration.invalid": "build.errors.invalidConfiguration",
        }[(error as { code?: string })?.code ?? ""];
        if (configurationError && error instanceof Error) error.message = this.ports.translate(configurationError);
        record.phase = controller.signal.aborted || this.disposed || (this.revisions.get(key) ?? 0) !== revision
          || (error as { code?: string })?.code === "cancelled" ? "cancelled" : "failed";
        if (record.phase === "failed") record.error = error instanceof Error ? error.message : String(error);
        throw error;
      } finally {
        this.controllers.delete(id);
        const completed = [...this.records.values()].filter(record => !this.controllers.has(record.id));
        for (const old of completed.slice(0, Math.max(0, completed.length - MAX_COMPLETED_OPERATIONS))) this.records.delete(old.id);
        this.changed();
      }
    })();
    this.pendingTasks.add(completion);
    const released = () => { this.pendingTasks.delete(completion); };
    void completion.then(released, released);
    return { operationID: id, completion };
  }

  private owned<T>(task: Promise<T>, signal: AbortSignal): Promise<T> {
    this.pendingTasks.add(task);
    const release = () => { this.pendingTasks.delete(task); };
    void task.then(release, release);
    return awaitBuildPreparation(task, signal);
  }

  private retainCleanup(release: () => Promise<unknown>): Promise<unknown> {
    const task = Promise.resolve().then(release);
    this.pendingTasks.add(task);
    void task.then(() => { this.cleanupFailures.delete(release); this.pendingTasks.delete(task); },
      error => { this.cleanupFailures.set(release, error); this.pendingTasks.delete(task); });
    return task;
  }

  async stopPlugin(pluginID: string): Promise<void> {
    const keys = new Set([...this.models.keys(), ...this.configurations.keys(), ...[...this.controllers.values()].map(pending => pending.instance)]);
    for (const key of keys) {
      const [plugin, system, root] = JSON.parse(key);
      if (plugin === pluginID) this.invalidate({ pluginID: plugin, buildSystemID: system, root, options: {} });
    }
    const targets = [...this.targets.values()].filter(target => target.pluginId === pluginID);
    const outcomes = await Promise.allSettled(targets.map(target => this.ports.providers.stop(target)));
    const failure = outcomes.find(result => result.status === "rejected");
    if (failure?.status === "rejected") throw failure.reason;
  }

  async dispose(): Promise<void> {
    // Retry only failures retained before this close. A newly failed release
    // remains visible to the caller and requires another explicit cleanup.
    const retries = [...this.cleanupFailures.keys()];
    this.disposed = true;
    for (const pending of this.controllers.values()) pending.controller.abort(this.revoked());
    this.models.clear();
    this.modelInputs.clear();
    this.configurations.clear();
    this.changed();
    const stops = await Promise.allSettled([...this.targets.values()].map(target => this.ports.providers.stop(target)));
    // Cancelling a completion may register cleanup for its late native reply.
    // Drain newly registered work as well as the first captured batch.
    while (this.pendingTasks.size) await Promise.allSettled([...this.pendingTasks]);
    await Promise.allSettled(retries.map(release => this.retainCleanup(release)));
    const failures = stops.filter((result): result is PromiseRejectedResult => result.status === "rejected");
    if (failures.length || this.cleanupFailures.size) throw Object.assign(new Error(this.message("cleanupFailed")),
      { causes: [...failures.map(result => result.reason), ...this.cleanupFailures.values()] });
  }
}
