import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import type { GitHistorySnapshot, GitStatus } from "../types/git.types";
import * as repoApi from "../api/git-repo-api";
import * as statusApi from "../api/git-status-api";
import * as historyApi from "../api/git-commits-api";
import * as branchesApi from "../api/git-branches-api";
import * as stashApi from "../api/git-stash-api";
import * as integrationApi from "../api/git-integration-api";
import * as events from "../events/git-events";
import * as fileSystem from "@/features/file-system/stores/file-system.store";
import * as settings from "@/features/settings/stores/settings.store";
import { useRepositoryStore } from "../stores/git-repository.store";
import { workspaceRuntimeRegistry } from "@/features/workspace/runtime/workspace-runtime-registry";
import { WorkspaceStoreScopeContext } from "@/features/workspace/stores/create-workspace-scoped-store";

let restoreDom: () => void;
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousActEnvironment: boolean | undefined;
const status: GitStatus = {
  branch: "main",
  ahead: 0,
  behind: 0,
  files: [{ path: "draft.ts", status: "modified", staged: false }],
};
const history: GitHistorySnapshot = {
  commits: [],
  references: [],
  recentReferences: [],
  hasMore: false,
};
type Deferred<Value> = {
  promise: Promise<Value>;
  resolve: (value: Value) => void;
};

function deferred<Value>(): Deferred<Value> {
  let resolve!: (value: Value) => void;
  const promise = new Promise<Value>((resolver) => {
    resolve = resolver;
  });
  return { promise, resolve };
}

const getWorkspaceGitStatus = mock(async (): Promise<GitStatus | null> => status);
const getGitHistory = mock(async (): Promise<GitHistorySnapshot | null> => history);
const getBranches = mock(async (): Promise<string[]> => ["main"]);
const clearRepositoryDiscoveryCache = mock(() => {});
const repositoryActions = {
  syncWorkspaceRepositories: async () => {},
  refreshWorkspaceRepositories: async () => {},
};
const folders: never[] = [];
const spies: Array<{ mockRestore: () => void }> = [];
const { useGitDataController } = await import("./use-git-data-controller");
const { useGitStore } = await import("../stores/git.store");
let previousRepository: ReturnType<typeof useRepositoryStore.getState>;
let previousGitState: ReturnType<typeof useGitStore.getState>;
let root: Root | undefined;
let container: HTMLDivElement;
let controller: ReturnType<typeof useGitDataController>;
function Probe() {
  controller = useGitDataController({ workspacePath: "C:/repo", isActive: true });
  return null;
}
function ScopedProbe({ workspaceId }: { workspaceId: string }) {
  return (
    <WorkspaceStoreScopeContext.Provider value={workspaceId}>
      <Probe />
    </WorkspaceStoreScopeContext.Provider>
  );
}
async function mount(element: ReactNode = <Probe />) {
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  await act(async () => {
    root!.render(element);
  });
}
beforeEach(() => {
  restoreDom = installHappyDom();
  previousActEnvironment = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  previousRepository = useRepositoryStore.getState();
  previousGitState = useGitStore.getState();
  workspaceRuntimeRegistry.resetForTests();
  workspaceRuntimeRegistry.updateWorkspaceStatus("workspace:welcome", "ready");
  clearRepositoryDiscoveryCache.mockClear();
  useRepositoryStore.getState().actions.reset();
  useRepositoryStore.getState().actions.setManualRepository("C:/repo");
  spies.push(
    spyOn(useRepositoryStore.use, "actions").mockReturnValue({
      ...useRepositoryStore.getState().actions, ...repositoryActions,
    }),
    spyOn(fileSystem, "useFileSystemStore").mockImplementation(
      ((selector: (state: { workspaceFolders: never[] }) => unknown) =>
        selector({ workspaceFolders: folders })) as typeof fileSystem.useFileSystemStore,
    ),
    spyOn(settings, "useSettingsStore").mockImplementation(
      ((selector: (state: { settings: { autoRefreshGitStatus: boolean } }) => unknown) =>
        selector({ settings: { autoRefreshGitStatus: false } })) as typeof settings.useSettingsStore,
    ),
    spyOn(repoApi, "clearRepositoryDiscoveryCache").mockImplementation(clearRepositoryDiscoveryCache),
    spyOn(statusApi, "getWorkspaceGitStatus").mockImplementation(getWorkspaceGitStatus),
    spyOn(historyApi, "getGitHistory").mockImplementation(getGitHistory),
    spyOn(branchesApi, "getBranches").mockImplementation(getBranches),
    spyOn(stashApi, "getStashes").mockResolvedValue([]),
    spyOn(integrationApi, "getOperationState").mockResolvedValue(null),
    spyOn(events, "subscribeToGitChanges").mockReturnValue(() => {}),
  );
  useGitStore.getState().actions.reset();
  getWorkspaceGitStatus.mockReset().mockResolvedValue(status);
  getGitHistory.mockReset().mockResolvedValue(history);
  getBranches.mockReset().mockResolvedValue(["main"]);
});
afterEach(async () => {
  try {
    await act(async () => { root?.unmount(); });
  } finally {
    root = undefined;
    container?.remove();
    for (const spy of spies.splice(0).reverse()) spy.mockRestore();
    useRepositoryStore.setState(previousRepository, true);
    useGitStore.setState(previousGitState, true);
    workspaceRuntimeRegistry.resetForTests();
    actGlobal.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
    restoreDom();
  }
});

