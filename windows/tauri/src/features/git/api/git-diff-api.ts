import { invoke as tauriInvoke } from "@/platform/tauri-core";
import type { GitDiff, GitDiffStat, GitReference } from "../types/git.types";
import { registerGitCacheInvalidator } from "../runtime/git-cache-registry";
import { runGitRead } from "../runtime/git-read-coordinator";
import { gitDiffCache } from "../utils/git-diff-cache";
import { FULL_FILE_CONTEXT_LINES } from "../utils/git-diff-helpers";
import { checkHunkRollbackAttributes } from "../utils/lossy-rollback-attrs";
import {
  isNotGitRepositoryError,
  resolveRepositoryForFile,
  resolveRepositoryPath,
} from "./git-repo-api";
import { referencePayload, toCoreGitReference } from "./git-reference-payload";

interface MultiFileDiffCacheEntry {
  diffs: GitDiff[];
  timestamp: number;
}

const MULTI_FILE_DIFF_CACHE_TTL = 30_000;
const commitDiffCache = new Map<string, MultiFileDiffCacheEntry>();
const stashDiffCache = new Map<string, MultiFileDiffCacheEntry>();
const refDiffCache = new Map<string, MultiFileDiffCacheEntry>();
const inFlightFileDiffRequests = new Map<string, Promise<GitDiff | null>>();
const inFlightStatusDiffStatsRequests = new Map<
  string,
  Promise<GitDiffStat[]>
>();
const repositoryCacheGenerations = new Map<string, number>();

const getRepositoryCacheGeneration = (repoPath: string): number => {
  const generation = repositoryCacheGenerations.get(repoPath) ?? 0;
  if (!repositoryCacheGenerations.has(repoPath)) {
    repositoryCacheGenerations.set(repoPath, generation);
  }
  return generation;
};

const getFileDiffRequestKey = (
  repoPath: string,
  filePath: string,
  staged: boolean,
  content?: string,
): string =>
  JSON.stringify([
    repoPath,
    filePath,
    staged,
    content === undefined ? null : gitDiffCache.getContentFingerprint(content),
  ]);

const getMultiFileDiffCacheEntry = (
  cache: Map<string, MultiFileDiffCacheEntry>,
  key: string,
): GitDiff[] | null => {
  const entry = cache.get(key);
  if (!entry) return null;
  if (Date.now() - entry.timestamp > MULTI_FILE_DIFF_CACHE_TTL) {
    cache.delete(key);
    return null;
  }
  return entry.diffs;
};

const setMultiFileDiffCacheEntry = (
  cache: Map<string, MultiFileDiffCacheEntry>,
  key: string,
  diffs: GitDiff[],
): void => {
  cache.set(key, {
    diffs,
    timestamp: Date.now(),
  });
};

export function invalidateGitDiffData(repoPath?: string, filePath?: string): void {
  if (!repoPath) {
    if (filePath) {
      gitDiffCache.invalidateFile(filePath);
      inFlightFileDiffRequests.clear();
      inFlightStatusDiffStatsRequests.clear();
      return;
    }

    commitDiffCache.clear();
    stashDiffCache.clear();
    refDiffCache.clear();
    for (const [cachedRepoPath, generation] of repositoryCacheGenerations) {
      repositoryCacheGenerations.set(cachedRepoPath, generation + 1);
    }
    gitDiffCache.clear();
    inFlightFileDiffRequests.clear();
    inFlightStatusDiffStatsRequests.clear();
    return;
  }

  repositoryCacheGenerations.set(repoPath, getRepositoryCacheGeneration(repoPath) + 1);
  gitDiffCache.invalidate(repoPath, filePath);
  if (filePath) {
    gitDiffCache.invalidateFile(filePath);
  }
  inFlightStatusDiffStatsRequests.delete(repoPath);
  const fileRequestPrefix = JSON.stringify([repoPath]).slice(0, -1);
  for (const key of inFlightFileDiffRequests.keys()) {
    if (key.startsWith(fileRequestPrefix)) {
      inFlightFileDiffRequests.delete(key);
    }
  }

  if (filePath) {
    return;
  }

  const prefix = `${repoPath}:`;
  for (const cache of [commitDiffCache, stashDiffCache, refDiffCache]) {
    for (const key of cache.keys()) {
      if (key.startsWith(prefix)) {
        cache.delete(key);
      }
    }
  }
}

registerGitCacheInvalidator(({ repoPath, filePath }) => {
  invalidateGitDiffData(repoPath, filePath);
});

