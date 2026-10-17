import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { installHappyDom } from "@/test-utils/happy-dom";
import { fullDiff } from "@/test-utils/commit-diff-fixtures";
import { LocaleProvider } from "@/i18n/locale-provider";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import * as dialog from "@/ui/dialog";
import * as statusApi from "@/features/git/api/git-status-api";
import * as diffApi from "@/features/git/api/git-diff-api";
import * as repoApi from "@/features/git/api/git-repo-api";
import { emitGitChanged } from "@/features/git/events/git-events";
import { createSingleFileWorkingTreeDiff } from "@/features/git/utils/working-tree-multi-diff";
import { useCommitDiffReview } from "@/features/git/hooks/use-commit-diff-review";
import { commitDiffWritePending } from "@/features/git/runtime/commit-diff-write-state";

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
function Harness({ followFile = false }: { followFile?: boolean }) {
  const key = followFile ? current.initiallySelectedFileKey ?? current.initiallyExpandedFileKey ?? fileKey : fileKey;
  review = useCommitDiffReview("review-buffer", key, current.workingTreeTargets?.[key], target);
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

test("block rollback confirms once when discard confirmation is enabled and retains included changes", async () => {
  const settings = useSettingsStore.getState();
  const confirm = spyOn(dialog, "showConfirmDialog").mockResolvedValue(true);
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
  expect(confirm).toHaveBeenCalledTimes(1);
  expect(rollback).toHaveBeenCalledTimes(1);
  expect(rollback.mock.calls[0][0]).toBe(target.repoPath);
  expect(rollback.mock.calls[0][1].file_path).toBe(target.filePath);
  expect(review.blocks.map(block => block.checked)).toEqual([true]);
  expect(indexed).toEqual(["a", "B", "c", "d"]);
  expect(commitDiffWritePending()).toBe(false);
});

test("block rollback cancellation skips the discard entirely", async () => {
  const settings = useSettingsStore.getState();
  const confirm = spyOn(dialog, "showConfirmDialog").mockResolvedValue(false);
  const rollback = spyOn(statusApi, "discardHunk");
  spies.push(confirm, rollback, spyOn(useSettingsStore, "getState").mockReturnValue({
    ...settings, settings: { ...settings.settings, confirmBeforeDiscard: true },
  }));
  await act(async () => { root.render(<LocaleProvider language="en-US"><Harness /></LocaleProvider>); });
  let result: unknown;
  await act(async () => { result = await review.rollback(review.blocks[0].id); });
  expect(result).toBe("cancelled");
  expect(confirm).toHaveBeenCalledTimes(1);
  expect(rollback).not.toHaveBeenCalled();
});

test("block rollback applies immediately when discard confirmation is disabled", async () => {
  const settings = useSettingsStore.getState();
  const confirm = spyOn(dialog, "showConfirmDialog");
  const rollback = spyOn(statusApi, "discardHunk").mockImplementation(async () => {
    workingDiff.mockResolvedValue(fullDiff(head, indexed));
    return true;
  });
  spies.push(confirm, rollback, spyOn(useSettingsStore, "getState").mockReturnValue({
    ...settings, settings: { ...settings.settings, confirmBeforeDiscard: false },
  }));
  await act(async () => { root.render(<LocaleProvider language="en-US"><Harness /></LocaleProvider>); });
  let result: unknown;
  await act(async () => { result = await review.rollback(review.blocks[0].id); });
  expect(result).toBe("applied");
  expect(confirm).not.toHaveBeenCalled();
  expect(rollback).toHaveBeenCalledTimes(1);
});

test("a confirmed rollback does not survive a snapshot refresh during the dialog", async () => {
  const settings = useSettingsStore.getState();
  let releaseDialog: ((value: boolean) => void) | undefined;
  const confirm = spyOn(dialog, "showConfirmDialog").mockImplementation(
    () => new Promise<boolean>((resolve) => { releaseDialog = resolve; }),
  );
  const rollback = spyOn(statusApi, "discardHunk");
  spies.push(confirm, rollback, spyOn(useSettingsStore, "getState").mockReturnValue({
    ...settings, settings: { ...settings.settings, confirmBeforeDiscard: true },
  }));
  await act(async () => { root.render(<LocaleProvider language="en-US"><Harness /></LocaleProvider>); });
  const pending = review.rollback(review.blocks[0].id);
  await act(async () => { await Promise.resolve(); });
  // A Git event refreshes the snapshot while the dialog is still open.
  await act(async () => { emitGitChanged({ repoPath: target.repoPath, filePath: target.filePath }); });
  releaseDialog?.(true);
  let result: unknown;
  await act(async () => { result = await pending; });
  expect(result).toBe("stale");
  expect(confirm).toHaveBeenCalledTimes(1);
  expect(rollback).not.toHaveBeenCalled();
});

test("repeat clicks while the confirmation is open stay on one dialog", async () => {
  const settings = useSettingsStore.getState();
  let releaseDialog: ((value: boolean) => void) | undefined;
  const confirm = spyOn(dialog, "showConfirmDialog").mockImplementation(
    () => new Promise<boolean>((resolve) => { releaseDialog = resolve; }),
  );
  const rollback = spyOn(statusApi, "discardHunk").mockImplementation(async () => {
    workingDiff.mockResolvedValue(fullDiff(head, indexed));
    return true;
  });
  spies.push(confirm, rollback, spyOn(useSettingsStore, "getState").mockReturnValue({
    ...settings, settings: { ...settings.settings, confirmBeforeDiscard: true },
  }));
  await act(async () => { root.render(<LocaleProvider language="en-US"><Harness /></LocaleProvider>); });
  const first = review.rollback(review.blocks[0].id);
  await act(async () => { await Promise.resolve(); });
  let second: unknown;
  await act(async () => { second = await review.rollback(review.blocks[0].id); });
  expect(second).toBe("ignored");
  releaseDialog?.(true);
  let result: unknown;
  await act(async () => { result = await first; });
  expect(result).toBe("applied");
  expect(confirm).toHaveBeenCalledTimes(1);
  expect(rollback).toHaveBeenCalledTimes(1);
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
  status.mockImplementation(async () => ({ branch: "main", ahead: 0, behind: 0,
    files: [{ path: "file.txt", status: "modified", staged: indexed !== head, worktree: true },
      { path: "next.txt", status: "untracked", staged: false, worktree: true }] }));
  await act(async () => { root.render(<LocaleProvider language="en-US"><Harness followFile /></LocaleProvider>); });
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
  expect(current.initialDifference).toBe("first");
  await act(async () => { await review.navigateFile(-1); });
  expect(current.initiallyExpandedFileKey).toBe(fileKey);
  expect(current.initialDifference).toBe("last");
  await act(async () => { await review.refresh(); });
  expect(current.initialDifference).toBe("last");
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

test("acceptance: refresh and confirm in the same batch must not roll back the refreshed content", async () => {
  const settings = useSettingsStore.getState();
  let releaseDialog: ((value: boolean) => void) | undefined;
  const confirm = spyOn(dialog, "showConfirmDialog").mockImplementation(
    () => new Promise<boolean>((resolve) => { releaseDialog = resolve; }),
  );
  const rollback = spyOn(statusApi, "discardHunk").mockResolvedValue(true);
  spies.push(confirm, rollback, spyOn(useSettingsStore, "getState").mockReturnValue({
    ...settings, settings: { ...settings.settings, confirmBeforeDiscard: true },
  }));
  await act(async () => { root.render(<LocaleProvider language="en-US"><Harness /></LocaleProvider>); });
  const pending = review.rollback(review.blocks[0].id);
  let result: unknown;
  try {
    workingDiff.mockResolvedValue(fullDiff(head, ["a", "NEW-UNCONFIRMED", "c", "D"]));
    await act(async () => {
      await review.refresh();
      releaseDialog?.(true);
      result = await pending;
    });
    console.log(JSON.stringify({ acceptanceCase: "same-batch-refresh-confirm", result,
      discardCalls: rollback.mock.calls.length,
      discardedNewContent: JSON.stringify(rollback.mock.calls).includes("NEW-UNCONFIRMED") }));
    expect(result).toBe("stale");
    expect(rollback).not.toHaveBeenCalled();
  } finally { releaseDialog?.(false); await pending; }
});
