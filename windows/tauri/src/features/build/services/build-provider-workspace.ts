import { awaitBuildPreparation } from "@/platform/build-provider-operation";
import type { CoreBuildProviderTarget } from "@/platform/lsp-core-adapter";
import { BuildResultStore, type BuildDiagnostic, type BuildTestResults, type BuildTestSelector } from "./build-results";
import { BuildFileInputs } from "./build-file-inputs";
import type { BuildConfigurationWatch, BuildConfigurationSourceVersion } from "./build-configuration-watch";
import { configurationRunSelection, prepareBuildRun } from "./build-run-preparation";

import type { BuildProject, BuildDependencies, BuildDependencySnapshot, BuildModel, BuildInstance, BuildOperation,
  BuildTestSelection, BuildNativeConfiguration, BuildNativeConfigurationEdits, BuildRunSelection, BuildConfigurationRunSelection, BuildRequiredOptions, BuildPreparedRun, BuildWork, WorkspacePorts } from "./build-provider-types";
export type * from "./build-provider-types";

const MAX_OUTPUT_CHARACTERS = 500_000;
const MAX_COMPLETED_OPERATIONS = 50;
const MAX_DEPENDENCY_SNAPSHOTS = 4;

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
  private readonly factListeners = new Set<() => void>();
  private factsQueued = false;
  private publicationRevision = 0;
  private publicationQueued = false;
  private disposed = false;
  private readonly revisions = new Map<string, number>();
  private readonly models = new Map<string, BuildModel>();
  private readonly modelInputs = new Map<string, { options: string; context: string; sync: string; nativeSources?: BuildConfigurationSourceVersion[]; current: () => void }>();
  private readonly nativeWatches = new Map<string, BuildConfigurationWatch>();
  private readonly nativeRetirements = new Map<Promise<unknown>, string>();
  private readonly configurationSaves = new Map<string, number>();
  private readonly dependencyResults = new Map<string, { instance: string; snapshot: BuildDependencySnapshot }>();
  private readonly configurations = new Map<string, { snapshot: string; context: string; options: string; current: () => void }>();
  private readonly cleanupFailures = new Map<() => Promise<unknown>, unknown>();
  private readonly pendingTasks = new Set<Promise<unknown>>();
  private readonly controllers = new Map<string, { controller: AbortController; instance: string }>();
  private readonly records = new Map<string, BuildOperation>();
  private readonly outputOffsets = new Map<string, number>();
  private readonly targets = new Map<string, CoreBuildProviderTarget>();
  private readonly results = new BuildResultStore();
  private readonly fileInputs: BuildFileInputs;
  private readonly runScopes = new Map<WindowsBuildProviderWorkspace, string>();
  private factRevision = 0;

  constructor(readonly workspacePath: string, private readonly ports: WorkspacePorts) { this.fileInputs = new BuildFileInputs(workspacePath); }

  private message(key: string): string { return this.ports.translate(`build.errors.${key}`); }
  private revoked(): Error & { code: string } { return revoked(this.message("inputsChanged")); }

  subscribe = (listener: () => void): (() => void) => { this.listeners.add(listener); return () => { this.listeners.delete(listener); }; };
  subscribeFacts = (listener: () => void): (() => void) => { this.factListeners.add(listener); return () => { this.factListeners.delete(listener); }; };
  private factsChanged(): void {
    if (this.factsQueued) return;
    this.factsQueued = true;
    queueMicrotask(() => {
      this.factsQueued = false; this.factRevision++;
      for (const listener of this.factListeners) listener();
    });
  }
  snapshotRevision = (): number => this.publicationRevision;
  snapshotFactRevision = (): number => this.factRevision;
  result(id: string) { return this.results.result(id); }
  testDiscovery(instance: BuildInstance) {
    return this.modelIsCurrent(instance) ? this.results.discovery(owner(instance)) : undefined;
  }
  operation(id: string): BuildOperation | undefined {
    const record = this.records.get(id); return record && structuredClone(record);
  }
  operationOutput(id: string): { output: string; offset: number } | undefined {
    const record = this.records.get(id);
    return record && { output: record.output, offset: this.outputOffsets.get(id) ?? record.output.length };
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
  private modelIsCurrent(instance: BuildInstance): boolean {
    const inputs = this.modelInputs.get(owner(instance));
    if (!inputs || inputs.options !== fingerprint(instance.options)) return false;
    try { inputs.current(); return true; } catch { return false; }
  }
  model(instance: BuildInstance): BuildModel | undefined {
    if (!this.modelIsCurrent(instance)) return undefined;
    const model = this.models.get(owner(instance)); return model && structuredClone(model);
  }
  hasCurrentModel(instance: BuildInstance): boolean { return this.modelIsCurrent(instance) && this.models.has(owner(instance)); }
  /** A cheap opaque lease for UI actions crossing asynchronous persistence. */
  modelGuard(instance: BuildInstance): () => void {
    const model = this.models.get(owner(instance));
    return () => { if (!model || !this.modelIsCurrent(instance) || this.models.get(owner(instance)) !== model) throw this.revoked(); };
  }
  dependencyResult(instance: BuildInstance, projectID?: string): BuildDependencySnapshot | undefined {
    if (!this.modelIsCurrent(instance)) return undefined;
    const result = this.dependencyResults.get(JSON.stringify([owner(instance), projectID ?? ""]))?.snapshot;
    return result && structuredClone(result);
  }
  configurationIsCurrent(instance: BuildInstance, snapshot: BuildNativeConfiguration): boolean {
    const receipt = this.configurations.get(owner(instance));
    if (!receipt || receipt.snapshot !== fingerprint(snapshot) || receipt.options !== fingerprint(instance.options)) return false;
    try { receipt.current(); return true; } catch { return false; }
  }
  invalidate(instance: BuildInstance): void {
    this.invalidateKey(owner(instance));
  }
  private invalidateKey(key: string): void {
    for (const [scope, instance] of this.runScopes) if (instance === key) scope.invalidateKey(key);
    this.revisions.set(key, (this.revisions.get(key) ?? 0) + 1);
    this.models.delete(key);
    this.modelInputs.delete(key);
    this.results.forget(key);
    this.fileInputs.forget(key);
    for (const [id, cached] of this.dependencyResults) if (cached.instance === key) this.dependencyResults.delete(id);
    this.configurations.delete(key);
    this.retireNativeWatch(key);
    for (const pending of this.controllers.values()) if (pending.instance === key) pending.controller.abort(this.revoked());
    this.factsChanged();
    this.changed();
  }
  filesChanged(path: string, rescan = false): boolean {
    if (this.disposed) return false;
    let scoped = false;
    for (const scope of this.runScopes.keys()) scoped = scope.filesChanged(path, rescan) || scoped;
    const change = this.fileInputs.changed(path, rescan);
    if (change.workspace) { this.results.forgetDiscoveries(); this.factsChanged(); }
    for (const id of change.cancelled) this.cancel(id);
    for (const key of change.owners) this.invalidateKey(key);
    return change.owners.size > 0 || scoped;
  }
  cancel(id: string): boolean {
    const pending = this.controllers.get(id);
    if (!pending) return false;
    pending.controller.abort(this.revoked()); return true;
  }

  loadModel(instance: BuildInstance, requiredOptions?: BuildRequiredOptions) {
    const required = requiredOptions && structuredClone(requiredOptions);
    this.invalidate(instance);
    const started = this.begin<BuildModel>(instance, false, async operation => {
      if (required) await this.validateRunOptions(operation, required.values, required.modelValues);
      const before = await operation.decode<{ sync: { fingerprint: string; watch: string[] } }>("build.syncFingerprint", { projects: [] });
      let nativeSources: BuildConfigurationSourceVersion[] | undefined;
      const declaration = (operation.tool.manifest.buildSystems as Array<{ id: string; configuration?: { source?: string } }> | undefined)
        ?.find(system => system.id === operation.record.instance.buildSystemID);
      if (declaration?.configuration?.source === "provider") {
        const result = await operation.perform("build.configurationPlan", { refresh: true });
        const decoded = await operation.decode<{ configuration: BuildNativeConfiguration }>("build.decodeConfiguration", { result }, false);
        this.rememberConfiguration(operation, decoded.configuration);
        nativeSources = decoded.configuration.sources.map(({ uri, revision }) => ({ uri, revision }));
      }
      const result = await operation.perform("build.modelPlan", { refresh: true });
      const decoded = await operation.decode<{ model: BuildModel }>("build.decodeModel", { result });
      if (required) await this.validateRunOptions(operation, required.values, decoded.model.optionValues);
      const after = await operation.decode<typeof before>("build.syncFingerprint", { projects: [] });
      if (before.sync.fingerprint !== after.sync.fingerprint) { this.invalidate(operation.record.instance); operation.current(); }
      const watched = await operation.decode<typeof before>("build.syncFingerprint", { projects: decoded.model.projects.map(project => project.path) });
      if (nativeSources) await this.checkNativeSources(operation, nativeSources);
      operation.current();
      const selected = operation.record.instance;
      this.fileInputs.remember(owner(selected), watched.sync.watch);
      this.models.set(owner(selected), structuredClone(decoded.model));
      this.modelInputs.set(owner(selected), { options: fingerprint(selected.options), context: operation.context, sync: watched.sync.fingerprint, nativeSources, current: operation.current });
      this.factsChanged();
      return decoded.model;
    }, false);
    return this.trackSourcePreparation(started, instance, true);
  }

  /** The Run owns private model/source leases, but borrows the workspace's
   * backend session. Closing it must never stop another Run or the Build pane. */
  createRunScope(instance: BuildInstance, input: BuildConfigurationRunSelection, configurationID?: string) {
    if (this.disposed) throw this.revoked();
    const baseline = structuredClone(instance), key = owner(baseline), revision = this.revisions.get(key) ?? 0;
    const selected = { ...baseline, options: { ...baseline.options, ...structuredClone(input.optionOverrides) } };
    const current = () => {
      if (this.disposed || (this.revisions.get(key) ?? 0) !== revision) throw this.revoked();
    };
    const scope = new WindowsBuildProviderWorkspace(this.workspacePath, { ...this.ports,
      guard: () => { const guard = this.ports.guard(); return plugin => { current(); guard(plugin); }; },
      tools: (target, root, checkVersions) => this.ports.tools(target, root, checkVersions, configurationID),
      providers: { send: (target, request) => this.ports.providers.send(target, request), stop: async () => {} },
    });
    this.runScopes.set(scope, key);
    const target = { workspacePath: this.workspacePath, pluginId: baseline.pluginID, buildSystemId: baseline.buildSystemID };
    this.targets.set(JSON.stringify(target), target);
    return { domain: scope, instance: selected,
      requiredOptions: { values: structuredClone(selected.options) },
      dispose: async () => { try { await scope.dispose(); } finally { this.runScopes.delete(scope); } } };
  }

  private async validateRunOptions(operation: BuildWork, overrides: Record<string, unknown>, modelValues?: BuildModel["optionValues"]) {
    if (!Object.keys(overrides).length) return;
    const resolved = await operation.decode<{ options: { options: Array<{ id: string; source: string }>; dropped: string[] } }>(
      "build.resolveOptions", { options: operation.record.instance.options, modelValues }, false);
    if (Object.keys(overrides).some(key => resolved.options.dropped.includes(key)
      || !resolved.options.options.some(option => option.id === key && option.source === "user"))) {
      throw new Error(this.ports.translate("native.buildOptionInvalid"));
    }
  }
  private trackSourcePreparation<T>(operation: { operationID: string; completion: Promise<T> }, instance: BuildInstance, model: boolean) {
    this.fileInputs.begin(operation.operationID, owner(instance), model);
    const finish = () => { this.fileInputs.finish(operation.operationID); };
    void operation.completion.then(finish, finish); return operation;
  }

  dependencies(instance: BuildInstance, projectID?: string) {
    return this.begin<{ dependencies: BuildDependencies }>(instance, false, async operation => {
      const project = this.project(operation.record.instance, projectID);
      const result = await operation.perform("build.dependencyPlan", { project });
      const decoded = await operation.decode<{ dependencies: BuildDependencies }>("build.decodeDependencies", { result, project: project?.path });
      operation.current();
      const key = owner(operation.record.instance);
      const cacheKey = JSON.stringify([key, projectID ?? ""]);
      this.dependencyResults.delete(cacheKey);
      this.dependencyResults.set(cacheKey, { instance: key, snapshot: { ...structuredClone(decoded.dependencies), revision: operation.record.id } });
      // Core bounds each tree. Keep only four recently requested trees across
      // all roots, rather than one large tree for every reactor project.
      while (this.dependencyResults.size > MAX_DEPENDENCY_SNAPSHOTS) this.dependencyResults.delete(this.dependencyResults.keys().next().value!);
      this.factsChanged();
      return decoded;
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
      return this.savingConfiguration(key, async () => {
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
      });
    }, false);
  }

  private async savingConfiguration<T>(key: string, body: () => Promise<T>): Promise<T> {
    this.configurationSaves.set(key, (this.configurationSaves.get(key) ?? 0) + 1);
    try { return await body(); }
    finally {
      const count = this.configurationSaves.get(key)! - 1;
      if (count) this.configurationSaves.set(key, count);
      else { this.configurationSaves.delete(key); this.nativeWatches.get(key)?.recheck(); }
    }
  }
  private retireNativeWatch(key: string): void {
    const watch = this.nativeWatches.get(key); this.nativeWatches.delete(key);
    if (watch) {
      const cleanup = this.retainCleanup(() => watch.dispose());
      this.nativeRetirements.set(cleanup, key);
      void cleanup.then(() => { this.nativeRetirements.delete(cleanup); }, () => {});
    }
  }
  private async checkNativeSources(operation: Pick<BuildWork, "record" | "current" | "native">, sources: BuildConfigurationSourceVersion[]): Promise<void> {
    const check = this.ports.configurationCheck, selected = operation.record.instance;
    if (!check) throw new Error(this.message("unsupportedSource"));
    const result = await operation.native(check({ workspacePath: this.workspacePath, pluginId: selected.pluginID, buildSystemId: selected.buildSystemID }, sources));
    operation.current();
    if (!result.current) { this.invalidate(selected); throw this.revoked(); }
  }

  private nativeConfigurationChanged(selected: BuildInstance, savingOperationID: string): void {
    // User/installation settings may be inherited by sibling roots. Even if
    // the caller cancelled while atomic publication was already in progress,
    // its completed write must invalidate facts read before publication.
    const keys = new Set([...this.models.keys(), ...this.configurations.keys(), ...[...this.controllers.values()].map(pending => pending.instance)]
      .filter(key => { const [plugin, system] = JSON.parse(key); return plugin === selected.pluginID && system === selected.buildSystemID; }));
    for (const key of keys) { this.models.delete(key); this.modelInputs.delete(key); this.configurations.delete(key); this.results.forget(key); this.fileInputs.forget(key); this.retireNativeWatch(key); }
    for (const [id, cached] of this.dependencyResults) if (keys.has(cached.instance)) this.dependencyResults.delete(id);
    for (const [id, pending] of this.controllers) {
      if (id !== savingOperationID && keys.has(pending.instance)) pending.controller.abort(this.revoked());
    }
    this.factsChanged();
    this.changed();
  }

  private rememberConfiguration(operation: BuildWork, snapshot: BuildNativeConfiguration): void {
    operation.current();
    const selected = operation.record.instance;
    this.configurations.set(owner(selected), { snapshot: fingerprint(snapshot), context: operation.context,
      options: fingerprint(selected.options), current: operation.current });
    const key = owner(selected); this.retireNativeWatch(key);
    if (this.ports.watchConfiguration) {
      const sources = snapshot.sources.map(({ uri, revision }) => ({ uri, revision }));
      const watch = this.ports.watchConfiguration({ workspacePath: this.workspacePath, pluginId: selected.pluginID, buildSystemId: selected.buildSystemID }, sources,
        () => queueMicrotask(() => {
          if (this.nativeWatches.get(key) === watch && !this.configurationSaves.has(key)) this.invalidateKey(key);
        }));
      this.nativeWatches.set(key, watch);
    }
    this.factsChanged();
  }

  executeTask(instance: BuildInstance, task: string, projectID?: string, userArguments: string[] = []) {
    const argumentsSnapshot = [...userArguments];
    return this.begin<Record<string, unknown>>(instance, true, async operation => {
      const project = this.project(operation.record.instance, projectID);
      return await this.execution(operation, await operation.perform("build.taskPlan", { task, project, userArguments: argumentsSnapshot }), project);
    });
  }

  prepareRun(instance: BuildInstance, selection: BuildRunSelection) {
    const snapshot = structuredClone(selection);
    return this.begin<BuildPreparedRun>(instance, true, async operation => {
      const selected = operation.record.instance, model = this.models.get(owner(selected))!, inputs = this.modelInputs.get(owner(selected))!;
      return await prepareBuildRun(this.workspacePath, operation, model, snapshot,
        this.runValidation(operation, model, inputs.sync, inputs.nativeSources), () => new Error(this.message("missingProject")));
    });
  }

  /** A single Run may read another effective model. Its facts, options and
   * receipts remain local to this operation; the default model/drafts survive. */
  prepareConfigurationRun(instance: BuildInstance, selection: BuildConfigurationRunSelection) {
    const baseline = structuredClone(instance), input = structuredClone(selection), key = owner(baseline);
    const model = this.models.get(key), inputs = this.modelInputs.get(key);
    if (!model || model.truncated || !inputs || !this.modelIsCurrent(baseline)) throw new Error(this.message("incompleteModel"));
    const selected = { ...baseline, options: { ...baseline.options, ...input.optionOverrides } };
    const started = this.begin<BuildPreparedRun>(selected, true, async operation => {
      if (operation.context !== inputs.context) { this.invalidate(baseline); throw this.revoked(); }
      await this.validateRunOptions(operation, input.optionOverrides, model.optionValues);
      if (fingerprint(selected.options) === inputs.options) {
        const target = configurationRunSelection(operation.tool.manifest, selected.buildSystemID, model, input);
        if (!target) throw new Error(this.message("missingProject"));
        const validate = this.runValidation(operation, model, inputs.sync, inputs.nativeSources);
        await validate();
        return await prepareBuildRun(this.workspacePath, operation, model, target, validate, () => new Error(this.message("missingProject")));
      }
      const projects = model.projects.map(project => project.path);
      const initial = await operation.decode<{ sync: { fingerprint: string } }>("build.syncFingerprint", { projects, options: baseline.options });
      if (initial.sync.fingerprint !== inputs.sync) { this.invalidate(baseline); throw this.revoked(); }
      // A sync fingerprint includes effective options. Compare default inputs
      // with defaults, then compare the private model only with its own inputs.
      const before = await operation.decode<{ sync: { fingerprint: string } }>("build.syncFingerprint", { projects });
      if (inputs.nativeSources) {
        const raw = await operation.perform("build.configurationPlan", { refresh: true });
        const decoded = await operation.decode<{ configuration: BuildNativeConfiguration }>("build.decodeConfiguration", { result: raw }, false);
        const sources = decoded.configuration.sources.map(({ uri, revision }) => ({ uri, revision }));
        // Core's current Run overrides are invocation preferences (Profiles /
        // skip tests), not another native source selection. Keep the existing
        // source watcher lease and reject a changed native baseline.
        if (fingerprint(sources) !== fingerprint(inputs.nativeSources)) { this.invalidate(baseline); throw this.revoked(); }
        await this.checkNativeSources(operation, sources);
      }
      const raw = await operation.perform("build.modelPlan", { refresh: true });
      const decoded = await operation.decode<{ model: BuildModel }>("build.decodeModel", { result: raw });
      const after = await operation.decode<typeof before>("build.syncFingerprint", { projects });
      if (before.sync.fingerprint !== after.sync.fingerprint) { this.invalidate(baseline); throw this.revoked(); }
      await this.validateRunOptions(operation, input.optionOverrides, decoded.model.optionValues);
      const watched = await operation.decode<typeof before>("build.syncFingerprint", { projects: decoded.model.projects.map(project => project.path) });
      const target = configurationRunSelection(operation.tool.manifest, selected.buildSystemID, decoded.model, input);
      if (!target) throw new Error(this.message("missingProject"));
      return await prepareBuildRun(this.workspacePath, operation, decoded.model, target,
        this.runValidation(operation, decoded.model, watched.sync.fingerprint, inputs.nativeSources), () => new Error(this.message("missingProject")));
    }, false);
    return this.trackSourcePreparation(started, baseline, true);
  }

  private runValidation(operation: BuildWork, model: BuildModel, expected: string, sources?: BuildConfigurationSourceVersion[]) {
    return async () => {
      operation.current();
      const selected = operation.record.instance;
      const target = { workspacePath: this.workspacePath, pluginId: selected.pluginID, buildSystemId: selected.buildSystemID };
      const tool = await operation.native(this.ports.tools(target, selected.root, false));
      operation.current();
      if (fingerprint(tool) !== operation.context) { this.invalidate(selected); throw this.revoked(); }
      const sync = await operation.decode<{ sync: { fingerprint: string } }>("build.syncFingerprint", { projects: model.projects.map(project => project.path) });
      if (sync.sync.fingerprint !== expected) { this.invalidate(selected); throw this.revoked(); }
      if (sources) await this.checkNativeSources(operation, sources);
      operation.current();
    };
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
    return this.trackSourcePreparation(this.begin(instance, false, async operation => {
      const result = await operation.perform("build.testDiscoveryPlan", { refresh: true });
      const decoded = await operation.decode<{ discovery: { tests: BuildTestSelector[] } }>("build.decodeTestDiscovery", { result });
      operation.current();
      this.results.rememberDiscovery(owner(operation.record.instance), { ...decoded.discovery, revision: operation.record.id });
      this.factsChanged(); return decoded;
    }), instance, false);
  }

  executeDiscoveredTest(instance: BuildInstance, id: string) {
    const selected = this.testDiscovery(instance)?.tests.find(test => test.id === id);
    if (!selected) throw new Error(this.message("testsExpired"));
    return this.executeTests(instance, { projectID: selected.project?.id, targetID: selected.target?.id, suite: selected.suite, case: selected.case });
  }

  executeTests(instance: BuildInstance, selection: BuildTestSelection = {}) {
    const snapshot = structuredClone(selection);
    return this.begin(instance, true, async operation => {
      const target = snapshot.targetID ? this.models.get(owner(operation.record.instance))?.targets.find(target => target.id === snapshot.targetID) : undefined;
      if (snapshot.targetID && !target) throw new Error(this.message("missingProject"));
      const project = this.project(operation.record.instance, snapshot.projectID ?? target?.projectID);
      const { projectID: _, targetID: __, ...filters } = snapshot;
      const result = await operation.perform("build.testPlan", { ...filters, project, target,
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
    const diagnostics = await operation.decode<{ diagnostics: BuildDiagnostic[] }>("build.decodeDiagnostics", { output: result.output });
    let tests: { results: BuildTestResults } | undefined;
    if (result.testResults !== undefined) tests = await operation.decode("build.decodeTestResults", {
      project: project?.path, projects: this.models.get(owner(operation.record.instance))?.projects.map(project => project.path) ?? [],
      output: result.output, result: result.testResults, suite,
    });
    operation.current();
    this.results.remember(operation.record.id, owner(operation.record.instance), { diagnostics: diagnostics.diagnostics, tests: tests?.results });
    this.factsChanged();
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
              if (record.phase !== "running") return;
              try { current(); } catch { return; }
              if (!value || typeof value !== "object") return;
              const progress = value as { output?: unknown; message?: unknown };
              const text = typeof progress.output === "string" ? progress.output : typeof progress.message === "string" ? progress.message + "\n" : "";
              this.outputOffsets.set(id, (this.outputOffsets.get(id) ?? 0) + text.length);
              record.output = (record.output + text).slice(-MAX_OUTPUT_CHARACTERS);
              this.changed();
            } }), controller.signal);
          current(); return value;
        };
        if (needsModel) {
          const checked = await decode<{ sync: { fingerprint: string } }>("build.syncFingerprint", { projects: model!.projects.map(project => project.path) });
          if (checked.sync.fingerprint !== this.modelInputs.get(key)?.sync) { this.invalidate(snapshot); throw this.revoked(); }
          const sources = this.modelInputs.get(key)?.nativeSources;
          if (sources) await this.checkNativeSources({ record, current, native: task => this.owned(task, controller.signal) }, sources);
        }
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
        for (const old of completed.slice(0, Math.max(0, completed.length - MAX_COMPLETED_OPERATIONS))) { this.records.delete(old.id); this.outputOffsets.delete(old.id); }
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
    const keys = new Set([...this.models.keys(), ...this.configurations.keys(), ...this.runScopes.values(), ...[...this.controllers.values()].map(pending => pending.instance)]);
    for (const key of keys) {
      const [plugin, system, root] = JSON.parse(key);
      if (plugin === pluginID) this.invalidate({ pluginID: plugin, buildSystemID: system, root, options: {} });
    }
    const targets = [...this.targets.values()].filter(target => target.pluginId === pluginID);
    const watches = [...this.nativeRetirements].filter(([, key]) => JSON.parse(key)[0] === pluginID).map(([task]) => task);
    const outcomes = await Promise.allSettled([...targets.map(target => this.ports.providers.stop(target)), ...watches]);
    const failure = outcomes.find(result => result.status === "rejected");
    if (failure?.status === "rejected") throw failure.reason;
  }

  async dispose(): Promise<void> {
    // Retry only failures retained before this close. A newly failed release
    // remains visible to the caller and requires another explicit cleanup.
    const retries = [...this.cleanupFailures.keys()];
    this.disposed = true;
    for (const [scope, key] of this.runScopes) scope.invalidateKey(key);
    for (const pending of this.controllers.values()) pending.controller.abort(this.revoked());
    this.models.clear();
    this.modelInputs.clear();
    this.results.clear();
    this.fileInputs.clear();
    for (const key of this.nativeWatches.keys()) this.retireNativeWatch(key);
    this.dependencyResults.clear();
    this.configurations.clear();
    this.factsChanged();
    this.changed();
    const stops = await Promise.allSettled([...this.targets.values()].map(target => this.ports.providers.stop(target)));
    // Cancelling a completion may register cleanup for its late native reply.
    // Drain newly registered work as well as the first captured batch.
    while (this.pendingTasks.size) await Promise.allSettled([...this.pendingTasks]);
    await Promise.allSettled(retries.map(release => this.retainCleanup(release)));
    const failures = stops.filter((result): result is PromiseRejectedResult => result.status === "rejected");
    if (failures.length || this.cleanupFailures.size) throw Object.assign(new Error(this.message("cleanupFailed")),
      { causes: [...failures.map(result => result.reason), ...this.cleanupFailures.values()] });
    this.nativeRetirements.clear();
  }
}
