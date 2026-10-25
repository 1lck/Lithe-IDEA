import { useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { showConfirmDialog } from "@/ui/dialog";
import { CaretDownIcon, CaretRightIcon, CopyIcon, StarIcon } from "@/ui/icons";
import { Spinner } from "@/ui/spinner";
import { tryWriteClipboardText } from "@/utils/clipboard";
import { agentHistoryRows } from "../services/agent-history-view";
import type { AgentSessionSummary } from "../types/agent.types";
import type { AgentHistoryFilter, AgentHistoryMetadataMap } from "../types/agent-history.types";

export interface AgentArchiveHistoryProps {
  supported: boolean;
  sessions: AgentSessionSummary[];
  loading: boolean;
  complete: boolean;
  error: string | null;
  restoringIDs: string[];
  canRefresh: boolean;
  onRefresh: () => void;
  onRestore: (sessionID: string) => Promise<boolean>;
}

/** The provider archive shares search/annotations, but never the local hidden flag. */
export function AgentArchivedHistory({ archive, query, filter, metadata, onSelect, onSetHidden, onSetFavorite }: {
  archive: AgentArchiveHistoryProps;
  query: string;
  filter: AgentHistoryFilter;
  metadata: AgentHistoryMetadataMap;
  onSelect: (sessionID: string) => void;
  onSetHidden: (ids: string[], hidden: boolean) => void;
  onSetFavorite: (ids: string[], favorite: boolean) => void;
}) {
  const { t } = useTranslation();
  const [expanded, setExpanded] = useState(false);
  const rows = agentHistoryRows(archive.sessions, metadata, query, filter);
  const isExpanded = expanded || (query.trim().length > 0 && rows.length > 0);
  const restore = async (sessionID: string) => {
    if (filter === "removed") {
      onSetHidden([sessionID], false);
      return;
    }
    const confirmed = await showConfirmDialog(t("agent.archive.confirmMessage"), {
      title: t("agent.archive.restore"), confirmLabel: t("agent.archive.restore"), cancelLabel: t("ui.cancel"),
    });
    if (confirmed && await archive.onRestore(sessionID)) onSelect(sessionID);
  };
  return (
    <section className="border-t border-border/70 px-2 py-1" aria-label={t("agent.archive.title")}>
      <div className="flex items-center gap-1">
        <button type="button" className="flex min-w-0 flex-1 items-center gap-1 text-left ui-text-caption"
          aria-expanded={isExpanded} onClick={() => setExpanded(!isExpanded)}>
          {isExpanded ? <CaretDownIcon className="size-3" /> : <CaretRightIcon className="size-3" />}
          {t("agent.archive.title")} ({rows.length})
        </button>
        {archive.loading ? <Spinner className="size-3" /> : null}
        <Button size="xs" variant="ghost" disabled={!archive.canRefresh || archive.loading}
          onClick={archive.onRefresh}>{t("agent.archive.refresh")}</Button>
      </div>
      {!archive.supported ? <p className="text-subtle-foreground ui-text-caption">{t("agent.archive.unsupported")}</p> : null}
      {archive.error ? <p role="alert" className="text-warning ui-text-caption">{archive.error}</p> : null}
      {!archive.complete ? <p className="text-subtle-foreground ui-text-caption">{t("agent.archive.incomplete")}</p> : null}
      {isExpanded && archive.supported ? <div className="max-h-56 overflow-auto">
        {rows.length === 0 && !archive.loading ? <p className="text-subtle-foreground ui-text-caption">{t("agent.archive.empty")}</p> : null}
        {rows.map((row) => <div key={row.session.id} className="flex items-center gap-1 py-1 ui-text-caption">
          <button type="button" className="min-w-0 flex-1 text-left" disabled={!archive.canRefresh || archive.restoringIDs.includes(row.session.id)} onClick={() => void restore(row.session.id)}>
            <span className="block truncate">{row.title ?? t("agent.tabs.untitled")}</span>
            <span className="block truncate text-subtle-foreground">{t("agent.archive.badge")} · {row.session.updatedAt ?? row.session.id}</span>
          </button>
          <Button size="icon-xs" variant="ghost" aria-label={t(row.isFavorite ? "agent.history.removeFavorite" : "agent.history.addFavorite")}
            onClick={() => onSetFavorite([row.session.id], !row.isFavorite)}>
            <StarIcon className={row.isFavorite ? "size-3 fill-current text-warning" : "size-3"} />
          </Button>
          <Button size="icon-xs" variant="ghost" aria-label={t("agent.history.copyId")}
            onClick={() => void tryWriteClipboardText(row.session.id)}><CopyIcon className="size-3" /></Button>
          <Button size="xs" variant="ghost" disabled={!archive.canRefresh || archive.restoringIDs.includes(row.session.id)} onClick={() => void restore(row.session.id)}>
            {t(filter === "removed" ? "agent.history.restore" : "agent.archive.restore")}
          </Button>
        </div>)}
      </div> : null}
    </section>
  );
}
