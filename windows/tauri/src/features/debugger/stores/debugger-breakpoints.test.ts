import { afterEach, beforeEach, expect, test } from "bun:test";
import { installHappyDom } from "@/test-utils/happy-dom";
import { debugDecorations } from "../services/monaco-debug-decorations";
import { useDebuggerStore } from "./debugger.store";

let restoreDom: () => void;
let previous: ReturnType<typeof useDebuggerStore.getState>;
const storageKey = "lithe-debugger-breakpoints";
beforeEach(() => {
  restoreDom = installHappyDom();
  previous = useDebuggerStore.getState();
  useDebuggerStore.setState({ breakpoints: [] });
});
afterEach(() => {
  useDebuggerStore.setState(previous);
  restoreDom();
});

test("a second gutter toggle through a Windows casing/slash alias removes the displayed breakpoint", () => {
  const { actions } = useDebuggerStore.getState();
  actions.toggleBreakpoint("D:/Work/Main.java", 8);
  expect(
    debugDecorations("d:\\work\\MAIN.java", useDebuggerStore.getState().breakpoints),
  ).toHaveLength(1);
  actions.toggleBreakpoint("d:\\work\\MAIN.java", 8);
  expect(useDebuggerStore.getState().breakpoints).toHaveLength(0);
  expect(
    debugDecorations("D:/Work/Main.java", useDebuggerStore.getState().breakpoints),
  ).toHaveLength(0);
  expect(JSON.parse(window.localStorage.getItem(storageKey)!)).toEqual([]);
});

test("file queries use the same identity but keep original source spelling and other lines/modules", () => {
  const { actions } = useDebuggerStore.getState();
  actions.toggleBreakpoint("D:/Work/Main.java", 8);
  actions.toggleBreakpoint("D:/Work/Main.java", 12);
  actions.toggleBreakpoint("D:/Other/Main.java", 8);
  const owned = actions.getBreakpointsForFile("d:\\work\\MAIN.java");
  expect(owned.map((point) => point.line)).toEqual([8, 12]);
  expect(owned[0]?.filePath).toBe("D:/Work/Main.java");
  actions.toggleBreakpoint("d:/work/main.java", 8);
  expect(
    useDebuggerStore.getState().breakpoints.map((point) => [point.filePath, point.line]),
  ).toEqual([
    ["D:/Work/Main.java", 12],
    ["D:/Other/Main.java", 8],
  ]);
});

test("one gutter click removes all legacy aliases at that location, not a different file", () => {
  useDebuggerStore.setState({
    breakpoints: [
      { id: "first", filePath: "D:/Work/Main.java", line: 8, enabled: true, createdAt: 1 },
      { id: "alias", filePath: "d:\\work\\Main.java", line: 8, enabled: false, createdAt: 2 },
      { id: "other", filePath: "D:/Other/Main.java", line: 8, enabled: true, createdAt: 3 },
    ],
  });
  useDebuggerStore.getState().actions.toggleBreakpoint("D:/Work/Main.java", 8);
  expect(useDebuggerStore.getState().breakpoints.map((point) => point.id)).toEqual(["other"]);
  expect(
    debugDecorations("D:/Work/Main.java", useDebuggerStore.getState().breakpoints),
  ).toHaveLength(0);
  expect(
    JSON.parse(window.localStorage.getItem(storageKey)!).map((point: { id: string }) => point.id),
  ).toEqual(["other"]);
});

test("POSIX case-sensitive sources remain distinct in queries, projection and mutation", () => {
  const { actions } = useDebuggerStore.getState();
  actions.toggleBreakpoint("/work/Main.java", 0);
  actions.toggleBreakpoint("/work/main.java", 0);
  expect(useDebuggerStore.getState().breakpoints).toHaveLength(2);
  expect(actions.getBreakpointsForFile("/work/Main.java")).toHaveLength(1);
  expect(debugDecorations("/work/main.java", useDebuggerStore.getState().breakpoints)).toHaveLength(
    1,
  );
  actions.toggleBreakpoint("/work/main.java", 0);
  expect(useDebuggerStore.getState().breakpoints[0]?.filePath).toBe("/work/Main.java");
});

test("a hydrated breakpoint keeps its persisted spelling yet toggles through its displayed alias", () => {
  window.localStorage.setItem(
    storageKey,
    JSON.stringify([
      { id: "persisted", filePath: "d:\\work\\Main.java", line: 1, enabled: false, createdAt: 1 },
    ]),
  );
  const { actions } = useDebuggerStore.getState();
  actions.hydrate();
  expect(actions.getBreakpointsForFile("D:/Work/Main.java")[0]?.id).toBe("persisted");
  expect(useDebuggerStore.getState().breakpoints[0]?.filePath).toBe("d:\\work\\Main.java");
  actions.toggleBreakpoint("D:/Work/Main.java", 1);
  expect(useDebuggerStore.getState().breakpoints).toHaveLength(0);
});
