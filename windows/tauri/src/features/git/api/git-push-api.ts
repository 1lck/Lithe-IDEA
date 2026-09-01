import { invoke as tauriInvoke } from "@/platform/tauri-core";
import { emitGitChanged } from "../events/git-events";
import type {
  GitCommit,
  GitOperationWarning,
  GitPushExpectation,
  GitPushPreview,
  GitPushTagScope,
} from "../types/git.types";
import { resolveRepositoryPathOrThrow } from "./git-repo-api";
import { referencePayload, type GitReferenceInput } from "./git-reference-payload";

interface CoreGitCommit {
  hash: string;
  shortHash: string;
  parentHashes: string[];
  authorName: string;
  authorEmail: string;
  date: string;
  subject: string;
  decorations: string;
}

interface CoreGitPushPreview extends Omit<GitPushPreview, "commits"> {
  commits: CoreGitCommit[];
}

export interface GitPushOptions {
  reference?: GitReferenceInput;
  expectedPush?: GitPushExpectation;
  force?: boolean;
  pushTags?: GitPushTagScope;
}

const localReference = (branch: string): string =>
  branch.startsWith("refs/heads/") ? branch : `refs/heads/${branch}`;

const pushReferencePayload = (reference?: GitReferenceInput): Record<string, unknown> => {
  if (!reference) return {};
  return referencePayload(typeof reference === "string" ? localReference(reference) : reference);
};

const toGitCommit = (commit: CoreGitCommit): GitCommit => ({
  hash: commit.hash,
  shortHash: commit.shortHash,
  parentHashes: commit.parentHashes,
  message: commit.subject,
  author: commit.authorName,
  email: commit.authorEmail,
  date: commit.date,
  decorations: commit.decorations,
});

export const getGitPushPreview = async (
  repoPath: string,
  reference?: GitReferenceInput,
  pushTags: GitPushTagScope = "none",
): Promise<GitPushPreview> => {
  const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
  const preview = await tauriInvoke<CoreGitPushPreview>("git.pushPreview", {
    repoPath: resolvedRepoPath,
    ...pushReferencePayload(reference),
    pushTags,
  });
  return {
    ...preview,
    commits: preview.commits.map(toGitCommit),
  };
};

export const executeGitPush = async (
  repoPath: string,
  options: GitPushOptions = {},
): Promise<GitOperationWarning[]> => {
  const resolvedRepoPath = await resolveRepositoryPathOrThrow(repoPath);
  const result = await tauriInvoke<{ warnings?: GitOperationWarning[] } | null>("git.write", {
    repoPath: resolvedRepoPath,
    operation: "push",
    ...pushReferencePayload(options.reference),
    ...(options.expectedPush ? { expectedPush: options.expectedPush } : {}),
    force: options.force ?? false,
    pushTags: options.pushTags ?? "none",
  });
  emitGitChanged({
    repoPath: resolvedRepoPath,
    scopes: ["history", "refs", "remotes"],
    source: options.force ? "force-push" : "push",
  });
  return result?.warnings ?? [];
};
