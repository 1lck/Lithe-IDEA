import type { CommitFileInput } from "../types/ai-commit";
import type { GitDiff, GitFile } from "../types/git.types";
import {
  getGitFileOriginalRepositoryRelativePath,
  getGitFileRepositoryPath,
  getGitFileRepositoryRelativePath,
} from "../utils/git-status-selection";

type ReadDiff = (
  repository: string,
  path: string,
  untracked: boolean,
  originalPath?: string,
) => Promise<GitDiff | null>;
const MAX_CONTEXT_CHARACTERS = 120_000;
const MAX_CONTEXT_FILES = 1_000;

export function commitSelectionKey(repoPath: string, files: GitFile[]): string {
  return JSON.stringify([
    repoPath,
    files
      .map((file) => [
        getGitFileRepositoryPath(file, repoPath),
        getGitFileRepositoryRelativePath(file),
        getGitFileOriginalRepositoryRelativePath(file),
        file.status,
        file.rawStatus,
      ])
      .sort(),
  ]);
}

/** Reads every selected path with at most four concurrent Git requests and bounded retained text. */
export async function collectCommitContext(
  repoPath: string,
  files: GitFile[],
  signal: AbortSignal,
  readDiff: ReadDiff,
): Promise<CommitFileInput[]> {
  if (files.length > MAX_CONTEXT_FILES) throw new Error("AI_COMMIT_TOO_MANY_FILES");
  const repositories = new Set(
    files.map((file) => getGitFileRepositoryPath(file, repoPath) ?? repoPath),
  );
  if (repositories.size > 1) throw new Error("AI_COMMIT_MULTIPLE_REPOSITORIES");
  const ordered = [...files].sort((a, b) =>
    getGitFileRepositoryRelativePath(a).localeCompare(getGitFileRepositoryRelativePath(b)),
  );
  const inputs: CommitFileInput[] = [];
  let next = 0;
  let failed = false;
  const budget = Math.floor(MAX_CONTEXT_CHARACTERS / Math.max(1, files.length));
  const workers = Array.from({ length: Math.min(4, files.length) }, async () => {
    try {
      while (!failed && next < ordered.length) {
        signal.throwIfAborted();
        const index = next++;
        const file = ordered[index];
        const path = getGitFileRepositoryRelativePath(file);
        const diff = await readDiff(
          getGitFileRepositoryPath(file, repoPath) ?? repoPath,
          path,
          file.status === "untracked",
          getGitFileOriginalRepositoryRelativePath(file),
        );
        signal.throwIfAborted();
        if (!diff) throw new Error("AI_COMMIT_DIFF_FAILED");
        const patch =
          diff.raw_patch ??
          diff.lines
            .map(
              (line) =>
                `${line.line_type === "added" ? "+" : line.line_type === "removed" ? "-" : " "}${line.content}`,
            )
            .join("\n");
        // Hash the full available patch before truncation to detect later edits outside the prompt.
        const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(patch));
        const fingerprint = Array.from(new Uint8Array(hash), (byte) =>
          byte.toString(16).padStart(2, "0"),
        ).join("");
        const prefix = [...patch].slice(0, budget).join("");
        const text =
          prefix +
          (prefix.length < patch.length || diff.is_truncated
            ? "\n[Diff truncated; do not infer omitted changes.]"
            : "");
        inputs[index] = {
          path,
          changeKind: file.status,
          diff: diff.is_binary ? "" : text,
          fingerprint,
        };
      }
    } catch (error) {
      failed = true;
      throw error;
    }
  });
  // Drain already-started, individually bounded Git reads on errors/cancellation.
  const results = await Promise.allSettled(workers);
  const failure = results.find(
    (result): result is PromiseRejectedResult => result.status === "rejected",
  );
  if (failure) throw failure.reason;
  return inputs;
}
