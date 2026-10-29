import type { ApproveBuildModel } from "@/features/build-systems/build-systems-service";

export interface PluginReloadReceipt {
  pluginId: string;
  workspacePath: string;
  expectedIdentity: string;
  expectedPackageIdentity: string;
  scope?: "global" | "project";
  project?: { workspaceId: string; registration: number; windowIncarnation: number };
}
export interface PluginReloadState {
  receipt: PluginReloadReceipt;
  busy: boolean;
  error: string | null;
  cancellable: boolean;
}

/** Saved values and an explicit reload are separate operations. Receipts
 * outlive settings-page revocation so a failed process drain remains retryable. */
export class PluginSettingsReloads {
  private readonly pending = new Map<string, PluginReloadState>();
  private readonly listeners = new Set<() => void>();
  private readonly controllers = new Map<string, AbortController>();
  private version = 0;
  constructor(
    private readonly ports: {
      reload(
        receipt: PluginReloadReceipt,
        approve?: ApproveBuildModel,
        signal?: AbortSignal,
        modelPhase?: () => void,
      ): Promise<unknown>;
      refresh(receipt: PluginReloadReceipt): Promise<void>;
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
  key(receipt: PluginReloadReceipt) {
    return receipt.scope === "project"
      ? JSON.stringify([receipt.pluginId, receipt.workspacePath, receipt.project])
      : receipt.pluginId;
  }
  state(key: string) {
    return this.pending.get(key);
  }
  busy(pluginId: string) {
    return this.states().some((state) => state.receipt.pluginId === pluginId && state.busy);
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
        state.error === "Error: plugin.settings.conflict" ||
        state.error === "Error: plugin.settings.reloadCancelled")
    );
  }
  require(receipt: PluginReloadReceipt) {
    this.saved(receipt, true);
  }
  saved(receipt: PluginReloadReceipt, requiresReload: boolean) {
    const key = this.key(receipt);
    const pending = this.pending.get(key);
    if (this.busy(receipt.pluginId)) throw new Error("plugin.settings.reloadBusy");
    // A later explicit save advances the settings baseline, never the
    // accepted package whose reload the user originally requested.
    if (pending && pending.receipt.expectedPackageIdentity !== receipt.expectedPackageIdentity)
      throw new Error("plugin.settings.packageChanged");
    const matching = [...this.pending].filter(
      ([, other]) =>
        other.receipt.pluginId === receipt.pluginId &&
        other.receipt.workspacePath === receipt.workspacePath &&
        JSON.stringify(other.receipt.project) === JSON.stringify(receipt.project),
    );
    for (const [, other] of matching) {
      if (other.receipt.expectedPackageIdentity !== receipt.expectedPackageIdentity)
        throw new Error("plugin.settings.packageChanged");
    }
    let changed = false;
    for (const [otherKey, other] of matching) {
      this.pending.set(otherKey, {
        ...other,
        receipt: { ...other.receipt, expectedIdentity: receipt.expectedIdentity },
      });
      changed = true;
    }
    if (requiresReload || pending) {
      this.pending.set(key, { receipt, busy: false, error: null, cancellable: false });
      changed = true;
    }
    if (!changed) return;
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
  async confirm(pluginId: string, approve?: ApproveBuildModel) {
    const state = this.pending.get(pluginId);
    if (!state || this.busy(state.receipt.pluginId)) return;
    const controller = new AbortController();
    this.controllers.set(pluginId, controller);
    this.pending.set(pluginId, { ...state, busy: true, error: null, cancellable: false });
    this.changed();
    try {
      await this.ports.reload(state.receipt, approve, controller.signal, () => {
        const current = this.pending.get(pluginId);
        if (current?.busy && this.controllers.get(pluginId) === controller) {
          this.pending.set(pluginId, { ...current, cancellable: true });
          this.changed();
        }
      });
      await this.ports.refresh(state.receipt);
      this.pending.delete(pluginId);
    } catch (error) {
      this.pending.set(pluginId, {
        ...state,
        busy: false,
        error: String(error),
        cancellable: false,
      });
    } finally {
      this.controllers.delete(pluginId);
    }
    this.changed();
  }
  cancel(key: string) {
    if (this.pending.get(key)?.cancellable) this.controllers.get(key)?.abort();
  }
}

export const pluginSettingsReloads = new PluginSettingsReloads({
  reload: async (receipt, approve, signal, modelPhase) => {
    if (receipt.scope === "project") {
      const { reloadProjectSettings } = await import("./declarative-plugin-reload-project");
      return reloadProjectSettings(receipt, approve, signal, modelPhase);
    }
    const { invoke } = await import("@/platform/tauri-core");
    return invoke("declarative_plugins_reload_settings", { ...receipt, scope: "global" });
  },
  refresh: async (receipt) => {
    if (receipt.scope === "project") return;
    const { refreshDeclarativeUI } = await import("./declarative-plugin-ui");
    await refreshDeclarativeUI();
  },
});
