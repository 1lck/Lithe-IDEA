import { pluginCore } from "../packages/plugin-core";
import { extensionRegistry } from "./extension-registry";

export interface PluginSessionSnapshot {
  lifecycle: { pluginId: string; state: string; generation: number; resources: string[] };
  operationId: string | null;
  installed: boolean;
}

/** The host keeps handles; Core alone accepts lifecycle changes and resource reservations. */
export class PluginLifecycleClient {
  private readonly ownerId: string;
  private readonly restored = new Map<string, Promise<PluginSessionSnapshot>>();
  private readonly recovered = new Set<string>();


  constructor(private readonly execute: (payload: Record<string, unknown>) => Promise<PluginSessionSnapshot> =
    (payload) => pluginCore.execute("plugin.session", payload)) {
    // A WebView reload can recover live native LSP sessions. Preserve the same
    // Core owner until the window closes, without persisting into a package.
    const key = "lithe:plugin-owner:v1";
    this.ownerId = typeof sessionStorage === "undefined" ? crypto.randomUUID()
      : sessionStorage.getItem(key) ?? crypto.randomUUID();
    if (typeof sessionStorage !== "undefined") sessionStorage.setItem(key, this.ownerId);
  }

  private request(pluginId: string, action: string, fields: Record<string, unknown> = {}) {
    return this.execute({ ownerId: this.ownerId, pluginId, action, ...fields });
  }

  restore(pluginId: string, installed: boolean, enabled = false): Promise<PluginSessionSnapshot> {
    const pending = this.restored.get(pluginId);
    if (pending) return pending.then(() => this.snapshot(pluginId));
    const restoring = this.request(pluginId, "restore", { installed, enabled }).then(async (snapshot) => {
      if (this.recovered.has(pluginId)) return snapshot;
      // Workers belonged to the previous document and cannot survive its reload.
      // Native runs can survive, so confirm their process-tree stop before release.
      // LSP leases are adopted by the persisted session adapter instead.
      for (const resourceId of snapshot.lifecycle.resources) {
        if (resourceId.startsWith("run:")) {
          const { stopRunProcess } = await import("@/features/run/api/run-host-api");
          await stopRunProcess(resourceId.slice(4));
        } else if (!resourceId.startsWith("worker:")) continue;
        await this.request(pluginId, "releaseResource", { resourceId });
      }
      this.recovered.add(pluginId);
      return this.snapshot(pluginId);
    });
    this.restored.set(pluginId, restoring);
    void restoring.then(() => { this.restored.delete(pluginId); }, () => { this.restored.delete(pluginId); });
    return restoring;
  }

  transition(pluginId: string, transition: string, operationId: string) {
    return this.request(pluginId, "transition", { transition, operationId });
  }

  snapshot(pluginId: string) {
    return this.request(pluginId, "snapshot");
  }

  async reserve(pluginId: string, resourceId: string, recover = false): Promise<() => Promise<void>> {
    const entry = extensionRegistry.getExtension(pluginId);
    // This is bootstrap input only. Restore never overwrites an existing Core session.
    const snapshot = await this.restore(pluginId, !!entry && entry.state !== "not-installed", !!entry && entry.state !== "not-installed" && entry.isEnabled === true);
    if (!recover || !snapshot.lifecycle.resources.includes(resourceId))
      await this.request(pluginId, "bindResource", { resourceId });
    let released = false;
    return async () => {
      if (released) return;
      await this.request(pluginId, "releaseResource", { resourceId });
      released = true;
    };
  }

  async fail(pluginId: string, operationId: string, cause: unknown): Promise<never> {
    // A concurrent disable owns the newer token and performs cleanup. Never let
    // this stale failure reopen its gate or erase its resource reservations.
    const current = await this.snapshot(pluginId);
    if (current.operationId === operationId && current.lifecycle.resources.length === 0)
      await this.transition(pluginId, "fail", operationId);
    throw cause;
  }
}

export const pluginLifecycle = new PluginLifecycleClient();
