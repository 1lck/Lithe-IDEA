import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import * as native from "@/platform/tauri-core";
import { installHappyDom } from "@/test-utils/happy-dom";
import { useDebuggerStore } from "../stores/debugger.store";
import { debugDecorations } from "./monaco-debug-decorations";
import { SourceText } from "@lithe/editor/source-text";
import { queueBreakpointRelocation, flushBreakpointRelocations } from "./breakpoint-relocation";

let restoreDom: () => void;
let previous: ReturnType<typeof useDebuggerStore.getState>;
beforeEach(() => {
  restoreDom = installHappyDom();
  previous = useDebuggerStore.getState();
  useDebuggerStore.getState().actions.clearBreakpoints();
});
afterEach(async () => {
  useDebuggerStore.getState().actions.clearBreakpoints();
  await flushBreakpointRelocations();
  useDebuggerStore.setState(previous);
  restoreDom();
});

const insertion = () => ({ previousContent: "first();\nrun();\n", content: "\nfirst();\nrun();\n", external: false,
  changes: [{ offset: 0, length: 0, text: "\n", start: { line: 0, column: 0 }, end: { line: 0, column: 0 } }] });

test("editing updates the persisted owner, its gutter projection and the one-based Core boundary", async () => {
  useDebuggerStore.getState().actions.toggleBreakpoint("D:/work/Main.java", 1);
  const invoke = spyOn(native, "invoke").mockResolvedValue({ breakpoints: [{ line: 3, enabled: true }], originalIndices: [0] });
  try {
    queueBreakpointRelocation("d:\\work\\MAIN.java", insertion());
    await flushBreakpointRelocations();
    const points = useDebuggerStore.getState().breakpoints;
    expect(invoke.mock.calls[0]).toEqual(["debug.relocateBreakpoints", {
      source: "first();\nrun();\n", document: expect.objectContaining({ version: 1 }), edits: [ { startUtf16Offset: 0, endUtf16Offset: 0, replacement: "\n" }],
      breakpoints: [{ line: 2, enabled: true }],
    }]);
    expect(points[0]?.line).toBe(2);
    expect(points[0]?.filePath).toBe("D:/work/Main.java");
    expect(debugDecorations("D:/work/Main.java", points)[0]?.range.startLineNumber).toBe(3);
    expect(JSON.parse(window.localStorage.getItem("lithe-debugger-breakpoints")!)[0].line).toBe(2);
  } finally { invoke.mockRestore(); }
});

test("a source mutation shared by split editors is submitted only once", async () => {
  useDebuggerStore.getState().actions.toggleBreakpoint("D:/work/Main.java", 1);
  const invoke = spyOn(native, "invoke").mockResolvedValue({ breakpoints: [{ line: 3, enabled: true }], originalIndices: [0] });
  try {
    const change = insertion();
    queueBreakpointRelocation("D:/work/Main.java", change);
    queueBreakpointRelocation("d:/work/MAIN.java", change);
    await flushBreakpointRelocations();
    expect(invoke).toHaveBeenCalledTimes(1);
  } finally { invoke.mockRestore(); }
});

test("files without breakpoints and external refreshes do not send requests", async () => {
  const invoke = spyOn(native, "invoke");
  try {
    queueBreakpointRelocation("D:/work/Main.java", insertion());
    useDebuggerStore.getState().actions.toggleBreakpoint("D:/work/Main.java", 1);
    queueBreakpointRelocation("D:/work/Main.java", { ...insertion(), external: true });
    await flushBreakpointRelocations();
    expect(invoke).not.toHaveBeenCalled();
  } finally { invoke.mockRestore(); }
});

test("unchanged locations retain store identity and do not trigger another adapter sync", async () => {
  useDebuggerStore.getState().actions.toggleBreakpoint("D:/work/Main.java", 1);
  const before = useDebuggerStore.getState().breakpoints;
  const invoke = spyOn(native, "invoke").mockResolvedValue({ breakpoints: [{ line: 2, enabled: true }], originalIndices: [0] });
  try {
    queueBreakpointRelocation("D:/work/Main.java", insertion());
    await flushBreakpointRelocations();
    expect(useDebuggerStore.getState().breakpoints).toBe(before);
  } finally { invoke.mockRestore(); }
});

