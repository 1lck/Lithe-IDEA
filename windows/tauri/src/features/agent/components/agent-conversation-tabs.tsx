import { useTranslation } from "@/i18n/locale-provider";
import { PlusIcon, XIcon } from "@/ui/icons";
import { Spinner } from "@/ui/spinner";
import { cn } from "@/utils/cn";

export interface AgentConversationTab {
  id: string;
  title: string;
  isSelected: boolean;
  isBusy: boolean;
  needsAttention: boolean;
}

interface AgentConversationTabsProps {
  tabs: AgentConversationTab[];
  /** The new conversation being prepared, shown selected until it exists. */
  showsNewTab: boolean;
  isNewTabBusy: boolean;
  newTabTitle: string | null;
  onSelect: (sessionID: string) => void;
  onClose: (sessionID: string) => void;
  onNew: () => void;
}

/**
 * One tab per open conversation and a "new" button, as `AgentSessionTabStrip`
 * on macOS: busy tabs spin, a tab waiting for permission shows a dot, and the
 * close button appears on hover or on the selected tab.
 */
export function AgentConversationTabs({
  tabs,
  showsNewTab,
  isNewTabBusy,
  newTabTitle,
  onSelect,
  onClose,
  onNew,
}: AgentConversationTabsProps) {
  const { t } = useTranslation();

  return (
    <div className="flex h-8 shrink-0 items-center gap-1 bg-surface px-2">
      <div
        role="tablist"
        aria-label={t("agent.actions.tabs")}
        className="flex min-w-0 flex-1 gap-0.5 overflow-x-auto [scrollbar-width:none]"
      >
        {tabs.map((tab) => (
          <Tab
            key={tab.id}
            title={tab.title}
            isSelected={tab.isSelected}
            isBusy={tab.isBusy}
            needsAttention={tab.needsAttention}
            onSelect={() => onSelect(tab.id)}
            onClose={() => onClose(tab.id)}
          />
        ))}
        {showsNewTab ? (
          <Tab
            title={newTabTitle ?? t("agent.actions.newConversation")}
            isSelected
            isBusy={isNewTabBusy}
            needsAttention={false}
            onSelect={() => undefined}
            onClose={null}
          />
        ) : null}
      </div>
      <button
        type="button"
        aria-label={t("agent.actions.newConversation")}
        title={t("agent.actions.newConversation")}
        disabled={showsNewTab}
        className="flex size-6 shrink-0 items-center justify-center rounded text-subtle-foreground hover:bg-accent hover:text-foreground disabled:opacity-40"
        onClick={onNew}
      >
        <PlusIcon className="size-3" />
      </button>
    </div>
  );
}

function Tab({
  title,
  isSelected,
  isBusy,
  needsAttention,
  onSelect,
  onClose,
}: {
  title: string;
  isSelected: boolean;
  isBusy: boolean;
  needsAttention: boolean;
  onSelect: () => void;
  onClose: (() => void) | null;
}) {
  const { t } = useTranslation();
  return (
    <span
      className={cn(
        "group flex shrink-0 items-center gap-[5px] rounded px-2 py-[5px] ui-text-sm",
        isSelected
          ? "bg-selected font-medium text-foreground"
          : "text-subtle-foreground hover:bg-accent",
      )}
    >
      {isBusy ? (
        <Spinner className="size-3" />
      ) : needsAttention ? (
        <span aria-hidden className="size-1.5 rounded-full bg-warning" />
      ) : null}
      <button
        type="button"
        role="tab"
        aria-selected={isSelected}
        className="max-w-[140px] truncate"
        onClick={onSelect}
      >
        {title}
      </button>
      {onClose === null ? null : (
        <button
          type="button"
          aria-label={t("agent.tabs.close")}
          title={t("agent.tabs.close")}
          className={cn(
            "flex size-3.5 items-center justify-center text-subtle-foreground hover:text-foreground",
            isSelected ? "" : "invisible group-hover:visible group-focus-within:visible",
          )}
          onClick={onClose}
        >
          <XIcon className="size-2.5" />
        </button>
      )}
    </span>
  );
}
