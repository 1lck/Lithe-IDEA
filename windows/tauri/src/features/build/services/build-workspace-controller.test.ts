import { expect, spyOn, test } from "bun:test";
import { BuildWorkspaceController } from "./build-workspace-controller";
import { BuildWorkspaceOwner } from "./build-workspace-owner";
import { WindowsBuildProviderWorkspace } from "./build-provider-workspace";
import type { WindowsBuildCatalog } from "@/platform/build-provider-platform";

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(complete => { resolve = complete; });
  return { promise, resolve };
}
function catalog(pluginID = "dev.example.build"): WindowsBuildCatalog {
  return { detection: { instances: [{ pluginID, buildSystemID: "example", id: pluginID + ":root", root: ".",
    displayName: "Example", modelSource: "provider", options: { features: [] }, optionFingerprint: "chosen",
    droppedOptions: [] }], rejected: [], shadowed: [] }, plugins: [{ manifest: { id: pluginID } }], document: { version: 1, systems: {} } };
}
function fixture() {
  const stopped: string[] = [], revisions = new Map<string, number>();
  const scheduled = new Set<() => Promise<void>>();
  const guard = () => { const captured = new Map(revisions); return (plugin: string) => {
    if ((captured.get(plugin) ?? 0) !== (revisions.get(plugin) ?? 0)) throw new Error("revoked");
  }; };
  const domain = new WindowsBuildProviderWorkspace("C:/work", {
    core: async () => { throw new Error("detection must not query a Provider"); },
    providers: { send: async () => { throw new Error("detection must not launch a Provider"); }, stop: async target => { stopped.push(target.pluginId); } },
    tools: async () => { throw new Error("detection must not probe tools"); }, guard, translate: key => key,
  });
  let detect = async () => catalog();
  const controller = new BuildWorkspaceController("C:/work", { domain, guard, detect: () => detect(),
    scheduleRefresh: callback => { scheduled.add(callback); return () => { scheduled.delete(callback); }; },
  });
  return { controller, domain, stopped, scheduled,
    refreshScheduled: async () => { const callbacks = [...scheduled]; scheduled.clear(); await Promise.all(callbacks.map(callback => callback())); },
    detect: (next: typeof detect) => { detect = next; }, revoke: (id: string) => revisions.set(id, (revisions.get(id) ?? 0) + 1) };
}

test("team-file notifications revoke the catalog immediately, coalesce reads and never launch tools", async () => {
  const f = fixture();
  try {
    await f.controller.refresh();
    f.controller.filesChanged("C:/work/.lithe/build/options.json");
    expect(f.controller.snapshot()).toMatchObject({ status: "loading", entries: [], manifests: {} });
    f.controller.filesChanged("C:/work/.lithe/build/options.json"); expect(f.scheduled.size).toBe(1);
    await f.refreshScheduled();
    expect(f.controller.snapshot().entries).toHaveLength(1); expect(f.domain.operations()).toEqual([]);
    f.controller.filesChanged("C:/other/.lithe/build/options.json"); expect(f.scheduled.size).toBe(0);
    f.controller.filesChanged("C:/work/.lithe/build/options.json"); expect(f.scheduled.size).toBe(1);
  } finally { await f.controller.dispose(); }
  expect(f.scheduled.size).toBe(0);
}, 5000);

test("a change during detection prevents its older catalog from publishing before the scheduled read", async () => {
  const f = fixture(), old = deferred<WindowsBuildCatalog>(); f.detect(() => old.promise);
  const detecting = f.controller.refresh();
  try {
    f.controller.filesChanged("C:/work/.lithe/build/options.json");
    old.resolve(catalog()); await detecting;
    expect(f.controller.snapshot().entries).toEqual([]);
    f.detect(async () => catalog("dev.replacement.build")); await f.refreshScheduled();
    expect(f.controller.snapshot().entries[0]?.pluginID).toBe("dev.replacement.build");
    expect(f.domain.operations()).toEqual([]);
  } finally { old.resolve(catalog()); await detecting; await f.controller.dispose(); }
}, 5000);

test("catalog selection preserves Core's explicit empty options without launching tools", async () => {
  const f = fixture();
  try {
    await f.controller.refresh();
    expect(f.controller.snapshot()).toMatchObject({ status: "ready", selectedID: "dev.example.build:root", entries: [{ options: { features: [] } }] });
    expect(f.domain.operations()).toEqual([]);
  } finally { await f.controller.dispose(); }
}, 5000);

test("parallel Run consumers share detection while a newer file generation starts a fresh read", async () => {
  const f = fixture(), first = deferred<WindowsBuildCatalog>(); let reads = 0;
  f.detect(async () => { reads++; return await first.promise; });
  const a = f.controller.ensureDetected(), b = f.controller.ensureDetected();
  try {
    expect(a).toBe(b); expect(reads).toBe(1);
    f.controller.filesChanged("C:/work/.lithe/build/options.json");
    f.detect(async () => { reads++; return catalog("dev.current.build"); });
    await f.controller.ensureDetected(); expect(reads).toBe(2);
    first.resolve(catalog()); await a;
    expect(f.controller.snapshot().entries[0]?.pluginID).toBe("dev.current.build");
    await f.controller.ensureDetected(); expect(reads).toBe(2);
    expect(f.domain.operations()).toEqual([]);
  } finally { first.resolve(catalog()); await Promise.allSettled([a, b]); await f.controller.dispose(); }
}, 5000);

