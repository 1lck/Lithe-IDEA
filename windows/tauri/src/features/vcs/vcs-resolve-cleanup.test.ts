import { afterEach, expect, test } from "bun:test";
import { actionFixture, flushActions } from "./vcs-action-test-fixture";
import type { VcsWriteAction } from "./vcs-action-types";

const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});
async function fixture() {
  const f = await actionFixture();
  cleanups.push(f.close);
  const status = f.controller.status.getSnapshot().snapshot!;
  status.capabilities = { ...status.capabilities, conflicts: 1, cleanup: 1 };
  status.result.changes.push(
    { path: "conflict.txt", oldPath: null, status: "conflicted", flags: [] },
    {
      path: "tree.txt",
      oldPath: "old-tree.txt",
      status: "renamed",
      flags: ["treeConflict"],
    },
  );
  return { ...f, snapshot: status };
}
const actions: VcsWriteAction[] = [
  { operation: "resolve", paths: ["conflict.txt", "tree.txt"] },
  { operation: "cleanup" },
];

test("resolve uses conflicts negotiation and freezes exactly the selected conflict paths and receipt", async () => {
  const f = await fixture();
  const action: VcsWriteAction = {
    operation: "resolve",
    paths: ["tree.txt", "conflict.txt"],
  };
  f.controller.actions.prepare(f.snapshot, action);
  expect(f.controller.actions.getSnapshot().review?.paths).toEqual(["conflict.txt", "tree.txt"]);
  expect(f.controller.actions.getSnapshot().review?.statusId).toBe(f.snapshot.requestId);
  action.paths.push("new.txt");
  await f.controller.actions.confirm();
  expect(f.calls[0]).toMatchObject({
    kind: "write",
    statusId: f.snapshot.requestId,
    action: { operation: "resolve", paths: ["tree.txt", "conflict.txt"] },
  });
  expect(f.controller.actions.getSnapshot().phase).toBe("completed");
});

test("resolve refuses nonconflicts, missing rows, scheduled ancestors, incomplete receipts and unnegotiated conflicts", async () => {
  const f = await fixture();
  for (const paths of [[], ["new.txt"], ["absent.txt"], ["tree.txt", "gone.txt"]]) {
    f.controller.actions.prepare(f.snapshot, { operation: "resolve", paths });
    expect(f.controller.actions.getSnapshot().phase).toBe("failed");
  }
  for (const status of ["added", "replaced", "renamed", "copied"]) {
    f.snapshot.result.changes.push(
      { path: status, oldPath: null, status, flags: [] },
      {
        path: `${status}/child.txt`,
        oldPath: null,
        status: "conflicted",
        flags: [],
      },
    );
    f.controller.actions.prepare(f.snapshot, {
      operation: "resolve",
      paths: [`${status}/child.txt`],
    });
    expect(f.controller.actions.getSnapshot().phase).toBe("failed");
  }
  f.snapshot.result.truncated = true;
  f.controller.actions.prepare(f.snapshot, actions[0]!);
  expect(f.controller.actions.getSnapshot().phase).toBe("failed");
  f.snapshot.result.truncated = false;
  f.snapshot.capabilities = { resolve: 1 };
  f.controller.actions.prepare(f.snapshot, actions[0]!);
  expect(f.controller.actions.getSnapshot().phase).toBe("failed");
  expect(f.calls).toEqual([]);
});

test("cleanup is unavailable for parent, subroot, nested, ambiguous and incomplete root scopes", async () => {
  for (const boundary of ["parent", "subroot", "nested", "ambiguous", "truncated"]) {
    const f = await fixture();
    const root = f.view.detection.roots[0]!;
    if (boundary === "parent" || boundary === "subroot") {
      root.id = boundary === "parent" ? ".." : "child";
      f.snapshot.rootId = root.id;
    } else if (boundary === "nested") f.view.detection.roots.push({ ...root, id: "nested" });
    else if (boundary === "ambiguous")
      f.view.detection.ambiguous.push({ id: "mixed", vcs: ["git", "example"] });
    else f.view.detection.truncated = true;
    f.controller.actions.prepare(f.snapshot, { operation: "cleanup" });
    expect(f.controller.actions.getSnapshot().review).toBeNull();
    await f.controller.actions.confirm();
    expect(f.calls).toEqual([]);
  }
});

