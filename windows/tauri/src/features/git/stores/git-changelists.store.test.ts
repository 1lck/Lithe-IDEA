import { expect, mock, test } from "bun:test";
import { createMemoryStateStorage } from "@/utils/zustand-storage";
import { createChangelistStorage, changelistStorageKey } from "../api/git-changelist-storage";
import {
  createGitChangelistsStore,
  changelistsUnavailable,
  workspaceChangelists,
} from "./git-changelists.store";
import type { projectChangelists } from "../api/git-changelist-core";
import { EMPTY_CHANGELISTS, type LocalChangelists } from "../utils/git-changelists";

const workspace = "C:/workspace";
const scope = { include: false, paths: {} };
const immediateLock = async <T>(_workspace: string, task: () => Promise<T>): Promise<T> => task();
const clone = (state: LocalChangelists): LocalChangelists => structuredClone(state);

test("storage load is protected until Core validates it; failures do not overwrite saved data", async () => {
  const memory = createMemoryStateStorage();
  const storage = createChangelistStorage(() => memory);
  const saved = {
    lists: [
      { id: "default", name: "" },
      { id: "local", name: "Local" },
    ],
    activeId: "local",
    assignments: {},
  };
  storage.save(workspace, saved);
  let release!: () => void;
  const pending = new Promise<void>((resolve) => {
    release = resolve;
  });
  const reduce = mock(async (state: LocalChangelists) => {
    await pending;
    return { state, members: [], scope };
  }) as unknown as typeof projectChangelists;
  const store = createGitChangelistsStore(storage, reduce, immediateLock);
  const load = store.getState().loadWorkspace(workspace);
  try {
    expect(changelistsUnavailable(store.getState(), workspace)).toBe(true);
    release();
    expect(await load).toBe(true);
    expect(changelistsUnavailable(store.getState(), workspace)).toBe(false);
    expect(workspaceChangelists(store.getState(), workspace)).toEqual(saved);
  } finally {
    release();
    await load;
  }
}, 1000);

test("two windows serialize read-reduce-save and keep both changes", async () => {
  const memory = createMemoryStateStorage();
  const storage = createChangelistStorage(() => memory);
  let held!: () => void;
  let started!: () => void;
  const gate = new Promise<void>((resolve) => {
    held = resolve;
  });
  const entered = new Promise<void>((resolve) => {
    started = resolve;
  });
  const actions: string[] = [];
  let tail: Promise<unknown> = Promise.resolve();
  const lock = <T>(_key: string, run: () => Promise<T>): Promise<T> => {
    const next = tail.then(run, run);
    tail = next;
    return next;
  };
  const reduce = mock(
    async (
      state: LocalChangelists,
      _files: unknown,
      _repos: unknown,
      _fallback: unknown,
      action?: { type: string; id: string; name: string },
    ) => {
      if (!action) return { state, members: [], scope };
      actions.push(action.id);
      if (action.id === "first") {
        started();
        await gate;
      }
      const next = clone(state);
      next.lists.push({ id: action.id, name: action.name });
      return { state: next, members: [], scope };
    },
  ) as unknown as typeof projectChangelists;
  const first = createGitChangelistsStore(storage, reduce, lock);
  const second = createGitChangelistsStore(storage, reduce, lock);
  const one = first.getState().createList(workspace, "First", "first");
  let two: Promise<boolean> | undefined;
  try {
    await entered;
    two = second.getState().createList(workspace, "Second", "second");
    await Promise.resolve();
    expect(actions).toEqual(["first"]);
    expect(changelistsUnavailable(second.getState(), workspace)).toBe(true);
    held();
    expect(await one).toBe(true);
    expect(await two).toBe(true);
    expect(storage.load(workspace)?.lists.map((list) => list.id)).toEqual([
      "default",
      "first",
      "second",
    ]);
  } finally {
    held();
    await Promise.allSettled([one, ...(two ? [two] : [])]);
  }
}, 1000);

