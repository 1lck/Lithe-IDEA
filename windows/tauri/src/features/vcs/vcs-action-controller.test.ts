import { afterEach, expect, test } from "bun:test";
import type { VcsWriteAction } from "./vcs-action-types";
import { actionFixture, flushActions } from "./vcs-action-test-fixture";
const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});
async function fixture() {
  const f = await actionFixture();
  cleanups.push(f.close);
  return f;
}

test("confirmation expands both rename paths and cancel before confirm makes no native call", async () => {
  const f = await fixture();
  f.controller.actions.prepare(f.controller.status.getSnapshot().snapshot!, {
    operation: "checkin",
    paths: ["after.txt", "gone.txt"],
    message: "Exact message",
  });
  expect(f.controller.actions.getSnapshot().review?.paths).toEqual([
    "after.txt",
    "before.txt",
    "gone.txt",
  ]);
  expect(f.calls).toEqual([]);
  await f.controller.actions.cancel();
  await f.controller.actions.confirm();
  expect(f.calls).toEqual([]);
});

test("confirmed commit binds status receipt and only refreshes original root status and history", async () => {
  const f = await fixture();
  await f.controller.query.history("");
  f.calls.length = 0;
  const snapshot = f.controller.status.getSnapshot().snapshot!;
  f.controller.actions.prepare(snapshot, {
    operation: "checkin",
    paths: ["new.txt", "gone.txt"],
    message: "Selected only",
  });
  await f.controller.actions.confirm();
  expect(f.calls.filter((call) => call.kind === "write")).toHaveLength(1);
  expect(f.calls[0]).toMatchObject({
    kind: "write",
    statusId: snapshot.requestId,
    root: "",
    action: { operation: "checkin", paths: ["new.txt", "gone.txt"], message: "Selected only" },
  });
  expect(f.calls.map((call) => call.kind)).toEqual(["write", "detect", "status", "query"]);
  expect(f.controller.actions.getSnapshot().phase).toBe("completed");
});

test("missing capability, arbitrary paths, empty messages and unversioned rollback cannot open confirmation", async () => {
  const f = await fixture();
  const snapshot = f.controller.status.getSnapshot().snapshot!;
  for (const action of [
    { operation: "rollback", paths: ["untracked.txt"] },
    { operation: "rollback", paths: ["absent.txt"] },
    { operation: "checkin", paths: ["new.txt"], message: "   " },
  ] satisfies VcsWriteAction[]) {
    f.controller.actions.prepare(snapshot, structuredClone(action));
    expect(f.controller.actions.getSnapshot().phase).toBe("failed");
  }
  snapshot.capabilities = {};
  f.controller.actions.prepare(snapshot, { operation: "update" });
  expect(f.controller.actions.getSnapshot().review).toBeNull();
  expect(f.calls).toEqual([]);
});

test("nested or ambiguous roots and parent working copies reject root-wide update", async () => {
  const f = await fixture();
  const snapshot = f.controller.status.getSnapshot().snapshot!;
  f.view.detection.roots.push({
    id: "nested",
    path: `${f.scope.workspaceRoot}/nested`,
    vcs: "git",
    mapped: false,
  });
  f.controller.actions.prepare(snapshot, { operation: "update" });
  expect(f.controller.actions.getSnapshot().phase).toBe("failed");
  f.view.detection.roots.pop();
  f.view.detection.ambiguous.push({ id: "mixed", vcs: ["git", "example"] });
  f.controller.actions.prepare(snapshot, { operation: "update" });
  expect(f.controller.actions.getSnapshot().phase).toBe("failed");
  expect(f.calls).toEqual([]);
});

test("replacement invalidates confirmation and stale confirm never launches", async () => {
  const f = await fixture();
  f.controller.actions.prepare(f.controller.status.getSnapshot().snapshot!, {
    operation: "rollback",
    paths: ["gone.txt"],
  });
  f.controller.invalidate();
  await f.controller.actions.confirm();
  expect(f.calls).toEqual([]);
});

test("checkin cannot confirm a child whose provider would add an unreviewed scheduled parent", async () => {
  const f = await fixture();
  const snapshot = f.controller.status.getSnapshot().snapshot!;
  for (const status of ["added", "replaced", "renamed", "copied"] as const) {
    const parent = `${status}-parent`;
    const path = `${parent}/inside/child.txt`;
    snapshot.result.changes.push(
      { path: parent, oldPath: null, status, flags: [] },
      { path, oldPath: null, status: "added", flags: [] },
    );
    f.controller.actions.prepare(snapshot, {
      operation: "checkin",
      paths: [path],
      message: "Only the child was selected",
    });
    expect(f.controller.actions.getSnapshot().phase).toBe("failed");
    expect(f.controller.actions.getSnapshot().review).toBeNull();
    expect(String(f.controller.actions.getSnapshot().error)).toContain(
      "vcs.provider.pathUnavailable",
    );
  }
  expect(f.calls).toEqual([]);
});

