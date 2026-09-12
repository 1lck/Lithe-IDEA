import { useEffect, useRef } from "react";
import { toast } from "sonner";
import { invoke } from "@/platform/tauri-core";
import { useTranslation } from "@/i18n/locale-provider";
import { tryWriteClipboardText } from "@/utils/clipboard";
import { clearGitConsole, useGitConsoleStore } from "../../stores/git-console.store";
import { gitConsoleCommand } from "../../services/git-execution-journal";

export function GitExecutionConsole({ repoPath }: { repoPath: string | null }) {
  const { t } = useTranslation();
  const allRecords = useGitConsoleStore((state) => state.records);
  const active = useGitConsoleStore((state) => state.active);
  const records = allRecords.filter((record) => record.root === repoPath);
  const bottom = useRef<HTMLDivElement>(null);
  const scroll = useRef<HTMLDivElement>(null);
  const followsOutput = useRef(true);
  useEffect(() => { if (followsOutput.current) bottom.current?.scrollIntoView({ block: "end" }); }, [allRecords, repoPath]);
  const operations = [...active].filter(([, root]) => root === repoPath);
  return <div className="flex min-h-0 flex-1 flex-col font-mono text-xs">
    <div className="flex shrink-0 gap-4 border-b px-3 py-2">
      <button disabled={!operations.length} onClick={() => {
        for (const [id] of operations) void invoke("core_cancel", { operationId: id })
          .catch((error: unknown) => toast.error(String(error)));
      }}>{t("git.console.cancel")}</button>
      <button disabled={!records.length} onClick={() => repoPath && clearGitConsole(repoPath)}>{t("git.console.clear")}</button>
      <button disabled={!records.length} onClick={() => void tryWriteClipboardText(records.map((record) => [
        `[${record.root}] ${record.arguments.length ? gitConsoleCommand(record.arguments) : record.action}`,
        `${t(`git.console.${record.state}`)}${record.durationMilliseconds == null ? "" : ` · ${record.durationMilliseconds} ms`}${record.exitCode == null ? "" : ` · ${t("git.console.exit")} ${record.exitCode}`}`,
        record.output,
        record.progress,
        record.truncated ? t("git.console.truncated") : undefined,
        record.error,
      ].filter(Boolean).join("\n")).join("\n\n"))}>{t("git.console.copy")}</button>
    </div>
    <div ref={scroll} className="min-h-0 flex-1 overflow-auto p-3" onScroll={() => { const node = scroll.current; if (node) followsOutput.current = node.scrollHeight - node.scrollTop - node.clientHeight < 32; }}>
      {!records.length && <p className="text-subtle-foreground">{t("git.console.empty")}</p>}
      {records.map((record) => <div key={record.id} className="mb-4 whitespace-pre-wrap break-words">
        <p className="text-subtle-foreground">{t(`git.console.${record.state}`)}{record.durationMilliseconds == null ? "" : ` · ${record.durationMilliseconds} ms`}{record.exitCode == null ? "" : ` · ${t("git.console.exit")} ${record.exitCode}`}</p>
        <p className="text-primary">[{record.root}] {record.arguments.length ? gitConsoleCommand(record.arguments) : record.action}</p>
        <pre className="whitespace-pre-wrap">{record.output}</pre>
        {record.progress && <p className="text-subtle-foreground">{record.progress}</p>}
        {record.truncated && <p className="text-subtle-foreground">{t("git.console.truncated")}</p>}
        {record.error && <p className="text-destructive">{record.error}</p>}
      </div>)}
      <div ref={bottom} />
    </div>
  </div>;
}
