import { afterEach, beforeEach, expect, mock, test } from "bun:test";

const tabs: { id: string; path: string; name: string; readonly isActive: boolean }[] = [];
const workspaces = new Map<string, { status: string }>();
let active = "welcome";
let redirected = false;
const released: string[] = [];
// Native registry owners claimed by this window, so tests can observe leaked claims.
const ownedByThisWindow = new Set<string>();
const revokedIdeWorkspaces: string[] = [];
mock.module("@/features/host-api/mcp-connection", () => ({
  disableMcp: async (id: string) => {
    revokedIdeWorkspaces.push(id);
  },
}));
const actions = {
  setActiveProjectTab: (id: string) => {
    active = id;
  },
  addProjectTab: (path: string, name: string) => {
    const id = createProjectTabId(path);
    if (!tabs.some((tab) => tab.id === id)) {
      tabs.push({
        id,
        path,
        name,
        get isActive() {
          return this.id === active;
        },
      });
    }
  },
  removeProjectTab: (id: string) => {
    const index = tabs.findIndex((tab) => tab.id === id);
    if (index >= 0) tabs.splice(index, 1);
  },
  getActiveProjectTab: () => tabs.find((tab) => tab.id === active),
};
mock.module("@/extensions/run/extension-process-owner", () => ({
  extensionProcessOwner: { stop: async () => {} },
}));
mock.module("@/features/settings/stores/settings.store", () => ({
  useSettingsStore: { getState: () => ({ settings: { theme: "dark" } }) },
}));
mock.module("@/features/window/stores/workspace-tabs.store", () => ({
  useWorkspaceTabsStore: { getState: () => ({ projectTabs: tabs, actions }) },
}));
mock.module("@/features/workspace/runtime/workspace-runtime-registry", () => ({
  workspaceRuntimeRegistry: {
    getActiveWorkspaceId: () => active,
    hasWorkspace: (id: string) => workspaces.has(id),
    isWorkspaceReady: (id: string) => workspaces.get(id)?.status === "ready",
    activateWorkspace: (descriptor: { id: string }, status: string) => {
      active = descriptor.id;
      workspaces.set(descriptor.id, { status });
    },
    ensureWorkspace: (descriptor: { id: string }, status: string) => {
      workspaces.set(descriptor.id, { status });
    },
    updateWorkspaceStatus: (id: string, status: string) => {
      workspaces.set(id, { status });
    },
    removeWorkspace: (id: string) => {
      workspaces.delete(id);
    },
    getWorkspace: (id: string) => workspaces.get(id),
  },
}));
mock.module("@/features/window/services/project-window-routing", () => ({
  projectWindowRouting: {
    claim: async (tab: { id: string }) => {
      if (redirected) return true;
      ownedByThisWindow.add(tab.id);
      return false;
    },
    release: async (id: string) => {
      released.push(id);
      ownedByThisWindow.delete(id);
    },
  },
}));
const { createProjectTabId } = await import("@/features/window/utils/project-tab-path");
const { openWorkspaceRuntime, closeWorkspaceRuntime, switchWorkspaceRuntime, isWorkspaceClosing } =
  await import("./workspace-lifecycle");

beforeEach(() => {
  tabs.length = 0;
  workspaces.clear();
  active = "welcome";
  redirected = false;
  released.length = 0;
  ownedByThisWindow.clear();
  revokedIdeWorkspaces.length = 0;
});
afterEach(() => {
  mock.restore();
});

const descriptor = { path: "C:/projects/example", name: "example" };

test("a project owned by another window does not mutate the current workspace", async () => {
  redirected = true;
  let initialized = false;
  let persisted = false;
  expect(
    await openWorkspaceRuntime({
      descriptor,
      initialize: async () => {
        initialized = true;
        return true;
      },
      persistCurrent: () => {
        persisted = true;
      },
    }),
  ).toBe(true);
  expect(initialized).toBe(false);
  expect(persisted).toBe(false);
  expect(tabs).toEqual([]);
  expect(active).toBe("welcome");
});

