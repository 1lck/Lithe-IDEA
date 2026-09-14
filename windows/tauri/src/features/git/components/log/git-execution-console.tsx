import { Search, WrapText, ArrowDownToLine, Square, Trash2, Copy } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { toast } from "sonner";
import { invoke } from "@/platform/tauri-core";
import { useTranslation } from "@/i18n/locale-provider";
import { tryWriteClipboardText } from "@/utils/clipboard";
import { clearGitConsole, useGitConsoleStore } from "../../stores/git-console.store";
import { gitConsoleCompleteCommand, gitConsoleTimestamp, redactConsoleText } from "../../services/git-execution-journal";

import { consolePresentationRequest, consoleSearchAnchor, type ConsolePresentation } from "../../services/git-console-presentation";
import type { GitConsoleRecord } from "../../services/git-execution-journal";
import { useRepositoryStore } from "../../stores/git-repository.store";
import { GitConsoleEntry } from "./git-console-entry";

export function GitExecutionConsole() {
  const { t } = useTranslation();
  const [wrapsLines, setWrapsLines] = useState(false);
  const allRecords = useGitConsoleStore((state) => state.records);
  const repositoryRoots = useRepositoryStore((state) => state.availableRepoPaths);
  const historyTruncated = useGitConsoleStore((state) => state.historyTruncated);
  const active = useGitConsoleStore((state) => state.active);
  const currentRecords = allRecords;
  const [search, setSearch] = useState("");
  const [searchOpen, setSearchOpen] = useState(false);
  const [matchIndex, setMatchIndex] = useState(0);
  const [navigation, setNavigation] = useState(0);
  const [bundle, setBundle] = useState<{ records: GitConsoleRecord[]; search: string; presentation?: ConsolePresentation; failed?: boolean }>();
  useEffect(() => {
    let disposed = false;
    // The journal already batches streaming snapshots; cancellation discards stale projections.
    void invoke<ConsolePresentation>("git.consolePresentation", consolePresentationRequest(currentRecords, search, repositoryRoots)).then(
      (presentation) => { if (!disposed) setBundle({ records: currentRecords, search, presentation }); },
      () => { if (!disposed) setBundle({ records: currentRecords, search, failed: true }); },
    );
    return () => { disposed = true; };
  }, [currentRecords, search, repositoryRoots]);
  const currentBundle = bundle;
  const records = currentBundle?.records ?? currentRecords;
  const presentation = currentBundle?.presentation;
  const selectedHit = currentBundle?.search === search ? presentation?.matches[matchIndex] : undefined;
  const selectedAnchor = selectedHit ? consoleSearchAnchor(selectedHit) : undefined;
  const entryById = new Map(presentation?.entries.map((entry) => [entry.id, entry]));
  useEffect(() => { setMatchIndex(0); setNavigation((value) => value + 1); }, [search]);
  const moveMatch = (delta: number) => {
    const count = presentation?.matches.length ?? 0;
    if (count) setMatchIndex((index) => (index + delta + count) % count);
    setNavigation((value) => value + 1);
  };
  const bottom = useRef<HTMLDivElement>(null);
  const scroll = useRef<HTMLDivElement>(null);
  const followsOutput = useRef(true);
  useEffect(() => { if (followsOutput.current) bottom.current?.scrollIntoView({ block: "end" }); }, [records]);
  useEffect(() => {
    if (!selectedAnchor) return;
    followsOutput.current = false;
    // Wait for the target range to be mounted after disclosure.
    let nestedFrame: number | undefined;
    const frame = requestAnimationFrame(() => {
      nestedFrame = requestAnimationFrame(() => {
      const target = selectedAnchor;
      const node = [...(scroll.current?.querySelectorAll<HTMLElement>("[data-console-anchor]") ?? [])].find((element) => element.dataset.consoleAnchor === target);
      node?.scrollIntoView({ block: "center" });
      });
    });
    return () => { cancelAnimationFrame(frame); if (nestedFrame != null) cancelAnimationFrame(nestedFrame); };
  }, [selectedAnchor, navigation]);
  const operations = [...active];
  return <div className="flex min-h-0 flex-1 font-mono text-xs" onKeyDown={(event) => {
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "f") { event.preventDefault(); setSearchOpen(true); }
  }}>
    <div className="flex w-8 shrink-0 flex-col items-center gap-1 border-r py-1 [&>button]:flex [&>button]:size-6 [&>button]:items-center [&>button]:justify-center [&>button]:rounded [&>button:hover]:bg-accent [&>button:disabled]:opacity-40">
      <button onClick={() => { if (searchOpen) setSearch(""); setSearchOpen((value) => !value); }} title={t("git.console.find")} aria-label={t("git.console.find")}><Search className="size-3.5" /></button>
      <button aria-pressed={wrapsLines} onClick={() => setWrapsLines((value) => !value)} title={t("git.console.wrap")} aria-label={t("git.console.wrap")}><WrapText className="size-3.5" /></button>
      <button onClick={() => { followsOutput.current = true; bottom.current?.scrollIntoView({ block: "end" }); }} title={t("git.console.scrollToEnd")} aria-label={t("git.console.scrollToEnd")}><ArrowDownToLine className="size-3.5" /></button>
      <button disabled={!operations.length} onClick={() => {
        for (const [id] of operations) void invoke("core_cancel", { operationId: id })
          .catch((error: unknown) => toast.error(String(error)));
      }} title={t("git.console.cancel")} aria-label={t("git.console.cancel")}><Square className="size-3.5" /></button>
      <button disabled={!records.length} onClick={() => clearGitConsole()} title={t("git.console.clear")} aria-label={t("git.console.clear")}><Trash2 className="size-3.5" /></button>
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
      ].filter(Boolean).join("\n")).join("\n\n")))} title={t("git.console.copy")} aria-label={t("git.console.copy")}><Copy className="size-3.5" /></button>
    </div>
    <div className="flex min-h-0 min-w-0 flex-1 flex-col">
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
        {records.map((record) => <GitConsoleEntry key={record.id} record={record}
          presentation={entryById.get(record.id)} selectedHit={selectedHit} searchNavigation={navigation} />)}
      </div>
      <div ref={bottom} />
    </div>
    </div>
  </div>;
}