const getErrorMessage = (error: unknown): string => {
  if (error instanceof Error) {
    return error.message;
  }

  if (typeof error === "string") {
    return error;
  }

  if (
    typeof error === "object" &&
    error !== null &&
    "message" in error &&
    typeof error.message === "string"
  ) {
    return error.message;
  }

  return "";
};

const isNoDiffFoundError = (error: unknown): boolean => {
  return getErrorMessage(error).includes("No changes found for file:");
};

export const getFileDiff = async (
  repoPath: string,
  filePath: string,
  staged: boolean = false,
  content?: string,
): Promise<GitDiff | null> => {
  try {
    const resolved = await resolveRepositoryForFile(repoPath, filePath);
    if (!resolved) {
      return null;
    }

    const cached = gitDiffCache.get(resolved.repoPath, resolved.filePath, staged, content);
    if (cached) {
      return cached;
    }

    const requestKey = getFileDiffRequestKey(resolved.repoPath, resolved.filePath, staged, content);
    const existingRequest = inFlightFileDiffRequests.get(requestKey);
    if (existingRequest) {
      return existingRequest;
    }

    const generation = gitDiffCache.getGeneration(resolved.repoPath);
    const request = tauriInvoke<GitDiff>("git_diff_file", {
      repoPath: resolved.repoPath,
      filePath: resolved.filePath,
      staged,
    })
      .then((diff) => {
        if (generation !== gitDiffCache.getGeneration(resolved.repoPath)) {
          return getFileDiff(resolved.repoPath, resolved.filePath, staged, content);
        }

        if (diff) {
          gitDiffCache.set(resolved.repoPath, resolved.filePath, staged, diff, content, generation);
        }

        return diff;
      })
      .catch((error) => {
        if (!isNotGitRepositoryError(error) && !isNoDiffFoundError(error)) {
          console.error("Failed to get file diff:", error);
        }
        return null;
      })
      .finally(() => {
        if (inFlightFileDiffRequests.get(requestKey) === request) {
          inFlightFileDiffRequests.delete(requestKey);
        }
      });

    inFlightFileDiffRequests.set(requestKey, request);
    return request;
  } catch (error) {
    if (!isNotGitRepositoryError(error) && !isNoDiffFoundError(error)) {
      console.error("Failed to get file diff:", error);
    }
    return null;
  }
};

/**
 * Whole-file context stays below half of Git's signed 32-bit limit: xdiff
 * doubles it when merging adjacent changes. Larger values overflow on Windows
 * and emit overlapping full-file hunks for separate changes.
 */
const markFullContext = (diff: GitDiff | null): GitDiff | null =>
  diff ? { ...diff, is_full_context: true } : diff;

export const getWorkingTreePathDiff = async (
  repoPath: string,
  filePath: string,
  _untracked = false,
  originalPath?: string,
  fullContext = false,
): Promise<GitDiff | null> => {
  try {
    const resolved = await resolveRepositoryForFile(repoPath, filePath);
    if (!resolved) return null;

    const filePaths = [...new Set([originalPath, resolved.filePath].filter(Boolean) as string[])];
    const diff = await runGitRead(
      resolved.repoPath,
      `working-tree-path-diff:${fullContext ? "full:" : ""}${resolved.filePath}`,
      () =>
        tauriInvoke<GitDiff>("git_diff_file", {
          repoPath: resolved.repoPath,
          filePath: resolved.filePath,
          ...(filePaths.length > 1 ? { filePaths } : {}),
          worktreeSnapshot: true,
          ...(fullContext ? { contextLines: FULL_FILE_CONTEXT_LINES } : {}),
        }),
    );
    if (!diff) return null;
    // The rollback channel needs the raw patch bytes for lossy files; the
    // display adapter strips CR and EOF markers. Attach writePatch the same
    // way getFullContextFileDiff does, gated by the attribute safety check
    // and a snapshot consistency verification.
    if (diff.has_lossy_line_endings) {
      const safety = await checkHunkRollbackAttributes(resolved.repoPath, resolved.filePath);
      if (safety.byteSafe) {
        const raw = await fetchRawWorktreePatch(resolved.repoPath, resolved.filePath);
        if (raw && writePatchMatchesDisplay(raw, diff)) {
          return fullContext ? markFullContext({ ...diff, writePatch: raw }) : { ...diff, writePatch: raw };
        }
      }
    }
    return fullContext ? markFullContext(diff) : diff;
  } catch (error) {
    if (!isNotGitRepositoryError(error) && !isNoDiffFoundError(error)) {
      console.error("Failed to get working-tree path diff:", error);
    }
    return null;
  }
};

/**
 * Index or worktree diff of one file with the whole file as context. It is not
 * cached with `getFileDiff` results because gutter and AI consumers expect the
 * regular sparse patch for the same key.
 */
