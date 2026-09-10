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

describe("Git refresh notifications", () => {
  const snapshot: GitStatus = {
    branch: "main", ahead: 0, behind: 0,
    files: [{ path: "draft.ts", status: "modified", staged: false }],
  };

  test("ten identical refreshes produce no store notifications", () => {
    const store = createGitStore();
    loadInitialHistory(store, "C:/repo", commits(50));
    store.getState().actions.setGitStatus(snapshot);
    const previous = store.getState();
    let notifications = 0;
    const unsubscribe = store.subscribe(() => { notifications++; });
    try {
      for (let index = 0; index < 10; index++) {
        store.getState().actions.refreshGitData({
          repoPath: "C:/repo", gitStatus: structuredClone(snapshot),
          commits: commits(50), hasMoreCommits: true, branches: [], operationState: null,
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
    store.getState().actions.setGitStatus(snapshot);
    const previous = store.getState();
    store.getState().actions.refreshGitData({
      repoPath: "C:/repo",
      gitStatus: { ...snapshot, files: [{ ...snapshot.files[0]!, staged: true }] },
      commits: commits(50), hasMoreCommits: true,
    });
    expect(store.getState().gitStatus?.files[0]?.staged).toBe(true);
    expect(store.getState().gitStatus).not.toBe(previous.gitStatus);
    expect(store.getState().commits).toBe(previous.commits);
  });

  test("pagination and operation changes are not lost when status is unchanged", () => {
    const store = createGitStore();
    loadInitialHistory(store, "C:/repo", commits(50));
    store.getState().actions.setGitStatus(snapshot);
    store.getState().actions.refreshGitData({
      repoPath: "C:/repo", gitStatus: structuredClone(snapshot),
      commits: commits(50), hasMoreCommits: false, branches: ["main"],
      operationState: { kind: "rebase", reference: "main", step: 1, total: 2, conflictedPaths: [] },
    });
    expect(store.getState().gitStatus).toBe(snapshot);
    expect(store.getState().hasMoreCommits).toBe(false);
    expect(store.getState().branches).toEqual(["main"]);
    expect(store.getState().operationState?.kind).toBe("rebase");
  });
});