test("cancel in the microtask before dispatch creates only a stop tombstone", async () => {
  const f = await fixture();
  f.controller.actions.prepare(f.controller.status.getSnapshot().snapshot!, {
    operation: "update",
  });
  const running = f.controller.actions.confirm();
  await f.controller.actions.cancel();
  await running;
  expect(f.calls.some((call) => call.kind === "write")).toBe(false);
  expect(f.calls.filter((call) => call.kind === "stop")).toHaveLength(1);
});

test("lost reply and cleanup retry stop the same owner without resending and report unknown outcome", async () => {
  const f = await fixture();
  const late = f.deferred(f.result("late", { operation: "update" }));
  f.port.write = async (_scope, _gen, root, id, statusId, action) => {
    f.calls.push({ kind: "write", id, root, statusId, action });
    return late.promise;
  };
  f.port.cancelStatus = async (_scope, id) => {
    f.calls.push({ kind: "stop", id });
    throw new Error("vcs.provider.cleanupFailed");
  };
  f.controller.actions.prepare(f.controller.status.getSnapshot().snapshot!, {
    operation: "update",
  });
  const running = f.controller.actions.confirm();
  await flushActions();
  for (const deadline of [...f.writes]) deadline();
  await running;
  expect(f.controller.actions.getSnapshot().phase).toBe("cancelFailed");
  const id = f.calls.find((call) => call.kind === "write")!.id;
  f.port.cancelStatus = async (_scope, stopping) => {
    f.calls.push({ kind: "stop", id: stopping });
  };
  await f.controller.actions.cancel();
  expect(f.calls.filter((call) => call.kind === "write")).toHaveLength(1);
  expect(f.calls.filter((call) => call.kind === "stop").every((call) => call.id === id)).toBe(true);
  expect(f.controller.actions.getSnapshot().phase).toBe("unknown");
  late.resolve(f.result(id!, { operation: "update" }));
  await flushActions();
  expect(f.controller.actions.getSnapshot().phase).toBe("unknown");
});

test("definitive provider and preflight failures stay failed and refresh the original root", async () => {
  for (const code of ["vcs.outOfDate", "vcs.authentication.failed", "requestCancelled"]) {
    const f = await fixture();
    await f.controller.query.history("");
    f.calls.length = 0;
    f.port.write = async (_scope, _gen, root, id) => {
      f.calls.push({ kind: "write", id, root });
      throw new Error(code);
    };
    f.controller.actions.prepare(f.controller.status.getSnapshot().snapshot!, {
      operation: "update",
    });
    await f.controller.actions.confirm();
    expect(f.controller.actions.getSnapshot().phase).toBe("failed");
    expect(String(f.controller.actions.getSnapshot().error)).toContain(code);
    expect(f.calls.map((call) => call.kind)).toEqual([
      "write",
      "stop",
      "detect",
      "status",
      "query",
    ]);
  }
});

test("retry cleanup preserves definitive preflight and provider failures without another write", async () => {
  for (const code of ["requestCancelled", "vcs.authentication.failed", "vcs.outOfDate"]) {
    const f = await fixture();
    const original = new Error(`${code};vcs.provider.cleanupFailed`);
    f.port.write = async (_scope, _gen, root, id) => {
      f.calls.push({ kind: "write", id, root });
      throw original;
    };
    f.port.cancelStatus = async (_scope, id) => {
      f.calls.push({ kind: "stop", id });
      throw new Error("vcs.provider.cleanupFailed");
    };
    f.controller.actions.prepare(f.controller.status.getSnapshot().snapshot!, {
      operation: "update",
    });
    await f.controller.actions.confirm();
    expect(f.controller.actions.getSnapshot().phase).toBe("cancelFailed");
    const id = f.calls.find((call) => call.kind === "write")!.id;
    f.port.cancelStatus = async (_scope, id) => {
      f.calls.push({ kind: "stop", id });
    };
    await f.controller.actions.cancel();
    expect(f.controller.actions.getSnapshot().phase).toBe("failed");
    expect(f.controller.actions.getSnapshot().error).toBe(original);
    expect(f.calls.filter((call) => call.kind === "write")).toHaveLength(1);
    expect(f.calls.filter((call) => call.kind === "stop").every((call) => call.id === id)).toBe(
      true,
    );
  }
});

