import { extensionProcessOwner } from "@/extensions/run/extension-process-owner";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import type { WorkspaceRuntimeDescriptor } from "@/features/workspace/types/workspace-runtime.types";
import { WELCOME_WORKSPACE_ID } from "@/features/workspace/types/workspace-runtime.types";
import { useWorkspaceTabsStore } from "@/features/window/stores/workspace-tabs.store";
import { removeProjectTabItems } from "@/features/window/utils/project-tab-close";
import { createProjectTabId } from "@/features/window/utils/project-tab-path";

// "attach" keeps the current projects as tabs beside the new one; "replace-active" closes
// the previously active project after the new one opens successfully.
export type ProjectOpenMode = "attach" | "replace-active";

interface OpenWorkspaceRuntimeOptions {
  descriptor: Omit<WorkspaceRuntimeDescriptor, "id"> & { path: string };
  initialize: (workspaceId: string) => Promise<boolean>;
  persistCurrent?: () => void;
  resume?: (workspaceId: string) => Promise<void>;
  mode?: ProjectOpenMode;
  /** replace-active only: dirty-buffer guard for the workspace being replaced, run after ownership checks but before any state change and again before teardown; returning false aborts that step. */
  confirmReplaceCurrent?: (workspaceId: string) => Promise<boolean>;
  /** replace-active only: service teardown for the replaced project, injected by the file-system store. */
  disposeReplaced?: (workspaceId: string, path: string) => Promise<void>;
}

interface SwitchWorkspaceRuntimeOptions {
  initialize: (workspaceId: string, path: string, name: string) => Promise<boolean>;
  persistCurrent?: () => void;
  resume?: (workspaceId: string, path: string) => Promise<void>;
  onActivate?: (workspaceId: string) => void;
}

interface PrepareWorkspaceRuntimeOptions {
  descriptor: WorkspaceRuntimeDescriptor;
  initialize: (workspaceId: string, path: string, name: string) => Promise<boolean>;
}

interface CloseWorkspaceRuntimeOptions {
  dispose?: (path: string) => Promise<void>;
  persist?: () => void;
  showWelcome?: () => Promise<void>;
  switchTo?: (workspaceId: string) => Promise<boolean>;
}

const activateDescriptor = (descriptor: WorkspaceRuntimeDescriptor) => {
  useWorkspaceTabsStore.getState().actions.setActiveProjectTab(descriptor.id);
  workspaceRuntimeRegistry.activateWorkspace(descriptor, "opening");
};

const pendingWorkspaceInitializations = new Map<string, Promise<boolean>>();

const initializeWorkspaceRuntime = (
  descriptor: WorkspaceRuntimeDescriptor,
  initialize: (workspaceId: string, path: string, name: string) => Promise<boolean>,
) => {
  const existingInitialization = pendingWorkspaceInitializations.get(descriptor.id);
  if (existingInitialization) {
    return existingInitialization;
  }

  workspaceRuntimeRegistry.ensureWorkspace(descriptor, "opening");
  const initialization = (async () => {
    try {
      const initialized = await initialize(descriptor.id, descriptor.path ?? "", descriptor.name);
      if (!initialized) {
        throw new Error(`Failed to initialize workspace "${descriptor.name}".`);
      }

      workspaceRuntimeRegistry.updateWorkspaceStatus(descriptor.id, "ready");
      return true;
    } catch (error) {
      workspaceRuntimeRegistry.updateWorkspaceStatus(
        descriptor.id,
        "error",
        error instanceof Error ? error.message : String(error),
      );
      return false;
    } finally {
      pendingWorkspaceInitializations.delete(descriptor.id);
    }
  })();

  pendingWorkspaceInitializations.set(descriptor.id, initialization);
  return initialization;
};

const resumeWorkspaceInBackground = (
  workspaceId: string,
  path: string,
  resume: SwitchWorkspaceRuntimeOptions["resume"],
) => {
  if (!resume) {
    return;
  }

  globalThis.setTimeout(() => {
    if (workspaceRuntimeRegistry.getActiveWorkspaceId() !== workspaceId) {
      return;
    }

    void resume(workspaceId, path).catch((error) => {
      console.warn(`Failed to resume workspace services for "${path}":`, error);
    });
  }, 0);
};

