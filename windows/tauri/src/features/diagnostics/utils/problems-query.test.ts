import { afterEach, expect, spyOn, test } from "bun:test";
import * as core from "@/platform/tauri-core";
import fixture from "../../../../../../shared/fixtures/lsp/problems-query-v1.json";
import type { Diagnostic } from "../types/diagnostics.types";
import { EMPTY_PROBLEMS_VIEW, queryProblems } from "./problems-query";

const diagnostic = (filePath: string, severity: Diagnostic["severity"], line: number): Diagnostic => ({
  severity,
  filePath,
  line,
  column: 0,
  endLine: line,
  endColumn: 1,
  message: `${severity} at ${line}`,
  source: "server-a",
});

let restore: (() => void) | null = null;
afterEach(() => {
  restore?.();
  restore = null;
});

test("submits Core facts with case-folded file identity and maps groups back to diagnostics", async () => {
  const diagnostics = [
    diagnostic("C:/Work/src/File10.txt", "warning", 4),
    diagnostic("C:/Work/src/File2.txt", "error", 9),
    diagnostic("c:/work/src/file2.txt", "info", 1),
  ];
  const requests: unknown[] = [];
  const spy = spyOn(core, "invoke").mockImplementation((async (command, args) => {
    expect(command).toBe("lsp.problems.query");
    requests.push(args);
    return {
      groups: [
        { key: "file:c:/work/src/file2.txt", kind: "file", indices: [1, 2] },
        { key: "file:c:/work/src/file10.txt", kind: "file", indices: [0] },
      ],
      files: [
        { fileKey: "c:/work/src/file2.txt", displayPath: "src/File2.txt", count: 2, highestSeverity: 1 },
        { fileKey: "c:/work/src/file10.txt", displayPath: "src/File10.txt", count: 1, highestSeverity: 2 },
      ],
      visibleCounts: { error: 1, warning: 1, information: 1, hint: 0, unknown: 0 },
      totalCounts: { error: 1, warning: 1, information: 1, hint: 2, unknown: 1 },
    };
  }) as typeof core.invoke);
  restore = () => spy.mockRestore();

  const view = await queryProblems(diagnostics, {
    groupBy: "file",
    sortBy: "severity",
    severities: { error: true, warning: true, info: false },
    currentFilePath: "C:/WORK/src/File2.txt",
    source: null,
    query: "  mismatch ",
    displayPath: (filePath) => filePath.replace(/^[A-Za-z]:\/work\//i, ""),
  });

  expect(requests).toEqual([
    {
      diagnostics: [
        { fileKey: "c:/work/src/file10.txt", displayPath: "src/File10.txt", line: 4, column: 0, severity: 2, message: "warning at 4", source: "server-a", code: null },
        { fileKey: "c:/work/src/file2.txt", displayPath: "src/File2.txt", line: 9, column: 0, severity: 1, message: "error at 9", source: "server-a", code: null },
        { fileKey: "c:/work/src/file2.txt", displayPath: "src/file2.txt", line: 1, column: 0, severity: 3, message: "info at 1", source: "server-a", code: null },
      ],
      groupBy: "file",
      sortBy: "severity",
      filter: { severities: [1, 2], fileKey: "c:/work/src/file2.txt", source: null, query: "mismatch" },
    },
  ]);
  expect(view.groups.map((group) => [group.id, group.items])).toEqual([
    ["file-C:/Work/src/File2.txt", [diagnostics[1], diagnostics[2]]],
    ["file-C:/Work/src/File10.txt", [diagnostics[0]]],
  ]);
  expect(view.visible).toEqual([diagnostics[1], diagnostics[2], diagnostics[0]]);
  expect(view.files).toEqual([
    { filePath: "C:/Work/src/File2.txt", displayPath: "src/File2.txt", total: 2, severity: "error" },
    { filePath: "C:/Work/src/File10.txt", displayPath: "src/File10.txt", total: 1, severity: "warning" },
  ]);
  expect(view.visibleBySeverity).toEqual({ error: 1, warning: 1, info: 1 });
  // Hints and unknown severities are shown with information.
  expect(view.totalBySeverity).toEqual({ error: 1, warning: 1, info: 4 });
});

test("severity groups use the shared fixture's Core response shape", async () => {
  const shared = fixture.cases.find((entry) => entry.request.groupBy === "severity");
  expect(shared).toBeDefined();
  const diagnostics = shared!.request.diagnostics.map((facts) =>
    diagnostic(facts.fileKey, facts.severity === 1 ? "error" : facts.severity === 2 ? "warning" : "info", facts.line),
  );
  const spy = spyOn(core, "invoke").mockResolvedValue(shared!.response as never);
  restore = () => spy.mockRestore();

  const view = await queryProblems(diagnostics, {
    groupBy: "severity",
    sortBy: "file",
    severities: { error: true, warning: true, info: true },
    currentFilePath: null,
    source: null,
    query: "",
    displayPath: (filePath) => filePath,
  });

  expect(view.groups.map((group) => [group.id, group.severity])).toEqual([
    ["severity-1", "error"],
    ["severity-2", "warning"],
    ["severity-3", "info"],
    ["severity-4", "info"],
    ["severity-0", "info"],
  ]);
  expect(view.groups[1]?.items).toEqual([diagnostics[0], diagnostics[4]]);
});

test("an empty list does not cross the IPC boundary", async () => {
  const spy = spyOn(core, "invoke");
  restore = () => spy.mockRestore();
  const view = await queryProblems([], {
    groupBy: "file",
    sortBy: "severity",
    severities: { error: true, warning: true, info: true },
    currentFilePath: null,
    source: null,
    query: "",
    displayPath: (filePath) => filePath,
  });
  expect(view).toBe(EMPTY_PROBLEMS_VIEW);
  expect(spy).not.toHaveBeenCalled();
});
