import { describe, expect, test } from "bun:test";
import type { CompletionItem } from "vscode-languageserver-protocol";
import {
  attachLspCompletionOrigin,
  lspCompletionOrigin,
  mergeResolvedCompletionSuggestion,
  toMonacoCompletionSuggestion,
} from "./lsp-completion";

const wordRange = {
  startLineNumber: 3,
  startColumn: 5,
  endLineNumber: 3,
  endColumn: 8,
};

describe("toMonacoCompletionSuggestion", () => {
  test("shows the class namespace and maps import edits onto Monaco ranges", () => {
    const item: CompletionItem = {
      label: "Carbon",
      kind: 7,
      insertText: "Carbon",
      labelDetails: { description: "Carbon\\Carbon" },
      additionalTextEdits: [
        {
          range: {
            start: { line: 1, character: 0 },
            end: { line: 1, character: 0 },
          },
          newText: "use Carbon\\Carbon;\n",
        },
      ],
    };

    expect(toMonacoCompletionSuggestion(item, wordRange)).toEqual({
      label: { label: "Carbon", description: "Carbon\\Carbon" },
      insertText: "Carbon",
      range: wordRange,
      detail: undefined,
      documentation: undefined,
      filterText: undefined,
      sortText: undefined,
      additionalTextEdits: [
        {
          range: {
            startLineNumber: 2,
            startColumn: 1,
            endLineNumber: 2,
            endColumn: 1,
          },
          text: "use Carbon\\Carbon;\n",
        },
      ],
      snippet: false,
    });
  });

  test("falls back to detail when the server omitted labelDetails", () => {
    const item: CompletionItem = {
      label: "Carbon",
      kind: 7,
      insertText: "Carbon",
      detail: "Carbon\\Carbon",
    };

    expect(toMonacoCompletionSuggestion(item, wordRange).label).toEqual({
      label: "Carbon",
      description: "Carbon\\Carbon",
    });
  });
});

describe("lspCompletionOrigin", () => {
  test("survives Monaco cloning the suggestion by object spread", () => {
    const suggestion = attachLspCompletionOrigin(
      { label: "Carbon", insertText: "Carbon" },
      {
        item: { label: "Carbon", data: { fqn: "Carbon\\Carbon" } },
        target: { filePath: "C:/work/index.php" },
        range: wordRange,
      },
    );
    const cloned = { ...suggestion };

    expect(lspCompletionOrigin(cloned)?.item.data).toEqual({ fqn: "Carbon\\Carbon" });
  });
});

describe("mergeResolvedCompletionSuggestion", () => {
  test("keeps the typed label and applies resolved namespace import edits", () => {
    const incomplete: CompletionItem = {
      label: "Carbon",
      kind: 7,
      insertText: "Carbon",
      labelDetails: { description: "Carbon\\Carbon" },
      data: { fqn: "Carbon\\Carbon" },
    };
    const resolved: CompletionItem = {
      label: "Carbon",
      kind: 7,
      insertText: "Carbon",
      detail: "class Carbon\\Carbon",
      additionalTextEdits: [
        {
          range: {
            start: { line: 1, character: 0 },
            end: { line: 1, character: 0 },
          },
          newText: "use Carbon\\Carbon;\n",
        },
      ],
      data: { fqn: "Carbon\\Carbon" },
    };

    const merged = mergeResolvedCompletionSuggestion(
      toMonacoCompletionSuggestion(incomplete, wordRange),
      resolved,
      wordRange,
    );

    expect(merged.label).toEqual({ label: "Carbon", description: "Carbon\\Carbon" });
    expect(merged.insertText).toBe("Carbon");
    expect(merged.detail).toBe("class Carbon\\Carbon");
    expect(merged.additionalTextEdits).toEqual([
      {
        range: {
          startLineNumber: 2,
          startColumn: 1,
          endLineNumber: 2,
          endColumn: 1,
        },
        text: "use Carbon\\Carbon;\n",
      },
    ]);
  });
});
