import { invoke } from "@/platform/tauri-core";

/** How a test process ended, as the host observed it. */
export type TestRunTermination =
  | { kind: "exited"; exitCode: number }
  | { kind: "timedOut" }
  | { kind: "cancelled" };

/** The breadth the host asked to run; Core never reads selector syntax. */
export type TestRunScope = "workspace" | "project" | "suite" | "case";

export interface TestRunSummary {
  total: number;
  passed: number;
  failed: number;
  errors: number;
  skipped: number;
}

export type TestRunOutcome =
  | "passed"
  | "testsFailed"
  | "exitedWithError"
  | "noTestsMatched"
  | "noTestsFound"
  | "timedOut"
  | "cancelled";

export interface TestRunVerdict {
  outcome: TestRunOutcome;
  success: boolean;
  exitCode: number | null;
}

/**
 * Reduces a finished test run to the tool-neutral verdict macOS shows too
 * (`build.resolveTestRunOutcome`). `summary` is null when the run produced no
 * structured results.
 */
export function resolveTestRunOutcome(request: {
  termination: TestRunTermination;
  scope: TestRunScope;
  summary: TestRunSummary | null;
}): Promise<TestRunVerdict> {
  return invoke<TestRunVerdict>("build.resolveTestRunOutcome", request);
}
