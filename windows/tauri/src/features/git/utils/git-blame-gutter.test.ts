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

const options = { language: "en-US", uncommittedLabel: "Uncommitted" };

describe("git blame gutter entries", () => {
  test("labels every line, including neighbours from the same commit", () => {
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
      expect(entries.get(lineNumber)?.text.startsWith("Ada, ")).toBe(true);
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
  test("zero pads the month and day in the app language", () => {
    const singleDigits = Date.UTC(2026, 7, 8, 12, 0, 0) / 1000;

    // Padded fields keep the annotation column from jumping between commits.
    expect(formatGitBlameDate(singleDigits, "en-US")).toBe("08/08/2026");
    expect(formatGitBlameDate(singleDigits, "zh-CN")).toBe("2026/08/08");
  });

  test("renders an absolute date in the app language", () => {
    const english = formatGitBlameDate(AUTHOR_TIME, "en-US");
    const chinese = formatGitBlameDate(AUTHOR_TIME, "zh-CN");

    // Both locales must carry the full year and day; a relative label would not.
    for (const text of [english, chinese]) {
      expect(text).toContain("2025");
      expect(text).toContain("30");
      expect(text).not.toMatch(/ago|前/);
    }
  });

  test("omits the date when the authoring time is missing", () => {
    expect(formatGitBlameDate(0, "en-US")).toBe("");
    expect(formatGitBlameDate(Number.NaN, "en-US")).toBe("");
  });
});