test("queue overflow is bounded and cannot silently launch with stale positions", async () => {
  useDebuggerStore.getState().actions.toggleBreakpoint("D:/work/Main.java", 1);
  const invoke = spyOn(native, "invoke");
  try {
    for (let index = 0; index < 129; index++) queueBreakpointRelocation("D:/work/Main.java", insertion());
    await expect(flushBreakpointRelocations()).rejects.toBeInstanceOf(Error);
    // Loading the localized failure may initialize settings through the same bridge.
    expect(invoke.mock.calls.filter(call => call[0] === "debug.relocateBreakpoints")).toEqual([]);
  } finally { invoke.mockRestore(); }
});

test("rapid edits serialize against the relocated owner rather than an old snapshot", async () => {
  useDebuggerStore.getState().actions.toggleBreakpoint("D:/work/Main.java", 1);
  let release!: (value: { breakpoints: { line: number; enabled: boolean }[]; originalIndices: number[] }) => void;
  let entered!: () => void;
  const started = new Promise<void>(resolve => { entered = resolve; });
  const first = new Promise<{ breakpoints: { line: number; enabled: boolean }[]; originalIndices: number[] }>(resolve => { release = resolve; });
  const invoke = spyOn(native, "invoke").mockImplementation(async <T>(_command: string, args?: unknown): Promise<T> => {
    const points = (args as { breakpoints: { line: number }[] }).breakpoints;
    if (points[0]?.line === 2) { entered(); return await first as T; }
    return { breakpoints: [{ line: 4, enabled: true }], originalIndices: [0] } as T;
  });
  try {
    queueBreakpointRelocation("D:/work/Main.java", insertion());
    await started;
    queueBreakpointRelocation("D:/work/Main.java", { ...insertion(), previousContent: "\nfirst();\nrun();\n" });
    expect(invoke).toHaveBeenCalledTimes(1);
    release({ breakpoints: [{ line: 3, enabled: true }], originalIndices: [0] });
    await flushBreakpointRelocations();
    expect(invoke).toHaveBeenCalledTimes(2);
    expect(useDebuggerStore.getState().breakpoints[0]?.line).toBe(3);
  } finally {
    release({ breakpoints: [{ line: 3, enabled: true }], originalIndices: [0] });
    await flushBreakpointRelocations();
    invoke.mockRestore();
  }
});

test("clearing breakpoints retires an in-flight result without resurrecting them", async () => {
  useDebuggerStore.getState().actions.toggleBreakpoint("D:/work/Main.java", 1);
  let release!: (value: { breakpoints: { line: number; enabled: boolean }[]; originalIndices: number[] }) => void;
  let entered!: () => void;
  const started = new Promise<void>(resolve => { entered = resolve; });
  const response = new Promise<{ breakpoints: { line: number; enabled: boolean }[]; originalIndices: number[] }>(resolve => { release = resolve; });
  const invoke = spyOn(native, "invoke").mockImplementation(async <T>(): Promise<T> => { entered(); return await response as T; });
  try {
    queueBreakpointRelocation("D:/work/Main.java", insertion());
    await started;
    useDebuggerStore.getState().actions.clearBreakpoints();
    release({ breakpoints: [{ line: 3, enabled: true }], originalIndices: [0] });
    await flushBreakpointRelocations();
    expect(useDebuggerStore.getState().breakpoints).toEqual([]);
  } finally {
    release({ breakpoints: [], originalIndices: [] });
    await flushBreakpointRelocations();
    invoke.mockRestore();
  }
});

test("hydrating unchanged breakpoints during relocation preserves the pending update", async () => {
  useDebuggerStore.getState().actions.toggleBreakpoint("D:/work/Main.java", 1);
  let release!: (value: { breakpoints: { line: number; enabled: boolean }[]; originalIndices: number[] }) => void;
  let entered!: () => void;
  const started = new Promise<void>(resolve => { entered = resolve; });
  const response = new Promise<{ breakpoints: { line: number; enabled: boolean }[]; originalIndices: number[] }>(resolve => { release = resolve; });
  const invoke = spyOn(native, "invoke").mockImplementation(async <T>(): Promise<T> => { entered(); return await response as T; });
  try {
    queueBreakpointRelocation("D:/work/Main.java", insertion());
    await started;
    useDebuggerStore.getState().actions.hydrate();
    release({ breakpoints: [{ line: 3, enabled: true }], originalIndices: [0] });
    await flushBreakpointRelocations();
    expect(useDebuggerStore.getState().actions.getBreakpointsForFile("D:/work/Main.java")[0]?.line).toBe(2);
  } finally {
    release({ breakpoints: [], originalIndices: [] });
    await flushBreakpointRelocations();
    invoke.mockRestore();
  }
});

