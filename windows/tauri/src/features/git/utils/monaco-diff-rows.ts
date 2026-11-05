import type { ReviewRow } from "@lithe/editor/diff-review";
import type { GitDiff, GitDiffLine, GitHunk } from "../types/git.types";
import { parseDiffHunkRange } from "./git-diff-helpers";

/** A Core-split Git-default hunk of a complete-file patch, as indices into `diff.lines`. */
interface FullContextHunk {
  id: string;
  /** First changed line; the hunk's action band is rendered above it. */
  anchor: number;
  start: number;
  /** Exclusive end index. */
  end: number;
  header: string;
  patch: string;
}

const isChange = (line: GitDiffLine) => line.line_type === "added" || line.line_type === "removed";

/** Reads the stageable hunks Core split from a complete-file patch. Core owns
 * both the split and each hunk's patch bytes; this only locates them in the
 * display lines. Returns null for sparse patches, which keep the host's own
 * hunks, and an empty list when Core offered no writable hunk. */
function fullContextHunks(diff: GitDiff): FullContextHunk[] | null {
  const { lines } = diff;
  if (!diff.is_full_context || lines[0]?.line_type !== "header"
    || lines.some((line, index) => index > 0 && line.line_type === "header")) return null;
  const hunks: FullContextHunk[] = [];
  for (const core of diff.core_hunks ?? []) {
    const { lineStart: start, lineEnd: end } = core;
    if (start === undefined || end === undefined || !core.patch) continue;
    const anchor = lines.findIndex((line, index) => index >= start && index < end && isChange(line));
    if (anchor < 0) continue;
    hunks.push({ id: core.id, anchor, start, end, header: core.header, patch: core.patch });
  }
  return hunks;
}

const rowKind = (line: GitDiffLine): ReviewRow["kind"] =>
  line.line_type === "header" ? "information"
    : line.line_type === "added" ? "addition"
    : line.line_type === "removed" ? "removal" : "context";

/** Preserve patch order and identity. Monaco aligns the projections, while
 * search results continue to address the original Git line array. */
export function monacoDiffRows(diff: GitDiff, options: { hideHunkHeaders?: boolean } = {}): ReviewRow[] {
  const derived = fullContextHunks(diff);
  if (derived) {
    // The single full-file header carries no information worth a row, and its
    // range would stage the whole file; derived hunks own the actions instead.
    const owners = new Map<number, FullContextHunk>();
    for (const hunk of derived) for (let index = hunk.start; index < hunk.end; index++) owners.set(index, hunk);
    return diff.lines.flatMap((line, index) => {
      if (line.line_type === "header") return [];
      const hunk = owners.get(index);
      return [{
        id: `line-${index}`,
        oldLine: line.old_line_number ?? null,
        newLine: line.new_line_number ?? null,
        left: line.line_type === "added" ? null : line.content,
        right: line.line_type === "removed" ? null : line.content,
        kind: rowKind(line),
        hunkID: hunk?.id ?? null,
        ...(hunk?.anchor === index ? { actionAnchor: true } : {}),
      }];
    });
  }

  let hunkID: string | null = null;
  return diff.lines.flatMap((line, index) => {
    if (line.line_type === "header") hunkID = `hunk-${index}`;
    if (options.hideHunkHeaders && line.line_type === "header") return [];
    return [{
      id: `line-${index}`,
      oldLine: line.old_line_number ?? null,
      newLine: line.new_line_number ?? null,
      left: line.line_type === "added" ? null : line.content,
      right: line.line_type === "removed" ? null : line.content,
      kind: rowKind(line),
      hunkID,
    }];
  });
}

/** Resolve the host's patch identity, never Monaco's aligned display ranges. */
export function monacoDiffHunk(diff: GitDiff, hunkID: string): GitHunk | null {
  if (diff.is_truncated) return null;
  const derived = fullContextHunks(diff);
  if (derived) {
    const hunk = derived.find(candidate => candidate.id === hunkID);
    if (!hunk) return null;
    // The patch is Core's, with original bytes; display lines only label it.
    return {
      file_path: diff.file_path,
      lines: [
        { line_type: "header", content: hunk.header },
        ...diff.lines.slice(hunk.start, hunk.end),
      ],
      rawPatch: hunk.patch,
    };
  }
  if (!/^hunk-(0|[1-9]\d*)$/.test(hunkID)) return null;
  const start = Number(hunkID.slice(5));
  const header = diff.lines[start];
  if (header?.line_type !== "header" || !parseDiffHunkRange(header.content)) return null;
  let end = start + 1;
  while (end < diff.lines.length && diff.lines[end].line_type !== "header") end++;
  if (end === start + 1) return null;
  // Sparse hunks are Core's own; the patch is found by its header, and a
  // missing or ambiguous match leaves the hunk without a writable patch.
  const matches = (diff.core_hunks ?? []).filter(core => core.header === header.content && core.patch);
  return { file_path: diff.file_path, lines: diff.lines.slice(start, end),
    ...(matches.length === 1 ? { rawPatch: matches[0].patch } : {}) };
}
