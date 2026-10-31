import type { BuildWorkspaceController } from "./build-workspace-controller";

/** One owner per open project, independent of tool-window mount/selection.
 * Failed cleanup retains its owner for an explicit retry; reopening must never
 * create a second Provider while the first one's disposal is unresolved. */
export class BuildWorkspaceOwner {
  private readonly workspaces = new Map<string, { path: string; controller: BuildWorkspaceController; closing?: Promise<void>; retired?: boolean }>();

  constructor(private readonly create: (path: string, workspaceID: string) => BuildWorkspaceController) {}

  get(workspaceID: string, path: string): BuildWorkspaceController | undefined {
    const existing = this.workspaces.get(workspaceID);
    if (existing) return existing.path === path && !existing.retired ? existing.controller : undefined;
    const controller = this.create(path, workspaceID);
    this.workspaces.set(workspaceID, { path, controller });
    return controller;
  }

  close(workspaceID: string): Promise<void> {
    const entry = this.workspaces.get(workspaceID);
    if (!entry) return Promise.resolve();
    if (entry.closing) return entry.closing;
    entry.retired = true;
    const closing = (async () => {
      try {
        await entry.controller.dispose();
        this.workspaces.delete(workspaceID);
      } finally { entry.closing = undefined; }
    })();
    entry.closing = closing;
    return closing;
  }

  async stopPlugin(pluginID: string): Promise<void> {
    const results = await Promise.allSettled([...this.workspaces.values()].map(entry => entry.controller.revokePlugin(pluginID)));
    const failures = results.filter((result): result is PromiseRejectedResult => result.status === "rejected");
    if (failures.length) throw Object.assign(new Error("Build Provider cleanup failed"), { causes: failures.map(result => result.reason) });
  }

  async refresh(): Promise<void> {
    await Promise.all([...this.workspaces.values()].filter(entry => !entry.retired).map(entry => entry.controller.refresh()));
  }

  filesChanged(path: string, rescan = false): void {
    for (const entry of this.workspaces.values()) if (!entry.retired) entry.controller.filesChanged(path, rescan);
  }
}
