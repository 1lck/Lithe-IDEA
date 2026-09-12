/** Native diagnostics only; command input and environment are never included. */
export interface GitExecutionEvent {
  operationId: string;
  type: "requestStarted" | "started" | "output" | "finished" | "requestFinished" | "authentication" | "remoteResult";
  invocationId?: number;
  workingDirectory?: string;
  arguments?: string[];
  stream?: "stdout" | "stderr";
  text?: string;
  progress?: boolean;
  truncated?: boolean;
  exitCode?: number | null;
  durationMilliseconds?: number;
  error?: { code?: string; message: string; details?: string } | null;
  action?: string;
  executable?: string | null;
  temporaryConfig?: string[][];
  displayArguments?: string[];
  globalArguments?: string[];
  progressDetails?: { stage: string; percent?: number | null; completed?: number | null; total?: number | null };
  requestId?: string;
  prompt?: string;
  secret?: boolean;
  attempt?: number;
  retry?: boolean;
  remote?: string;
  succeeded?: boolean;
  updatedReferenceCount?: number;
  deletedReferenceCount?: number;
  referencesTruncated?: boolean;
  referencesAvailable?: boolean;
  updatedReferences?: string[];
  deletedReferences?: string[];
}

const listeners = new Set<(event: GitExecutionEvent) => void>();
export function observeGitExecution(listener: (event: GitExecutionEvent) => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}
export function deliverGitExecution(event: GitExecutionEvent) {
  for (const listener of listeners) listener(event);
}

let preferences: () => Record<string, unknown> = () => ({});
export function configureGitExecutionPreferences(provider: () => Record<string, unknown>) { preferences = provider; }
export function gitExecutionPreferences() { return preferences(); }
