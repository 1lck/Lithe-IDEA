import type { GitDiff, GitDiffSplitRow } from "@/features/git/types/git.types";
import { countSplitDiffStats } from "@/features/git/utils/git-diff-helpers";

type JsonRecord = Record<string, any>;

function asRecord(value: unknown): JsonRecord {
  return typeof value === "object" && value !== null ? (value as JsonRecord) : {};
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

/** Projects one Core status change into the Windows file shape. */
function adaptStatusChange(change: JsonRecord) {
  return {
    path: change.path,
    ...(typeof change.originalPath === "string" ? { originalPath: change.originalPath } : {}),
    status: normalizeStatus(String(change.status ?? ""), Boolean(change.untracked)),
    staged: Boolean(change.staged),
    rawStatus: String(change.status ?? ""),
    ...(typeof change.canToggleStaging === "boolean"
      ? { canToggleStaging: change.canToggleStaging }
      : {}),
    ...(change.submodule ? { submodule: change.submodule } : {}),
    worktree: Boolean(change.worktree),
    ...(typeof change.untrackedFileCount === "number"
      ? { untrackedFileCount: change.untrackedFileCount }
      : {}),
  };
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
    const isInvisibleChange = kind === "changed" && row.isInvisibleChange === true;
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

function adaptDiff(command: string, args: JsonRecord | undefined, value: unknown): unknown {
  const data = asRecord(value);
  const diffs: GitDiff[] = (Array.isArray(data.files) ? data.files : []).map((entry: unknown) => {
    const file = asRecord(entry);
    const path = String(file.path ?? "");
    const status = String(file.status ?? "M");
    const splitHunks = adaptStructuredSplitHunks(file.rows);
    const stats = countSplitDiffStats(splitHunks);
    const decodingLoss = Boolean(data.hasDecodingLoss);
    return {
      file_path: path, old_path: status === "A" ? undefined : String(file.originalPath ?? path),
      new_path: status === "D" ? undefined : path, is_new: status === "A",
      is_deleted: status === "D", is_renamed: status === "R", is_binary: Boolean(file.isBinary),
      is_image: false, has_lossy_line_endings: Boolean(file.hasLossyLineEndings) || decodingLoss,
      has_decoding_loss: decodingLoss,
      lines: (Array.isArray(file.lines) ? file.lines : []).map((entry: unknown) => {
        const line = asRecord(entry);
        return { line_type: line.lineType, content: String(line.content ?? ""),
          old_line_number: line.oldLine ?? undefined, new_line_number: line.newLine ?? undefined };
      }),
      split_hunks: splitHunks,
      additions: splitHunks.length ? stats.additions : Number(file.additions ?? 0),
      deletions: splitHunks.length ? stats.deletions : Number(file.deletions ?? 0),
      core_hunks: decodingLoss ? undefined : (Array.isArray(file.hunks) ? file.hunks : []).map((entry: unknown) => {
        const hunk = asRecord(entry);
        return { id: String(hunk.id ?? ""), header: String(hunk.header ?? ""),
          patch: String((status === "R" ? hunk.contentPatch : hunk.patch) ?? ""),
          ...(typeof hunk.lineStart === "number" && typeof hunk.lineEnd === "number"
            ? { lineStart: hunk.lineStart, lineEnd: hunk.lineEnd } : {}) };
      }),
    };
  });
  if (command === "git_status_diff_stats") {
    return diffs.map((diff) => ({ file_path: diff.file_path, staged: Boolean(asRecord(args).staged),
      additions: diff.additions ?? 0, deletions: diff.deletions ?? 0 }));
  }
  if (command === "git_diff_file") {
    return diffs[0] ?? { file_path: String(asRecord(args).filePath ?? ""), is_new: false,
      is_deleted: false, is_renamed: false, lines: [] };
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

  if (data.files.some((file: JsonRecord) => Array.isArray(file.rows))) {
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

/** Projects one Core history commit into the Windows commit shape. */
function adaptHistoryCommit(commit: JsonRecord) {
  return {
    hash: commit.hash,
    shortHash: commit.shortHash ?? String(commit.hash ?? "").slice(0, 7),
    parentHashes: Array.isArray(commit.parentHashes) ? commit.parentHashes : [],
    message: commit.subject,
    author: commit.authorName,
    email: commit.authorEmail,
    date: commit.date,
    dateUtcOffsetMinutes:
      typeof commit.dateUtcOffsetMinutes === "number" ? commit.dateUtcOffsetMinutes : undefined,
    dateUnixSeconds:
      typeof commit.dateUnixSeconds === "number" ? commit.dateUnixSeconds : undefined,
    decorations: commit.decorations ?? "",
  };
}

function adaptHistoryCommits(value: unknown) {
  return Array.isArray(value) ? value.map((commit: JsonRecord) => adaptHistoryCommit(commit)) : [];
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
              .filter(
                (change: JsonRecord) =>
                  args?.includeIndexOnlyChanges || String(change.status ?? "") !== "AD",
              )
              .map(adaptStatusChange)
          : [],
      } as T;
    case "git.untrackedDirectory":
      return {
        files: Array.isArray(data.changes) ? data.changes.map(adaptStatusChange) : [],
      } as T;
    case "git_log":
      return {
        references: Array.isArray(data.references)
          ? data.references.map((reference: JsonRecord) => ({
              fullName: reference.fullName,
              shortName: reference.shortName,
              kind: reference.kind,
              peelsToCommit: Boolean(reference.peelsToCommit),
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
              peelsToCommit: Boolean(reference.peelsToCommit),
              isCurrent: Boolean(reference.isCurrent),
              upstreamShortName: reference.upstreamShortName ?? undefined,
              ahead: typeof reference.ahead === "number" ? reference.ahead : 0,
              behind: typeof reference.behind === "number" ? reference.behind : 0,
            }))
          : [],
        commits: adaptHistoryCommits(data.commits),
        hasMore: Boolean(data.hasMore),
      } as T;
    case "git_references":
      return {
        references: Array.isArray(data.references)
          ? data.references.map((reference: JsonRecord) => ({
              fullName: reference.fullName,
              shortName: reference.shortName,
              kind: reference.kind,
              peelsToCommit: Boolean(reference.peelsToCommit),
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
              peelsToCommit: Boolean(reference.peelsToCommit),
              isCurrent: Boolean(reference.isCurrent),
              upstreamShortName: reference.upstreamShortName ?? undefined,
              ahead: typeof reference.ahead === "number" ? reference.ahead : 0,
              behind: typeof reference.behind === "number" ? reference.behind : 0,
            }))
          : [],
      } as T;
    case "git_history_page":
      return {
        commits: adaptHistoryCommits(data.commits),
        nextCursor: typeof data.nextCursor === "string" ? data.nextCursor : undefined,
        hasMore: Boolean(data.hasMore),
      } as T;
    case "git.historyLocate":
      return {
        found: Boolean(data.found),
        commits: adaptHistoryCommits(data.commits),
        nextCursor: typeof data.nextCursor === "string" ? data.nextCursor : undefined,
        hasMore: Boolean(data.hasMore),
        pagesLoaded: typeof data.pagesLoaded === "number" ? data.pagesLoaded : 0,
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
              oid: stash.oid,
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
          // Core emits one entry per source line, so every entry covers exactly
          // that line; the gutter shape expresses it as a single-line span.
          // Using the entry count here made every span swallow the whole file,
          // so the lookup attributed a line to an arbitrary commit.
          total_lines: 1,
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
    case "git.diff":
    case "git.parsePatch":
    case "git_ref_diff":
    case "git_working_tree_ref_diff":
    case "git_stash_diff":
      return adaptDiff(command, args, value) as T;
    case "git.planDiffBlocks": {
      // Core plans blocks and owns every patch; only display sections adapt.
      const section = (key: string) => (adaptDiff("git.diff", args, data[key]) as GitDiff[])[0]
        ?? { file_path: String(args?.path ?? ""), is_new: false, is_deleted: false,
          is_renamed: false, lines: [] };
      return { token: String(data.token ?? ""), blocks: Array.isArray(data.blocks) ? data.blocks : [],
        diff: section("worktree"), staged: section("index") } as T;
    }
    case "git_status_diff_stats":
      return adaptDiffStats(args, value) as T;
    case "git_discover_repo":
      return String(typeof value === "string" ? value : (data.output ?? "")).trim() as T;
    case "git_get_remotes":
      return (Array.isArray(data.remotes) ? data.remotes : []) as T;
    case "git_get_tags":
      return (Array.isArray(data.tags) ? data.tags : [])
        .map((entry: unknown) => {
          const tag = asRecord(entry);
          return {
            name: tag.name,
            commit: tag.targetId,
            object_id: tag.objectId,
            message: tag.message ?? undefined,
            date: tag.date,
            is_annotated: tag.isAnnotated,
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
