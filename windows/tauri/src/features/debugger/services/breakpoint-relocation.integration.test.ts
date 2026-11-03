import { SourceText } from "@lithe/editor/source-text";
import { afterAll, afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { CString, dlopen, FFIType } from "bun:ffi";
import * as native from "@/platform/tauri-core";
import { installHappyDom } from "@/test-utils/happy-dom";
import fixture from "../../../../../../shared/fixtures/debug/breakpoint-relocation-v1.json";
import { useDebuggerStore } from "../stores/debugger.store";
import { queueBreakpointRelocation, flushBreakpointRelocations } from "./breakpoint-relocation";
import { syncDebugBreakpoints } from "./debug-adapter-service";

// Explicit local native integration lane; ordinary unit tests need no Core DLL.
const libraryPath = process.env.LITHE_CORE_TEST_LIBRARY;
const library = libraryPath ? dlopen(libraryPath, {
  lithe_core_execute_json: { args: [FFIType.ptr], returns: FFIType.ptr },
  lithe_core_free_string: { args: [FFIType.ptr], returns: FFIType.void },
}) : null;
afterAll(() => library?.close());
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

for (const item of fixture.cases) {
  test.skipIf(!library)(`native relocation -> persisted owner -> DAP: ${item.name}`, async () => {
    const path = "D:/fixture/Main.java";
    useDebuggerStore.setState({ breakpoints: item.payload.breakpoints.map((point, index) => ({
      id: `point-${index}`, filePath: path, line: point.line - 1, enabled: point.enabled, createdAt: 1,
    })) });
    const invoke = spyOn(native, "invoke").mockImplementation(async (command, payload) => {
      if (command === "debug_send_request") return {};
      const input = Buffer.from(JSON.stringify({ id: "relocation", command, payload }) + "\0");
      const pointer = library!.symbols.lithe_core_execute_json(input);
      if (!pointer) throw new Error("Core returned a null response pointer");
      try {
        const response = JSON.parse(new CString(pointer).toString());
        if (!response.ok) throw Object.assign(new Error(response.error.message), response.error);
        return response.data;
      } finally { library!.symbols.lithe_core_free_string(pointer); }
    });
    try {
      const model = new SourceText(item.payload.source, 1);
      const extra = ("editBatches" in item.payload ? item.payload.editBatches : undefined) ?? [];
      const batches = [[item.payload.edit], ...extra];
      for (const [index, batch] of batches.entries()) {
        const source = model.value;
        const changes = model.apply(batch.map(edit => ({
          rangeOffset: source.slice(0, edit.startUtf16Offset).replace(/\r\n/g, "\n").length,
          rangeLength: source.slice(edit.startUtf16Offset, edit.endUtf16Offset).replace(/\r\n/g, "\n").length,
          text: edit.replacement,
        })), index + 2);
        queueBreakpointRelocation(path, { previousContent: source, content: model.value, changes, anchorChanges: model.lastAnchorChanges, external: false });
      }
      await flushBreakpointRelocations();
      const points = useDebuggerStore.getState().breakpoints;
      expect(points.map(point => ({ line: point.line + 1, enabled: point.enabled })))
        .toEqual(item.expected.breakpoints.map(point => ({ line: point.line, enabled: point.enabled })));
      await syncDebugBreakpoints("fixture-session", points);
      expect(invoke.mock.calls[invoke.mock.calls.length - 1]?.[1]).toMatchObject({ request: { command: "setBreakpoints",
        arguments: { source: { path }, breakpoints: item.expected.breakpoints.filter(point => point.enabled).map(point => ({ line: point.line })) },
      } });
    } finally { invoke.mockRestore(); }
  });
}

test.skipIf(!library)("native retry keeps a breakpoint added while relocation is in flight", async () => {
  const path = "D:/fixture/Race.java";
  const actions = useDebuggerStore.getState().actions;
  actions.toggleBreakpoint(path, 1);
  let entered!: () => void;
  let release!: () => void;
  const started = new Promise<void>(resolve => { entered = resolve; });
  const gate = new Promise<void>(resolve => { release = resolve; });
  let calls = 0;
  const invoke = spyOn(native, "invoke").mockImplementation(async (command, payload) => {
    const input = Buffer.from(JSON.stringify({ id: "race", command, payload }) + "\0");
    const pointer = library!.symbols.lithe_core_execute_json(input);
    if (!pointer) throw new Error("Core returned a null response pointer");
    let response: { ok: boolean; data: unknown; error?: { message: string } };
    try { response = JSON.parse(new CString(pointer).toString()); }
    finally { library!.symbols.lithe_core_free_string(pointer); }
    if (!response.ok) throw new Error(response.error?.message);
    if (++calls === 1) { entered(); await gate; }
    return response.data as never;
  });
  try {
    const source = "first();\nrun();\n";
    const model = new SourceText(source, 1);
    const changes = model.apply([{rangeOffset: 0, rangeLength: 0, text: "\n"}], 2);
    queueBreakpointRelocation(path, {previousContent: source, content: model.value, changes, anchorChanges: model.lastAnchorChanges, external: false});
    await started;
    actions.toggleBreakpoint(path, 0);
    release();
    await flushBreakpointRelocations();
    expect(calls).toBe(2);
    expect(actions.getBreakpointsForFile(path).map(point => point.line).sort()).toEqual([0, 2]);
  } finally {
    release(); actions.clearBreakpoints(); await flushBreakpointRelocations(); invoke.mockRestore();
  }
});

test.skipIf(!library)("native large-file queue batches typing while a request is in flight", async () => {
  const path = "D:/fixture/Large.java";
  const actions = useDebuggerStore.getState().actions;
  actions.toggleBreakpoint(path, 0);
  let entered!: () => void;
  let release!: () => void;
  const started = new Promise<void>(resolve => { entered = resolve; });
  const gate = new Promise<void>(resolve => { release = resolve; });
  const payloads: unknown[] = [];
  const invoke = spyOn(native, "invoke").mockImplementation(async (command, payload) => {
    payloads.push(payload);
    const input = Buffer.from(JSON.stringify({ id: "large", command, payload }) + "\0");
    const pointer = library!.symbols.lithe_core_execute_json(input);
    if (!pointer) throw new Error("Core returned a null response pointer");
    let response: { ok: boolean; data: unknown; error?: { message: string } };
    try { response = JSON.parse(new CString(pointer).toString()); }
    finally { library!.symbols.lithe_core_free_string(pointer); }
    if (!response.ok) throw new Error(response.error?.message);
    if (payloads.length === 1) { entered(); await gate; }
    return response.data as never;
  });
  try {
    let source = "a".repeat(9 * 1024 * 1024);
    for (let index = 0; index < 128; index++) {
      const content = source + "x";
      queueBreakpointRelocation(path, { previousContent: source, content,
        changes: [{ offset: source.length, length: 0, text: "x",
          start: { line: 0, column: source.length }, end: { line: 0, column: source.length } }], external: false });
      source = content;
      if (index === 0) await started;
    }
    release();
    await flushBreakpointRelocations();
    expect(payloads.length).toBe(2);
    expect(JSON.stringify(payloads[1]).length).toBeLessThan(20_000);
    expect(actions.getBreakpointsForFile(path).map(point => point.line)).toEqual([0]);
  } finally {
    release(); actions.clearBreakpoints(); await flushBreakpointRelocations(); invoke.mockRestore();
  }
}, 30_000);
