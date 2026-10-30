import { useEffect, useState } from "react";
import { Spinner } from "@/ui/spinner";
import { Progress } from "@/ui/progress";
import { CaretRightIcon } from "@/ui/icons";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useTranslation } from "@/i18n/locale-provider";
import {
  type BackgroundTask,
  useLanguageServerProgress,
} from "../stores/language-server-progress.store";

/**
 * Java reports short tasks (validating, publishing diagnostics) on every edit;
 * only work still running after this delay reaches the status bar.
 */
export const BACKGROUND_TASK_STATUS_DELAY_MS = 600;

/**
 * Work a ready language server still runs (building, indexing, validating).
 * Tasks have no cancel action: Core does not send
 * `window/workDoneProgress/cancel`, so a button could only hide the task while
 * the server keeps running it.
 */
export function LanguageServerTasksStatus() {
  const root = useFileSystemStore((state) => state.rootFolderPath);
  const tasks = useLanguageServerProgress(root).flatMap((entry) => entry.tasks);
  const { t } = useTranslation();
  const active = tasks.length > 0;
  const [shown, setShown] = useState(false);
  useEffect(() => {
    if (!active) {
      setShown(false);
      return;
    }
    const timer = setTimeout(() => setShown(true), BACKGROUND_TASK_STATUS_DELAY_MS);
    return () => clearTimeout(timer);
  }, [active]);
  if (!active || !shown) return null;
  const [first] = tasks;
  const title = (task: BackgroundTask) =>
    task.title ?? task.message ?? t("backgroundTasks.untitled");
  return (
    <details className="group relative shrink-0 ui-text-sm">
      <summary
        className="flex cursor-pointer list-none items-center gap-1 text-subtle-foreground [&::-webkit-details-marker]:hidden"
        aria-label={t("backgroundTasks.title")}
      >
        <Spinner compact />
        <span className="max-w-56 truncate">{title(first)}</span>
        {first.percent !== undefined ? <span>{first.percent}%</span> : null}
        {tasks.length > 1 ? (
          <span>{t("backgroundTasks.more", { count: tasks.length - 1 })}</span>
        ) : null}
      </summary>
      <div className="absolute bottom-full left-0 z-50 mb-2 w-80 space-y-2 rounded border border-border bg-background p-3 shadow-lg">
        <p className="flex items-center gap-1 font-medium">
          <CaretRightIcon className="size-3 shrink-0 rotate-90" aria-hidden />
          {t("backgroundTasks.title")}
        </p>
        <ul className="space-y-2">
          {tasks.map((task) => (
            <li key={task.token} className="space-y-0.5">
              <div className="flex items-center justify-between gap-2">
                <span className="truncate">{title(task)}</span>
                {task.percent !== undefined ? (
                  <span className="shrink-0 text-subtle-foreground">{task.percent}%</span>
                ) : null}
              </div>
              {task.title && task.message ? (
                <p className="truncate text-subtle-foreground">{task.message}</p>
              ) : null}
              {task.percent !== undefined ? (
                <Progress aria-label={title(task)} value={task.percent} />
              ) : null}
            </li>
          ))}
        </ul>
        <p className="text-subtle-foreground">{t("backgroundTasks.explanation")}</p>
      </div>
    </details>
  );
}
