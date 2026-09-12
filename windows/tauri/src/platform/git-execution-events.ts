/** Native diagnostics only; command input and environment are never included. */
export interface GitExecutionEvent {
  operationId: string;
  type: "requestStarted" | "started" | "output" | "finished" | "requestFinished";
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
}

const listeners = new Set<(event: GitExecutionEvent) => void>();
export function observeGitExecution(listener: (event: GitExecutionEvent) => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}
export function deliverGitExecution(event: GitExecutionEvent) {
  for (const listener of listeners) listener(event);
}