test("an older detection cannot replace a newer catalog or republish a revoked declaration", async () => {
  const f = fixture(), old = deferred<WindowsBuildCatalog>();
  f.detect(() => old.promise);
  const first = f.controller.refresh();
  try {
    f.detect(async () => catalog("dev.other.build"));
    await f.controller.refresh();
    old.resolve(catalog()); await first;
    expect(f.controller.snapshot().entries.map(entry => entry.pluginID)).toEqual(["dev.other.build"]);
    const pending = deferred<WindowsBuildCatalog>(); f.detect(() => pending.promise);
    const refreshing = f.controller.refresh();
    f.revoke("dev.other.build"); pending.resolve(catalog("dev.other.build")); await refreshing;
    expect(f.controller.snapshot().entries).toEqual([]);
  } finally { old.resolve(catalog()); await first; await f.controller.dispose(); }
}, 5000);

test("late action errors do not contaminate a refreshed selection", async () => {
  const f = fixture(), completed = deferred<void>();
  try {
    await f.controller.refresh();
    const old = f.controller.perform(f.controller.snapshot().entries[0]!, () => ({ operationID: "old", completion: completed.promise.then(() => { throw new Error("stale failure"); }) }));
    await f.controller.refresh(); completed.resolve(); await old;
    expect(f.controller.snapshot().error).toBeUndefined();
    expect(f.controller.snapshot().status).toBe("ready");
  } finally { completed.resolve(); await f.controller.dispose(); }
}, 5000);

test("a successful action from an older catalog cannot return a usable stale result", async () => {
  const f = fixture(), completed = deferred<string>();
  try {
    await f.controller.refresh();
    const old = f.controller.perform(f.controller.snapshot().entries[0]!, () => ({ operationID: "old", completion: completed.promise }));
    await f.controller.refresh(); completed.resolve("stale facts");
    expect(await old).toBeUndefined();
    expect(f.controller.snapshot().status).toBe("ready");
  } finally { completed.resolve("released"); await f.controller.dispose(); }
}, 5000);

test("plugin revocation removes its catalog immediately and propagates cleanup failure", async () => {
  const f = fixture(), stopping = deferred<void>();
  const stop = spyOn(f.domain, "stopPlugin").mockImplementation(async () => { await stopping.promise; throw new Error("still running"); });
  try {
    await f.controller.refresh();
    const result = f.controller.revokePlugin("dev.example.build").catch(error => error.message);
    expect(f.controller.snapshot().entries).toEqual([]);
    stopping.resolve(); expect(await result).toBe("still running");
  } finally { stopping.resolve(); stop.mockRestore(); await f.controller.dispose(); }
}, 5000);

test("close drains an outstanding detection even when domain disposal fails", async () => {
  const f = fixture(), detection = deferred<WindowsBuildCatalog>(), stopped = deferred<void>();
  f.detect(() => detection.promise);
  const refreshing = f.controller.refresh();
  const dispose = spyOn(f.domain, "dispose").mockImplementation(async () => { stopped.resolve(); throw new Error("cleanup failed"); });
  let closed = false;
  const closing = f.controller.dispose().catch(error => { closed = true; return error.message; });
  try {
    await stopped.promise;
    expect(closed).toBe(false);
    detection.resolve(catalog()); await refreshing;
    expect(await closing).toBe("cleanup failed");
    expect(f.controller.snapshot()).toMatchObject({ status: "idle", entries: [] });
  } finally { detection.resolve(catalog()); await closing; dispose.mockRestore(); await f.controller.dispose(); }
}, 5000);

test("workspace owner reuses hidden-pane state and blocks reopening until cleanup succeeds", async () => {
  const f = fixture(), gate = deferred<void>(); let attempts = 0, creates = 0;
  const dispose = spyOn(f.controller, "dispose").mockImplementation(async () => { attempts++; await gate.promise; if (attempts === 1) throw new Error("cleanup failed"); });
  const owner = new BuildWorkspaceOwner(() => { creates++; return f.controller; });
  try {
    expect(owner.get("project", "C:/work")).toBe(f.controller);
    expect(owner.get("project", "C:/work")).toBe(f.controller);
    const closing = owner.close("project"), result = closing.catch(error => error.message);
    expect(owner.close("project")).toBe(closing);
    expect(owner.get("project", "C:/work")).toBeUndefined();
    gate.resolve(); expect(await result).toBe("cleanup failed");
    expect(owner.get("project", "C:/replacement")).toBeUndefined();
    expect(creates).toBe(1);
    await owner.close("project");
    expect(attempts).toBe(2);
    expect(owner.get("project", "C:/replacement")).toBe(f.controller);
    expect(creates).toBe(2);
  } finally { gate.resolve(); dispose.mockRestore(); await owner.close("project"); }
}, 5000);

test("plugin stop drains every owned workspace before reporting any failure", async () => {
  const a = fixture(), b = fixture(), gate = deferred<void>(), entered = deferred<void>();
  const first = spyOn(a.controller, "revokePlugin").mockRejectedValue(new Error("first failed"));
  const second = spyOn(b.controller, "revokePlugin").mockImplementation(async () => { entered.resolve(); await gate.promise; });
  const owner = new BuildWorkspaceOwner(path => path === "C:/a" ? a.controller : b.controller);
  owner.get("a", "C:/a"); owner.get("b", "C:/b");
  let finished = false;
  const stopping = owner.stopPlugin("dev.example.build").catch(error => { finished = true; return error; });
  try {
    await entered.promise; expect(finished).toBe(false);
    gate.resolve(); expect((await stopping).causes).toHaveLength(1);
    expect(first).toHaveBeenCalledWith("dev.example.build");
    expect(second).toHaveBeenCalledWith("dev.example.build");
  } finally { gate.resolve(); await stopping; first.mockRestore(); second.mockRestore(); await owner.close("a"); await owner.close("b"); }
}, 5000);
