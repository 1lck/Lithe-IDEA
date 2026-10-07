import { expect, test } from "bun:test";
import { debugDecorations } from "./monaco-debug-decorations";

test("Windows breakpoint paths share one owner and zero-based store lines become Monaco lines", () => {
  const result = debugDecorations(
    "D:/Work/Main.java",
    [
      { id: "mine", filePath: "d:\\work\\Main.java", line: 8, enabled: true, createdAt: 1 },
      { id: "other", filePath: "D:/Other/Main.java", line: 3, enabled: true, createdAt: 1 },
    ],
    { id: 7, name: "main", sourcePath: "d:/work/Main.java", line: 10, column: 1 },
  );
  expect(result).toHaveLength(2);
  expect(result[0]?.range.startLineNumber).toBe(9);
  expect(result[0]?.options.glyphMarginClassName).toBe("lithe-debug-breakpoint");
  expect(result[1]?.range.startLineNumber).toBe(10);
});

test("disabled breakpoints remain distinguishable and frames from another source are not highlighted", () => {
  const result = debugDecorations(
    "D:/Main.java",
    [{ id: "bp", filePath: "D:/Main.java", line: 0, enabled: false, createdAt: 1 }],
    { id: 2, name: "other", sourcePath: "D:/Other.java", line: 5, column: 1 },
  );
  expect(result).toHaveLength(1);
  expect(result[0]?.options.glyphMarginClassName).toBe("lithe-debug-breakpoint-disabled");
});
