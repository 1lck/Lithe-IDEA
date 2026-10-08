import { afterEach, beforeEach, describe, expect, mock, spyOn, test } from "bun:test";
import type { GitCommit, GitHistorySnapshot, GitStatus } from "../types/git.types";
import * as historyApi from "../api/git-commits-api";

const getGitHistory = mock(
  async (_repoPath: string, _limit = 50): Promise<GitHistorySnapshot | null> => null,
);

let historySpy: ReturnType<typeof spyOn<typeof historyApi, "getGitHistory">>;

const { createGitStore } = await import("./git.store");

const commit = (index: number): GitCommit => ({
  hash: `commit-${index}`,
  shortHash: `commit-${index}`,
  parentHashes: [],
  message: `Commit ${index}`,
  author: "Developer",
  date: "2026/08/16 10:00",
  decorations: "",
});

const commits = (count: number): GitCommit[] =>
  Array.from({ length: count }, (_, index) => commit(index));

const loadInitialHistory = (
  store: ReturnType<typeof createGitStore>,
  repoPath: string,
  initialCommits: GitCommit[],
) => {
  store.getState().actions.prepareRepositoryLoad(repoPath);
  store.getState().actions.loadFreshGitData({
    repositoryStatuses: {},
    commits: initialCommits,
    hasMoreCommits: true,
    branches: [],
    stashes: [],
    operationState: null,
    repoPath,
  });
};

beforeEach(() => {
  getGitHistory.mockReset();
  historySpy = spyOn(historyApi, "getGitHistory").mockImplementation(getGitHistory);
});
afterEach(() => historySpy.mockRestore());

describe("Git history pagination", () => {
  test("requests a larger cumulative snapshot instead of an ignored offset", async () => {
    const store = createGitStore();
    loadInitialHistory(store, "C:/repo", commits(50));
    getGitHistory.mockResolvedValue({
      references: [],
      recentReferences: [],
      commits: commits(100),
      hasMore: true,
    });

    await store.getState().actions.loadMoreCommits("C:/repo");

    expect(getGitHistory).toHaveBeenCalledWith("C:/repo", 100);
    expect(store.getState().commits).toHaveLength(100);
    expect(store.getState().hasMoreCommits).toBe(true);
  });

  test("uses the shared core hasMore flag at the end of history", async () => {
    const store = createGitStore();
    loadInitialHistory(store, "C:/repo", commits(50));
    getGitHistory.mockResolvedValue({
      references: [],
      recentReferences: [],
      commits: commits(73),
      hasMore: false,
    });

    await store.getState().actions.loadMoreCommits("C:/repo");

    expect(store.getState().commits).toHaveLength(73);
    expect(store.getState().hasMoreCommits).toBe(false);
  });

  test("keeps the current snapshot when loading more fails", async () => {
    const store = createGitStore();
    loadInitialHistory(store, "C:/repo", commits(50));
    getGitHistory.mockResolvedValue(null);

    await store.getState().actions.loadMoreCommits("C:/repo");

    expect(store.getState().commits).toHaveLength(50);
    expect(store.getState().hasMoreCommits).toBe(true);
    expect(store.getState().isLoadingMoreCommits).toBe(false);
  });

  test("discards a completed request after switching repositories", async () => {
    const store = createGitStore();
    loadInitialHistory(store, "C:/repo-a", commits(50));

    let resolveHistory: (snapshot: GitHistorySnapshot) => void = () => {};
    getGitHistory.mockImplementation(
      () =>
        new Promise<GitHistorySnapshot>((resolve) => {
          resolveHistory = resolve;
        }),
    );

    const pending = store.getState().actions.loadMoreCommits("C:/repo-a");
    store.getState().actions.prepareRepositoryLoad("C:/repo-b");
    resolveHistory({
      references: [],
      recentReferences: [],
      commits: commits(100),
      hasMore: true,
    });
    await pending;

    expect(store.getState().currentRepoPath).toBe("C:/repo-b");
    expect(store.getState().commits).toEqual([]);
    expect(store.getState().isLoadingMoreCommits).toBe(false);
  });
});

describe("Git operation state refresh", () => {
  test("keeps the last operation state when a refresh omits a failed query", () => {
    const store = createGitStore();
    store.getState().actions.prepareRepositoryLoad("C:/repo");
    store.getState().actions.loadFreshGitData({
      repositoryStatuses: {},
      commits: [],
      hasMoreCommits: false,
      branches: [],
      stashes: [],
      operationState: {
        kind: "rebase",
        reference: "refs/heads/main",
        step: 2,
        total: 4,
        conflictedPaths: [],
      },
      repoPath: "C:/repo",
    });

    store.getState().actions.refreshGitData({
      repositoryStatuses: {},
      repoPath: "C:/repo",
    });

    expect(store.getState().operationState).toEqual({
      kind: "rebase",
      reference: "refs/heads/main",
      step: 2,
      total: 4,
      conflictedPaths: [],
    });
  });
});

