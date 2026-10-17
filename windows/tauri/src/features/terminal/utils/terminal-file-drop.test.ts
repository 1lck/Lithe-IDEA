import { describe, expect, test } from "bun:test";
import { formatPathsForTerminal, quoteTerminalPaths } from "./terminal-file-drop";

describe("quoteTerminalPaths", () => {
  test("leaves a plain relative path bare", () => {
    expect(quoteTerminalPaths(["src/Main.java"])).toBe("src/Main.java");
  });

  test("leaves a plain absolute path bare", () => {
    expect(quoteTerminalPaths(["C:\\work\\proj\\a.txt"])).toBe("C:\\work\\proj\\a.txt");
  });

  // A path with spaces must stay one shell argument, which is the whole reason
  // the terminal quotes before writing to the PTY.
  test("double-quotes a path containing spaces", () => {
    expect(quoteTerminalPaths(["my folder/a.ts"])).toBe('"my folder/a.ts"');
  });

  test("escapes an embedded quote by doubling it inside the quoted form", () => {
    expect(quoteTerminalPaths(['C:\\work\\my "dir"'])).toBe('"C:\\work\\my ""dir"""');
  });

  // Regression: workspace-relative paths dropped the backslash that used to make
  // an absolute Windows path match the quoting rule, so a file named
  // `README&whoami` reached cmd unquoted and `&` started a second command.
  // Every shell operator below must keep the path quoted and inert.
  for (const metacharacter of ["&", "|", "<", ">", ";", "^", "(", ")", "*", "?"]) {
    test(`quotes a path containing the shell operator ${metacharacter}`, () => {
      const path = `README${metacharacter}whoami`;
      expect(quoteTerminalPaths([path])).toBe(`"${path}"`);
    });
  }

  test("quotes a path containing PowerShell variable syntax", () => {
    expect(quoteTerminalPaths(["$(whoami).txt"])).toBe('"$(whoami).txt"');
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
