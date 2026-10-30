import { afterEach, describe, expect, test } from "bun:test";
import { useDiagnosticsStore } from "@/features/diagnostics/stores/diagnostics.store";
import type { LspDiagnosticsPublication } from "@/platform/lsp-core-adapter";
import { LspClient } from "./lsp-client";

const error = (message: string) => ({
  range: { start: { line: 0, character: 0 }, end: { line: 0, character: 4 } },
  severity: 1,
  message,
});

function clientWithOpenDocument(filePath: string, version: number): LspClient {
  const client = Object.create(LspClient.prototype) as LspClient;
  Object.assign(client, {
    activeLanguageServers: new Set(["C:/work:java"]),
    documents: new Map([
      [filePath.toLowerCase(), { filePath, attachmentId: "a", version, content: "", phase: "open" }],
    ]),
    workspaceDiagnosticFiles: new Map(),
    workspaceDiagnosticLimitReported: false,
  });
  return client;
}

function applyBatch(client: LspClient, publications: LspDiagnosticsPublication[]): void {
  (client as unknown as { applyDiagnosticsBatch(batch: LspDiagnosticsPublication[]): void })
    .applyDiagnosticsBatch(publications);
}

function countStoreUpdates(): { readonly count: number; stop(): void } {
  let count = 0;
  const stop = useDiagnosticsStore.subscribe(() => {
    count += 1;
  });
  return {
    get count() {
      return count;
    },
    stop,
  };
}

afterEach(() => {
  useDiagnosticsStore.getState().actions.clearAllDiagnostics();
});

describe("batched LSP diagnostics", () => {
  test("a workspace import updates the store once for all of its files", () => {
    const client = clientWithOpenDocument("C:/work/Open.java", 3);
    const updates = countStoreUpdates();

    applyBatch(client, [
      { uri: "file:///C:/work/Open.java", version: 3, diagnostics: [error("open")] },
      ...Array.from({ length: 500 }, (_, index) => ({
        uri: `file:///C:/work/src/File${index}.java`,
        diagnostics: [error(`unopened ${index}`)],
      })),
      // Clean files nobody tracked and files outside the workspace never reach the store.
      { uri: "file:///C:/work/Clean.java", diagnostics: [] },
      { uri: "file:///D:/elsewhere/Other.java", diagnostics: [error("outside")] },
    ]);
    updates.stop();

    const byFile = useDiagnosticsStore.getState().diagnosticsByFile;
    expect(updates.count).toBe(1);
    expect(byFile.size).toBe(501);
    expect(byFile.get("C:/work/Open.java")?.map((diagnostic) => diagnostic.message)).toEqual(["open"]);
    expect(byFile.get("C:/work/src/File42.java")?.[0]).toMatchObject({
      message: "unopened 42",
      owner: "lsp",
      severity: "error",
    });
    expect(byFile.has("C:/work/Clean.java")).toBe(false);
    expect(byFile.has("D:/elsewhere/Other.java")).toBe(false);
  });

  test("a later batch clears fixed unopened files and keeps a newer open document", () => {
    const client = clientWithOpenDocument("C:/work/Open.java", 5);
    applyBatch(client, [
      { uri: "file:///C:/work/Open.java", version: 5, diagnostics: [error("current")] },
      { uri: "file:///C:/work/Fixed.java", diagnostics: [error("broken")] },
    ]);
    const updates = countStoreUpdates();

    applyBatch(client, [
      { uri: "file:///C:/work/Fixed.java", diagnostics: [] },
      // Published for an edit the editor has already moved past.
      { uri: "file:///C:/work/Open.java", version: 4, diagnostics: [error("stale")] },
    ]);
    updates.stop();

    const byFile = useDiagnosticsStore.getState().diagnosticsByFile;
    expect(updates.count).toBe(1);
    expect(byFile.has("C:/work/Fixed.java")).toBe(false);
    expect(byFile.get("C:/work/Open.java")?.map((diagnostic) => diagnostic.message)).toEqual(["current"]);
  });
});
