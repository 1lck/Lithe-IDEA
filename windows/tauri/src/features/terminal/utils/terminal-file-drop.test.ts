import { describe, expect, test } from "bun:test";
import { formatPathsForTerminal, quoteTerminalPaths } from "./terminal-file-drop";

describe("quoteTerminalPaths", () => {
  test("leaves a path without special characters bare", () => {
    expect(quoteTerminalPaths(["src/Main.java"])).toBe("src/Main.java");
  });

  // A path with spaces must stay one shell argument, which is the whole reason
  // the terminal quotes before writing to the PTY.
  test("double-quotes a path containing spaces", () => {
    expect(quoteTerminalPaths(["my folder/a.ts"])).toBe('"my folder/a.ts"');
  });

  test("escapes quotes and backslashes inside the quoted form", () => {
    expect(quoteTerminalPaths(['C:\\work\\my "dir"'])).toBe('"C:\\\\work\\\\my \\"dir\\""');
  });

  test("joins multiple paths with a single space", () => {
    expect(quoteTerminalPaths(["a.ts", "pkg"])).toBe("a.ts pkg");
  });

  test("returns empty text for no paths", () => {
    expect(quoteTerminalPaths([])).toBe("");
  });
});

describe("formatPathsForTerminal", () => {
  test("omits the trailing space by default so paste output stays exact", () => {
    expect(formatPathsForTerminal(["a.ts"])).toBe("a.ts");
  });

  // Drag-and-drop appends a space so what the user types next stays separate.
  test("appends a trailing space when dropping", () => {
    expect(formatPathsForTerminal(["a.ts"], { trailingSpace: true })).toBe("a.ts ");
  });

  test("does not produce a lone space when there are no paths", () => {
    expect(formatPathsForTerminal([], { trailingSpace: true })).toBe("");
  });
});
