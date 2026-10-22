import { useMemo, useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { Checkbox } from "@/ui/checkbox";
import { showConfirmDialog, showPromptDialog } from "@/ui/dialog";
import {
  ArrowClockwiseIcon,
  ArrowCounterClockwiseIcon,
  CheckIcon,
  CopyIcon,
  DownloadSimpleIcon,
  PencilSimpleIcon,
  StarIcon,
  TrashIcon,
} from "@/ui/icons";
import { NativeSelect, NativeSelectOption } from "@/ui/native-select";
import { SearchField } from "@/ui/search";
import { Spinner } from "@/ui/spinner";
import { tryWriteClipboardText } from "@/utils/clipboard";
import { cn } from "@/utils/cn";
import { agentHistoryRows, historyMessageCount } from "../services/agent-history-view";
import type { AgentConversation, AgentSessionSummary } from "../types/agent.types";
import type { AgentHistoryFilter, AgentHistoryMetadataMap } from "../types/agent-history.types";

interface AgentHistoryListProps {
  sessions: AgentSessionSummary[];
  /** Lithe's own annotations for this workspace and Agent. */
  metadata: AgentHistoryMetadataMap;
  /** Loaded transcripts, used only to count the turns a row already shows. */
  conversations: Record<string, AgentConversation>;
  isRefreshing: boolean;
  error: string | null;
  canRefresh: boolean;
  onRefresh: () => void;
  onSelect: (sessionID: string) => void;
  onRename: (sessionID: string, title: string) => Promise<boolean>;
  onSetFavorite: (sessionIDs: string[], favorite: boolean) => void;
  onSetHidden: (sessionIDs: string[], hidden: boolean) => void;
  isExporting: boolean;
  onExport: (sessionIDs: string[]) => void;
  canExportSession: (sessionID: string) => boolean;
}

/**
 * Sessions the Agent keeps for this workspace, with Lithe's own annotations.
 *
 * The Agent owns the records; the title override, the favourite mark, and the
 * hidden mark are Lithe's, scoped to this project and Agent, and stay reversible
 * from the removed filter. Selecting only ever acts on the visible rows, so a
 * filtered view cannot change sessions the user cannot see.
 */
export function AgentHistoryList({
  sessions,
  metadata,
  conversations,
  isRefreshing,
  error,
  canRefresh,
  onRefresh,
  onSelect,
  onRename,
  onSetFavorite,
  onSetHidden,
  isExporting,
  onExport,
  canExportSession,
}: AgentHistoryListProps) {
  const { t } = useTranslation();
  const [query, setQuery] = useState("");
  const [filter, setFilter] = useState<AgentHistoryFilter>("all");
  const [isSelecting, setIsSelecting] = useState(false);
  const [selectedIDs, setSelectedIDs] = useState<string[]>([]);
  const [copiedID, setCopiedID] = useState<string | null>(null);

  const rows = useMemo(
    () => agentHistoryRows(sessions, metadata, query, filter),
    [sessions, metadata, query, filter],
  );
  const visibleIDs = useMemo(() => rows.map((row) => row.session.id), [rows]);
  const selected = visibleIDs.filter((id) => selectedIDs.includes(id));
  const allSelected = visibleIDs.length > 0 && selected.length === visibleIDs.length;

  const toggleSelection = (sessionID: string) =>
    setSelectedIDs((current) =>
      current.includes(sessionID)
        ? current.filter((id) => id !== sessionID)
        : [...current, sessionID],
    );

  const copySessionID = (sessionID: string) => {
    void tryWriteClipboardText(sessionID).then((copied) =>
      setCopiedID(copied ? sessionID : null),
    );
  };

  const rename = async (sessionID: string, title: string | null) => {
    const next = await showPromptDialog(t("agent.history.renameMessage"), {
      title: t("agent.history.rename"),
      defaultValue: title ?? "",
      confirmLabel: t("ui.ok"),
      cancelLabel: t("ui.cancel"),
    });
    if (next !== null) void onRename(sessionID, next);
  };

  /** Removing is Lithe-only, so it confirms once and stays reversible. */
  const remove = async (sessionIDs: string[]) => {
    if (sessionIDs.length === 0) return;
    const confirmed = await showConfirmDialog(
      t("agent.history.removeConfirm", { count: sessionIDs.length }),
      {
        title: t("agent.history.remove"),
        confirmLabel: t("agent.history.remove"),
        cancelLabel: t("ui.cancel"),
      },
    );
    if (!confirmed) return;
    onSetHidden(sessionIDs, true);
    setSelectedIDs((current) => current.filter((id) => !sessionIDs.includes(id)));
  };

  const emptyMessage = isRefreshing
    ? t("agent.history.loading")
    : query.trim().length > 0
      ? `${t("agent.history.noMatch")} ${t("agent.history.noMatchHint")}`
      : t("agent.history.empty");

  return (
    <div className="border-border/70 border-b">
      <div className="flex items-center gap-1 px-2 py-1">
        <span className="min-w-0 flex-1 truncate text-subtle-foreground ui-text-caption">
          {isSelecting
            ? t("agent.history.selectedCount", { count: selected.length })
            : t("agent.history.conversations", { count: sessions.length })}
        </span>
        <Button
          type="button"
          size="xs"
          variant="ghost"
          onClick={() => {
            setIsSelecting(!isSelecting);
            setSelectedIDs([]);
          }}
        >
          {isSelecting ? t("agent.history.done") : t("agent.history.select")}
        </Button>
        <NativeSelect
          size="sm"
          value={filter}
          aria-label={t("agent.history.filter")}
          title={t("agent.history.filter")}
          onChange={(event) => setFilter(event.target.value as AgentHistoryFilter)}
        >
          <NativeSelectOption value="all">{t("agent.history.filter.all")}</NativeSelectOption>
          <NativeSelectOption value="favorites">
            {t("agent.history.filter.favorites")}
          </NativeSelectOption>
          <NativeSelectOption value="removed">
            {t("agent.history.filter.removed")}
          </NativeSelectOption>
        </NativeSelect>
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

      <div className="px-2 pb-1">
        <SearchField
          value={query}
          onChange={setQuery}
          placeholder={t("agent.history.search")}
          aria-label={t("agent.history.search")}
          className="h-6 ui-text-caption"
        />
      </div>

      {error === null ? null : (
        <div className="px-2 pb-1 text-warning ui-text-caption">{error}</div>
      )}

      {isSelecting ? (
        <div className="flex flex-wrap items-center gap-1 px-2 pb-1">
          <Button
            type="button"
            size="xs"
            variant="ghost"
            disabled={visibleIDs.length === 0}
            onClick={() => setSelectedIDs(allSelected ? [] : visibleIDs)}
          >
            {allSelected ? t("agent.history.deselectAll") : t("agent.history.selectAll")}
          </Button>
          <Button
            type="button"
            size="xs"
            variant="ghost"
            disabled={selected.length === 0 || isExporting}
            onClick={() => onExport(selected)}
          >
            {t("agent.history.export")}
          </Button>
          <Button
            type="button"
            size="xs"
            variant="ghost"
            disabled={selected.length === 0}
            onClick={() => onSetFavorite(selected, true)}
          >
            {t("agent.history.addFavorite")}
          </Button>
          <Button
            type="button"
            size="xs"
            variant="ghost"
            disabled={selected.length === 0}
            onClick={() => onSetFavorite(selected, false)}
          >
            {t("agent.history.removeFavorite")}
          </Button>
          <Button
            type="button"
            size="xs"
            variant="ghost"
            disabled={selected.length === 0}
            onClick={() => {
              if (filter === "removed") {
                onSetHidden(selected, false);
                setSelectedIDs([]);
                return;
              }
              void remove(selected);
            }}
          >
            {filter === "removed"
              ? t("agent.history.restore")
              : t("agent.history.remove")}
          </Button>
        </div>
      ) : null}

      {filter === "removed" ? (
        <div className="px-2 pb-1 text-subtle-foreground ui-text-caption">
          {t("agent.history.removedNotice")}
        </div>
      ) : null}

      {rows.length === 0 ? (
        <div className="px-2 pb-1.5 text-subtle-foreground ui-text-caption">{emptyMessage}</div>
      ) : (
        <div className="max-h-56 overflow-auto pb-1">
          {rows.map((row) => {
            const sessionID = row.session.id;
            const isSelected = selected.includes(sessionID);
            const messageCount = historyMessageCount(conversations[sessionID] ?? null);
            const label = row.title ?? t("agent.tabs.untitled");
            return (
              <div
                key={sessionID}
                className={cn(
                  "group flex items-center gap-1 px-2 py-1",
                  isSelected ? "bg-accent" : "hover:bg-accent",
                )}
              >
                {isSelecting ? (
                  <Checkbox
                    className="size-3.5"
                    checked={isSelected}
                    aria-label={label}
                    onCheckedChange={() => toggleSelection(sessionID)}
                  />
                ) : null}
                <button
                  type="button"
                  className="flex min-w-0 flex-1 flex-col text-left"
                  onClick={() => onSelect(sessionID)}
                >
                  <span className="truncate text-foreground ui-text-sm">{label}</span>
                  <span className="truncate text-subtle-foreground ui-text-caption">
                    {row.session.updatedAt ?? sessionID}
                    {messageCount === null
                      ? ""
                      : ` · ${t("agent.history.messages", { count: messageCount })}`}
                  </span>
                </button>
                <Button
                  type="button"
                  size="icon-xs"
                  variant="ghost"
                  className={cn(
                    row.isFavorite ? "opacity-100" : "opacity-0 group-hover:opacity-100 group-focus-within:opacity-100",
                  )}
                  tooltip={
                    row.isFavorite
                      ? t("agent.history.removeFavorite")
                      : t("agent.history.addFavorite")
                  }
                  aria-label={
                    row.isFavorite
                      ? t("agent.history.removeFavorite")
                      : t("agent.history.addFavorite")
                  }
                  onClick={() => onSetFavorite([sessionID], !row.isFavorite)}
                >
                  <StarIcon
                    className={cn("size-3", row.isFavorite && "fill-current text-warning")}
                  />
                </Button>
                <div className="flex shrink-0 items-center opacity-0 group-hover:opacity-100 group-focus-within:opacity-100">
                  <Button
                    type="button"
                    size="icon-xs"
                    variant="ghost"
                    tooltip={copiedID === sessionID ? t("agent.history.copied") : t("agent.history.copyId")}
                    aria-label={t("agent.history.copyId")}
                    onClick={() => copySessionID(sessionID)}
                  >
                    {copiedID === sessionID ? (
                      <CheckIcon className="size-3" />
                    ) : (
                      <CopyIcon className="size-3" />
                    )}
                  </Button>
                  <Button
                    type="button"
                    size="icon-xs"
                    variant="ghost"
                    tooltip={t("agent.history.rename")}
                    aria-label={t("agent.history.rename")}
                    onClick={() => void rename(sessionID, row.title)}
                  >
                    <PencilSimpleIcon className="size-3" />
                  </Button>
                  <Button
                    type="button"
                    size="icon-xs"
                    variant="ghost"
                    disabled={isExporting || !canExportSession(sessionID)}
                    tooltip={t("agent.history.export")}
                    aria-label={t("agent.history.export")}
                    onClick={() => onExport([sessionID])}
                  >
                    <DownloadSimpleIcon className="size-3" />
                  </Button>
                  <Button
                    type="button"
                    size="icon-xs"
                    variant="ghost"
                    tooltip={
                      filter === "removed"
                        ? t("agent.history.restore")
                        : t("agent.history.remove")
                    }
                    aria-label={
                      filter === "removed"
                        ? t("agent.history.restore")
                        : t("agent.history.remove")
                    }
                    onClick={() => {
                      if (filter === "removed") {
                        onSetHidden([sessionID], false);
                        return;
                      }
                      void remove([sessionID]);
                    }}
                  >
                    {filter === "removed" ? (
                      <ArrowCounterClockwiseIcon className="size-3" />
                    ) : (
                      <TrashIcon className="size-3" />
                    )}
                  </Button>
                </div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
