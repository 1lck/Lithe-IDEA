import { expect, mock, spyOn, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { parseRawDiffContent } from "@/features/git/utils/git-diff-parser";
import { monacoDiffRows } from "@/features/git/utils/monaco-diff-rows";
import { createMonacoDiffHunkActions } from "@/features/git/utils/monaco-diff-hunk-actions";

let current: ReturnType<typeof fixture> | undefined;
let afterDisplayRead: (() => void) | undefined;
function fixture() {
  const root = mkdtempSync(join(tmpdir(), "lithe-channel-review-"));
  const file = join(root, "file.txt");
  const env = { ...process.env, GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "NUL", GIT_TERMINAL_PROMPT: "0" };
  const git = (args: string[], input?: string) => execFileSync("git", [
    "-c", "user.name=Reviewer", "-c", "user.email=review@example.invalid",
    "-c", "commit.gpgsign=false", "-c", "core.hooksPath=", ...args,
  ], { cwd: root, env, encoding: "utf8", timeout: 5000, windowsHide: true, input });
  const dispose = () => {
    if (dirname(resolve(root)).toLowerCase() !== resolve(tmpdir()).toLowerCase()
      || !basename(root).startsWith("lithe-channel-review-")) throw new Error("Unsafe cleanup target");
    rmSync(root, { recursive: true, force: true });
  };
  try {
    git(["init", "-q"]); git(["config", "core.autocrlf", "false"]);
    writeFileSync(file, "a\r\nb\r\nc\r\n"); git(["add", "file.txt"]); git(["commit", "-qm", "base"]);
    writeFileSync(file, "a\r\nDISPLAYED\r\nc\r\n");
    return { root, file, git, dispose };
  } catch (error) { dispose(); throw error; }
}

const core = await import("@/platform/tauri-core");
mock.module("@/platform/tauri-core", () => ({ ...core, invoke: async (command: string, args: any, options?: { rawCoreResult?: boolean }) => {
  if (!current) throw new Error("Fixture is not active");
  if (command === "git_discover_repo") return current.root;
  if (command === "git.command") return { output: current.git(args.arguments), exitCode: 0 };
  // Like the real compatibility adapter, `git.diff` yields display diffs
  // unless the caller asks for Core's raw response.
  if (command === "git.diff") {
    const patch = current.git(["diff", "--unified=3", "--", "file.txt"]);
    return options?.rawCoreResult ? { patch, exitCode: 0, hasDecodingLoss: false } : [parseRawDiffContent(patch, "file.txt")];
  }
  if (command === "git_diff_file") {
    const diff = parseRawDiffContent(current.git(["diff", ...(args.worktreeSnapshot ? ["HEAD"] : args.staged ? ["--cached"] : []),
      "--unified=9999", "--", "file.txt"]), "file.txt");
    const mutate = afterDisplayRead;
    afterDisplayRead = undefined;
    mutate?.();
    return diff;
  }
  throw new Error(`Unexpected command: ${command}`);
} }));
const { getWorkingTreePathDiff, isWorktreeWritePatchCurrent } = await import("@/features/git/api/git-diff-api");

// The same operations MonacoGitDiff wires: a real zero-context apply guarded
// by the real pre-write probe.
function monacoOperations(f: ReturnType<typeof fixture>, writePatch: string | undefined) {
  return {
    stage: async () => false, unstage: async () => false,
    discard: async (_repo: string, hunk: { rawPatch?: string }) => {
      if (!hunk.rawPatch) return false;
      f.git(["apply", "--reverse", "--unidiff-zero", "--whitespace=nowarn", "-"], hunk.rawPatch);
      return true;
    },
    validate: () => isWorktreeWritePatchCurrent(f.root, "file.txt", writePatch),
  };
}
const { loadWorkingTreeFileDiff } = await import("@/features/git/services/working-tree-diff-refresh");

test("normal Monaco loading and refresh attach writePatch and perform faithful discard", async () => {
  const f = current = fixture();
  let owner: ReturnType<typeof createMonacoDiffHunkActions> | undefined;
  try {
    const diff = await loadWorkingTreeFileDiff({ repoPath: f.root, filePath: "file.txt", untracked: false });
    expect(diff?.writePatch).toBeTruthy();
    owner = createMonacoDiffHunkActions(diff!, { repoPath: f.root, isStaged: false, canDiscard: true },
      monacoOperations(f, diff!.writePatch));
    const target = monacoDiffRows(diff!).find(row => row.actionAnchor)!;
    expect(await owner.apply(target.hunkID!, "discard")).toBe("applied");
    expect(readFileSync(f.file, "utf8")).toBe("a\r\nb\r\nc\r\n");
  } finally { owner?.dispose(); afterDisplayRead = undefined; current = undefined; f.dispose(); }
}, 15000);

// Regression: the probe once re-read a three-line-context display diff and
// compared it with the full-context review, so every discard there was
// refused. The raw patch it now compares has a fixed context width.
test("a full-context review discards a current block through the pre-write probe", async () => {
  const f = current = fixture();
  let owner: ReturnType<typeof createMonacoDiffHunkActions> | undefined;
  try {
    const lines = (...content: string[]) => content.join("\r\n") + "\r\n";
    const body = Array.from({ length: 12 }, (_, index) => `line ${index + 1}`);
    writeFileSync(f.file, lines(...body)); f.git(["add", "file.txt"]); f.git(["commit", "-qm", "long-base"]);
    writeFileSync(f.file, lines(...body.slice(0, 6), "CHANGED", ...body.slice(7)));
    const diff = await getWorkingTreePathDiff(f.root, "file.txt", false, undefined, true);
    expect(diff?.is_full_context).toBe(true);
    expect(diff?.writePatch).toBeTruthy();
    owner = createMonacoDiffHunkActions(diff!, { repoPath: f.root, isStaged: false, canDiscard: true },
      monacoOperations(f, diff!.writePatch));
    const target = monacoDiffRows(diff!).find(row => row.actionAnchor)!;
    expect(await owner.apply(target.hunkID!, "discard")).toBe("applied");
    expect(readFileSync(f.file, "utf8")).toBe(lines(...body));
  } finally { owner?.dispose(); afterDisplayRead = undefined; current = undefined; f.dispose(); }
}, 15000);

test("an edit after the diff loaded refuses the zero-context discard as stale", async () => {
  for (const later of ["a\r\nDISPLAYED\r\nLATER\r\n", "a\r\nDISPLAYED\r\nc\n"]) {
    // The second edit only drops a CR, which the display strips.
    const f = current = fixture();
    let owner: ReturnType<typeof createMonacoDiffHunkActions> | undefined;
    try {
      const diff = await getWorkingTreePathDiff(f.root, "file.txt", false, undefined, true);
      expect(diff?.writePatch).toBeTruthy();
      owner = createMonacoDiffHunkActions(diff!, { repoPath: f.root, isStaged: false, canDiscard: true },
        monacoOperations(f, diff!.writePatch));
      writeFileSync(f.file, later);
      const target = monacoDiffRows(diff!).find(row => row.actionAnchor)!;
      expect(await owner.apply(target.hunkID!, "discard")).toBe("stale");
      expect(readFileSync(f.file, "utf8")).toBe(later);
    } finally { owner?.dispose(); afterDisplayRead = undefined; current = undefined; f.dispose(); }
  }
}, 15000);

test("a writePatch fetched after a file change must not discard content absent from the displayed snapshot", async () => {
  const f = current = fixture();
  let owner: ReturnType<typeof createMonacoDiffHunkActions> | undefined;
  try {
    const unseen = "a\r\nUNSEEN-LATER-EDIT\r\nc\r\n";
    afterDisplayRead = () => writeFileSync(f.file, unseen);
    const diff = await getWorkingTreePathDiff(f.root, "file.txt", false, undefined, true);
    expect(diff?.lines.some(line => line.content === "DISPLAYED")).toBe(true);
    expect(diff?.lines.some(line => line.content === "UNSEEN-LATER-EDIT")).toBe(false);
    if (!diff?.writePatch) {
      expect(readFileSync(f.file, "utf8")).toBe(unseen);
      return;
    }
    owner = createMonacoDiffHunkActions(diff!, { repoPath: f.root, isStaged: false, canDiscard: true }, {
      stage: async () => false, unstage: async () => false,
      discard: async (_repo, hunk) => {
        if (!hunk.rawPatch) return false;
        f.git(["apply", "--reverse", "--unidiff-zero", "--whitespace=nowarn", "-"], hunk.rawPatch);
        return true;
      },
    });
    const target = monacoDiffRows(diff!).find(row => row.actionAnchor)!;
    const result = await owner.apply(target.hunkID!, "discard");
    console.log("mixed snapshots", JSON.stringify({ displayed: diff?.lines.filter(l => l.line_type === "added"),
      raw: diff?.writePatch, result, after: readFileSync(f.file, "utf8") }));
    expect(readFileSync(f.file, "utf8")).toBe(unseen);
  } finally { owner?.dispose(); afterDisplayRead = undefined; current = undefined; f.dispose(); }
}, 15000);

test("Commit hook must not reattach a later faithful patch to an old display rejected by the API guard", async () => {
  const { act, createElement } = await import("react");
  const { createRoot } = await import("react-dom/client");
  const { installHappyDom } = await import("@/test-utils/happy-dom");
  const { useBufferStore } = await import("@/features/editor/stores/buffer.store");
  const statusApi = await import("@/features/git/api/git-status-api");
  const { useCommitDiffReview } = await import("@/features/git/hooks/use-commit-diff-review");
  const { createSingleFileWorkingTreeDiff } = await import("@/features/git/utils/working-tree-multi-diff");
  const restoreDom = installHappyDom();
  const actGlobal = globalThis as any;
  const priorAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  const priorEvent = Object.getOwnPropertyDescriptor(globalThis, "CustomEvent");
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  Object.defineProperty(globalThis, "CustomEvent", { configurable: true, writable: true, value: window.CustomEvent });
  const container = document.createElement("div"); document.body.append(container);
  const root = createRoot(container);
  const f = current = fixture();
  const spies: Array<{ mockRestore(): void }> = [];
  try {
    const target = { repoPath: f.root, filePath: "file.txt", untracked: false };
    const fileKey = "unstaged:file.txt";
    const parsedHead = parseRawDiffContent(f.git(["diff", "HEAD", "--unified=9999", "--", "file.txt"]), "file.txt");
    let data = createSingleFileWorkingTreeDiff({ repoPath: f.root, fileKey, target, commitPreview: true,
      diff: { ...("files" in parsedHead ? parsedHead.files[0] : parsedHead), is_full_context: true } });
    const state = useBufferStore.getState();
    spies.push(spyOn(useBufferStore, "getState").mockImplementation(() => ({ ...state,
      activeBufferId: "review-buffer", buffers: [{ id: "review-buffer", type: "diff", path: "diff://review", diffData: data }],
      actions: { ...state.actions, updateBufferContent: (_id: string, _text: string, _dirty: boolean, next: typeof data) => { data = next; } },
    } as any)));
    spies.push(spyOn(statusApi, "getGitStatus").mockResolvedValue({ branch: "main", ahead: 0, behind: 0,
      files: [{ path: "file.txt", status: "modified", staged: false, worktree: true }] }));
    spies.push(spyOn(statusApi, "discardHunk").mockImplementation(async (_repo, hunk) => {
      f.git(["apply", "--reverse", "--unidiff-zero", "--whitespace=nowarn", "-"], hunk.rawPatch!);
      return true;
    }));
    let review: ReturnType<typeof useCommitDiffReview>;
    function Harness() { review = useCommitDiffReview("review-buffer", fileKey, target); return null; }
    const unseen = "a\r\nUNSEEN-LATER-EDIT\r\nc\r\n";
    afterDisplayRead = () => writeFileSync(f.file, unseen);
    await act(async () => root.render(createElement(Harness)));
    expect(review!.snapshot?.diff.lines.some(line => line.content === "DISPLAYED")).toBe(true);
    let result: unknown = "disabled";
    const selected = review!.blocks.find(block => block.canRollback);
    if (selected) await act(async () => { result = await review!.rollback(selected.id); });
    console.log("Commit hook mixed snapshot", JSON.stringify({ result, displayed: review!.snapshot?.diff.lines,
      raw: review!.snapshot?.diff.writePatch, after: readFileSync(f.file, "utf8") }));
    expect(readFileSync(f.file, "utf8")).toBe(unseen);
  } finally {
    try { await act(async () => root.unmount()); }
    finally {
      spies.forEach(spy => spy.mockRestore()); container.remove();
      if (priorAct === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT; else actGlobal.IS_REACT_ACT_ENVIRONMENT = priorAct;
      if (priorEvent) Object.defineProperty(globalThis, "CustomEvent", priorEvent); else Reflect.deleteProperty(globalThis, "CustomEvent");
      restoreDom(); afterDisplayRead = undefined; current = undefined; f.dispose();
    }
  }
}, 15000);

test("Monaco must reject relocated edits even when the changed text sequence is identical", async () => {
  const f = current = fixture();
  let owner: ReturnType<typeof createMonacoDiffHunkActions> | undefined;
  try {
    const lines = (...content: string[]) => content.join("\r\n") + "\r\n";
    const base = lines("a", "b", "c", "b", "e", "f", "g", "h");
    writeFileSync(f.file, base); f.git(["add", "file.txt"]); f.git(["commit", "-qm", "larger-base"]);
    writeFileSync(f.file, lines("a", "DISPLAYED", "c", "b", "e", "F", "g", "h"));
    const unseen = lines("a", "b", "c", "DISPLAYED", "e", "F", "g", "h");
    afterDisplayRead = () => writeFileSync(f.file, unseen);
    const diff = await getWorkingTreePathDiff(f.root, "file.txt", false, undefined, true);
    expect(diff?.lines.filter(line => line.line_type === "added").map(line => line.new_line_number)).toEqual([2, 6]);
    if (!diff?.writePatch) { expect(readFileSync(f.file, "utf8")).toBe(unseen); return; }
    owner = createMonacoDiffHunkActions(diff, { repoPath: f.root, isStaged: false, canDiscard: true }, {
      stage: async () => false, unstage: async () => false,
      discard: async (_repo, hunk) => {
        if (!hunk.rawPatch) return false;
        f.git(["apply", "--reverse", "--unidiff-zero", "--whitespace=nowarn", "-"], hunk.rawPatch);
        return true;
      },
    });
    const anchor = monacoDiffRows(diff).find(row => row.actionAnchor)!;
    const result = await owner.apply(anchor.hunkID!, "discard");
    console.log("relocated edits", JSON.stringify({ displayedAddedLines: diff.lines.filter(l => l.line_type === "added"),
      raw: diff.writePatch, result, after: readFileSync(f.file, "utf8") }));
    expect(readFileSync(f.file, "utf8")).toBe(unseen);
  } finally { owner?.dispose(); afterDisplayRead = undefined; current = undefined; f.dispose(); }
}, 15000);
