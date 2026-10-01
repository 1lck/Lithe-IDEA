/**
 * Ordering and filtering for the history list.
 *
 * This mirrors macOS `AgentHistoryPresentation`: the same filter semantics, the
 * same title override, and the same newest-first order with a session id
 * tie-break, so both platforms list one project's history the same way.
 */

import type { AgentConversation, AgentSessionSummary } from "../types/agent.types";
import {
  emptyAgentHistoryMetadata,
  type AgentHistoryFilter,
  type AgentHistoryMetadataMap,
  type AgentHistoryRow,
} from "../types/agent-history.types";

/** ISO-8601 internet date-time, with or without fractional seconds. */
const INTERNET_DATE_TIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;

/**
 * Milliseconds for an Agent timestamp, or `null` when the value is not the
 * documented ISO-8601 form. A date-only string is rejected rather than guessed,
 * because it would silently reorder the list.
 */
export function historyDate(value: string | null): number | null {
  if (value === null || !INTERNET_DATE_TIME.test(value)) return null;
  const parsed = Date.parse(value);
  return Number.isNaN(parsed) ? null : parsed;
}

/** The title Lithe shows: its own override first, the Agent's own title next. */
export function historyTitle(
  session: AgentSessionSummary,
  metadata: AgentHistoryMetadataMap,
): string | null {
  return metadata[session.id]?.title ?? session.title;
}

/**
 * The rows the active filter shows, searched and ordered.
 *
 * `all` and `favorites` exclude removed sessions, `removed` shows only those,
 * and the search matches the shown title or the session id. Updated time
 * decides the order, and sessions without a usable timestamp sort last.
 */
export function agentHistoryRows(
  sessions: AgentSessionSummary[],
  metadata: AgentHistoryMetadataMap,
  query: string,
  filter: AgentHistoryFilter,
): AgentHistoryRow[] {
  const needle = query.trim().toLowerCase();
  return sessions
    .flatMap((session) => {
      const entry = metadata[session.id] ?? emptyAgentHistoryMetadata;
      if (entry.isHidden !== (filter === "removed")) return [];
      if (filter === "favorites" && !entry.isFavorite) return [];
      const title = entry.title ?? session.title;
      if (needle.length > 0) {
        const haystack = title ?? "";
        if (
          !haystack.toLowerCase().includes(needle) &&
          !session.id.toLowerCase().includes(needle)
        ) {
          return [];
        }
      }
      return [{ row: { session, title, isFavorite: entry.isFavorite, isHidden: entry.isHidden },
        date: historyDate(session.updatedAt) }];
    })
    .sort((lhs, rhs) => {
      if (lhs.date !== rhs.date) {
        return (rhs.date ?? Number.NEGATIVE_INFINITY) - (lhs.date ?? Number.NEGATIVE_INFINITY);
      }
      return lhs.row.session.id.localeCompare(rhs.row.session.id);
    })
    .map((entry) => entry.row);
}

/**
 * Turns of one loaded conversation, or `null` while it is unknown. Tool
 * messages are not turns, so they are not counted.
 */
export function historyMessageCount(conversation: AgentConversation | null): number | null {
  if (conversation === null || conversation.isLoading) return null;
  if (!conversation.isAttached && conversation.messages.length === 0) return null;
  return conversation.messages.filter((message) => message.role !== "tool").length;
}
