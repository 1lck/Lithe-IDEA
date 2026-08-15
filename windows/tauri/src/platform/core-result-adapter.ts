import { parseRawDiffContent } from "@/features/git/utils/git-diff-parser";

type JsonRecord = Record<string, any>;

function asRecord(value: unknown): JsonRecord {
  return typeof value === "object" && value !== null ? (value as JsonRecord) : {};
}

function normalizeStatus(status: string, untracked: boolean): string {
  if (untracked || status.includes("?")) return "untracked";
  if (status.includes("A")) return "added";
  if (status.includes("D")) return "deleted";
  if (status.includes("R")) return "renamed";
  return "modified";
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

  if (command === "git_diff_file") {
    return "files" in parsed ? parsed.files[0] ?? null : parsed;
  }
  if (command === "git_status_diff_stats") {
    const diffs = "files" in parsed ? parsed.files : [parsed];
    return diffs.map((diff) => ({
      file_path: diff.file_path,
      staged: false,
      additions: diff.additions ?? diff.lines.filter((line) => line.line_type === "added").length,
      deletions: diff.deletions ?? diff.lines.filter((line) => line.line_type === "removed").length,
    }));
  }
  return "files" in parsed ? parsed.files : [parsed];
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
          ? data.changes.map((change: JsonRecord) => ({
              path: change.path,
              status: normalizeStatus(String(change.status ?? ""), Boolean(change.untracked)),
              staged: Boolean(change.staged),
            }))
          : [],
      } as T;
    case "git_log":
      return (Array.isArray(data.commits)
        ? data.commits.map((commit: JsonRecord) => ({
            hash: commit.hash,
            message: commit.subject,
            author: commit.authorName,
            email: commit.authorEmail,
            date: commit.date,
          }))
        : []) as T;
    case "git_branches":
      return (Array.isArray(data.references)
        ? data.references
            .filter((reference: JsonRecord) => reference.kind === "local")
            .map((reference: JsonRecord) => reference.shortName)
        : []) as T;
    case "git_get_stashes":
      return (Array.isArray(data.stashes)
        ? data.stashes.map((stash: JsonRecord, index: number) => ({
            index: Number(String(stash.reference ?? "").match(/\d+/)?.[0] ?? index),
            message: stash.message,
            date: stash.date,
          }))
        : []) as T;
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
    case "git_status_diff_stats":
    case "git_commit_diff":
    case "git_ref_diff":
    case "git_stash_diff":
      return adaptDiff(command, args, value) as T;
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
          const [name = "", commit = "", message = "", date = "", objectType = ""] = line.split("\0");
          return { name, commit, message: message || undefined, date, is_annotated: objectType === "tag" };
        }) as T;
    case "git_get_worktrees": {
      const currentRoot = String(asRecord(args).repoPath ?? "").replace(/\\/g, "/").replace(/\/$/, "");
      const records = String(data.output ?? "").trim().split(/\n\s*\n/).filter(Boolean);
      return records.map((record) => {
        const fields = new Map(record.split("\n").map((line) => {
          const separator = line.indexOf(" ");
          return separator < 0 ? [line, "true"] : [line.slice(0, separator), line.slice(separator + 1)];
        }));
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
    case "git_checkout_tag":
      return { success: true, hasChanges: false, message: "" } as T;
    default:
      return value as T;
  }
}
