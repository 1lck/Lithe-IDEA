import { afterEach, beforeEach, expect, mock, test } from "bun:test";

const tabs: { id: string; path: string; name: string }[] = [];
const workspaces = new Map<string, { status: string }>();
let active = "welcome";
let redirected = false;
const released: string[] = [];
const actions = {
  setActiveProjectTab: (id: string) => {
    active = id;
  },
  addProjectTab: (path: string, name: string) => {
    const id = createProjectTabId(path);
    if (!tabs.some((tab) => tab.id === id)) tabs.push({ id, path, name });
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
    claim: async () => redirected,
    release: async (id: string) => {
      released.push(id);
    },
  },
}));
const { createProjectTabId } = await import("@/features/window/utils/project-tab-path");
const { openWorkspaceRuntime, closeWorkspaceRuntime } = await import("./workspace-lifecycle");

beforeEach(() => {
  tabs.length = 0;
  workspaces.clear();
  active = "welcome";
  redirected = false;
  released.length = 0;
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

test("closing a project releases its ownership after disposal", async () => {
  await openWorkspaceRuntime({ descriptor, initialize: async () => true });
  const id = createProjectTabId(descriptor.path);
  let disposed = false;
  expect(
    await closeWorkspaceRuntime(id, {
      dispose: async () => {
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
