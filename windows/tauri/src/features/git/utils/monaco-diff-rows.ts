import type { ReviewRow } from "@lithe/editor/diff-review";
import type { GitDiff, GitDiffLine, GitHunk } from "../types/git.types";
import { parseDiffHunkRange } from "./git-diff-helpers";

/** Context kept around each change when a full-file patch is split back into
 * stageable hunks. Matches Git's default `--unified=3`. */
const FULL_CONTEXT_HUNK_CONTEXT_LINES = 3;

/** A stageable range of a full-context patch, as indices into `diff.lines`. */
interface FullContextHunk {
  id: string;
  /** First changed line; the hunk's action band is rendered above it. */
  anchor: number;
  start: number;
  /** Exclusive end index. */
  end: number;
}

const isChange = (line: GitDiffLine) => line.line_type === "added" || line.line_type === "removed";

/** Splits a full-context patch the way Git would at three context lines, so
 * staging granularity does not grow to the whole file. Returns null for sparse
 * patches, which keep the host's own hunks. */
function fullContextHunks(diff: GitDiff): FullContextHunk[] | null {
  const { lines } = diff;
  if (!diff.is_full_context || lines[0]?.line_type !== "header"
    || lines.some((line, index) => index > 0 && line.line_type === "header")) return null;
  const context = FULL_CONTEXT_HUNK_CONTEXT_LINES;
  const hunks: FullContextHunk[] = [];
  for (let index = 1; index < lines.length; index++) {
    if (!isChange(lines[index])) continue;
    let last = index;
    // Like Git, changes whose surrounding context would touch share one hunk.
    for (let next = index + 1; next < lines.length && next - last - 1 <= 2 * context; next++) {
      if (isChange(lines[next])) last = next;
    }
    hunks.push({
      id: `hunk-${index}`,
      anchor: index,
      start: Math.max(1, index - context),
      end: Math.min(lines.length, last + context + 1),
    });
    index = last;
  }
  return hunks;
}

function hunkHeader(lines: GitDiffLine[], start: number, end: number): string {
  const range = (key: "old_line_number" | "new_line_number") => {
    const numbers = lines.slice(start, end).flatMap(line => line[key] ?? []);
    if (numbers.length > 0) return `${numbers[0]},${numbers.length}`;
    // Git names the line before an empty range, or 0 at the start of the file.
    for (let index = start - 1; index >= 0; index--) {
      const previous = lines[index][key];
      if (previous !== undefined) return `${previous},0`;
    }
    return "0,0";
  };
  return `@@ -${range("old_line_number")} +${range("new_line_number")} @@`;
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
  if (diff.is_truncated || !/^hunk-(0|[1-9]\d*)$/.test(hunkID)) return null;
  const derived = fullContextHunks(diff);
  if (derived) {
    const hunk = derived.find(candidate => candidate.id === hunkID);
    if (!hunk) return null;
    return {
      file_path: diff.file_path,
      lines: [
        { line_type: "header", content: hunkHeader(diff.lines, hunk.start, hunk.end) },
        ...diff.lines.slice(hunk.start, hunk.end),
      ],
    };
  }
  const start = Number(hunkID.slice(5));
  const header = diff.lines[start];
  if (header?.line_type !== "header" || !parseDiffHunkRange(header.content)) return null;
  let end = start + 1;
  while (end < diff.lines.length && diff.lines[end].line_type !== "header") end++;
  if (end === start + 1) return null;
  return { file_path: diff.file_path, lines: diff.lines.slice(start, end) };
}
