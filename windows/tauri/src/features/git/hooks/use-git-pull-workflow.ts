import { useCallback, useMemo, useSyncExternalStore } from "react";
import { toast } from "sonner";
import { getGitPullWorkflow } from "../api/git-remotes-api";
import { emitGitChanged } from "../events/git-events";
import type { GitPullResult } from "../types/git.types";

interface UseGitPullWorkflowOptions {
  repoPath: string;
  refresh: () => Promise<void>;
}

const reportResult = (result: GitPullResult) => {
  if (result.status === "duplicate" || result.status === "cancelled") return;
  if (result.status === "pulled") {
    toast.success(result.message);
  } else if (result.status === "conflict") {
    toast.warning(result.message);
  } else if (result.status === "blocked") {
    if (result.reason === "up-to-date") toast.info(result.message);
    else toast.warning(result.message);
  } else {
    toast.error(result.message);
  }
};

export function useGitPullWorkflow({ repoPath, refresh }: UseGitPullWorkflowOptions) {
  const workflow = useMemo(() => getGitPullWorkflow(repoPath), [repoPath]);
  const snapshot = useSyncExternalStore(
    workflow.subscribe,
    workflow.getSnapshot,
    workflow.getSnapshot,
  );

  const pull = useCallback(async () => {
    const result = await workflow.run(repoPath, {
      refresh: async () => {
        // Invalidate read caches before the owning controller re-reads every
        // Pull-related surface, including after a rejected or cancelled attempt.
        emitGitChanged({
          repoPath,
          scopes: ["working-tree", "history", "refs", "remotes"],
          source: "pull-finished",
        });
        await refresh();
      },
    });
    reportResult(result);
    return result;
  }, [refresh, repoPath, workflow]);

  return {
    ...snapshot,
    pull,
  };
}
