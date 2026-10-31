import { expect, test } from "bun:test";
import { BuildModelPreparationOwner } from "./build-model-preparation-owner";
import type { BuildInstance, BuildModel } from "./build-provider-workspace";

const instance: BuildInstance = { pluginID: "dev.example.build", buildSystemID: "example", root: ".", options: {} };
function fixture() {
  let current = false;
  const loads: Array<{ instance: BuildInstance; resolve: (model: BuildModel) => void; reject: (error: unknown) => void }> = [], cancelled: string[] = [];
  const owner = new BuildModelPreparationOwner({ hasCurrentModel: () => current,
    loadModel: selected => {
      let resolve!: (value: BuildModel) => void, reject!: (error: unknown) => void;
      const completion = new Promise<BuildModel>((done, failed) => { resolve = done; reject = failed; });
      loads.push({ instance: selected, resolve, reject }); return { operationID: String(loads.length - 1), completion };
    },
    cancel: id => { cancelled.push(id); loads[Number(id)]?.reject(new Error("revoked")); return true; },
  });
  return { owner, loads, cancelled, current: () => { current = true; },
    finish: (index: number) => loads[index]!.resolve({ projects: [], targets: [], tasks: [], contentRoots: [], optionValues: {} }),
    close: () => { owner.dispose(); loads.forEach(load => load.reject(new Error("closed"))); } };
}

test("parallel services share preparation while one cancellation leaves the other waiter alive", async () => {
  const f = fixture(), first = new AbortController(), second = new AbortController();
  const a = f.owner.ensure(instance, first.signal).catch(() => "cancelled"), b = f.owner.ensure(instance, second.signal);
  try {
    expect(f.loads).toHaveLength(1); first.abort(); expect(await a).toBe("cancelled"); expect(f.cancelled).toEqual([]);
    f.finish(0); await b; expect(f.cancelled).toEqual([]);
    f.current(); await f.owner.ensure(instance, second.signal); expect(f.loads).toHaveLength(1);
  } finally { first.abort(); second.abort(); f.close(); await Promise.allSettled([a, b]); }
}, 5000);

test("the last departing waiter cancels unused project preparation", async () => {
  const f = fixture(), a = new AbortController(), b = new AbortController();
  const first = f.owner.ensure(instance, a.signal).catch(() => "cancelled"), second = f.owner.ensure(instance, b.signal).catch(() => "cancelled");
  try { a.abort(); b.abort(); await Promise.all([first, second]); expect(f.cancelled).toEqual(["0"]); }
  finally { a.abort(); b.abort(); f.close(); await Promise.allSettled([first, second]); }
}, 5000);

test("option ABA replaces only its old preparation and late settlement cannot remove the newest load", async () => {
  const f = fixture(), controller = new AbortController();
  const first = f.owner.ensure(instance, controller.signal).catch(() => "old");
  const changed = f.owner.ensure({ ...instance, options: { features: ["other"] } }, controller.signal).catch(() => "old");
  const latest = f.owner.ensure(instance, controller.signal);
  const shared = f.owner.ensure(instance, controller.signal);
  try {
    await Promise.all([first, changed]); expect(f.loads).toHaveLength(3); expect(f.cancelled).toEqual(["0", "1"]);
    f.finish(0); f.finish(1); f.finish(2); await Promise.all([latest, shared]);
  } finally { controller.abort(); f.close(); await Promise.allSettled([first, changed, latest, shared]); }
}, 5000);

test("workspace retirement cancels owned preparation and refuses fresh waits", async () => {
  const f = fixture(), controller = new AbortController();
  const pending = f.owner.ensure(instance, controller.signal).catch(() => "retired");
  try {
    f.owner.dispose(); expect(await pending).toBe("retired"); expect(f.cancelled).toEqual(["0"]);
    await expect(f.owner.ensure(instance, controller.signal)).rejects.toThrow("Aborted");
  } finally { controller.abort(); f.close(); await pending; }
}, 5000);
