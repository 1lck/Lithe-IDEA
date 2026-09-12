import { useState } from "react";
import { ContextMenu, ContextMenuContent, ContextMenuItem, ContextMenuTrigger } from "@/ui/context-menu";
import { tryWriteClipboardText } from "@/utils/clipboard";
import { useTranslation } from "@/i18n/locale-provider";
import { gitConsoleCommand, gitConsoleConfiguration, gitConsoleTimestamp, redactConsoleText, type GitConsoleRecord } from "../../services/git-execution-journal";

export function GitConsoleEntry({ record }: { record: GitConsoleRecord }) {
  const { t } = useTranslation();
  const [expandedConfiguration, setExpandedConfiguration] = useState(false);
  const [expandedDetails, setExpandedDetails] = useState(false);
  const configuration = record.globalArguments ? gitConsoleCommand(record.globalArguments).slice(4) : gitConsoleConfiguration(record.temporaryConfig);
  const arguments_ = record.displayArguments ?? record.arguments;
  return (
    <ContextMenu>
      <ContextMenuTrigger className="mb-1 leading-5" tabIndex={0}>
        <div className="text-info">
          <span>{gitConsoleTimestamp(record.timestamp)}: [{record.root}] git </span>
          {configuration && <>
            <button
              type="button"
              className="rounded-sm bg-success/10 px-1 text-foreground"
              title={t("git.console.options")}
              aria-label={t("git.console.options")}
              aria-expanded={expandedConfiguration}
              onClick={() => setExpandedConfiguration((value) => !value)}
            >{expandedConfiguration ? configuration : "-c …"}</button>{" "}
          </>}
          <span>{arguments_.length ? gitConsoleCommand(arguments_).slice(4) : t(`git.console.${record.state}`)}</span>
        </div>
        {record.lines.map((line, index) => (
          <div key={index} className={line.stream === "stderr" ? "text-destructive" : "text-foreground"}>{line.text || "\u00a0"}</div>
        ))}
        {record.progress && <div className="text-subtle-foreground">{record.progress}</div>}
        {record.truncated && <div className="text-subtle-foreground">{t("git.console.truncated")}</div>}
        {record.error && <div className="text-destructive">{redactConsoleText(record.error)}</div>}
        {record.state === "unconfirmed" && <div className="text-destructive">{t("git.console.unconfirmed")}</div>}
        {record.state === "completed" && record.exitCode !== 0 && <div className="text-destructive">{t("git.console.exit")} {record.exitCode}</div>}
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
        <ContextMenuItem onClick={() => setExpandedDetails((value) => !value)}>{t("git.console.details")}</ContextMenuItem>
        <ContextMenuItem onClick={() => void tryWriteClipboardText(redactConsoleText([
          `${gitConsoleTimestamp(record.timestamp)}: [${record.root}] ${gitConsoleCommand(record.arguments)}`,
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
