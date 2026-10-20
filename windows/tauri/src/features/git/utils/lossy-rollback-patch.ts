import type { GitDiff, GitDiffLine, GitHunk } from "../types/git.types";

/** One raw patch line with its original bytes (including CR) intact. */
interface RawPatchLine {
  /** Prefix character: ' ', '+', '-', or '\\' for the no-newline marker. */
  prefix: string;
  /** Line content after the prefix, with original line endings preserved. */
  content: string;
  /** True for `\\ No newline at end of file` markers. */
  isEofMarker: boolean;
  /** One-based old-side line number, when the prefix occupies an old line. */
  oldLine: number | null;
  /** One-based new-side line number, when the prefix occupies a new line. */
  newLine: number | null;
}

/**
 * Parses a unified diff patch into raw lines with original bytes. Unlike the
 * display parser, this never strips CR or skips EOF markers — the whole point
 * is byte fidelity for `git apply`.
 */
export function parseRawPatchLines(patch: string): RawPatchLine[] {
  const result: RawPatchLine[] = [];
  let oldLine = 0;
  let newLine = 0;
  let inHunk = false;

  for (const raw of patch.split("\n")) {
    if (raw.startsWith("@@")) {
      inHunk = true;
      const match = raw.match(/@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/);
      if (match) {
        oldLine = parseInt(match[1], 10);
        newLine = parseInt(match[3], 10);
      }
      continue;
    }
    if (!inHunk) continue;
    if (raw === "") continue;

    if (raw.startsWith("\\ No newline")) {
      // The marker belongs to the previous line's old side, new side, or
      // both, but never occupies a source line number itself.
      result.push({ prefix: "\\", content: raw, isEofMarker: true, oldLine: null, newLine: null });
      continue;
    }

    const prefix = raw[0];
    const content = raw.slice(1);
    const entry: RawPatchLine = {
      prefix,
      content,
      isEofMarker: false,
      oldLine: null,
      newLine: null,
    };
    if (prefix === " " || prefix === "-") {
      entry.oldLine = oldLine++;
    }
    if (prefix === " " || prefix === "+") {
      entry.newLine = newLine++;
    }
    result.push(entry);
  }
  return result;
}

/**
 * Extracts a single hunk's raw patch text covering the target old/new line
 * range from a full raw patch. The result preserves CR bytes and EOF markers
 * so `git apply` can reverse it byte-faithfully.
 *
 * When targetOldEnd/targetNewEnd are provided, the extracted contiguous run
 * is verified not to extend beyond the target range — a run that would affect
 * changes outside the selected block returns null (conservative disable).
 *
 * @returns null when the range cannot be unambiguously isolated.
 */