test("starts Git loading when the workspace becomes ready", async () => {
  workspaceRuntimeRegistry.updateWorkspaceStatus("workspace:welcome", "opening");
  await mount();
  expect(getWorkspaceGitStatus).not.toHaveBeenCalled();

  await act(async () => {
    workspaceRuntimeRegistry.updateWorkspaceStatus("workspace:welcome", "ready");
    await Promise.resolve();
  });

  expect(getWorkspaceGitStatus).toHaveBeenCalledTimes(1);
});

test("loads initial status before starting optional Git metadata", async () => {
  const pendingStatus = deferred<GitStatus | null>();
  getWorkspaceGitStatus.mockImplementationOnce(() => pendingStatus.promise);
  await mount();

  expect(getBranches).not.toHaveBeenCalled();

  await act(async () => {
    pendingStatus.resolve(status);
    await pendingStatus.promise;
  });

  expect(useGitStore.getState().gitStatus).toEqual(status);
  expect(getBranches).toHaveBeenCalledTimes(1);
});

test("publishes initial status while optional Git metadata is still loading", async () => {
  const pendingBranches = deferred<string[]>();
  getBranches.mockImplementationOnce(() => pendingBranches.promise);
  await mount();

  expect(useGitStore.getState().gitStatus).toEqual(status);
  expect(useGitStore.getState().isLoadingGitData).toBe(true);
  expect(controller.hasLoadError).toBe(false);

  await act(async () => {
    pendingBranches.resolve(["main"]);
    await pendingBranches.promise;
  });

  expect(useGitStore.getState().isLoadingGitData).toBe(false);
});

test("does not refresh Git while the workspace is opening", async () => {
  workspaceRuntimeRegistry.updateWorkspaceStatus("workspace:welcome", "opening");
  await mount();

  await act(async () => {
    await controller.refreshGitData();
  });

  expect(getWorkspaceGitStatus).not.toHaveBeenCalled();
});

test("does not start a queued refresh after the workspace stops being ready", async () => {
  await mount();
  getWorkspaceGitStatus.mockClear();
  const refresh = controller.refreshGitData();

  await act(async () => {
    workspaceRuntimeRegistry.updateWorkspaceStatus("workspace:welcome", "opening");
    await refresh;
  });

  expect(getWorkspaceGitStatus).not.toHaveBeenCalled();
});

