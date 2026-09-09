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
  revisions: { baseRevision?: string; targetRevision?: string } = {},
  operationId?: string,
  metadataOnly = false,
): Promise<GitPatchExport> {
  const root = await resolveRepositoryPathOrThrow(repoPath);
  return invoke("git.patchExport", {
    root,
    source,
    paths,
    ...revisions,
    ...(metadataOnly ? { metadataOnly: true } : {}),
    ...(operationId ? { operationId } : {}),
  });
}

export async function previewGitPatch(
  repoPath: string,
  patch: string,
  target: GitPatchTarget,
  operationId: string,
): Promise<GitPatchPreview> {
  const root = await resolveRepositoryPathOrThrow(repoPath);
  return invoke("git.patchPreview", { root, patch, target, operationId });
}

export async function applyGitPatch(
  repoPath: string,
  patch: string,
  target: GitPatchTarget,
  expectedState: string,
): Promise<GitOperationWarning[]> {
  const root = await resolveRepositoryPathOrThrow(repoPath);
  try {
    const result = await invoke<{
      exitCode: number;
      output: string;
      operationError?: { message: string };
      warnings?: GitOperationWarning[];
    }>("git.patchApply", { root, patch, target, expectedState });
    if (result.operationError || result.exitCode !== 0)
      throw new Error(result.operationError?.message || result.output);
    return result.warnings ?? [];
  } finally {
    emitGitChanged({ repoPath: root, scopes: ["working-tree"], source: "apply-patch" });
  }
}
