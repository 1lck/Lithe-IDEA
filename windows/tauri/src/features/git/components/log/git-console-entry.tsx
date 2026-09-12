import { useState } from "react";
import { useTranslation } from "@/i18n/locale-provider";
import { gitConsoleCommand, gitConsoleConfiguration, gitConsoleTimestamp, redactConsoleText, type GitConsoleRecord } from "../../services/git-execution-journal";

export function GitConsoleEntry({ record }: { record: GitConsoleRecord }) {
  const { t } = useTranslation();
  const [expandedConfiguration, setExpandedConfiguration] = useState(false);
  const [expandedDetails, setExpandedDetails] = useState(false);
  const configuration = gitConsoleConfiguration(record.temporaryConfig);
  return (
    <div className="mb-1 leading-5">
      <div className="text-info">
        <span>{gitConsoleTimestamp(record.timestamp)}: [{record.root}] git </span>
        {configuration && <>
          <button
            type="button"
            className="rounded-sm bg-success/10 px-1 text-foreground"
            title={t("git.execution.temporary")}
            aria-label={t("git.execution.temporary")}
            aria-expanded={expandedConfiguration}
            onClick={() => setExpandedConfiguration((value) => !value)}
          >{expandedConfiguration ? configuration : "-c …"}</button>{" "}
        </>}
        <span>{record.arguments.length ? gitConsoleCommand(record.arguments).slice(4) : t(`git.console.${record.state}`)}</span>
        {" "}<button type="button" className="px-1 text-subtle-foreground opacity-60 hover:opacity-100"
          title={t("git.console.details")} aria-label={t("git.console.details")} aria-expanded={expandedDetails}
          onClick={() => setExpandedDetails((value) => !value)}>⋯</button>
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
    </div>
  );
}
