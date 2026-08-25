import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { PuzzlePieceIcon } from "@/ui/icons";

export function PluginActivityRail() {
  const { t } = useTranslation();
  const openExtensionsBuffer = useBufferStore.use.actions().openExtensionsBuffer;
  const isExtensionsActive = useBufferStore((state) => {
    if (!state.activeBufferId) return false;

    return state.buffers.some(
      (buffer) => buffer.id === state.activeBufferId && buffer.type === "extensions",
    );
  });
  const extensionsLabel = t("extensions.title");

  return (
    <aside
      aria-label={extensionsLabel}
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
    </aside>
  );
}
