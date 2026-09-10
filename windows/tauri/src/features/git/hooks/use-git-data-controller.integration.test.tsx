import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import { act } from "react";
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
const getWorkspaceGitStatus = mock(async (): Promise<GitStatus | null> => status);
const getGitHistory = mock(async (): Promise<GitHistorySnapshot | null> => history);
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
async function mount() {
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  await act(async () => {
    root!.render(<Probe />);
  });
}
beforeEach(() => {
  restoreDom = installHappyDom();
  previousActEnvironment = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  previousRepository = useRepositoryStore.getState();
  previousGitState = useGitStore.getState();
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
    spyOn(branchesApi, "getBranches").mockResolvedValue(["main"]),
    spyOn(stashApi, "getStashes").mockResolvedValue([]),
    spyOn(integrationApi, "getOperationState").mockResolvedValue(null),
    spyOn(events, "subscribeToGitChanges").mockReturnValue(() => {}),
  );
  useGitStore.getState().actions.reset();
  getWorkspaceGitStatus.mockReset().mockResolvedValue(status);
  getGitHistory.mockReset().mockResolvedValue(history);
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
    actGlobal.IS_REACT_ACT_ENVIRONMENT = previousActEnvironment;
    restoreDom();
  }
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


test("history errors survive working-tree refreshes until history succeeds", async () => {
  getGitHistory.mockResolvedValue(null);
  await mount();
  expect(controller.hasLoadError).toBe(true);
  const historyCalls = getGitHistory.mock.calls.length;
  await act(async () => { await controller.refreshGitData(["working-tree"]); });
  expect(getGitHistory.mock.calls.length).toBe(historyCalls);
  expect(controller.hasLoadError).toBe(true);
  getGitHistory.mockResolvedValue(history);
  await act(async () => { await controller.refreshGitData(["history"]); });
  expect(controller.hasLoadError).toBe(false);
});


test("a failed initial batch remains incomplete after only status recovers", async () => {
  getWorkspaceGitStatus.mockResolvedValue(null);
  await mount();
  getWorkspaceGitStatus.mockResolvedValue(status);
  await act(async () => { await controller.refreshGitData(["working-tree"]); });
  expect(useGitStore.getState().gitStatus).toEqual(status);
  expect(controller.hasLoadError).toBe(true);
  await act(async () => { await controller.refresh(); });
  expect(controller.hasLoadError).toBe(false);
});

test("switching repositories does not carry over a previous history failure", async () => {
  getGitHistory.mockResolvedValue(null);
  await mount();
  expect(controller.hasLoadError).toBe(true);
  getGitHistory.mockResolvedValue(history);
  await act(async () => {
    useRepositoryStore.getState().actions.setManualRepository("C:/other");
  });
  expect(controller.activeRepoPath).toBe("C:/other");
  expect(controller.hasLoadError).toBe(false);
});
