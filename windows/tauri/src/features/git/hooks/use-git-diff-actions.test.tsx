import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import * as dialogs from "@/ui/dialog";
import * as paneSync from "@/features/editor/stores/buffer-pane-sync";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import * as commitsApi from "../api/git-commits-api";
import * as diffApi from "../api/git-diff-api";
import * as repoApi from "../api/git-repo-api";
import type { GitCommit, GitDiff, GitFile } from "../types/git.types";
import { useGitDiffActions } from "./use-git-diff-actions";

const commit = (hash: string): GitCommit => ({
  hash,
  shortHash: hash,
  parentHashes: [],
  message: hash,
  author: "Developer",
  date: "2026/09/01",
  decorations: "",
});
const commits = new Map(["first", "second"].map((hash) => [hash, commit(hash)]));
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let originalAct: boolean | undefined;
let restoreDom: () => void;
let container: HTMLDivElement;
let root: Root;
let actions: ReturnType<typeof useGitDiffActions>;
let openBuffer: ReturnType<typeof spyOn>;
const spies: Array<{ mockRestore(): void }> = [];
const pending = new Map<string, () => void>();
const requests: Promise<void>[] = [];

function Harness({ repo, files = [], previewScope = null }: { repo: string; files?: GitFile[]; previewScope?: string | null }) {
  actions = useGitDiffActions({
    activeRepoPath: repo,
    commitPreviewScope: previewScope,
    commitByHash: commits,
    gitFileByPath: new Map(files.map(file => [file.path, file])),
    workingTreeDiffEntriesByScope: { all: files.map(file => [`unstaged:${file.path}`, file]), staged: [], unstaged: [] },
  });
  return null;
}
async function render(repo = "C:/repo-a", files: GitFile[] = []) {
  await act(async () => {
    root.render(
      <LocaleProvider language="en-US">
        <Harness repo={repo} files={files} />
      </LocaleProvider>,
    );
  });
}
async function start(hash: string) {
  await act(async () => {
    requests.push(actions.viewCommitDiff(hash));
    await Promise.resolve();
  });
  expect(pending.has(hash)).toBe(true);
}
async function finish(hash: string) {
  const release = pending.get(hash);
  if (!release) throw new Error(`Missing pending message for ${hash}`);
  await act(async () => {
    release();
    await Promise.resolve();
  });
  pending.delete(hash);
}

