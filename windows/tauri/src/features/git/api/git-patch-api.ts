import { invoke } from "@/platform/tauri-core";
import { emitGitChanged } from "../events/git-events";
import type { GitOperationWarning } from "../types/git.types";
import type {
  GitPatchExport,
  GitPatchPreview,
  GitPatchSource,
  GitPatchTarget,
} from "../types/git-patch.types";
import { resolveRepositoryPathOrThrow } from "./git-repo-api";

export async function exportGitPatch(
  repoPath: string,
  source: GitPatchSource,
  paths: string[],
  options: { baseRevision?: string; targetRevision?: string; includeUntracked?: boolean } = {},
  operationId?: string,
  metadataOnly = false,
): Promise<GitPatchExport> {
  const root = await resolveRepositoryPathOrThrow(repoPath);
  return invoke("git.patchExport", {
    root,
    source,
    paths,
    ...options,
    ...(metadataOnly ? { metadataOnly: true } : {}),
    ...(operationId ? { operationId } : {}),
  });
}

export async function previewGitPatch(
  repoPath: string,
  patch: string,
  target: GitPatchTarget,
  operationId: string,
  reverse = false,
  metadataOnly = false,
): Promise<GitPatchPreview> {
  const root = await resolveRepositoryPathOrThrow(repoPath);
  return invoke("git.patchPreview", {
    root,
    patch,
    target,
    operationId,
    ...(reverse ? { reverse: true } : {}),
    ...(metadataOnly ? { metadataOnly: true } : {}),
  });
}

export async function applyGitPatch(
  repoPath: string,
  patch: string,
  target: GitPatchTarget,
  expectedState: string,
  reverse = false,
): Promise<GitOperationWarning[]> {
  const root = await resolveRepositoryPathOrThrow(repoPath);
  try {
    const result = await invoke<{
      exitCode: number;
      output: string;
      operationError?: { message: string };
      warnings?: GitOperationWarning[];
    }>("git.patchApply", {
      root,
      patch,
      target,
      expectedState,
      ...(reverse ? { reverse: true } : {}),
    });
    if (result.operationError || result.exitCode !== 0)
      throw new Error(result.operationError?.message || result.output);
    return result.warnings ?? [];
  } finally {
    emitGitChanged({ repoPath: root, scopes: ["working-tree"], source: "apply-patch" });
  }
}

/** Reuse Core's read-only reverse check; staged restoration checks the index alone. */
export async function isGitPatchApplied(
  repoPath: string,
  patch: string,
  target: GitPatchTarget,
): Promise<boolean> {
  const root = await resolveRepositoryPathOrThrow(repoPath);
  const result = await invoke<{ exitCode: number; operationError?: { message: string } }>(
    "git.apply",
    { root, patch, mode: target === "indexAndWorktree" ? "restoreIndexCheck" : "worktreeCheck" },
  );
  return result.exitCode === 0 && !result.operationError;
}
