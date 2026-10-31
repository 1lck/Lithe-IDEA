import { afterEach, expect, test } from "bun:test";
import { VcsRootController } from "./vcs-root-controller";
import type { VcsOwnership, VcsRootPort, VcsSnapshot } from "./vcs-root-types";

const cleanups: Array<() => void | Promise<void>> = [];
const pending: Promise<unknown>[] = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
  await Promise.allSettled(pending.splice(0));
});
function deferred<T>(fallback: T) {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((yes) => {
    resolve = yes;
  });
  cleanups.push(() => resolve(fallback));
  return { promise, resolve };
}
async function flush() {
  for (let turn = 0; turn < 8; turn++) await Promise.resolve();
}
function fixture() {
  const scope = {
    workspaceId: "fixture-workspace",
    workspaceRoot: "C:/fixture/vcs",
    incarnation: "fixture-incarnation",
  };
  const view: VcsSnapshot = {
    generation: 1,
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
        { id: "", vcs: "git", path: scope.workspaceRoot, mapped: false },
        { id: "legacy", vcs: "svn", path: `${scope.workspaceRoot}/legacy`, mapped: false },
      ],
      ambiguous: [{ id: "mixed", vcs: ["git", "svn"] }],
      unusedMappings: [],
      truncated: false,
      rejected: [],
      conflicts: [],
    },
  };
  const timers = new Set<() => void>();
  const calls: unknown[] = [];
  const port: VcsRootPort = {
    detect: async (scope) => {
      calls.push(["detect", scope]);
      return view;
    },
    owners: async (scope, generation, paths) => {
      calls.push(["owners", scope, generation, paths]);
      return {
        generation,
        owners: paths.map((path) => ({ path, root: "legacy" })),
        commonRoot: view.detection.roots[1],
        complete: true,
      };
    },
    close: async (scope) => {
      calls.push(["close", scope]);
    },
    deadline: (callback) => {
      timers.add(callback);
      return () => {
        timers.delete(callback);
      };
    },
  };
  const controller = new VcsRootController(scope, port);
  cleanups.push(() => controller.close());
  const track = <T>(promise: Promise<T>) => {
    pending.push(promise);
    void promise.catch(() => {});
    return promise;
  };
  return { controller, port, view, scope, calls, timers, track };
}

test("passive roots preserve the native Git/plugin/ambiguity snapshot and query exact generation", async () => {
  const f = fixture();
  await f.controller.refresh();
  expect(f.controller.getSnapshot()).toEqual({ status: "ready", snapshot: f.view, error: null });
  const answer = await f.controller.owners(["legacy/a.txt", "legacy/b.txt"]);
  expect(answer.commonRoot?.id).toBe("legacy");
  expect(f.calls[1]).toEqual(["owners", f.scope, 1, ["legacy/a.txt", "legacy/b.txt"]]);
  expect(f.timers.size).toBe(0);
});

test("cross-root and ambiguous ownership is forwarded unchanged without inferring an owner", async () => {
  const f = fixture();
  await f.controller.refresh();
  const answer: VcsOwnership = {
    generation: 1,
    owners: [
      { path: "legacy/a.txt", root: "legacy" },
      { path: "mixed/a.txt", root: null },
    ],
    commonRoot: null,
    complete: true,
  };
  f.port.owners = async () => answer;
  expect(await f.controller.owners(answer.owners.map((owner) => owner.path))).toBe(answer);
});

test("a newer scan rejects older results and clears stale sources while loading", async () => {
  const f = fixture();
  const old = deferred(f.view);
  f.port.detect = () => old.promise;
  const first = f.track(f.controller.refresh());
  await flush();
  f.port.detect = async () => ({ ...f.view, generation: 2 });
  const second = f.track(f.controller.refresh());
  expect(f.controller.getSnapshot().snapshot).toBeNull();
  await second;
  old.resolve(f.view);
  await first;
  expect(f.controller.getSnapshot().snapshot?.generation).toBe(2);
});