export function sliceRawHunkPatch(
  patch: string,
  filePath: string,
  targetOldStart: number,
  targetNewStart: number,
  targetOldEnd?: number,
  targetNewEnd?: number,
): string | null {
  const lines = parseRawPatchLines(patch);
  if (lines.length === 0) return null;

  // Build a minimal U0 hunk: only the changed lines covering the target,
  // context stripped, original bytes (CR, EOF markers) preserved. This pairs
  // with git apply --unidiff-zero for byte-faithful reverse application.
  // A replacement block is a contiguous run of `-` and `+` lines with no
  // context line in between; the target identifies which block by its
  // one-based new-side line (for replacements and insertions) or old-side
  // line (for pure deletions, which have no new-side lines).
  let blockStart = -1;
  let blockEnd = -1;
  let currentStart = -1;
  let found = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line.isEofMarker) continue;
    if (line.prefix === "+" || line.prefix === "-") {
      if (currentStart === -1) currentStart = i;
      if (!found) {
        // Match by new-side line for replacement/insertion blocks, or by
        // old-side line for pure deletion blocks (newLine is null).
        const newMatch = line.newLine !== null && line.newLine === targetNewStart;
        const oldMatch =
          line.newLine === null && line.oldLine !== null && line.oldLine === targetOldStart;
        if (newMatch || oldMatch) {
          found = true;
          blockStart = currentStart;
        }
      }
    } else {
      // Context line terminates the current run.
      if (found && currentStart !== -1) {
        blockEnd = i - 1;
        break;
      }
      currentStart = -1;
    }
  }
  if (found && blockEnd === -1) blockEnd = lines.length - 1;
  if (!found || blockStart === -1) return null;

  // Range verification: when target endpoints are provided, the contiguous
  // run must not extend beyond them in either direction — a run that
  // includes changes outside the selected block would roll back content
  // the user did not choose. Additionally, the run must COVER all changed
  // lines within the target range: when the range contains separated
  // changes, a single contiguous run cannot represent them and the caller
  // needs the range-based builder instead.
  if (targetNewEnd !== undefined && targetOldEnd !== undefined) {
    for (let i = blockStart; i <= blockEnd; i++) {
      const line = lines[i];
      if (line.isEofMarker) continue;
      if (line.newLine !== null && (line.newLine > targetNewEnd || line.newLine < targetNewStart)) return null;
      if (line.oldLine !== null && (line.oldLine > targetOldEnd || line.oldLine < targetOldStart)) return null;
    }
    // Coverage check: every changed line in the raw patch within the target
    // range must be inside this contiguous run. If any is outside (separated
    // by context from this run), the single-run slicer is insufficient.
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (line.isEofMarker || (line.prefix !== "+" && line.prefix !== "-")) continue;
      const inTargetRange =
        (line.oldLine !== null && line.oldLine >= targetOldStart && line.oldLine <= targetOldEnd) ||
        (line.newLine !== null && line.newLine >= targetNewStart && line.newLine <= targetNewEnd);
      if (inTargetRange && (i < blockStart || i > blockEnd)) return null;
    }
  }

  // Include trailing EOF markers attached to the last changed line.
  while (blockEnd + 1 < lines.length && lines[blockEnd + 1].isEofMarker) {
    blockEnd++;
  }

  const hunkLines = lines.slice(blockStart, blockEnd + 1);
  if (hunkLines.length === 0) return null;

  // U0 hunk: count only changed lines for each side.
  let oldCount = 0;
  let newCount = 0;
  let firstOldLine: number | null = null;
  let firstNewLine: number | null = null;
  for (const line of hunkLines) {
    if (line.isEofMarker) continue;
    if (line.prefix === "-") {
      oldCount++;
      if (firstOldLine === null && line.oldLine !== null) firstOldLine = line.oldLine;
    }
    if (line.prefix === "+") {
      newCount++;
      if (firstNewLine === null && line.newLine !== null) firstNewLine = line.newLine;
    }
  }
  // When one side has zero lines, git uses the position-before convention:
  // the hunk header's start is the line number preceding the insertion or
  // the deletion boundary.
  const oldStart = oldCount === 0
    ? Math.max(0, (firstOldLine ?? targetOldStart) - 1)
    : (firstOldLine ?? targetOldStart);
  const newStart = newCount === 0
    ? Math.max(0, (firstNewLine ?? targetNewStart) - 1)
    : (firstNewLine ?? targetNewStart);

  const header = `@@ -${oldStart},${oldCount} +${newStart},${newCount} @@`;
  const body = hunkLines.map((line) => (line.isEofMarker ? line.content : line.prefix + line.content));

  return `diff --git a/${filePath} b/${filePath}\n--- a/${filePath}\n+++ b/${filePath}\n${header}\n${body.join("\n")}\n`;
}

/**
 * Builds a GitHunk whose lines carry original bytes (CR, EOF markers) from
 * the writePatch, so the host-side patch reconstruction is byte-faithful.
 * When target endpoints are provided, the slice is verified not to extend
 * beyond them (a contiguous run crossing block boundaries returns null).
 */
export function buildByteFaithfulHunk(
  diff: GitDiff,
  targetOldStart: number,
  targetNewStart: number,
  targetOldEnd?: number,
  targetNewEnd?: number,
): GitHunk | null {
  if (!diff.writePatch) return null;
  const patch = sliceRawHunkPatch(
    diff.writePatch,
    diff.new_path || diff.file_path,
    targetOldStart,
    targetNewStart,
    targetOldEnd,
    targetNewEnd,
  );
  if (!patch) return null;
  const rawLines = parseRawPatchLines(patch);
  const hunkLines: GitDiffLine[] = rawLines
    .filter((line) => !line.isEofMarker && line.prefix !== "@")
    .map((line) => ({
      line_type: line.prefix === "+" ? "added" : line.prefix === "-" ? "removed" : "context",
      content: line.content,
      old_line_number: line.oldLine ?? undefined,
      new_line_number: line.newLine ?? undefined,
    }));
  if (hunkLines.length === 0) return null;
  return {
    file_path: diff.new_path || diff.file_path,
    lines: hunkLines,
    // The host checks rawPatch to bypass display-line reconstruction; without
    // it, EOF markers embedded in the patch text would be lost.
    rawPatch: patch,
  };
}

/**
 * Builds a byte-faithful GitHunk from ALL changed raw-patch lines within the
 * given one-based range, regardless of contiguity. Used when a selection
 * spans multiple separated change runs (e.g. insert + nearby replacement).
 */
