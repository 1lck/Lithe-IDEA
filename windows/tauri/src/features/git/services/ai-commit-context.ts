import { invoke } from "@/platform/tauri-core";
import { resolveRepositoryPathOrThrow } from "../api/git-repo-api";
import type { CommitFileInput } from "../types/ai-commit";
import type { GitFile } from "../types/git.types";
import {
  getGitFileOriginalRepositoryRelativePath,
  getGitFileRepositoryPath,
  getGitFileRepositoryRelativePath,
} from "../utils/git-status-selection";

type SelectionFile = { path: string; originalPath?: string; changeKind: GitFile["status"] };
type RepositorySelection = { root: string; files: SelectionFile[] };
export interface CommitContext {
  files: CommitFileInput[];
  token: string;
  repositories: RepositorySelection[];
}

export function commitSelectionKey(repoPath: string, files: GitFile[]): string {
  return JSON.stringify([
    repoPath,
    files.map((file) => [
      getGitFileRepositoryPath(file, repoPath),
      getGitFileRepositoryRelativePath(file),
      getGitFileOriginalRepositoryRelativePath(file),
      file.status,
      file.rawStatus,
    ]).sort(),
  ]);
}

/** Core reads fresh worktree evidence and binds it to the exact selected state. */
export async function captureCommitContext(
  repoPath: string, files: GitFile[], maximumDiffCharacters: number, signal: AbortSignal,
): Promise<CommitContext> {
  const grouped = new Map<string, SelectionFile[]>();
  for (const file of files) {
    const root = getGitFileRepositoryPath(file, repoPath) ?? repoPath;
    const selected = grouped.get(root) ?? [];
    selected.push({
      path: getGitFileRepositoryRelativePath(file),
      originalPath: getGitFileOriginalRepositoryRelativePath(file),
      changeKind: file.status,
    });
    grouped.set(root, selected);
  }
  const resolved = new Map<string, SelectionFile[]>();
  for (const [root, selected] of grouped) {
    signal.throwIfAborted();
    const actual = await resolveRepositoryPathOrThrow(root);
    const entries = resolved.get(actual) ?? [];
    entries.push(...selected);
    resolved.set(actual, entries);
  }
  signal.throwIfAborted();
  const repositories = [...resolved].map(([root, selected]) => ({ root, files: selected }));
  const result = await invoke<{ files: CommitFileInput[]; token: string }>("git.commitMessageContext", {
    action: "capture", mode: "worktree", repositories, maximumDiffCharacters,
  });
  signal.throwIfAborted();
  if (!/^[0-9a-f]{64}$/.test(result.token) || !Array.isArray(result.files) || result.files.length === 0 || result.files.length > 1_000 ||
      result.files.some((file) => {
        if (typeof file.path !== "string" || !file.path || typeof file.changeKind !== "string" || typeof file.diff !== "string" ||
            !Number.isSafeInteger(file.originalCharacters) || typeof file.truncated !== "boolean") return true;
        let length = 0;
        for (const _ of file.diff) length += 1;
        return file.originalCharacters! < length || file.truncated !== (file.originalCharacters! > length);
      })) throw new Error("AI_COMMIT_DIFF_FAILED");
  return { ...result, repositories };
}

export async function isCommitContextCurrent(context: CommitContext, signal: AbortSignal): Promise<boolean> {
  signal.throwIfAborted();
  const result = await invoke<{ isCurrent: boolean }>("git.commitMessageContext", {
    action: "check", mode: "worktree", repositories: context.repositories, token: context.token,
  });
  signal.throwIfAborted();
  return result.isCurrent;
}
