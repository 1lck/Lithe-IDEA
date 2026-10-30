import type { BuildInstance, BuildNativeConfiguration, WindowsBuildProviderWorkspace } from "./build-provider-workspace";

type Source = BuildNativeConfiguration["sources"][number];
type Draft = Record<string, { override: boolean; value: unknown }>;
export interface NativeConfigurationSnapshot {
  phase: "idle" | "loading" | "ready" | "failed";
  saving: boolean;
  stale: boolean;
  requiresProjectTool: boolean;
  configuration?: BuildNativeConfiguration;
  drafts: Record<string, Draft>;
  error?: string;
}
const same = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);
function original(source: Source): Draft {
  return Object.fromEntries(source.fields.map(field => [field.id,
    { override: field.value !== null, value: structuredClone(field.value ?? field.effectiveValue
      ?? (field.kind === "boolean" ? false : field.kind === "stringList" ? [] : "")) }]));
}

/** Non-sensitive source drafts belong to the workspace, not to a settings
 * component. File bytes and conflict protection remain in the native adapter. */
export class BuildNativeConfigurationController {
  private state: NativeConfigurationSnapshot = { phase: "idle", saving: false, stale: false, requiresProjectTool: false, drafts: {} };
  private readonly listeners = new Set<() => void>();
  private readonly unsubscribe: () => void;
  private generation = 0;
  private operationID?: string;
  private disposed = false;
  constructor(private readonly domain: WindowsBuildProviderWorkspace, private readonly instance: () => BuildInstance | undefined) {
    this.unsubscribe = domain.subscribe(() => {
      if (this.state.configuration && !this.busy() && !this.current() && !this.state.stale) this.publish({ stale: true });
    });
  }
  snapshot = (): NativeConfigurationSnapshot => this.state;
  subscribe = (listener: () => void) => { this.listeners.add(listener); return () => { this.listeners.delete(listener); }; };
  private publish(values: Partial<NativeConfigurationSnapshot>) {
    if (this.disposed) return;
    this.state = { ...this.state, ...values };
    for (const listener of this.listeners) listener();
  }
  private busy(): boolean { return this.state.phase === "loading" || this.state.saving; }
  private current(): boolean {
    const selected = this.instance();
    return !!selected && !!this.state.configuration && this.domain.configurationIsCurrent(selected, this.state.configuration);
  }
  private fresh(configuration: BuildNativeConfiguration): Record<string, Draft> {
    return Object.fromEntries(configuration.sources.map(source => [source.id, original(source)]));
  }
  read(allowProjectTool = false): Promise<void> {
    const selected = this.instance();
    if (this.disposed || !selected) return Promise.resolve();
    if (this.operationID) this.domain.cancel(this.operationID);
    const generation = ++this.generation;
    this.publish({ phase: "loading", saving: false, error: undefined });
    const operation = this.domain.readConfiguration(selected, allowProjectTool); this.operationID = operation.operationID;
    return operation.completion.then(configuration => {
      if (this.disposed || this.generation !== generation) return;
      this.publish({ phase: "ready", configuration, drafts: this.fresh(configuration), stale: false, requiresProjectTool: false });
    }, error => {
      if (this.disposed || this.generation !== generation) return;
      this.publish({ phase: "failed", error: error instanceof Error ? error.message : String(error), stale: !!this.state.configuration,
        requiresProjectTool: error?.code === "build.configuration.projectToolRequiresAction" });
    });
  }
  set(sourceID: string, fieldID: string, update: Partial<Draft[string]>): void {
    const source = this.state.configuration?.sources.find(source => source.id === sourceID);
    const draft = this.state.drafts[sourceID]?.[fieldID];
    if (this.disposed || this.busy() || this.state.stale || !source?.writable || !draft) return;
    if (!this.current()) { this.publish({ stale: true }); return; }
    this.publish({ drafts: { ...this.state.drafts, [sourceID]: { ...this.state.drafts[sourceID], [fieldID]: { ...draft, ...structuredClone(update) } } } });
  }
  cancel(sourceID: string): void {
    const source = this.state.configuration?.sources.find(source => source.id === sourceID);
    if (source && !this.busy()) this.publish({ drafts: { ...this.state.drafts, [sourceID]: original(source) } });
  }
  edits(sourceID: string): Record<string, unknown> {
    const source = this.state.configuration?.sources.find(source => source.id === sourceID);
    if (!source) return {};
    return Object.fromEntries(source.fields.flatMap(field => {
      const draft = this.state.drafts[sourceID]?.[field.id];
      if (!draft) return [];
      const value = draft.override ? draft.value : null;
      return !same(value, field.value) ? [[field.id, value]] : [];
    }));
  }
  save(sourceID: string): Promise<void> {
    const selected = this.instance(), configuration = this.state.configuration;
    const source = configuration?.sources.find(source => source.id === sourceID);
    if (this.disposed || this.busy() || this.state.stale || !selected || !configuration || !source?.writable) return Promise.resolve();
    if (!this.current()) { this.publish({ stale: true }); return Promise.resolve(); }
    const values = this.edits(sourceID);
    if (!Object.keys(values).length) return Promise.resolve();
    const generation = ++this.generation;
    this.publish({ saving: true, error: undefined });
    const operation = this.domain.saveConfiguration(selected, configuration, { sourceID, revision: source.revision, values });
    this.operationID = operation.operationID;
    return operation.completion.then(readback => {
      if (this.disposed || this.generation !== generation) return;
      const drafts = this.fresh(readback);
      // Saving one source must not discard a draft in another source. Values
      // still inherited there instead follow the newly read effective value.
      for (const previous of configuration.sources.filter(source => source.id !== sourceID)) {
        const old = original(previous);
        for (const [fieldID, draft] of Object.entries(this.state.drafts[previous.id] ?? {})) {
          if (drafts[previous.id]?.[fieldID] && !same(draft, old[fieldID])) drafts[previous.id]![fieldID] = draft;
        }
      }
      this.publish({ phase: "ready", saving: false, configuration: readback, drafts, stale: false });
    }, error => {
      if (this.disposed || this.generation !== generation) return;
      this.publish({ saving: false, error: error instanceof Error ? error.message : String(error), stale: !this.current() });
    });
  }
  dispose(): void {
    this.disposed = true; this.generation++; this.unsubscribe(); this.listeners.clear();
    if (this.operationID) this.domain.cancel(this.operationID);
  }
}
