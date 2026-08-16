import { beforeEach, describe, expect, mock, test } from "bun:test";
import type { GitCommit, GitHistorySnapshot } from "../types/git.types";

const getGitHistory = mock(
  async (_repoPath: string, _limit: number): Promise<GitHistorySnapshot | null> => null,
);

mock.module("../api/git-commits-api", () => ({ getGitHistory }));

const { createGitStore } = await import("./git.store");

const commit = (index: number): GitCommit => ({
  hash: `commit-${index}`,
  message: `Commit ${index}`,
  author: "Developer",
  date: "2026/08/16 10:00",
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
    getGitHistory.mockResolvedValue({ commits: commits(100), hasMore: true });

    await store.getState().actions.loadMoreCommits("C:/repo");

    expect(getGitHistory).toHaveBeenCalledWith("C:/repo", 100);
    expect(store.getState().commits).toHaveLength(100);
    expect(store.getState().hasMoreCommits).toBe(true);
  });

  test("uses the shared core hasMore flag at the end of history", async () => {
    const store = createGitStore();
    loadInitialHistory(store, "C:/repo", commits(50));
    getGitHistory.mockResolvedValue({ commits: commits(73), hasMore: false });

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
    resolveHistory({ commits: commits(100), hasMore: true });
    await pending;

    expect(store.getState().currentRepoPath).toBe("C:/repo-b");
    expect(store.getState().commits).toEqual([]);
    expect(store.getState().isLoadingMoreCommits).toBe(false);
  });
});
