import { useCallback, useMemo, useSyncExternalStore } from "react";
import { toast } from "sonner";
import { useTranslation } from "@/i18n/locale-provider";
import { getGitPullWorkflow } from "../api/git-remotes-api";
import { emitGitChanged } from "../events/git-events";
import type { GitPullResult } from "../types/git.types";
import { getGitPullResultPresentation } from "../utils/git-pull-result-presentation";

interface UseGitPullWorkflowOptions {
  repoPath: string;
  refresh: () => Promise<void>;
}

const reportResult = (
  result: GitPullResult,
  translate: (key: string, values?: Record<string, string | number>) => string,
) => {
  const presentation = getGitPullResultPresentation(result, translate);
  if (!presentation) return;
  toast[presentation.tone](presentation.message);
};

export function useGitPullWorkflow({ repoPath, refresh }: UseGitPullWorkflowOptions) {
  const { t } = useTranslation();
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
    reportResult(result, t);
    return result;
  }, [refresh, repoPath, t, workflow]);

  return {
    ...snapshot,
    pull,
  };
}