beforeEach(() => {
  restoreDom = installHappyDom();
  originalAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  openBuffer = spyOn(useBufferStore.getState().actions, "openBuffer").mockReturnValue(
    "diff-buffer",
  );
  spies.push(
    openBuffer,
    spyOn(dialogs, "showAlertDialog").mockResolvedValue(undefined),
    spyOn(paneSync, "activateMainEditorPane").mockReturnValue(null),
    spyOn(diffApi, "getCommitDiff").mockResolvedValue([
      { file_path: "file.txt", lines: [], is_new: false, is_deleted: false, is_renamed: false },
    ] satisfies GitDiff[]),
    spyOn(commitsApi, "withCommitDescription").mockImplementation(
      (_repo, selected) =>
        new Promise((resolve) =>
          pending.set(selected.hash, () =>
            resolve({ ...selected, description: `Body ${selected.hash}` }),
          ),
        ),
    ),
  );
});
afterEach(async () => {
  try {
    await act(async () => {
      root.unmount();
      for (const release of pending.values()) release();
      await Promise.all(requests);
    });
  } finally {
    pending.clear();
    requests.length = 0;
    for (const spy of spies.splice(0)) spy.mockRestore();
    container.remove();
    restoreDom();
    if (originalAct === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
    else actGlobal.IS_REACT_ACT_ENVIRONMENT = originalAct;
  }
});

test("opens the selected commit diff with its loaded message", async () => {
  await render();
  await start("first");
  await finish("first");
  expect(openBuffer).toHaveBeenCalledTimes(1);
  expect(openBuffer.mock.calls[0]?.[7]).toMatchObject({
    commitDescription: "Body first",
    repoPath: "C:/repo-a",
  });
  expect(actions.isLoadingCommitDiff).toBe(false);
  expect(openBuffer.mock.calls[0]?.[7]).not.toHaveProperty("preserveFocus");
});

test("Automatic commit preview opens its first file without requesting editor focus", async () => {
  await act(async () => root.render(<LocaleProvider language="en-US"><Harness repo="C:/repo-a" previewScope="commit:first" /></LocaleProvider>));
  await act(async () => { await actions.previewCommitFileDiff({ kind: "commit", commit: commit("first") }, "file.txt"); });
  expect(openBuffer.mock.calls[0]?.[7]).toMatchObject({ commitFilePreview: true, preserveFocus: true });
});
test("late message cannot open an old diff or clear the newer loading state", async () => {
  await render();
  await start("first");
  await start("second");
  await finish("first");
  expect(openBuffer).not.toHaveBeenCalled();
  expect(actions.isLoadingCommitDiff).toBe(true);
  await finish("second");
  expect(openBuffer).toHaveBeenCalledTimes(1);
  expect(openBuffer.mock.calls[0]?.[7]).toMatchObject({ commitDescription: "Body second" });
});
test("switching repositories invalidates a pending message even when returning to the original", async () => {
  await render();
  await start("first");
  await render("C:/repo-b");
  await render();
  await finish("first");
  expect(openBuffer).not.toHaveBeenCalled();
  expect(actions.isLoadingCommitDiff).toBe(false);
});
test("unmount prevents a pending message from opening an editor", async () => {
  await render();
  await start("first");
  await act(async () => {
    root.render(null);
  });
  await finish("first");
  expect(openBuffer).not.toHaveBeenCalled();
});

test("a file absent from the status mapping still opens an owned HEAD-to-worktree Commit review", async () => {
  const resolved = { repoPath: "C:/repo-a/nested", filePath: "file.txt" };
  const diff: GitDiff = { file_path: "file.txt", is_new: false, is_deleted: false, is_renamed: false,
    is_full_context: true, lines: [{ line_type: "header", content: "@@ -1 +1 @@" },
      { line_type: "removed", content: "old" }, { line_type: "added", content: "new" }] };
  const worktree = spyOn(diffApi, "getWorkingTreePathDiff").mockResolvedValue(diff);
  spies.push(worktree, spyOn(repoApi, "resolveRepositoryForFile").mockResolvedValue(resolved));
  await render();
  await act(async () => { await actions.viewFileDiff("nested/file.txt", false); });
  expect(worktree).toHaveBeenCalledWith(resolved.repoPath, resolved.filePath, false, undefined, true);
  expect(openBuffer.mock.calls[0]?.[7]).toMatchObject({
    repoPath: resolved.repoPath, commitPreview: true,
    workingTreeTargets: { "unstaged:nested/file.txt": { ...resolved, untracked: false } },
  });
});

test("Commit file click captures the file order without eagerly reading other comparisons", async () => {
  const worktree = spyOn(diffApi, "getWorkingTreePathDiff").mockResolvedValue(null);
  spies.push(worktree);
  await render("C:/repo-a", [
    { path: "a.txt", status: "modified", staged: false, worktree: true },
    { path: "b.txt", status: "untracked", staged: false, worktree: true },
  ]);
  await act(async () => { await actions.viewFileDiff("a.txt"); });
  expect(worktree).toHaveBeenCalledTimes(1);
  expect(worktree.mock.calls[0][1]).toBe("a.txt");
  expect(openBuffer.mock.calls[0][7]).toMatchObject({ workingTreeFileOrder: [
    { fileKey: "unstaged:a.txt", target: { repoPath: "C:/repo-a", filePath: "a.txt", untracked: false } },
    { fileKey: "unstaged:b.txt", target: { repoPath: "C:/repo-a", filePath: "b.txt", untracked: true } },
  ] });
});
