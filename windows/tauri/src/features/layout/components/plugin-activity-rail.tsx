import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { toggleMavenPane } from "@/features/keymaps/commands/view-command-actions";
import { useMavenStore } from "@/features/maven/stores/maven.store";
import { NotificationsTrigger } from "@/features/notifications/components/notifications-trigger";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { PackageIcon, PuzzlePieceIcon } from "@/ui/icons";

export function PluginActivityRail() {
  const { t } = useTranslation();
  const openExtensionsBuffer = useBufferStore.use.actions().openExtensionsBuffer;
  const isExtensionsActive = useBufferStore((state) => {
    if (!state.activeBufferId) return false;

    return state.buffers.some(
      (buffer) => buffer.id === state.activeBufferId && buffer.type === "extensions",
    );
  });
  const isMavenAvailable = useMavenStore(
    (state) => Boolean(state.project) || state.projectStatus === "failed",
  );
  const isMavenActive = useUIState(
    (state) => state.isRightSidebarVisible && state.activeRightSidebarView === "maven",
  );
  const activityViewsLabel = t("workbench.activityViews");
  const extensionsLabel = t("extensions.title");
  const mavenLabel = t("workbench.maven");

  return (
    <aside
      aria-label={activityViewsLabel}
      className="lithe-plugin-activity-rail flex w-9.5 shrink-0 flex-col items-center rounded-r-xl border-border border-r bg-surface pt-1"
    >
      <Button
        type="button"
        variant="ghost"
        size="icon-sm"
        active={isExtensionsActive}
        tooltip={extensionsLabel}
        tooltipSide="left"
        aria-label={extensionsLabel}
        aria-pressed={isExtensionsActive}
        className="rounded-sm"
        onClick={openExtensionsBuffer}
      >
        <PuzzlePieceIcon className="size-4.5" />
      </Button>
      <NotificationsTrigger />
      {isMavenAvailable ? (
        <Button
          type="button"
          variant="ghost"
          size="icon-sm"
          active={isMavenActive}
          tooltip={mavenLabel}
          tooltipSide="left"
          aria-label={mavenLabel}
          aria-pressed={isMavenActive}
          className="rounded-sm"
          onClick={toggleMavenPane}
        >
          <PackageIcon className="size-4.5" />
        </Button>
      ) : null}
    </aside>
  );
}
