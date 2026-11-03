import { Spinner } from "@/ui/spinner";
import { Progress } from "@/ui/progress";
import { CaretRightIcon, CheckCircleIcon, WarningIcon } from "@/ui/icons";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { useTranslation } from "@/i18n/locale-provider";
import { useProjectPreparation } from "../stores/project-preparation.store";
import { useLanguageServerProgress } from "../stores/language-server-progress.store";
import { runWorkspacePreferenceKey, useRunPreferencesStore } from "../stores/run-preferences.store";

/** The footer is compact; the Run panel retains the current stage and recovery entry. */
export function ProjectPreparationStatus({ compact = false }: { compact?: boolean }) {
  const root = useFileSystemStore((state) => state.rootFolderPath);
  const preparation = useProjectPreparation(root);
  const { t } = useTranslation();
  const openSettings = useUIState((state) => state.openSettingsDialog);
  const javaBuildFailurePolicy = useRunPreferencesStore((state) =>
    root
      ? (state.javaBuildFailurePolicyByWorkspace[runWorkspacePreferenceKey(root)] ?? "ask")
      : "ask",
  );
  const setJavaBuildFailurePolicy = useRunPreferencesStore(
    (state) => state.actions.setJavaBuildFailurePolicy,
  );
  const importProgress = useLanguageServerProgress(root).find(
    (entry) => entry.languageId === "java" && entry.importProgress,
  )?.importProgress;
  if (!preparation || preparation.phase === "stopped") return null;
  if (compact && preparation.status === "ready") return null;
  const importing = preparation.status === "loading" ? importProgress : undefined;
  const label =
    preparation.status === "failed"
      ? t("preparation.failed")
      : importing?.percent !== undefined
        ? t("preparation.importingPercent", { percent: importing.percent })
        : t(`preparation.${preparation.phase}`);
  return (
    <details
      className={
        compact
          ? "group relative shrink-0 ui-text-sm"
          : "group border-border border-b px-3 py-2 ui-text-sm"
      }
    >
      <summary
        className="flex cursor-pointer list-none items-center gap-1 [&::-webkit-details-marker]:hidden"
        aria-live="polite"
      >
        <CaretRightIcon className="size-3 shrink-0 text-subtle-foreground group-open:rotate-90" />
        <span
          className={
            preparation.status === "failed"
              ? "flex items-center gap-1 text-destructive"
              : "flex items-center gap-1 text-subtle-foreground"
          }
        >
          {preparation.status === "loading" ? (
            <Spinner compact />
          ) : preparation.status === "failed" ? (
            <WarningIcon className="size-3.5 shrink-0" aria-hidden />
          ) : (
            <CheckCircleIcon className="size-3.5 shrink-0" aria-hidden />
          )}
          {label}
        </span>
        {compact && importing?.percent !== undefined ? (
          <Progress aria-hidden value={importing.percent} className="w-16 shrink-0" />
        ) : null}
      </summary>
      <div
        className={
          compact
            ? "absolute bottom-full left-0 z-50 mb-2 w-80 rounded border border-border bg-background p-3 shadow-lg"
            : "space-y-2 pt-2"
        }
      >
        <ol className="space-y-1">
          {(["starting", "importing", "configuring", "building"] as const).map((phase) => (
            <li
              key={phase}
              className={
                preparation.phase === phase
                  ? "flex items-center gap-1 font-medium"
                  : "flex items-center gap-1 text-subtle-foreground"
              }
            >
              <CaretRightIcon
                className={`size-3 shrink-0 ${preparation.phase === phase ? "" : "invisible"}`}
                aria-hidden
              />
              {t(`preparation.${phase}`)}
            </li>
          ))}
        </ol>
        {importing ? (
          <div className="space-y-1">
            {importing.currentProject ? (
              <p className="truncate">
                {t("preparation.currentProject", { name: importing.currentProject })}
              </p>
            ) : null}
            {importing.downloadArtifact ? (
              <p className="truncate text-subtle-foreground">
                {t("preparation.downloading", { artifact: importing.downloadArtifact })}
              </p>
            ) : null}
            {importing.percent !== undefined ? (
              <Progress aria-label={label} value={importing.percent} />
            ) : null}
          </div>
        ) : null}
        <p className="text-subtle-foreground">{t("preparation.explanation")}</p>
        <button type="button" className="mt-2 underline" onClick={() => openSettings("language")}>
          {t("preparation.settings")}
        </button>
        <button type="button" className="ml-3 underline" onClick={() => openSettings("logs")}>
          {t("preparation.logs")}
        </button>
        {root && javaBuildFailurePolicy === "alwaysProceed" ? (
          <div className="mt-2 border-warning/30 border-t pt-2 text-subtle-foreground">
            <p>{t("run.javaBuildAlwaysContinueEnabled")}</p>
            <button
              type="button"
              className="mt-1 underline"
              onClick={() => setJavaBuildFailurePolicy(root, "ask")}
            >
              {t("run.javaBuildAskAgain")}
            </button>
          </div>
        ) : null}
      </div>
    </details>
  );
}
