import { EDITOR_CONSTANTS } from "@/features/editor/config/constants";
import { useTranslation } from "@/i18n/locale-provider";
import { Dropdown, type MenuItem } from "@/ui/dropdown";
import { ClockIcon, UserIcon } from "@/ui/icons";

export interface GutterContextMenuHandlers {
  /** Turns the per-file Git blame annotation on or off; disabled when absent. */
  onToggleBlame?: () => void;
  /** Current annotation state of the file behind the gutter. */
  blameVisible?: boolean;
  /** Opens the Git line-history popover for the clicked line. */
  onLineHistory?: () => void;
}

/**
 * Right-clicking the line numbers answers a question about one line, so it gets
 * the two line-level Git actions instead of the full editor menu. IDEA and the
 * macOS workbench build the same short menu.
 */
export function buildGutterContextMenuItems({
  t,
  onToggleBlame,
  blameVisible = false,
  onLineHistory,
}: GutterContextMenuHandlers & {
  t: (key: string, values?: Record<string, string | number>) => string;
}): MenuItem[] {
  const items: MenuItem[] = [];

  if (onToggleBlame) {
    items.push({
      id: "toggle-blame",
      label: t(blameVisible ? "git.blame.hide" : "git.blame.annotate"),
      icon: <UserIcon />,
      onClick: onToggleBlame,
    });
  }
  if (onLineHistory) {
    items.push({
      id: "line-history",
      label: t("git.lineHistory.menuLabel"),
      icon: <ClockIcon />,
      onClick: onLineHistory,
    });
  }

  return items;
}

interface GutterContextMenuProps extends GutterContextMenuHandlers {
  isOpen: boolean;
  position: { x: number; y: number };
  onClose: () => void;
}

export const GutterContextMenu = ({
  isOpen,
  position,
  onClose,
  ...handlers
}: GutterContextMenuProps) => {
  const { t } = useTranslation();
  if (!isOpen) return null;

  return (
    <Dropdown
      isOpen={isOpen}
      point={position}
      items={buildGutterContextMenuItems({ t, ...handlers })}
      onClose={onClose}
      style={{ zIndex: EDITOR_CONSTANTS.Z_INDEX.CONTEXT_MENU }}
    />
  );
};