export function buildFaithfulHunkFromRange(
  diff: GitDiff,
  oldStart: number,
  newStart: number,
  oldEnd: number,
  newEnd: number,
): GitHunk | null {
  if (!diff.writePatch) return null;
  const lines = parseRawPatchLines(diff.writePatch);
  const inRange = lines.filter((line) => {
    if (line.isEofMarker) return false;
    if (line.prefix !== "+" && line.prefix !== "-") return false;
    const oldOk = line.oldLine === null || (line.oldLine >= oldStart && line.oldLine <= oldEnd);
    const newOk = line.newLine === null || (line.newLine >= newStart && line.newLine <= newEnd);
    return oldOk && newOk;
  });
  if (inRange.length === 0) return null;
  // Preserve original ordering: include EOF markers adjacent to their
  //所属 changed line in the raw patch, never appended after other lines.
  // An old-side no-newline marker must stay after its `-` line, not after
  // a following `+` line, or reverse-application restores the wrong side.
  const ordered = lines.filter((line) => {
    if (inRange.includes(line)) return true;
    if (line.isEofMarker) {
      const idx = lines.indexOf(line);
      return idx > 0 && inRange.includes(lines[idx - 1]);
    }
    return false;
  });
  const filePath = diff.new_path || diff.file_path;

  // Group into contiguous runs (adjacent in the original patch, no context
  // gap) — each run becomes its own @@ hunk so separated changes apply
  // correctly instead of sharing one wrong-range header.
  const runs: RawPatchLine[][] = [];
  let currentRun: RawPatchLine[] = [];
  for (const line of ordered) {
    if (line.isEofMarker) {
      if (currentRun.length > 0) currentRun.push(line);
      continue;
    }
    const prev = currentRun[currentRun.length - 1];
    // Adjacent if both are changed lines from the same contiguous segment
    // (their positions in the original `lines` array are consecutive).
    const prevIdx = prev ? lines.indexOf(prev) : -1;
    const currIdx = lines.indexOf(line);
    if (prev && !prev.isEofMarker && currIdx === prevIdx + 1) {
      currentRun.push(line);
    } else {
      if (currentRun.length > 0) runs.push(currentRun);
      currentRun = [line];
    }
  }
  if (currentRun.length > 0) runs.push(currentRun);

  // Build one @@ header per run.
  const hunkHeaders: string[] = [];
  const allBodyLines: string[] = [];
  for (const run of runs) {
    let oldCount = 0;
    let newCount = 0;
    let firstOld: number | null = null;
    let firstNew: number | null = null;
    for (const line of run) {
      if (line.isEofMarker) continue;
      if (line.prefix === "-") {
        oldCount++;
        if (firstOld === null && line.oldLine !== null) firstOld = line.oldLine;
      }
      if (line.prefix === "+") {
        newCount++;
        if (firstNew === null && line.newLine !== null) firstNew = line.newLine;
      }
    }
    const oStart = oldCount === 0 ? Math.max(0, (firstOld ?? oldStart) - 1) : (firstOld ?? oldStart);
    const nStart = newCount === 0 ? Math.max(0, (firstNew ?? newStart) - 1) : (firstNew ?? newStart);
    hunkHeaders.push(`@@ -${oStart},${oldCount} +${nStart},${newCount} @@`);
    for (const line of run) {
      allBodyLines.push(line.isEofMarker ? line.content : line.prefix + line.content);
    }
  }

  // Assemble the multi-hunk patch.
  const parts: string[] = [`diff --git a/${filePath} b/${filePath}`, `--- a/${filePath}`, `+++ b/${filePath}`];
  for (let i = 0; i < hunkHeaders.length; i++) {
    parts.push(hunkHeaders[i]);
  }
  // Interleave headers with their body lines correctly.
  const patchLines: string[] = [`diff --git a/${filePath} b/${filePath}`, `--- a/${filePath}`, `+++ b/${filePath}`];
  let bodyIdx = 0;
  for (const run of runs) {
    const hdr = hunkHeaders[runs.indexOf(run)];
    patchLines.push(hdr);
    for (const line of run) {
      patchLines.push(line.isEofMarker ? line.content : line.prefix + line.content);
    }
  }
  const patch = patchLines.join("\n") + "\n";

  const hunkLines: GitDiffLine[] = ordered
    .filter((line) => !line.isEofMarker)
    .map((line) => ({
      line_type: line.prefix === "+" ? "added" : "removed",
      content: line.content,
      old_line_number: line.oldLine ?? undefined,
      new_line_number: line.newLine ?? undefined,
    }));
  return { file_path: filePath, lines: hunkLines, rawPatch: patch };
}
