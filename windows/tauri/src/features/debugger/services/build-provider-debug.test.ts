import { expect, test } from "bun:test";
import { ExtensionProcessOwner } from "@/extensions/run/extension-process-owner";
import { startBuildProviderDebug, type ProviderDebugPorts, type RegisteredConnectionPlan } from "./build-provider-debug";
import type { RunProcessInstance } from "@/features/run/types/run.types";
import type { DebugAdapterSessionInfo } from "../types/debugger.types";

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>(done => { resolve = done; }); return { promise, resolve };
}
function fixture() {
  const calls: string[] = [], processes = new ExtensionProcessOwner();
  const run = { sessionId: "saved-service", executionId: "exact-execution" }, session = { id: "exact-adapter", command: "fixture-adapter", args: [] };
  const plan: RegisteredConnectionPlan = { pluginId: "dev.example.debug", adapterID: "dev.example.debug/remote", configurationType: "engine.remote", port: 51234,
    arguments: { connect: { host: "127.0.0.1", port: 51234 }, preserve: ["", "two words"] }, identity: { revision: 1 },
    adapter: { adapterID: "engine-dap", transport: "stdio", disabledCapabilities: ["supportsRestartRequest"] }, languageId: null, command: null,
    launch: { serverPath: "fixture-adapter", serverArgs: [], environment: {} } };
  let revision = 1, validation = 0, failValidation = 0, failStop = false;
  let runGate: Promise<RunProcessInstance | null> = Promise.resolve(run), adapterGate: Promise<DebugAdapterSessionInfo> = Promise.resolve(session), listenerGate = Promise.resolve();
  const runEntered = deferred<void>(), adapterEntered = deferred<void>(), listenerEntered = deferred<void>();
  const ports: ProviderDebugPorts = {
    processes, allocatePort: async () => { calls.push("allocate"); return 51234; },
    plan: async () => { calls.push("plan"); return plan; },
    validate: async () => { calls.push("validate"); if (++validation === failValidation) throw new Error("native source changed"); },
    startRun: async (options, current) => { current(); calls.push("run"); expect(options).toEqual({ adapterID:plan.adapterID,configurationType:plan.configurationType,
      target:{kind:"connection",host:"127.0.0.1",port:51234} }); runEntered.resolve(); return runGate; },
    stopRun: async instance => { expect(instance).toEqual(run); calls.push("stop-run"); if (failStop) throw new Error("Run stop failed"); },
    waitForPort: async () => { calls.push("listen"); listenerEntered.resolve(); await listenerGate; },
    startAdapter: async (value, started, current) => { current(); expect(value).toBe(plan); calls.push("adapter"); adapterEntered.resolve();
      const result = await adapterGate; started(result); return result; },
    stopAdapter: async id => { expect(id).toBe(session.id); calls.push("stop-adapter"); },
    onStarted: () => { calls.push("present"); },
    guard: () => { const initial=revision; return () => { if(initial!==revision) throw new Error("adapter revoked"); }; },
    unavailable: () => new Error("unavailable"),
  };
  const launch = () => startBuildProviderDebug({ workspaceId:"workspace-a",root:"C:/fixture",name:"service",configurationType:"engine.remote",isCurrent:()=>true },ports);
  return { calls,ports,plan,run,session,processes,launch,runEntered:runEntered.promise,adapterEntered:adapterEntered.promise,listenerEntered:listenerEntered.promise,
    delayRun: () => { const gate=deferred<RunProcessInstance | null>();runGate=gate.promise;return gate; },
    delayAdapter: () => { const gate=deferred<DebugAdapterSessionInfo>();adapterGate=gate.promise;return gate; },
    delayListener: () => { const gate=deferred<void>();listenerGate=gate.promise;return gate; },
    revoke: () => {revision++;},failValidation:(step:number)=>{failValidation=step;},failStop:(value:boolean)=>{failStop=value;},
    close: () => processes.stop("workspace-a"),
  };
}

test("Registry connection debugging keeps typed options, rechecks every boundary and stops exact owners", async () => {
  const f=fixture(),handle=f.launch();
  try {
    await handle.completion;
    expect(f.calls).toEqual(["allocate","plan","validate","run","validate","listen","validate","adapter","present","validate"]);
    await handle.stop();
    expect(f.calls.filter(call=>call.startsWith("stop-"))).toEqual(["stop-adapter","stop-run"]);
  } finally {await f.close();await Promise.allSettled([handle.completion]);}
},5000);

