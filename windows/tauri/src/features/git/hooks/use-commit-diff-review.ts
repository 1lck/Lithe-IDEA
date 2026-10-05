import { useEffect, useLayoutEffect, useRef, useState, useSyncExternalStore } from "react";
import equal from "fast-deep-equal";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { getBufferById } from "@/features/editor/utils/buffer-index";
import { getFullContextFileDiff, getWorkingTreePathDiff } from "../api/git-diff-api";
import { resolveRepositoryForFile } from "../api/git-repo-api";
import { discardHunk, getGitStatus, setFilesStaged, stageHunk, unstageHunk } from "../api/git-status-api";
import { isGitChangeRelevant, subscribeToGitChanges } from "../events/git-events";
import { commitDiffPresentation, createCommitDiffReview, type CommitDiffReviewState } from "../services/commit-diff-review";
import { beginCommitDiffWrite, commitDiffWritePending } from "../runtime/commit-diff-write-state";
import { useWorkspaceCommitStore } from "../stores/git-workspace-commit.store";
import type { MultiFileDiff, WorkingTreeDiffTarget } from "../types/git-diff.types";
import { createSingleFileWorkingTreeDiff } from "../utils/working-tree-multi-diff";
import { getGitFileRepositoryRelativePath, resolveGitFileMutationPaths } from "../utils/git-status-selection";
import { createRequestGeneration } from "../utils/request-generation";