export const getFullContextFileDiff = async (
  repoPath: string,
  filePath: string,
  staged = false,
): Promise<GitDiff | null> => {
  try {
    const resolved = await resolveRepositoryForFile(repoPath, filePath);
    if (!resolved) return null;

    const diff = await runGitRead(
      resolved.repoPath,
      `full-context-diff:${staged ? "staged" : "unstaged"}:${resolved.filePath}`,
      () =>
        tauriInvoke<GitDiff>("git_diff_file", {
          repoPath: resolved.repoPath,
          filePath: resolved.filePath,
          staged,
          contextLines: FULL_FILE_CONTEXT_LINES,
        }),
    );
    if (!diff) return null;
    // The rollback channel needs the raw patch bytes (CR, EOF markers) that
    // the display adapter strips. Only the unstaged read (index → worktree)
    // is the correct rollback basis, so only that direction carries it, and
    // only when Git's effective attributes prove the bytes can round-trip
    // and the display and raw reads describe the same snapshot.
    if (!staged && diff.has_lossy_line_endings) {
      const safety = await checkHunkRollbackAttributes(resolved.repoPath, resolved.filePath);
      if (safety.byteSafe) {
        const raw = await fetchRawWorktreePatch(resolved.repoPath, resolved.filePath);
        if (raw && writePatchMatchesDisplay(raw, diff)) {
          return markFullContext({ ...diff, writePatch: raw });
        }
      }
    }
    return markFullContext(diff);
  } catch (error) {
    if (!isNotGitRepositoryError(error) && !isNoDiffFoundError(error)) {
      console.error("Failed to get full-context file diff:", error);
    }
    return null;
  }
};


/** Fetches the unmodified index-to-worktree patch text for byte-faithful
 * hunk rollback; returns null when Git cannot produce one. */
const fetchRawWorktreePatch = async (
  repoPath: string,
  filePath: string,
): Promise<string | null> => {
  try {
    const response = await tauriInvoke<{
      patch: string;
      exitCode: number;
      hasDecodingLoss?: boolean;
    }>("git.diff", {
      root: repoPath,
      pathspecs: [filePath],
      contextLines: 3,
      // The compatibility adapter re-parses `git.diff` for display and would
      // strip the very CR and EOF bytes this channel exists to preserve.
    }, { rawCoreResult: true });
    if (typeof response?.patch !== "string") return null;
    // Core replaced invalid UTF-8 with U+FFFD; writing this back would
    // permanently corrupt the file. Also detect the replacement character
    // directly as a belt-and-suspenders check for older core builds.
    if (response.hasDecodingLoss || response.patch.includes("�")) return null;
    return response.patch;
  } catch {
    return null;
  }
};

/**
 * Pre-write probe for zero-context rollback: re-reads the raw patch a lossy
 * diff's `writePatch` came from, with the same repository resolution and fixed
 * context, and compares it byte for byte. The display diff's context width
 * (full-file or three lines) never enters the comparison, and CR-only edits the
 * display strips still count. Any read failure resolves false, so the write is
 * refused rather than applied to lines that may have moved.
 */
export const isWorktreeWritePatchCurrent = async (
  repoPath: string | undefined,
  filePath: string,
  writePatch: string | undefined,
): Promise<boolean> => {
  if (!repoPath || !writePatch) return false;
  try {
    const resolved = await resolveRepositoryForFile(repoPath, filePath);
    if (!resolved) return false;
    return await fetchRawWorktreePatch(resolved.repoPath, resolved.filePath) === writePatch;
  } catch {
    return false;
  }
};

/**
 * Verifies that a raw writePatch and a display diff describe the same
 * worktree snapshot. The display read strips CR; the raw read preserves it.
 * Comparing the structured entries — change type, line number, and stripped
 * text — catches edits that land between the two reads, including changes
 * that relocate to different lines with identical text. Mixing snapshots
 * would let a rollback discard content the user never saw.
 */
