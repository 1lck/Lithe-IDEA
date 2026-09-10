import { afterAll, afterEach, beforeEach, expect, mock, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import type { GitHistorySnapshot, GitStatus } from "../types/git.types";

const restoreDom = installHappyDom();
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
const previousActEnvironment = actGlobal.IS_REACT_ACT_ENVIRONMENT;
actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
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
const getWorkspaceGitStatus = mock(async (): Promise<GitStatus | null> => status);
const getGitHistory = mock(async (): Promise<GitHistorySnapshot | null> => history);
const clearRepositoryDiscoveryCache = mock(() => {});
mock.module("../api/git-repo-api", () => ({ clearRepositoryDiscoveryCache }));
const paths = ["C:/repo"];
const repository = {
  activeRepoPath: paths[0],
  availableRepoPaths: paths,
  actions: {
    syncWorkspaceRepositories: async () => {},
    refreshWorkspaceRepositories: async () => {},
  },
};
const folders: never[] = [];
mock.module("../stores/git-repository.store", () => ({
  useRepositoryStore: {
    getState: () => repository,
    use: {
      activeRepoPath: () => repository.activeRepoPath,
      availableRepoPaths: () => repository.availableRepoPaths,
      actions: () => repository.actions,
    },
  },
}));
mock.module("@/features/file-system/stores/file-system.store", () => ({
  useFileSystemStore: (selector: (state: { workspaceFolders: never[] }) => unknown) =>
    selector({ workspaceFolders: folders }),
}));
mock.module("@/features/settings/stores/settings.store", () => ({
  useSettingsStore: (
    selector: (state: { settings: { autoRefreshGitStatus: boolean } }) => unknown,
  ) => selector({ settings: { autoRefreshGitStatus: false } }),
}));
mock.module("../api/git-status-api", () => ({
  getWorkspaceGitStatus,
  getGitStatus: async () => status,
}));
mock.module("../api/git-commits-api", () => ({ getGitHistory }));
mock.module("../api/git-branches-api", () => ({ getBranches: async () => ["main"] }));
mock.module("../api/git-stash-api", () => ({ getStashes: async () => [] }));
mock.module("../api/git-integration-api", () => ({ getOperationState: async () => null }));
mock.module("../events/git-events", () => ({
  subscribeToGitChanges: () => () => {},
  isGitChangeRelevant: () => true,
  isPassiveGitChange: () => false,
}));
const { useGitDataController } = await import("./use-git-data-controller");
const { useGitStore } = await import("../stores/git.store");
let root: Root | undefined;
let container: HTMLDivElement;
let controller: ReturnType<typeof useGitDataController>;
function Probe() {
  controller = useGitDataController({ workspacePath: "C:/repo", isActive: true });
  return null;
}
async function mount() {
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  await act(async () => {
    root!.render(<Probe />);
  });
}
beforeEach(() => {
  clearRepositoryDiscoveryCache.mockClear();
  useGitStore.getState().actions.reset();
  getWorkspaceGitStatus.mockReset().mockResolvedValue(status);
  getGitHistory.mockReset().mockResolvedValue(history);
});
afterEach(async () => {
  await act(async () => {
    root?.unmount();
  });
  root = undefined;
  container?.remove();
});
afterAll(() => {
  actGlobal.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
  restoreDom();
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

test("remounting with a null history query preserves the previous snapshot", async () => {
  const snapshot = {
    ...history,
    commits: [
      {
        hash: "abc",
        shortHash: "abc",
        parentHashes: [],
        message: "Retain history",
        author: "Developer",
        date: "2026/09/10",
        decorations: "",
      },
    ],
  };
  getGitHistory.mockResolvedValue(snapshot);
  await mount();
  await act(async () => {
    root!.unmount();
  });
  root = undefined;
  container.remove();
  getGitHistory.mockResolvedValue(null);
  await mount();
  expect(useGitStore.getState().commits).toEqual(snapshot.commits);
  expect(useGitStore.getState().gitStatus).toEqual(status);
  expect(controller.hasLoadError).toBe(true);
});


test("a failed history query does not block working-tree status on initial load", async () => {
  getGitHistory.mockResolvedValue(null);
  await mount();
  expect(useGitStore.getState().gitStatus).toEqual(status);
  expect(useGitStore.getState().commits).toEqual([]);
  expect(controller.hasLoadError).toBe(true);
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
