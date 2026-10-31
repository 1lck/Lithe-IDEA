import type { WindowsBuildCatalog } from "@/platform/build-provider-platform";
import type { BuildInstance, WindowsBuildProviderWorkspace } from "./build-provider-workspace";
import { BuildNativeConfigurationController } from "./build-native-configuration-controller";
import { buildCatalogMayChange } from "./build-file-inputs";
import type { BuildTargetChoice } from "./build-target-presentation";

export type BuildEntry = WindowsBuildCatalog["detection"]["instances"][number];
export interface BuildWorkspaceSnapshot {
  status: "idle" | "loading" | "ready" | "failed";
  entries: BuildEntry[];
  manifests: Record<string, Record<string, unknown>>;
  selectedID?: string;
  operationID?: string;
  modelRevision: number;
  error?: string;
}
export interface BuildWorkspaceControllerPorts {
  detect: (path: string) => Promise<WindowsBuildCatalog>;
  domain: WindowsBuildProviderWorkspace;
  guard: () => (plugin: string) => void;
  scheduleRefresh?: (refresh: () => Promise<void>) => () => void;
  runTarget?: (choice: BuildTargetChoice, assertCurrent: () => void, signal: AbortSignal) => Promise<void>;
}

/** Product catalog/model state. High-volume progress remains subscribed by the
 * output leaf directly, never copied into workbench or settings state. */
export class BuildWorkspaceController {
  private state: BuildWorkspaceSnapshot = { status: "idle", entries: [], manifests: {}, modelRevision: 0 };
  private readonly listeners = new Set<() => void>();
  private readonly pending = new Set<Promise<unknown>>();
  private generation = 0;
  private targetRevision = 0;
  private readonly targetPreparations = new Set<AbortController>();
  private detection?: { generation: number; completion: Promise<void> };
  private disposed = false;
  private cancelScheduledRefresh?: () => void;
  private readonly nativeEditors = new Map<string, BuildNativeConfigurationController>();
  readonly domain: WindowsBuildProviderWorkspace;
  private readonly unsubscribeFacts: () => void;

