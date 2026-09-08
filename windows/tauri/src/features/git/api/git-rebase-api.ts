import { invoke } from "@/platform/tauri-core";
import { emitGitChanged } from "../events/git-events";
import type {
  GitRebasePreview,
  GitRebaseResult,
  GitRebaseSession,
  GitRebaseStep,
} from "../types/git-rebase.types";
import { resolveRepositoryPathOrThrow } from "./git-repo-api";

export async function previewGitRebase(
  repoPath: string,
  revision: string,
  operationId: string,
): Promise<GitRebasePreview> {
  return invoke("git.rebasePreview", {
    root: await resolveRepositoryPathOrThrow(repoPath),
    revision,
    operationId,
  });
}
export async function getGitRebaseSession(
  repoPath: string,
  operationId?: string,
): Promise<GitRebaseSession | null> {
  return invoke("git.rebaseSession", {
    root: await resolveRepositoryPathOrThrow(repoPath),
    operationId,
  });
}
async function mutate(
  repoPath: string,
  command: string,
  payload: Record<string, unknown>,
): Promise<GitRebaseResult> {
  const root = await resolveRepositoryPathOrThrow(repoPath);
  try {
    return await invoke(command, { root, ...payload });
  } finally {
    emitGitChanged({
      repoPath: root,
      scopes: ["working-tree", "history", "refs"],
      source: "interactive-rebase",
    });
  }
}
export async function startGitRebase(
  repoPath: string,
  preview: GitRebasePreview,
  steps: GitRebaseStep[],
): Promise<GitRebaseResult> {
  if (!preview.allowed || !preview.expectedState)
    throw new Error(preview.blockers.map((entry) => entry.message).join("\n"));
  return mutate(repoPath, "git.rebaseStart", {
    expectedState: preview.expectedState,
    steps: steps.map(({ hash, action, message }) => ({
      hash,
      action,
      ...((action === "reword" || action === "squash") && message !== undefined ? { message } : {}),
    })),
  });
}
export function controlGitRebase(
  repoPath: string,
  sessionId: string,
  action: "continue" | "skip" | "abort",
  amendMessage?: string,
): Promise<GitRebaseResult> {
  return mutate(repoPath, "git.rebaseControl", {
    sessionId,
    action,
    ...(amendMessage === undefined ? {} : { amendMessage }),
  });
}
