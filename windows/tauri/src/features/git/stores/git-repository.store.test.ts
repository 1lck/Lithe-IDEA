import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import * as repoApi from "../api/git-repo-api";
import { installHappyDom } from "@/test-utils/happy-dom";
import { directoryMarksStorageKey } from "@/features/file-explorer/stores/directory-marks-storage";

const discoverWorkspaceRepositories = mock(async (): Promise<string[]> => ["C:/repo"]);
const realDiscoverWorkspaceRepositories = repoApi.discoverWorkspaceRepositories;
const { createGitRepositoryStore } = await import("./git-repository.store");
let discoverySpy: ReturnType<typeof spyOn<typeof repoApi, "discoverWorkspaceRepositories">>;
let restoreDom: (() => void) | undefined;
beforeEach(() => {
  discoverWorkspaceRepositories.mockReset().mockImplementation(async () => ["C:/repo"]);
  discoverySpy = spyOn(repoApi, "discoverWorkspaceRepositories").mockImplementation(discoverWorkspaceRepositories);
});
afterEach(() => { discoverySpy.mockRestore(); restoreDom?.(); restoreDom = undefined; });

test("manual exclusions supersede an in-flight scan and remove its automatic active root", async () => {
  restoreDom = installHappyDom();
  const store = createGitRepositoryStore();
  const child = "C:/repo/child";
  discoverWorkspaceRepositories.mockResolvedValue(["C:/repo", child]);
  await store.getState().actions.syncWorkspaceRepositories("C:/repo");
  store.getState().actions.selectRepository(child);
  let release!: (roots: string[]) => void;
  const olderResult = new Promise<string[]>((resolve) => { release = resolve; });
  discoverWorkspaceRepositories.mockImplementationOnce(() => olderResult);
  const older = store.getState().actions.refreshWorkspaceRepositories();
  try {
    window.localStorage.setItem(directoryMarksStorageKey("C:/repo"), JSON.stringify({version: 1, marks: {child: "excluded"}}));
    discoverWorkspaceRepositories.mockResolvedValue(["C:/repo"]);
    await store.getState().actions.syncWorkspaceRepositories("C:/repo");
  } finally { release(["C:/repo", child]); await older; }
  expect(store.getState().availableRepoPaths).toEqual(["C:/repo"]);
  expect(store.getState().activeRepoPath).toBe("C:/repo");
});

test("discovery or preference failures retain published repository bindings", async () => {
  restoreDom = installHappyDom();
  const store = createGitRepositoryStore();
  await store.getState().actions.syncWorkspaceRepositories("C:/repo");
  const previous = store.getState().availableRepoPaths;
  discoverWorkspaceRepositories.mockRejectedValue(new Error("Git failed"));
  await store.getState().actions.refreshWorkspaceRepositories();
  expect(store.getState().availableRepoPaths).toBe(previous);
  expect(store.getState().error).toBe("Git failed");
  store.getState().actions.selectRepository("C:/repo");
  expect(store.getState().error).toBe("Git failed");
  store.getState().actions.setManualRepository("C:/manual");
  expect(store.getState().error).toBe("Git failed");
  store.getState().actions.clearManualRepository();
  expect(store.getState().error).toBe("Git failed");
  const afterSelection = store.getState().availableRepoPaths;
  window.localStorage.setItem(directoryMarksStorageKey("C:/repo"), "{");
  await store.getState().actions.refreshWorkspaceRepositories();
  expect(store.getState().availableRepoPaths).toBe(afterSelection);
  expect(store.getState().error).not.toBeNull();
  expect(store.getState().isDiscovering).toBe(false);
});

test("unsupported Windows roots report discovery errors without breaking repository state", async () => {
  discoverySpy.mockImplementation(realDiscoverWorkspaceRepositories);
  const store = createGitRepositoryStore();
  const unsupported = String.raw`\\?\C:\work\repo.`;
  await store.getState().actions.syncWorkspaceRepositories(unsupported);
  expect(store.getState().workspaceRootPath).toBe(unsupported);
  expect(store.getState().error).toContain("Git does not support Windows paths");
  expect(store.getState().isDiscovering).toBe(false);
  expect(store.getState().availableRepoPaths).toEqual([]);
});

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