describe("Git source control session", () => {
  test("keeps commit selections, message, and collapsed folders per repository", () => {
    const store = createGitStore();

    store.getState().actions.updateSourceControlSession("C:/repo-a", {
      commitSelectedPaths: ["src/main.ts"],
      commitMessage: "Keep this draft",
      collapsedFolders: ["tracked:src"],
    });
    store.getState().actions.updateSourceControlSession("C:/repo-b", {
      commitSelectedPaths: ["README.md"],
    });

    expect(store.getState().sourceControlSessions["C:/repo-a"]).toEqual({
      commitSelectedPaths: ["src/main.ts"],
      commitMessage: "Keep this draft",
      collapsedFolders: ["tracked:src"],
      collapsedSections: [],
    });
    expect(store.getState().sourceControlSessions["C:/repo-b"]?.commitSelectedPaths).toEqual([
      "README.md",
    ]);
  });

  test("starts with no files selected", () => {
    const store = createGitStore();

    expect(store.getState().sourceControlSessions).toEqual({});
  });
});

describe("Git working-tree publication ordering", () => {
  const status = (staged: boolean) => ({
    branch: "main",
    ahead: 0,
    behind: 0,
    files: [{ path: "changed.ts", status: "modified" as const, staged }],
  });
  const oldOperation = {
    kind: "rebase" as const,
    reference: "refs/heads/main",
    step: 1,
    total: 2,
    conflictedPaths: ["changed.ts"],
  };

  for (const source of ["initial", "refresh"] as const) {
    test(`late ${source} history preserves the newer working tree and operation state`, async () => {
      const store = createGitStore();
      const { actions } = store.getState();
      actions.prepareRepositoryLoad("C:/repo");
      const oldVersion = actions.beginWorkingTreeRefresh();
      const oldStatus = status(false);
      let releaseHistory!: () => void;
      const historyGate = new Promise<void>((resolve) => {
        releaseHistory = resolve;
      });
      // The old status has already been read; only unrelated history is pending.
      const fullRefresh = historyGate.then(() => {
        const data = {
          repoPath: "C:/repo",
          workingTreeVersion: oldVersion,
          repositoryStatuses: { "C:/repo": oldStatus },
          operationState: oldOperation,
          commits: [commit(1)],
          hasMoreCommits: false,
          branches: ["main"],
          stashes: [],
        };
        if (source === "initial") actions.loadFreshGitData(data);
        else actions.refreshGitData(data);
      });
      try {
        const stagedStatus = status(true);
        actions.refreshGitData({
          repoPath: "C:/repo",
          workingTreeVersion: actions.beginWorkingTreeRefresh(),
          repositoryStatuses: { "C:/repo": stagedStatus },
          operationState: null,
        });
        expect(store.getState().gitStatus).toBe(stagedStatus);
        releaseHistory();
        await fullRefresh;
        // Preserve identity too: late history must not rebuild the status list.
        expect(store.getState().gitStatus).toBe(stagedStatus);
        expect(store.getState().operationState).toBeNull();
        expect(store.getState().commits).toEqual([commit(1)]);
        expect(store.getState().branches).toEqual(["main"]);
      } finally {
        releaseHistory();
        await fullRefresh;
      }
    }, 1000);
  }

  test("starting a newer read neither notifies subscribers nor blocks an available snapshot", () => {
    const store = createGitStore();
    const { actions } = store.getState();
    actions.prepareRepositoryLoad("C:/repo");
    const onChange = mock(() => {});
    const unsubscribe = store.subscribe(onChange);
    try {
      const older = actions.beginWorkingTreeRefresh();
      const newer = actions.beginWorkingTreeRefresh();
      expect(onChange).not.toHaveBeenCalled();
      const firstStatus = status(false);
      actions.refreshGitData({
        repoPath: "C:/repo",
        workingTreeVersion: older,
        repositoryStatuses: { "C:/repo": firstStatus },
      });
      expect(store.getState().gitStatus).toBe(firstStatus);
      const latestStatus = status(true);
      actions.refreshGitData({
        repoPath: "C:/repo",
        workingTreeVersion: newer,
        repositoryStatuses: { "C:/repo": latestStatus },
      });
      expect(store.getState().gitStatus).toBe(latestStatus);
      const latestState = store.getState();
      actions.refreshGitData({
        repoPath: "C:/repo",
        workingTreeVersion: older,
        repositoryStatuses: { "C:/repo": firstStatus },
      });
      expect(store.getState()).toBe(latestState);
    } finally {
      unsubscribe();
    }
  });

  test("a previous repository session cannot publish after switching away and back", () => {
    const store = createGitStore();
    const { actions } = store.getState();
    actions.prepareRepositoryLoad("C:/repo");
    const previousSession = actions.beginWorkingTreeRefresh();
    actions.prepareRepositoryLoad("C:/other");
    actions.prepareRepositoryLoad("C:/repo");
    actions.refreshGitData({
      repoPath: "C:/repo",
      workingTreeVersion: previousSession,
      repositoryStatuses: { "C:/repo": status(true) },
      operationState: oldOperation,
    });
    expect(store.getState().gitStatus).toBeNull();
    expect(store.getState().operationState).toBeNull();
  });

  for (const [name, before, after] of [
    ["resolved conflict clears the banner", oldOperation, null],
    ["new conflict reaches the banner", null, oldOperation],
  ] as const) {
    test(`a newer status-only publication does not reject an older full read's operation state: ${name}`, () => {
      const store = createGitStore();
      const { actions } = store.getState();
      actions.prepareRepositoryLoad("C:/repo");
      actions.refreshGitData({
        repoPath: "C:/repo",
        workingTreeVersion: actions.beginWorkingTreeRefresh(),
        repositoryStatuses: { "C:/repo": status(false) },
        operationState: before,
      });
      // Event order: the Commit controller starts a full read, then the global host
      // starts and publishes a status-only read before the operation state returns.
      const fullRead = actions.beginWorkingTreeRefresh();
      const hostStatus = status(true);
      actions.publishRepositoryStatuses({ "C:/repo": hostStatus }, actions.beginWorkingTreeRefresh());
      expect(store.getState().gitStatus).toBe(hostStatus);

      actions.refreshGitData({
        repoPath: "C:/repo",
        workingTreeVersion: fullRead,
        repositoryStatuses: { "C:/repo": status(false) },
        operationState: after,
      });

      expect(store.getState().operationState).toEqual(after);
      // The older file snapshot is still rejected: it must not roll the list back.
      expect(store.getState().gitStatus).toBe(hostStatus);
    });
  }

  test("an older operation state is still rejected after a newer one was published", () => {
    const store = createGitStore();
    const { actions } = store.getState();
    actions.prepareRepositoryLoad("C:/repo");
    const olderRead = actions.beginWorkingTreeRefresh();
    actions.refreshGitData({
      repoPath: "C:/repo",
      workingTreeVersion: actions.beginWorkingTreeRefresh(),
      repositoryStatuses: { "C:/repo": status(true) },
      operationState: null,
    });
    actions.refreshGitData({
      repoPath: "C:/repo",
      workingTreeVersion: olderRead,
      repositoryStatuses: { "C:/repo": status(false) },
      operationState: oldOperation,
    });
    expect(store.getState().operationState).toBeNull();
  });
});

