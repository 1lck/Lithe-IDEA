import { useCallback, useEffect, useState } from "react";
import { getGitHistory } from "../api/git-commits-api";
import type { GitCommit } from "../types/git.types";

type PickerStatus = "idle" | "loading" | "ready" | "failed";
interface PickerState {
  identity: string;
  status: PickerStatus;
  commits: GitCommit[];
}

/** Owns the picker snapshot; closed, replaced and unmounted requests cannot publish. */
export function useGitCommitPicker(repoPath: string | null, workspaceId: string, open: boolean) {
  const [attempt, setAttempt] = useState(0);
  const identity = JSON.stringify([workspaceId, repoPath, open, attempt]);
  const [state, setState] = useState<PickerState>({ identity: "", status: "idle", commits: [] });
  const retry = useCallback(() => setAttempt((value) => value + 1), []);

  useEffect(() => {
    if (!open || !repoPath) return;
    let active = true;
    setState({ identity, status: "loading", commits: [] });
    void getGitHistory(repoPath, 50).then(
      (history) => {
        if (active)
          setState({
            identity,
            status: history ? "ready" : "failed",
            commits: history?.commits ?? [],
          });
      },
      () => {
        if (active) setState({ identity, status: "failed", commits: [] });
      },
    );
    return () => {
      active = false;
    };
  }, [identity, repoPath, open]);

  // Do not render a previous repository's results before the effect resets them.
  return {
    status:
      state.identity === identity
        ? state.status
        : open && repoPath
          ? ("loading" as const)
          : ("idle" as const),
    commits: state.identity === identity ? state.commits : [],
    retry,
  };
}
