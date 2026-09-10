import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import * as repoApi from "../api/git-repo-api";

const discoverWorkspaceRepositories = mock(async (): Promise<string[]> => ["C:/repo"]);
const { createGitRepositoryStore } = await import("./git-repository.store");
let discoverySpy: ReturnType<typeof spyOn<typeof repoApi, "discoverWorkspaceRepositories">>;
beforeEach(() => {
  discoverWorkspaceRepositories.mockReset().mockImplementation(async () => ["C:/repo"]);
  discoverySpy = spyOn(repoApi, "discoverWorkspaceRepositories").mockImplementation(discoverWorkspaceRepositories);
});
afterEach(() => discoverySpy.mockRestore());

test("unchanged rescans do not notify repository-list consumers", async () => {
  const store = createGitRepositoryStore();
  await store.getState().actions.syncWorkspaceRepositories("C:/repo");
  const previous = store.getState();
  let listChanges = 0;
  const unsubscribe = store.subscribe((next, current) => {
    if (next.availableRepoPaths !== current.availableRepoPaths) listChanges++;
  });
  try {
    for (let index = 0; index < 10; index++) {
      await store.getState().actions.refreshWorkspaceRepositories();
    }
    expect(store.getState().workspaceRepoPaths).toBe(previous.workspaceRepoPaths);
    expect(store.getState().availableRepoPaths).toBe(previous.availableRepoPaths);
    expect(listChanges).toBe(0);
    expect(store.getState().isDiscovering).toBe(false);
  } finally {
    unsubscribe();
  }
});

test("discovered additions and removals still change the list and active repository", async () => {
  const store = createGitRepositoryStore();
  await store.getState().actions.syncWorkspaceRepositories("C:/repo");
  const initialPaths = store.getState().availableRepoPaths;
  discoverWorkspaceRepositories.mockResolvedValue(["C:/repo", "C:/other"]);
  await store.getState().actions.refreshWorkspaceRepositories();
  expect(store.getState().availableRepoPaths).not.toBe(initialPaths);
  expect(store.getState().activeRepoPath).toBe("C:/repo");
  discoverWorkspaceRepositories.mockResolvedValue(["C:/other"]);
  await store.getState().actions.refreshWorkspaceRepositories();
  expect(store.getState().availableRepoPaths).toEqual(["C:/other"]);
  expect(store.getState().activeRepoPath).toBe("C:/other");
});

test("rescans preserve manual repositories without recreating the merged list", async () => {
  const store = createGitRepositoryStore();
  await store.getState().actions.syncWorkspaceRepositories("C:/repo");
  store.getState().actions.setManualRepository("C:/manual");
  const previous = store.getState().availableRepoPaths;
  await store.getState().actions.refreshWorkspaceRepositories();
  expect(store.getState().availableRepoPaths).toBe(previous);
  expect(store.getState().availableRepoPaths).toEqual(["C:/repo", "C:/manual"]);
  expect(store.getState().activeRepoPath).toBe("C:/manual");
});