const writePatchMatchesDisplay = (rawPatch: string, display: GitDiff): boolean => {
  // Parse the raw patch into structured entries with line numbers.
  const rawEntries: Array<{ type: string; line: number | null; text: string }> = [];
  let oldLine = 0;
  let newLine = 0;
  let inHunk = false;
  for (const line of rawPatch.split("\n")) {
    if (line.startsWith("@@")) {
      inHunk = true;
      const match = line.match(/@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/);
      if (match) {
        oldLine = parseInt(match[1], 10);
        newLine = parseInt(match[3], 10);
      }
      continue;
    }
    if (!inHunk || line === "" || line.startsWith("\\")) continue;
    const prefix = line[0];
    const text = line.slice(1).replace(/\r$/, "");
    if (prefix === "-") {
      rawEntries.push({ type: "removed", line: oldLine, text });
    } else if (prefix === "+") {
      rawEntries.push({ type: "added", line: newLine, text });
    }
    if (prefix === " " || prefix === "-") oldLine++;
    if (prefix === " " || prefix === "+") newLine++;
  }
  const displayEntries = display.lines
    .filter(l => l.line_type === "added" || l.line_type === "removed")
    .map(l => ({
      type: l.line_type,
      line: l.line_type === "removed" ? l.old_line_number : l.new_line_number,
      text: l.content.replace(/\r$/, ""),
    }));
  return rawEntries.length === displayEntries.length
    && rawEntries.every((entry, index) => {
      const other = displayEntries[index];
      return entry.type === other.type && entry.line === other.line && entry.text === other.text;
    });
};

export const getUntrackedFileDiff = async (
  repoPath: string,
  filePath: string,
): Promise<GitDiff | null> => {
  try {
    const resolved = await resolveRepositoryForFile(repoPath, filePath);
    if (!resolved) return null;

    return await runGitRead(
      resolved.repoPath,
      `untracked-diff:${resolved.filePath}`,
      () =>
        tauriInvoke<GitDiff>("git_diff_file", {
          repoPath: resolved.repoPath,
          filePath: resolved.filePath,
          untracked: true,
        }),
    );
  } catch (error) {
    if (!isNotGitRepositoryError(error) && !isNoDiffFoundError(error)) {
      console.error("Failed to get untracked file diff:", error);
    }
    return null;
  }
};

export const getStatusDiffStats = async (repoPath: string): Promise<GitDiffStat[]> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPath(repoPath);
    if (!resolvedRepoPath) {
      return [];
    }

    const existingRequest = inFlightStatusDiffStatsRequests.get(resolvedRepoPath);
    if (existingRequest) {
      return existingRequest;
    }

    const generation = getRepositoryCacheGeneration(resolvedRepoPath);
    const request = Promise.all([
      tauriInvoke<GitDiffStat[]>("git_status_diff_stats", {
        repoPath: resolvedRepoPath,
      }),
      tauriInvoke<GitDiffStat[]>("git_status_diff_stats", {
        repoPath: resolvedRepoPath,
        staged: true,
      }),
    ])
      .then(([unstagedStats, stagedStats]) => {
        if (generation !== getRepositoryCacheGeneration(resolvedRepoPath)) {
          return getStatusDiffStats(resolvedRepoPath);
        }
        return [...unstagedStats, ...stagedStats];
      })
      .catch((error) => {
        if (!isNotGitRepositoryError(error)) {
          console.error("Failed to get status diff stats:", error);
        }
        return [];
      })
      .finally(() => {
        if (inFlightStatusDiffStatsRequests.get(resolvedRepoPath) === request) {
          inFlightStatusDiffStatsRequests.delete(resolvedRepoPath);
        }
      });

    inFlightStatusDiffStatsRequests.set(resolvedRepoPath, request);
    return request;
  } catch (error) {
    if (!isNotGitRepositoryError(error)) {
      console.error("Failed to get status diff stats:", error);
    }
    return [];
  }
};

export const getCommitDiff = async (
  repoPath: string,
  commitHash: string,
): Promise<GitDiff[] | null> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPath(repoPath);
    if (!resolvedRepoPath) {
      return null;
    }

    const cacheKey = `${resolvedRepoPath}:${commitHash}`;
    const cached = getMultiFileDiffCacheEntry(commitDiffCache, cacheKey);
    if (cached) {
      return cached;
    }

    const generation = getRepositoryCacheGeneration(resolvedRepoPath);
    const diffs = await runGitRead(
      resolvedRepoPath,
      `commit-diff:${commitHash}`,
      () =>
        tauriInvoke<GitDiff[]>("git_commit_diff", {
          repoPath: resolvedRepoPath,
          commitHash,
        }),
    );
    if (generation !== getRepositoryCacheGeneration(resolvedRepoPath)) {
      return getCommitDiff(resolvedRepoPath, commitHash);
    }
    setMultiFileDiffCacheEntry(commitDiffCache, cacheKey, diffs);
    return diffs;
  } catch (error) {
    if (!isNotGitRepositoryError(error)) {
      console.error("Failed to get commit diff:", error);
    }
    return null;
  }
};