test("a successful native write awaiting cleanup stays unknown after cleanup retry", async () => {
  const f = await fixture();
  const original = new Error("vcs.provider.outcomeUnknown:vcs.provider.cleanupFailed");
  f.port.write = async (_scope, _gen, root, id) => {
    f.calls.push({ kind: "write", id, root });
    throw original;
  };
  f.port.cancelStatus = async (_scope, id) => {
    f.calls.push({ kind: "stop", id });
    throw new Error("vcs.provider.cleanupFailed");
  };
  f.controller.actions.prepare(f.controller.status.getSnapshot().snapshot!, {
    operation: "update",
  });
  await f.controller.actions.confirm();
  expect(f.controller.actions.getSnapshot().phase).toBe("cancelFailed");
  f.port.cancelStatus = async (_scope, id) => {
    f.calls.push({ kind: "stop", id });
  };
  await f.controller.actions.cancel();
  expect(f.controller.actions.getSnapshot().phase).toBe("unknown");
  expect(f.controller.actions.getSnapshot().error).toBe(original);
  expect(f.calls.filter((call) => call.kind === "write")).toHaveLength(1);
});

test("native uncertain outcomes and malformed write replies stay unknown after refresh", async () => {
  for (const invalidReply of [false, true]) {
    const f = await fixture();
    f.port.write = async (_scope, _gen, root, id) => {
      f.calls.push({ kind: "write", id, root });
      if (!invalidReply) throw new Error("vcs.provider.outcomeUnknown:requestTimeout");
      return f.result("wrong-owner", { operation: "update" });
    };
    f.controller.actions.prepare(f.controller.status.getSnapshot().snapshot!, {
      operation: "update",
    });
    await f.controller.actions.confirm();
    expect(f.controller.actions.getSnapshot().phase).toBe("unknown");
    expect(f.calls.filter((call) => call.kind === "write")).toHaveLength(1);
    expect(f.calls.filter((call) => call.kind === "status")).toHaveLength(1);
  }
});

test("window closure stops the original running owner and drops late results", async () => {
  const f = await fixture();
  const late = f.deferred(f.result("late", { operation: "rollback", paths: ["gone.txt"] }));
  f.port.write = async (_scope, _gen, root, id, _statusId, action) => {
    f.calls.push({ kind: "write", root, id, action });
    return late.promise;
  };
  f.controller.actions.prepare(f.controller.status.getSnapshot().snapshot!, {
    operation: "rollback",
    paths: ["gone.txt"],
  });
  const running = f.controller.actions.confirm();
  await flushActions();
  await f.controller.close();
  await running;
  expect(f.calls.filter((call) => call.kind === "stop")).toHaveLength(1);
  expect(f.calls.filter((call) => call.kind === "status")).toHaveLength(0);
  late.resolve(f.result("late", { operation: "rollback", paths: ["gone.txt"] }));
  await flushActions();
  expect(f.controller.actions.getSnapshot().phase).not.toBe("completed");
});

test("passive watch invalidation never confirms or replays a write", async () => {
  const f = await fixture();
  f.controller.actions.prepare(f.controller.status.getSnapshot().snapshot!, {
    operation: "update",
  });
  f.controller.metadataChanged({
    workspaceId: f.scope.workspaceId,
    incarnation: f.scope.incarnation,
    generation: 7,
  });
  await f.controller.actions.confirm();
  expect(f.calls.filter((call) => call.kind === "write")).toEqual([]);
});

test("completed outcomes are removed when the root source is invalidated", async () => {
  const f = await fixture();
  f.controller.actions.prepare(f.controller.status.getSnapshot().snapshot!, {
    operation: "update",
  });
  await f.controller.actions.confirm();
  expect(f.controller.actions.getSnapshot().phase).toBe("completed");
  f.controller.invalidate();
  expect(f.controller.actions.getSnapshot().phase).toBe("idle");
  expect(f.controller.actions.getSnapshot().result).toBeNull();
});
test("same path replacement during post-write refresh cannot inherit an old outcome", async () => {
  const f = await fixture();
  f.controller.status.getSnapshot().snapshot!.rootIdentity = "original-directory";
  f.port.status = async (_scope, _gen, _root, id) => ({
    ...f.status(id),
    rootIdentity: "replacement-directory",
  });
  f.controller.actions.prepare(f.controller.status.getSnapshot().snapshot!, {
    operation: "update",
  });
  await f.controller.actions.confirm();
  expect(f.controller.actions.getSnapshot().phase).toBe("idle");
  expect(f.controller.actions.getSnapshot().result).toBeNull();
});
