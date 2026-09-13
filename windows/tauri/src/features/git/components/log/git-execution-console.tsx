import { useEffect, useMemo, useRef, useState } from "react";
import { toast } from "sonner";
import { invoke } from "@/platform/tauri-core";
import { useTranslation } from "@/i18n/locale-provider";
import { tryWriteClipboardText } from "@/utils/clipboard";
import { clearGitConsole, useGitConsoleStore } from "../../stores/git-console.store";
import { gitConsoleCompleteCommand, gitConsoleTimestamp, redactConsoleText, sameGitRoot } from "../../services/git-execution-journal";

import { consolePresentationRequest, consoleSearchAnchor, type ConsolePresentation } from "../../services/git-console-presentation";
import type { GitConsoleRecord } from "../../services/git-execution-journal";
import { useRepositoryStore } from "../../stores/git-repository.store";
import { GitConsoleEntry } from "./git-console-entry";

export function GitExecutionConsole({ repoPath }: { repoPath: string | null }) {
  const { t } = useTranslation();
  const [wrapsLines, setWrapsLines] = useState(false);
  const allRecords = useGitConsoleStore((state) => state.records);
  const repositoryRoots = useRepositoryStore((state) => state.availableRepoPaths);
  const historyTruncated = useGitConsoleStore((state) => state.historyTruncated);
  const active = useGitConsoleStore((state) => state.active);
  const currentRecords = useMemo(() => allRecords.filter((record) => sameGitRoot(record.root, repoPath)), [allRecords, repoPath]);
  const [search, setSearch] = useState("");
  const [searchOpen, setSearchOpen] = useState(false);
  const [matchIndex, setMatchIndex] = useState(0);
  const [navigation, setNavigation] = useState(0);
  const [expandedGroups, setExpandedGroups] = useState<Set<string>>(() => new Set());
  const [bundle, setBundle] = useState<{ records: GitConsoleRecord[]; root: string | null; search: string; presentation?: ConsolePresentation; failed?: boolean }>();
  useEffect(() => {
    let disposed = false;
    // The journal already batches streaming snapshots; cancellation discards stale projections.
    void invoke<ConsolePresentation>("git.consolePresentation", consolePresentationRequest(currentRecords, search, repositoryRoots)).then(
      (presentation) => { if (!disposed) setBundle({ records: currentRecords, root: repoPath, search, presentation }); },
      () => { if (!disposed) setBundle({ records: currentRecords, root: repoPath, search, failed: true }); },
    );
    return () => { disposed = true; };
  }, [currentRecords, repoPath, search, repositoryRoots]);
  const currentBundle = bundle?.root === repoPath ? bundle : undefined;
  const records = currentBundle?.records ?? currentRecords;
  const presentation = currentBundle?.presentation;
  const selectedHit = currentBundle?.search === search ? presentation?.matches[matchIndex] : undefined;
  const selectedAnchor = selectedHit ? consoleSearchAnchor(selectedHit) : undefined;
  const selectedGroupId = presentation?.groups.find((group) => group.recordIds.includes(selectedHit?.recordId ?? ""))?.id;
  const entryById = new Map(presentation?.entries.map((entry) => [entry.id, entry]));
  const groupByRecord = new Map(presentation?.groups.flatMap((group) => group.recordIds.map((id) => [id, group] as const)));
  const firstById = new Map(records.map((record) => [record.id, record]));
  useEffect(() => { setMatchIndex(0); setNavigation((value) => value + 1); }, [search]);
  const moveMatch = (delta: number) => {
    const count = presentation?.matches.length ?? 0;
    if (count) setMatchIndex((index) => (index + delta + count) % count);
    setNavigation((value) => value + 1);
  };
  const bottom = useRef<HTMLDivElement>(null);
  const scroll = useRef<HTMLDivElement>(null);
  const followsOutput = useRef(true);
  useEffect(() => { if (followsOutput.current) bottom.current?.scrollIntoView({ block: "end" }); }, [records, repoPath]);
  useEffect(() => {
    if (!selectedAnchor) return;
    followsOutput.current = false;
    if (selectedGroupId) setExpandedGroups((previous) => previous.has(selectedGroupId) ? previous : new Set(previous).add(selectedGroupId));
    // Wait for both the group and its target range to be mounted after disclosure.
    let nestedFrame: number | undefined;
    const frame = requestAnimationFrame(() => {
      nestedFrame = requestAnimationFrame(() => {
      const target = selectedAnchor;
      const node = [...(scroll.current?.querySelectorAll<HTMLElement>("[data-console-anchor]") ?? [])].find((element) => element.dataset.consoleAnchor === target);
      node?.scrollIntoView({ block: "center" });
      });
    });
    return () => { cancelAnimationFrame(frame); if (nestedFrame != null) cancelAnimationFrame(nestedFrame); };
  }, [selectedAnchor, selectedGroupId, navigation]);
  const operations = [...active].filter(([, root]) => sameGitRoot(root, repoPath));
  return <div className="flex min-h-0 flex-1 flex-col font-mono text-xs" onKeyDown={(event) => {
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "f") { event.preventDefault(); setSearchOpen(true); }
  }}>
    <div className="flex shrink-0 flex-wrap gap-x-4 gap-y-2 border-b px-3 py-2">
      <button onClick={() => { if (searchOpen) setSearch(""); setSearchOpen((value) => !value); }}>{t("git.console.find")}</button>
      <button aria-pressed={wrapsLines} onClick={() => setWrapsLines((value) => !value)}>{t("git.console.wrap")}</button>
      <button onClick={() => { followsOutput.current = true; bottom.current?.scrollIntoView({ block: "end" }); }}>{t("git.console.scrollToEnd")}</button>
      <button disabled={!operations.length} onClick={() => {
        for (const [id] of operations) void invoke("core_cancel", { operationId: id })
          .catch((error: unknown) => toast.error(String(error)));
      }}>{t("git.console.cancel")}</button>
      <button disabled={!records.length} onClick={() => repoPath && clearGitConsole(repoPath)}>{t("git.console.clear")}</button>
      <button disabled={!records.length} onClick={() => void tryWriteClipboardText(redactConsoleText(records.map((record) => [
        `${gitConsoleTimestamp(record.timestamp)}: [${record.root}] ${gitConsoleCompleteCommand(record)}`,
        `${t(`git.console.${record.state}`)}${record.durationMilliseconds == null ? "" : ` · ${record.durationMilliseconds} ms`}${record.exitCode == null ? "" : ` · ${t("git.console.exit")} ${record.exitCode}`}`,
        record.executable,
        record.temporaryConfig?.map((pair) => pair.join("=")).join(", "),
        record.remoteResult ? `${record.remoteResult.remote}: ${record.remoteResult.succeeded ? t("git.execution.remoteSucceeded") : t("git.execution.remoteFailed")}\n${(record.remoteResult.updatedReferences ?? []).join(", ")}\n${(record.remoteResult.deletedReferences ?? []).join(", ")}` : undefined,
        record.output,
        record.progress,
        record.truncated ? t("git.console.truncated") : undefined,
        record.error,
      ].filter(Boolean).join("\n")).join("\n\n")))}>{t("git.console.copy")}</button>
    </div>
    {searchOpen && <div className="flex items-center gap-2 border-b px-3 py-1">
      <input autoFocus value={search} maxLength={256} aria-label={t("git.console.find")} placeholder={t("git.console.find")}
        className="min-w-0 flex-1 bg-transparent" onChange={(event) => setSearch(event.target.value)}
        onKeyDown={(event) => { if (event.key === "Enter") moveMatch(event.shiftKey ? -1 : 1); if (event.key === "Escape") { setSearchOpen(false); setSearch(""); } }} />
      <span>{presentation?.totalMatches ? matchIndex + 1 : 0}/{presentation?.totalMatches ?? 0}{presentation && presentation.totalMatches > presentation.matches.length ? ` (${t("git.console.searchLimit", { count: presentation.matches.length })})` : ""}</span>
      <button onClick={() => moveMatch(-1)} aria-label={t("git.console.previousMatch")}>↑</button>
      <button onClick={() => moveMatch(1)} aria-label={t("git.console.nextMatch")}>↓</button>
      <button onClick={() => { setSearchOpen(false); setSearch(""); }} aria-label={t("git.console.closeSearch")}>×</button>
    </div>}
    {currentBundle?.failed && <div className="px-3 text-subtle-foreground">{t("git.console.presentationUnavailable")}</div>}
    <div ref={scroll} className="min-h-0 flex-1 overflow-auto p-3" onScroll={() => { const node = scroll.current; if (node) followsOutput.current = node.scrollHeight - node.scrollTop - node.clientHeight < 32; }}>
      {historyTruncated && <p className="text-subtle-foreground">{t("git.console.historyTruncated")}</p>}
      {!records.length && <p className="text-subtle-foreground">{t("git.console.empty")}</p>}
      <div className={wrapsLines ? "whitespace-pre-wrap break-words" : "w-max min-w-full whitespace-pre"}>
        {records.map((record) => {
          const group = groupByRecord.get(record.id);
          const isFirst = !group || group.id === record.id;
          const expanded = !group || expandedGroups.has(group.id);
          // Preserve mounted row state even while its background group is folded.
          return <div key={record.id} hidden={!isFirst && !expanded}>
            <GitConsoleEntry record={record} presentation={entryById.get(record.id)} selectedHit={selectedHit} searchNavigation={navigation} />
            {isFirst && group && group.recordIds.length > 1 && <button className="mb-1 inline border-0 bg-transparent p-0 font-[inherit] text-subtle-foreground"
              aria-expanded={expanded} onClick={() => setExpandedGroups((previous) => {
                const next = new Set(previous); if (next.has(group.id)) next.delete(group.id); else next.add(group.id); return next;
              })}>{expanded ? "▾ " : "▸ "}{t("git.console.automaticQueries", { count: group.recordIds.length })}{group.matches > 0 ? ` · ${t("git.console.matches", { count: group.matches })}` : ""} · {gitConsoleTimestamp(record.timestamp)}–{gitConsoleTimestamp(firstById.get(group.recordIds[group.recordIds.length - 1]!)?.timestamp ?? record.timestamp)}</button>}
          </div>;
        })}
      </div>
      <div ref={bottom} />
    </div>
  </div>;
}
