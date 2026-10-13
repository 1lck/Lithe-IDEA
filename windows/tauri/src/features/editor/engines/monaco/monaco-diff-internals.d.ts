// Narrow declaration for Monaco 0.55.1's synchronous line diff. The public API
// only exposes it through a diff editor; the gutter needs the raw line ranges.
// Re-check this shape whenever the pinned Monaco version changes.
declare module "monaco-editor/esm/vs/editor/common/diff/linesDiffComputers.js" {
  interface LineRange {
    readonly startLineNumber: number;
    readonly endLineNumberExclusive: number;
  }
  interface LineRangeMapping {
    readonly original: LineRange;
    readonly modified: LineRange;
  }
  interface LinesDiff {
    readonly changes: readonly LineRangeMapping[];
    readonly hitTimeout: boolean;
  }
  interface LinesDiffComputer {
    computeDiff(
      originalLines: string[],
      modifiedLines: string[],
      options: { ignoreTrimWhitespace: boolean; maxComputationTimeMs: number; computeMoves: boolean },
    ): LinesDiff;
  }
  export const linesDiffComputers: { getDefault(): LinesDiffComputer };
}
