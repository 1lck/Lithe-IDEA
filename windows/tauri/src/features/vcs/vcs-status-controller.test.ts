import { afterEach, expect, test } from "bun:test";
import { VcsRootController } from "./vcs-root-controller";
import type { VcsRootPort, VcsSnapshot, VcsStatusSnapshot } from "./vcs-root-types";

const cleanups: Array<() => void | Promise<void>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});
async function flush() {
  for (let turn = 0; turn < 12; turn++) await Promise.resolve();
}
function deferred<T>(fallback: T) {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((yes) => {
    resolve = yes;
  });
  cleanups.push(() => resolve(fallback));
  return { promise, resolve };
}
async function fixture() {
  const scope = {
    workspaceId: "fixture",
    workspaceRoot: "C:/fixture/workspace",
    incarnation: "one",
  };
  const view: VcsSnapshot = {
    generation: 7,
    workspaceId: scope.workspaceId,
    workspaceRoot: scope.workspaceRoot,
    detection: {
      providers: [
        { vcs: "git", displayName: "Git", origin: { kind: "builtIn" } },
        {
          vcs: "svn",
          displayName: "Subversion",
          origin: { kind: "plugin", pluginID: "fixture.plugin" },
        },
      ],
      roots: [
        { id: "", path: scope.workspaceRoot, vcs: "git", mapped: false },
        { id: "legacy", path: `${scope.workspaceRoot}/legacy`, vcs: "svn", mapped: false },
        { id: "other", path: `${scope.workspaceRoot}/other`, vcs: "svn", mapped: false },
      ],
      ambiguous: [{ id: "mixed", vcs: ["git", "svn"] }],
      unusedMappings: [],
      truncated: false,
      rejected: [],
      conflicts: [],
    },
  };
  const calls: unknown[][] = [];
  const deadlines = new Set<() => void>();
  const statusDeadlines = new Set<() => void>();
  const result = (requestId = "late", rootId = "legacy"): VcsStatusSnapshot => ({
    requestId,
    generation: 7,
    rootId,
    vcs: "svn",
    result: {
      head: null,
      changes: [{ path: "a.txt", oldPath: null, status: "modified", flags: [] }],
      truncated: false,
    },
  });
  const port: VcsRootPort = {
    detect: async () => view,
    owners: async () => {
      throw new Error("unused");
    },
    close: async () => {
      calls.push(["close", scope]);
    },
    deadline: (callback) => {
      deadlines.add(callback);
      return () => {
        deadlines.delete(callback);
      };
    },
    statusDeadline: (callback) => {
      statusDeadlines.add(callback);
      return () => {
        statusDeadlines.delete(callback);
      };
    },
    status: async (...args) => {
      calls.push(["status", ...args]);
      return result(args[3], args[2]);
    },
    cancelStatus: async (...args) => {
      calls.push(["cancel", ...args]);
    },
  };
  const controller = new VcsRootController(scope, port);
  cleanups.push(async () => {
    port.cancelStatus = async () => {};
    await controller.close();
  });
  await controller.refresh();
  return { controller, port, calls, view, scope, result, deadlines, statusDeadlines };
}

test("explicit read-only status binds the exact plugin root and generation without changing the Git source", async () => {
  const f = await fixture();
  await f.controller.status.refresh("legacy");
  const state = f.controller.status.getSnapshot();
  expect(state.phase).toBe("ready");
  expect(state.snapshot?.rootId).toBe("legacy");
  expect(f.calls[0]).toEqual(["status", f.scope, 7, "legacy", state.snapshot!.requestId]);
  expect(f.controller.getSnapshot().snapshot).toBe(f.view);
  expect(f.statusDeadlines.size).toBe(0);
});

test("Git, unknown and ambiguous roots never start a VCS provider", async () => {
  const f = await fixture();
  for (const id of ["", "mixed", "absent"]) await f.controller.status.refresh(id);
  expect(f.calls).toEqual([]);
  expect(f.controller.status.getSnapshot().phase).toBe("idle");
});

test("one active status keeps its root until native cancellation acknowledges cleanup", async () => {
  const f = await fixture();
  const late = deferred(f.result());
  f.port.status = async (...args) => {
    f.calls.push(["status", ...args]);
    return late.promise;
  };
  const reading = f.controller.status.refresh("legacy");
  await flush();
  await f.controller.status.refresh("other");
  expect(f.calls.filter(([kind]) => kind === "status")).toHaveLength(1);
  await f.controller.status.cancel();
  await reading;
  expect(f.calls[1]?.slice(0, 2)).toEqual(["cancel", f.scope]);
  expect(f.controller.status.getSnapshot().phase).toBe("idle");
});

