import type { CommitDiffBlock } from "../api/git-diff-block-api";
import type { IndependentChange, planIndependentCommitDiff } from "./independent-commit-diff";

export type { CommitDiffBlock };

/** Row identity of a change, matching the block ID Core plans: the first old-side
 * row of the change, else its first new-side row. Core owns the blocks; this
 * only locates them in the display plan. */
export function commitDiffChangeID(
  plan: ReturnType<typeof planIndependentCommitDiff>, change: IndependentChange,
): string {
  return change.leftStart < change.leftEnd
    ? plan.left[change.leftStart].id : plan.right[change.rightStart].id;
}
