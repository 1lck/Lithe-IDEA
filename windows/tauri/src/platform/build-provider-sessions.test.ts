import { describe, expect, test } from "bun:test";
import { WindowsBuildProviderSessions, type BuildProviderLaunch } from "./build-provider-sessions";
import type { CoreBuildProviderTarget } from "./lsp-core-adapter";

const target = { workspacePath: "C:/work", pluginId: "dev.example.build", buildSystemId: "example" };
const request = { method: "lithe/build/model", params: {}, timeoutMilliseconds: 1000 };
const launch: BuildProviderLaunch = { pluginId: target.pluginId, buildSystemId: target.buildSystemId,
  identity: { package: "version1", settings: {} }, serverPath: "C:/provider.exe", serverArgs: [], environment: {} };

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(complete => { resolve = complete; });
  return { promise, resolve };
}

function fixture() {
  const calls: Array<{ operation: string; target: CoreBuildProviderTarget }> = [];
  let current = launch, revision = 0, stopFailure = false;
  let resolveGate: Promise<BuildProviderLaunch> | undefined;
  const entered = deferred<void>();
  const pool = new WindowsBuildProviderSessions({
    resolve: async target => { calls.push({ operation: "resolve", target }); entered.resolve(); return await resolveGate ?? current; },
    start: async target => { calls.push({ operation: "start", target }); },
    stop: async target => { calls.push({ operation: "stop", target }); if (stopFailure) throw new Error("process still owns package"); },
    request: async <T>(target: CoreBuildProviderTarget) => { calls.push({ operation: "request", target }); return { projects: [] } as T; },
    guard: () => { const generation = revision; return () => { if (revision !== generation) throw new Error("plugin changed"); }; },
  });
  return { pool, calls, entered, setLaunch: (value: BuildProviderLaunch) => { current = value; },
    holdResolve: (value: Promise<BuildProviderLaunch>) => { resolveGate = value; },
    revoke: () => { revision += 1; }, failStop: (value: boolean) => { stopFailure = value; } };
}

describe("Windows Build Provider launch ownership", () => {
  test("only changed package or effective settings replace a target's process", async () => {
    const f = fixture();
    await f.pool.send(target, request);
    await f.pool.send({ ...target, workspacePath: "c:\\WORK" }, request);
    expect(f.calls.filter(call => call.operation === "stop")).toHaveLength(0);
    f.setLaunch({ ...launch, identity: { package: "version1", settings: { heap: "2g" } } });
    await f.pool.send(target, request);
    expect(f.calls.map(call => call.operation)).toEqual(["resolve", "start", "request", "resolve", "start", "request", "resolve", "stop", "start", "request"]);
  }, 5000);

  test("cancellation stops waiting for native resolution without losing ownership of its late reply", async () => {
    const f = fixture(), gate = deferred<BuildProviderLaunch>(), controller = new AbortController();
    f.holdResolve(gate.promise);
    const sent = f.pool.send(target, { ...request, signal: controller.signal }).then(() => "sent", () => "cancelled");
    try {
      await f.entered.promise;
      controller.abort();
      expect(await sent).toBe("cancelled");
      const stopped = f.pool.stop(target);
      gate.resolve(launch);
      await stopped;
      expect(f.calls.filter(call => call.operation === "start" || call.operation === "request")).toHaveLength(0);
    } finally { gate.resolve(launch); await f.pool.stop(target); await sent; }
  }, 5000);

  test("a plugin mutation during native resolution never starts or requests its stale package", async () => {
    const f = fixture(), gate = deferred<BuildProviderLaunch>();
    f.holdResolve(gate.promise);
    const sent = f.pool.send(target, request).then(() => "sent", () => "revoked");
    try {
      await f.entered.promise; f.revoke(); gate.resolve(launch);
      expect(await sent).toBe("revoked");
      expect(f.calls.map(call => call.operation)).toEqual(["resolve"]);
    } finally { gate.resolve(launch); await sent; }
  }, 5000);

  test("a target stopped while resolving cannot publish a late launch", async () => {
    const f = fixture(), gate = deferred<BuildProviderLaunch>();
    f.holdResolve(gate.promise);
    const sent = f.pool.send(target, request).then(() => "sent", () => "cancelled");
    let stopping: Promise<void> | undefined;
    try {
      await f.entered.promise; stopping = f.pool.stop(target); gate.resolve(launch);
      await stopping;
      expect(await sent).toBe("cancelled");
      expect(f.calls.filter(call => call.operation === "start" || call.operation === "request")).toHaveLength(0);
    } finally { gate.resolve(launch); await Promise.allSettled([sent, stopping]); }
  }, 5000);

  test("mismatched native identity is rejected before creating a process", async () => {
    const f = fixture(); f.setLaunch({ ...launch, buildSystemId: "other" });
    await expect(f.pool.send(target, request)).rejects.toThrow("another Build Provider");
    expect(f.calls.map(call => call.operation)).toEqual(["resolve"]);
  }, 5000);

  test("cleanup failure blocks new requests until an explicit cleanup retry succeeds", async () => {
    const f = fixture(); await f.pool.send(target, request); f.failStop(true);
    await expect(f.pool.stop(target)).rejects.toThrow("still owns package");
    const before = f.calls.length;
    await expect(f.pool.send(target, request)).rejects.toMatchObject({ code: "cancelled" });
    expect(f.calls).toHaveLength(before);
    f.failStop(false); await f.pool.stop(target);
    expect(await f.pool.send<{ projects: unknown[] }>(target, request)).toEqual({ projects: [] });
  }, 5000);

  test("a second target's input changes never stop the first target", async () => {
    const f = fixture(), other = { ...target, workspacePath: "C:/other" };
    await f.pool.send(target, request); await f.pool.send(other, request);
    f.setLaunch({ ...launch, identity: { package: "version2" } });
    await f.pool.send(other, request);
    expect(f.calls.filter(call => call.operation === "stop").map(call => call.target.workspacePath)).toEqual(["C:/other"]);
  }, 5000);

  test("a changed resolved runtime or environment replaces a process even when the manifest is unchanged", async () => {
    const f = fixture(); await f.pool.send(target, request);
    f.setLaunch({ ...launch, serverPath: "C:/new-java/java.exe", environment: { JAVA_HOME: "C:/new-java" } });
    await f.pool.send(target, request);
    expect(f.calls.map(call => call.operation)).toEqual(["resolve", "start", "request", "resolve", "stop", "start", "request"]);
  }, 5000);
});
