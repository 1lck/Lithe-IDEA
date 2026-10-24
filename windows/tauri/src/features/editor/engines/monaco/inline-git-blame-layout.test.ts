import { describe, expect, test } from "bun:test";
import { inlineGitBlameLayoutKey } from "./inline-git-blame-layout";

const uncommittedLine = {
  filePath: "src/LRUCache.java",
  lineNumber: 28,
  commitHash: "0000000000000000000000000000000000000000",
  content: "  Uncommitted changes",
};

describe("inline Git blame layout identity", () => {
  test("moves the hint when typing extends the same uncommitted line", () => {
    const before = inlineGitBlameLayoutKey({ ...uncommittedLine, column: 16 });
    const after = inlineGitBlameLayoutKey({ ...uncommittedLine, column: 20 });

    expect(after).not.toBe(before);
  });

  test("reuses the layout only when the position and blame content are unchanged", () => {
    const first = inlineGitBlameLayoutKey({ ...uncommittedLine, column: 16 });
    const same = inlineGitBlameLayoutKey({ ...uncommittedLine, column: 16 });
    const moved = inlineGitBlameLayoutKey({ ...uncommittedLine, column: 16, lineNumber: 29 });

    expect(same).toBe(first);
    expect(moved).not.toBe(first);
  });
});
