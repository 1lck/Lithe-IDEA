import type { MultiFileDiff } from "@/features/git/types/git-diff.types";
import type { GitDiff } from "@/features/git/types/git.types";

type Translate = (key: string, params?: Record<string, string>) => string;

const WORKING_TREE_DIFF_PATH = "diff://working-tree/all-files";

export function formatDiffBufferLabel(
  name: string,
  path?: string,
  translate?: Translate,
  diffData?: GitDiff | MultiFileDiff,
): string {
  // A diff opened from the commit panel mirrors IntelliJ's commit diff preview tab (VcsBundle
  // commit.editor.diff.preview.title): "Commit: <current file>", or "Commit" before a change
  // is selected. Other working-tree diffs (e.g. from the editor gutter) keep the generic title.
  if (path === WORKING_TREE_DIFF_PATH) {
    if (!isCommitPreview(diffData)) {
      return translate?.("git.diff.uncommitted") ?? "Uncommitted Changes";
    }
    const fileName = getCommitPreviewFileName(diffData);
    if (fileName) {
      return translate?.("git.diff.commitPreviewTitle", { file: fileName }) ?? `Commit: ${fileName}`;
    }
    return translate?.("git.diff.commitPreviewEmptyTitle") ?? "Commit";
  }

  const normalizedName = decodeIfEncoded(name);
  if (normalizedName && normalizedName !== name) {
    return normalizedName;
  }

  if (path?.startsWith("diff://")) {
    const derived = deriveDiffLabelFromPath(path);
    if (derived) return derived;
  }

  return name;
}

export function isCommitPreview(diffData?: GitDiff | MultiFileDiff): diffData is MultiFileDiff {
  return Boolean(diffData && "files" in diffData && diffData.commitPreview);
}

/** File name in a commit preview tab title: the change it was opened on. */
export function getCommitPreviewFileName(diffData?: GitDiff | MultiFileDiff): string | null {
  if (!isCommitPreview(diffData)) return null;
  const fileKey = diffData.initiallySelectedFileKey ?? diffData.initiallyExpandedFileKey;
  if (!fileKey) return null;
  const filePath =
    diffData.workingTreeTargets?.[fileKey]?.filePath ?? fileKey.replace(/^(staged|unstaged):/, "");
  return filePath.split(/[\\/]/).pop() || filePath;
}

function deriveDiffLabelFromPath(path: string): string | null {
  const stagedMatch = path.match(/^diff:\/\/(staged|unstaged)\/(.+)$/);
  if (stagedMatch) {
    const filePath = decodeIfEncoded(stagedMatch[2]);
    const fileName = filePath.split("/").pop() || filePath;
    return `${fileName} (${stagedMatch[1]})`;
  }

  const commitAllMatch = path.match(/^diff:\/\/commit\/([^/]+)\/all-files$/);
  if (commitAllMatch) {
    return `Commit ${commitAllMatch[1].slice(0, 7)}`;
  }

  const stashAllMatch = path.match(/^diff:\/\/stash\/(\d+)\/all-files$/);
  if (stashAllMatch) {
    return `Stash @{${stashAllMatch[1]}}`;
  }

  const prMatch = path.match(/^diff:\/\/pr-(\d+)\/changes$/);
  if (prMatch) {
    return `PR #${prMatch[1]} Changes`;
  }

  return null;
}

function decodeIfEncoded(value: string): string {
  if (!/%[0-9A-Fa-f]{2}/.test(value)) return value;

  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}
