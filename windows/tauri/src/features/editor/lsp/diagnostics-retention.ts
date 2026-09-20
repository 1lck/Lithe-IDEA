/**
 * What to do with one published diagnostic set for a workspace file.
 *
 * `store` keeps the diagnostics, `clear` removes an entry that a clean rebuild
 * just emptied, and `ignore` drops the notification without touching the store.
 */
export type WorkspaceDiagnosticsDecision = "store" | "clear" | "ignore";

export interface WorkspaceDiagnosticsInput {
  /** The file is open in the editor, so its markers are never bounded. */
  isDocumentOpen: boolean;
  /** Number of diagnostics in this notification; zero means the file is clean. */
  diagnosticCount: number;
  /** The file already has stored diagnostics from an earlier notification. */
  isTracked: boolean;
  /** How many unopened files currently carry diagnostics. */
  trackedFileCount: number;
  /** Upper bound on `trackedFileCount`. */
  maxTrackedFiles: number;
}

/**
 * Decides how a published diagnostic set for an unopened workspace file is
 * applied.
 *
 * A language server publishes an empty set to retract a file's markers. Storing
 * that empty set would leave one row per clean file, so a retraction either
 * clears a tracked entry or is ignored outright. New files stop being accepted
 * at the bound, while files already tracked keep updating so their markers
 * cannot get stuck at a stale value.
 */
export function decideWorkspaceDiagnostics({
  isDocumentOpen,
  diagnosticCount,
  isTracked,
  trackedFileCount,
  maxTrackedFiles,
}: WorkspaceDiagnosticsInput): WorkspaceDiagnosticsDecision {
  if (isDocumentOpen) return "store";
  if (diagnosticCount === 0) return isTracked ? "clear" : "ignore";
  if (!isTracked && trackedFileCount >= maxTrackedFiles) return "ignore";
  return "store";
}