describe("Git refresh notifications", () => {
  const snapshot: GitStatus = {
    branch: "main",
    ahead: 0,
    behind: 0,
    files: [{ path: "draft.ts", status: "modified", staged: false }],
  };

  test("ten identical refreshes produce no store notifications", () => {
    const store = createGitStore();
    loadInitialHistory(store, "C:/repo", commits(50));
    store.getState().actions.publishRepositoryStatuses({ "C:/repo": snapshot });
    const previous = store.getState();
    let notifications = 0;
    const unsubscribe = store.subscribe(() => {
      notifications++;
    });
    try {
      for (let index = 0; index < 10; index++) {
        store.getState().actions.refreshGitData({
          repoPath: "C:/repo",
          repositoryStatuses: { "C:/repo": structuredClone(snapshot) },
          commits: commits(50),
          hasMoreCommits: true,
          branches: [],
          operationState: null,
        });
        store.getState().actions.setStashes([]);
      }
      expect(notifications).toBe(0);
      expect(store.getState()).toBe(previous);
    } finally {
      unsubscribe();
    }
  });

  test("a staging change updates status while retaining unchanged history", () => {
    const store = createGitStore();
    loadInitialHistory(store, "C:/repo", commits(50));
    store.getState().actions.publishRepositoryStatuses({ "C:/repo": snapshot });
    const previous = store.getState();
    store.getState().actions.refreshGitData({
      repoPath: "C:/repo",
      repositoryStatuses: {
        "C:/repo": { ...snapshot, files: [{ ...snapshot.files[0]!, staged: true }] },
      },
      commits: commits(50),
      hasMoreCommits: true,
    });
    expect(store.getState().gitStatus?.files[0]?.staged).toBe(true);
    expect(store.getState().gitStatus).not.toBe(previous.gitStatus);
    expect(store.getState().commits).toBe(previous.commits);
  });

  test("pagination and operation changes are not lost when status is unchanged", () => {
    const store = createGitStore();
    loadInitialHistory(store, "C:/repo", commits(50));
    store.getState().actions.publishRepositoryStatuses({ "C:/repo": snapshot });
    store.getState().actions.refreshGitData({
      repoPath: "C:/repo",
      repositoryStatuses: { "C:/repo": structuredClone(snapshot) },
      commits: commits(50),
      hasMoreCommits: false,
      branches: ["main"],
      operationState: { kind: "rebase", reference: "main", step: 1, total: 2, conflictedPaths: [] },
    });
    expect(store.getState().gitStatus).toBe(snapshot);
    expect(store.getState().hasMoreCommits).toBe(false);
    expect(store.getState().branches).toEqual(["main"]);
    expect(store.getState().operationState?.kind).toBe("rebase");
  });
});