export function useCommitDiffReview(bufferId: string | null, fileKey: string,
  target?: WorkingTreeDiffTarget, legacyTarget?: WorkingTreeDiffTarget) {
  const owner = useRef<ReturnType<typeof createCommitDiffReview> | null>(null);
  const workflow = useWorkspaceCommitStore(state => state.workflow);
  const batch = useSyncExternalStore(workflow.subscribe, workflow.getState, workflow.getState);
  const [state, setState] = useState<CommitDiffReviewState>({ snapshot: null, blocks: [], busy: false });
  const navigationRequests = useRef(createRequestGeneration());
  const [fileNavigationBusy, setFileNavigationBusy] = useState(false);
  useLayoutEffect(() => {
    navigationRequests.current.begin();
    setFileNavigationBusy(false);
    return () => { navigationRequests.current.begin(); };
  }, [bufferId, fileKey]);
  const repoPath = target?.repoPath, filePath = target?.filePath, stagedView = target?.staged === true;
  const legacyRepo = legacyTarget?.repoPath, legacyPath = legacyTarget?.filePath;
  useEffect(() => {
    if (target || !bufferId || !legacyRepo || !legacyPath) return;
    let closed = false;
    // Old/fallback previews may contain text without a working-tree owner.
    // Repair metadata before enabling any writes, and never replace a new file's identity.
    const originalBuffer = getBufferById(useBufferStore.getState().buffers, bufferId);
    const original = originalBuffer?.type === "diff" ? originalBuffer.diffData : undefined;
    void resolveRepositoryForFile(legacyRepo, legacyPath).then(resolved => {
      if (closed) return;
      if (!resolved) { setState(previous => ({ ...previous, error: "read" })); return; }
      const state = useBufferStore.getState();
      const buffer = getBufferById(state.buffers, bufferId);
      const data = buffer?.type === "diff" ? buffer.diffData : undefined;
      if (data !== original || !data || !("files" in data) || data.isLoading
        || !data.commitPreview || data.commitHash !== "working-tree" || data.files.length !== 1
        || data.workingTreeTargets?.[fileKey]) return;
      state.actions.updateBufferContent(bufferId, "", false, { ...data,
        repoPath: resolved.repoPath,
        workingTreeTargets: { ...data.workingTreeTargets, [fileKey]: {
          repoPath: resolved.repoPath, filePath: resolved.filePath,
          untracked: data.files[0].is_new, ...(legacyTarget?.staged ? { staged: true } : {}),
        } },
      });
    }).catch(() => { if (!closed) setState(previous => ({ ...previous, error: "read" })); });
    return () => { closed = true; };
  }, [bufferId, fileKey, target, legacyRepo, legacyPath, legacyTarget?.staged]);
  useEffect(() => {
    setState({ snapshot: null, blocks: [], busy: false });
    if (!bufferId || !repoPath || !filePath) return;
    let closed = false;
    const current = (): MultiFileDiff | null => {
      const buffer = getBufferById(useBufferStore.getState().buffers, bufferId);
      if (buffer?.type !== "diff" || !buffer.diffData || !("files" in buffer.diffData)) return null;
      const data = buffer.diffData;
      const identity = data.workingTreeTargets?.[fileKey];
      return !data.isLoading && data.commitPreview && data.commitHash === "working-tree"
        && identity?.repoPath === repoPath && identity.filePath === filePath
        && Boolean(identity.staged) === stagedView ? data : null;
    };
    let statusFile: Parameters<typeof resolveGitFileMutationPaths>[0][number] | undefined;
    const instance = createCommitDiffReview({
      beginWrite: beginCommitDiffWrite,
      writeAvailable: () => !commitDiffWritePending(),
      canWrite: () => {
        const batch = useWorkspaceCommitStore.getState().workflow.getState();
        return Boolean(current()) && !batch.busy && !batch.review
          && !(batch.session && !batch.session.succeeded);
      },
      read: async () => {
        const status = await getGitStatus(repoPath);
        if (!status) throw new Error("Git status unavailable");
        const file = status.files.find(file => getGitFileRepositoryRelativePath(file) === filePath);
        if (!file) {
          if (!closed && current()) useBufferStore.getState().actions.closeBuffer(bufferId);
          return null;
        }
        statusFile = file;
        const [diff, indexed] = await Promise.all([
          stagedView ? getFullContextFileDiff(repoPath, filePath, true)
            : getWorkingTreePathDiff(repoPath, filePath, file.status === "untracked", file.originalPath, true),
          file.staged ? getFullContextFileDiff(repoPath, filePath, true) : Promise.resolve(null),
        ]);
        if (!diff || (file.staged && !indexed)) throw new Error("Git diff unavailable");
        return { diff, staged: indexed ?? { ...diff, lines: [] }, file };
      },
      stage: hunk => current() ? stageHunk(repoPath, hunk) : Promise.resolve(false),
      unstage: hunk => current() ? unstageHunk(repoPath, hunk) : Promise.resolve(false),
      rollback: hunk => current() ? discardHunk(repoPath, hunk) : Promise.resolve(false),
      includeFile: included => current() && statusFile
        ? setFilesStaged(repoPath, resolveGitFileMutationPaths([statusFile]), included) : Promise.resolve(false),
      changed: next => {
        if (closed || !current()) return;
        setState(next);
        const data = current()!, snapshot = next.snapshot;
        if (!snapshot) return;
        const nextTarget: WorkingTreeDiffTarget = {
          repoPath, filePath, untracked: snapshot.file.status === "untracked",
          ...(snapshot.file.originalPath ? { originalPath: snapshot.file.originalPath } : {}),
          ...(stagedView ? { staged: true } : {}),
          ...(!stagedView && snapshot.file.staged ? { hasStagedChanges: true } : {}),
        };
        const diff = commitDiffPresentation(snapshot, stagedView).diff;
        const updated = createSingleFileWorkingTreeDiff({ repoPath, fileKey, target: nextTarget,
          diff,
          title: data.title, commitPreview: true, workingTreeFileOrder: data.workingTreeFileOrder });
        if (!equal(data.files, updated.files) || !equal(data.workingTreeTargets, updated.workingTreeTargets)) {
          useBufferStore.getState().actions.updateBufferContent(bufferId, "", false, updated);
        }
      },
    });
    owner.current = instance;
    const unsubscribe = subscribeToGitChanges(change => {
      if (isGitChangeRelevant(change, repoPath, filePath)) void instance.refresh();
    });
    void instance.refresh();
    return () => {
      closed = true;
      unsubscribe();
      instance.dispose();
      if (owner.current === instance) owner.current = null;
    };
  }, [bufferId, fileKey, repoPath, filePath, stagedView]);
  const busy = state.busy || fileNavigationBusy || batch.busy || Boolean(batch.review)
    || Boolean(batch.session && !batch.session.succeeded);
  const navigateFile = async (direction: -1 | 1) => {
    if (busy || !bufferId || commitDiffWritePending()) return;
    const bufferState = useBufferStore.getState();
    const buffer = getBufferById(bufferState.buffers, bufferId);
    const data = buffer?.type === "diff" ? buffer.diffData : undefined;
    if (bufferState.activeBufferId !== bufferId || !data || !("files" in data)
      || !data.commitPreview || data.commitHash !== "working-tree" || data.isLoading) return;
    const order = data.workingTreeFileOrder;
    const index = order?.findIndex(entry => entry.fileKey === fileKey) ?? -1;
    const next = index >= 0 ? order?.[index + direction] : undefined;
    if (!next) return;
    const request = navigationRequests.current.begin();
    const current = () => {
      if (!navigationRequests.current.isCurrent(request)) return null;
      const state = useBufferStore.getState();
      const buffer = getBufferById(state.buffers, bufferId);
      const current = buffer?.type === "diff" ? buffer.diffData : undefined;
      return state.activeBufferId === bufferId && current && "files" in current
        && current.commitPreview && current.commitHash === "working-tree" && !current.isLoading
        && current.workingTreeFileOrder === order
        && (current.initiallySelectedFileKey ?? current.initiallyExpandedFileKey) === fileKey
        ? current : null;
    };
    setFileNavigationBusy(true);
    try {
      const target = next.target;
      const diff = target.staged
        ? await getFullContextFileDiff(target.repoPath, target.filePath, true)
        : await getWorkingTreePathDiff(target.repoPath, target.filePath, target.untracked, target.originalPath, true);
      const latest = current();
      if (!latest) return;
      if (!diff) throw new Error("Git diff unavailable");
      const updated = createSingleFileWorkingTreeDiff({ repoPath: target.repoPath,
        fileKey: next.fileKey, target, diff, title: latest.title, commitPreview: true,
        workingTreeFileOrder: order });
      useBufferStore.getState().actions.updateBufferContent(bufferId, "", false, updated);
    } catch {
      if (current()) setState(previous => ({ ...previous, error: "read" }));
    } finally {
      if (navigationRequests.current.isCurrent(request)) setFileNavigationBusy(false);
    }
  };
  return { ...state, busy, fileNavigationBusy, navigateFile,
    presentation: state.snapshot ? commitDiffPresentation(state.snapshot, stagedView) : undefined,
    refresh: () => owner.current?.refresh(),
    toggle: (id: string | null, included: boolean) => owner.current?.apply(id, included ? "include" : "exclude"),
    rollback: (id: string) => owner.current?.apply(id, "rollback") };
}
