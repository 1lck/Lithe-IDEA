import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import { fullDiff } from "@/test-utils/commit-diff-fixtures";
import { LocaleProvider } from "@/i18n/locale-provider";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import * as dialog from "@/ui/dialog";
import * as statusApi from "../api/git-status-api";
import * as diffApi from "../api/git-diff-api";
import * as repoApi from "../api/git-repo-api";
import { emitGitChanged } from "../events/git-events";
import { createSingleFileWorkingTreeDiff } from "../utils/working-tree-multi-diff";
import { useCommitDiffReview } from "./use-commit-diff-review";
import { commitDiffWritePending } from "../runtime/commit-diff-write-state";

const target = { repoPath: "C:/review", filePath: "file.txt", untracked: false };
const fileKey = "unstaged:file.txt";
const head = ["a", "b", "c", "d"], work = ["a", "B", "c", "D"];
const diff = fullDiff(head, work);
let current = createSingleFileWorkingTreeDiff({ repoPath: target.repoPath, fileKey,
  diff, target, commitPreview: true });
let indexed = head;
let review: ReturnType<typeof useCommitDiffReview>;
let restore: () => void, root: Root, container: HTMLElement;
let stage: ReturnType<typeof spyOn>, status: ReturnType<typeof spyOn>, workingDiff: ReturnType<typeof spyOn>;
const spies: Array<{ mockRestore(): void }> = [];
const actGlobal = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
let previousAct: boolean | undefined;
let previousCustomEvent: PropertyDescriptor | undefined;
function Harness() {
  review = useCommitDiffReview("review-buffer", fileKey, current.workingTreeTargets?.[fileKey], target);
  return null;
}
beforeEach(() => {
  restore = installHappyDom();
  previousCustomEvent = Object.getOwnPropertyDescriptor(globalThis, "CustomEvent");
  Object.defineProperty(globalThis, "CustomEvent", { configurable: true, writable: true, value: window.CustomEvent });
  previousAct = actGlobal.IS_REACT_ACT_ENVIRONMENT;
  actGlobal.IS_REACT_ACT_ENVIRONMENT = true;
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  indexed = head;
  current = createSingleFileWorkingTreeDiff({ repoPath: target.repoPath, fileKey, diff, target, commitPreview: true });
  const state = useBufferStore.getState();
  spies.push(spyOn(useBufferStore, "getState").mockImplementation(() => ({ ...state,
    activeBufferId: "review-buffer",
    buffers: [{ id: "review-buffer", type: "diff", path: "diff://review", diffData: current }],
    actions: { ...state.actions, updateBufferContent: (_id: string, _text: string, _dirty: boolean, next: typeof current) => { current = next; } },
  } as ReturnType<typeof useBufferStore.getState>)));
  status = spyOn(statusApi, "getGitStatus").mockImplementation(async () => ({ branch: "main", ahead: 0, behind: 0,
    files: [{ path: "file.txt", status: "modified", staged: indexed !== head, worktree: true }] }));
  stage = spyOn(statusApi, "stageHunk").mockImplementation(async () => {
    indexed = ["a", "B", "c", "d"];
    emitGitChanged({ repoPath: target.repoPath, filePath: target.filePath, source: "stage-hunk" });
    return true;
  });
  workingDiff = spyOn(diffApi, "getWorkingTreePathDiff").mockResolvedValue(diff);
  spies.push(status, stage, workingDiff,
    spyOn(diffApi, "getFullContextFileDiff").mockImplementation(async () => fullDiff(head, indexed)));
});
afterEach(async () => {
  try { await act(async () => root.unmount()); }
  finally {
    spies.splice(0).forEach(spy => spy.mockRestore());
    container.remove();
    if (previousAct === undefined) delete actGlobal.IS_REACT_ACT_ENVIRONMENT;
    else actGlobal.IS_REACT_ACT_ENVIRONMENT = previousAct;
    if (previousCustomEvent) Object.defineProperty(globalThis, "CustomEvent", previousCustomEvent);
    else Reflect.deleteProperty(globalThis, "CustomEvent");
    restore();
  }
});

test("Commit preview uses the owning repository, writes one block, retains other changes and refreshes inclusion", async () => {
  await act(async () => { root.render(<LocaleProvider language="en-US"><Harness /></LocaleProvider>); });
  expect(review.blocks).toHaveLength(2);
  await act(async () => { await review.toggle(review.blocks[0].id, true); });
  expect(stage).toHaveBeenCalledTimes(1);
  expect(stage.mock.calls[0][0]).toBe(target.repoPath);
  expect(review.blocks.map(block => block.checked)).toEqual([true, false]);
  expect(current.files[0].lines).toEqual(diff.lines);
  expect(current.workingTreeTargets![fileKey].hasStagedChanges).toBe(true);
  expect(commitDiffWritePending()).toBe(false);
});

