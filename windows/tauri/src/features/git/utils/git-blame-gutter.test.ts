import { describe, expect, test } from "bun:test";
import type { GitBlame, GitBlameLine } from "../types/git.types";
import {
  buildGitBlameGutterEntries,
  escapeGitBlameHtml,
  formatGitBlameDate,
  gitBlameGutterHtml,
} from "./git-blame-gutter";

const FIRST = "1".repeat(40);
const SECOND = "2".repeat(40);
const UNCOMMITTED = "0".repeat(40);
const AUTHOR_TIME = Date.UTC(2025, 9, 30, 12, 0, 0) / 1000;

function blameLine(overrides: Partial<GitBlameLine> & { line_number: number }): GitBlameLine {
  return {
    total_lines: 1,
    commit_hash: FIRST,
    is_uncommitted: false,
    author: "Ada",
    email: "ada@example.com",
    time: AUTHOR_TIME,
    commit: FIRST,
    ...overrides,
  };
}

function blame(lines: GitBlameLine[]): GitBlame {
  return { file_path: "src/main.ts", lines };
}

const options = { uncommittedLabel: "Uncommitted" };

describe("git blame gutter entries", () => {
  test("labels every line with the date first, then the author", () => {
    const entries = buildGitBlameGutterEntries(
      blame([
        blameLine({ line_number: 1 }),
        blameLine({ line_number: 2 }),
        blameLine({ line_number: 3, commit_hash: SECOND }),
      ]),
      options,
    );

    // IDEA annotates each line; a blank gutter on the second line of a block
    // reads as missing attribution rather than as shared authorship.
    for (const lineNumber of [1, 2, 3]) {
      expect(entries.get(lineNumber)?.text).toBe("2025/10/30, Ada");
    }
    expect(entries.get(2)?.commitHash).toBe(FIRST);
    expect(entries.get(3)?.commitHash).toBe(SECOND);
  });

  test("uses the uncommitted label and drops the hash from its tooltip", () => {
    const entries = buildGitBlameGutterEntries(
      blame([
        blameLine({ line_number: 4, commit_hash: UNCOMMITTED, is_uncommitted: true }),
      ]),
      options,
    );

    const entry = entries.get(4);
    expect(entry?.text).toBe("Uncommitted");
    expect(entry?.title).toBe("Uncommitted");
    expect(entry?.isUncommitted).toBe(true);
  });

  test("orders entries by line so a shuffled blame payload still renders", () => {
    const entries = buildGitBlameGutterEntries(
      blame([blameLine({ line_number: 2 }), blameLine({ line_number: 1 })]),
      options,
    );

    expect([...entries.keys()]).toEqual([1, 2]);
    expect(entries.get(1)?.text).not.toBe("");
    expect(entries.get(2)?.text).not.toBe("");
  });
});

describe("git blame gutter markup", () => {
  test("escapes author text instead of injecting it into the gutter", () => {
    const entries = buildGitBlameGutterEntries(
      blame([blameLine({ line_number: 1, author: '<img src=x onerror="alert(1)">' })]),
      options,
    );

    const html = gitBlameGutterHtml(entries.get(1)!);
    expect(html).not.toContain("<img");
    expect(html).toContain("&lt;img src=x onerror=&quot;alert(1)&quot;&gt;");
  });

  test("escapes the tooltip and carries the short hash", () => {
    expect(escapeGitBlameHtml('a "b" <c>')).toBe("a &quot;b&quot; &lt;c&gt;");
    const entries = buildGitBlameGutterEntries(blame([blameLine({ line_number: 1 })]), options);
    expect(gitBlameGutterHtml(entries.get(1)!)).toContain(`· ${FIRST.slice(0, 8)}`);
  });
});

describe("git blame date", () => {
  test("formats yyyy/M/d without padding", () => {
    const singleDigits = Date.UTC(2026, 7, 8, 12, 0, 0) / 1000;

    // IDEA and the macOS workbench both annotate with an unpadded y/M/d date.
    expect(formatGitBlameDate(singleDigits)).toBe("2026/8/8");
    expect(formatGitBlameDate(AUTHOR_TIME)).toBe("2025/10/30");
  });

  test("renders an absolute date", () => {
    const text = formatGitBlameDate(AUTHOR_TIME);

    expect(text).toContain("2025");
    expect(text).toContain("30");
    expect(text).not.toMatch(/ago|前/);
  });

  test("omits the date when the authoring time is missing", () => {
    expect(formatGitBlameDate(0)).toBe("");
    expect(formatGitBlameDate(Number.NaN)).toBe("");
  });
});