test("loads Git for a scoped workspace when that workspace becomes ready", async () => {
  const workspaceId = "workspace:scoped-git-test";
  workspaceRuntimeRegistry.ensureWorkspace(
    { id: workspaceId, name: "Scoped Git test" },
    "opening",
  );
  useRepositoryStore.getStore(workspaceId).getState().actions.setManualRepository("C:/repo");
  await mount(<ScopedProbe workspaceId={workspaceId} />);
  expect(getWorkspaceGitStatus).not.toHaveBeenCalled();

  await act(async () => {
    workspaceRuntimeRegistry.updateWorkspaceStatus(workspaceId, "ready");
    await Promise.resolve();
  });

  expect(getWorkspaceGitStatus).toHaveBeenCalledTimes(1);
});

test("keeps files and the commit draft after a failed refresh, then recovers", async () => {
  await mount();
  useGitStore
    .getState()
    .actions.updateSourceControlSession("C:/repo", { commitMessage: "My draft" });
  getWorkspaceGitStatus.mockResolvedValue(null);
  await act(async () => {
    await controller.refresh();
  });
  expect(useGitStore.getState().gitStatus).toEqual(status);
  expect(useGitStore.getState().sourceControlSessions["C:/repo"]?.commitMessage).toBe("My draft");
  expect(controller.hasLoadError).toBe(true);
  expect(useGitStore.getState().isRefreshing).toBe(false);
  getWorkspaceGitStatus.mockResolvedValue({ ...status, files: [] });
  await act(async () => {
    await controller.refresh();
  });
  expect(useGitStore.getState().gitStatus?.files).toEqual([]);
  expect(controller.hasLoadError).toBe(false);
});

test("initial query failure can recover without reopening the project", async () => {
  getWorkspaceGitStatus.mockRejectedValue(new Error("No status snapshot"));
  await mount();
  expect(controller.hasLoadError).toBe(true);
  expect(useGitStore.getState().gitStatus).toBeNull();
  expect(useGitStore.getState().isLoadingGitData).toBe(false);
  getWorkspaceGitStatus.mockResolvedValue(status);
  await act(async () => {
    await controller.refresh();
  });
  expect(useGitStore.getState().gitStatus).toEqual(status);
  expect(controller.hasLoadError).toBe(false);
});

// The Commit panel no longer lists history, so loading and refreshing the
// working tree must not spend a `git log --all` read on it.
test("does not read commit history for the Commit panel", async () => {
  await mount();
  await act(async () => { await controller.refresh(); });
  await act(async () => { await controller.refreshGitData(["history"]); });
  expect(useGitStore.getState().gitStatus).toEqual(status);
  expect(getGitHistory).not.toHaveBeenCalled();
});

test("successful refreshes retain discovery caches; error retries clear them", async () => {
  await mount();
  await act(async () => { await controller.refresh(); });
  expect(clearRepositoryDiscoveryCache).not.toHaveBeenCalled();
  getWorkspaceGitStatus.mockResolvedValue(null);
  await act(async () => { await controller.refresh(); });
  expect(clearRepositoryDiscoveryCache).not.toHaveBeenCalled();
  getWorkspaceGitStatus.mockResolvedValue(status);
  await act(async () => { await controller.refresh(); });
  expect(clearRepositoryDiscoveryCache).toHaveBeenCalledTimes(1);
  expect(controller.hasLoadError).toBe(false);
});


test("a failed initial status can recover without waiting for optional metadata", async () => {
  getWorkspaceGitStatus.mockRejectedValueOnce(new Error("Operation timed out"));
  await mount();
  expect(getBranches).not.toHaveBeenCalled();
  await act(async () => { await controller.refreshGitData(["working-tree"]); });
  expect(useGitStore.getState().gitStatus).toEqual(status);
  expect(controller.hasLoadError).toBe(false);
  expect(getBranches).not.toHaveBeenCalled();

  await act(async () => { await controller.refresh(); });
  expect(getBranches).toHaveBeenCalledTimes(1);
});
