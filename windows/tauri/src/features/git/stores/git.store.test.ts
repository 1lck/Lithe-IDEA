import { beforeEach, describe, expect, mock, test } from "bun:test";
import type { GitCommit, GitHistorySnapshot } from "../types/git.types";

const getGitHistory = mock(
  async (_repoPath: string, _limit: number): Promise<GitHistorySnapshot | null> => null,
);

mock.module("../api/git-commits-api", () => ({ getGitHistory }));

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
    gitStatus: null,
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
});

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
      gitStatus: null,
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
      gitStatus: null,
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
      const historyGate = new Promise<void>((resolve) => { releaseHistory = resolve; });
      // The old status has already been read; only unrelated history is pending.
      const fullRefresh = historyGate.then(() => {
        const data = {
          repoPath: "C:/repo",
          workingTreeVersion: oldVersion,
          gitStatus: oldStatus,
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
          gitStatus: stagedStatus,
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
      actions.refreshGitData({ repoPath: "C:/repo", workingTreeVersion: older, gitStatus: firstStatus });
      expect(store.getState().gitStatus).toBe(firstStatus);
      const latestStatus = status(true);
      actions.refreshGitData({ repoPath: "C:/repo", workingTreeVersion: newer, gitStatus: latestStatus });
      expect(store.getState().gitStatus).toBe(latestStatus);
      const latestState = store.getState();
      actions.refreshGitData({ repoPath: "C:/repo", workingTreeVersion: older, gitStatus: firstStatus });
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
      gitStatus: status(true),
      operationState: oldOperation,
    });
    expect(store.getState().gitStatus).toBeNull();
    expect(store.getState().operationState).toBeNull();
  });
});