test("concurrent opens share initialization and release ownership on failure before retry", async () => {
  let complete!: (value: boolean) => void;
  const gate = new Promise<boolean>((resolve) => {
    complete = resolve;
  });
  let initializations = 0;
  const first = openWorkspaceRuntime({
    descriptor,
    initialize: () => {
      initializations++;
      return gate;
    },
  });
  try {
    const second = openWorkspaceRuntime({
      descriptor,
      initialize: async () => {
        initializations++;
        return true;
      },
    });
    expect(second).toBe(first);
    complete(false);
    expect(await first).toBe(false);
    expect(await second).toBe(false);
    expect(initializations).toBe(1);
    expect(tabs).toEqual([]);
    expect(released).toEqual([createProjectTabId(descriptor.path)]);
    expect(await openWorkspaceRuntime({ descriptor, initialize: async () => true })).toBe(true);
    expect(tabs).toHaveLength(1);
  } finally {
    complete(false);
    await first;
  }
});

test("closing a project revokes IDE access before disposal and then releases ownership", async () => {
  await openWorkspaceRuntime({ descriptor, initialize: async () => true });
  const id = createProjectTabId(descriptor.path);
  let disposed = false;
  expect(
    await closeWorkspaceRuntime(id, {
      dispose: async () => {
        expect(revokedIdeWorkspaces).toEqual([id]);
        expect(released).toEqual([]);
        disposed = true;
      },
      switchTo: async () => true,
    }),
  ).toBe(true);
  expect(disposed).toBe(true);
  expect(released).toEqual([id]);
  expect(tabs).toEqual([]);
});

test("replace-active opens the new project and tears the previously active one down", async () => {
  const oldDescriptor = { path: "C:/projects/old", name: "old" };
  await openWorkspaceRuntime({ descriptor: oldDescriptor, initialize: async () => true });
  const oldId = createProjectTabId(oldDescriptor.path);
  const bystanderDescriptor = { path: "C:/projects/bystander", name: "bystander" };
  await openWorkspaceRuntime({ descriptor: bystanderDescriptor, initialize: async () => true });
  await openWorkspaceRuntime({ descriptor: oldDescriptor, initialize: async () => true });
  const bystanderId = createProjectTabId(bystanderDescriptor.path);

  let confirmed = false;
  let disposedWorkspace = "";
  expect(
    await openWorkspaceRuntime({
      descriptor,
      mode: "replace-active",
      confirmReplaceCurrent: async () => {
        confirmed = true;
        return true;
      },
      disposeReplaced: async (workspaceId) => {
        disposedWorkspace = workspaceId;
      },
      initialize: async () => true,
    }),
  ).toBe(true);

  const newId = createProjectTabId(descriptor.path);
  expect(confirmed).toBe(true);
  expect(disposedWorkspace).toBe(oldId);
  expect(active).toBe(newId);
  expect(revokedIdeWorkspaces).toContain(oldId);
  expect(released).toContain(oldId);
  // The old tab is gone; other background tabs stay untouched.
  expect(tabs.map((tab) => tab.id).includes(oldId)).toBe(false);
  expect(tabs.map((tab) => tab.id).includes(bystanderId)).toBe(true);
});

test("replace-active aborts without any state change when the guard declines", async () => {
  const oldDescriptor = { path: "C:/projects/old", name: "old" };
  await openWorkspaceRuntime({ descriptor: oldDescriptor, initialize: async () => true });
  const oldId = createProjectTabId(oldDescriptor.path);

  let initialized = false;
  let disposed = false;
  expect(
    await openWorkspaceRuntime({
      descriptor,
      mode: "replace-active",
      confirmReplaceCurrent: async () => false,
      disposeReplaced: async () => {
        disposed = true;
      },
      initialize: async () => {
        initialized = true;
        return true;
      },
    }),
  ).toBe(false);

  expect(initialized).toBe(false);
  expect(disposed).toBe(false);
  expect(active).toBe(oldId);
  expect(tabs.map((tab) => tab.id)).toEqual([oldId]);
  // Only the claim this open just made is handed back; the replaced project keeps its owner.
  expect(released).toEqual([createProjectTabId(descriptor.path)]);
});

test("replace-active rolls the failed open back and leaves the replaced project intact", async () => {
  const oldDescriptor = { path: "C:/projects/old", name: "old" };
  await openWorkspaceRuntime({ descriptor: oldDescriptor, initialize: async () => true });
  const oldId = createProjectTabId(oldDescriptor.path);

  let disposed = false;
  expect(
    await openWorkspaceRuntime({
      descriptor,
      mode: "replace-active",
      confirmReplaceCurrent: async () => true,
      disposeReplaced: async () => {
        disposed = true;
      },
      initialize: async () => false,
    }),
  ).toBe(false);

  expect(disposed).toBe(false);
  expect(active).toBe(oldId);
  expect(tabs.map((tab) => tab.id)).toEqual([oldId]);
});