test("resolve and cleanup confirm only once and refresh original status and file history", async () => {
  for (const action of actions) {
    const f = await fixture();
    await f.controller.query.history("", "conflict.txt");
    f.calls.length = 0;
    f.controller.actions.prepare(f.snapshot, action);
    await Promise.all([f.controller.actions.confirm(), f.controller.actions.confirm()]);
    expect(f.calls.map((call) => call.kind)).toEqual(["write", "detect", "status", "query"]);
    expect(f.controller.actions.getSnapshot().phase).toBe("completed");
  }
});

test("resolve and cleanup retain definitive versus unknown outcomes through failed stop and cleanup retry", async () => {
  for (const action of actions) {
    for (const code of [
      "vcs.provider.pathUnavailable",
      "vcs.workingCopy.locked",
      "vcs.provider.failed",
      "vcs.provider.outcomeUnknown:requestTimeout",
    ]) {
      const f = await fixture();
      f.port.write = async (_scope, _gen, root, id) => {
        f.calls.push({ kind: "write", root, id });
        throw new Error(code);
      };
      f.port.cancelStatus = async (_scope, id) => {
        f.calls.push({ kind: "stop", id });
        throw new Error("vcs.provider.cleanupFailed");
      };
      f.controller.actions.prepare(f.snapshot, action);
      await f.controller.actions.confirm();
      expect(f.controller.actions.getSnapshot().phase).toBe("cancelFailed");
      const id = f.calls[0]!.id;
      f.port.cancelStatus = async (_scope, id) => {
        f.calls.push({ kind: "stop", id });
      };
      await f.controller.actions.cancel();
      expect(f.controller.actions.getSnapshot().phase).toBe(
        code.includes("outcomeUnknown") ? "unknown" : "failed",
      );
      expect(f.calls.filter((call) => call.kind === "write")).toHaveLength(1);
      expect(f.calls.filter((call) => call.kind === "stop").every((call) => call.id === id)).toBe(
        true,
      );
    }
  }
});

test("replacement, receipt mutation and cancellation before dispatch leave resolve and cleanup inert", async () => {
  for (const action of actions) {
    for (const boundary of ["replace", "receipt", "cancel"]) {
      const f = await fixture();
      f.controller.actions.prepare(f.snapshot, action);
      if (boundary === "replace") f.controller.invalidate();
      else if (boundary === "receipt") f.snapshot.requestId = "replacement-receipt";
      else await f.controller.actions.cancel();
      await f.controller.actions.confirm();
      expect(f.calls).toEqual([]);
    }
  }
});

test("closing a running resolve or cleanup stops its owner without affecting another window or accepting a late reply", async () => {
  for (const action of actions) {
    const f = await fixture();
    const other = await fixture();
    const late = f.deferred(f.result("late", action));
    f.port.write = async (_scope, _gen, root, id) => {
      f.calls.push({ kind: "write", root, id });
      return late.promise;
    };
    f.controller.actions.prepare(f.snapshot, action);
    const running = f.controller.actions.confirm();
    await flushActions();
    await f.controller.close();
    await running;
    late.resolve(f.result(f.calls[0]!.id!, action));
    await flushActions();
    expect(f.calls.map((call) => call.kind)).toEqual(["write", "stop"]);
    expect(f.calls[1]!.id).toBe(f.calls[0]!.id);
    expect(f.controller.actions.getSnapshot().phase).not.toBe("completed");
    expect(other.calls).toEqual([]);
    expect(other.controller.status.getSnapshot().snapshot).toBe(other.snapshot);
  }
});

test("resolve and cleanup cancellation, deadline and replacement never accept or resend a late write", async () => {
  for (const action of actions) {
    for (const boundary of ["stop", "deadline", "replace"]) {
      const f = await fixture();
      const late = f.deferred(f.result("late", action));
      f.port.write = async (_scope, _gen, root, id) => {
        f.calls.push({ kind: "write", root, id });
        return late.promise;
      };
      f.controller.actions.prepare(f.snapshot, action);
      const running = f.controller.actions.confirm();
      await flushActions();
      if (boundary === "stop") await f.controller.actions.cancel();
      else if (boundary === "deadline") for (const deadline of [...f.writes]) deadline();
      else f.controller.invalidate();
      await running;
      await flushActions();
      const id = f.calls[0]!.id!;
      late.resolve(f.result(id, action));
      await flushActions();
      expect(f.controller.actions.getSnapshot().phase).toBe("unknown");
      expect(f.calls.filter((call) => call.kind === "write")).toHaveLength(1);
      expect(f.calls.filter((call) => call.kind === "stop")).toHaveLength(1);
      expect(f.calls.find((call) => call.kind === "stop")?.id).toBe(id);
    }
  }
});
