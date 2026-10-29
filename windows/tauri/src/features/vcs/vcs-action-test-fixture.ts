import { VcsRootController } from "./vcs-root-controller";
import type { VcsRootPort, VcsSnapshot, VcsStatusSnapshot } from "./vcs-root-types";
import type { VcsWriteAction, VcsWriteSnapshot } from "./vcs-action-types";
export async function actionFixture() {
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
        {
          vcs: "example",
          displayName: "Example VCS",
          origin: { kind: "plugin", pluginID: "fixture.plugin" },
        },
      ],
      roots: [{ id: "", vcs: "example", path: scope.workspaceRoot, mapped: false }],
      ambiguous: [],
      unusedMappings: [],
      truncated: false,
      rejected: [],
      conflicts: [],
    },
  };
  const calls: Array<{
    kind: string;
    id?: string;
    statusId?: string;
    action?: VcsWriteAction;
    root?: string;
  }> = [];
  const deadlines = new Set<() => void>();
  const writes = new Set<() => void>();
  const releases: Array<() => void> = [];
  const status = (id: string): VcsStatusSnapshot => ({
    requestId: id,
    generation: view.generation,
    rootId: "",
    vcs: "example",
    capabilities: { checkin: 1, rollback: 1, update: 1, history: 1 },
    result: {
      head: null,
      truncated: false,
      changes: [
        { path: "after.txt", oldPath: "before.txt", status: "renamed", flags: [] },
        { path: "new.txt", oldPath: null, status: "added", flags: [] },
        { path: "gone.txt", oldPath: null, status: "deleted", flags: [] },
        { path: "untracked.txt", oldPath: null, status: "unversioned", flags: [] },
      ],
    },
  });
  const result = (id: string, action: VcsWriteAction): VcsWriteSnapshot => ({
    requestId: id,
    generation: view.generation,
    rootId: "",
    vcs: "example",
    operation: action.operation,
    result: { revision: { display: "r2" }, conflicts: [] },
  });
  const schedule = (set: Set<() => void>) => (callback: () => void) => {
    set.add(callback);
    return () => {
      set.delete(callback);
    };
  };
  const port: VcsRootPort = {
    detect: async () => {
      calls.push({ kind: "detect" });
      return { ...view };
    },
    owners: async () => {
      throw new Error("unused");
    },
    close: async () => {},
    deadline: schedule(deadlines),
    writeDeadline: schedule(writes),
    status: async (_scope, _generation, root, id) => {
      calls.push({ kind: "status", id, root });
      return status(id);
    },
    write: async (_scope, _generation, root, id, statusId, action) => {
      calls.push({ kind: "write", id, statusId, root, action });
      return result(id, action);
    },
    cancelStatus: async (_scope, id) => {
      calls.push({ kind: "stop", id });
    },
    query: async (_scope, generation, rootId, requestId, query) => {
      calls.push({ kind: "query", root: rootId });
      return {
        requestId,
        generation,
        rootId,
        vcs: "example",
        operation: query.operation,
        result: { entries: [], nextCursor: null },
      };
    },
  };
  const controller = new VcsRootController(scope, port);
  await controller.refresh();
  await controller.status.refresh("");
  calls.length = 0;
  return {
    scope,
    view,
    controller,
    port,
    calls,
    deadlines,
    writes,
    status,
    result,
    deferred<T>(fallback: T) {
      let resolve!: (value: T) => void;
      const promise = new Promise<T>((yes) => {
        resolve = yes;
      });
      releases.push(() => resolve(fallback));
      return { promise, resolve };
    },
    async close() {
      for (const release of releases) release();
      port.cancelStatus = async () => {};
      await controller.close();
      if (deadlines.size || writes.size) throw new Error("test leaked deadline");
    },
  };
}
export async function flushActions() {
  for (let turn = 0; turn < 24; turn++) await Promise.resolve();
}