test("replace-active without a previous project tab behaves like attach", async () => {
  let disposed = false;
  expect(
    await openWorkspaceRuntime({
      descriptor,
      mode: "replace-active",
      confirmReplaceCurrent: async () => true,
      disposeReplaced: async () => {
        disposed = true;
      },
      initialize: async () => true,
    }),
  ).toBe(true);

  expect(disposed).toBe(false);
  expect(tabs.map((tab) => tab.id)).toEqual([createProjectTabId(descriptor.path)]);
});

test("replace-active reopening the active project keeps it instead of tearing it down", async () => {
  await openWorkspaceRuntime({ descriptor, initialize: async () => true });
  const id = createProjectTabId(descriptor.path);

  let disposed = false;
  expect(
    await openWorkspaceRuntime({
      descriptor,
      mode: "replace-active",
      confirmReplaceCurrent: async () => true,
      disposeReplaced: async () => {
        disposed = true;
      },
      initialize: async () => true,
    }),
  ).toBe(true);

  expect(disposed).toBe(false);
  expect(active).toBe(id);
  expect(tabs).toHaveLength(1);
});

test("replace-active keeps the replaced project when the user switches back during initialization", async () => {
  const oldDescriptor = { path: "C:/projects/old", name: "old" };
  await openWorkspaceRuntime({ descriptor: oldDescriptor, initialize: async () => true });
  const oldId = createProjectTabId(oldDescriptor.path);

  let completeInitialize!: (value: boolean) => void;
  const initialization = new Promise<boolean>((resolve) => {
    completeInitialize = resolve;
  });
  let disposed = false;
  const opening = openWorkspaceRuntime({
    descriptor,
    mode: "replace-active",
    confirmReplaceCurrent: async () => true,
    disposeReplaced: async () => {
      disposed = true;
    },
    initialize: async () => {
      // The user switches back to the old tab once the new project is initializing,
      // i.e. after the open already activated the new tab.
      active = oldId;
      return await initialization;
    },
  });

  completeInitialize(true);
  expect(await opening).toBe(true);

  expect(disposed).toBe(false);
  expect(tabs.map((tab) => tab.id)).toContain(oldId);
  expect(released).not.toContain(oldId);
});

test("replace-active re-checks the guard before teardown and keeps the project when declined", async () => {
  const oldDescriptor = { path: "C:/projects/old", name: "old" };
  await openWorkspaceRuntime({ descriptor: oldDescriptor, initialize: async () => true });
  const oldId = createProjectTabId(oldDescriptor.path);

  const confirmedWorkspaces: string[] = [];
  let disposed = false;
  expect(
    await openWorkspaceRuntime({
      descriptor,
      mode: "replace-active",
      confirmReplaceCurrent: async (workspaceId) => {
        confirmedWorkspaces.push(workspaceId);
        // Confirm at entry, decline at the teardown re-check.
        return confirmedWorkspaces.length === 1;
      },
      disposeReplaced: async () => {
        disposed = true;
      },
      initialize: async () => true,
    }),
  ).toBe(true);

  expect(confirmedWorkspaces).toEqual([oldId, oldId]);
  expect(disposed).toBe(false);
  expect(tabs.map((tab) => tab.id)).toContain(oldId);
});

test("replace-active retries with its own semantics after an in-flight attach fails", async () => {
  const oldDescriptor = { path: "C:/projects/old", name: "old" };
  await openWorkspaceRuntime({ descriptor: oldDescriptor, initialize: async () => true });
  const oldId = createProjectTabId(oldDescriptor.path);

  // Both calls in one tick: the replace must observe the attach's pending entry.
  const attach = openWorkspaceRuntime({ descriptor, initialize: async () => false });
  const confirmedWorkspaces: string[] = [];
  let disposedWorkspace = "";
  const replace = openWorkspaceRuntime({
    descriptor,
    mode: "replace-active",
    confirmReplaceCurrent: async (workspaceId) => {
      confirmedWorkspaces.push(workspaceId);
      return true;
    },
    disposeReplaced: async (workspaceId) => {
      disposedWorkspace = workspaceId;
    },
    initialize: async () => true,
  });

  expect(await attach).toBe(false);
  // The failed attach must not be reused: the replace opens, guards, and tears the old
  // project down itself instead of just returning the failure.
  expect(await replace).toBe(true);
  expect(confirmedWorkspaces).toEqual([oldId, oldId]);
  expect(disposedWorkspace).toBe(oldId);
  expect(tabs.map((tab) => tab.id)).toEqual([createProjectTabId(descriptor.path)]);
});

