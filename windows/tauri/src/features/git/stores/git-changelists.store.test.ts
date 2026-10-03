import type { StateStorage } from "zustand/middleware";
import { createChangelistStorage, changelistStorageKey } from "../api/git-changelist-storage";
import { expect, test } from "bun:test";
import { createMemoryStateStorage } from "@/utils/zustand-storage";
import {
  changelistsUnavailable,
  createGitChangelistsStore,
  workspaceChangelists,
} from "./git-changelists.store";
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
const storageFrom = (storage: StateStorage) => createChangelistStorage(() => storage);
const makeStore = () => createGitChangelistsStore(storageFrom(createMemoryStateStorage()));

test("changelists persist clean-file membership and isolate repositories, worktrees and workspaces", () => {
  const storage = storageFrom(createMemoryStateStorage());
  const store = createGitChangelistsStore(storage);
  store.getState().createList(workspace, "Local only", "local");
  store.getState().moveFiles(workspace, [file], "local");
  const reloaded = createGitChangelistsStore(storage);
  reloaded.getState().loadWorkspace(workspace);
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
  const store = createGitChangelistsStore(storageFrom(storage));
  store.getState().loadWorkspace(workspace);
  expect(store.getState().unavailable).toBe(true);
  expect(store.getState().createList(workspace, "Unsafe reset", "new")).toBe(false);
});

