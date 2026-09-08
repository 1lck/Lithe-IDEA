import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { MinusIcon, PackageIcon, StopIcon, TrashIcon, WarningIcon } from "@/ui/icons";
import { ScrollArea } from "@/ui/scroll-area";
import Tooltip from "@/ui/tooltip";
import { cn } from "@/utils/cn";
import { joinPath } from "@/utils/path-helpers";
import { RunOutputText } from "@/features/run/components/run-output-text";
import { useMavenStore } from "../stores/maven.store";

export default function MavenRunPane() {
  const { t } = useTranslation();
  const root = useMavenStore((state) => state.root);
  const taskStatus = useMavenStore((state) => state.taskStatus);
  const taskError = useMavenStore((state) => state.taskError);
  const taskTitle = useMavenStore((state) => state.taskTitle);
  const output = useMavenStore((state) => state.output);
  const issues = useMavenStore((state) => state.issues);
  const lastExitCode = useMavenStore((state) => state.lastExitCode);
  const actions = useMavenStore((state) => state.actions);
  const handleFileSelect = useFileSystemStore((state) => state.handleFileSelect);
  const setIsBottomPaneVisible = useUIState((state) => state.setIsBottomPaneVisible);
  const isRunning = taskStatus === "running" || taskStatus === "stopping";
  const canClear =
    output.length > 0 || issues.length > 0 || lastExitCode !== null || taskStatus === "cancelled";

  const openIssue = (path: string, line: number, column?: number | null) => {
    if (!root || !path) return;
    const target = /^(?:[A-Za-z]:[\\/]|[\\/]{2}|\/)/.test(path) ? path : joinPath(root, path);
    void handleFileSelect(target, false, line, column ?? undefined, undefined, false);
  };

  return (
    <section
      aria-label={`${t("run.title")} - ${t("maven.title")}`}
      className="flex h-full min-h-0 flex-col bg-background"
    >
      <div className="flex h-(--lithe-pane-header-height) shrink-0 items-center gap-2 border-border/70 border-b px-3">
        <PackageIcon className="size-4 shrink-0 text-primary" />
        <div className="min-w-0 flex-1 truncate font-medium ui-text-sm">
          {t("run.title")} - {t("maven.title")}
          {taskTitle ? ` - ${taskTitle}` : ""}
        </div>
        <div aria-live="polite" className="shrink-0">
          {isRunning ? (
            <span className="text-success ui-text-sm">{t("run.running")}</span>
          ) : taskStatus === "cancelled" ? (
            <span className="text-warning ui-text-sm">{t("maven.cancelled")}</span>
          ) : lastExitCode !== null ? (
            <span
              className={cn("ui-text-sm", lastExitCode === 0 ? "text-success" : "text-destructive")}
            >
              {lastExitCode === 0 ? t("run.succeeded") : t("run.failed")}
            </span>
          ) : null}
        </div>
        <Tooltip content={t("maven.stop")} side="bottom">
          <Button
            variant="ghost"
            size="icon-xs"
            disabled={!isRunning || taskStatus === "stopping"}
            onClick={() => void actions.stop()}
            aria-label={t("maven.stop")}
          >
            <StopIcon className="text-warning" />
          </Button>
        </Tooltip>
        <Tooltip content={t("maven.clearOutput")} side="bottom">
          <Button
            variant="ghost"
            size="icon-xs"
            disabled={!canClear}
            onClick={actions.clearOutput}
            aria-label={t("maven.clearOutput")}
          >
            <TrashIcon />
          </Button>
        </Tooltip>
        <Tooltip content={t("run.minimize")} side="bottom">
          <Button
            variant="ghost"
            size="icon-xs"
            onClick={() => setIsBottomPaneVisible(false)}
            aria-label={t("run.minimize")}
          >
            <MinusIcon />
          </Button>
        </Tooltip>
      </div>

      {taskError ? (
        <div
          role="alert"
          className="flex shrink-0 items-start gap-2 border-warning/30 border-b bg-warning/10 px-3 py-2"
        >
          <WarningIcon className="mt-0.5 size-3.5 shrink-0 text-warning" />
          <span className="min-w-0 flex-1 ui-text-sm">{taskError}</span>
        </div>
      ) : null}

      <div className="flex min-h-0 flex-1">
        {issues.length > 0 ? (
          <ScrollArea className="w-72 max-w-[38%] shrink-0 border-border/70 border-r bg-sidebar">
            <div className="border-border/70 border-b px-3 py-2 font-medium text-subtle-foreground ui-text-sm">
              {t("maven.buildOutput")} ({issues.length})
            </div>
            <div className="py-1">
              {issues.map((issue, index) => (
                <button
                  key={`${issue.path}:${issue.line}:${index}`}
                  type="button"
                  className="flex w-full items-start gap-2 px-3 py-1.5 text-left hover:bg-hover disabled:cursor-default"
                  onClick={() => openIssue(issue.path, issue.line, issue.column)}
                  disabled={!issue.path}
                >
                  <WarningIcon
                    className={cn(
                      "mt-0.5 size-3.5 shrink-0",
                      issue.severity === "error" ? "text-destructive" : "text-warning",
                    )}
                  />
                  <span className="min-w-0">
                    <span className="block truncate font-medium ui-text-sm">
                      {issue.path
                        ? `${issue.path}:${issue.line}${issue.column ? `:${issue.column}` : ""}`
                        : t("maven.buildOutput")}
                    </span>
                    <span className="block truncate text-subtle-foreground ui-text-sm">
                      {issue.message}
                    </span>
                  </span>
                </button>
              ))}
            </div>
          </ScrollArea>
        ) : null}
        <ScrollArea className="min-w-0 flex-1" orientation="both">
          <div className="min-h-full p-3">
            <RunOutputText
              source={output}
              title={t("maven.processOutput")}
              emptyLabel={t("maven.emptyOutput")}
            />
          </div>
        </ScrollArea>
      </div>
    </section>
  );
}