test("replace-active after a successful in-flight attach reactivates without teardown", async () => {
  const oldDescriptor = { path: "C:/projects/old", name: "old" };
  await openWorkspaceRuntime({ descriptor: oldDescriptor, initialize: async () => true });
  const oldId = createProjectTabId(oldDescriptor.path);
  const newId = createProjectTabId(descriptor.path);

  let completeInitialize!: (value: boolean) => void;
  const initialization = new Promise<boolean>((resolve) => {
    completeInitialize = resolve;
  });
  const attach = openWorkspaceRuntime({ descriptor, initialize: () => initialization });
  let disposed = false;
  const replace = openWorkspaceRuntime({
    descriptor,
    mode: "replace-active",
    confirmReplaceCurrent: async () => true,
    disposeReplaced: async () => {
      disposed = true;
    },
    initialize: async () => true,
  });

  completeInitialize(true);
  expect(await attach).toBe(true);
  // The attach already activated the target, so the same-path rule turns the replace into
  // a reactivation: both projects stay and nothing is torn down.
  expect(await replace).toBe(true);
  expect(disposed).toBe(false);
  expect(tabs.map((tab) => tab.id).sort()).toEqual([oldId, newId].sort());
  expect(active).toBe(newId);
});

test("replace-active cancel hands a fresh claim back so another window can open the project", async () => {
  const oldDescriptor = { path: "C:/projects/old", name: "old" };
  await openWorkspaceRuntime({ descriptor: oldDescriptor, initialize: async () => true });
  const oldId = createProjectTabId(oldDescriptor.path);
  const newId = createProjectTabId(descriptor.path);

  expect(
    await openWorkspaceRuntime({
      descriptor,
      mode: "replace-active",
      confirmReplaceCurrent: async () => false,
      initialize: async () => true,
    }),
  ).toBe(false);

  expect(ownedByThisWindow.has(newId)).toBe(false);
  expect(ownedByThisWindow.has(oldId)).toBe(true);
  expect(active).toBe(oldId);
});

test("replace-active guard failure also hands the fresh claim back", async () => {
  const oldDescriptor = { path: "C:/projects/old", name: "old" };
  await openWorkspaceRuntime({ descriptor: oldDescriptor, initialize: async () => true });
  const newId = createProjectTabId(descriptor.path);

  await expect(
    openWorkspaceRuntime({
      descriptor,
      mode: "replace-active",
      confirmReplaceCurrent: async () => {
        throw new Error("dialog failed");
      },
      initialize: async () => true,
    }),
  ).rejects.toThrow("dialog failed");

  expect(ownedByThisWindow.has(newId)).toBe(false);
});

test("replace-active cancel keeps ownership of a project that already had a tab here", async () => {
  await openWorkspaceRuntime({ descriptor, initialize: async () => true });
  const existingId = createProjectTabId(descriptor.path);
  const otherDescriptor = { path: "C:/projects/other", name: "other" };
  await openWorkspaceRuntime({ descriptor: otherDescriptor, initialize: async () => true });

  expect(
    await openWorkspaceRuntime({
      descriptor,
      mode: "replace-active",
      confirmReplaceCurrent: async () => false,
      initialize: async () => true,
    }),
  ).toBe(false);

  expect(ownedByThisWindow.has(existingId)).toBe(true);
  expect(released).not.toContain(existingId);
});

test("a replaced project cannot be reactivated while its teardown waits", async () => {
  const oldDescriptor = { path: "C:/projects/old", name: "old" };
  await openWorkspaceRuntime({ descriptor: oldDescriptor, initialize: async () => true });
  const oldId = createProjectTabId(oldDescriptor.path);
  const newId = createProjectTabId(descriptor.path);

  let releaseDispose!: () => void;
  const disposeGate = new Promise<void>((resolve) => {
    releaseDispose = resolve;
  });
  let disposeStarted!: () => void;
  const disposing = new Promise<void>((resolve) => {
    disposeStarted = resolve;
  });
  const opening = openWorkspaceRuntime({
    descriptor,
    mode: "replace-active",
    confirmReplaceCurrent: async () => true,
    disposeReplaced: async () => {
      disposeStarted();
      await disposeGate;
    },
    initialize: async () => true,
  });

  try {
    await disposing;
    expect(isWorkspaceClosing(oldId)).toBe(true);
    // The old tab is still visible, but switching back to it is refused.
    expect(tabs.map((tab) => tab.id)).toContain(oldId);
    expect(await switchWorkspaceRuntime(oldId, { initialize: async () => true })).toBe(false);
    expect(active).toBe(newId);
  } finally {
    releaseDispose();
  }

  expect(await opening).toBe(true);
  expect(isWorkspaceClosing(oldId)).toBe(false);
  expect(tabs.map((tab) => tab.id)).toEqual([newId]);
  expect(active).toBe(newId);
});