const restorePreviousWorkspace = (workspaceId: string | undefined) => {
  if (!workspaceId) {
    return;
  }

  const previousTab = useWorkspaceTabsStore
    .getState()
    .projectTabs.find((tab) => tab.id === workspaceId);
  if (!previousTab) {
    return;
  }

  useWorkspaceTabsStore.getState().actions.setActiveProjectTab(previousTab.id);
  workspaceRuntimeRegistry.activateWorkspace(
    { id: previousTab.id, name: previousTab.name, path: previousTab.path },
    workspaceRuntimeRegistry.getWorkspace(previousTab.id)?.status ?? "ready",
  );
};

const pendingWorkspaceOpens = new Map<string, Promise<boolean>>();

// A project being torn down stays in the tab strip until its services stop (the Java
// server can wait for its start task). Activation and close are mutually exclusive during
// that window: switching back would let the user edit buffers that are about to be removed.
const closingWorkspaces = new Map<string, Promise<boolean>>();

export const isWorkspaceClosing = (workspaceId: string) => closingWorkspaces.has(workspaceId);

export function openWorkspaceRuntime(options: OpenWorkspaceRuntimeOptions): Promise<boolean> {
  const workspaceId = createProjectTabId(options.descriptor.path);
  const closing = closingWorkspaces.get(workspaceId);
  if (closing) {
    // Reopening a project mid-teardown starts fresh once the old runtime is gone.
    return closing.catch(() => false).then(() => openWorkspaceRuntime(options));
  }
  const pending = pendingWorkspaceOpens.get(workspaceId);
  // An attach may share an in-flight open of the same path; the end state is identical.
  // A replace-active open must not adopt that promise — its guard, teardown, and failure
  // retry would all be skipped — so it waits for the pending open, then runs with its own
  // semantics (a same-path target naturally deactivates replacement).
  if (pending && options.mode !== "replace-active") {
    return pending;
  }

  const opening = (async () => {
    if (pending) {
      await pending.catch(() => false);
    }
    return await openWorkspaceRuntimeOnce(options);
  })().finally(() => {
    pendingWorkspaceOpens.delete(workspaceId);
  });
  pendingWorkspaceOpens.set(workspaceId, opening);
  return opening;
}

