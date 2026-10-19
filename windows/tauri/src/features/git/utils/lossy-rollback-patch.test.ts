import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";
import { execSync } from "node:child_process";
import { mkdtempSync, rmSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const invoke = mock(async (command: string, _args?: unknown): Promise<unknown> => {
  if (command === "git_discover_repo") return null;
  if (command === "git.command") {
    return { output: "doc.txt: filter: unspecified\ndoc.txt: working-tree-encoding: unspecified\n", exitCode: 0 };
  }
  if (command === "git.diff") return { patch: "", exitCode: 0 };
  throw new Error(`Unexpected command: ${command}`);
});
const tauriCoreModule = await import("@/platform/tauri-core");
mock.module("@/platform/tauri-core", () => ({ ...tauriCoreModule, invoke }));

const { checkHunkRollbackAttributes } = await import("./lossy-rollback-attrs");
const { parseRawPatchLines, sliceRawHunkPatch, buildByteFaithfulHunk } = await import("./lossy-rollback-patch");

function git(dir: string, ...args: string[]): string {
  return execSync(`git ${args.join(" ")}`, { cwd: dir, encoding: "utf-8" });
}

function makeRepo(label: string, config: { autocrlf?: string; gitattributes?: string }): string {
  const dir = mkdtempSync(join(tmpdir(), `lithe-lossy-${label}-`));
  git(dir, "init", "-q");
  git(dir, "config", "user.name", "T");
  git(dir, "config", "user.email", "t@t");
  git(dir, "config", "core.autocrlf", config.autocrlf ?? "false");
  if (config.gitattributes) writeFileSync(join(dir, ".gitattributes"), config.gitattributes);
  return dir;
}

const repos: string[] = [];
afterEach(() => {
  for (const dir of repos.splice(0)) {
    try { rmSync(dir, { recursive: true, force: true }); } catch { /* best effort */ }
  }
});

describe("lossy hunk rollback patch slicing", () => {
  test("parseRawPatchLines preserves CR bytes and EOF markers", () => {
    const patch = "diff --git a/doc b/doc\n--- a/doc\n+++ b/doc\n@@ -1,3 +1,3 @@\n alpha\r\n-beta\r\n+BETA\r\n gamma\r\n\\ No newline at end of file\n";
    const lines = parseRawPatchLines(patch);
    // 4 content lines (alpha, -beta, +BETA, gamma) + 1 EOF marker; header skipped.
    expect(lines.length).toBe(5);
    expect(lines[0].content).toContain("\r");
    expect(lines[4].isEofMarker).toBe(true);
    expect(lines[0].oldLine).toBe(1);
    expect(lines[0].newLine).toBe(1);
  });

  test("sliceRawHunkPatch isolates the target hunk with original bytes", () => {
    const patch = "diff --git a/doc b/doc\n--- a/doc\n+++ b/doc\n@@ -1,3 +1,3 @@\n alpha\r\n-beta\r\n+BETA\r\n gamma\r\n";
    const sliced = sliceRawHunkPatch(patch, "doc", 2, 2);
    expect(sliced).toBeTruthy();
    expect(sliced!).toContain("-beta\r");
    expect(sliced!).toContain("+BETA\r");
    // U0: context lines are stripped from the output hunk.
    expect(sliced!).not.toContain(" alpha");
  });

  test("buildByteFaithfulHunk carries CR content in the hunk lines", () => {
    const diff = {
      file_path: "doc.txt", is_new: false, is_deleted: false, is_renamed: false,
      has_lossy_line_endings: true,
      writePatch: "diff --git a/doc.txt b/doc.txt\n--- a/doc.txt\n+++ b/doc.txt\n@@ -1,3 +1,3 @@\n alpha\r\n-beta\r\n+BETA\r\n gamma\r\n",
      lines: [],
    };
    const hunk = buildByteFaithfulHunk(diff as never, 2, 2);
    expect(hunk).toBeTruthy();
    expect(hunk!.lines.some((line) => line.content.includes("\r"))).toBe(true);
  });
});

describe("byte-faithful rollback with real Git", () => {
  test("autocrlf=false: CRLF file, rollback restores index content with CR preserved", () => {
    const dir = makeRepo("crlf", { autocrlf: "false" });
    repos.push(dir);
    const file = join(dir, "doc.txt");

    // HEAD: all CRLF
    writeFileSync(file, "alpha\r\nbravo\r\ncharlie\r\ndelta\r\necho\r\nfoxtrot\r\ngolf\r\nhotel\r\n");
    git(dir, "add", "-A");
    git(dir, "commit", "-qm", "initial");

    // Index: line 4 changed to STAGED (partial stage)
    writeFileSync(file, "alpha\r\nbravo\r\ncharlie\r\nSTAGED\r\necho\r\nfoxtrot\r\ngolf\r\nhotel\r\n");
    git(dir, "add", "doc.txt");

    // Worktree: line 2 also changed (unstaged), line 4 further changed
    writeFileSync(file, "alpha\r\nBRAVO-WT\r\ncharlie\r\nWORKTREE\r\necho\r\nfoxtrot\r\ngolf\r\nhotel\r\n");

    const staged = readFileSync(file);

    // Extract the worktree diff's raw patch (index → worktree)
    const rawPatch = git(dir, "diff", "--", "doc.txt");
    expect(rawPatch).toContain("\r");

    // Slice the hunk containing line 2 (the unstaged BRAVO change)
    const sliced = sliceRawHunkPatch(rawPatch, "doc.txt", 2, 2);
    expect(sliced).toBeTruthy();

    // Reverse-apply the sliced patch (the rollback operation)
    // Write the patch to a temp file and apply
    const patchFile = join(dir, ".test-patch");
    writeFileSync(patchFile, sliced!);
    git(dir, "apply", "--reverse", "--unidiff-zero", "--whitespace=nowarn", ".test-patch");

    const result = readFileSync(file);
    // Line 2 restored to index version (bravo), line 4 keeps WORKTREE
    expect(result.includes("bravo\r\n")).toBe(true);
    expect(result.includes("WORKTREE\r\n")).toBe(true);
    expect(result.includes("BRAVO-WT")).toBe(false);
    // CR bytes preserved throughout
    expect(result.equals(
      Buffer.from("alpha\r\nbravo\r\ncharlie\r\nWORKTREE\r\necho\r\nfoxtrot\r\ngolf\r\nhotel\r\n"),
    )).toBe(true);

    // Index unchanged
    const indexContent = git(dir, "show", ":doc.txt");
    expect(indexContent).toContain("STAGED");
  });

  test("autocrlf=true: Git converts LF patch to CRLF worktree faithfully", () => {
    const dir = makeRepo("autocrlf", { autocrlf: "true" });
    repos.push(dir);
    const file = join(dir, "doc.txt");

    writeFileSync(file, "alpha\r\nbravo\r\ncharlie\r\ndelta\r\necho\r\n");
    git(dir, "add", "-A");
    git(dir, "commit", "-qm", "initial");

    // Change line 2
    writeFileSync(file, "alpha\r\nBRAVO\r\ncharlie\r\ndelta\r\necho\r\n");

    // Git may output the patch with LF (converted), but git apply converts back
    const rawPatch = git(dir, "diff", "--", "doc.txt");
    const sliced = sliceRawHunkPatch(rawPatch, "doc.txt", 2, 2);
    expect(sliced).toBeTruthy();

    const patchFile = join(dir, ".test-patch");
    writeFileSync(patchFile, sliced!);
    git(dir, "apply", "--reverse", "--unidiff-zero", "--whitespace=nowarn", ".test-patch");

    const result = readFileSync(file);
    expect(result.includes("bravo")).toBe(true);
    expect(result.includes("BRAVO")).toBe(false);
    // The file maintains its line ending convention
    expect(result.includes("\r\n")).toBe(true);
  });

  test("gitattributes eol=crlf: rollback preserves CRLF", () => {
    const dir = makeRepo("attrs", { autocrlf: "false", gitattributes: "*.txt text eol=crlf\n" });
    repos.push(dir);
    const file = join(dir, "doc.txt");

    writeFileSync(file, "one\r\ntwo\r\nthree\r\nfour\r\nfive\r\n");
    git(dir, "add", "-A");
    git(dir, "commit", "-qm", "initial");

    writeFileSync(file, "one\r\nTWO-CHANGED\r\nthree\r\nfour\r\nfive\r\n");

    const rawPatch = git(dir, "diff", "--", "doc.txt");
    const sliced = sliceRawHunkPatch(rawPatch, "doc.txt", 2, 2);
    expect(sliced).toBeTruthy();

    const patchFile = join(dir, ".test-patch");
    writeFileSync(patchFile, sliced!);
    git(dir, "apply", "--reverse", "--unidiff-zero", "--whitespace=nowarn", ".test-patch");

    const result = readFileSync(file);
    expect(result.equals(Buffer.from("one\r\ntwo\r\nthree\r\nfour\r\nfive\r\n"))).toBe(true);
  });

  test("EOF marker in target block restores the missing newline", () => {
    const dir = makeRepo("eof", { autocrlf: "false" });
    repos.push(dir);
    const file = join(dir, "doc.txt");

    // HEAD has trailing newline
    writeFileSync(file, "alpha\nbravo\ncharlie\n");
    git(dir, "add", "-A");
    git(dir, "commit", "-qm", "initial");

    // Worktree: line 3 changed AND trailing newline removed
    writeFileSync(file, "alpha\nbravo\nCHARLIE-NO-EOL");

    const rawPatch = git(dir, "diff", "--", "doc.txt");
    // Verify the patch has the EOF marker
    expect(rawPatch).toContain("\\ No newline at end of file");

    const sliced = sliceRawHunkPatch(rawPatch, "doc.txt", 3, 3);
    expect(sliced).toBeTruthy();
    expect(sliced!).toContain("\\ No newline");

    const patchFile = join(dir, ".test-patch");
    writeFileSync(patchFile, sliced!);
    git(dir, "apply", "--reverse", "--unidiff-zero", "--whitespace=nowarn", ".test-patch");

    const result = readFileSync(file);
    // Line 3 restored to index version WITH the trailing newline
    expect(result.equals(Buffer.from("alpha\nbravo\ncharlie\n"))).toBe(true);
  });
});

describe("attribute safety check", () => {
  test("clean attributes pass the safety check", async () => {
    const safety = await checkHunkRollbackAttributes("C:/repo", "doc.txt");
    expect(safety.byteSafe).toBe(true);
  });
});
