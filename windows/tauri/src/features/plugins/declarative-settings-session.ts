import type {
  DeclarativePluginSetting,
  DeclarativeSettingSnapshot,
} from "./declarative-plugin-launch";

export type SettingEffectResult =
  | "restart"
  | "nextRun"
  | "immediate"
  | "nextStart"
  | "reloadUnavailable"
  | "reloadRequired"
  | "projectReloadUnavailable";
export interface SettingsSessionPorts {
  read(): Promise<DeclarativeSettingSnapshot>;
  write(
    id: string,
    scope: "global" | "project",
    value: unknown,
    identity: string,
  ): Promise<DeclarativeSettingSnapshot>;
  effect(
    setting: DeclarativePluginSetting,
    snapshot: DeclarativeSettingSnapshot,
    scope: "global" | "project",
  ): Promise<SettingEffectResult>;
  assertCurrent(): void;
}
export interface SettingsSessionState {
  snapshot: DeclarativeSettingSnapshot | null;
  busy: boolean;
  error: string | null;
  drafts: Record<string, unknown>;
  effect: SettingEffectResult | null;
}

/** One mounted plugin/workspace incarnation. Persistence always uses the
 * read baseline; failure retains drafts and an obsolete response never
 * publishes into another plugin/page. Core owns all value validation. */
export class DeclarativeSettingsSession {
  private generation = 0;
  private disposed = false;
  state: SettingsSessionState = {
    snapshot: null,
    busy: false,
    error: null,
    drafts: {},
    effect: null,
  };
  constructor(
    private readonly ports: SettingsSessionPorts,
    private readonly publish: (state: SettingsSessionState) => void,
  ) {}
  private emit(patch: Partial<SettingsSessionState>) {
    if (!this.disposed) {
      this.state = { ...this.state, ...patch };
      this.publish(this.state);
    }
  }
  private current(generation: number) {
    if (this.disposed || this.generation !== generation) return false;
    this.ports.assertCurrent();
    return true;
  }
  edit(id: string, scope: "global" | "project", value: unknown) {
    if (this.disposed || this.state.busy) return;
    const baseline = (
      scope === "project"
        ? this.state.snapshot?.resolvedProject
        : this.state.snapshot?.resolvedGlobal
    )?.find((item) => item.id === id);
    const drafts = { ...this.state.drafts };
    const key = `${scope}:${id}`;
    if (baseline && JSON.stringify(baseline.value) === JSON.stringify(value)) delete drafts[key];
    else drafts[key] = value;
    this.emit({ drafts });
  }
  async reload() {
    if (this.disposed || this.state.busy) return;
    const generation = ++this.generation;
    this.emit({ busy: true, error: null });
    try {
      this.ports.assertCurrent();
      const snapshot = await this.ports.read();
      if (this.current(generation)) this.emit({ snapshot, drafts: {}, effect: null });
    } catch (error) {
      if (!this.disposed && this.generation === generation) this.emit({ error: String(error) });
    } finally {
      if (!this.disposed && this.generation === generation) this.emit({ busy: false });
    }
  }
  async save(setting: DeclarativePluginSetting, scope: "global" | "project", reset = false) {
    const snapshot = this.state.snapshot;
    if (this.disposed || !snapshot || this.state.busy) return;
    const key = `${scope}:${setting.id}`;
    if (!reset && !Object.prototype.hasOwnProperty.call(this.state.drafts, key)) return;
    if (
      reset &&
      !Object.prototype.hasOwnProperty.call(
        scope === "project" ? snapshot.projectValues : snapshot.globalValues,
        setting.id,
      )
    )
      return;
    const generation = this.generation;
    this.emit({ busy: true, error: null, effect: null });
    try {
      this.ports.assertCurrent();
      const next = await this.ports.write(
        setting.id,
        scope,
        reset ? null : this.state.drafts[key],
        snapshot.identity,
      );
      if (!this.current(generation)) return;
      const drafts = { ...this.state.drafts };
      delete drafts[key];
      // A saved global value can become the project layer's inherited value.
      // Do not turn an already-equal pending draft into a new override.
      for (const [draftKey, draft] of Object.entries(drafts)) {
        const separator = draftKey.indexOf(":");
        const values =
          draftKey.slice(0, separator) === "project" ? next.resolvedProject : next.resolvedGlobal;
        const baseline = values.find((item) => item.id === draftKey.slice(separator + 1));
        if (baseline && JSON.stringify(baseline.value) === JSON.stringify(draft))
          delete drafts[draftKey];
      }
      this.emit({ snapshot: next, drafts });
      const effect = await this.ports.effect(setting, next, scope);
      if (this.current(generation)) this.emit({ effect });
    } catch (error) {
      if (!this.disposed && this.generation === generation) this.emit({ error: String(error) });
    } finally {
      if (!this.disposed && this.generation === generation) this.emit({ busy: false });
    }
  }
  cancel(id: string, scope: "global" | "project") {
    if (this.state.busy) return;
    const drafts = { ...this.state.drafts };
    delete drafts[`${scope}:${id}`];
    this.emit({ drafts });
  }
  dispose() {
    this.disposed = true;
    this.generation++;
  }
}

export async function applySettingEffect(
  setting: DeclarativePluginSetting,
  snapshot: DeclarativeSettingSnapshot,
  workspacePath: string | null,
  ports: {
    assertCurrent(): void;
    configuration(
      manifest: Record<string, unknown>,
      languageId: string,
      workspacePath: string,
    ): Promise<{ status: string; configuration?: unknown }>;
    push(args: {
      pluginId: string;
      workspacePath: string;
      languageId: string;
      configuration: unknown;
    }): Promise<boolean>;
    pluginId: string;
    savedForReload?(snapshot: DeclarativeSettingSnapshot, requiresReload: boolean): void;
  },
  scope: "global" | "project" = "global",
): Promise<SettingEffectResult> {
  ports.assertCurrent();
  // Every successful save has a newer CAS baseline, even when only an earlier
  // saved field requires reload. Project saves never create a global reload.
  ports.savedForReload?.(snapshot, setting.effect === "reload" && scope === "global");
  if (setting.effect === "reload") {
    if (scope === "project") return "projectReloadUnavailable";
    if (!ports.savedForReload) return "reloadUnavailable";
    return "reloadRequired";
  }
  if (setting.effect !== "immediate") return setting.effect === "nextRun" ? "nextRun" : "restart";
  if (!workspacePath) return "nextStart";
  const servers = Array.isArray(snapshot.manifest.languageServers)
    ? (snapshot.manifest.languageServers as Array<Record<string, unknown>>)
    : [];
  let pushed = false;
  for (const server of servers) {
    if (typeof server.languageID !== "string") continue;
    const result = await ports.configuration(snapshot.manifest, server.languageID, workspacePath);
    ports.assertCurrent();
    if (result.status !== "ok") throw new Error("plugin.settings.effectUnavailable");
    if (result.configuration == null) continue;
    pushed =
      (await ports.push({
        pluginId: ports.pluginId,
        workspacePath,
        languageId: server.languageID,
        configuration: result.configuration,
      })) || pushed;
    ports.assertCurrent();
  }
  return pushed ? "immediate" : "nextStart";
}