test("block rollback is immediate even with discard confirmation enabled and retains included changes", async () => {
  const settings = useSettingsStore.getState();
  const confirm = spyOn(dialog, "showConfirmDialog").mockResolvedValue(false);
  const rollback = spyOn(statusApi, "discardHunk").mockImplementation(async () => {
    workingDiff.mockResolvedValue(fullDiff(head, indexed));
    return true;
  });
  spies.push(confirm, rollback, spyOn(useSettingsStore, "getState").mockReturnValue({
    ...settings, settings: { ...settings.settings, confirmBeforeDiscard: true },
  }));
  await act(async () => { root.render(<LocaleProvider language="en-US"><Harness /></LocaleProvider>); });
  await act(async () => { await review.toggle(review.blocks[0].id, true); });
  const unselected = review.blocks[1].id;
  let result: unknown;
  await act(async () => { result = await review.rollback(unselected); });
  expect(result).toBe("applied");
  expect(confirm).not.toHaveBeenCalled();
  expect(rollback).toHaveBeenCalledTimes(1);
  expect(rollback.mock.calls[0][0]).toBe(target.repoPath);
  expect(rollback.mock.calls[0][1].file_path).toBe(target.filePath);
  expect(review.blocks.map(block => block.checked)).toEqual([true]);
  expect(indexed).toEqual(["a", "B", "c", "d"]);
  expect(commitDiffWritePending()).toBe(false);
});

test("automatic refresh ignores events belonging to a different repository", async () => {
  await act(async () => { root.render(<LocaleProvider language="en-US"><Harness /></LocaleProvider>); });
  const initialReads = status.mock.calls.length;
  await act(async () => { emitGitChanged({ repoPath: "C:/other", filePath: "file.txt" }); });
  expect(status.mock.calls.length).toBe(initialReads);
  await act(async () => { emitGitChanged({ repoPath: target.repoPath, filePath: target.filePath }); });
  expect(status.mock.calls.length).toBeGreaterThan(initialReads);
});

test("index-only changes retain a file, index title and whole-file inclusion without inventing worktree blocks", async () => {
  indexed = ["a", "B", "c", "d"];
  workingDiff.mockResolvedValue({ ...diff, lines: [] });
  const include = spyOn(statusApi, "setFilesStaged").mockImplementation(async () => { indexed = head; return true; });
  spies.push(include);
  await act(async () => { root.render(<LocaleProvider language="en-US"><Harness /></LocaleProvider>); });
  expect(current.files).toHaveLength(1);
  expect(current.files[0].lines).toEqual(fullDiff(head, indexed).lines);
  expect(review.presentation).toMatchObject({ staged: true, included: true, indeterminate: true });
  expect(review.snapshot!.diff.lines).toHaveLength(0);
  expect(review.blocks).toHaveLength(0);
  await act(async () => { await review.toggle(null, true); });
  expect(include).toHaveBeenCalledWith(target.repoPath, [target.filePath], true);
  expect(stage).not.toHaveBeenCalled();
});

test.each(["binary", "renamed", "lossy"])("%s file inclusion stays mixed with staged and worktree changes", async kind => {
  indexed = ["a", "B", "c", "d"];
  workingDiff.mockResolvedValue({ ...diff, ...(kind === "binary" ? { is_binary: true }
    : kind === "renamed" ? { is_renamed: true } : { has_lossy_line_endings: true }) });
  const include = spyOn(statusApi, "setFilesStaged").mockResolvedValue(true);
  spies.push(include);
  await act(async () => { root.render(<LocaleProvider language="en-US"><Harness /></LocaleProvider>); });
  expect(review.blocks).toHaveLength(0);
  expect(review.presentation).toMatchObject({ included: true, indeterminate: true });
  await act(async () => { await review.toggle(null, true); });
  expect(include).toHaveBeenCalledWith(target.repoPath, [target.filePath], true);
  expect(stage).not.toHaveBeenCalled();
});

