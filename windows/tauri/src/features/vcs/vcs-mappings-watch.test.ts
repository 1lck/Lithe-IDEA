import { afterEach, expect, test } from "bun:test";
import { VcsRootController } from "./vcs-root-controller";
import type { VcsInvalidation, VcsRootPort, VcsSnapshot } from "./vcs-root-types";

const cleanup: Array<() => void | Promise<void>> = [];
const releases: Array<() => void> = [];
afterEach(async () => {
  for (const release of releases.splice(0)) release();
  for (const stop of cleanup.splice(0).reverse()) await stop();
});
async function flush() {
  for (let turn = 0; turn < 20; turn++) await Promise.resolve();
}
function gate<T>(fallback: T) {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((yes) => {
    resolve = yes;
  });
  releases.push(() => {
    resolve(fallback);
  });
  return { promise, resolve };
}
function fixture(incarnation = "one", workspaceId = "fixture") {
  const scope = { workspaceId, workspaceRoot: "C:/fixture/mapping", incarnation };
  let generation = 0;
  let changed: (event: VcsInvalidation) => void = () => {};
  let stops = 0;
  const timers = new Set<() => void>();
  const deadlines = new Set<() => void>();
  const saves: unknown[][] = [];
  const detects: number[] = [];
  let entries: Array<{ id: string; vcs: string }> = [];
  const snapshot = (): VcsSnapshot => ({
    ...scope,
    generation: ++generation,
    mappings: {
      source: "C:/fixture/app-data/vcs-roots/identity.json",
      revision: entries.length ? "saved-hash" : null,
      entries,
    },
    mappingChoices: [{ id: "mixed", vcs: ["git", "svn"] }],
    detection: {
      providers: [
        { vcs: "git", displayName: "Git", origin: { kind: "builtIn" } },
        {
          vcs: "svn",
          displayName: "Subversion",
          origin: { kind: "plugin", pluginID: "fixture.plugin" },
        },
      ],
      roots: entries.length
        ? [{ id: "mixed", vcs: entries[0].vcs, path: `${scope.workspaceRoot}/mixed`, mapped: true }]
        : [],
      ambiguous: entries.length ? [] : [{ id: "mixed", vcs: ["git", "svn"] }],
      unusedMappings: [],
      truncated: false,
      rejected: [],
      conflicts: [],
    },
  });
  const port: VcsRootPort = {
    detect: async () => {
      detects.push(generation + 1);
      return snapshot();
    },
    owners: async () => {
      throw new Error("not used");
    },
    close: async () => {},
    subscribe: async (_scope, onEvent) => {
      changed = onEvent;
      return () => {
        ++stops;
      };
    },
    debounce: (callback) => {
      timers.add(callback);
      return () => {
        timers.delete(callback);
      };
    },
    deadline: (callback) => {
      deadlines.add(callback);
      return () => {
        deadlines.delete(callback);
      };
    },
    saveMapping: async (...args) => {
      saves.push(args);
      entries = args[4] ? [{ id: args[3], vcs: args[4] }] : [];
    },
  };
  const roots = new VcsRootController(scope, port);
  cleanup.push(() => roots.close());
  const invalidate = () => changed({ workspaceId, incarnation, generation });
  const fire = () => {
    const pending = [...timers];
    timers.clear();
    for (const callback of pending) callback();
  };
  return {
    roots,
    port,
    saves,
    detects,
    timers,
    deadlines,
    invalidate,
    fire,
    snapshot,
    event: (event: VcsInvalidation) => changed(event),
    stops: () => stops,
  };
}

test("opening and editing are read-only; explicit save uses the frozen generation/source revision and reads back", async () => {
  const f = fixture();
  await f.roots.refresh();
  expect(f.saves).toEqual([]);
  const source = f.roots.getSnapshot().snapshot!;
  f.roots.mappings.edit("mixed", "svn");
  expect(f.saves).toEqual([]);
  await f.roots.mappings.save("mixed");
  expect(f.saves).toEqual([[f.roots.scope, source.generation, null, "mixed", "svn"]]);
  expect(f.roots.getSnapshot().snapshot?.mappings?.entries).toEqual([{ id: "mixed", vcs: "svn" }]);
  expect(f.roots.mappings.getSnapshot().drafts.size).toBe(0);
  expect(f.deadlines.size).toBe(0);
});

test("external conflict keeps its draft and never overwrites a newer mapping snapshot", async () => {
  const f = fixture();
  await f.roots.refresh();
  f.roots.mappings.edit("mixed", "svn");
  f.port.saveMapping = async () => {
    throw new Error("vcs.mapping.conflict");
  };
  await f.roots.mappings.save("mixed");
  expect(f.roots.mappings.getSnapshot().drafts.get("mixed")?.value).toBe("svn");
  expect(String(f.roots.mappings.getSnapshot().error)).toContain("vcs.mapping.conflict");
  await f.roots.refresh();
  f.port.saveMapping = async (...args) => {
    f.saves.push(args);
  };
  await f.roots.mappings.save("mixed");
  expect(f.saves).toHaveLength(0);
  expect(f.roots.mappings.getSnapshot().drafts.size).toBe(1);
  f.roots.mappings.cancel("mixed");
  expect(f.roots.mappings.getSnapshot().drafts.size).toBe(0);
});