test("a failed relocation blocks launch until the user clears unsafe anchors", async () => {
  useDebuggerStore.getState().actions.toggleBreakpoint("D:/work/Main.java", 1);
  const invoke = spyOn(native, "invoke").mockRejectedValue(new Error("native failure"));
  try {
    queueBreakpointRelocation("D:/work/Main.java", insertion());
    await expect(flushBreakpointRelocations()).rejects.toBeInstanceOf(Error);
    expect(useDebuggerStore.getState().breakpoints[0]?.line).toBe(1);
    useDebuggerStore.getState().actions.clearBreakpoints();
    await flushBreakpointRelocations();
  } finally { invoke.mockRestore(); }
});

test("multi-cursor native edits are submitted together to preserve character anchors", async () => {
 const source = "first();\nsecond();\nrun();\n";
 const model = new SourceText(source, 1);
 const changes = model.apply([{rangeOffset:0,rangeLength:0,text:"\n"},{rangeOffset:9,rangeLength:0,text:"\n"}], 2);
 useDebuggerStore.getState().actions.toggleBreakpoint("D:/work/Batch.java",2);
 const invoke = spyOn(native,"invoke").mockResolvedValue({breakpoints:[{line:5,enabled:true}],originalIndices:[0]});
 try {
  queueBreakpointRelocation("D:/work/Batch.java",{previousContent:source,content:model.value,changes,external:false});
  await flushBreakpointRelocations();
  expect(invoke).toHaveBeenCalledTimes(1);
  expect((invoke.mock.calls[0]?.[1] as {edits:unknown[]}).edits).toHaveLength(2);
  expect(useDebuggerStore.getState().actions.getBreakpointsForFile("D:/work/Batch.java")[0]?.line).toBe(4);
 } finally { invoke.mockRestore(); }
});

test("a breakpoint added while an earlier edit is queued stays at its new-document location", async () => {
 const actions = useDebuggerStore.getState().actions;
 actions.toggleBreakpoint("D:/work/Block.java", 1); actions.toggleBreakpoint("D:/work/Queued.java", 1);
 let release!: (value: {breakpoints: {line:number;enabled:boolean}[]; originalIndices: number[]}) => void; let enter!:()=>void;
 const started = new Promise<void>(resolve => {enter=resolve;});
 const blocked = new Promise<{breakpoints:{line:number;enabled:boolean}[]; originalIndices: number[]}>(resolve => {release=resolve;});
 const invoke = spyOn(native,"invoke").mockImplementation(async command => { if(command === "debug.relocateBreakpoints") {enter(); return await blocked as never;} return undefined as never; });
 try {
  queueBreakpointRelocation("D:/work/Block.java", insertion()); await started;
  queueBreakpointRelocation("D:/work/Queued.java", insertion());
  actions.toggleBreakpoint("D:/work/Queued.java", 0);
  release({breakpoints:[{line:3,enabled:true}],originalIndices:[0]});
  await flushBreakpointRelocations();
  expect(invoke.mock.calls.filter(call=>call[0] === "debug.relocateBreakpoints")).toHaveLength(2);
  expect(actions.getBreakpointsForFile("D:/work/Queued.java").map(point=>point.line).sort()).toEqual([0,2]);
 } finally {release({breakpoints:[],originalIndices:[]}); actions.clearBreakpoints(); await flushBreakpointRelocations(); invoke.mockRestore();}
});

test("a breakpoint added during a native request is not relocated with an older edit", async () => {
 const actions = useDebuggerStore.getState().actions;
 actions.toggleBreakpoint("D:/work/Main.java", 1);
 let release!: (value: {breakpoints:{line:number;enabled:boolean}[]; originalIndices:number[]}) => void;
 let entered!: () => void;
 const started = new Promise<void>(resolve => { entered = resolve; });
 const blocked = new Promise<{breakpoints:{line:number;enabled:boolean}[]; originalIndices:number[]}>(resolve => { release = resolve; });
 let calls = 0;
 const invoke = spyOn(native, "invoke").mockImplementation(async <T>(_command: string, args?: unknown): Promise<T> => {
  calls++;
  expect((args as {breakpoints: unknown[]}).breakpoints).toHaveLength(1);
  if (calls === 1) { entered(); return await blocked as T; }
  return {breakpoints:[{line:3,enabled:true}],originalIndices:[0]} as T;
 });
 try {
  queueBreakpointRelocation("D:/work/Main.java", insertion());
  await started;
  actions.toggleBreakpoint("D:/work/Main.java", 0);
  release({breakpoints:[{line:3,enabled:true}],originalIndices:[0]});
  await flushBreakpointRelocations();
  expect(calls).toBe(2);
  expect(actions.getBreakpointsForFile("D:/work/Main.java").map(point => point.line).sort()).toEqual([0,2]);
 } finally {
  release({breakpoints:[],originalIndices:[]});
  actions.clearBreakpoints(); await flushBreakpointRelocations(); invoke.mockRestore();
 }
});