test("adapter revocation while the target listener is pending rejects the handoff and drains the Run", async () => {
  const f=fixture(),gate=f.delayListener(),handle=f.launch(),settled=handle.completion.then(()=>"started",error=>String(error));
  try {
    await f.listenerEntered;f.revoke();gate.resolve();
    expect(await settled).toContain("adapter revoked");expect(f.calls).not.toContain("adapter");
    expect(f.calls.filter(call=>call==="stop-run")).toHaveLength(1);
  } finally {gate.resolve();await f.close();await settled;}
},5000);

test("Stop drains a late Run acknowledgement before releasing the adapter package", async () => {
  const f=fixture(),gate=f.delayRun(),handle=f.launch(),settled=handle.completion.catch(()=>{});
  let stopping:Promise<void>|undefined;
  try {
    await f.runEntered;stopping=handle.stop();expect(f.calls).not.toContain("stop-run");
    gate.resolve(f.run);await stopping;await settled;
    expect(f.calls.filter(call=>call==="stop-run")).toHaveLength(1);expect(f.calls).not.toContain("adapter");
  } finally {gate.resolve(f.run);await Promise.allSettled([stopping,settled]);await f.close();}
},5000);

test("Stop drains a late adapter acknowledgement without presenting a retired session", async () => {
  const f=fixture(),gate=f.delayAdapter(),handle=f.launch(),settled=handle.completion.catch(()=>{});
  let stopping:Promise<void>|undefined;
  try {
    await f.adapterEntered;stopping=handle.stop();gate.resolve(f.session);await stopping;await settled;
    expect(f.calls).not.toContain("present");expect(f.calls.filter(call=>call==="stop-adapter")).toHaveLength(1);
    expect(f.calls.filter(call=>call==="stop-run")).toHaveLength(1);
  } finally {gate.resolve(f.session);await Promise.allSettled([stopping,settled]);await f.close();}
},5000);

test("native source validation fails before executing workspace code", async () => {
  const f=fixture();f.failValidation(1);const handle=f.launch();
  try {await expect(handle.completion).rejects.toThrow("native source changed");expect(f.calls).not.toContain("run");}
  finally {await f.close();await Promise.allSettled([handle.completion]);}
},5000);

test("a failure after adapter creation stops both resources and keeps failed cleanup retryable", async () => {
  const f=fixture();f.failValidation(4);f.failStop(true);const handle=f.launch();
  try {
    await expect(handle.completion).rejects.toThrow("Run stop failed");expect(f.calls.filter(call=>call==="stop-adapter")).toHaveLength(1);
    f.failStop(false);await handle.stop();expect(f.calls.filter(call=>call==="stop-adapter")).toHaveLength(1);
    expect(f.calls.filter(call=>call==="stop-run")).toHaveLength(2);
  } finally {f.failStop(false);await f.close();await Promise.allSettled([handle.completion]);}
},5000);

test("a mismatched Registry answer never reaches Provider preparation", async () => {
  const f=fixture();f.plan.configurationType="other.type";const handle=f.launch();
  try {await expect(handle.completion).rejects.toThrow("unavailable");expect(f.calls).not.toContain("run");}
  finally {await f.close();await Promise.allSettled([handle.completion]);}
},5000);

test("Run exit revokes its adapter and removes the exact execution observation",async()=>{
  const f=fixture();let ended:(()=>void)|undefined,unwatched=0;
  f.ports.watchRun=(instance,callback)=>{expect(instance).toEqual(f.run);ended=callback;return()=>{unwatched++;};};
  const handle=f.launch();
  try {
    await handle.completion;expect(ended).toBeDefined();ended!();await handle.stop();
    expect(unwatched).toBe(1);expect(f.calls.filter(call=>call==="stop-adapter")).toHaveLength(1);
    expect(f.calls.filter(call=>call==="stop-run")).toHaveLength(1);
  } finally {await f.close();await Promise.allSettled([handle.completion]);}
},5000);
