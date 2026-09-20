import { Spinner } from "@/ui/spinner";
import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { useTranslation } from "@/i18n/locale-provider";
import { useProjectPreparation } from "../stores/project-preparation.store";

/** The footer is compact; the Run panel retains the current stage and recovery entry. */
export function ProjectPreparationStatus({ compact = false }: { compact?: boolean }) {
  const root = useFileSystemStore((state) => state.rootFolderPath);
  const preparation = useProjectPreparation(root);
  const { t } = useTranslation();
  const openSettings = useUIState((state) => state.openSettingsDialog);
  if (!preparation || preparation.phase === "stopped") return null;
  if (compact && preparation.status === "ready") return null;
  const label =
    preparation.status === "failed"
      ? t("preparation.failed")
      : t(`preparation.${preparation.phase}`);
  return (
    <details
      className={
        compact ? "relative shrink-0 ui-text-sm" : "border-border border-b px-3 py-2 ui-text-sm"
      }
    >
      <summary className="cursor-pointer" aria-live="polite">
        <span
          className={
            preparation.status === "failed" ? "text-destructive" : "text-subtle-foreground"
          }
        >
          {preparation.status === "loading" ? (
            <Spinner compact className="mr-1" />
          ) : preparation.status === "failed" ? (
            "! "
          ) : (
            "✓ "
          )}
          {label}
        </span>
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
              className={preparation.phase === phase ? "font-medium" : "text-subtle-foreground"}
            >
              {preparation.phase === phase ? "› " : "· "}
              {t(`preparation.${phase}`)}
            </li>
          ))}
        </ol>
        <p className="text-subtle-foreground">{t("preparation.explanation")}</p>
        <button type="button" className="mt-2 underline" onClick={() => openSettings("language")}>
          {t("preparation.settings")}
        </button>
        <button type="button" className="ml-3 underline" onClick={() => openSettings("logs")}>
          {t("preparation.logs")}
        </button>
      </div>
    </details>
  );
}
