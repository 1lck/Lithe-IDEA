import { expect, test } from "bun:test";
import { createJSONStorageFrom, createMemoryStateStorage } from "@/utils/zustand-storage";
import { createGitChangelistsStore, workspaceChangelists } from "./git-changelists.store";
import {
  changelistCommitScope,
  DEFAULT_CHANGELIST,
  fileChangelist,
} from "../utils/git-changelists";
import type { GitFile } from "../types/git.types";

const workspace = "C:/workspace";
const file: GitFile = {
  path: "A/application.yaml",
  repositoryPath: "C:/workspace/A",
  repositoryRelativePath: "application.yaml",
  status: "modified",
  staged: false,
};
const makeStore = () =>
  createGitChangelistsStore(createJSONStorageFrom(createMemoryStateStorage()));

test("changelists persist clean-file membership and isolate repositories, worktrees and workspaces", () => {
  const storage = createJSONStorageFrom<{
    workspaces: Record<string, import("../utils/git-changelists").LocalChangelists>;
  }>(createMemoryStateStorage());
  const store = createGitChangelistsStore(storage);
  store.getState().createList(workspace, "Local only", "local");
  store.getState().moveFiles(workspace, [file], "local");
  const reloaded = createGitChangelistsStore(storage);
  const state = workspaceChangelists(reloaded.getState(), workspace);
  expect(fileChangelist(state, file)).toBe("local");
  expect(fileChangelist(state, { ...file, repositoryPath: "C:/workspace/B" })).toBe(
    DEFAULT_CHANGELIST,
  );
  expect(fileChangelist(state, { ...file, repositoryPath: "C:/worktrees/A" })).toBe(
    DEFAULT_CHANGELIST,
  );
  expect(fileChangelist(workspaceChangelists(reloaded.getState(), "C:/other"), file)).toBe(
    DEFAULT_CHANGELIST,
  );
  expect(file.staged).toBe(false);
});

test("names are unique, active list survives renaming, and deletion returns files to Default", () => {
  const store = makeStore();
  expect(store.getState().createList(workspace, "Local", "local")).toBe(true);
  expect(store.getState().createList(workspace, " local ", "duplicate")).toBe(false);
  expect(store.getState().createList(workspace, " ", "empty")).toBe(false);
  store.getState().moveFiles(workspace, [file], "local");
  store.getState().activateList(workspace, "local");
  expect(store.getState().renameList(workspace, "local", "Config")).toBe(true);
  expect(workspaceChangelists(store.getState(), workspace).activeId).toBe("local");
  store.getState().removeList(workspace, "local");
  const state = workspaceChangelists(store.getState(), workspace);
  expect(state.activeId).toBe(DEFAULT_CHANGELIST);
  expect(fileChangelist(state, file)).toBe(DEFAULT_CHANGELIST);
  store.getState().removeList(workspace, DEFAULT_CHANGELIST);
  expect(workspaceChangelists(store.getState(), workspace).lists).toHaveLength(1);
});

test("rename membership and commit scopes include both paths without broadening a custom list", () => {
  const store = makeStore();
  store.getState().createList(workspace, "Local", "local");
  store.getState().moveFiles(workspace, [file], "local");
  const renamed = {
    ...file,
    status: "renamed" as const,
    repositoryRelativePath: "config/application.yaml",
    repositoryOriginalRelativePath: "application.yaml",
  };
  let state = workspaceChangelists(store.getState(), workspace);
  expect(fileChangelist(state, renamed)).toBe("local");
  const roots = [{ id: "A", root: "C:/workspace/A" }];
  expect(changelistCommitScope(state, roots, [renamed])).toEqual({
    include: false,
    paths: { A: ["application.yaml", "config/application.yaml"] },
  });
  store.getState().activateList(workspace, "local");
  state = workspaceChangelists(store.getState(), workspace);
  expect(changelistCommitScope(state, roots, [renamed])).toEqual({
    include: true,
    paths: { A: ["application.yaml", "config/application.yaml"] },
  });
  store.getState().moveFiles(workspace, [renamed], DEFAULT_CHANGELIST);
  expect(fileChangelist(workspaceChangelists(store.getState(), workspace), renamed)).toBe(
    DEFAULT_CHANGELIST,
  );
});

test("invalid saved assignments fail closed instead of forgetting excluded files", () => {
  const storage = createMemoryStateStorage();
  storage.setItem(
    "git-local-changelists-v1",
    JSON.stringify({
      state: {
        workspaces: {
          [JSON.stringify(workspace)]: {
            lists: [{ id: "default", name: "" }],
            activeId: "default",
            assignments: { invalid: "missing" },
          },
        },
      },
      version: 0,
    }),
  );
  const store = createGitChangelistsStore(createJSONStorageFrom(storage));
  expect(store.getState().unavailable).toBe(true);
  expect(store.getState().createList(workspace, "Unsafe reset", "new")).toBe(false);
});

test("observed renames remain assigned after they disappear from Git status", () => {
  const store = makeStore();
  store.getState().createList(workspace, "Local", "local");
  store.getState().moveFiles(workspace, [file], "local");
  store
    .getState()
    .rememberRenames(workspace, [
      {
        ...file,
        repositoryRelativePath: "renamed.yaml",
        repositoryOriginalRelativePath: "application.yaml",
      },
    ]);
  expect(
    fileChangelist(workspaceChangelists(store.getState(), workspace), {
      ...file,
      repositoryRelativePath: "renamed.yaml",
    }),
  ).toBe("local");
});

test("unreadable JSON and storage write failures stop submissions without overwriting saved data", () => {
  const memory = createMemoryStateStorage();
  memory.setItem("git-local-changelists-v1", "{broken");
  const corrupt = createGitChangelistsStore(createJSONStorageFrom(memory));
  expect(corrupt.getState().unavailable).toBe(true);
  expect(memory.getItem("git-local-changelists-v1")).toBe("{broken");
  const failed = createGitChangelistsStore(
    createJSONStorageFrom({
      ...createMemoryStateStorage(),
      setItem: () => {
        throw new Error("storage unavailable");
      },
    }),
  );
  expect(failed.getState().createList(workspace, "Local", "local")).toBe(false);
  expect(failed.getState().unavailable).toBe(true);
});

test("the Windows selection adapter produces the shared Core scopes", async () => {
  const { default: fixture } =
    await import("../../../../../../shared/fixtures/git/local-changelist-scope-v1.json");
  const store = makeStore();
  store.getState().createList(workspace, "Local", "local");
  store.getState().moveFiles(workspace, [file], "local");
  const bindings = [{ id: "A", root: "C:/workspace/A" }];
  expect(
    changelistCommitScope(workspaceChangelists(store.getState(), workspace), bindings, []),
  ).toEqual(fixture.defaultScope);
  store.getState().activateList(workspace, "local");
  expect(
    changelistCommitScope(workspaceChangelists(store.getState(), workspace), bindings, []),
  ).toEqual(fixture.customScope);
});

test("repository names that match object properties remain literal scope identifiers", () => {
  const store = makeStore();
  store.getState().createList(workspace, "Local", "local");
  store.getState().moveFiles(workspace, [file], "local");
  const scope = changelistCommitScope(workspaceChangelists(store.getState(), workspace), [{ id: "__proto__", root: "C:/workspace/A" }], []);
  expect(scope.paths["__proto__"]).toEqual(["application.yaml"]);
  expect(JSON.parse(JSON.stringify(scope)).paths["__proto__"]).toEqual(["application.yaml"]);
});
