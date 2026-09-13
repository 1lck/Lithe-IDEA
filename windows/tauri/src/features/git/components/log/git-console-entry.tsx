import { Fragment, useEffect, useState } from "react";
import { ContextMenu, ContextMenuContent, ContextMenuItem, ContextMenuTrigger } from "@/ui/context-menu";
import { tryWriteClipboardText } from "@/utils/clipboard";
import { useTranslation } from "@/i18n/locale-provider";
import { gitConsoleCommand, gitConsoleCompleteCommand, gitConsoleConfiguration, gitConsoleTimestamp, redactConsoleText, type GitConsoleRecord } from "../../services/git-execution-journal";

import { consoleSearchAnchor, type ConsolePresentationEntry, type ConsoleSearchHit, type ConsoleOutputFragment } from "../../services/git-console-presentation";

export function GitConsoleEntry({ record, presentation, selectedHit, searchNavigation = 0 }: {
  record: GitConsoleRecord; presentation?: ConsolePresentationEntry;
  selectedHit?: ConsoleSearchHit; searchNavigation?: number;
}) {
  const { t } = useTranslation();
  const [expandedConfiguration, setExpandedConfiguration] = useState(false);
  const [expanded, setExpanded] = useState<Set<string>>(() => new Set());
  const toggle = (id: string) => setExpanded((previous) => {
    const next = new Set(previous); if (next.has(id)) next.delete(id); else next.add(id); return next;
  });
  const selectedRecordId = selectedHit?.recordId;
  const selectedFragmentId = selectedHit?.fragmentId;
  useEffect(() => {
    if (selectedRecordId !== record.id || !selectedFragmentId) return;
    setExpanded((previous) => new Set(previous).add(selectedFragmentId));
  }, [selectedRecordId, selectedFragmentId, record.id, searchNavigation]);
  const target = selectedHit?.recordId === record.id ? consoleSearchAnchor(selectedHit) : undefined;
  const outputExpanded = (id: string) => expanded.has(id) || expanded.has("running-output");
  const toggleOutput = (id: string) => setExpanded((previous) => {
    const next = new Set(previous);
    if (next.has(id) || next.has("running-output")) { next.delete(id); next.delete("running-output"); }
    else { next.add(id); if (record.state === "running") next.add("running-output"); }
    return next;
  });
  const foldLabel = (fragment: ConsoleOutputFragment) => fragment.kind === "progress"
    ? record.lines[fragment.end - 1]?.text ?? ""
    : fragment.kind === "references"
    ? t("git.console.referenceChanges", { added: fragment.added, updated: fragment.updated, deleted: fragment.deleted })
    : t(`git.console.fold.${fragment.kind}`, { count: fragment.count });
  const matchLabel = (count: number) => count ? ` · ${t("git.console.matches", { count })}` : "";
  const outputLine = (index: number) => {
    const line = record.lines[index];
    if (!line) return null;
    const id = `${record.id}:line-${index}`;
    return <div key={index} data-console-anchor={id} className={(line.stream === "stderr" ? "text-destructive" : "text-foreground") + (id === target ? " bg-warning/20" : "")}>{line.text || "\u00a0"}</div>;
  };
  const [expandedDetails, setExpandedDetails] = useState(false);
  const configuration = record.globalArguments ? gitConsoleCommand(record.globalArguments).slice(4) : gitConsoleConfiguration(record.temporaryConfig);
  const arguments_ = record.displayArguments ?? record.arguments;
  return (
    <ContextMenu>
      <ContextMenuTrigger className="mb-1 leading-5" tabIndex={0}>
        <div className="text-info" title={`${record.root} · ${t(`git.console.${record.state}`)}${record.exitCode == null ? "" : ` · ${record.exitCode}`}`}>
          <span data-console-anchor={`${record.id}:repository`} className={target === `${record.id}:repository` ? "bg-warning/20" : undefined}>{gitConsoleTimestamp(record.timestamp)}: [{presentation?.repositoryLabel ?? record.root}] git </span>
          {presentation ? presentation.command.map((fragment, index) => <Fragment key={fragment.id}>
            {index > 0 && " "}
            <span data-console-anchor={`${record.id}:${fragment.id}`} className={target === `${record.id}:${fragment.id}` ? "bg-warning/20" : undefined}>
              {fragment.kind === "text" ? fragment.text : <button type="button"
                className="inline cursor-pointer border-0 bg-success/10 p-0 font-[inherit] text-foreground focus-visible:outline focus-visible:outline-1"
                title={fragment.text} aria-expanded={expanded.has(fragment.id)} onClick={() => toggle(fragment.id)}>
                {expanded.has(fragment.id) ? fragment.text : fragment.preview || t(`git.console.arguments.${fragment.kind}`, { count: fragment.count })}
                {!expanded.has(fragment.id) && matchLabel(fragment.matches)}
              </button>}
            </span>
          </Fragment>) : <>
            {configuration && <><button type="button" className="inline cursor-pointer border-0 bg-success/10 p-0 font-[inherit] text-foreground"
              title={t("git.console.options")} aria-label={t("git.console.options")} aria-expanded={expandedConfiguration}
              onClick={() => setExpandedConfiguration((value) => !value)}>{expandedConfiguration ? configuration : "-c …"}</button>{" "}</>}
            {arguments_.length ? gitConsoleCommand(arguments_).slice(4) : t(`git.console.${record.state}`)}
          </>}
        </div>
        {presentation ? presentation.output.map((fragment) => <Fragment key={fragment.id}>
          {fragment.kind !== "text" && <div><button type="button" className="inline cursor-pointer border-0 bg-transparent p-0 font-[inherit] text-subtle-foreground"
            aria-expanded={outputExpanded(fragment.id)} onClick={() => toggleOutput(fragment.id)}>
            {outputExpanded(fragment.id) ? "▾ " : "▸ "}{foldLabel(fragment)}{matchLabel(fragment.matches)}
          </button></div>}
          {(fragment.kind === "text" || outputExpanded(fragment.id)) && Array.from({ length: fragment.end - fragment.start }, (_, offset) => outputLine(fragment.start + offset))}
        </Fragment>) : record.lines.map((_, index) => outputLine(index))}
        {record.progress && <div data-console-anchor={`${record.id}:progress`} className={target === `${record.id}:progress` ? "bg-warning/20" : "text-subtle-foreground"}>{record.progress}</div>}
        {record.truncated && <div className="text-subtle-foreground">{t("git.console.truncated")}</div>}
        {record.error && <div data-console-anchor={`${record.id}:error`} className={`text-destructive ${target === `${record.id}:error` ? "bg-warning/20" : ""}`}>{redactConsoleText(record.error)}</div>}
        {record.state === "unconfirmed" && <div className="text-destructive">{t("git.console.unconfirmed")}</div>}
        {record.state === "completed" && record.exitCode !== 0 && !record.expectedExit && <div className="text-destructive">{t("git.console.exit")} {record.exitCode}</div>}
        {expandedDetails && <div className="text-subtle-foreground">
          <div>{t(`git.console.${record.state}`)} · {record.durationMilliseconds ?? "—"} ms · {t("git.console.exit")} {record.exitCode ?? "—"}</div>
          {record.executable && <div>{t("git.execution.executable")}: {record.executable}</div>}
          {record.remoteResult && <>
            <div>{record.remoteResult.remote} · {t(record.remoteResult.succeeded ? "git.execution.remoteSucceeded" : "git.execution.remoteFailed")}</div>
            {record.remoteResult.referencesTruncated && <div>{t("git.execution.referencesTruncated", { updated: record.remoteResult.updatedReferenceCount ?? 0, deleted: record.remoteResult.deletedReferenceCount ?? 0 })}</div>}
            {record.remoteResult.referencesAvailable === false && <div>{t("git.execution.referencesUnavailable")}</div>}
            <div>{t("git.execution.updated")}: {(record.remoteResult.updatedReferences ?? []).join(", ")}</div>
            <div>{t("git.execution.deleted")}: {(record.remoteResult.deletedReferences ?? []).join(", ")}</div>
          </>}
        </div>}
      </ContextMenuTrigger>
      <ContextMenuContent>
        <ContextMenuItem onClick={() => void tryWriteClipboardText(record.root)}>{t("git.console.copyPath")}</ContextMenuItem>
        <ContextMenuItem onClick={() => void tryWriteClipboardText(gitConsoleCompleteCommand(record))}>{t("git.console.copyCommand")}</ContextMenuItem>
        <ContextMenuItem onClick={() => void tryWriteClipboardText(record.output)}>{t("git.console.copyOutput")}</ContextMenuItem>
        <ContextMenuItem onClick={() => setExpandedDetails((value) => !value)}>{t("git.console.details")}</ContextMenuItem>
        <ContextMenuItem onClick={() => void tryWriteClipboardText(redactConsoleText([
          `${gitConsoleTimestamp(record.timestamp)}: [${record.root}] ${gitConsoleCompleteCommand(record)}`,
          `${t(`git.console.${record.state}`)} · ${record.durationMilliseconds ?? "—"} ms · ${t("git.console.exit")} ${record.exitCode ?? "—"}`,
          record.executable, gitConsoleConfiguration(record.temporaryConfig),
          record.remoteResult ? `${record.remoteResult.remote}: ${record.remoteResult.succeeded ? t("git.execution.remoteSucceeded") : t("git.execution.remoteFailed")}\n${(record.remoteResult.updatedReferences ?? []).join(", ")}\n${(record.remoteResult.deletedReferences ?? []).join(", ")}` : undefined,
          record.output, record.progress, record.error,
          record.truncated ? t("git.console.truncated") : undefined,
        ].filter(Boolean).join("\n")))}>{t("git.console.copy")}</ContextMenuItem>
      </ContextMenuContent>
    </ContextMenu>
  );
}