test("a native metadata storm clears old roots/status immediately and schedules one passive scan", async () => {
  const f = fixture();
  await f.roots.refresh();
  let statusRequests = 0;
  f.port.status = async () => {
    ++statusRequests;
    throw new Error("must stay passive");
  };
  for (let index = 0; index < 2000; index++) f.invalidate();
  expect(f.roots.getSnapshot().snapshot).toBeNull();
  expect(f.roots.status.getSnapshot().snapshot).toBeNull();
  expect(f.timers.size).toBe(1);
  f.fire();
  await flush();
  expect(f.detects).toHaveLength(2);
  expect(statusRequests).toBe(0);
  expect(f.timers.size).toBe(0);
});

test("events during discovery wait for the owned scan before one trailing refresh", async () => {
  const f = fixture();
  await f.roots.refresh();
  const delayed = gate(f.snapshot());
  f.port.detect = async () => {
    f.detects.push(2);
    return delayed.promise;
  };
  f.invalidate();
  f.fire();
  await flush();
  for (let index = 0; index < 2000; index++) f.invalidate();
  expect(f.detects).toHaveLength(2);
  expect(f.timers.size).toBe(0);
  delayed.resolve(f.snapshot());
  await flush();
  expect(f.timers.size).toBe(1);
  f.port.detect = async () => {
    f.detects.push(3);
    return f.snapshot();
  };
  f.fire();
  await flush();
  expect(f.detects).toHaveLength(3);
});

test("an event during an existing manual scan does not start a second native discovery", async () => {
  const f = fixture();
  await f.roots.refresh();
  const delayed = gate(f.snapshot());
  f.port.detect = async () => {
    f.detects.push(2);
    return delayed.promise;
  };
  const manual = f.roots.refresh();
  cleanup.push(() => manual);
  await flush();
  f.invalidate();
  f.fire();
  await flush();
  expect(f.detects).toHaveLength(2);
  f.port.detect = async () => {
    f.detects.push(3);
    return f.snapshot();
  };
  delayed.resolve(f.snapshot());
  await manual;
  await flush();
  expect(f.detects).toHaveLength(3);
});

test("old generations, other windows and same-path old incarnations cannot clear a replacement snapshot", async () => {
  const f = fixture("reopened"),
    other = fixture("one", "other");
  await f.roots.refresh();
  await f.roots.refresh();
  await other.roots.refresh();
  const current = f.roots.getSnapshot().snapshot,
    separate = other.roots.getSnapshot().snapshot;
  f.event({ workspaceId: "fixture", incarnation: "one", generation: 100 });
  f.event({ workspaceId: "other", incarnation: "reopened", generation: 100 });
  f.event({ workspaceId: "fixture", incarnation: "reopened", generation: 1 });
  expect(f.roots.getSnapshot().snapshot).toBe(current);
  f.invalidate();
  expect(other.roots.getSnapshot().snapshot).toBe(separate);
});

test("close releases listeners/timers and a late subscription is disposed without restoring ownership", async () => {
  const f = fixture();
  await f.roots.refresh();
  f.invalidate();
  await f.roots.close();
  expect(f.stops()).toBe(1);
  expect(f.timers.size).toBe(0);
  f.invalidate();
  f.fire();
  await flush();
  expect(f.detects).toHaveLength(1);
  let stops = 0;
  const subscription = gate(() => {
    ++stops;
  });
  const roots = new VcsRootController(
    { ...f.roots.scope, incarnation: "late" },
    { ...f.port, subscribe: () => subscription.promise },
  );
  cleanup.push(() => roots.close());
  await roots.close();
  subscription.resolve(() => {
    ++stops;
  });
  await flush();
  expect(stops).toBe(1);
});

test("truncated roots and unknown mapping candidates cannot turn a draft into an execution grant", async () => {
  const f = fixture();
  await f.roots.refresh();
  f.roots.mappings.edit("outside", "svn");
  f.roots.mappings.edit("mixed", "unknown");
  expect(f.roots.mappings.getSnapshot().drafts.size).toBe(0);
  f.roots.getSnapshot().snapshot!.detection.truncated = true;
  f.roots.mappings.edit("mixed", "svn");
  expect(f.roots.mappings.getSnapshot().drafts.size).toBe(0);
  expect(f.saves).toHaveLength(0);
});

test("a successful manual refresh cancels the old queued hint before a user can read new status", async () => {
  const f = fixture();
  await f.roots.refresh();
  f.invalidate();
  expect(f.timers.size).toBe(1);
  await f.roots.refresh();
  const current = f.roots.getSnapshot().snapshot;
  expect(f.timers.size).toBe(0);
  f.fire();
  await flush();
  expect(f.roots.getSnapshot().snapshot).toBe(current);
  expect(f.detects).toHaveLength(2);
});
