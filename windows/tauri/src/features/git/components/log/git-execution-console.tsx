import { useEffect, useRef, useState } from "react";
import { toast } from "sonner";
import { invoke } from "@/platform/tauri-core";
import { useTranslation } from "@/i18n/locale-provider";
import { tryWriteClipboardText } from "@/utils/clipboard";
import { clearGitConsole, useGitConsoleStore } from "../../stores/git-console.store";
import { gitConsoleCommand, gitConsoleConfiguration, gitConsoleTimestamp, redactConsoleText, sameGitRoot } from "../../services/git-execution-journal";

import { GitConsoleEntry } from "./git-console-entry";

export function GitExecutionConsole({ repoPath }: { repoPath: string | null }) {
  const { t } = useTranslation();
  const [wrapsLines, setWrapsLines] = useState(false);
  const allRecords = useGitConsoleStore((state) => state.records);
  const active = useGitConsoleStore((state) => state.active);
  const records = allRecords.filter((record) => sameGitRoot(record.root, repoPath));
  const bottom = useRef<HTMLDivElement>(null);
  const scroll = useRef<HTMLDivElement>(null);
  const followsOutput = useRef(true);
  useEffect(() => { if (followsOutput.current) bottom.current?.scrollIntoView({ block: "end" }); }, [allRecords, repoPath]);
  const operations = [...active].filter(([, root]) => sameGitRoot(root, repoPath));
  return <div className="flex min-h-0 flex-1 flex-col font-mono text-xs">
    <div className="flex shrink-0 flex-wrap gap-x-4 gap-y-2 border-b px-3 py-2">
      <button aria-pressed={wrapsLines} onClick={() => setWrapsLines((value) => !value)}>{t("git.console.wrap")}</button>
      <button onClick={() => { followsOutput.current = true; bottom.current?.scrollIntoView({ block: "end" }); }}>{t("git.console.scrollToEnd")}</button>
      <button disabled={!operations.length} onClick={() => {
        for (const [id] of operations) void invoke("core_cancel", { operationId: id })
          .catch((error: unknown) => toast.error(String(error)));
      }}>{t("git.console.cancel")}</button>
      <button disabled={!records.length} onClick={() => repoPath && clearGitConsole(repoPath)}>{t("git.console.clear")}</button>
      <button disabled={!records.length} onClick={() => void tryWriteClipboardText(redactConsoleText(records.map((record) => [
        `${gitConsoleTimestamp(record.timestamp)}: [${record.root}] git ${gitConsoleConfiguration(record.temporaryConfig)} ${record.arguments.length ? gitConsoleCommand(record.arguments).slice(4) : t(`git.console.${record.state}`)}`,
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
    <div ref={scroll} className="min-h-0 flex-1 overflow-auto p-3" onScroll={() => { const node = scroll.current; if (node) followsOutput.current = node.scrollHeight - node.scrollTop - node.clientHeight < 32; }}>
      {!records.length && <p className="text-subtle-foreground">{t("git.console.empty")}</p>}
      <div className={wrapsLines ? "whitespace-pre-wrap break-words" : "w-max min-w-full whitespace-pre"}>
        {records.map((record) => <GitConsoleEntry key={record.id} record={record} />)}
      </div>
      <div ref={bottom} />
    </div>
  </div>;
}
