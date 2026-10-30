import { afterEach, describe, expect, test } from "bun:test";
import type { Diagnostic } from "../types/diagnostics.types";
import { useDiagnosticsStore } from "./diagnostics.store";

const diagnostic = (message: string): Diagnostic => ({
  severity: "error",
  filePath: "",
  line: 0,
  column: 0,
  endLine: 0,
  endColumn: 1,
  message,
  source: "test",
});

afterEach(() => {
  useDiagnosticsStore.getState().actions.clearAllDiagnostics();
});

describe("owner diagnostics batches", () => {
  test("replace and remove one owner's files while other owners keep theirs", () => {
    const { actions } = useDiagnosticsStore.getState();
    actions.setDiagnostics("C:/work/A.java", [diagnostic("lint")], "linter");
    actions.applyOwnerDiagnostics("lsp", [
      { filePath: "C:/work/A.java", diagnostics: [diagnostic("lsp a")] },
      { filePath: "C:/work/B.java", diagnostics: [diagnostic("lsp b")] },
    ]);

    actions.applyOwnerDiagnostics("lsp", [
      { filePath: "C:/work/A.java", diagnostics: null },
      { filePath: "C:/work/B.java", diagnostics: null },
    ]);

    const { diagnosticsByFile, diagnosticsByOwner } = useDiagnosticsStore.getState();
    expect(diagnosticsByFile.get("C:/work/A.java")?.map((entry) => entry.message)).toEqual(["lint"]);
    expect(diagnosticsByFile.has("C:/work/B.java")).toBe(false);
    expect([...(diagnosticsByOwner.get("C:/work/A.java")?.keys() ?? [])]).toEqual(["linter"]);
    expect(diagnosticsByOwner.has("C:/work/B.java")).toBe(false);
  });

  test("an empty batch leaves the store and its subscribers untouched", () => {
    const before = useDiagnosticsStore.getState();
    let notified = false;
    const stop = useDiagnosticsStore.subscribe(() => {
      notified = true;
    });
    useDiagnosticsStore.getState().actions.applyOwnerDiagnostics("lsp", []);
    stop();
    expect(notified).toBe(false);
    expect(useDiagnosticsStore.getState().diagnosticsByFile).toBe(before.diagnosticsByFile);
  });
});
