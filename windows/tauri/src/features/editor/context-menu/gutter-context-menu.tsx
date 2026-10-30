import { EDITOR_CONSTANTS } from "@/features/editor/config/constants";
import { useTranslation } from "@/i18n/locale-provider";
import { Dropdown, type MenuItem } from "@/ui/dropdown";
import { ClockIcon, CopyIcon, GitDiffIcon, UserIcon } from "@/ui/icons";

export interface GutterContextMenuHandlers {
  /** Turns the per-file Git blame annotation on or off; disabled when absent. */
  onToggleBlame?: () => void;
  /** Current annotation state of the file behind the gutter. */
  blameVisible?: boolean;
  /** Opens the diff of the commit that owns the clicked line. */
  onShowDiff?: () => void;
  /** Copies the full revision hash of the clicked line. */
  onCopyRevision?: () => void;
  /** Opens the Git line-history popover for the clicked line. */
  onLineHistory?: () => void;
}

function separator(id: string): MenuItem {
  return { id, label: "", separator: true, onClick: () => {} };
}

/**
 * Right-clicking the gutter answers a question about one line, so it gets the
 * line-level Git actions instead of the full editor menu. The item set and its
 * grouping follow IDEA's annotate menu: the annotation toggle, the commit
 * actions that only exist while annotating, then the line history entry.
 */
export function buildGutterContextMenuItems({
  t,
  onToggleBlame,
  blameVisible = false,
  onShowDiff,
  onCopyRevision,
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
  if (blameVisible && onShowDiff) {
    items.push({
      id: "blame-show-diff",
      label: t("git.blame.showDiff"),
      icon: <GitDiffIcon />,
      onClick: onShowDiff,
    });
  }
  if (blameVisible && onCopyRevision) {
    items.push({
      id: "blame-copy-revision",
      label: t("git.blame.copyRevision"),
      icon: <CopyIcon />,
      onClick: onCopyRevision,
    });
  }
  if (items.length > 0 && onLineHistory) {
    items.push(separator("blame-separator"));
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
