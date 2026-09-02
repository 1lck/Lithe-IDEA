import { parseRawDiffContent } from "@/features/git/utils/git-diff-parser";
import type { GitDiff, GitDiffSplitRow } from "@/features/git/types/git.types";
import { countSplitDiffStats } from "@/features/git/utils/git-diff-helpers";

type JsonRecord = Record<string, any>;

function asRecord(value: unknown): JsonRecord {
  return typeof value === "object" && value !== null ? (value as JsonRecord) : {};
}

function withoutTrailingCarriageReturn(value: string): string {
  return value.endsWith("\r") ? value.slice(0, -1) : value;
}

function normalizeStatus(status: string, untracked: boolean): string {
  if (untracked || status.includes("?")) return "untracked";
  const indexStatus = status[0] ?? " ";
  const worktreeStatus = status[1] ?? " ";
  if (indexStatus === "A") return "added";
  if (worktreeStatus === "D" || indexStatus === "D") return "deleted";
  if ([indexStatus, worktreeStatus].some((value) => value === "R" || value === "C")) {
    return "renamed";
  }
  if (worktreeStatus === "A") return "added";
  return "modified";
}

function adaptStructuredSplitHunks(value: unknown): GitDiffSplitRow[][] {
  if (!Array.isArray(value)) return [];

  const hunks: GitDiffSplitRow[][] = [];
  let currentHunk: GitDiffSplitRow[] | null = null;

  for (const item of value) {
    const row = asRecord(item);
    const kind = String(row.kind ?? "");
    if (kind === "information") {
      if (currentHunk) hunks.push(currentHunk);
      currentHunk = [];
      continue;
    }
    if (!currentHunk) currentHunk = [];
    if (!["context", "changed", "addition", "removal"].includes(kind)) continue;

    const left = typeof row.left === "string" ? row.left : undefined;
    const right = typeof row.right === "string" ? row.right : kind === "context" ? left : undefined;
    const isInvisibleChange =
      kind === "changed" &&
      left !== undefined &&
      right !== undefined &&
      withoutTrailingCarriageReturn(left) === withoutTrailingCarriageReturn(right);
    const visualKind = isInvisibleChange ? "context" : kind;
    currentHunk.push({
      kind: visualKind as GitDiffSplitRow["kind"],
      old_line_number: typeof row.oldLine === "number" ? row.oldLine : undefined,
      new_line_number: typeof row.newLine === "number" ? row.newLine : undefined,
      old_content: left,
      new_content: right,
      ...(isInvisibleChange ? { is_invisible_change: true } : {}),
    });
  }

  if (currentHunk) hunks.push(currentHunk);
  return hunks;
}

function attachStructuredSplitHunks(diffs: GitDiff[], value: unknown): GitDiff[] {
  const availableHunks = adaptStructuredSplitHunks(value);
  let hunkOffset = 0;

  return diffs.map((diff) => {
    const hunkCount = diff.lines.filter((line) => line.line_type === "header").length;
    const splitHunks = availableHunks.slice(hunkOffset, hunkOffset + hunkCount);
    hunkOffset += hunkCount;
    if (splitHunks.length !== hunkCount || hunkCount === 0) return diff;

    const stats = countSplitDiffStats(splitHunks);
    return {
      ...diff,
      split_hunks: splitHunks,
      additions: stats.additions,
      deletions: stats.deletions,
    };
  });
}

function adaptDiff(command: string, args: JsonRecord | undefined, value: unknown): unknown {
  const data = asRecord(value);
  const patch = typeof data.patch === "string" ? data.patch : "";
  const argumentsRecord = asRecord(args);
  const fallback =
    argumentsRecord.filePath ??
    argumentsRecord.commitHash ??
    argumentsRecord.baseRef ??
    `git-${command}.diff`;
  const parsed = parseRawDiffContent(patch, String(fallback));
  const parsedDiffs = "files" in parsed ? parsed.files : [parsed];
  const diffs = attachStructuredSplitHunks(parsedDiffs, data.rows);

  if (command === "git_diff_file") {
    return diffs[0] ?? null;
  }
  if (command === "git_status_diff_stats") {
    const staged = Boolean(argumentsRecord.staged);
    return diffs.map((diff) => ({
      file_path: diff.file_path,
      staged,
      additions: diff.additions ?? diff.lines.filter((line) => line.line_type === "added").length,
      deletions: diff.deletions ?? diff.lines.filter((line) => line.line_type === "removed").length,
    }));
  }
  return diffs;
}

