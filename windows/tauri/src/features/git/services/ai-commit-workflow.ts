import type { CommitFileInput } from "../types/ai-commit";
import type { CommitContext } from "./ai-commit-context";

export interface CommitDraftState {
  selection: string;
  message: string;
}
export interface CommitGenerationDependencies {
  readContext: () => Promise<CommitContext>;
  isCurrent: (context: CommitContext) => Promise<boolean>;
  generate: (files: CommitFileInput[]) => Promise<string>;
  current: () => CommitDraftState;
  confirmReplace: () => Promise<boolean>;
  apply: (message: string) => void;
  signal: AbortSignal;
}

/** Keeps generation separate from committing and checks fresh evidence before applying any draft. */
export async function generateCommitDraft(
  deps: CommitGenerationDependencies,
): Promise<"applied" | "kept"> {
  const selection = deps.current().selection;
  const checkSelection = () => {
    deps.signal.throwIfAborted();
    if (deps.current().selection !== selection) throw new Error("AI_COMMIT_STALE");
  };
  const context = await deps.readContext();
  checkSelection();
  const generated = await deps.generate(context.files);
  checkSelection();
  const draft = deps.current().message;
  if (draft.trim() && !(await deps.confirmReplace())) return "kept";
  checkSelection();
  // Core checks fresh Git content and the index, without the UI diff cache.
  const stillCurrent = await deps.isCurrent(context);
  checkSelection();
  if (!stillCurrent) throw new Error("AI_COMMIT_STALE");
  if (deps.current().message !== draft) throw new Error("AI_COMMIT_DRAFT_CHANGED");
  deps.apply(generated);
  return "applied";
}
