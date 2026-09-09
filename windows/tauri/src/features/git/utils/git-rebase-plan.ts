import type { GitHistoryRewriteCommit } from "../types/git-history-rewrite.types";
import type { GitRebaseStep } from "../types/git-rebase.types";

/** Plan messages are explicit user edits; predicted squash text stays presentation-only. */
export function prepareGitRebasePlan(
  steps: GitRebaseStep[],
  commits: GitHistoryRewriteCommit[],
): { steps: GitRebaseStep[]; messages: Map<string, string> } {
  const originals = new Map(commits.map((commit) => [commit.hash, commit.message]));
  const messages = new Map<string, string>();
  let combined = "";
  const prepared = steps.map((step): GitRebaseStep => {
    const original = originals.get(step.hash) ?? "";
    let displayed = original;
    switch (step.action) {
      case "pick":
      case "edit":
        combined = original;
        break;
      case "reword":
        combined = displayed = step.message ?? original;
        break;
      case "squash":
        combined = displayed = step.message ?? `${combined.replace(/\n+$/, "")}\n\n${original}`;
        break;
      case "fixup":
      case "drop":
        break;
    }
    messages.set(step.hash, displayed);
    return {
      hash: step.hash,
      action: step.action,
      ...(step.action === "reword"
        ? { message: displayed }
        : step.action === "squash" && step.message !== undefined
          ? { message: step.message }
          : {}),
    };
  });
  return { steps: prepared, messages };
}
