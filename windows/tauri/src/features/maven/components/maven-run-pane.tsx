import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import {
  CheckCircleIcon,
  MinusCircleIcon,
  MinusIcon,
  PackageIcon,
  RefreshIcon,
  StopIcon,
  TrashIcon,
  WarningIcon,
  XCircleIcon,
} from "@/ui/icons";
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
  const testResults = useMavenStore((state) => state.testResults);
  const lastTestRun = useMavenStore((state) => state.lastTestRun);
  const actions = useMavenStore((state) => state.actions);
  const handleFileSelect = useFileSystemStore((state) => state.handleFileSelect);
  const setIsBottomPaneVisible = useUIState((state) => state.setIsBottomPaneVisible);
  const isRunning = taskStatus === "running" || taskStatus === "stopping";
  const canClear =
    output.length > 0 ||
    issues.length > 0 ||
    testResults !== null ||
    lastTestRun !== null ||
    lastExitCode !== null ||
    taskStatus === "cancelled";

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
        <Tooltip content={t("maven.rerunTest")} side="bottom">
          <Button
            variant="ghost"
            size="icon-xs"
            disabled={!lastTestRun || isRunning}
            onClick={() => void actions.rerunLastTest()}
            aria-label={t("maven.rerunTest")}
          >
            <RefreshIcon />
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

      {testResults ? (
        <div className="flex shrink-0 flex-wrap items-center gap-x-4 gap-y-1 border-border/70 border-b px-3 py-2 ui-text-sm">
          <span className="inline-flex items-center gap-1.5 text-success">
            <CheckCircleIcon className="size-3.5" />
            {t("maven.testsPassed", { count: testResults.passed })}
          </span>
          <span className="inline-flex items-center gap-1.5 text-destructive">
            <XCircleIcon className="size-3.5" />
            {t("maven.testsFailed", { count: testResults.failures + testResults.errors })}
          </span>
          <span className="inline-flex items-center gap-1.5 text-warning">
            <MinusCircleIcon className="size-3.5" />
            {t("maven.testsSkipped", { count: testResults.skipped })}
          </span>
          <span className="text-subtle-foreground">
            {t("maven.testsRun", { count: testResults.testsRun })}
          </span>
        </div>
      ) : null}

      <div className="flex min-h-0 flex-1">
        {issues.length > 0 || (testResults?.failureDetails.length ?? 0) > 0 ? (
          <ScrollArea className="w-72 max-w-[38%] shrink-0 border-border/70 border-r bg-sidebar">
            {testResults?.failureDetails.length ? (
              <>
                <div className="border-border/70 border-b px-3 py-2 font-medium text-subtle-foreground ui-text-sm">
                  {t("maven.testFailures")} ({testResults.failureDetails.length})
                </div>
                <div className="border-border/70 border-b py-1">
                  {testResults.failureDetails.map((failure, index) => {
                    const location = failure.path
                      ? `${failure.path}${failure.line ? `:${failure.line}` : ""}${failure.column ? `:${failure.column}` : ""}`
                      : null;
                    return (
                      <button
                        key={`${failure.name}:${index}`}
                        type="button"
                        className="flex w-full items-start gap-2 px-3 py-1.5 text-left hover:bg-hover disabled:cursor-default"
                        onClick={() =>
                          failure.path &&
                          openIssue(failure.path, failure.line ?? 1, failure.column)
                        }
                        disabled={!failure.path}
                      >
                        <XCircleIcon className="mt-0.5 size-3.5 shrink-0 text-destructive" />
                        <span className="min-w-0">
                          <span className="block truncate font-medium ui-text-sm">
                            {failure.name}
                          </span>
                          <span className="block truncate text-subtle-foreground ui-text-sm">
                            {location ?? failure.message ?? t("maven.testLocationUnknown")}
                          </span>
                          {location && failure.message ? (
                            <span className="block truncate text-subtle-foreground ui-text-sm">
                              {failure.message}
                            </span>
                          ) : null}
                        </span>
                      </button>
                    );
                  })}
                </div>
              </>
            ) : null}
            {issues.length > 0 ? (
              <>
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
              </>
            ) : null}
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
