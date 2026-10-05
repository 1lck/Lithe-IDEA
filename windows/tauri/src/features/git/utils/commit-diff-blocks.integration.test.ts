import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { GitDiff, GitHunk } from "../types/git.types";
import { parseRawDiffContent } from "./git-diff-parser";
import { planCommitDiffBlocks } from "./commit-diff-blocks";

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
    const patch = git(["diff", ...(staged ? ["--cached"] : ["HEAD"]), "--no-ext-diff", "--unified=2147483647", "--", "file.txt"]);
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
