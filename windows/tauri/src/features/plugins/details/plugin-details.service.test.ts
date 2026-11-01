import { describe, expect, mock, test } from "bun:test";
import type { PluginDetailsService } from "./plugin-details.service";
import type {
  PluginDetailsModel,
  PluginDetailsSelection,
  PluginDetailsState,
} from "./plugin-details.types";

mock.module("@/platform/tauri-core", () => ({ invoke: mock(async () => null) }));
mock.module("../declarative-plugin-launch", () => ({
  rollbackDeclarativePlugin: mock(async () => {}),
  setDeclarativePluginEnabled: mock(async () => {}),
  uninstallDeclarativePlugin: mock(async () => {}),
}));

const { PluginDetailsSession } = await import("./plugin-details.service");

interface Deferred<T> {
  promise: Promise<T>;
  resolve: (value: T) => void;
  reject: (reason: unknown) => void;
}

function deferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((accept, decline) => {
    resolve = accept;
    reject = decline;
  });
  return { promise, resolve, reject };
}

function model(pluginId: string, source: "bundled" | "installed" = "installed"): PluginDetailsModel {
  return {
    identity: { pluginId, source, version: "1.0.0" },
    displayName: pluginId,
    vendorName: null,
    description: null,
    localizedDescriptions: {},
    apiVersion: 1,
    enabled: true,
    status: "accepted",
    rejection: null,
    settings: [],
    primaryLanguageId: null,
    features: [],
    permissions: [],
    programs: [],
    versions: {
      current: {
        version: "1.0.0",
        origin: source === "bundled" ? "bundled" : "community",
        channel: source === "bundled" ? "bundled" : "disk",
        sourceId: null,
        sourceName: null,
        repository: null,
        fileName: null,
        archiveSha256: null,
        contentDigest: null,
        verification: { status: source === "bundled" ? "hostSeal" : "approvedDigest", keyId: null },
      },
      previous: null,
      updateStatus: "unknown",
    },
    operations: { canSetEnabled: source === "installed", canUninstall: source === "installed", canRollback: false },
  };
}

function fixture(load: PluginDetailsService["load"]) {
  const states: PluginDetailsState[] = [];
  const service: PluginDetailsService = {
    load,
    setEnabled: mock(async () => {}),
    uninstall: mock(async () => {}),
    rollback: mock(async () => {}),
  };
  const changed = mock(() => {});
  return { states, service, changed, session: new PluginDetailsSession(service, (state) => states.push(state), changed) };
}

async function flushMicrotasks() {
  await Promise.resolve();
  await Promise.resolve();
}

describe("plugin detail session ownership", () => {
  test("a late success from the old plugin cannot replace the new selection", async () => {
    const first = deferred<PluginDetailsModel>();
    const second = deferred<PluginDetailsModel>();
    const f = fixture(({ pluginId }) => pluginId === "first" ? first.promise : second.promise);
    f.session.select({ pluginId: "first", source: "installed" }, "C:/one");
    f.session.select({ pluginId: "second", source: "installed" }, "C:/two");
    second.resolve(model("second"));
    await flushMicrotasks();
    const ready = f.states[f.states.length - 1];
    expect(ready?.phase).toBe("ready");
    if (ready?.phase === "ready") expect(ready.details.identity.pluginId).toBe("second");
    const count = f.states.length;
    first.resolve(model("first"));
    await flushMicrotasks();
    expect(f.states).toHaveLength(count);
  });

  test("a late failure and a same-plugin result from the old workspace are ignored", async () => {
    const first = deferred<PluginDetailsModel>();
    const second = deferred<PluginDetailsModel>();
    let call = 0;
    const f = fixture(() => (++call === 1 ? first.promise : second.promise));
    const selected: PluginDetailsSelection = { pluginId: "same", source: "installed" };
    f.session.select(selected, "C:/old");
    f.session.select(selected, "C:/new");
    first.reject(new Error("old workspace failed"));
    second.resolve(model("same"));
    await flushMicrotasks();
    expect(f.states.some((state) => state.phase === "failed")).toBe(false);
    const last = f.states[f.states.length - 1];
    expect(last?.phase).toBe("ready");
    if (last?.phase === "ready") expect(last.workspacePath).toBe("C:/new");
  });

  test("disposing the panel suppresses every pending write", async () => {
    const request = deferred<PluginDetailsModel>();
    const f = fixture(() => request.promise);
    f.session.select({ pluginId: "closing", source: "installed" }, null);
    const count = f.states.length;
    f.session.dispose();
    request.resolve(model("closing"));
    await flushMicrotasks();
    expect(f.states).toHaveLength(count);
  });

  test("an operation failure stays on the captured plugin and is actionable", async () => {
    const f = fixture(async () => model("broken"));
    f.service.setEnabled = mock(async () => { throw new Error("could not stop the language server"); });
    const selected: PluginDetailsSelection = { pluginId: "broken", source: "installed" };
    f.session.select(selected, "C:/work");
    await flushMicrotasks();
    await f.session.perform("disable", model("broken"));
    const last = f.states[f.states.length - 1];
    expect(last?.phase).toBe("ready");
    if (last?.phase === "ready") {
      expect(last.selection.pluginId).toBe("broken");
      expect(last.error).toContain("could not stop");
      expect(last.operation).toBeNull();
    }
    expect(f.changed).not.toHaveBeenCalled();
  });

  test("an operation completion cannot reload or publish after selection changes", async () => {
    const operation = deferred<void>();
    const f = fixture(async ({ pluginId }) => model(pluginId));
    f.service.setEnabled = mock(() => operation.promise);
    const first: PluginDetailsSelection = { pluginId: "first", source: "installed" };
    f.session.select(first, "C:/one");
    await flushMicrotasks();
    const pending = f.session.perform("disable", model("first"));
    f.session.select({ pluginId: "second", source: "installed" }, "C:/two");
    await flushMicrotasks();
    operation.resolve();
    await pending;
    const last = f.states[f.states.length - 1];
    expect(last?.phase).toBe("ready");
    if (last?.phase === "ready") expect(last.details.identity.pluginId).toBe("second");
    expect(f.changed).not.toHaveBeenCalled();
  });

  test("successful uninstall clears details without requesting the removed package", async () => {
    const load = mock(async () => model("removed"));
    const f = fixture(load);
    f.session.select({ pluginId: "removed", source: "installed" }, "C:/work");
    await flushMicrotasks();
    await f.session.perform("uninstall", model("removed"));
    expect(f.service.uninstall).toHaveBeenCalledWith("removed");
    expect(load).toHaveBeenCalledTimes(1);
    expect(f.states[f.states.length - 1]?.phase).toBe("idle");
    expect(f.changed).toHaveBeenCalledTimes(1);
  });
});