test("closing picks the successor from the active workspace at removal time", async () => {
  const otherDescriptor = { path: "C:/projects/other", name: "other" };
  await openWorkspaceRuntime({ descriptor: otherDescriptor, initialize: async () => true });
  await openWorkspaceRuntime({ descriptor, initialize: async () => true });
  const id = createProjectTabId(descriptor.path);
  const otherId = createProjectTabId(otherDescriptor.path);

  // Close the background project; the registry ends on the surviving project, never on
  // the removed id.
  active = otherId;
  const switchedTo: string[] = [];
  expect(
    await closeWorkspaceRuntime(id, {
      switchTo: async (next) => {
        switchedTo.push(next);
        return true;
      },
    }),
  ).toBe(true);
  expect(active).toBe(otherId);
  expect(switchedTo).toEqual([]);
  expect(workspaces.has(id)).toBe(false);
});

test("closing the active project leaves it before MCP and services are torn down", async () => {
  const otherDescriptor = { path: "C:/projects/other", name: "other" };
  await openWorkspaceRuntime({ descriptor: otherDescriptor, initialize: async () => true });
  await openWorkspaceRuntime({ descriptor, initialize: async () => true });
  const id = createProjectTabId(descriptor.path);
  const otherId = createProjectTabId(otherDescriptor.path);

  let releaseDispose!: () => void;
  const disposeGate = new Promise<void>((resolve) => {
    releaseDispose = resolve;
  });
  let disposeStarted!: () => void;
  const disposing = new Promise<void>((resolve) => {
    disposeStarted = resolve;
  });
  const events: string[] = [];
  const closing = closeWorkspaceRuntime(id, {
    persist: () => events.push("persist"),
    switchTo: async (next) => {
      events.push(`switch:${next}`);
      // Nothing has been revoked yet: the project is left while still fully usable.
      expect(revokedIdeWorkspaces).toEqual([]);
      active = next;
      return true;
    },
    dispose: async () => {
      events.push("dispose");
      disposeStarted();
      await disposeGate;
    },
  });

  try {
    await disposing;
    // During teardown the project is inactive and cannot be reactivated for editing.
    expect(active).toBe(otherId);
    expect(await switchWorkspaceRuntime(id, { initialize: async () => true })).toBe(false);
    expect(active).toBe(otherId);
  } finally {
    releaseDispose();
  }

  expect(await closing).toBe(true);
  expect(events).toEqual(["persist", `switch:${otherId}`, "dispose"]);
  expect(revokedIdeWorkspaces).toEqual([id]);
  expect(tabs.map((tab) => tab.id)).toEqual([otherId]);
  expect(active).toBe(otherId);
});

test("closing the last project shows the welcome workspace before teardown", async () => {
  await openWorkspaceRuntime({ descriptor, initialize: async () => true });
  const id = createProjectTabId(descriptor.path);

  const events: string[] = [];
  expect(
    await closeWorkspaceRuntime(id, {
      showWelcome: async () => {
        events.push(`welcome:${active}`);
      },
      dispose: async () => {
        events.push("dispose");
      },
    }),
  ).toBe(true);

  expect(events).toEqual([`welcome:${active}`, "dispose"]);
  expect(active).not.toBe(id);
  expect(tabs).toEqual([]);
});

test("a failed successor switch never leaves the registry on the removed project", async () => {
  const otherDescriptor = { path: "C:/projects/other", name: "other" };
  await openWorkspaceRuntime({ descriptor: otherDescriptor, initialize: async () => true });
  await openWorkspaceRuntime({ descriptor, initialize: async () => true });
  const id = createProjectTabId(descriptor.path);

  // Every switch fails and leaves the registry on the closing project; removal must still
  // move it off the removed id.
  await closeWorkspaceRuntime(id, { switchTo: async () => false });

  expect(workspaces.has(id)).toBe(false);
  expect(active).not.toBe(id);
});
