export interface PluginReloadReceipt {
  pluginId: string;
  workspacePath: string;
  expectedIdentity: string;
  expectedPackageIdentity: string;
}
export interface PluginReloadState {
  receipt: PluginReloadReceipt;
  busy: boolean;
  error: string | null;
}

/** Saved values and an explicit reload are separate operations. Receipts
 * outlive settings-page revocation so a failed process drain remains retryable. */
export class PluginSettingsReloads {
  private readonly pending = new Map<string, PluginReloadState>();
  private readonly listeners = new Set<() => void>();
  private version = 0;
  constructor(
    private readonly ports: {
      reload(receipt: PluginReloadReceipt): Promise<unknown>;
      refresh(): Promise<void>;
    },
  ) {}
  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  };
  revision = () => this.version;
  private changed() {
    this.version++;
    for (const listener of this.listeners) listener();
  }
  state(pluginId: string) {
    return this.pending.get(pluginId);
  }
  states() {
    return [...this.pending.values()];
  }
  canPostpone(pluginId: string) {
    const state = this.pending.get(pluginId);
    return (
      !!state &&
      !state.busy &&
      (state.error === null ||
        state.error === "plugin.settings.conflict" ||
        state.error === "Error: plugin.settings.conflict")
    );
  }
  require(receipt: PluginReloadReceipt) {
    this.saved(receipt, true);
  }
  saved(receipt: PluginReloadReceipt, requiresReload: boolean) {
    const pending = this.pending.get(receipt.pluginId);
    if (!pending && !requiresReload) return;
    if (pending?.busy) throw new Error("plugin.settings.reloadBusy");
    // A later explicit save advances the settings baseline, never the
    // accepted package whose reload the user originally requested.
    if (pending && pending.receipt.expectedPackageIdentity !== receipt.expectedPackageIdentity)
      throw new Error("plugin.settings.packageChanged");
    this.pending.set(receipt.pluginId, { receipt, busy: false, error: null });
    this.changed();
  }
  postpone(pluginId: string) {
    const state = this.pending.get(pluginId);
    // Native conflicts leave the plugin active after fresh validation. Drain
    // and trust failures keep it revoked and must retain their retry owner.
    if (!state || !this.canPostpone(pluginId)) return;
    this.pending.delete(pluginId);
    this.changed();
  }
  async confirm(pluginId: string) {
    const state = this.pending.get(pluginId);
    if (!state || state.busy) return;
    this.pending.set(pluginId, { ...state, busy: true, error: null });
    this.changed();
    try {
      await this.ports.reload(state.receipt);
      await this.ports.refresh();
      this.pending.delete(pluginId);
    } catch (error) {
      this.pending.set(pluginId, { ...state, busy: false, error: String(error) });
    }
    this.changed();
  }
}

export const pluginSettingsReloads = new PluginSettingsReloads({
  reload: async (receipt) => {
    const { invoke } = await import("@/platform/tauri-core");
    return invoke("declarative_plugins_reload_settings", { ...receipt, scope: "global" });
  },
  refresh: async () => {
    const { refreshDeclarativeUI } = await import("./declarative-plugin-ui");
    await refreshDeclarativeUI();
  },
});
