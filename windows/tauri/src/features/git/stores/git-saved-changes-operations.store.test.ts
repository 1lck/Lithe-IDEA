import { expect, test } from "bun:test";
import { useSavedChangesOperationsStore } from "./git-saved-changes-operations.store";

test("saved-changes locks stay in their workspace and recognize Windows path aliases", () => {
  const first = useSavedChangesOperationsStore.getStore("saved-operations-first");
  const second = useSavedChangesOperationsStore.getStore("saved-operations-second");
  const release = first.getState().startOperation("C:/fixture/Repo/");
  try {
    expect(first.getState().startOperation("c:\\fixture\\repo")).toBeUndefined();
    expect(first.getState().pending.size).toBe(1);
    expect(second.getState().pending.size).toBe(0);
  } finally {
    release?.();
  }
});

test("a matching release is idempotent and cannot release a later operation", () => {
  const store = useSavedChangesOperationsStore.getStore("saved-operations-release");
  const releaseFirst = store.getState().startOperation("C:/fixture/repo");
  releaseFirst?.();
  const releaseSecond = store.getState().startOperation("C:/fixture/repo");
  try {
    releaseFirst?.();
    expect(store.getState().pending.size).toBe(1);
  } finally {
    releaseFirst?.();
    releaseSecond?.();
  }
  expect(store.getState().pending.size).toBe(0);
});

test("WSL repositories retain distinct case-sensitive operation owners", () => {
  const store = useSavedChangesOperationsStore.getStore("saved-operations-wsl");
  const releaseUpper = store.getState().startOperation("wsl://Fixture/home/Repo");
  const releaseLower = store.getState().startOperation("wsl://Fixture/home/repo");
  try {
    expect(store.getState().pending.size).toBe(2);
    releaseUpper?.();
    expect(store.getState().pending.size).toBe(1);
    expect(store.getState().startOperation("wsl://Fixture/home/repo")).toBeUndefined();
  } finally {
    releaseUpper?.();
    releaseLower?.();
  }
});
