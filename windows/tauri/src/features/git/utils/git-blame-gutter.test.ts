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
  test("labels only the first line of a commit block", () => {
    const entries = buildGitBlameGutterEntries(
      blame([
        blameLine({ line_number: 1 }),
        blameLine({ line_number: 2 }),
        blameLine({ line_number: 3, commit_hash: SECOND }),
      ]),
      options,
    );

    expect(entries.get(1)?.text.startsWith("Ada, ")).toBe(true);
    // Repeating the same author on every line of a block would bury the numbers.
    expect(entries.get(2)?.text).toBe("");
    expect(entries.get(3)?.text.startsWith("Ada, ")).toBe(true);
    expect(entries.get(2)?.commitHash).toBe(FIRST);
  });

  test("labels the same commit again when its lines are not contiguous", () => {
    const entries = buildGitBlameGutterEntries(
      blame([
        blameLine({ line_number: 1 }),
        blameLine({ line_number: 2, commit_hash: SECOND }),
        blameLine({ line_number: 3 }),
      ]),
      options,
    );

    expect(entries.get(1)?.text).not.toBe("");
    expect(entries.get(3)?.text).not.toBe("");
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
    expect(entries.get(2)?.text).toBe("");
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

  test("keeps the number column in place for continuation lines", () => {
    const entries = buildGitBlameGutterEntries(
      blame([blameLine({ line_number: 1 }), blameLine({ line_number: 2 })]),
      options,
    );

    // A zero-width placeholder holds the annotation column so the number does
    // not shift between the first and later lines of one block; the tooltip
    // stays, so hovering a continuation line still names its commit.
    expect(entries.get(2)?.text).toBe("");
    expect(gitBlameGutterHtml(entries.get(2)!)).toContain(">&#8203;</span>");
  });

  test("escapes the tooltip only when a short hash is present", () => {
    expect(escapeGitBlameHtml('a "b" <c>')).toBe("a &quot;b&quot; &lt;c&gt;");
    const entries = buildGitBlameGutterEntries(blame([blameLine({ line_number: 1 })]), options);
    expect(gitBlameGutterHtml(entries.get(1)!)).toContain(`· ${FIRST.slice(0, 8)}`);
  });
});

describe("git blame date", () => {
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
