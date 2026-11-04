import { useFileSystemStore } from "@/features/file-system/stores/file-system.store";
import { ProjectPreparationStatus } from "@/features/run/components/project-preparation-status";
import { useProjectPreparation } from "@/features/run/stores/project-preparation.store";
import { useRunStore } from "@/features/run/stores/run.store";
import { useTranslation } from "@/i18n/locale-provider";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { MinusIcon, WrenchIcon } from "@/ui/icons";
import { Spinner } from "@/ui/spinner";
import Tooltip from "@/ui/tooltip";

/** Explains when the Java entries shown are not JDT's current answer. */
function JavaDiscoveryNotice() {
  const status = useRunStore((state) => state.javaDiscovery);
  const message = useRunStore((state) => state.javaDiscoveryMessage);
  const { t } = useTranslation();
  if (status === "idle" || status === "ready") return null;
  return (
    <div className="flex items-center gap-1 px-3 py-1.5 ui-text-sm" aria-live="polite">
      {status === "failed" ? (
        <span className="text-destructive">
          {t("run.javaDiscoveryFailed", { message: message ?? "" })}
        </span>
      ) : (
        <>
          <Spinner compact />
          <span className="text-subtle-foreground">
            {t(status === "stale" ? "run.javaDiscoveryStale" : "run.javaDiscoveryLoading")}
          </span>
        </>
      )}
    </div>
  );
}

/**
 * Build tool window. Import progress and Java discovery used to be stacked on
 * top of the Run panel, where every extra row pushed the run configurations
 * down. They own this panel instead, so Run keeps its full height.
 */
export default function BuildPane() {
  const { t } = useTranslation();
  const root = useFileSystemStore((state) => state.rootFolderPath);
  const preparation = useProjectPreparation(root);
  const javaDiscovery = useRunStore((state) => state.javaDiscovery);
  const setIsBottomPaneVisible = useUIState((state) => state.setIsBottomPaneVisible);
  const hasActivity =
    (preparation !== undefined && preparation.phase !== "stopped") ||
    (javaDiscovery !== "idle" && javaDiscovery !== "ready");

  return (
    <div className="flex h-full min-h-0 flex-col bg-background">
      <div className="flex h-(--lithe-pane-header-height) shrink-0 items-center gap-2 border-border/70 border-b px-3">
        <WrenchIcon className="size-4 text-subtle-foreground" />
        <div className="min-w-0 flex-1 truncate font-medium ui-text-sm">{t("build.title")}</div>
        <Tooltip content={t("layout.hideBottomPane")}>
          <button
            type="button"
            aria-label={t("layout.hideBottomPane")}
            className="rounded p-1 hover:bg-hover"
            onClick={() => setIsBottomPaneVisible(false)}
          >
            <MinusIcon className="size-4" />
          </button>
        </Tooltip>
      </div>
      <div className="min-h-0 flex-1 overflow-auto">
        <ProjectPreparationStatus />
        <JavaDiscoveryNotice />
        {hasActivity ? null : (
          <p className="px-3 py-2 text-subtle-foreground ui-text-sm">{t("build.idle")}</p>
        )}
      </div>
    </div>
  );
}