export const getRefDiff = async (
  repoPath: string,
  baseRef: string | null,
  targetRef: string,
): Promise<GitDiff[] | null> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPath(repoPath);
    if (!resolvedRepoPath) {
      return null;
    }

    const cacheKey = `${resolvedRepoPath}:${baseRef}:${targetRef}`;
    const cached = getMultiFileDiffCacheEntry(refDiffCache, cacheKey);
    if (cached) {
      return cached;
    }

    const generation = getRepositoryCacheGeneration(resolvedRepoPath);
    const diffs = await runGitRead(
      resolvedRepoPath,
      `ref-diff:${baseRef}:${targetRef}`,
      () =>
        tauriInvoke<GitDiff[]>("git_ref_diff", {
          repoPath: resolvedRepoPath,
          baseRef,
          targetRef,
        }),
    );
    if (generation !== getRepositoryCacheGeneration(resolvedRepoPath)) {
      return getRefDiff(resolvedRepoPath, baseRef, targetRef);
    }
    setMultiFileDiffCacheEntry(refDiffCache, cacheKey, diffs);
    return diffs;
  } catch (error) {
    if (!isNotGitRepositoryError(error)) {
      console.error("Failed to get ref diff:", error);
    }
    return null;
  }
};

export const getTypedReferenceDiff = async (
  repoPath: string,
  baseReference: GitReference,
  targetReference: GitReference,
): Promise<GitDiff[] | null> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPath(repoPath);
    if (!resolvedRepoPath) return null;
    const cacheKey = `${resolvedRepoPath}:${baseReference.fullName}:${targetReference.fullName}`;
    const cached = getMultiFileDiffCacheEntry(refDiffCache, cacheKey);
    if (cached) return cached;

    const generation = getRepositoryCacheGeneration(resolvedRepoPath);
    const diffs = await runGitRead(
      resolvedRepoPath,
      `typed-ref-diff:${baseReference.fullName}:${targetReference.fullName}`,
      () =>
        tauriInvoke<GitDiff[]>("git_ref_diff", {
          repoPath: resolvedRepoPath,
          gitReference: toCoreGitReference(baseReference),
          targetGitReference: toCoreGitReference(targetReference),
          pathspecs: ["."],
        }),
    );
    if (generation !== getRepositoryCacheGeneration(resolvedRepoPath)) {
      return getTypedReferenceDiff(resolvedRepoPath, baseReference, targetReference);
    }
    setMultiFileDiffCacheEntry(refDiffCache, cacheKey, diffs);
    return diffs;
  } catch (error) {
    if (!isNotGitRepositoryError(error)) {
      console.error("Failed to compare Git references:", error);
    }
    return null;
  }
};

export const getWorkingTreeRefDiff = async (
  repoPath: string,
  reference: GitReference | string,
): Promise<GitDiff[] | null> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPath(repoPath);
    if (!resolvedRepoPath) return null;
    const fullName = typeof reference === "string" ? reference : reference.fullName;
    return await runGitRead(resolvedRepoPath, `working-tree-ref-diff:${fullName}`, () =>
      tauriInvoke<GitDiff[]>("git_working_tree_ref_diff", {
        repoPath: resolvedRepoPath,
        ...referencePayload(reference),
      }),
    );
  } catch (error) {
    if (!isNotGitRepositoryError(error)) {
      console.error("Failed to compare reference with the working tree:", error);
    }
    return null;
  }
};

export const getStashDiff = async (
  repoPath: string,
  stashIndex: number,
  stashOid?: string,
): Promise<GitDiff[] | null> => {
  try {
    const resolvedRepoPath = await resolveRepositoryPath(repoPath);
    if (!resolvedRepoPath) {
      return null;
    }

    const cacheKey = `${resolvedRepoPath}:${stashOid ?? stashIndex}`;
    const cached = getMultiFileDiffCacheEntry(stashDiffCache, cacheKey);
    if (cached) {
      return cached;
    }

    const generation = getRepositoryCacheGeneration(resolvedRepoPath);
    const diffs = await runGitRead(resolvedRepoPath, `stash-diff:${stashOid ?? stashIndex}`, () =>
      tauriInvoke<GitDiff[]>("git_stash_diff", {
        repoPath: resolvedRepoPath,
        stashIndex,
        ...(stashOid ? { stashOid } : {}),
      }),
    );
    if (generation !== getRepositoryCacheGeneration(resolvedRepoPath)) {
      return getStashDiff(resolvedRepoPath, stashIndex, stashOid);
    }
    setMultiFileDiffCacheEntry(stashDiffCache, cacheKey, diffs);
    return diffs;
  } catch (error) {
    if (!isNotGitRepositoryError(error)) {
      console.error("Failed to get stash diff:", error);
    }
    return null;
  }
};
