import { afterEach, expect, spyOn, test } from "bun:test";
import fixture from "../../../../../../shared/fixtures/lsp/diagnostic-code-actions-v1.json";
import { useDiagnosticsStore } from "@/features/diagnostics/stores/diagnostics.store";
import * as adapter from "@/platform/lsp-core-adapter";
import { LspClient } from "./lsp-client";

afterEach(() => {
  useDiagnosticsStore.getState().actions.clearAllDiagnostics();
});

test.each(fixture.severityCases)("quick fixes preserve the original $name diagnostic", async (entry) => {
  const filePath = "C:/work/Main.java";
  const client = Object.create(LspClient.prototype) as LspClient;
  Object.assign(client, {
    activeLanguageServers: new Set(["C:/work:java"]),
    documents: new Map(),
    workspaceDiagnosticFiles: new Map(),
    workspaceDiagnosticLimitReported: false,
  });
  const original = { ...fixture.diagnostic, severity: entry.severity };
  (client as unknown as { applyDiagnosticsBatch(batch: adapter.LspDiagnosticsPublication[]): void })
    .applyDiagnosticsBatch([{ uri: fixture.uri, diagnostics: [original] }]);
  const diagnostic = useDiagnosticsStore.getState().actions.getDiagnosticsForFile(filePath)[0]!;
  const invoke = spyOn(adapter, "invokeLsp").mockResolvedValue([]);
  try {
    expect(diagnostic).toMatchObject({ severity: entry.displaySeverity });
    expect(diagnostic).toMatchObject({ line: 2, column: 4, endLine: 2, endColumn: 9 });
    // The presentation keeps a reference, not a second copy of the diagnostic.
    expect(diagnostic.lspDiagnostic).toBe(original);
    await client.getCodeActions(filePath, diagnostic);
    expect(invoke).toHaveBeenCalledWith("lsp_get_code_actions", expect.objectContaining({
      filePath,
      range: original.range,
      diagnostics: [original],
    }));
  } finally {
    invoke.mockRestore();
  }
});

test("non-LSP diagnostics request actions for a range without inventing LSP metadata", async () => {
  const client = Object.create(LspClient.prototype) as LspClient;
  const invoke = spyOn(adapter, "invokeLsp").mockResolvedValue([]);
  try {
    await client.getCodeActions("C:/work/Main.java", {
      severity: "warning", filePath: "C:/work/Main.java",
      line: 1, column: 2, endLine: 1, endColumn: 5, message: "Linter warning",
    });
    expect(invoke).toHaveBeenCalledWith("lsp_get_code_actions", expect.objectContaining({
      filePath: "C:/work/Main.java",
      range: { start: { line: 1, utf16Column: 2 }, end: { line: 1, utf16Column: 5 } },
      diagnostics: [],
    }));
  } finally {
    invoke.mockRestore();
  }
});
