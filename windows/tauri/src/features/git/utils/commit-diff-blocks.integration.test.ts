import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { GitDiff, GitHunk } from "../types/git.types";
import { parseRawDiffContent } from "./git-diff-parser";
import { planCommitDiffBlocks } from "./commit-diff-blocks";
import { commitDiffPresentation } from "../services/commit-diff-review";
import { FULL_FILE_CONTEXT_LINES } from "./git-diff-helpers";
import { monacoDiffRows } from "./monaco-diff-rows";
import { planIndependentCommitDiff } from "./independent-commit-diff";

// Integration lane: actual local Git, with a deadline on every subprocess and
// exclusive temporary ownership. No worktree or index from the user's repo is used.
test("real Git commits only a checked block, unchecks it independently, and rolls back without changing the index", () => {
  const root = mkdtempSync(join(tmpdir(), "lithe-commit-blocks-"));
  const git = (args: string[], input?: string) => execFileSync("git", ["-c", "core.autocrlf=false",
    "-c", "commit.gpgsign=false", "-c", "core.hooksPath=", ...args],
    { cwd: root, encoding: "utf8", timeout: 5000, input, windowsHide: true });
  const hunkPatch = (hunk: GitHunk) => `diff --git a/file.txt b/file.txt\n--- a/file.txt\n+++ b/file.txt\n`
    + hunk.lines.map(line => (line.line_type === "header" ? "" : line.line_type === "added" ? "+"
      : line.line_type === "removed" ? "-" : " ") + line.content + "\n").join("");
  const read = (staged: boolean): GitDiff => {
    const patch = git(["diff", ...(staged ? ["--cached"] : ["HEAD"]), "--no-ext-diff", `--unified=${FULL_FILE_CONTEXT_LINES}`, "--", "file.txt"]);
    return { ...parseRawDiffContent(patch, "file.txt") as GitDiff, is_full_context: true };
  };
  try {
    git(["init", "--quiet"]);
    git(["config", "user.name", "Diff integration"]);
    git(["config", "user.email", "diff@example.invalid"]);
    writeFileSync(join(root, "file.txt"), "a\nb\nc\nd\ne\n");
    git(["add", "file.txt"]);
    git(["commit", "--quiet", "-m", "base"]);
    writeFileSync(join(root, "file.txt"), "a\nnew\nb\nc\nD\ne\n");
    let blocks = planCommitDiffBlocks(read(false), read(true))!;
    git(["apply", "--cached", "--whitespace=nowarn", "-"], hunkPatch(blocks[0].stage!));
    blocks = planCommitDiffBlocks(read(false), read(true))!;
    expect(blocks.map(block => block.checked)).toEqual([true, false]);
    git(["apply", "--cached", "--whitespace=nowarn", "-"], hunkPatch(blocks[1].stage!));
    blocks = planCommitDiffBlocks(read(false), read(true))!;
    expect(blocks.every(block => block.checked)).toBe(true);
    git(["apply", "--cached", "--reverse", "--whitespace=nowarn", "-"], hunkPatch(blocks[0].unstage!));
    blocks = planCommitDiffBlocks(read(false), read(true))!;
    expect(blocks.map(block => block.checked)).toEqual([false, true]);
    expect(git(["show", ":file.txt"])).toBe("a\nb\nc\nD\ne\n");
    git(["apply", "--reverse", "--whitespace=nowarn", "-"], hunkPatch(blocks[0].rollback!));
    expect(git(["show", ":file.txt"])).toBe("a\nb\nc\nD\ne\n");
    git(["commit", "--quiet", "-m", "selected block"]);
    expect(git(["show", "HEAD:file.txt"])).toBe("a\nb\nc\nD\ne\n");
    expect(git(["status", "--porcelain"])).toBe("");
  } finally { rmSync(root, { recursive: true, force: true }); }
}, 15000);