test("observed renames remain assigned after they disappear from Git status", () => {
  const store = makeStore();
  store.getState().createList(workspace, "Local", "local");
  store.getState().moveFiles(workspace, [file], "local");
  store.getState().rememberRenames(workspace, [
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
  const corrupt = createGitChangelistsStore(storageFrom(memory));
  corrupt.getState().loadWorkspace(workspace);
  expect(corrupt.getState().unavailable).toBe(true);
  expect(memory.getItem("git-local-changelists-v1")).toBe("{broken");
  const failed = createGitChangelistsStore(
    storageFrom({
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
  const scope = changelistCommitScope(
    workspaceChangelists(store.getState(), workspace),
    [{ id: "__proto__", root: "C:/workspace/A" }],
    [],
  );
  expect(scope.paths["__proto__"]).toEqual(["application.yaml"]);
  expect(JSON.parse(JSON.stringify(scope)).paths["__proto__"]).toEqual(["application.yaml"]);
});

test("a renamed protected source takes precedence over stale destination membership", () => {
  const store = makeStore();
  store.getState().createList(workspace, "Local", "local");
  store.getState().moveFiles(workspace, [file], "local");
  const destination = { ...file, repositoryRelativePath: "renamed.yaml" };
  store.getState().moveFiles(workspace, [destination], DEFAULT_CHANGELIST);
  const renamed = { ...destination, repositoryOriginalRelativePath: "application.yaml" };
  store.getState().rememberRenames(workspace, [renamed]);
  const state = workspaceChangelists(store.getState(), workspace);
  expect(fileChangelist(state, renamed)).toBe("local");
  expect(
    changelistCommitScope(state, [{ id: "A", root: file.repositoryPath! }], []).paths.A,
  ).toEqual(["application.yaml", "renamed.yaml"]);
});

test("unknown persisted versions and missing state remain blocked and untouched", () => {
  for (const saved of [{ version: 9, state: { workspaces: {} } }, {}, false]) {
    const memory = createMemoryStateStorage();
    const raw = JSON.stringify(saved);
    memory.setItem("git-local-changelists-v1", raw);
    const store = createGitChangelistsStore(storageFrom(memory));
    store.getState().loadWorkspace(workspace);
    expect(store.getState().unavailable).toBe(true);
    expect(store.getState().createList(workspace, "Local", "local")).toBe(false);
    expect(memory.getItem("git-local-changelists-v1")).toBe(raw);
  }
});

test("inaccessible browser storage never falls back to an empty in-memory list", () => {
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
  try {
    Object.defineProperty(globalThis, "localStorage", {
      configurable: true,
      get: () => {
        throw new Error("Access denied");
      },
    });
    const store = createGitChangelistsStore();
    store.getState().loadWorkspace(workspace);
    expect(store.getState().unavailable).toBe(true);
    expect(store.getState().createList(workspace, "Local", "local")).toBe(false);
  } finally {
    if (descriptor) Object.defineProperty(globalThis, "localStorage", descriptor);
    else Reflect.deleteProperty(globalThis, "localStorage");
  }
});

test("moving a copied file does not remove protection from its source", () => {
  const store = makeStore();
  store.getState().createList(workspace, "Local", "local");
  store.getState().moveFiles(workspace, [file], "local");
  const copy = {
    ...file,
    repositoryRelativePath: "copy.yaml",
    repositoryOriginalRelativePath: "application.yaml",
    rawStatus: "C ",
  };
  store.getState().moveFiles(workspace, [copy], DEFAULT_CHANGELIST);
  const state = workspaceChangelists(store.getState(), workspace);
  expect(fileChangelist(state, file)).toBe("local");
  expect(fileChangelist(state, copy)).toBe(DEFAULT_CHANGELIST);
});

test("a stored JSON null is corrupt metadata, not a new workspace", () => {
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
  let writes = 0;
  try {
    Object.defineProperty(globalThis, "localStorage", {
      configurable: true,
      value: {
        getItem: () => " null ",
        setItem: () => {
          writes += 1;
        },
        removeItem: () => {},
      },
    });
    const store = createGitChangelistsStore();
    store.getState().loadWorkspace(workspace);
    expect(store.getState().unavailable).toBe(true);
    expect(store.getState().createList(workspace, "Local", "local")).toBe(false);
    expect(writes).toBe(0);
  } finally {
    if (descriptor) Object.defineProperty(globalThis, "localStorage", descriptor);
    else Reflect.deleteProperty(globalThis, "localStorage");
  }
});

test("two stale windows save different workspaces without erasing either protection", () => {
  const memory = createMemoryStateStorage();
  const writes: string[] = [];
  const storage = storageFrom({
    ...memory,
    setItem: (key, value) => {
      writes.push(key);
      memory.setItem(key, value);
    },
  });
  const first = createGitChangelistsStore(storage);
  const second = createGitChangelistsStore(storage);
  const other = "C:/other";
  for (const store of [first, second]) {
    store.getState().loadWorkspace(workspace);
    store.getState().loadWorkspace(other);
  }
  first.getState().createList(workspace, "Local", "local");
  first.getState().moveFiles(workspace, [file], "local");
  const protectedRaw = memory.getItem(changelistStorageKey(workspace));
  second.getState().createList(other, "Other", "other-list");
  second.getState().activateList(other, "other-list");
  expect(memory.getItem(changelistStorageKey(workspace))).toBe(protectedRaw);
  expect(writes).toEqual([
    changelistStorageKey(workspace),
    changelistStorageKey(workspace),
    changelistStorageKey(other),
    changelistStorageKey(other),
  ]);
  const reopened = createGitChangelistsStore(storage);
  reopened.getState().loadWorkspace(workspace);
  reopened.getState().loadWorkspace(other);
  const state = workspaceChangelists(reopened.getState(), workspace);
  expect(fileChangelist(state, file)).toBe("local");
  expect(
    changelistCommitScope(state, [{ id: "A", root: file.repositoryPath! }], []).paths.A,
  ).toEqual(["application.yaml"]);
  expect(workspaceChangelists(reopened.getState(), other).activeId).toBe("other-list");
});

test("legacy migration writes only the selected workspace and preserves the original snapshot", () => {
  const seed = makeStore();
  seed.getState().createList(workspace, "Local", "local");
  seed.getState().moveFiles(workspace, [file], "local");
  const memory = createMemoryStateStorage();
  const original = JSON.stringify({
    version: 0,
    state: { workspaces: seed.getState().workspaces },
  });
  memory.setItem("git-local-changelists-v1", original);
  const storage = storageFrom(memory);
  const first = createGitChangelistsStore(storage);
  const second = createGitChangelistsStore(storage);
  first.getState().loadWorkspace(workspace);
  second.getState().loadWorkspace(workspace);
  expect(fileChangelist(workspaceChangelists(first.getState(), workspace), file)).toBe("local");
  first.getState().renameList(workspace, "local", "Private");
  second.getState().createList("C:/other", "Other", "other");
  expect(memory.getItem("git-local-changelists-v1")).toBe(original);
  const reopened = createGitChangelistsStore(storage);
  reopened.getState().loadWorkspace(workspace);
  expect(workspaceChangelists(reopened.getState(), workspace).lists[1]!.name).toBe("Private");
  memory.setItem(changelistStorageKey(workspace), "{broken");
  reopened.getState().loadWorkspace(workspace);
  expect(reopened.getState().unavailable).toBe(true);
  expect(memory.getItem(changelistStorageKey(workspace))).toBe("{broken");
});

test("workspace changes stay disabled until loaded and actions read the latest target data", () => {
  const storage = storageFrom(createMemoryStateStorage());
  const first = createGitChangelistsStore(storage);
  const second = createGitChangelistsStore(storage);
  expect(changelistsUnavailable(second.getState(), workspace)).toBe(true);
  second.getState().loadWorkspace(workspace);
  expect(changelistsUnavailable(second.getState(), workspace)).toBe(false);
  first.getState().createList(workspace, "Local", "local");
  first.getState().moveFiles(workspace, [file], "local");
  second.getState().createList(workspace, "Task", "task");
  const state = workspaceChangelists(second.getState(), workspace);
  expect(fileChangelist(state, file)).toBe("local");
  expect(state.lists.map((list) => list.id)).toEqual(["default", "local", "task"]);
  expect(changelistsUnavailable(second.getState(), "C:/unloaded")).toBe(true);
});
