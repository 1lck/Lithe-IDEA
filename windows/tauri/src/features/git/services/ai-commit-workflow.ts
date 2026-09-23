import type { CommitFileInput } from "../types/ai-commit";

export interface CommitDraftState {
  selection: string;
  message: string;
}
export interface CommitGenerationDependencies {
  readFiles: () => Promise<CommitFileInput[]>;
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
  const files = await deps.readFiles();
  checkSelection();
  const generated = await deps.generate(files);
  checkSelection();
  const draft = deps.current().message;
  if (draft.trim() && !(await deps.confirmReplace())) return "kept";
  checkSelection();
  // Refresh the actual patch, not just file names: edits during the HTTP request invalidate it.
  const latestFiles = await deps.readFiles();
  checkSelection();
  if (JSON.stringify(files) !== JSON.stringify(latestFiles)) throw new Error("AI_COMMIT_STALE");
  if (deps.current().message !== draft) throw new Error("AI_COMMIT_DRAFT_CHANGED");
  deps.apply(generated);
  return "applied";
}
