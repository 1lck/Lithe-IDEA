import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import * as repoApi from "../api/git-repo-api";
import * as vcsService from "@/features/vcs/vcs-root-service";
import { VcsRootController } from "@/features/vcs/vcs-root-controller";

const discoverWorkspaceRepositories = mock(async (): Promise<string[]> => ["C:/repo"]);
const realDiscoverWorkspaceRepositories = repoApi.discoverWorkspaceRepositories;
const { createGitRepositoryStore } = await import("./git-repository.store");
let discoverySpy: ReturnType<typeof spyOn<typeof repoApi, "discoverWorkspaceRepositories">>;
beforeEach(() => {
  discoverWorkspaceRepositories.mockReset().mockImplementation(async () => ["C:/repo"]);
  discoverySpy = spyOn(repoApi, "discoverWorkspaceRepositories").mockImplementation(
    discoverWorkspaceRepositories,
  );
});
afterEach(() => discoverySpy.mockRestore());

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

test("workspace source projection preserves Git repository selection and never injects plugin roots", async () => {
  const controller = new VcsRootController(
    { workspaceId: "fixture-vcs", workspaceRoot: "C:/repo", incarnation: "one" },
    {
      detect: async (scope) => ({
        generation: 1,
        workspaceId: scope.workspaceId,
        workspaceRoot: scope.workspaceRoot,
        detection: {
          providers: [
            {
              vcs: "svn",
              displayName: "Subversion",
              origin: { kind: "plugin", pluginID: "fixture.plugin" },
            },
          ],
          roots: [{ id: "legacy", vcs: "svn", path: "C:/repo/legacy", mapped: false }],
          ambiguous: [],
          unusedMappings: [],
          truncated: false,
          rejected: [],
          conflicts: [],
        },
      }),
      owners: async () => {
        throw new Error("no ownership query needed for a source list");
      },
      close: async () => {},
      deadline: () => () => {},
    },
  );
  const projection = spyOn(vcsService, "workspaceVcsRoots").mockReturnValue(controller);
  try {
    const store = createGitRepositoryStore("fixture-vcs");
    await store.getState().actions.syncWorkspaceRepositories("C:/repo");
    await controller.refresh();
    expect(store.getState().vcsRoots).toBe(controller);
    expect(controller.getSnapshot().snapshot?.detection.roots[0].vcs).toBe("svn");
    expect(store.getState().availableRepoPaths).toEqual(["C:/repo"]);
    expect(store.getState().activeRepoPath).toBe("C:/repo");
    expect(projection).toHaveBeenCalledWith("fixture-vcs");
  } finally {
    projection.mockRestore();
    await controller.close();
  }
});
