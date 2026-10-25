import { invoke } from "@/platform/tauri-core";
import {
  rollbackDeclarativePlugin,
  setDeclarativePluginEnabled,
  uninstallDeclarativePlugin,
} from "../declarative-plugin-launch";
import {
  samePluginSelection,
  type PluginDetailsModel,
  type PluginDetailsOperation,
  type PluginDetailsSelection,
  type PluginDetailsState,
} from "./plugin-details.types";

export interface PluginDetailsService {
  load(selection: PluginDetailsSelection): Promise<PluginDetailsModel>;
  setEnabled(pluginId: string, enabled: boolean): Promise<void>;
  uninstall(pluginId: string): Promise<void>;
  rollback(pluginId: string): Promise<void>;
}

export const invokePluginDetailsService: PluginDetailsService = {
  load: ({ pluginId, source }) =>
    invoke<PluginDetailsModel>("declarative_plugins_details", { pluginId, source }),
  setEnabled: setDeclarativePluginEnabled,
  uninstall: uninstallDeclarativePlugin,
  rollback: rollbackDeclarativePlugin,
};

/**
 * Owns one mounted detail panel. Every request captures both plugin selection
 * and workspace identity. Selection changes and disposal advance the token,
 * so an old success or failure cannot write into the new/closed panel.
 */
export class PluginDetailsSession {
  #selection: PluginDetailsSelection | null = null;
  #workspacePath: string | null = null;
  #generation = 0;
  #disposed = false;

  constructor(
    private readonly service: PluginDetailsService,
    private readonly publish: (state: PluginDetailsState) => void,
    private readonly changed?: (selection: PluginDetailsSelection, workspacePath: string | null) => void,
  ) {}

  select(selection: PluginDetailsSelection | null, workspacePath: string | null): void {
    this.#selection = selection;
    this.#workspacePath = workspacePath;
    const generation = ++this.#generation;
    if (!selection) {
      this.#emit({ phase: "idle", selection: null, workspacePath });
      return;
    }
    const captured = { ...selection };
    this.#emit({ phase: "loading", selection: captured, workspacePath });
    void this.service.load(captured).then(
      (details) => {
        if (!this.#current(generation, captured, workspacePath)) return;
        this.#emit({
          phase: "ready",
          selection: captured,
          workspacePath,
          details,
          operation: null,
          error: null,
        });
      },
      (reason: unknown) => {
        if (!this.#current(generation, captured, workspacePath)) return;
        this.#emit({
          phase: "failed",
          selection: captured,
          workspacePath,
          error: errorMessage(reason),
        });
      },
    );
  }

  async perform(operation: PluginDetailsOperation, details: PluginDetailsModel): Promise<void> {
    const selection = this.#selection ? { ...this.#selection } : null;
    const workspacePath = this.#workspacePath;
    if (!selection || !samePluginSelection(selection, details.identity)) return;
    const generation = this.#generation;
    this.#emit({
      phase: "ready",
      selection,
      workspacePath,
      details,
      operation,
      error: null,
    });
    try {
      if (operation === "enable" || operation === "disable") {
        await this.service.setEnabled(selection.pluginId, operation === "enable");
      } else if (operation === "uninstall") {
        await this.service.uninstall(selection.pluginId);
      } else {
        await this.service.rollback(selection.pluginId);
      }
      if (!this.#current(generation, selection, workspacePath)) return;
      this.changed?.(selection, workspacePath);
      if (!this.#current(generation, selection, workspacePath)) return;
      if (operation === "uninstall") {
        // The removed package has no detail snapshot to reload. Leave a
        // stable empty panel while its owner refreshes the catalog.
        this.select(null, workspacePath);
        return;
      }
      // Reload from the host after mutation; never synthesize version or trust state.
      this.select(selection, workspacePath);
    } catch (reason) {
      if (!this.#current(generation, selection, workspacePath)) return;
      this.#emit({
        phase: "ready",
        selection,
        workspacePath,
        details,
        operation: null,
        error: errorMessage(reason),
      });
    }
  }

  dispose(): void {
    this.#disposed = true;
    this.#selection = null;
    this.#generation += 1;
  }

  #current(
    generation: number,
    selection: PluginDetailsSelection,
    workspacePath: string | null,
  ): boolean {
    return !this.#disposed
      && generation === this.#generation
      && samePluginSelection(this.#selection, selection)
      && this.#workspacePath === workspacePath;
  }

  #emit(state: PluginDetailsState): void {
    if (!this.#disposed) this.publish(state);
  }
}

function errorMessage(reason: unknown): string {
  if (typeof reason === "object" && reason !== null && "message" in reason) {
    return String((reason as { message: unknown }).message);
  }
  return String(reason);
}
