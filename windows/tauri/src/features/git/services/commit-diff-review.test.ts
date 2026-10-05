import { expect, test } from "bun:test";
import { fullDiff } from "@/test-utils/commit-diff-fixtures";
import { createCommitDiffReview, type CommitDiffSnapshot, type CommitDiffReviewState } from "./commit-diff-review";

function snapshot(index = ["a", "b", "c", "d"]) : CommitDiffSnapshot {
  return { diff: fullDiff(["a", "b", "c", "d"], ["a", "B", "c", "D"]),
    staged: fullDiff(["a", "b", "c", "d"], index),
    file: { path: "file.txt", status: "modified", staged: index[1] === "B", worktree: true } };
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(settle => { resolve = settle; });
  return { promise, resolve };
}
function fixture() {
  let current = snapshot();
  let state!: CommitDiffReviewState;
  const writes: string[] = [];
  let read: () => Promise<CommitDiffSnapshot | null> = async () => current;
  let released = 0;
  const owner = createCommitDiffReview({
    read: () => read(),
    stage: async () => { writes.push("stage"); current = snapshot(["a", "B", "c", "d"]); return true; },
    unstage: async () => { writes.push("unstage"); current = snapshot(); return true; },
    rollback: async () => { writes.push("rollback"); return true; },
    includeFile: async () => { writes.push("file"); return true; },
    changed: next => { state = next; }, beginWrite: () => () => { released++; },
  });
  return { owner, writes, setSnapshot: (value: CommitDiffSnapshot) => { current = value; },
    setRead: (value: typeof read) => { read = value; },
    get state() { return state; }, get released() { return released; } };
}

test("inclusion writes one block and republishes its actual index state", async () => {
  const f = fixture();
  try {
    await f.owner.refresh();
    const id = f.state.blocks[0].id;
    expect(await f.owner.apply(id, "include")).toBe("applied");
    expect(f.writes).toEqual(["stage"]);
    expect(f.state.blocks.map(block => block.checked)).toEqual([true, false]);
    expect(await f.owner.apply(id, "exclude")).toBe("applied");
    expect(f.state.blocks.map(block => block.checked)).toEqual([false, false]);
    expect(f.released).toBe(2);
  } finally { f.owner.dispose(); }
});

test("a changed snapshot during rollback validation refreshes without applying an old patch", async () => {
  const f = fixture(), gate = deferred<CommitDiffSnapshot | null>();
  let action: Promise<unknown> | undefined;
  try {
    await f.owner.refresh();
    f.setRead(() => gate.promise);
    action = f.owner.apply(f.state.blocks[0].id, "rollback");
    const updated = snapshot(["a", "B", "c", "d"]);
    f.setSnapshot(updated);
    gate.resolve(updated);
    expect(await action).toBe("stale");
    expect(f.writes).toEqual([]);
    expect(f.state.blocks[0].checked).toBe(true);
  } finally { gate.resolve(null); await action; f.owner.dispose(); }
});

test("disposal during rollback validation suppresses writes and still releases the commit guard", async () => {
  const f = fixture(), gate = deferred<CommitDiffSnapshot | null>();
  let action: Promise<unknown> | undefined;
  try {
    await f.owner.refresh();
    f.setRead(() => gate.promise);
    action = f.owner.apply(f.state.blocks[0].id, "rollback");
    expect(await f.owner.apply(f.state.blocks[1].id, "include")).toBe("ignored");
    f.owner.dispose();
    gate.resolve(snapshot());
    expect(await action).toBe("ignored");
    expect(f.writes).toEqual([]);
    expect(f.released).toBe(1);
  } finally { gate.resolve(null); await action; f.owner.dispose(); }
});

test("a Git event arriving during a refresh triggers a new read instead of publishing a stale result", async () => {
  const f = fixture(), gate = deferred<CommitDiffSnapshot | null>();
  let pending: Promise<void> | undefined;
  let reads = 0;
  try {
    f.setRead(() => ++reads === 1 ? gate.promise : Promise.resolve(snapshot(["a", "B", "c", "d"])));
    pending = f.owner.refresh();
    const joined = f.owner.refresh();
    gate.resolve(snapshot());
    await Promise.all([pending, joined]);
    expect(reads).toBe(2);
    expect(f.state.blocks[0].checked).toBe(true);
  } finally { gate.resolve(null); await pending; f.owner.dispose(); }
});

test("read failures retain the existing diff and surface a refresh error", async () => {
  const f = fixture();
  try {
    await f.owner.refresh();
    const previous = f.state.snapshot;
    f.setRead(async () => { throw new Error("unavailable"); });
    await f.owner.refresh();
    expect(f.state.snapshot).toBe(previous);
    expect(f.state.error).toBe("read");
  } finally { f.owner.dispose(); }
});

test("entering commit review during a pending validation read prevents the block write", async () => {
  const gate = deferred<CommitDiffSnapshot | null>();
  const current = snapshot();
  let writable = true, reads = 0, writes = 0, state!: CommitDiffReviewState;
  const owner = createCommitDiffReview({
    read: () => ++reads === 2 ? gate.promise : Promise.resolve(current),
    stage: async () => { writes++; return true; }, unstage: async () => false,
    rollback: async () => false, includeFile: async () => false,
    canWrite: () => writable, changed: next => { state = next; },
  });
  let action: Promise<unknown> | undefined;
  try {
    await owner.refresh();
    action = owner.apply(state.blocks[0].id, "include");
    writable = false;
    gate.resolve(current);
    expect(await action).toBe("ignored");
    expect(writes).toBe(0);
  } finally { gate.resolve(current); await action; owner.dispose(); }
});
