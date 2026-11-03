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
      const edit = item.payload.edit;
      const source = item.payload.source;
      const model = new SourceText(source, 1);
      const changes = model.apply([{
        rangeOffset: source.slice(0, edit.startUtf16Offset).replace(/\r\n/g, "\n").length,
        rangeLength: source.slice(edit.startUtf16Offset, edit.endUtf16Offset).replace(/\r\n/g, "\n").length,
        text: edit.replacement,
      }], 2);
      queueBreakpointRelocation(path, { previousContent: source, content: model.value, changes, anchorChanges: model.lastAnchorChanges, external: false });
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
