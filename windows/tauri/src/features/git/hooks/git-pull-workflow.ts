import type {
  GitOperationState,
  GitPullPreflight,
  GitPullResult,
  PullStrategy,
} from "../types/git.types";

interface RemoteActionResult {
  success: boolean;
  error?: string;
}

export interface GitPullWorkflowDependencies {
  fetch: (repoPath: string) => Promise<RemoteActionResult>;
  preflight: (repoPath: string) => Promise<GitPullPreflight>;
  pull: (repoPath: string, strategy: PullStrategy) => Promise<RemoteActionResult>;
  operationState: (repoPath: string) => Promise<GitOperationState | null>;
}

export interface GitPullWorkflowOptions {
  refresh: () => Promise<void>;
}

export interface GitPullWorkflowSnapshot {
  isPulling: boolean;
  pendingPreflight: GitPullPreflight | null;
}

const IDLE_SNAPSHOT: GitPullWorkflowSnapshot = {
  isPulling: false,
  pendingPreflight: null,
};

const errorText = (error: unknown): string | undefined => {
  const message = error instanceof Error ? error.message : String(error);
  return message.trim() || undefined;
};

/** Coordinates one safe pull path, including an explicit divergent-history choice. */
export class GitPullWorkflow {
  private snapshot: GitPullWorkflowSnapshot = IDLE_SNAPSHOT;
  private readonly listeners = new Set<() => void>();
  private resolveStrategy: ((strategy: PullStrategy | null) => void) | null = null;

  constructor(private readonly dependencies: GitPullWorkflowDependencies) {}

  readonly subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  readonly getSnapshot = () => this.snapshot;

  chooseStrategy(strategy: Exclude<PullStrategy, "ffOnly"> | null) {
    this.resolveStrategy?.(strategy);
  }

  async run(repoPath: string, options: GitPullWorkflowOptions): Promise<GitPullResult> {
    if (this.snapshot.isPulling) {
      return { status: "duplicate" };
    }

    this.update({ isPulling: true, pendingPreflight: null });
    try {
      const fetched = await this.dependencies.fetch(repoPath);
      if (!fetched.success) {
        return {
          status: "failed",
          stage: "fetch",
          error: fetched.error,
        };
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

      if (!preflight.upstream) {
        return {
          status: "blocked",
          reason: "no-upstream",
        };
      }

      if (preflight.hasLocalChanges) {
        return {
          status: "blocked",
          reason: "dirty",
        };
      }

      if (preflight.behind === 0 && !preflight.diverged) {
        return {
          status: "blocked",
          reason: "up-to-date",
        };
      }

      let strategy: PullStrategy = "ffOnly";
      if (preflight.diverged) {
        const selectedStrategy = await this.waitForStrategy(preflight);
        if (!selectedStrategy) {
          return { status: "cancelled" };
        }

        let currentPreflight: GitPullPreflight;
        try {
          currentPreflight = await this.dependencies.preflight(repoPath);
        } catch (error) {
          return {
            status: "failed",
            stage: "preflight",
            error: errorText(error),
          };
        }

        if (currentPreflight.hasLocalChanges) {
          return {
            status: "blocked",
            reason: "dirty",
          };
        }

        if (
          currentPreflight.upstream !== preflight.upstream ||
          currentPreflight.ahead !== preflight.ahead ||
          currentPreflight.behind !== preflight.behind ||
          currentPreflight.diverged !== preflight.diverged
        ) {
          return {
            status: "blocked",
            reason: "state-changed",
          };
        }
        strategy = selectedStrategy;
      }

      const pulled = await this.dependencies.pull(repoPath, strategy);
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
      this.resolveStrategy = null;
      try {
        await options.refresh();
      } catch (refreshError) {
        console.error("Failed to refresh Git data after pull:", refreshError);
      }
      this.update(IDLE_SNAPSHOT);
    }
  }

  private waitForStrategy(preflight: GitPullPreflight): Promise<"merge" | "rebase" | null> {
    return new Promise((resolve) => {
      this.resolveStrategy = (strategy) => {
        this.resolveStrategy = null;
        this.update({ isPulling: true, pendingPreflight: null });
        resolve(strategy === "merge" || strategy === "rebase" ? strategy : null);
      };
      this.update({ isPulling: true, pendingPreflight: preflight });
    });
  }

  private update(snapshot: GitPullWorkflowSnapshot) {
    this.snapshot = snapshot;
    for (const listener of this.listeners) listener();
  }
}
