import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuItem,
  ContextMenuTrigger,
} from "@/ui/context-menu";
import { PuzzlePieceIcon } from "@/ui/icons";
import { useUIState } from "@/features/window/stores/ui-state.store";
import { useActiveWorkspaceId } from "@/features/workspace/stores/create-workspace-scoped-store";
import {
  moveNativeContribution,
  nativePlacement,
  nativeSlot,
  nativeTriggerId,
  nativeViewId,
  openNativeContribution,
  useNativeDocking,
  type DockableContribution,
} from "./native-docking";

export function NativeContributionButton({
  entry,
  className,
}: {
  entry: DockableContribution;
  className?: string;
}) {
  const { t } = useTranslation();
  const workspaceId = useActiveWorkspaceId();
  const placements = useNativeDocking((state) => state.placements);
  const placement = nativePlacement(entry, placements);
  const view = nativeViewId(entry);
  const active = useUIState((state) => {
    const slot = nativeSlot(state, placement);
    return slot.visible && slot.view === view;
  });
  return (
    <ContextMenu key={`${workspaceId}:${entry.packageIdentity}`}>
      <ContextMenuTrigger render={<div />}>
        <Button
          id={nativeTriggerId(view)}
          type="button"
          variant="ghost"
          size="icon-sm"
          className={className}
          tooltip={entry.title}
          aria-label={entry.title}
          aria-pressed={active}
          active={active}
          onClick={() => openNativeContribution(entry)}
        >
          <PuzzlePieceIcon className="size-5" />
        </Button>
      </ContextMenuTrigger>
      <ContextMenuContent>
        {(["left", "bottom", "right"] as const).map((position) => (
          <ContextMenuItem
            key={position}
            disabled={position === placement}
            onClick={() => moveNativeContribution(entry, position)}
          >
            {t(`settings.declarativePlugins.placement.${position}`)}
          </ContextMenuItem>
        ))}
      </ContextMenuContent>
    </ContextMenu>
  );
}