test("manual status deadline cancels natively and a late reply cannot publish", async () => {
  const f = await fixture();
  const late = deferred(f.result());
  f.port.status = () => late.promise;
  const reading = f.controller.status.refresh("legacy");
  await flush();
  for (const expire of [...f.statusDeadlines]) expire();
  await reading;
  expect(f.controller.status.getSnapshot().phase).toBe("failed");
  expect(String(f.controller.status.getSnapshot().error)).toContain("requestTimeout");
  expect(f.calls[0]?.[0]).toBe("cancel");
  late.resolve(f.result());
  await flush();
  expect(f.controller.status.getSnapshot().snapshot).toBeNull();
  expect(f.deadlines.size).toBe(0);
});

test("cleanup failure retains the same request and blocks new reads until retry succeeds", async () => {
  const f = await fixture();
  const late = deferred(f.result());
  f.port.status = () => late.promise;
  const ids: string[] = [];
  f.port.cancelStatus = async (_scope, id) => {
    ids.push(id);
    throw new Error("vcs.provider.cleanupFailed");
  };
  const reading = f.controller.status.refresh("legacy");
  await flush();
  expect((await Promise.allSettled([f.controller.status.cancel()]))[0].status).toBe("rejected");
  await reading;
  expect(f.controller.status.getSnapshot().phase).toBe("cancelFailed");
  await f.controller.status.refresh("other");
  f.port.cancelStatus = async (_scope, id) => {
    ids.push(id);
  };
  await f.controller.status.cancel();
  expect(new Set(ids).size).toBe(1);
  expect(ids.length).toBeGreaterThanOrEqual(2);
  expect(f.controller.status.getSnapshot().phase).toBe("idle");
});

test("cancellation acknowledgement has its own deadline and remains retryable", async () => {
  const f = await fixture();
  const late = deferred(f.result());
  const cleanup = deferred<void>(undefined);
  f.port.status = () => late.promise;
  f.port.cancelStatus = () => cleanup.promise;
  const reading = f.controller.status.refresh("legacy");
  await flush();
  const stopping = f.controller.status.cancel();
  void stopping.catch(() => {});
  await flush();
  for (const expire of [...f.deadlines]) expire();
  expect((await Promise.allSettled([stopping]))[0].status).toBe("rejected");
  await reading;
  expect(f.controller.status.getSnapshot().phase).toBe("cancelFailed");
  f.port.cancelStatus = async () => {};
  await f.controller.status.cancel();
  expect(f.controller.status.getSnapshot().phase).toBe("idle");
});

test("root invalidation cancels an in-flight status and removes a completed projection", async () => {
  const f = await fixture();
  await f.controller.status.refresh("legacy");
  f.controller.invalidate();
  expect(f.controller.status.getSnapshot().snapshot).toBeNull();
  await f.controller.refresh();
  const late = deferred(f.result());
  f.port.status = () => late.promise;
  const reading = f.controller.status.refresh("legacy");
  await flush();
  f.controller.invalidate();
  await reading;
  expect(f.controller.status.getSnapshot().snapshot).toBeNull();
  expect(f.calls.some(([kind]) => kind === "cancel")).toBe(true);
});

test("wrong request, root, VCS and generation are rejected before a projection is published", async () => {
  const f = await fixture();
  for (const patch of [
    { requestId: "foreign" },
    { rootId: "other" },
    { generation: 6 },
    { vcs: "git" },
  ]) {
    f.port.status = async (_scope, _generation, root, request) => ({
      ...f.result(request, root),
      ...patch,
    });
    await f.controller.status.refresh("legacy");
    expect(f.controller.status.getSnapshot().phase).toBe("failed");
    expect(f.controller.status.getSnapshot().snapshot).toBeNull();
  }
});

test("workspace close still revokes native scope when individual status cleanup fails", async () => {
  const f = await fixture();
  const late = deferred(f.result());
  f.port.status = () => late.promise;
  f.port.cancelStatus = async () => {
    throw new Error("vcs.provider.cleanupFailed");
  };
  const reading = f.controller.status.refresh("legacy");
  await flush();
  expect((await Promise.allSettled([f.controller.close()]))[0].status).toBe("rejected");
  await reading;
  expect(f.calls.some(([kind]) => kind === "close")).toBe(true);
  expect(f.controller.status.getSnapshot().snapshot).toBeNull();
});

test("separate windows keep independent status projections and cancellation", async () => {
  const a = await fixture(),
    b = await fixture();
  const late = deferred(a.result());
  a.port.status = () => late.promise;
  const reading = a.controller.status.refresh("legacy");
  await flush();
  await b.controller.status.refresh("other");
  await a.controller.close();
  await reading;
  expect(a.controller.status.getSnapshot().snapshot).toBeNull();
  expect(b.controller.status.getSnapshot().snapshot?.rootId).toBe("other");
  expect(b.calls.some(([kind]) => kind === "cancel")).toBe(false);
});