test("a restored preview without target metadata resolves its owner before enabling block controls", async () => {
  current = { ...current, workingTreeTargets: undefined };
  spies.push(spyOn(repoApi, "resolveRepositoryForFile").mockResolvedValue({
    repoPath: target.repoPath, filePath: target.filePath,
  }));
  const render = () => root.render(<LocaleProvider language="en-US"><Harness /></LocaleProvider>);
  await act(async () => { render(); });
  expect(current.workingTreeTargets?.[fileKey]).toEqual(target);
  await act(async () => { render(); });
  expect(review.blocks).toHaveLength(2);
  await act(async () => { await review.toggle(review.blocks[0].id, true); });
  expect(stage).toHaveBeenCalledTimes(1);
});

test("a late legacy owner lookup cannot replace a newly selected file", async () => {
  current = { ...current, workingTreeTargets: undefined };
  let resolve!: (value: { repoPath: string; filePath: string }) => void;
  const pending = new Promise<{ repoPath: string; filePath: string }>(done => { resolve = done; });
  spies.push(spyOn(repoApi, "resolveRepositoryForFile").mockReturnValue(pending));
  try {
    await act(async () => { root.render(<LocaleProvider language="en-US"><Harness /></LocaleProvider>); });
    current = { ...current, title: "new comparison" };
    await act(async () => { resolve({ repoPath: target.repoPath, filePath: target.filePath }); await pending; });
    expect(current.workingTreeTargets).toBeUndefined();
    expect(stage).not.toHaveBeenCalled();
  } finally { resolve({ repoPath: target.repoPath, filePath: target.filePath }); await pending; }
});

test("refresh and block inclusion retain file order and next file reads the actual nested owner", async () => {
  const next = { fileKey: "unstaged:nested/next.txt", target: {
    repoPath: "C:/review/nested", filePath: "next.txt", untracked: true,
  } };
  const order = [{ fileKey, target }, next];
  current = { ...current, workingTreeFileOrder: order };
  await act(async () => { root.render(<LocaleProvider language="en-US"><Harness /></LocaleProvider>); });
  await act(async () => { await review.toggle(review.blocks[0].id, true); });
  expect(current.workingTreeFileOrder).toBe(order);
  const read = spyOn(diffApi, "getWorkingTreePathDiff").mockResolvedValue({ ...diff, file_path: "next.txt" });
  spies.push(read);
  await act(async () => { await review.navigateFile(1); });
  expect(read).toHaveBeenCalledWith(next.target.repoPath, next.target.filePath, true, undefined, true);
  expect(current.initiallyExpandedFileKey).toBe(next.fileKey);
  expect(current.repoPath).toBe(next.target.repoPath);
  expect(current.workingTreeTargets?.[next.fileKey]).toEqual(next.target);
  expect(current.workingTreeFileOrder).toBe(order);
  expect(current.files).toHaveLength(1);
});

test("closing Commit while a next-file read is pending cannot replace or reopen the preview", async () => {
  current = { ...current, workingTreeFileOrder: [{ fileKey, target }, {
    fileKey: "unstaged:next.txt", target: { ...target, filePath: "next.txt" },
  }] };
  await act(async () => { root.render(<LocaleProvider language="en-US"><Harness /></LocaleProvider>); });
  let resolve!: (value: typeof diff) => void;
  const pending = new Promise<typeof diff>(done => { resolve = done; });
  spies.push(spyOn(diffApi, "getWorkingTreePathDiff").mockReturnValue(pending));
  let navigation!: Promise<void>;
  const original = current;
  try {
    await act(async () => { navigation = review.navigateFile(1); });
    expect(review.fileNavigationBusy).toBe(true);
    await act(async () => { root.render(null); });
    await act(async () => { resolve({ ...diff, file_path: "next.txt" }); await navigation; });
    expect(current).toBe(original);
  } finally { resolve(diff); await navigation; }
});

test("a late next-file read cannot overwrite a newer comparison in the same tab", async () => {
  current = { ...current, workingTreeFileOrder: [{ fileKey, target }, {
    fileKey: "unstaged:next.txt", target: { ...target, filePath: "next.txt" },
  }] };
  await act(async () => { root.render(<LocaleProvider language="en-US"><Harness /></LocaleProvider>); });
  let resolve!: (value: typeof diff) => void;
  const pending = new Promise<typeof diff>(done => { resolve = done; });
  spies.push(spyOn(diffApi, "getWorkingTreePathDiff").mockReturnValue(pending));
  let navigation!: Promise<void>;
  try {
    await act(async () => { navigation = review.navigateFile(1); });
    current = { ...current, initiallyExpandedFileKey: "unstaged:other.txt" };
    const newer = current;
    await act(async () => { resolve({ ...diff, file_path: "next.txt" }); await navigation; });
    expect(current).toBe(newer);
    expect(review.fileNavigationBusy).toBe(false);
  } finally { resolve(diff); await navigation; }
});
