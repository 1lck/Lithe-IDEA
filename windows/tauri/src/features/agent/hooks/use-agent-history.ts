/**
 * Lithe's annotations for one project's Agent history.
 *
 * The Agent owns the sessions; this only reads and writes Lithe's own marks
 * (title override, favourite, hidden) for the workspace the window is bound to.
 * Every write re-reads the stored map first, so two windows annotating different
 * sessions of one project never overwrite each other.
 */

import { useCallback, useEffect, useMemo, useState } from "react";
import { createTranslator } from "@/i18n/locale";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import {
  markAgentHistory,
  renameAgentHistoryEntry,
} from "../services/agent-history-annotations";
import {
  readAgentHistoryMetadata,
  writeAgentHistoryMetadata,
} from "../services/agent-history-store";
import type { AgentHistoryMetadataMap } from "../types/agent-history.types";

export interface AgentHistoryAnnotationActions {
  metadata: AgentHistoryMetadataMap;
  error: string | null;
  /** False when the title is blank or the write failed. */
  rename: (sessionID: string, title: string) => Promise<boolean>;
  setFavorite: (sessionIDs: string[], favorite: boolean) => Promise<void>;
  setHidden: (sessionIDs: string[], hidden: boolean) => Promise<void>;
}

function translator() {
  return createTranslator(useSettingsStore.getState().settings.displayLanguage);
}

export function useAgentHistory(
  workspacePath: string | null,
  agentID: string,
): AgentHistoryAnnotationActions {
  const [metadata, setMetadata] = useState<AgentHistoryMetadataMap>({});
  const [error, setError] = useState<string | null>(null);
  const scope = useMemo(
    () => (workspacePath === null ? null : { workspacePath, agentID }),
    [workspacePath, agentID],
  );

  useEffect(() => {
    if (scope === null) {
      setMetadata({});
      setError(null);
      return;
    }
    let cancelled = false;
    void readAgentHistoryMetadata(scope.workspacePath, scope.agentID)
      .then((loaded) => {
        if (cancelled) return;
        setMetadata(loaded);
        setError(null);
      })
      .catch(() => {
        if (!cancelled) setError(translator()("agent.history.saveFailed"));
      });
    return () => {
      cancelled = true;
    };
  }, [scope]);

  const mutate = useCallback(
    async (change: (current: AgentHistoryMetadataMap) => AgentHistoryMetadataMap | null) => {
      if (scope === null) return false;
      try {
        const current = await readAgentHistoryMetadata(scope.workspacePath, scope.agentID);
        const next = change(current);
        if (next === null) return false;
        await writeAgentHistoryMetadata(scope.workspacePath, scope.agentID, next);
        setMetadata(next);
        setError(null);
        return true;
      } catch {
        setError(translator()("agent.history.saveFailed"));
        return false;
      }
    },
    [scope],
  );

  const rename = useCallback(
    (sessionID: string, title: string) =>
      mutate((current) => renameAgentHistoryEntry(current, sessionID, title)),
    [mutate],
  );

  const setFavorite = useCallback(
    async (sessionIDs: string[], favorite: boolean) => {
      await mutate((current) => markAgentHistory(current, sessionIDs, { isFavorite: favorite }));
    },
    [mutate],
  );

  const setHidden = useCallback(
    async (sessionIDs: string[], hidden: boolean) => {
      await mutate((current) => markAgentHistory(current, sessionIDs, { isHidden: hidden }));
    },
    [mutate],
  );

  return { metadata, error, rename, setFavorite, setHidden };
}