function adaptDiffStats(args: JsonRecord | undefined, value: unknown): unknown {
  const data = asRecord(value);
  if (!Array.isArray(data.files)) {
    // Older Core builds returned a structured patch for this compatibility
    // command. Keep accepting that shape during rolling upgrades.
    return adaptDiff("git_status_diff_stats", args, value);
  }

  const requestStaged = Boolean(asRecord(args).staged);
  return data.files.map((entry: unknown) => {
    const file = asRecord(entry);
    return {
      file_path: String(file.path ?? ""),
      staged: typeof file.staged === "boolean" ? file.staged : requestStaged,
      additions: Number(file.additions ?? 0),
      deletions: Number(file.deletions ?? 0),
    };
  });
}

export function adaptCoreResult<T>(
  command: string,
  args: JsonRecord | undefined,
  value: unknown,
): T {
  const data = asRecord(value);

  switch (command) {
    case "git_status":
      return {
        branch: data.branch ?? "",
        ahead: data.ahead ?? 0,
        behind: data.behind ?? 0,
        files: Array.isArray(data.changes)
          ? data.changes
              .filter((change: JsonRecord) => String(change.status ?? "") !== "AD")
              .map((change: JsonRecord) => ({
              path: change.path,
              ...(typeof change.originalPath === "string"
                ? { originalPath: change.originalPath }
                : {}),
              status: normalizeStatus(String(change.status ?? ""), Boolean(change.untracked)),
              staged: Boolean(change.staged),
              rawStatus: String(change.status ?? ""),
              worktree: Boolean(change.worktree),
              }))
          : [],
      } as T;
    case "git_log":
      return {
        references: Array.isArray(data.references)
          ? data.references.map((reference: JsonRecord) => ({
              fullName: reference.fullName,
              shortName: reference.shortName,
              kind: reference.kind,
              isCurrent: Boolean(reference.isCurrent),
              upstreamShortName: reference.upstreamShortName ?? undefined,
              ahead: typeof reference.ahead === "number" ? reference.ahead : 0,
              behind: typeof reference.behind === "number" ? reference.behind : 0,
            }))
          : [],
        recentReferences: Array.isArray(data.recentReferences)
          ? data.recentReferences.map((reference: JsonRecord) => ({
              fullName: reference.fullName,
              shortName: reference.shortName,
              kind: reference.kind,
              isCurrent: Boolean(reference.isCurrent),
              upstreamShortName: reference.upstreamShortName ?? undefined,
              ahead: typeof reference.ahead === "number" ? reference.ahead : 0,
              behind: typeof reference.behind === "number" ? reference.behind : 0,
            }))
          : [],
        commits: Array.isArray(data.commits)
          ? data.commits.map((commit: JsonRecord) => ({
              hash: commit.hash,
              shortHash: commit.shortHash ?? String(commit.hash ?? "").slice(0, 7),
              parentHashes: Array.isArray(commit.parentHashes) ? commit.parentHashes : [],
              message: commit.subject,
              author: commit.authorName,
              email: commit.authorEmail,
              date: commit.date,
              decorations: commit.decorations ?? "",
            }))
          : [],
        hasMore: Boolean(data.hasMore),
      } as T;
    case "git_references":
      return {
        references: Array.isArray(data.references)
          ? data.references.map((reference: JsonRecord) => ({
              fullName: reference.fullName,
              shortName: reference.shortName,
              kind: reference.kind,
              isCurrent: Boolean(reference.isCurrent),
              upstreamShortName: reference.upstreamShortName ?? undefined,
              ahead: typeof reference.ahead === "number" ? reference.ahead : 0,
              behind: typeof reference.behind === "number" ? reference.behind : 0,
            }))
          : [],
        recentReferences: Array.isArray(data.recentReferences)
          ? data.recentReferences.map((reference: JsonRecord) => ({
              fullName: reference.fullName,
              shortName: reference.shortName,
              kind: reference.kind,
              isCurrent: Boolean(reference.isCurrent),
              upstreamShortName: reference.upstreamShortName ?? undefined,
              ahead: typeof reference.ahead === "number" ? reference.ahead : 0,
              behind: typeof reference.behind === "number" ? reference.behind : 0,
            }))
          : [],
      } as T;
    case "git_history_page":
      return {
        commits: Array.isArray(data.commits)
          ? data.commits.map((commit: JsonRecord) => ({
              hash: commit.hash,
              shortHash: commit.shortHash ?? String(commit.hash ?? "").slice(0, 7),
              parentHashes: Array.isArray(commit.parentHashes) ? commit.parentHashes : [],
              message: commit.subject,
              author: commit.authorName,
              email: commit.authorEmail,
              date: commit.date,
              decorations: commit.decorations ?? "",
            }))
          : [],
        nextCursor: typeof data.nextCursor === "string" ? data.nextCursor : undefined,
        hasMore: Boolean(data.hasMore),
      } as T;
    case "git_branches":
      return (
        Array.isArray(data.references)
          ? data.references
              .filter((reference: JsonRecord) => reference.kind === "local")
              .map((reference: JsonRecord) => reference.shortName)
          : []
      ) as T;
    case "git_get_stashes":
      return (
        Array.isArray(data.stashes)
          ? data.stashes.map((stash: JsonRecord, index: number) => ({
              index: Number(String(stash.reference ?? "").match(/\d+/)?.[0] ?? index),
              message: stash.message,
              date: stash.date,
            }))
          : []
      ) as T;
    case "git_blame_file": {
      const lines = Array.isArray(data.lines) ? data.lines : [];
      return {
        file_path: asRecord(args).filePath ?? "",
        lines: lines.map((line: JsonRecord) => ({
          line_number: line.line,
          total_lines: lines.length,
          commit_hash: line.commitHash,
          is_uncommitted: /^0+$/.test(String(line.commitHash ?? "")),
          author: line.authorName,
          email: "",
          time: line.authorTime,
          commit: line.commitHash,
        })),
      } as T;
    }
    case "git_diff_file":
    case "git_commit_diff":
    case "git_ref_diff":
    case "git_working_tree_ref_diff":
    case "git_stash_diff":
      return adaptDiff(command, args, value) as T;
    case "git_status_diff_stats":
      return adaptDiffStats(args, value) as T;
    case "git_discover_repo":
      return String(data.output ?? "").trim() as T;
    case "git_get_remotes": {
      const remotes = new Map<string, string>();
      for (const line of String(data.output ?? "").split("\n")) {
        const match = line.match(/^(\S+)\s+(\S+)\s+\(fetch\)$/);
        if (match) remotes.set(match[1], match[2]);
      }
      return [...remotes].map(([name, url]) => ({ name, url })) as T;
    }
    case "git_get_tags":
      return String(data.output ?? "")
        .split("\n")
        .filter(Boolean)
        .map((line) => {
          const [name = "", commit = "", message = "", date = "", objectType = ""] =
            line.split("\0");
          return {
            name,
            commit,
            message: message || undefined,
            date,
            is_annotated: objectType === "tag",
          };
        }) as T;
    case "git_get_worktrees": {
      const currentRoot = String(asRecord(args).repoPath ?? "")
        .replace(/\\/g, "/")
        .replace(/\/$/, "");
      const records = String(data.output ?? "")
        .trim()
        .split(/\n\s*\n/)
        .filter(Boolean);
      return records.map((record) => {
        const fields = new Map(
          record.split("\n").map((line) => {
            const separator = line.indexOf(" ");
            return separator < 0
              ? [line, "true"]
              : [line.slice(0, separator), line.slice(separator + 1)];
          }),
        );
        const path = String(fields.get("worktree") ?? "");
        return {
          path,
          branch: String(fields.get("branch") ?? "").replace(/^refs\/heads\//, "") || undefined,
          head: fields.get("HEAD") ?? "",
          is_bare: fields.has("bare"),
          is_detached: fields.has("detached"),
          locked_reason: fields.get("locked"),
          prunable_reason: fields.get("prunable"),
          is_current: path.replace(/\\/g, "/").replace(/\/$/, "") === currentRoot,
        };
      }) as T;
    }
    case "git_checkout": {
      const exitCode = typeof data.exitCode === "number" ? data.exitCode : 0;
      const output = typeof data.output === "string" ? data.output.trim() : "";
      return { success: exitCode === 0, hasChanges: false, message: output } as T;
    }
    case "git_checkout_preflight": {
      const blockingPaths = Array.isArray(data.blockingPaths)
        ? data.blockingPaths.map((path: unknown) => String(path))
        : [];
      return { blocked: blockingPaths.length > 0, blockingPaths } as T;
    }
    case "git_checkout_tag": {
      const exitCode = typeof data.exitCode === "number" ? data.exitCode : 0;
      const output = typeof data.output === "string" ? data.output.trim() : "";
      return { success: exitCode === 0, hasChanges: false, message: output } as T;
    }
    case "git_operation_state": {
      const kind = typeof data.kind === "string" ? data.kind : "";
      if (!kind) {
        return null as T;
      }
      const conflictedPaths = Array.isArray(data.conflictedPaths)
        ? data.conflictedPaths.map((path: unknown) => String(path))
        : [];
      return {
        kind,
        reference: typeof data.reference === "string" ? data.reference : null,
        step: typeof data.step === "number" ? data.step : null,
        total: typeof data.total === "number" ? data.total : null,
        conflictedPaths,
      } as T;
    }
    case "git_integration_preflight": {
      const blockingPaths = Array.isArray(data.blockingPaths)
        ? data.blockingPaths.map((path: unknown) => String(path))
        : [];
      return {
        blockingPaths,
        blocksEntirely: Boolean(data.blocksEntirely),
      } as T;
    }
    case "git_conflict_markers": {
      const paths = Array.isArray(data.paths)
        ? data.paths.map((path: unknown) => String(path))
        : [];
      return { paths } as T;
    }
    default:
      return value as T;
  }
}