  constructor(readonly workspacePath: string, private readonly ports: BuildWorkspaceControllerPorts) {
    this.domain = ports.domain;
    this.unsubscribeFacts = this.domain.subscribeFacts(() => {
      if (!this.disposed) this.publish({ modelRevision: this.state.modelRevision + 1 });
    });
  }
  snapshot = (): BuildWorkspaceSnapshot => this.state;
  subscribe = (listener: () => void): (() => void) => { this.listeners.add(listener); return () => { this.listeners.delete(listener); }; };
  private publish(values: Partial<BuildWorkspaceSnapshot>): void {
    this.state = { ...this.state, ...values };
    for (const listener of this.listeners) listener();
  }
  private own<T>(promise: Promise<T>): Promise<T> {
    this.pending.add(promise);
    const finished = () => { this.pending.delete(promise); }; void promise.then(finished, finished);
    return promise;
  }
  refresh(): Promise<void> {
    if (this.disposed) return Promise.resolve();
    this.cancelScheduledRefresh?.(); this.cancelScheduledRefresh = undefined;
    const generation = ++this.generation, guard = this.ports.guard();
    for (const entry of this.state.entries) this.domain.invalidate(entry);
    this.publish({ status: "loading", error: undefined, entries: [], manifests: {}, modelRevision: this.state.modelRevision + 1 });
    const completion = this.own((async () => {
      try {
        const catalog = await this.ports.detect(this.workspacePath);
        if (this.disposed || generation !== this.generation) return;
        const manifests: Record<string, Record<string, unknown>> = {};
        for (const { manifest } of catalog.plugins) {
          if (typeof manifest.id !== "string") continue;
          try { guard(manifest.id); manifests[manifest.id] = manifest; } catch { /* Revoked declarations cannot reappear after detection. */ }
        }
        const entries = catalog.detection.instances.filter(entry => manifests[entry.pluginID]);
        this.publish({ status: "ready", entries, manifests,
          selectedID: entries.some(entry => entry.id === this.state.selectedID) ? this.state.selectedID : entries[0]?.id });
      } catch (error) {
        if (!this.disposed && generation === this.generation) this.publish({ status: "failed", error: error instanceof Error ? error.message : String(error) });
      }
    })());
    this.detection = { generation, completion };
    const finished = () => { if (this.detection?.completion === completion) this.detection = undefined; };
    void completion.then(finished, finished); return completion;
  }
  ensureDetected(checkReadyInputs = false): Promise<void> {
    if (this.disposed) return Promise.resolve();
    if (this.detection?.generation === this.generation) return this.detection.completion;
    if (this.state.status !== "ready") return this.refresh();
    if (!checkReadyInputs) return Promise.resolve();
    const generation = this.generation, guard = this.ports.guard();
    const completion = this.own((async () => {
      try {
        const catalog = await this.ports.detect(this.workspacePath);
        if (this.disposed || generation !== this.generation) return;
        const manifests: Record<string, Record<string, unknown>> = {};
        for (const { manifest } of catalog.plugins) {
          if (typeof manifest.id !== "string") continue;
          try { guard(manifest.id); manifests[manifest.id] = manifest; } catch { /* Revoked entries stay unavailable. */ }
        }
        const entries = catalog.detection.instances.filter(entry => manifests[entry.pluginID]);
        // A Run rechecks canonical saved options even if a file notification
        // was missed. Unchanged catalogs retain their object/model identities
        // so concurrent services do not cancel each other's preparations.
        if (JSON.stringify({ entries, manifests }) === JSON.stringify({ entries: this.state.entries, manifests: this.state.manifests })) return;
        for (const entry of this.state.entries) this.domain.invalidate(entry);
        this.generation++;
        if (this.detection) this.detection.generation = this.generation;
        this.publish({ status: "ready", entries, manifests, error: undefined, modelRevision: this.state.modelRevision + 1,
          selectedID: entries.some(entry => entry.id === this.state.selectedID) ? this.state.selectedID : entries[0]?.id });
      } catch (error) {
        if (this.disposed || generation !== this.generation) return;
        for (const entry of this.state.entries) this.domain.invalidate(entry);
        this.generation++;
        this.publish({ status: "failed", entries: [], manifests: {}, modelRevision: this.state.modelRevision + 1,
          error: error instanceof Error ? error.message : String(error) });
      }
    })());
    this.detection = { generation, completion };
    const finished = () => { if (this.detection?.completion === completion) this.detection = undefined; };
    void completion.then(finished, finished); return completion;
  }
  select(id: string): void { if (this.state.entries.some(entry => entry.id === id)) this.publish({ selectedID: id, error: undefined }); }
  get canRunTargets(): boolean { return Boolean(this.ports.runTarget); }

  runTarget(instance: BuildInstance, choice: BuildTargetChoice, userArguments: string[]) {
    const cancellation = new AbortController();
    if (!this.ports.runTarget) return { completion: Promise.resolve(), cancel: () => {} };
    this.targetPreparations.add(cancellation);
    const modelCurrent = this.domain.modelGuard(instance), revision = ++this.targetRevision, guard = this.ports.guard();
    const assertCurrent = () => {
      cancellation.signal.throwIfAborted();
      guard(instance.pluginID);
      if (this.disposed) throw new DOMException("Aborted", "AbortError");
    };
    const completion = this.own((async () => {
      try {
        assertCurrent();
        modelCurrent();
        if (!this.state.entries.includes(instance as BuildEntry)) return;
        this.publish({ error: undefined });
        // Saving selectors triggers a Run-document watcher event. The launch
        // path re-detects and loads a fresh private model after that save; the
        // old UI model lease is needed only before starting persistence.
        await this.ports.runTarget!({ ...choice, reference: { ...choice.reference, userArguments: [...userArguments] } }, assertCurrent, cancellation.signal);
      } catch (error) {
        if (!this.disposed && revision === this.targetRevision && !(error instanceof DOMException && error.name === "AbortError")) {
          this.publish({ error: error instanceof Error ? error.message : String(error) });
        }
      } finally { this.targetPreparations.delete(cancellation); }
    })());
    return { completion, cancel: () => cancellation.abort() };
  }

