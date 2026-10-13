import { useCallback, useMemo, useSyncExternalStore } from "react";
import { getGitPullWorkflow } from "../api/git-remotes-api";
import { showGitPullDialog, type GitPullDialogResult } from "../services/git-pull-dialog-service";

interface UseGitPullWorkflowOptions {
  repoPath: string;
  refresh: () => Promise<void>;
}

export function useGitPullWorkflow({ repoPath, refresh }: UseGitPullWorkflowOptions) {
  const workflow = useMemo(() => getGitPullWorkflow(repoPath), [repoPath]);
  const snapshot = useSyncExternalStore(
    workflow.subscribe,
    workflow.getSnapshot,
    workflow.getSnapshot,
  );

  // Pull always opens the shared dialog; the dialog host runs the workflow with
  // the confirmed branch and strategy, and reports the result to the user.
  const pull = useCallback(
    (): Promise<GitPullDialogResult> => showGitPullDialog(repoPath, { refresh }),
    [refresh, repoPath],
  );

  return {
    ...snapshot,
    pull,
  };
}
