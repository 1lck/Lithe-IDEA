/**
 * Lithe's history annotations, as pure data.
 *
 * Kept apart from `agent-history-store.ts` so the reduction stays importable
 * without a Tauri runtime: the store module is the only place that touches the
 * platform store, and the tests here never load it.
 */

import {
  emptyAgentHistoryMetadata,
  type AgentHistoryMetadataMap,
} from "../types/agent-history.types";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/**
 * Scope key for one workspace and one Agent.
 *
 * Windows paths are case-insensitive but not case-preserving, so separators are
 * normalised and the trailing separator dropped. `|` cannot appear in a Windows
 * path, so the two halves stay unambiguous.
 */
export function agentHistoryKey(workspacePath: string, agentID: string): string {
  const normalized = workspacePath.replace(/\\/g, "/").replace(/\/+$/, "");
  return `${agentID.trim()}|${normalized}`;
}

/** Read annotations, dropping anything that is not the documented shape. */
export function parseAgentHistoryMetadata(value: unknown): AgentHistoryMetadataMap {
  if (!isRecord(value)) return {};
  const parsed: AgentHistoryMetadataMap = {};
  for (const [sessionID, entry] of Object.entries(value)) {
    if (!isRecord(entry)) continue;
    const title = typeof entry.title === "string" ? entry.title.trim() : "";
    parsed[sessionID] = {
      title: title.length > 0 ? title : null,
      isFavorite: entry.isFavorite === true,
      isHidden: entry.isHidden === true,
    };
  }
  return parsed;
}

/** Record a title override, or reject a blank one the way the field does. */
export function renameAgentHistoryEntry(
  metadata: AgentHistoryMetadataMap,
  sessionID: string,
  title: string,
): AgentHistoryMetadataMap | null {
  const trimmed = title.trim();
  if (trimmed.length === 0) return null;
  return {
    ...metadata,
    [sessionID]: { ...(metadata[sessionID] ?? emptyAgentHistoryMetadata), title: trimmed },
  };
}

/** Flip the marks on the given sessions; untouched sessions keep their entry. */
export function markAgentHistory(
  metadata: AgentHistoryMetadataMap,
  sessionIDs: string[],
  change: { isFavorite?: boolean; isHidden?: boolean },
): AgentHistoryMetadataMap {
  const next = { ...metadata };
  for (const sessionID of sessionIDs) {
    next[sessionID] = { ...(next[sessionID] ?? emptyAgentHistoryMetadata), ...change };
  }
  return next;
}
