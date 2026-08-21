import { describe, expect, test } from "bun:test";
import {
  hasLspDocumentChanges,
  queueLspDocumentChanges,
  takeLspDocumentChanges,
} from "./pending-document-changes";

describe("pending LSP document changes", () => {
  test("coalesces range changes until the debounce flush", () => {
    queueLspDocumentChanges("src/main.ts", [
      { rangeOffset: 0, rangeLength: 0, text: "a", startLine: 0, startColumn: 0, endLine: 0, endColumn: 0 },
    ]);
    queueLspDocumentChanges("src/main.ts", [
      { rangeOffset: 1, rangeLength: 0, text: "b", startLine: 0, startColumn: 1, endLine: 0, endColumn: 1 },
    ]);
    expect(hasLspDocumentChanges("src/main.ts")).toBe(true);
    expect(takeLspDocumentChanges("src/main.ts")).toHaveLength(2);
    expect(hasLspDocumentChanges("src/main.ts")).toBe(false);
  });
});
