import { afterEach, expect, test } from "bun:test";
import { actionFixture } from "./vcs-action-test-fixture";
import type { VcsWriteAction, VcsWriteSnapshot } from "./vcs-action-types";

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});
async function fixture() {
  const f = await actionFixture();
  cleanups.push(f.close);
  const snapshot = f.controller.status.getSnapshot().snapshot!;
  snapshot.capabilities = { ...snapshot.capabilities, fileOperations: 1 };
  return { ...f, snapshot };
}
const actions: VcsWriteAction[] = [
  { operation: "add", paths: ["untracked.txt"] },
  { operation: "delete", paths: ["after.txt"] },
];

test("add and delete freeze only typed selection and the one-use status receipt", async () => {
  for (const action of actions) {
    const f = await fixture();
    const selection = structuredClone(action);
    f.controller.actions.prepare(f.snapshot, selection);
    expect(f.controller.actions.getSnapshot().review?.paths).toEqual(
      action.operation === "add" ? ["untracked.txt"] : ["after.txt", "before.txt"],
    );
    if ("paths" in selection) selection.paths.push("gone.txt");
    await f.controller.actions.confirm();
    expect(f.calls[0]).toMatchObject({
      kind: "write",
      statusId: f.snapshot.requestId,
      action,
    });
    expect(f.controller.actions.getSnapshot().phase).toBe("completed");
  }
});

test("file operations reject wrong statuses, external scopes, implicit parents and incomplete or unnegotiated receipts", async () => {
  const f = await fixture();
  for (const action of [
    { operation: "add", paths: ["new.txt"] },
    { operation: "add", paths: ["after.txt"] },
    { operation: "delete", paths: ["untracked.txt"] },
    { operation: "delete", paths: ["gone.txt"] },
    { operation: "delete", paths: [] },
    { operation: "delete", paths: ["not-in-receipt.txt"] },
  ] as VcsWriteAction[]) {
    f.controller.actions.prepare(f.snapshot, action);
    expect(f.controller.actions.getSnapshot().phase).toBe("failed");
  }
  for (const status of ["added", "replaced", "renamed", "copied", "unversioned", "ignored"]) {
    f.snapshot.result.changes.push(
      { path: status, oldPath: null, status, flags: [] },
      { path: `${status}/child.txt`, oldPath: null, status: "modified", flags: [] },
    );
    f.controller.actions.prepare(f.snapshot, {
      operation: "delete",
      paths: [`${status}/child.txt`],
    });
    expect(f.controller.actions.getSnapshot().phase).toBe("failed");
  }
  f.snapshot.result.changes.push({
    path: "clean-looking/child.txt",
    oldPath: null,
    status: "unversioned",
    flags: [],
  });
  f.controller.actions.prepare(f.snapshot, {
    operation: "add",
    paths: ["clean-looking/child.txt"],
  });
  expect(f.controller.actions.getSnapshot().phase).toBe("failed");
  for (const flag of ["external", "submodule", "treeConflict"]) {
    for (const action of actions) {
      const row = f.snapshot.result.changes.find(
        (row) => row.path === (action.operation === "add" ? "untracked.txt" : "after.txt"),
      )!;
      row.flags = [flag];
      f.controller.actions.prepare(f.snapshot, action);
      expect(f.controller.actions.getSnapshot().phase).toBe("failed");
      row.flags = [];
    }
  }
  for (const action of actions) {
    f.snapshot.result.truncated = true;
    f.controller.actions.prepare(f.snapshot, action);
    expect(f.controller.actions.getSnapshot().phase).toBe("failed");
    f.snapshot.result.truncated = false;
    f.snapshot.capabilities = { add: 1, delete: 1, fileOperation: 1 };
    f.controller.actions.prepare(f.snapshot, action);
    expect(f.controller.actions.getSnapshot().phase).toBe("failed");
  }
  expect(f.calls).toEqual([]);
});

test("add and delete malformed or wrong-operation replies are unknown and never retried", async () => {
  for (const action of actions) {
    for (const malformed of ["wrongOperation", "null", "missingResult"]) {
      const f = await fixture();
      f.port.write = async (_scope, _gen, root, id) => {
        f.calls.push({ kind: "write", root, id });
        if (malformed === "null") return null as unknown as VcsWriteSnapshot;
        if (malformed === "missingResult")
          return { ...f.result(id, action), result: undefined } as unknown as VcsWriteSnapshot;
        return { ...f.result(id, action), operation: "rollback" };
      };
      f.controller.actions.prepare(f.snapshot, action);
      await f.controller.actions.confirm();
      expect(f.controller.actions.getSnapshot().phase).toBe("unknown");
      await f.controller.actions.confirm();
      expect(f.calls.filter((call) => call.kind === "write")).toHaveLength(1);
      expect(f.calls.find((call) => call.kind === "stop")?.id).toBe(f.calls[0]!.id);
    }
  }
});

test("delete checks both endpoints' own rows regardless of order or repeated selection", async () => {
  const f = await fixture();
  for (const status of ["renamed", "copied"]) {
    for (const old of [
      { status: "unversioned", flags: [] },
      { status: "ignored", flags: [] },
      { status: "conflicted", flags: [] },
      { status: "modified", flags: ["external"] },
      { status: "modified", flags: ["submodule"] },
      { status: "modified", flags: ["treeConflict"] },
      { status: "modified", flags: [] },
    ]) {
      const rows = [
        { path: "after.txt", oldPath: "before.txt", status, flags: [] },
        { path: "before.txt", oldPath: null, ...old },
      ];
      for (const changes of [rows, [...rows].reverse()]) {
        f.snapshot.result.changes = changes;
        for (const paths of [
          ["after.txt"],
          ["after.txt", "after.txt"],
          ["before.txt", "after.txt", "before.txt"],
          ["after.txt", "before.txt"],
        ]) {
          f.controller.actions.prepare(f.snapshot, { operation: "delete", paths });
          if (old.status === "modified" && old.flags.length === 0) {
            expect(f.controller.actions.getSnapshot().review?.paths).toEqual([
              "after.txt",
              "before.txt",
            ]);
            await f.controller.actions.cancel();
          } else {
            expect(f.controller.actions.getSnapshot().phase).toBe("failed");
            expect(f.controller.actions.getSnapshot().review).toBeNull();
          }
        }
      }
    }
  }
  expect(f.calls).toEqual([]);
});
