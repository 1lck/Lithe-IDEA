import { expect, test } from "bun:test";
import { fullDiff } from "@/test-utils/commit-diff-fixtures";
import type { CommitDiffBlock } from "../api/git-diff-block-api";
import { createCommitDiffReview, type CommitDiffSnapshot, type CommitDiffReviewState } from "./commit-diff-review";

const block = (id: string, checked: boolean): CommitDiffBlock => ({
  id, checked, indeterminate: false, canToggle: true, canRollback: !checked, leftStart: 0, rightStart: 0,
});
/** Core owns the blocks; the token names the read each block was planned from. */
function snapshot(included = false, token = "t0"): CommitDiffSnapshot {
  return { diff: fullDiff(["a", "b", "c", "d"], ["a", "B", "c", "D"]),
    staged: fullDiff(["a", "b", "c", "d"], ["a", "b", "c", "d"]),
    file: { path: "file.txt", status: "modified", staged: included, worktree: true },
    blocks: [block("line-1", included), block("line-3", false)], token };
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(settle => { resolve = settle; });
  return { promise, resolve };
}
function fixture(outcome: "applied" | "stale" | "unsafe" | "failed" = "applied") {
  let current = snapshot();
  let state!: CommitDiffReviewState;
  const writes: string[] = [];
  let read: () => Promise<CommitDiffSnapshot | null> = async () => current;
  let released = 0;
  const owner = createCommitDiffReview({
    read: () => read(),
    writeBlock: async (taken, id, action) => {
      writes.push(`${action}:${id}:${taken.token}`);
      if (outcome === "applied") current = snapshot(action === "include", "t1");
      return outcome;
    },
    includeFile: async () => { writes.push("file"); return true; },
    changed: next => { state = next; }, beginWrite: () => () => { released++; },
  });
  return { owner, writes, setSnapshot: (value: CommitDiffSnapshot) => { current = value; },
    setRead: (value: typeof read) => { read = value; },
    get state() { return state; }, get released() { return released; } };
}

test("a block write names the planned block and snapshot token, then republishes Core's state", async () => {
  const f = fixture();
  try {
    await f.owner.refresh();
    expect(await f.owner.apply("line-1", "include")).toBe("applied");
    expect(f.writes).toEqual(["include:line-1:t0"]);
    expect(f.state.blocks.map(item => item.checked)).toEqual([true, false]);
    expect(await f.owner.apply("line-1", "exclude")).toBe("applied");
    expect(f.writes[1]).toBe("exclude:line-1:t1");
    expect(f.state.blocks.map(item => item.checked)).toEqual([false, false]);
    expect(f.released).toBe(2);
  } finally { f.owner.dispose(); }
});

test("a write Core refuses as stale surfaces the stale notice and refreshes", async () => {
  const f = fixture("stale");
  try {
    await f.owner.refresh();
    expect(await f.owner.apply("line-1", "rollback")).toBe("stale");
    expect(f.state.error).toBe("stale");
    expect(f.state.busy).toBe(false);
    expect(f.released).toBe(1);
  } finally { f.owner.dispose(); }
});

test("an unsafe or failed Core write surfaces a write error", async () => {
  for (const outcome of ["unsafe", "failed"] as const) {
    const f = fixture(outcome);
    try {
      await f.owner.refresh();
      expect(await f.owner.apply("line-1", "rollback")).toBe("failed");
      expect(f.state.error).toBe("write");
    } finally { f.owner.dispose(); }
  }
});

test("blocks Core cannot toggle are never sent", async () => {
  const f = fixture();
  try {
    f.setSnapshot({ ...snapshot(), blocks: [{ ...block("line-1", false), canToggle: false, canRollback: false }] });
    await f.owner.refresh();
    expect(await f.owner.apply("line-1", "include")).toBe("ignored");
    expect(await f.owner.apply("line-1", "rollback")).toBe("ignored");
    expect(await f.owner.apply("line-9", "include")).toBe("ignored");
    expect(f.writes).toEqual([]);
  } finally { f.owner.dispose(); }
});

test("disposal during a write still releases the commit guard", async () => {
  const gate = deferred<"applied">();
  let released = 0, state!: CommitDiffReviewState;
  const owner = createCommitDiffReview({
    read: async () => snapshot(), writeBlock: () => gate.promise, includeFile: async () => false,
    beginWrite: () => () => { released++; }, changed: next => { state = next; },
  });
  await owner.refresh();
  const action = owner.apply("line-1", "include");
  expect(await owner.apply("line-3", "include")).toBe("ignored");
  owner.dispose();
  gate.resolve("applied");
  await action;
  expect(released).toBe(1);
  expect(state.snapshot).not.toBeNull();
});

test("a Git event arriving during a refresh triggers a new read instead of publishing a stale result", async () => {
  const f = fixture(), gate = deferred<CommitDiffSnapshot | null>();
  let pending: Promise<void> | undefined;
  let reads = 0;
  try {
    f.setRead(() => ++reads === 1 ? gate.promise : Promise.resolve(snapshot(true, "t1")));
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

test("leaving commit review mid-write prevents the block write", async () => {
  let writable = true, writes = 0, state!: CommitDiffReviewState;
  const owner = createCommitDiffReview({
    read: async () => snapshot(), writeBlock: async () => { writes++; return "applied"; },
    includeFile: async () => false, canWrite: () => writable, changed: next => { state = next; },
  });
  await owner.refresh();
  writable = false;
  expect(await owner.apply(state.blocks[0].id, "include")).toBe("ignored");
  expect(writes).toBe(0);
  owner.dispose();
});
