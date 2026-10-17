/**
 * Lithe-owned annotations for Agent sessions.
 *
 * The Agent still owns the transcripts and the sessions it lists; Lithe records
 * only a title override, a favourite mark, and a hidden mark, scoped to one
 * workspace and one configured Agent, exactly like `AgentHistoryMetadata` on
 * macOS. A hidden session is hidden in Lithe only, so removing one here stays
 * reversible and never touches the Agent's own records.
 */

import type { AgentSessionSummary } from "./agent.types";

export interface AgentHistoryMetadata {
  title: string | null;
  isFavorite: boolean;
  isHidden: boolean;
}

export type AgentHistoryMetadataMap = Record<string, AgentHistoryMetadata>;

export const emptyAgentHistoryMetadata: AgentHistoryMetadata = {
  title: null,
  isFavorite: false,
  isHidden: false,
};

/** Which slice of Lithe's history the panel lists. */
export type AgentHistoryFilter = "all" | "favorites" | "removed";

/** One history row after the annotations and the active filter are applied. */
export interface AgentHistoryRow {
  session: AgentSessionSummary;
  title: string | null;
  isFavorite: boolean;
  isHidden: boolean;
}
