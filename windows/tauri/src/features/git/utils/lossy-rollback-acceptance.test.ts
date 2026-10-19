import { expect, mock, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { parseRawDiffContent } from "@/features/git/utils/git-diff-parser";
import { planCommitDiffBlocks } from "@/features/git/utils/commit-diff-blocks";
import { monacoDiffHunk, monacoDiffRows } from "@/features/git/utils/monaco-diff-rows";
import { createMonacoDiffHunkActions } from "@/features/git/utils/monaco-diff-hunk-actions";

function fixture(base: string, indexed: string, worktree: string) {
  const root = mkdtempSync(join(tmpdir(), "lithe-lossy-acc-"));
  const env = { ...process.env, GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "NUL", GIT_TERMINAL_PROMPT: "0" };
  const git = (args: string[], input?: string) => execFileSync("git", [
    "-c", "user.name=T", "-c", "user.email=t@t",
    "-c", "commit.gpgsign=false", "-c", "core.hooksPath=", ...args,
  ], { cwd: root, env, encoding: "utf8", timeout: 10000, windowsHide: true, input });
  const dispose = () => {
    if (dirname(resolve(root)).toLowerCase() !== resolve(tmpdir()).toLowerCase()
      || !basename(root).startsWith("lithe-lossy-acc-")) throw new Error("Unsafe cleanup target");
    rmSync(root, { recursive: true, force: true });
  };
  try {
    git(["init", "-q"]); git(["config", "core.autocrlf", "false"]);
    const file = join(root, "file.txt");
    writeFileSync(file, base); git(["add", "file.txt"]); git(["commit", "-qm", "base"]);
    writeFileSync(file, indexed); git(["add", "file.txt"]);
    writeFileSync(file, worktree);
    const readDiff = (args: string[]) => {
      const parsed = parseRawDiffContent(git(["diff", ...args, "--unified=9999", "--", "file.txt"]), "file.txt");
      return { ...("files" in parsed ? parsed.files[0] : parsed), is_full_context: true };
    };
    const raw = git(["diff", "--unified=3", "--", "file.txt"]);
    const indexDiff = { ...readDiff([]), writePatch: raw };
    const display = { ...readDiff(["HEAD"]), writePatch: raw };
    const staged = readDiff(["--cached"]);
    return { root, file, git, indexDiff, unstaged: indexDiff, display, staged, dispose };
  } catch (error) { dispose(); throw error; }
}
const crlf = (...lines: string[]) => lines.join("\r\n") + "\r\n";
test("partial staging in one display block restores only unstaged content", () => {
  const f = fixture("a\r\nb\r\nc\r\n", "A\r\nb\r\nc\r\n", "A\r\nB\r\nc\r\n");
  try {
    const before = f.git(["diff", "--cached", "--binary"]);
    const selected = planCommitDiffBlocks(f.display, f.staged)?.find(block => block.indeterminate);
    expect(selected?.canRollback).toBe(true);
    f.git(["apply", "--reverse", "--unidiff-zero", "--whitespace=nowarn", "-"], selected!.rollback!.rawPatch!);
    expect(readFileSync(f.file, "utf8")).toBe("A\r\nb\r\nc\r\n");
    expect(f.git(["diff", "--cached", "--binary"])).toBe(before);
  } finally { f.dispose(); }
}, 15000);

test("CRLF pure insertion exposes a byte faithful rollback", () => {
  const f = fixture("a\r\nb\r\nc\r\n", "a\r\nb\r\nc\r\n", "a\r\nNEW\r\nb\r\nc\r\n");
  try {
    const blocks = planCommitDiffBlocks(f.display, f.staged);
    console.log("pure insertion", JSON.stringify(blocks?.map(b => ({ canRollback: b.canRollback, leftStart: b.leftStart, rightStart: b.rightStart }))));
    expect(blocks?.[0]?.canRollback).toBe(true);
  } finally { f.dispose(); }
}, 15000);

test("selected display block does not rollback neighboring reverted staged content", () => {
  const f = fixture("a\r\nb\r\nc\r\nd\r\n", "A\r\nB\r\nc\r\nd\r\n", "A\r\nb\r\nC\r\nd\r\n");
  try {
    const indexBefore = f.git(["rev-parse", ":file.txt"]);
    const stagedBefore = f.git(["diff", "--cached", "--binary"]);
    const blocks = planCommitDiffBlocks(f.display, f.staged)!;
    const selected = blocks.find(block => block.rightStart === 2)!;
    expect(selected.canRollback).toBe(true);
    f.git(["apply", "--reverse", "--unidiff-zero", "--whitespace=nowarn", "-"], selected.rollback!.rawPatch!);
    const after = readFileSync(f.file, "utf8");
    console.log("neighbor staged reversion", JSON.stringify({ blockCount: blocks.length, selectedLine: 3, patch: selected.rollback!.rawPatch, after }));
    expect(f.git(["rev-parse", ":file.txt"])).toBe(indexBefore);
    expect(f.git(["diff", "--cached", "--binary"])).toBe(stagedBefore);
    expect(after).toBe("A\r\nb\r\nc\r\nd\r\n");
  } finally { f.dispose(); }
}, 15000);

test("Monaco CRLF replacement carries rawPatch through discard operation", async () => {
  const f = fixture("a\r\nb\r\nc\r\n", "a\r\nb\r\nc\r\n", "a\r\nB\r\nc\r\n");
  let owner: ReturnType<typeof createMonacoDiffHunkActions> | undefined;
  try {
    const target = monacoDiffRows(f.indexDiff).find(row => row.actionAnchor)!;
    let received: any;
    let probed: any;
    owner = createMonacoDiffHunkActions(f.indexDiff, { repoPath: f.root, isStaged: false, canDiscard: true }, {
      stage: async () => false, unstage: async () => false,
      discard: async (_repo, hunk) => { received = hunk; return true; },
      validate: async (hunk) => { probed = hunk; return true; },
    });
    expect(owner.actions).toEqual(["discard"]);
    expect(await owner.apply(target.hunkID!, "discard")).toBe("applied");
    console.log("monaco replacement", JSON.stringify({ hasRaw: Boolean(received?.rawPatch), lines: received?.lines }));
    expect(received?.rawPatch).toBeTruthy();
    // The zero-context write was confirmed first, against the same hunk.
    expect(probed).toBe(received);
  } finally { owner?.dispose(); f.dispose(); }
}, 15000);

test("Monaco hunk containing two CRLF changes rolls back both", () => {
  const f = fixture("a\r\nb\r\nc\r\nd\r\ne\r\nf\r\n", "a\r\nb\r\nc\r\nd\r\ne\r\nf\r\n", "a\r\nNEW\r\nb\r\nc\r\nD\r\ne\r\nf\r\n");
  try {
    const anchors = monacoDiffRows(f.indexDiff).filter(row => row.actionAnchor);
    expect(anchors.length).toBe(1);
    const hunk = monacoDiffHunk(f.indexDiff, anchors[0].hunkID!);
    expect(hunk?.rawPatch).toBeTruthy();
    f.git(["apply", "--reverse", "--unidiff-zero", "--whitespace=nowarn", "-"], hunk!.rawPatch!);
    console.log("monaco grouped after", JSON.stringify(readFileSync(f.file, "utf8")));
    expect(readFileSync(f.file, "utf8")).toBe("a\r\nb\r\nc\r\nd\r\ne\r\nf\r\n");
  } finally { f.dispose(); }
}, 15000);

test("Monaco EOF rollback preserves missing newline through the host patch format", () => {
  for (const [indexed, worktree] of [["a\nb\nc", "a\nB\nc"], ["a\nb\nc\n", "a\nb\nC"], ["a\nb\nc", "a\nb\nC\n"]]) {
    const f = fixture(indexed, indexed, worktree);
    try {
      const anchor = monacoDiffRows(f.indexDiff).find(row => row.actionAnchor)!;
      const hunk = monacoDiffHunk(f.indexDiff, anchor.hunkID!)!;
      // This mirrors the existing hunk_patch host branch when rawPatch is absent.
      const patch = hunk.rawPatch ?? `diff --git a/file.txt b/file.txt\n--- a/file.txt\n+++ b/file.txt\n${hunk.lines.map(line =>
        (line.line_type === "header" ? "" : line.line_type === "added" ? "+" : line.line_type === "removed" ? "-" : " ") + line.content + "\n").join("")}`;
      let failure: string | undefined;
      try { f.git(["apply", "--reverse", ...(hunk.rawPatch ? ["--unidiff-zero"] : []), "--whitespace=nowarn", "-"], patch); }
      catch (error) { failure = String(error); }
      const after = readFileSync(f.file, "utf8");
      console.log("monaco EOF", JSON.stringify({ indexed, worktree, hasRaw: Boolean(hunk.rawPatch), after, failure }));
      expect(failure).toBeUndefined();
      expect(after).toBe(indexed);
    } finally { f.dispose(); }
  }
}, 15000);

test("Commit deletion does not consume the following unrelated worktree replacement", () => {
  const base = crlf("a", "b", "c", "d", "e", "f", "g", "h");
  const indexed = crlf("a", "b", "c", "d", "e", "f", "g", "STAGED");
  const f = fixture(base, indexed, crlf("a", "d", "E", "f", "g", "STAGED"));
  try {
    const selected = planCommitDiffBlocks(f.display, f.staged)!.find(b => b.leftStart === 1)!;
    expect(selected.canRollback).toBe(true);
    const indexBefore = f.git(["rev-parse", ":file.txt"]);
    const stagedBefore = f.git(["diff", "--cached", "--binary"]);
    const patch = selected.rollback!.rawPatch!;
    f.git(["apply", "--reverse", "--unidiff-zero", "--whitespace=nowarn", "-"], patch);
    console.log("deletion scope", JSON.stringify({ patch, after: readFileSync(f.file, "utf8") }));
    expect(f.git(["rev-parse", ":file.txt"])).toBe(indexBefore);
    expect(f.git(["diff", "--cached", "--binary"])).toBe(stagedBefore);
    expect(readFileSync(f.file, "utf8")).toBe(crlf("a", "b", "c", "d", "E", "f", "g", "STAGED"));
  } finally { f.dispose(); }
}, 15000);

test("Commit rollback preserves old-side EOF marker ownership", () => {
  const f = fixture("a\nb\nc", "A\nb\nc", "A\nb\nC\n");
  try {
    const selected = planCommitDiffBlocks(f.display, f.staged)!.find(b => b.rightStart === 2)!;
    expect(selected.canRollback).toBe(true);
    const patch = selected.rollback!.rawPatch!;
    console.log("commit EOF patch", JSON.stringify(patch));
    f.git(["apply", "--reverse", "--unidiff-zero", "--whitespace=nowarn", "-"], patch);
    expect(readFileSync(f.file, "utf8")).toBe("A\nb\nc");
  } finally { f.dispose(); }
}, 15000);

test("Monaco grouped pure deletions restore at distinct original boundaries", () => {
  const base = crlf("a", "b", "c", "d", "e");
  const f = fixture(base, base, crlf("a", "c", "e"));
  try {
    const anchors = monacoDiffRows(f.unstaged).filter(row => row.actionAnchor);
    expect(anchors.length).toBe(1);
    const patch = monacoDiffHunk(f.unstaged, anchors[0].hunkID!)!.rawPatch!;
    console.log("monaco deletions patch", JSON.stringify(patch));
    f.git(["apply", "--reverse", "--unidiff-zero", "--whitespace=nowarn", "-"], patch);
    console.log("monaco deletions after", JSON.stringify(readFileSync(f.file, "utf8")));
    expect(readFileSync(f.file, "utf8")).toBe(base);
  } finally { f.dispose(); }
}, 15000);

test("Commit partial staging followed by an insertion exposes faithful rollback", () => {
  const f = fixture(crlf("a", "b", "c"), crlf("A", "b", "c"), crlf("A", "NEW", "b", "c"));
  try {
    const blocks = planCommitDiffBlocks(f.display, f.staged)!;
    expect(blocks[0].canRollback).toBe(true);
    f.git(["apply", "--reverse", "--unidiff-zero", "--whitespace=nowarn", "-"], blocks[0].rollback!.rawPatch!);
    expect(readFileSync(f.file, "utf8")).toBe(crlf("A", "b", "c"));
  } finally { f.dispose(); }
}, 15000);

test("acceptance: staged prefix must not redirect rollback to an unselected block", async () => {
  const root = mkdtempSync(join(tmpdir(), "lithe-api-block-acceptance-"));
  const env = { ...process.env, GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "NUL", GIT_TERMINAL_PROMPT: "0" };
  const git = (args: string[], input?: string) => execFileSync("git", [
    "-c", "user.name=Reviewer", "-c", "user.email=review@example.invalid",
    "-c", "commit.gpgsign=false", "-c", "core.hooksPath=", ...args,
  ], { cwd: root, env, encoding: "utf8", timeout: 5000, windowsHide: true, input });
  const core = await import("@/platform/tauri-core");
  mock.module("@/platform/tauri-core", () => ({ ...core, invoke: async (command: string, args: any) => {
    if (command === "git_discover_repo") return root;
    if (command === "git.command") return { output: git(args.arguments), exitCode: 0 };
    if (command === "git.diff") return { patch: git(["diff", "--unified=3", "--", "file.txt"]) };
    if (command === "git_diff_file") return parseRawDiffContent(git([
      "diff", ...(args.worktreeSnapshot ? ["HEAD"] : args.staged ? ["--cached"] : []),
      "--unified=9999", "--", "file.txt",
    ]), "file.txt");
    throw new Error(`Unexpected command: ${command}`);
  } }));
  try {
    const { getWorkingTreePathDiff, getFullContextFileDiff } = await import("@/features/git/api/git-diff-api");
    const { planCommitDiffBlocks } = await import("@/features/git/utils/commit-diff-blocks");
    git(["init", "-q"]); git(["config", "core.autocrlf", "false"]);
    const file = join(root, "file.txt");
    const base = Array.from({ length: 10 }, (_, i) => `line-${i + 1}`);
    writeFileSync(file, base.join("\r\n") + "\r\n");
    git(["add", "file.txt"]); git(["commit", "-qm", "base"]);
    const indexed = ["S1", "S2", "S3", ...base];
    writeFileSync(file, indexed.join("\r\n") + "\r\n"); git(["add", "file.txt"]);
    const indexBefore = git(["rev-parse", ":file.txt"]);
    const stagedBefore = git(["diff", "--cached", "--binary"]);
    const work = [...indexed]; work[5] = "WT-THREE"; work[8] = "WT-SIX";
    writeFileSync(file, work.join("\r\n") + "\r\n");
    const visible = await getWorkingTreePathDiff(root, "file.txt", false, undefined, true);
    const staged = await getFullContextFileDiff(root, "file.txt", true);
    const faithful = await getFullContextFileDiff(root, "file.txt", false);
    const blocks = planCommitDiffBlocks({ ...visible!, writePatch: faithful?.writePatch }, staged!);
    const selected = blocks?.find(block => block.rightStart + 1 === 9);
    expect(selected?.canRollback).toBe(true);
    const patch = selected?.rollback?.rawPatch;
    expect(patch).toBeTruthy();
    git(["apply", "--reverse", "--unidiff-zero", "--whitespace=nowarn", "-"], patch!);
    const after = readFileSync(file, "utf8").split("\r\n");
    console.log(JSON.stringify({ selectedLine: 9, patchHeader: patch!.match(/@@[^\n]+/g),
      unselectedLine6: after[5], selectedLine9: after[8] }));
    expect(git(["rev-parse", ":file.txt"])).toBe(indexBefore);
    expect(git(["diff", "--cached", "--binary"])).toBe(stagedBefore);
    expect(after[5]).toBe("WT-THREE");
    expect(after[8]).toBe("line-6");
  } finally {
    if (dirname(resolve(root)).toLowerCase() !== resolve(tmpdir()).toLowerCase()
      || !basename(root).startsWith("lithe-api-block-acceptance-")) throw new Error("Unsafe cleanup target");
    rmSync(root, { recursive: true, force: true });
  }
}, 15000);