test.each(["a", "B", "a\r\n", "B\r\n"])("real Git preserves exact %j bytes through whole-file fallback", content => {
  const root = mkdtempSync(join(tmpdir(), "lithe-commit-bytes-"));
  const git = (args: string[]) => execFileSync("git", ["-c", "core.autocrlf=false",
    "-c", "core.attributesFile=", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=", ...args],
    { cwd: root, timeout: 5000, windowsHide: true });
  const read = (staged: boolean): GitDiff => ({ ...parseRawDiffContent(git(["diff",
    ...(staged ? ["--cached"] : ["HEAD"]), `--unified=${FULL_FILE_CONTEXT_LINES}`, "--", "file.txt"]).toString("utf8"),
    "file.txt") as GitDiff, is_full_context: true });
  try {
    git(["init", "--quiet"]);
    git(["config", "user.name", "Diff integration"]);
    git(["config", "user.email", "diff@example.invalid"]);
    writeFileSync(join(root, "file.txt"), "a\n");
    git(["add", "file.txt"]);
    git(["commit", "--quiet", "-m", "base"]);
    writeFileSync(join(root, "file.txt"), content);
    expect(read(false).has_lossy_line_endings).toBe(true);
    expect(planCommitDiffBlocks(read(false), read(true))).toBeNull();
    expect(git(["show", ":file.txt"])).toEqual(Buffer.from("a\n"));
    git(["add", "file.txt"]);
    expect(git(["show", ":file.txt"])).toEqual(Buffer.from(content));
    git(["commit", "--quiet", "-m", "exact bytes"]);
    expect(git(["show", "HEAD:file.txt"])).toEqual(Buffer.from(content));
    expect(git(["status", "--porcelain"]).toString()).toBe("");
  } finally { rmSync(root, { recursive: true, force: true }); }
}, 15000);

test.each([false, true])("real Git index-only/binary inclusion uses actual status (binary=%j)", binary => {
  const root = mkdtempSync(join(tmpdir(), "lithe-commit-index-"));
  const git = (args: string[]) => execFileSync("git", ["-c", "core.autocrlf=false",
    "-c", "commit.gpgsign=false", "-c", "core.hooksPath=", ...args],
    { cwd: root, timeout: 5000, windowsHide: true });
  const read = (staged: boolean): GitDiff => ({ ...parseRawDiffContent(git(["diff",
    ...(staged ? ["--cached"] : ["HEAD"]), `--unified=${FULL_FILE_CONTEXT_LINES}`, "--", "file.txt"]).toString("utf8"),
    "file.txt") as GitDiff, is_full_context: true });
  const base = binary ? "a\0\n" : "a\n", indexed = binary ? "B\0\n" : "B\n";
  const work = binary ? "C\0\n" : base;
  try {
    git(["init", "--quiet"]);
    git(["config", "user.name", "Diff integration"]);
    git(["config", "user.email", "diff@example.invalid"]);
    writeFileSync(join(root, "file.txt"), base);
    git(["add", "file.txt"]);
    git(["commit", "--quiet", "-m", "base"]);
    writeFileSync(join(root, "file.txt"), indexed);
    git(["add", "file.txt"]);
    writeFileSync(join(root, "file.txt"), work);
    const status = git(["status", "--porcelain"]).toString();
    expect(status.startsWith("MM ")).toBe(true);
    const snapshot = { diff: read(false), staged: read(true), file: {
      path: "file.txt", status: "modified" as const, staged: status[0] === "M", worktree: status[1] === "M",
    } };
    const presentation = commitDiffPresentation(snapshot, false);
    expect(presentation.indeterminate).toBe(true);
    expect(presentation.staged).toBe(!binary);
    expect(binary ? presentation.diff.is_binary : presentation.diff.lines.some(line => line.content === "B")).toBe(true);
    expect(planCommitDiffBlocks(snapshot.diff, snapshot.staged)).toBeNull();
    expect(git(["show", ":file.txt"])).toEqual(Buffer.from(indexed));
    git(["add", "file.txt"]);
    expect(git(["show", ":file.txt"])).toEqual(Buffer.from(work));
  } finally { rmSync(root, { recursive: true, force: true }); }
}, 15000);

test.each(["worktree", "snapshot", "staged"])("real Git full-context %s review projects multiple edits without repeating source lines", mode => {
  const root = mkdtempSync(join(tmpdir(), "lithe-diff-context-"));
  const git = (args: string[]) => execFileSync("git", ["-c", "core.autocrlf=false",
    "-c", "commit.gpgsign=false", "-c", "core.hooksPath=", ...args],
    { cwd: root, encoding: "utf8", timeout: 5000, windowsHide: true });
  const before = Array.from({ length: 40 }, (_, index) => `line ${index + 1}`);
  const after = [...before];
  after[5] = "first replacement";
  after[19] = "second replacement";
  after[33] = "third replacement";
  try {
    git(["init", "--quiet"]);
    git(["config", "user.name", "Diff integration"]);
    git(["config", "user.email", "diff@example.invalid"]);
    writeFileSync(join(root, "file.txt"), before.join("\n") + "\n");
    git(["add", "file.txt"]);
    git(["commit", "--quiet", "-m", "base"]);
    writeFileSync(join(root, "file.txt"), after.join("\n") + "\n");
    if (mode === "staged") git(["add", "file.txt"]);
    const patch = git([mode === "snapshot" ? "diff-files" : "diff",
      ...(mode === "staged" ? ["--cached"] : []), "--no-ext-diff",
      `--unified=${FULL_FILE_CONTEXT_LINES}`, "--", "file.txt"]);
    const diff = { ...parseRawDiffContent(patch, "file.txt") as GitDiff, is_full_context: true };
    expect(diff.lines.filter(line => line.line_type === "header")).toHaveLength(1);
    const rows = monacoDiffRows(diff, { hideHunkHeaders: true });
    const plan = planIndependentCommitDiff(rows, false, new Set());
    expect(plan.left.map(row => row.left)).toEqual(before);
    expect(plan.right.map(row => row.right)).toEqual(after);
    expect(plan.left.map(row => row.oldLine)).toEqual(Array.from({ length: 40 }, (_, index) => index + 1));
    expect(plan.right.map(row => row.newLine)).toEqual(Array.from({ length: 40 }, (_, index) => index + 1));
    expect(plan.changes).toHaveLength(3);
    expect(planCommitDiffBlocks(diff, { ...diff, lines: [] })).toHaveLength(3);
  } finally { rmSync(root, { recursive: true, force: true }); }
}, 15000);
