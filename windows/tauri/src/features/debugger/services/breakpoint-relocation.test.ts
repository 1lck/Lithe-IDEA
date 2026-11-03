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
  const invoke = spyOn(native, "invoke").mockResolvedValue({ breakpoints: [{ line: 3, enabled: true }] });
  try {
    queueBreakpointRelocation("d:\\work\\MAIN.java", insertion());
    await flushBreakpointRelocations();
    const points = useDebuggerStore.getState().breakpoints;
    expect(invoke.mock.calls[0]).toEqual(["debug.relocateBreakpoints", {
      source: "first();\nrun();\n", edit: { startUtf16Offset: 0, endUtf16Offset: 0, replacement: "\n" },
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
  const invoke = spyOn(native, "invoke").mockResolvedValue({ breakpoints: [{ line: 3, enabled: true }] });
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
  const invoke = spyOn(native, "invoke").mockResolvedValue({ breakpoints: [{ line: 2, enabled: true }] });
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
  let release!: (value: { breakpoints: { line: number; enabled: boolean }[] }) => void;
  let entered!: () => void;
  const started = new Promise<void>(resolve => { entered = resolve; });
  const first = new Promise<{ breakpoints: { line: number; enabled: boolean }[] }>(resolve => { release = resolve; });
  const invoke = spyOn(native, "invoke").mockImplementation(async <T>(_command: string, args?: unknown): Promise<T> => {
    const points = (args as { breakpoints: { line: number }[] }).breakpoints;
    if (points[0]?.line === 2) { entered(); return await first as T; }
    return { breakpoints: [{ line: 4, enabled: true }] } as T;
  });
  try {
    queueBreakpointRelocation("D:/work/Main.java", insertion());
    await started;
    queueBreakpointRelocation("D:/work/Main.java", { ...insertion(), previousContent: "\nfirst();\nrun();\n" });
    expect(invoke).toHaveBeenCalledTimes(1);
    release({ breakpoints: [{ line: 3, enabled: true }] });
    await flushBreakpointRelocations();
    expect(invoke).toHaveBeenCalledTimes(2);
    expect(useDebuggerStore.getState().breakpoints[0]?.line).toBe(3);
  } finally {
    release({ breakpoints: [{ line: 3, enabled: true }] });
    await flushBreakpointRelocations();
    invoke.mockRestore();
  }
});

test("clearing breakpoints retires an in-flight result without resurrecting them", async () => {
  useDebuggerStore.getState().actions.toggleBreakpoint("D:/work/Main.java", 1);
  let release!: (value: { breakpoints: { line: number; enabled: boolean }[] }) => void;
  let entered!: () => void;
  const started = new Promise<void>(resolve => { entered = resolve; });
  const response = new Promise<{ breakpoints: { line: number; enabled: boolean }[] }>(resolve => { release = resolve; });
  const invoke = spyOn(native, "invoke").mockImplementation(async <T>(): Promise<T> => { entered(); return await response as T; });
  try {
    queueBreakpointRelocation("D:/work/Main.java", insertion());
    await started;
    useDebuggerStore.getState().actions.clearBreakpoints();
    release({ breakpoints: [{ line: 3, enabled: true }] });
    await flushBreakpointRelocations();
    expect(useDebuggerStore.getState().breakpoints).toEqual([]);
  } finally {
    release({ breakpoints: [] });
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

test("multi-cursor native edits replay from the end and Core supplies intermediate text", async () => {
  const source = "first();\nsecond();\nrun();\n";
  const model = new SourceText(source, 1);
  const changes = model.apply([
    { rangeOffset: 0, rangeLength: 0, text: "\n" },
    { rangeOffset: 9, rangeLength: 0, text: "\n" },
  ], 2);
  useDebuggerStore.getState().actions.toggleBreakpoint("D:/work/Main.java", 2);
  const invoke = spyOn(native, "invoke")
    .mockResolvedValueOnce({ breakpoints: [{ line: 4, enabled: true }] })
    .mockResolvedValueOnce({ text: "first();\n\nsecond();\nrun();\n" })
    .mockResolvedValueOnce({ breakpoints: [{ line: 5, enabled: true }] });
  try {
    queueBreakpointRelocation("D:/work/Main.java", { previousContent: source, content: model.value, changes, external: false });
    await flushBreakpointRelocations();
    expect(invoke.mock.calls.map(call => call[0])).toEqual([
      "debug.relocateBreakpoints", "lsp.applyTextEdits", "debug.relocateBreakpoints",
    ]);
    expect(useDebuggerStore.getState().breakpoints[0]?.line).toBe(4);
  } finally { invoke.mockRestore(); }
});