describe("Unified repository status", () => {
  const repo = "C:/workspace";
  const child = "C:/workspace/service";
  const status = (branch: string, behind: number): GitStatus => ({
    branch,
    ahead: 0,
    behind,
    files: [{ path: "src/main.ts", status: "modified", staged: false }],
  });

  test("external checkout updates toolbar, closed Commit snapshot and file tree atomically", () => {
    const store = createGitStore();
    const { actions } = store.getState();
    actions.setWorkspaceRepository(repo);
    actions.prepareRepositoryLoad(repo);
    actions.publishRepositoryStatuses({ [repo]: status("old", 3) });
    actions.updateSourceControlSession(repo, { commitMessage: "Keep my draft" });
    const observations: number[] = [];
    const unsubscribe = store.subscribe((state) => {
      const toolbar = state.repositoryStatuses[repo];
      expect(state.gitStatus).toBe(toolbar);
      expect(state.workspaceGitStatus).toBe(toolbar);
      observations.push(toolbar!.behind);
    });
    try {
      actions.publishRepositoryStatuses({ [repo]: status("latest", 0) });
      expect(observations).toEqual([0]);
      expect(store.getState().gitStatus?.branch).toBe("latest");
      expect(store.getState().sourceControlSessions[repo]?.commitMessage).toBe("Keep my draft");
    } finally {
      unsubscribe();
    }
  });

  test("late bootstrap and Commit reads cannot restore old tracking counts or files", () => {
    const store = createGitStore();
    const { actions } = store.getState();
    actions.setWorkspaceRepository(repo);
    actions.prepareRepositoryLoad(repo);
    const bootstrap = actions.beginWorkingTreeRefresh();
    const commitRead = actions.beginWorkingTreeRefresh();
    const current = status("latest", 0);
    current.files = [];
    actions.publishRepositoryStatuses({ [repo]: current }, actions.beginWorkingTreeRefresh());
    actions.publishRepositoryStatuses({ [repo]: status("old", 3) }, bootstrap);
    actions.refreshGitData({
      repoPath: repo,
      repositoryStatuses: { [repo]: status("old", 3) },
      workingTreeVersion: commitRead,
    });
    expect(store.getState().repositoryStatuses[repo]).toBe(current);
    expect(store.getState().gitStatus).toBe(current);
    expect(store.getState().workspaceGitStatus).toBe(current);
  });

  test("multi-repository Commit projection keeps file identity and root decorations separate", () => {
    const store = createGitStore();
    const { actions } = store.getState();
    actions.setWorkspaceRepository(repo);
    actions.prepareRepositoryLoad(child);
    const parentStatus = status("parent", 2);
    const childStatus = status("child", 0);
    actions.publishRepositoryStatuses({ [repo]: parentStatus, [child]: childStatus }, undefined, [
      repo,
      child,
    ]);
    expect(store.getState().gitStatus?.branch).toBe("child");
    expect(store.getState().gitStatus?.behind).toBe(0);
    expect(
      store
        .getState()
        .gitStatus?.files.map((file) => [
          file.path,
          file.repositoryPath,
          file.repositoryRelativePath,
        ]),
    ).toEqual([
      ["workspace/src/main.ts", repo, "src/main.ts"],
      ["service/src/main.ts", child, "src/main.ts"],
    ]);
    expect(store.getState().workspaceGitStatus).toBe(parentStatus);
    actions.publishRepositoryStatuses({ [child]: status("next-child", 4) });
    expect(store.getState().gitStatus?.behind).toBe(4);
    expect(store.getState().workspaceGitStatus).toBe(parentStatus);
  });

  test("clearing the workspace discards pending global status publication", () => {
    const store = createGitStore();
    const { actions } = store.getState();
    actions.setWorkspaceRepository(repo);
    const pending = actions.beginWorkingTreeRefresh();
    actions.setWorkspaceRepository(null);
    actions.publishRepositoryStatuses({ [repo]: status("old", 3) }, pending);
    expect(store.getState().repositoryStatuses).toEqual({});
    expect(store.getState().gitStatus).toBeNull();
    expect(store.getState().workspaceGitStatus).toBeNull();
  });
});