test("a removed and re-added breakpoint is not overwritten by its old native result", async () => {
 const actions = useDebuggerStore.getState().actions;
 actions.toggleBreakpoint("D:/work/Main.java", 1);
 let release!: (value: {breakpoints:{line:number;enabled:boolean}[]; originalIndices:number[]}) => void;
 let entered!: () => void;
 const started = new Promise<void>(resolve => { entered = resolve; });
 const blocked = new Promise<{breakpoints:{line:number;enabled:boolean}[]; originalIndices:number[]}>(resolve => { release = resolve; });
 const invoke = spyOn(native, "invoke").mockImplementation(async <T>(): Promise<T> => { entered(); return await blocked as T; });
 try {
  const originalId = actions.getBreakpointsForFile("D:/work/Main.java")[0]!.id;
  queueBreakpointRelocation("D:/work/Main.java", insertion());
  await started;
  actions.toggleBreakpoint("D:/work/Main.java", 1);
  actions.toggleBreakpoint("D:/work/Main.java", 1);
  release({breakpoints:[{line:3,enabled:true}],originalIndices:[0]});
  await flushBreakpointRelocations();
  const [current] = actions.getBreakpointsForFile("D:/work/Main.java");
  expect(current!.id).not.toBe(originalId);
  expect(current!.line).toBe(1);
  expect(invoke).toHaveBeenCalledTimes(1);
 } finally {
  release({breakpoints:[],originalIndices:[]});
  actions.clearBreakpoints(); await flushBreakpointRelocations(); invoke.mockRestore();
 }
});

test("a later breakpoint wins when an older anchor moves onto its line", async () => {
 const actions = useDebuggerStore.getState().actions;
 actions.toggleBreakpoint("D:/work/Main.java", 1);
 let release!: (value: {breakpoints:{line:number;enabled:boolean}[]; originalIndices:number[]}) => void;
 let entered!: () => void;
 const started = new Promise<void>(resolve => { entered = resolve; });
 const blocked = new Promise<{breakpoints:{line:number;enabled:boolean}[]; originalIndices:number[]}>(resolve => { release = resolve; });
 let calls = 0;
 const invoke = spyOn(native, "invoke").mockImplementation(async <T>(): Promise<T> => {
  if (++calls === 1) { entered(); return await blocked as T; }
  return {breakpoints:[{line:3,enabled:true}],originalIndices:[0]} as T;
 });
 try {
  queueBreakpointRelocation("D:/work/Main.java", insertion());
  await started;
  actions.toggleBreakpoint("D:/work/Main.java", 2);
  const added = actions.getBreakpointsForFile("D:/work/Main.java").find(point => point.line === 2)!;
  release({breakpoints:[{line:3,enabled:true}],originalIndices:[0]});
  await flushBreakpointRelocations();
  expect(actions.getBreakpointsForFile("D:/work/Main.java").map(point => point.id)).toEqual([added.id]);
 } finally {
  release({breakpoints:[],originalIndices:[]});
  actions.clearBreakpoints(); await flushBreakpointRelocations(); invoke.mockRestore();
 }
});

