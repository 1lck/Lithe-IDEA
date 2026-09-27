export interface ProjectWindowOwner {
  label: string;
  workspaceId: string | null;
}

interface ProjectTabIdentity {
  id: string;
  path: string;
}

export const isLocalProjectPath = (path: string) => !path.includes("://");

interface ProjectWindowRouterDependencies {
  label: string;
  tabs: () => ProjectTabIdentity[];
  claim: (tab: ProjectTabIdentity, activate: boolean) => Promise<ProjectWindowOwner>;
  release: (workspaceId: string) => Promise<void>;
  listen: (activate: (workspaceId: string) => void) => Promise<() => void>;
  switchTo: (workspaceId: string) => Promise<boolean>;
  reportError: (error: unknown) => void;
}

// One router lives for the lifetime of a WebView, not for a React render.
export function createProjectWindowRouter(deps: ProjectWindowRouterDependencies) {
  let ready: Promise<void> | undefined;
  let unlisten: (() => void) | undefined;
  let disposed = false;
  let activation = Promise.resolve();

  const initialize = () => {
    ready ??= (async () => {
      const stop = await deps.listen((workspaceId) => {
        activation = activation
          .then(async () => {
            if (!disposed && deps.tabs().some((tab) => tab.id === workspaceId)) {
              if (!(await deps.switchTo(workspaceId))) {
                throw new Error("Could not activate the existing project workspace");
              }
            }
          })
          .catch(deps.reportError);
      });
      if (disposed) {
        stop();
        return;
      }
      unlisten = stop;
      // Restore ownership of inactive tabs too, before accepting new opens.
      for (const tab of deps.tabs()) {
        if (disposed) return;
        if (!isLocalProjectPath(tab.path)) continue;
        try {
          await deps.claim(tab, false);
        } catch (error) {
          // Missing persisted directories must not prevent the app from opening.
          deps.reportError(error);
        }
      }
    })().catch((error) => {
      ready = undefined;
      throw error;
    });
    return ready;
  };

  return {
    initialize,
    async claim(tab: ProjectTabIdentity) {
      if (!isLocalProjectPath(tab.path)) return false;
      await initialize();
      const owner = await deps.claim(tab, true);
      if (owner.label !== deps.label) return true;
      // Native identity can match a different spelling (case, link, separators).
      if (owner.workspaceId && owner.workspaceId !== tab.id) {
        if (!(await deps.switchTo(owner.workspaceId))) {
          throw new Error("Could not activate the existing project workspace");
        }
        return true;
      }
      return false;
    },
    async release(workspaceId: string) {
      await initialize();
      await deps.release(workspaceId);
    },
    dispose() {
      disposed = true;
      unlisten?.();
      unlisten = undefined;
    },
  };
}
