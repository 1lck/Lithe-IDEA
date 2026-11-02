import { afterEach, expect, test } from "bun:test";
import { VcsRootController } from "./vcs-root-controller";
import type { VcsRootPort, VcsSnapshot } from "./vcs-root-types";
import type { VcsQuerySnapshot, VcsReadQuery } from "./vcs-query-types";

const cleanups: Array<() => void | Promise<void>> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

function fixture() {
  const scope = { workspaceId: "fixture", workspaceRoot: "C:/fixture", incarnation: "one" };
  const view: VcsSnapshot = {
    generation: 4,
    workspaceId: scope.workspaceId,
    workspaceRoot: scope.workspaceRoot,
    detection: {
      providers: [
        {
          vcs: "svn",
          displayName: "Subversion",
          origin: { kind: "plugin", pluginID: "fixture.plugin" },
        },
      ],
      roots: [{ id: "legacy", vcs: "svn", path: "C:/fixture/legacy", mapped: false }],
      ambiguous: [],
      unusedMappings: [],
      truncated: false,
      rejected: [],
      conflicts: [],
    },
  };
  const calls: VcsReadQuery[] = [];
  const port: VcsRootPort = {
    detect: async () => view,
    owners: async () => {
      throw new Error("unused");
    },
    close: async () => {},
    deadline: () => () => {},
    statusDeadline: () => () => {},
    status: async () => {
      throw new Error("unused");
    },
    cancelStatus: async () => {},
    query: async (_scope, generation, rootId, requestId, query): Promise<VcsQuerySnapshot> => {
      calls.push(query);
      if (query.operation === "baseContent") {
        return {
          requestId,
          generation,
          rootId,
          vcs: "svn",
          operation: "baseContent",
          result: {
            path: query.path,
            currentPath: query.currentPath,
            content: "base\n",
            binary: false,
            currentContent: "current\n",
            currentBinary: false,
          },
        };
      }
      const first = query.cursor === null;
      return {
        requestId,
        generation,
        rootId,
        vcs: "svn",
        operation: query.operation,
        result: {
          entries: [
            {
              revision: { id: first ? "2" : "1", display: first ? "r2" : "r1", kind: "number" },
              author: "a",
              date: null,
              message: first ? "new" : "old",
              changes: [],
              changesTruncated: false,
            },
          ],
          nextCursor: first ? "cursor-1" : null,
        },
      };
    },
  };
  const controller = new VcsRootController(scope, port);
  cleanups.push(async () => {
    port.cancelStatus = async () => {};
    await controller.close();
  });
  return { controller, port, calls, view };
}

test("history pages retain provider order and opaque cursor, then stop at the end", async () => {
  const f = fixture();
  await f.controller.refresh();
  await f.controller.query.history("legacy");
  expect(f.controller.query.getSnapshot().entries.map((entry) => entry.revision.id)).toEqual(["2"]);
  expect(f.controller.query.getSnapshot().nextCursor).toBe("cursor-1");
  await f.controller.query.more();
  expect(f.controller.query.getSnapshot().entries.map((entry) => entry.revision.id)).toEqual([
    "2",
    "1",
  ]);
  expect(f.calls.map((query) => query.operation)).toEqual(["history", "history"]);
  expect(f.calls[1]).toMatchObject({ cursor: "cursor-1", limit: 50 });
});

test("baseline comparison publishes only the matching source and current path", async () => {
  const f = fixture();
  await f.controller.refresh();
  const values: string[] = [];
  await f.controller.query.compare("legacy", "deleted.txt", "renamed.txt", (result) => {
    values.push(`${result.path}:${result.currentPath}:${result.content}:${result.currentContent}`);
  });
  expect(values).toEqual(["deleted.txt:renamed.txt:base\n:current\n"]);
  expect(f.calls[0]).toEqual({
    operation: "baseContent",
    path: "deleted.txt",
    currentPath: "renamed.txt",
  });
});

test("root invalidation cancels a pending history owner and clears its cursor", async () => {
  const f = fixture();
  await f.controller.refresh();
  let release!: (value: VcsQuerySnapshot) => void;
  f.port.query = () =>
    new Promise((resolve) => {
      release = resolve;
    });
  const fallback: VcsQuerySnapshot = {
    requestId: "late",
    generation: 4,
    rootId: "legacy",
    vcs: "svn",
    operation: "history",
    result: { entries: [], nextCursor: null },
  };
  cleanups.push(() => release(fallback));
  const pending = f.controller.query.history("legacy");
  await Promise.resolve();
  f.controller.invalidate();
  release(fallback);
  await pending;
  expect(f.controller.query.getSnapshot().entries).toEqual([]);
  expect(f.controller.query.getSnapshot().nextCursor).toBeNull();
});

