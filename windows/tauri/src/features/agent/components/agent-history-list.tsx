import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { ArrowClockwiseIcon } from "@/ui/icons";
import { Spinner } from "@/ui/spinner";
import type { AgentSessionSummary } from "../types/agent.types";

interface AgentHistoryListProps {
  sessions: AgentSessionSummary[];
  isRefreshing: boolean;
  error: string | null;
  canRefresh: boolean;
  onRefresh: () => void;
  onSelect: (sessionID: string) => void;
}

/**
 * Sessions the agent keeps for this workspace. The header is the panel's own
 * history list; copying ids, renaming, and export arrive with the history page.
 */
export function AgentHistoryList({
  sessions,
  isRefreshing,
  error,
  canRefresh,
  onRefresh,
  onSelect,
}: AgentHistoryListProps) {
  const { t } = useTranslation();

  return (
    <div className="border-border/70 border-b">
      <div className="flex items-center justify-between gap-2 px-2 py-1">
        <span className="text-subtle-foreground ui-text-caption">
          {t("agent.history.title", { count: sessions.length })}
        </span>
        <Button
          type="button"
          size="icon-xs"
          variant="ghost"
          disabled={!canRefresh || isRefreshing}
          tooltip={t("agent.history.refresh")}
          aria-label={t("agent.history.refresh")}
          onClick={onRefresh}
        >
          {isRefreshing ? <Spinner className="size-3" /> : <ArrowClockwiseIcon className="size-3" />}
        </Button>
      </div>
      {sessions.length === 0 ? (
        <div className="px-2 pb-1.5 text-subtle-foreground ui-text-caption">
          {t("agent.history.empty")}
        </div>
      ) : (
        <div className="max-h-40 overflow-auto pb-1">
          {sessions.map((session) => (
            <button
              key={session.id}
              type="button"
              className="flex w-full flex-col px-2 py-1 text-left hover:bg-accent"
              onClick={() => onSelect(session.id)}
            >
              <span className="truncate text-foreground ui-text-sm">
                {session.title ?? t("agent.tabs.untitled")}
              </span>
              <span className="truncate text-subtle-foreground ui-text-caption">
                {session.updatedAt ?? session.id}
              </span>
            </button>
          ))}
        </div>
      )}
      {error === null ? null : <div className="px-2 pb-1.5 text-warning ui-text-caption">{error}</div>}
    </div>
  );
}