test("removing a collision survivor retries with the remaining breakpoint", async () => {
 const actions = useDebuggerStore.getState().actions;
 actions.toggleBreakpoint("D:/work/Main.java", 0);
 actions.toggleBreakpoint("D:/work/Main.java", 1);
 let release!: (value: {breakpoints:{line:number;enabled:boolean}[]; originalIndices:number[]}) => void;
 let entered!: () => void;
 const started = new Promise<void>(resolve => { entered = resolve; });
 const blocked = new Promise<{breakpoints:{line:number;enabled:boolean}[]; originalIndices:number[]}>(resolve => { release = resolve; });
 let calls = 0;
 const invoke = spyOn(native, "invoke").mockImplementation(async <T>(_command: string, args?: unknown): Promise<T> => {
  const points = (args as {breakpoints:{line:number}[]}).breakpoints;
  if (++calls === 1) { expect(points).toHaveLength(2); entered(); return await blocked as T; }
  expect(points.map(point => point.line)).toEqual([1]);
  return {breakpoints:[{line:1,enabled:true}],originalIndices:[0]} as T;
 });
 try {
  queueBreakpointRelocation("D:/work/Main.java", {
   previousContent: "first();\nrun();\n", content: "run();\n", external: false,
   changes: [{offset: 0, length: 9, text: "", start: {line: 0, column: 0}, end: {line: 1, column: 0}}],
  });
  await started;
  actions.toggleBreakpoint("D:/work/Main.java", 1);
  release({breakpoints:[{line:1,enabled:true}],originalIndices:[1]});
  await flushBreakpointRelocations();
  expect(calls).toBe(2);
  expect(actions.getBreakpointsForFile("D:/work/Main.java").map(point => point.line)).toEqual([0]);
 } finally {
  release({breakpoints:[],originalIndices:[]});
  actions.clearBreakpoints(); await flushBreakpointRelocations(); invoke.mockRestore();
 }
});

test("a breakpoint added between consecutive edits moves only with the later edit", async () => {
 const actions = useDebuggerStore.getState().actions;
 actions.toggleBreakpoint("D:/work/Main.java", 0);
 let release!: (value: {breakpoints:{line:number;enabled:boolean}[]; originalIndices:number[]}) => void;
 let entered!: () => void;
 const started = new Promise<void>(resolve => { entered = resolve; });
 const blocked = new Promise<{breakpoints:{line:number;enabled:boolean}[]; originalIndices:number[]}>(resolve => { release = resolve; });
 let calls = 0;
 const invoke = spyOn(native, "invoke").mockImplementation(async <T>(_command: string, args?: unknown): Promise<T> => {
  calls++;
  const points = (args as {breakpoints:{line:number}[]}).breakpoints;
  if (calls === 1) { entered(); return await blocked as T; }
  if (calls === 2) return {breakpoints:[{line:2,enabled:true}],originalIndices:[0]} as T;
  expect(points.map(point => point.line).sort()).toEqual([2,3]);
  return {breakpoints:[{line:3,enabled:true},{line:4,enabled:true}],originalIndices:[1,0]} as T;
 });
 const first = insertion();
 try {
  queueBreakpointRelocation("D:/work/Main.java", first);
  await started;
  const firstId = actions.getBreakpointsForFile("D:/work/Main.java")[0]!.id;
  actions.toggleBreakpoint("D:/work/Main.java", 2);
  const secondId = actions.getBreakpointsForFile("D:/work/Main.java")[1]!.id;
  queueBreakpointRelocation("D:/work/Main.java", {
   ...first, previousContent: first.content, content: "\n" + first.content,
  });
  release({breakpoints:[{line:2,enabled:true}],originalIndices:[0]});
  await flushBreakpointRelocations();
  expect(actions.getBreakpointsForFile("D:/work/Main.java").map(point => point.line).sort()).toEqual([2,3]);
  expect(actions.getBreakpointsForFile("D:/work/Main.java").find(point => point.id === firstId)?.line).toBe(2);
  expect(actions.getBreakpointsForFile("D:/work/Main.java").find(point => point.id === secondId)?.line).toBe(3);
 } finally {
  release({breakpoints:[],originalIndices:[]});
  actions.clearBreakpoints(); await flushBreakpointRelocations(); invoke.mockRestore();
 }
});

test("large document incremental IPC omits the source after the initial snapshot", async () => {
 const source = "x".repeat(10 * 1024 * 1024);
 useDebuggerStore.getState().actions.toggleBreakpoint("D:/work/Large.java",0);
 const invoke = spyOn(native,"invoke").mockResolvedValue({breakpoints:[{line:1,enabled:true}],originalIndices:[0]});
 let current = source;
 try {
  for(let index=0;index<128;index++) {
   const next = current + "x";
   queueBreakpointRelocation("D:/work/Large.java",{previousContent:current,content:next,external:false,changes:[{offset:current.length,length:0,text:"x",start:{line:0,column:current.length},end:{line:0,column:current.length}}]});
   await flushBreakpointRelocations(); current=next;
  }
  const payloads = invoke.mock.calls.filter(call=>call[0] === "debug.relocateBreakpoints").map(call=>call[1] as {source?:string});
  expect(payloads).toHaveLength(128);
  expect(payloads.filter(payload=>payload.source !== undefined)).toHaveLength(1);
  const bytes=payloads.reduce((sum,payload)=>sum+new TextEncoder().encode(JSON.stringify(payload)).length,0);
  expect(bytes).toBeLessThan(11*1024*1024);
 } finally {invoke.mockRestore();}
});