test("plugin invalidation clears roots and rejects an in-flight ownership answer", async () => {
  const f = fixture();
  await f.controller.refresh();
  const late = deferred<VcsOwnership>({
    generation: 1,
    owners: [{ path: "a.txt", root: "" }],
    commonRoot: f.view.detection.roots[0],
    complete: true,
  });
  f.port.owners = () => late.promise;
  const query = f.track(f.controller.owners(["a.txt"]));
  await flush();
  f.controller.invalidate();
  const result = await Promise.allSettled([query]);
  expect(result[0].status).toBe("rejected");
  expect(f.controller.getSnapshot().snapshot).toBeNull();
  late.resolve({
    generation: 1,
    owners: [{ path: "a.txt", root: "" }],
    commonRoot: f.view.detection.roots[0],
    complete: true,
  });
  await flush();
  expect(f.controller.getSnapshot().snapshot).toBeNull();
});

test("closing a workspace retires its exact incarnation and no late scan can restore roots", async () => {
  const f = fixture();
  const late = deferred(f.view);
  f.port.detect = () => late.promise;
  const scan = f.track(f.controller.refresh());
  await flush();
  await f.controller.close();
  late.resolve(f.view);
  await scan;
  expect(f.calls.filter((call) => (call as string[])[0] === "close")).toEqual([["close", f.scope]]);
  expect(f.controller.getSnapshot().snapshot).toBeNull();
  expect((await Promise.allSettled([f.controller.refresh()]))[0].status).toBe("rejected");
  expect(f.timers.size).toBe(0);
});

test("manual deadline reports a failed read and discards a later native reply", async () => {
  const f = fixture();
  const late = deferred(f.view);
  f.port.detect = () => late.promise;
  const scan = f.track(f.controller.refresh());
  await flush();
  for (const timer of [...f.timers]) timer();
  await scan;
  expect(f.controller.getSnapshot().status).toBe("failed");
  expect(String(f.controller.getSnapshot().error)).toContain("requestTimeout");
  late.resolve(f.view);
  await flush();
  expect(f.controller.getSnapshot().snapshot).toBeNull();
  expect(f.timers.size).toBe(0);
});

test("workspace mismatch and stale ownership generation fail closed", async () => {
  const f = fixture();
  f.port.detect = async () => ({ ...f.view, workspaceId: "foreign-workspace" });
  await f.controller.refresh();
  expect(f.controller.getSnapshot().status).toBe("failed");
  f.port.detect = async () => f.view;
  await f.controller.refresh();
  f.port.owners = async () => ({
    generation: 2,
    owners: [{ path: "a.txt", root: "" }],
    commonRoot: f.view.detection.roots[0],
    complete: true,
  });
  expect((await Promise.allSettled([f.controller.owners(["a.txt"])]))[0].status).toBe("rejected");
});

test("independent controllers cannot publish into another window workspace", async () => {
  const a = fixture(),
    b = fixture();
  const late = deferred(a.view);
  a.port.detect = () => late.promise;
  const scan = a.track(a.controller.refresh());
  await flush();
  await b.controller.refresh();
  await a.controller.close();
  late.resolve(a.view);
  await scan;
  expect(a.controller.getSnapshot().snapshot).toBeNull();
  expect(b.controller.getSnapshot().snapshot).toBe(b.view);
});

test("disposing a current-file ownership consumer releases its wait and deadline", async () => {
  const f = fixture();
  await f.controller.refresh();
  const late = deferred<VcsOwnership>({
    generation: 1,
    owners: [{ path: "a.txt", root: "" }],
    commonRoot: null,
    complete: true,
  });
  f.port.owners = () => late.promise;
  const consumer = new AbortController();
  const query = f.track(f.controller.owners(["a.txt"], consumer.signal));
  await flush();
  consumer.abort();
  expect((await Promise.allSettled([query]))[0].status).toBe("rejected");
  expect(f.timers.size).toBe(0);
});
