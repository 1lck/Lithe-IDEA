import { useEffect, useState } from "react";
import { frontendTrace } from "@/utils/frontend-trace";
import { cancelGitHistoryOperation } from "../api/git-commits-api";
import { getGitHistoryActionCapabilities, type GitHistoryActionCapabilities } from "../api/git-history-rewrite-api";
import { isGitChangeRelevant, subscribeToGitChanges } from "../events/git-events";

export interface GitHistoryActionRequest {
  owner: string;
  root: string;
  session: string;
  revisions: string[];
}

export function historyActionKey(root: string, revisions: readonly string[]): string {
  return JSON.stringify([root, [...revisions].sort()]);
}

/** Only inspect an open menu; cancellation and the key reject late results. */
export function useGitHistoryActionCapabilities(root: string | null, request: GitHistoryActionRequest | null) {
  const key = root && request && root === request.root ? JSON.stringify([historyActionKey(root, request.revisions), request.session]) : null;
  const [result, setResult] = useState<{ key: string; value: GitHistoryActionCapabilities } | null>(null);
  const [generation, setGeneration] = useState(0);

  useEffect(() => subscribeToGitChanges((change) => {
    if (root && isGitChangeRelevant(change, root) && (!change.scopes || change.scopes.some((scope) => scope === "history" || scope === "refs" || scope === "repository"))) {
      setResult(null);
      setGeneration((value) => value + 1);
    }
  }), [root]);

  useEffect(() => {
    if (!root || !request || !key) return;
    let active = true;
    let pending = true;
    const operationId = crypto.randomUUID();
    setResult(null);
    void getGitHistoryActionCapabilities(root, request.revisions, operationId).then((value) => {
      pending = false;
      if (active) setResult({key, value});
    }, () => {
      pending = false;
      if (active) frontendTrace("warn", "git.history", "Could not inspect history action eligibility");
    });
    return () => { active = false; if (pending) void cancelGitHistoryOperation(operationId); };
  }, [root, key, generation]);

  return result?.key === key ? result.value : null;
}
