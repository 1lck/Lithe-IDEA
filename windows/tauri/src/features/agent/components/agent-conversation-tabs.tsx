import { useTranslation } from "@/i18n/locale-provider";
import { XIcon } from "@/ui/icons";
import { cn } from "@/utils/cn";
import type { AgentSessionSummary } from "../types/agent.types";

interface AgentConversationTabsProps {
  openSessionIDs: string[];
  sessions: AgentSessionSummary[];
  selectedSessionID: string | null;
  titles: Record<string, string | null>;
  onSelect: (sessionID: string) => void;
  onClose: (sessionID: string) => void;
}

/** Open conversations, mirroring the macOS session tabs above the transcript. */
export function AgentConversationTabs({
  openSessionIDs,
  sessions,
  selectedSessionID,
  titles,
  onSelect,
  onClose,
}: AgentConversationTabsProps) {
  const { t } = useTranslation();
  if (openSessionIDs.length === 0) return null;

  return (
    <div
      role="tablist"
      aria-label={t("agent.tabs.label")}
      className="flex gap-1 overflow-x-auto border-border/70 border-b px-1.5 py-1"
    >
      {openSessionIDs.map((sessionID) => {
        const summary = sessions.find((session) => session.id === sessionID);
        const title = titles[sessionID] ?? summary?.title ?? t("agent.tabs.untitled");
        const isSelected = sessionID === selectedSessionID;
        return (
          <span
            key={sessionID}
            className={cn(
              "flex max-w-48 shrink-0 items-center gap-1 rounded-md px-1.5 py-0.5 ui-text-sm",
              isSelected ? "bg-selected text-foreground" : "text-subtle-foreground hover:bg-accent",
            )}
          >
            <button
              type="button"
              role="tab"
              aria-selected={isSelected}
              className="max-w-40 truncate"
              onClick={() => onSelect(sessionID)}
            >
              {title}
            </button>
            <button
              type="button"
              aria-label={t("agent.tabs.close", { title })}
              className="shrink-0 opacity-70 hover:opacity-100"
              onClick={() => onClose(sessionID)}
            >
              <XIcon className="size-3" />
            </button>
          </span>
        );
      })}
    </div>
  );
}