async function openWorkspaceRuntimeOnce({
  descriptor,
  initialize,
  persistCurrent,
  resume,
  mode = "attach",
  confirmReplaceCurrent,
  disposeReplaced,
}: OpenWorkspaceRuntimeOptions) {
  const workspaceId = createProjectTabId(descriptor.path);
  const { projectWindowRouting } =
    await import("@/features/window/services/project-window-routing");
  // A path without a tab here is a fresh claim made by this open; backing out before the
  // tab exists must hand it back, or the native registry keeps routing it to this window.
  const ownedBeforeClaim = useWorkspaceTabsStore
    .getState()
    .projectTabs.some((projectTab) => projectTab.id === workspaceId);
  if (await projectWindowRouting.claim({ id: workspaceId, path: descriptor.path })) {
    return true;
  }
  const previousWorkspaceId = workspaceRuntimeRegistry.getActiveWorkspaceId();
  const wasKnown = workspaceRuntimeRegistry.hasWorkspace(workspaceId);
  const wasReady = workspaceRuntimeRegistry.isWorkspaceReady(workspaceId);
  // Capture the replace target at entry so a tab switch during initialization cannot close
  // a different project. Reopening the already-active path deactivates replacement.
  const replacingPrevious =
    mode === "replace-active" &&
    !!previousWorkspaceId &&
    previousWorkspaceId !== workspaceId &&
    useWorkspaceTabsStore
      .getState()
      .projectTabs.some((projectTab) => projectTab.id === previousWorkspaceId);

  if (replacingPrevious && previousWorkspaceId) {
    const releaseFreshClaim = async () => {
      if (!ownedBeforeClaim) {
        await projectWindowRouting.release(workspaceId);
      }
    };
    if (!confirmReplaceCurrent) {
      // A replace without a guard would close a possibly-dirty project unseen; abort
      // loudly instead of silently degrading.
      console.warn('replace-active open is missing confirmReplaceCurrent; aborting.');
      await releaseFreshClaim();
      return false;
    }
    let confirmed: boolean;
    try {
      confirmed = await confirmReplaceCurrent(previousWorkspaceId);
    } catch (error) {
      await releaseFreshClaim();
      throw error;
    }
    if (!confirmed) {
      await releaseFreshClaim();
      return false;
    }
  }

  if (previousWorkspaceId !== workspaceId) {
    persistCurrent?.();
  }

  useWorkspaceTabsStore
    .getState()
    .actions.addProjectTab(
      descriptor.path,
      descriptor.name,
      useSettingsStore.getState().settings.theme,
    );
  activateDescriptor({ ...descriptor, id: workspaceId });

  try {
    if (wasReady) {
      await resume?.(workspaceId);
    } else {
      const initialized = await initialize(workspaceId);
      if (!initialized) {
        throw new Error(`Failed to initialize workspace "${descriptor.name}".`);
      }

      workspaceRuntimeRegistry.updateWorkspaceStatus(workspaceId, "ready");
    }
  } catch (error) {
    const shouldRestorePrevious = workspaceRuntimeRegistry.getActiveWorkspaceId() === workspaceId;
    workspaceRuntimeRegistry.updateWorkspaceStatus(
      workspaceId,
      "error",
      error instanceof Error ? error.message : String(error),
    );

    if (!wasKnown) {
      useWorkspaceTabsStore.getState().actions.removeProjectTab(workspaceId);
      workspaceRuntimeRegistry.removeWorkspace(workspaceId);
      await projectWindowRouting.release(workspaceId);
    }
    if (shouldRestorePrevious) {
      restorePreviousWorkspace(previousWorkspaceId);
    }
    return false;
  }

  // The new project is live; only now tear the replaced one down. If the user switched
  // back to the replaced project while the new one initialized, keep both tabs — their
  // switch says the old project is still wanted, and closing the now-active workspace
  // without a successor would strand the registry on a removed id. A teardown failure
  // must not roll the successful open back, so it is logged instead of thrown.
  if (replacingPrevious && previousWorkspaceId) {
    const activeAtTeardown = workspaceRuntimeRegistry.getActiveWorkspaceId();
    if (activeAtTeardown !== workspaceId) {
      console.debug(
        `Keeping workspace "${previousWorkspaceId}": the active workspace changed while "${descriptor.name}" opened.`,
      );
      return true;
    }

    try {
      // Re-run the guard against the replaced workspace: buffers may have turned dirty
      // after the first confirm. Declining keeps the old project as a background tab.
      if (confirmReplaceCurrent && !(await confirmReplaceCurrent(previousWorkspaceId))) {
        return true;
      }

      await closeWorkspaceRuntime(previousWorkspaceId, {
        dispose: (path) => disposeReplaced?.(previousWorkspaceId, path) ?? Promise.resolve(),
      });
    } catch (error) {
      console.warn(`Failed to tear down replaced workspace "${previousWorkspaceId}":`, error);
    }
  }

  return true;
}

export async function switchWorkspaceRuntime(
  workspaceId: string,
  { initialize, persistCurrent, resume, onActivate }: SwitchWorkspaceRuntimeOptions,
) {
  const tab = useWorkspaceTabsStore
    .getState()
    .projectTabs.find((projectTab) => projectTab.id === workspaceId);
  if (!tab || closingWorkspaces.has(workspaceId)) {
    return false;
  }

  if (
    workspaceRuntimeRegistry.getActiveWorkspaceId() === workspaceId &&
    workspaceRuntimeRegistry.isWorkspaceReady(workspaceId)
  ) {
    useWorkspaceTabsStore.getState().actions.setActiveProjectTab(workspaceId);
    return true;
  }

  const previousWorkspaceId = workspaceRuntimeRegistry.getActiveWorkspaceId();
  persistCurrent?.();
  activateDescriptor({ id: tab.id, name: tab.name, path: tab.path });
  onActivate?.(workspaceId);

  if (workspaceRuntimeRegistry.isWorkspaceReady(workspaceId)) {
    resumeWorkspaceInBackground(workspaceId, tab.path, resume);
    return true;
  }

  const initialized = await initializeWorkspaceRuntime(
    { id: tab.id, name: tab.name, path: tab.path },
    initialize,
  );
  if (initialized) {
    return true;
  }

  if (workspaceRuntimeRegistry.getActiveWorkspaceId() === workspaceId) {
    restorePreviousWorkspace(previousWorkspaceId);
  }
  return false;
}

