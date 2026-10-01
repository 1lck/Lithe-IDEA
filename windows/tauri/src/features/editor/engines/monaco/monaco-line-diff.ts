import { linesDiffComputers } from "monaco-editor/esm/vs/editor/common/diff/linesDiffComputers.js";
import type { GitGutterLineDiff } from "@/features/git/utils/git-gutter-changes";

/**
 * Time budget for one gutter comparison. It runs on the UI thread after the
 * user pauses typing; a file too large to compare in this time shows no
 * markers instead of blocking input.
 */
const GIT_GUTTER_DIFF_BUDGET_MS = 150;

/** Monaco's own line diff, the same algorithm its diff editor uses. */
export const monacoLineDiff: GitGutterLineDiff = (original, modified) => {
  // Monaco's computer assumes at least one line on each side, as in a model.
  if (original.length === 0 || modified.length === 0) {
    if (original.length === modified.length) return [];
    return [{
      originalStart: 1,
      originalEnd: original.length + 1,
      modifiedStart: 1,
      modifiedEnd: modified.length + 1,
    }];
  }
  const result = linesDiffComputers.getDefault().computeDiff([...original], [...modified], {
    ignoreTrimWhitespace: false,
    maxComputationTimeMs: GIT_GUTTER_DIFF_BUDGET_MS,
    computeMoves: false,
  });
  if (result.hitTimeout) return null;
  return result.changes.map((change) => ({
    originalStart: change.original.startLineNumber,
    originalEnd: change.original.endLineNumberExclusive,
    modifiedStart: change.modified.startLineNumber,
    modifiedEnd: change.modified.endLineNumberExclusive,
  }));
};