test("Core or locking failure blocks edits while preserving stored metadata", async () => {
  const memory = createMemoryStateStorage();
  const storage = createChangelistStorage(() => memory);
  storage.save(workspace, EMPTY_CHANGELISTS);
  const original = memory.getItem(changelistStorageKey(workspace));
  const reduce = mock(async () => {
    throw new Error("Core unavailable");
  }) as unknown as typeof projectChangelists;
  const store = createGitChangelistsStore(storage, reduce, immediateLock);
  expect(await store.getState().createList(workspace, "Local", "local")).toBe(false);
  expect(changelistsUnavailable(store.getState(), workspace)).toBe(true);
  expect(memory.getItem(changelistStorageKey(workspace))).toBe(original);
  const failedLock = createGitChangelistsStore(storage, reduce, async () => {
    throw new Error("lock unavailable");
  });
  expect(await failedLock.getState().loadWorkspace(workspace)).toBe(false);
  expect(failedLock.getState().unavailable).toBe(true);
}, 1000);

test("invalid list action does not corrupt or disable a valid workspace", async () => {
  const memory = createMemoryStateStorage();
  const storage = createChangelistStorage(() => memory);
  const reduce = mock(
    async (
      state: LocalChangelists,
      _files: unknown,
      _repos: unknown,
      _fallback: unknown,
      action?: unknown,
    ) => {
      if (action) throw new Error("INVALID_CHANGELIST_ACTION");
      return { state, members: [], scope };
    },
  ) as unknown as typeof projectChangelists;
  const store = createGitChangelistsStore(storage, reduce, immediateLock);
  expect(await store.getState().loadWorkspace(workspace)).toBe(true);
  expect(await store.getState().createList(workspace, "", "new")).toBe(false);
  expect(changelistsUnavailable(store.getState(), workspace)).toBe(false);
  expect(memory.getItem(changelistStorageKey(workspace))).toBeNull();
}, 1000);

test("corrupt workspace metadata is retained and never projected as an empty list", async () => {
  const memory = createMemoryStateStorage();
  const key = changelistStorageKey(workspace);
  const raw = JSON.stringify({
    version: 0,
    state: {
      lists: [{ id: "default", name: "" }],
      activeId: "default",
      assignments: { malformed: "local" },
    },
  });
  memory.setItem(key, raw);
  const reduce = mock(async () => ({
    state: EMPTY_CHANGELISTS,
    members: [],
    scope,
  })) as unknown as typeof projectChangelists;
  const store = createGitChangelistsStore(
    createChangelistStorage(() => memory),
    reduce,
    immediateLock,
  );
  expect(await store.getState().loadWorkspace(workspace)).toBe(false);
  expect(changelistsUnavailable(store.getState(), workspace)).toBe(true);
  expect(memory.getItem(key)).toBe(raw);
}, 1000);

test("independent workspace keys retain their own metadata and failed writes remain blocked", async () => {
  const memory = createMemoryStateStorage();
  const storage = createChangelistStorage(() => memory);
  const other = "C:/other";
  const first = {
    ...EMPTY_CHANGELISTS,
    lists: [...EMPTY_CHANGELISTS.lists, { id: "one", name: "One" }],
  };
  const second = {
    ...EMPTY_CHANGELISTS,
    lists: [...EMPTY_CHANGELISTS.lists, { id: "two", name: "Two" }],
  };
  storage.save(workspace, first);
  storage.save(other, second);
  const reduce = mock(async (state: LocalChangelists) => ({
    state,
    members: [],
    scope,
  })) as unknown as typeof projectChangelists;
  const store = createGitChangelistsStore(storage, reduce, immediateLock);
  expect(await store.getState().loadWorkspace(workspace)).toBe(true);
  expect(await store.getState().loadWorkspace(other)).toBe(true);
  expect(workspaceChangelists(store.getState(), workspace)).toEqual(first);
  expect(workspaceChangelists(store.getState(), other)).toEqual(second);
  const failingStorage = {
    load: () => first,
    save: () => {
      throw new Error("write denied");
    },
  };
  const changed = mock(async () => ({
    state: second,
    members: [],
    scope,
  })) as unknown as typeof projectChangelists;
  const failed = createGitChangelistsStore(failingStorage, changed, immediateLock);
  expect(await failed.getState().activateList(workspace, "two")).toBe(false);
  expect(failed.getState().unavailable).toBe(true);
}, 1000);
