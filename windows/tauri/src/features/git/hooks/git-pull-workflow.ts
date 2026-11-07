import type { GitUpdateBlocker, GitUpdatePlan } from "../api/git-update-plan-api";
import type {
  GitOperationState,
  GitPullPreflight,
  GitPullResult,
  GitReference,
  PullStrategy,
} from "../types/git.types";

interface RemoteActionResult {
  success: boolean;
  error?: string;
}

export interface GitPullWorkflowDependencies {
  fetch: (repoPath: string) => Promise<RemoteActionResult>;
  preflight: (repoPath: string) => Promise<GitPullPreflight>;
  /** Pulls the configured upstream, or the explicit `reference` when the Pull dialog chose another branch. */
  pull: (
    repoPath: string,
    strategy: PullStrategy,
    reference?: GitReference,
    expectedBranch?: string,
  ) => Promise<RemoteActionResult>;
  operationState: (repoPath: string) => Promise<GitOperationState | null>;
  /** Core's `git.updatePlan` inspection of the preflight (the only pull gate). */
  plan: (input: {
    preflight: GitPullPreflight;
    interactive: boolean;
    explicitSource: boolean;
    strategy?: PullStrategy;
  }) => Promise<GitUpdatePlan>;
}

export interface GitPullWorkflowOptions {
  refresh: () => Promise<void>;
  /** Strategy the user confirmed in the Pull dialog; Core resolves it otherwise. */
  strategy?: PullStrategy;
  /** Remote branch to pull into the current branch instead of the configured upstream. */
  reference?: GitReference;
  /**
   * The user can be asked to choose a strategy for a diverged history. A
   * non-interactive run (another worktree) refuses it instead.
   */
  interactive?: boolean;
  /** Complete local ref selected by a background update, not a new Pull source. */
  expectedBranch?: string;
  /** Revalidate that the worktree still has the selected branch checked out. */
  validateBranch?: () => Promise<boolean>;
}

export interface GitPullWorkflowSnapshot {
  isPulling: boolean;
  isPullLocked: boolean;
}

const IDLE_SNAPSHOT: GitPullWorkflowSnapshot = {
  isPulling: false,
  isPullLocked: false,
};

const REFRESHING_SNAPSHOT: GitPullWorkflowSnapshot = {
  isPulling: false,
  isPullLocked: true,
};

const blockedResult = (blocker: GitUpdateBlocker): GitPullResult => {
  switch (blocker) {
    case "noUpstream":
      return { status: "blocked", reason: "no-upstream" };
    case "localChanges":
      return { status: "blocked", reason: "dirty" };
    case "upToDate":
      return { status: "blocked", reason: "up-to-date" };
    case "stateChanged":
      return { status: "blocked", reason: "state-changed" };
    case "notFastForward":
      return {
        status: "failed",
        stage: "pull",
        error: "The selected branch cannot be fast-forwarded",
      };
  }
};

const errorText = (error: unknown): string | undefined => {
  const message = error instanceof Error ? error.message : String(error);
  return message.trim() || undefined;
};

/** Runs one pull: hosts fetch and inspect, Core decides, and this executes the returned step. */
export class GitPullWorkflow {
  private snapshot: GitPullWorkflowSnapshot = IDLE_SNAPSHOT;
  private readonly listeners = new Set<() => void>();

  constructor(private readonly dependencies: GitPullWorkflowDependencies) {}

  readonly subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  readonly getSnapshot = () => this.snapshot;

  async run(repoPath: string, options: GitPullWorkflowOptions): Promise<GitPullResult> {
    if (this.snapshot.isPullLocked) {
      return { status: "duplicate" };
    }

    this.update({ isPulling: true, isPullLocked: true });
    try {
      const fetched = await this.dependencies.fetch(repoPath);
      if (!fetched.success) {
        return {
          status: "failed",
          stage: "fetch",
          error: fetched.error,
        };
      }

      if (options.validateBranch && !(await options.validateBranch())) {
        return { status: "blocked", reason: "state-changed" };
      }

      let preflight: GitPullPreflight;
      try {
        preflight = await this.dependencies.preflight(repoPath);
      } catch (error) {
        return {
          status: "failed",
          stage: "preflight",
          error: errorText(error),
        };
      }

      // Core owns every gate: upstream, local changes, "up to date", and the
      // strategy default. A dialog-selected branch is pulled explicitly, so the
      // current branch's upstream does not gate it.
      let decision: GitUpdatePlan;
      try {
        decision = await this.dependencies.plan({
          preflight,
          interactive: options.interactive ?? true,
          explicitSource: !!options.reference,
          strategy: options.strategy,
        });
      } catch (error) {
        return { status: "failed", stage: "preflight", error: errorText(error) };
      }
      if (decision.step === "blocked") return blockedResult(decision.blocker);
      if (decision.step === "chooseStrategy") return { status: "needs-strategy" };
      if (decision.step !== "pull") {
        return { status: "failed", stage: "preflight", error: "Invalid Git update plan" };
      }
      const strategy = decision.strategy;

      if (options.validateBranch && !(await options.validateBranch())) {
        return { status: "blocked", reason: "state-changed" };
      }
      const pulled = await this.dependencies.pull(repoPath, strategy, options.reference, options.expectedBranch);
      if (pulled.success) {
        return { status: "pulled", strategy };
      }

      try {
        const operation = await this.dependencies.operationState(repoPath);
        if (operation?.kind === "merge" || operation?.kind === "rebase") {
          return {
            status: "conflict",
            operation,
          };
        }
      } catch (stateError) {
        console.error("Failed to inspect Git operation state after pull failed:", stateError);
      }

      return {
        status: "failed",
        stage: "pull",
        error: pulled.error,
      };
    } finally {
      // Keep duplicate Pull attempts blocked while allowing unrelated Git
      // actions after the command and conflict inspection have completed.
      this.update(REFRESHING_SNAPSHOT);
      try {
        await options.refresh();
      } catch (refreshError) {
        console.error("Failed to refresh Git data after pull:", refreshError);
      } finally {
        this.update(IDLE_SNAPSHOT);
      }
    }
  }

  private update(snapshot: GitPullWorkflowSnapshot) {
    this.snapshot = snapshot;
    for (const listener of this.listeners) listener();
  }
}