test("large-file typing queues bounded incremental edits while native relocation is in flight", async () => {
 const path = "D:/work/LargeQueued.java";
 const actions = useDebuggerStore.getState().actions;
 actions.toggleBreakpoint(path, 0);
 let release!: (value: {breakpoints:{line:number;enabled:boolean}[]; originalIndices:number[]}) => void;
 let entered!: () => void;
 const started = new Promise<void>(resolve => { entered = resolve; });
 const blocked = new Promise<{breakpoints:{line:number;enabled:boolean}[]; originalIndices:number[]}>(resolve => { release = resolve; });
 let calls = 0;
 const invoke = spyOn(native, "invoke").mockImplementation(async <T>(_command: string, args?: unknown): Promise<T> => {
  if (++calls === 1) { entered(); return await blocked as T; }
  const payload = args as { source?: string; editBatches?: unknown[][] };
  expect(payload.source).toBeUndefined();
  expect(payload.editBatches).toHaveLength(126);
  expect(JSON.stringify(payload).length).toBeLessThan(20_000);
  return {breakpoints:[{line:1,enabled:true}],originalIndices:[0]} as T;
 });
 try {
  let source = "x".repeat(9 * 1024 * 1024);
  const change = () => {
   const next = source + "a";
   const event = {previousContent:source, content:next, external:false,
    changes:[{offset:source.length,length:0,text:"a",start:{line:0,column:source.length},end:{line:0,column:source.length}}]};
   source = next;
   return event;
  };
  queueBreakpointRelocation(path, change());
  await started;
  for (let index = 0; index < 127; index++) queueBreakpointRelocation(path, change());
  release({breakpoints:[{line:1,enabled:true}],originalIndices:[0]});
  await flushBreakpointRelocations();
  expect(calls).toBe(2);
  expect(actions.getBreakpointsForFile(path).map(point => point.line)).toEqual([0]);
 } finally {
  release({breakpoints:[],originalIndices:[]});
  actions.clearBreakpoints(); await flushBreakpointRelocations(); invoke.mockRestore();
 }
});

test("queued edits are not coalesced across a breakpoint change", async () => {
 const actions = useDebuggerStore.getState().actions;
 actions.toggleBreakpoint("D:/work/Block.java", 0);
 actions.toggleBreakpoint("D:/work/Queued.java", 0);
 let release!: (value: {breakpoints:{line:number;enabled:boolean}[]; originalIndices:number[]}) => void;
 let entered!: () => void;
 const started = new Promise<void>(resolve => { entered = resolve; });
 const blocked = new Promise<{breakpoints:{line:number;enabled:boolean}[]; originalIndices:number[]}>(resolve => { release = resolve; });
 let calls = 0;
 const invoke = spyOn(native, "invoke").mockImplementation(async <T>(_command: string, args?: unknown): Promise<T> => {
  const payload = args as {breakpoints:{line:number}[]; editBatches?:unknown[][]};
  if (++calls === 1) { entered(); return await blocked as T; }
  expect(payload.editBatches).toBeUndefined();
  if (calls === 2) return {breakpoints:[{line:2,enabled:true}],originalIndices:[0]} as T;
  expect(payload.breakpoints.map(point => point.line).sort()).toEqual([2,3]);
  return {breakpoints:[{line:3,enabled:true},{line:4,enabled:true}],originalIndices:[1,0]} as T;
 });
 const first = insertion();
 try {
  queueBreakpointRelocation("D:/work/Block.java", first);
  await started;
  queueBreakpointRelocation("D:/work/Queued.java", {...first});
  actions.toggleBreakpoint("D:/work/Queued.java", 2);
  queueBreakpointRelocation("D:/work/Queued.java", {
   ...first, previousContent:first.content, content:"\n" + first.content,
  });
  release({breakpoints:[{line:2,enabled:true}],originalIndices:[0]});
  await flushBreakpointRelocations();
  expect(calls).toBe(3);
  expect(actions.getBreakpointsForFile("D:/work/Queued.java").map(point => point.line).sort()).toEqual([2,3]);
 } finally {
  release({breakpoints:[],originalIndices:[]});
  actions.clearBreakpoints(); await flushBreakpointRelocations(); invoke.mockRestore();
 }
});
