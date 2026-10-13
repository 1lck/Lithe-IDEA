import type { ReviewRow } from "@lithe/editor/diff-review";
import { describe, expect, test } from "bun:test";
import fixture from "../../../../../../shared/fixtures/editor/diff-review-v1.json";
import type { GitDiff } from "../types/git.types";
import { parseRawDiffContent } from "./git-diff-parser";
import { monacoDiffHunk, monacoDiffRows } from "./monaco-diff-rows";

const filePatch = (hunks: string) =>
  `diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n${hunks}`;
const parse = (hunks: string) => parseRawDiffContent(filePatch(hunks), "f.txt") as GitDiff;
const fileLines = (from: number, to: number) =>
  Array.from({ length: to - from + 1 }, (_, index) => ` line ${from + index}`);

// Both patches are real `git diff` output for one edit of a 40-line file:
// `--unified=1073741823` for the review, and Git's default `--unified=3`.
const fullContext: GitDiff = {
  ...parse([
    "@@ -1,40 +1,40 @@",
    " line 1", "-line 2", "+line 2 changed", ...fileLines(3, 12), "+inserted after 12",
    ...fileLines(13, 18), "-line 19", ...fileLines(20, 37), "-line 38", "+line 37 changed",
    ...fileLines(39, 40), "",
  ].join("\n")),
  is_full_context: true,
};
const gitDefaultHunks = parse([
  "@@ -1,5 +1,5 @@", " line 1", "-line 2", "+line 2 changed", ...fileLines(3, 5),
  "@@ -10,13 +10,13 @@ line 9", ...fileLines(10, 12), "+inserted after 12", ...fileLines(13, 18),
  "-line 19", ...fileLines(20, 22),
  "@@ -35,6 +35,6 @@ line 34", ...fileLines(35, 37), "-line 38", "+line 37 changed",
  ...fileLines(39, 40), "",
].join("\n"));

describe("shared Monaco diff rows", () => {
  test("repository previews omit sparse hunk headers but retain source identity and staging hunks", () => {
    const original = monacoDiffRows(gitDefaultHunks);
    const hidden = monacoDiffRows(gitDefaultHunks, { hideHunkHeaders: true });
    expect(hidden).toEqual(original.filter(row => row.kind !== "information"));
    expect(hidden[0].id).toBe("line-1");
    expect(hidden[0].oldLine).toBe(1);
    expect(hidden[0].newLine).toBe(1);
    expect(monacoDiffHunk(gitDefaultHunks, hidden[0].hunkID!)?.lines[0].line_type).toBe("header");
    expect(original.some(row => row.left?.startsWith("@@"))).toBe(true);
    const text = { ...gitDefaultHunks, lines: [{ line_type: "context" as const, content: "@@ is actual content", old_line_number: 1, new_line_number: 1 }] };
    expect(monacoDiffRows(text, { hideHunkHeaders: true })[0].left).toBe("@@ is actual content");
  });
  test("matches the cross-platform sparse patch fixture", () => {
    expect(monacoDiffRows(fixture.gitDiff as GitDiff)).toEqual(fixture.rows as ReviewRow[]);
  });
  test("keeps empty added lines distinct from a missing original side", () => {
    const rows = monacoDiffRows({ ...fixture.gitDiff, lines: [
      { line_type: "added", content: "", new_line_number: 1 },
      { line_type: "added", content: "tail", new_line_number: 2 },
    ] });
    expect(rows.map(row => row.left)).toEqual([null, null]);
    expect(rows.map(row => row.right)).toEqual(["", "tail"]);
    expect(rows.map(row => row.id)).toEqual(["line-0", "line-1"]);
  });
});

describe("full-context Monaco diff rows", () => {
  // Regression for #557: the review holds every source line, so Monaco can
  // reveal folded regions instead of showing a sparse patch with nothing to expand.
  test("project the whole file without the full-file header row", () => {
    const rows = monacoDiffRows(fullContext);
    expect(rows.some(row => row.kind === "information")).toBe(false);
    expect(rows.filter(row => row.left !== null).map(row => row.oldLine))
      .toEqual(Array.from({ length: 40 }, (_, index) => index + 1));
    expect(rows.filter(row => row.right !== null).map(row => row.newLine))
      .toEqual(Array.from({ length: 40 }, (_, index) => index + 1));
    // Identity still addresses the host line array, so search results keep working.
    expect(rows[0].id).toBe("line-1");
  });

  test("anchor one action band per hunk and leave distant context unowned", () => {
    const rows = monacoDiffRows(fullContext);
    const anchors = rows.filter(row => row.actionAnchor);
    expect(anchors.map(row => row.hunkID)).toEqual(["hunk-2", "hunk-14", "hunk-40"]);
    expect(rows.find(row => row.oldLine === 30)?.hunkID).toBeNull();
  });

  test("stage the same hunks Git reports at its default context", () => {
    const anchors = monacoDiffRows(fullContext).filter(row => row.actionAnchor);
    const derived = anchors.map(row => monacoDiffHunk(fullContext, row.hunkID!));
    const expected = gitDefaultHunks.lines.flatMap((line, index) =>
      line.line_type === "header" ? [monacoDiffHunk(gitDefaultHunks, `hunk-${index}`)] : []);
    // Git appends the enclosing-line hint to headers; `git apply` ignores it.
    const withoutHint = (hunk: ReturnType<typeof monacoDiffHunk>) => hunk && {
      ...hunk,
      lines: hunk.lines.map(line => line.line_type === "header"
        ? { line_type: "header" as const, content: line.content.replace(/ @@.*$/, " @@") }
        : line),
    };
    expect(derived).toEqual(expected.map(withoutHint));
  });

  test("name the preceding line for a hunk with an empty side", () => {
    const added = parse("@@ -0,0 +1,2 @@\n+first\n+second\n");
    const hunk = monacoDiffHunk({ ...added, is_full_context: true }, "hunk-1");
    expect(hunk?.lines[0]).toEqual({ line_type: "header", content: "@@ -0,0 +1,2 @@" });
  });

  test("keep sparse-patch hunks when the patch is not marked full-context", () => {
    expect(monacoDiffRows(gitDefaultHunks).filter(row => row.kind === "information")).toHaveLength(3);
    expect(monacoDiffHunk({ ...fullContext, is_full_context: false }, "hunk-0")?.lines)
      .toHaveLength(fullContext.lines.length);
  });

  test("reject identities that do not start a derived hunk", () => {
    for (const id of ["hunk-0", "hunk-3", "hunk-30", "line-2"]) {
      expect(monacoDiffHunk(fullContext, id)).toBeNull();
    }
    expect(monacoDiffHunk({ ...fullContext, is_truncated: true }, "hunk-2")).toBeNull();
  });
});