test("a repeated provider cursor stops pagination without another request", async () => {
  const f = fixture();
  await f.controller.refresh();
  const original = f.port.query!;
  f.port.query = async (...args) => {
    const answer = await original(...args);
    if (answer.operation !== "baseContent") answer.result = { entries: [], nextCursor: "repeated" };
    return answer;
  };
  await f.controller.query.history("legacy");
  await f.controller.query.more();
  expect(f.controller.query.getSnapshot().phase).toBe("failed");
  expect(String(f.controller.query.getSnapshot().error)).toContain("vcs.history.cursorRepeated");
  expect(f.controller.query.getSnapshot().nextCursor).toBeNull();
  await f.controller.query.more();
  expect(f.calls).toHaveLength(2);
});

test("empty history pages with fresh cursors still exhaust a bounded page budget", async () => {
  const f = fixture();
  await f.controller.refresh();
  let pages = 0;
  f.port.query = async (_scope, generation, rootId, requestId, query) => ({
    requestId,
    generation,
    rootId,
    vcs: "svn",
    operation: query.operation,
    result: { entries: [], nextCursor: `next-${++pages}` },
  });
  await f.controller.query.history("legacy");
  for (let index = 0; index < 30; index++) await f.controller.query.more();
  expect(pages).toBe(20);
  expect(f.controller.query.getSnapshot().limited).toBe(true);
});

test("history stops at its retained entry budget while preserving provider order", async () => {
  const f = fixture();
  await f.controller.refresh();
  let entries = 0;
  f.port.query = async (_scope, generation, rootId, requestId, query) => {
    if (query.operation === "baseContent") throw new Error("unexpected baseline read");
    return {
      requestId,
      generation,
      rootId,
      vcs: "svn",
      operation: query.operation,
      result: {
        entries: Array.from({ length: query.limit }, () => ({
          revision: { id: `${++entries}`, display: `${entries}`, kind: "opaque" },
          author: null,
          date: null,
          message: "",
          changes: [],
          changesTruncated: false,
        })),
        nextCursor: `next-${entries}`,
      },
    };
  };
  await f.controller.query.history("legacy");
  for (let index = 0; index < 20; index++) await f.controller.query.more();
  const state = f.controller.query.getSnapshot();
  expect(entries).toBe(500);
  expect(state.entries).toHaveLength(500);
  expect(state.entries[0].revision.id).toBe("1");
  expect(state.entries[499].revision.id).toBe("500");
  expect(state.limited).toBe(true);
});

test("failed query cleanup blocks new reads and retries the same owner before replacement", async () => {
  const f = fixture();
  await f.controller.refresh();
  const original = f.port.query!;
  let release!: (reply: VcsQuerySnapshot) => void;
  const pending = new Promise<VcsQuerySnapshot>((resolve) => {
    release = resolve;
  });
  const late: VcsQuerySnapshot = {
    requestId: "late",
    generation: 4,
    rootId: "legacy",
    vcs: "svn",
    operation: "history",
    result: { entries: [], nextCursor: null },
  };
  cleanups.push(() => release(late));
  f.port.query = () => pending;
  const reading = f.controller.query.history("legacy");
  await Promise.resolve();
  let rejectCleanup = true;
  const ids: string[] = [];
  f.port.cancelStatus = async (_scope, id) => {
    ids.push(id);
    if (rejectCleanup) throw new Error("vcs.provider.cleanupFailed");
  };
  await expect(f.controller.query.cancel()).rejects.toThrow("vcs.provider.cleanupFailed");
  expect(f.controller.query.getSnapshot().phase).toBe("cancelFailed");
  f.port.query = original;
  await f.controller.query.history("legacy");
  expect(f.calls).toEqual([]);
  rejectCleanup = false;
  await f.controller.query.cancel();
  await reading;
  expect(ids).toHaveLength(2);
  expect(ids[0]).toBe(ids[1]);
  await f.controller.query.history("legacy");
  release(late);
  await Promise.resolve();
  expect(f.controller.query.getSnapshot().entries[0].revision.id).toBe("2");
  expect(f.controller.query.busy).toBe(false);
});
