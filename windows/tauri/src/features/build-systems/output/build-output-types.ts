/**
 * Shapes the build output panel consumes. Diagnostics and test results mirror
 * the JSON that `build.decodeDiagnostics` and `build.decodeTestResults` in
 * Rust Core produce (camelCase, one-based lines and columns, workspace-
 * relative paths with `/` separators); the panel renders them and never
 * reparses build output itself. Output chunks, the ordered terminal state,
 * and cancellation arrive through an injected `BuildOutputPort` owned by the
 * build run coordinator, so this feature creates no IPC and no processes.
 */

/** One diagnostic as decoded by Core (`build.decodeDiagnostics`). */
export interface BuildDiagnostic {
  /** Workspace-relative path with `/` separators, never absolute. */
  path: string;
  /** One-based line. */
  line: number;
  /** One-based column, absent when the tool did not report one. */
  column?: number;
  severity: "error" | "warning" | "information" | "hint";
  message: string;
}

/** Aggregated outcome of one test case as decoded by Core. */
export interface BuildTestCase {
  suite: string;
  case: string;
  status: "passed" | "failed" | "error" | "skipped";
  message?: string;
  durationMillis?: number;
  /** Workspace-relative source file, when the report named one. */
  path?: string;
  /** One-based line, when the report named one. */
  line?: number;
  /** Invocations aggregated into this case. */
  invocations: number;
}

/** Counts of one decoded test run; `failed` and `errors` are separate. */
export interface BuildTestSummary {
  total: number;
  passed: number;
  failed: number;
  errors: number;
  skipped: number;
}

/** Envelope of `build.decodeTestResults`. */
export interface BuildTestResults {
  tests: BuildTestCase[];
  summary: BuildTestSummary;
  success: boolean;
}

/** Ordered final state of one run; exactly one terminal applies per operation. */
export interface BuildRunTerminal {
  kind: "succeeded" | "failed" | "cancelled" | "failedToStart";
  /** Process exit code when a process ran, else null/absent. */
  exitCode?: number | null;
  /** Failure or cancellation reason, when the owner reported one. */
  message?: string | null;
}

/**
 * Identity of one build run, captured when the coordinator starts it. Every
 * later event repeats the full reference (operation, plugin, build system,
 * instance, workspace and generation), so an earlier operation or another
 * workspace can never pollute a new one. `generation` is the build registry
 * generation the run started under; a newer generation invalidates the
 * session because the plugin set that produced it changed.
 */
export interface BuildOperationIdentity {
  operationId: string;
  pluginId: string;
  buildSystemId: string;
  /** Workspace-relative instance root. */
  root: string;
  /** Absolute workspace root the run belongs to. */
  workspaceRoot: string;
  /** Build registry generation at run start. */
  generation: number;
  /** Human-readable run title, e.g. `cargo build`. */
  title: string;
}

/** Full routing identity every event repeats; display titles are not keys. */
export type BuildOutputEventRef = Omit<BuildOperationIdentity, "title">;

/** Events one running operation streams to a subscribed sink. */
export type BuildOutputEvent =
  | ({ type: "chunk"; stream: "stdout" | "stderr"; text: string } & BuildOutputEventRef)
  | ({ type: "diagnostics"; diagnostics: BuildDiagnostic[] } & BuildOutputEventRef)
  | ({ type: "testResults"; results: BuildTestResults } & BuildOutputEventRef)
  | ({ type: "terminal"; terminal: BuildRunTerminal } & BuildOutputEventRef);

/**
 * Host adapter the coordinator injects. `subscribe` streams the events of one
 * operation until the returned unsubscriber is called (including late async
 * acquisition). The port is scoped to its owning product window; it must
 * never route cancellation to another window. Operation IDs are single-use.
 * `cancel` resolves when the request is accepted, NOT when the process stops.
 * Only an ordered terminal event confirms termination. Diagnostics/results
 * must already be decoded by Core, never parsed by this presentation port.
 * A production coordinator must invalidate sessions on registry-generation
 * changes and stream all events in arrival order. No default native port is
 * provided here.
 */
export interface BuildOutputPort {
  subscribe(
    identity: BuildOperationIdentity,
    sink: (event: BuildOutputEvent) => void,
  ): (() => void) | Promise<() => void>;
  cancel(identity: BuildOperationIdentity): Promise<void>;
}

/** Session id of one plugin build-system instance's output area. */
export function buildOutputSessionId(pluginId: string, buildSystemId: string, root: string) {
  return `build-output:${JSON.stringify([pluginId, buildSystemId, root])}`;
}