  filesChanged(path: string, rescan = false): void {
    if (this.disposed) return;
    const affected = this.domain.filesChanged(path, rescan);
    if (!affected && !buildCatalogMayChange(this.state.manifests, this.workspacePath, path, rescan)) return;
    // Revoke the old catalog before debounce or any asynchronous native call.
    // Redetection reads declarations/files only; it never starts a Provider.
    this.generation++;
    for (const entry of this.state.entries) this.domain.invalidate(entry);
    this.publish({ status: "loading", entries: [], manifests: {}, error: undefined, modelRevision: this.state.modelRevision + 1 });
    this.cancelScheduledRefresh?.();
    this.cancelScheduledRefresh = this.ports.scheduleRefresh?.(() => { this.cancelScheduledRefresh = undefined; return this.refresh(); });
  }

  nativeConfiguration(entry: BuildInstance): BuildNativeConfigurationController {
    const key = JSON.stringify([entry.pluginID, entry.buildSystemID, entry.root]);
    let editor = this.nativeEditors.get(key);
    if (!editor) {
      editor = new BuildNativeConfigurationController(this.domain, () => this.state.entries.find(candidate => candidate.pluginID === entry.pluginID
        && candidate.buildSystemID === entry.buildSystemID && candidate.root === entry.root));
      this.nativeEditors.set(key, editor);
      if (this.disposed) editor.dispose();
    }
    return editor;
  }

  perform<T>(entry: BuildInstance, start: () => { operationID: string; completion: Promise<T> }): Promise<T | undefined> {
    if (this.disposed || !this.state.entries.some(candidate => candidate.pluginID === entry.pluginID
      && candidate.buildSystemID === entry.buildSystemID && candidate.root === entry.root)) return Promise.resolve(undefined);
    const generation = this.generation;
    if (this.state.operationID) this.domain.cancel(this.state.operationID);
    let operation: ReturnType<typeof start>;
    try { operation = start(); } catch (error) {
      this.publish({ error: error instanceof Error ? error.message : String(error) }); return Promise.resolve(undefined);
    }
    this.publish({ operationID: operation.operationID, error: undefined, modelRevision: this.state.modelRevision + 1 });
    return this.own(operation.completion.then(result => {
      if (this.disposed || generation !== this.generation || this.state.operationID !== operation.operationID) return undefined;
      this.publish({ modelRevision: this.state.modelRevision + 1 });
      return result;
    }, error => {
      if (!this.disposed && generation === this.generation && this.state.operationID === operation.operationID) {
        this.publish({ modelRevision: this.state.modelRevision + 1,
          error: this.domain.operationSummary(operation.operationID)?.phase === "cancelled" ? undefined : error instanceof Error ? error.message : String(error) });
      }
      return undefined;
    }));
  }

  async revokePlugin(pluginID: string): Promise<void> {
    const entries = this.state.entries.filter(entry => entry.pluginID === pluginID);
    for (const entry of entries) this.domain.invalidate(entry);
    const manifests = { ...this.state.manifests }; delete manifests[pluginID];
    const retained = this.state.entries.filter(entry => entry.pluginID !== pluginID);
    this.publish({ entries: retained, manifests,
      selectedID: retained.some(entry => entry.id === this.state.selectedID) ? this.state.selectedID : retained[0]?.id,
      modelRevision: this.state.modelRevision + 1 });
    await this.domain.stopPlugin(pluginID);
  }

  async dispose(): Promise<void> {
    this.disposed = true; this.generation++;
    for (const preparation of this.targetPreparations) preparation.abort();
    this.cancelScheduledRefresh?.(); this.cancelScheduledRefresh = undefined;
    this.unsubscribeFacts();
    for (const editor of this.nativeEditors.values()) editor.dispose();
    this.publish({ status: "idle", entries: [], manifests: {}, selectedID: undefined, modelRevision: this.state.modelRevision + 1 });
    try { await this.domain.dispose(); }
    finally { await Promise.allSettled([...this.pending]); }
  }
}