export async function prepareWorkspaceRuntime({
  descriptor,
  initialize,
}: PrepareWorkspaceRuntimeOptions) {
  if (workspaceRuntimeRegistry.isWorkspaceReady(descriptor.id)) {
    return true;
  }

  return await initializeWorkspaceRuntime(descriptor, initialize);
}

export function closeWorkspaceRuntime(
  workspaceId: string,
  options: CloseWorkspaceRuntimeOptions,
): Promise<boolean> {
  const tab = useWorkspaceTabsStore
    .getState()
    .projectTabs.find((projectTab) => projectTab.id === workspaceId);
  if (!tab) {
    return Promise.resolve(false);
  }
  const closing = closingWorkspaces.get(workspaceId);
  if (closing) {
    return closing;
  }

  const closingOnce = closeWorkspaceRuntimeOnce(workspaceId, tab.path, options).finally(() => {
    closingWorkspaces.delete(workspaceId);
  });
  closingWorkspaces.set(workspaceId, closingOnce);
  return closingOnce;
}

// Activates the tab that will follow the closing one (the same pick removeProjectTab makes),
// or the welcome workspace when it is the last tab.
const activateSuccessor = async (
  workspaceId: string,
  { showWelcome, switchTo }: Pick<CloseWorkspaceRuntimeOptions, "showWelcome" | "switchTo">,
) => {
  const successor = removeProjectTabItems(
    useWorkspaceTabsStore.getState().projectTabs,
    workspaceId,
  ).find((projectTab) => projectTab.isActive);
  if (successor) {
    return (await switchTo?.(successor.id)) ?? true;
  }

  workspaceRuntimeRegistry.activateWorkspace({ id: WELCOME_WORKSPACE_ID, name: "Files" }, "empty");
  await showWelcome?.();
  return true;
};

async function closeWorkspaceRuntimeOnce(
  workspaceId: string,
  path: string,
  { dispose, persist, showWelcome, switchTo }: CloseWorkspaceRuntimeOptions,
) {
  // Leave the project before tearing it down. Teardown can wait a long time (the Java
  // server waits for its start task); with the project inactive and closing-locked nothing
  // can edit it meanwhile, so the caller's dirty guard stays the last word and no question
  // is ever asked after MCP and services are already gone.
  let switched = true;
  if (workspaceRuntimeRegistry.getActiveWorkspaceId() === workspaceId) {
    persist?.();
    switched = await activateSuccessor(workspaceId, { showWelcome, switchTo });
  }

  const { disableMcp } = await import("@/features/host-api/mcp-connection");
  await disableMcp(workspaceId);
  await extensionProcessOwner.stop(workspaceId);
  await dispose?.(path);

  // A failed successor switch rolls back onto this project; check again at removal so the
  // registry never keeps pointing at the removed workspace.
  const isActiveAtRemoval = workspaceRuntimeRegistry.getActiveWorkspaceId() === workspaceId;
  useWorkspaceTabsStore.getState().actions.removeProjectTab(workspaceId);
  workspaceRuntimeRegistry.removeWorkspace(workspaceId);
  const { projectWindowRouting } =
    await import("@/features/window/services/project-window-routing");
  await projectWindowRouting.release(workspaceId);

  if (isActiveAtRemoval) {
    return await activateSuccessor(workspaceId, { showWelcome, switchTo });
  }
  return switched;
}
