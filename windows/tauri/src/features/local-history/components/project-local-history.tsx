import { useProjectStore } from "@/features/window/stores/project.store";
import { useEffect, useState } from "react";
import { listProjectLocalHistory, type LocalHistoryEntry } from "../api/local-history-api";
import { useLocalHistoryStore } from "../stores/local-history.store";
import { openLocalHistoryForPath } from "../utils/open-local-history";
import {
  CommandHeader,
  CommandHeaderAction,
  CommandInput,
  CommandList,
  CommandEmpty,
} from "@/ui/command";
import { ArrowLeftIcon } from "@/ui/icons";
import { useTranslation } from "@/i18n/locale-provider";
import { joinPath } from "@/utils/path-helpers";
import { formatShortDateTime } from "@/utils/date";

export function ProjectLocalHistoryContent({
  isActive,
  onBack,
  onClose,
}: {
  isActive: boolean;
  onBack: () => void;
  onClose: () => void;
}) {
  const { t } = useTranslation();
  const workspace = useLocalHistoryStore((state) => state.targetPath);
  const activeWorkspace = useProjectStore((state) => state.rootFolderPath);
  const [entries, setEntries] = useState<LocalHistoryEntry[]>([]);
  const [query, setQuery] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string>();
  useEffect(() => {
    if (!workspace || !isActive || activeWorkspace !== workspace) {
      setEntries([]);
      return;
    }
    let cancelled = false;
    setLoading(true);
    setError(undefined);
    setEntries([]);
    void listProjectLocalHistory(workspace)
      .then((value) => {
        if (!cancelled) setEntries(value);
      })
      .catch((failure) => {
        if (!cancelled) setError(String(failure));
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [workspace, isActive, activeWorkspace]);
  const filtered = entries.filter((entry) =>
    `${entry.file_path} ${entry.label ?? ""}`.toLowerCase().includes(query.toLowerCase()),
  );
  return (
    <>
      <CommandHeader onClose={onClose}>
        <CommandHeaderAction aria-label={t("localHistory.back")} onClick={onBack}>
          <ArrowLeftIcon />
        </CommandHeaderAction>
        <span>{t("project.localHistory")}</span>
      </CommandHeader>
      <div className="px-4 py-2">
        <CommandInput
          value={query}
          onChange={setQuery}
          placeholder={t("localHistory.searchTimeline")}
        />
      </div>
      <CommandList>
        {error ? (
          <CommandEmpty>{error}</CommandEmpty>
        ) : loading ? (
          <CommandEmpty>{t("localHistory.loadingTimeline")}</CommandEmpty>
        ) : !filtered.length ? (
          <CommandEmpty>{t("localHistory.noSnapshots")}</CommandEmpty>
        ) : (
          filtered.map((entry) => (
            <button
              key={entry.id}
              type="button"
              className="flex w-full flex-col gap-1 rounded px-3 py-2 text-left hover:bg-accent focus:bg-selected"
              onClick={() => {
                if (workspace && activeWorkspace === workspace)
                  openLocalHistoryForPath(joinPath(workspace, entry.file_path), entry.id);
              }}
            >
              <span>{entry.file_path}</span>
              <span className="ui-text-sm text-subtle-foreground">
                {entry.label || formatShortDateTime(entry.created_at)} · {entry.reason}
              </span>
            </button>
          ))
        )}
      </CommandList>
    </>
  );
}
