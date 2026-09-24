import { EDITOR_CONSTANTS } from "@/features/editor/config/constants";
import Keybinding from "@/features/keymaps/components/keybinding";
import type { JavaRunMarker } from "@/features/run/services/java-run-markers";
import { useTranslation } from "@/i18n/locale-provider";
import { Dropdown, type MenuItem } from "@/ui/dropdown";
import { PencilLineIcon as PenLine, PlayIcon as Play } from "@/ui/icons";

interface JavaRunMarkerMenuProps {
  marker: JavaRunMarker;
  position: { x: number; y: number };
  onRun: () => void;
  /** Present when the marker's configuration can be opened for editing. */
  onEditConfiguration?: () => void;
  onClose: () => void;
}

/**
 * The popup IDEA shows for a gutter Run icon. Debug is not offered on Windows
 * until the Debug tool window is generally available there.
 */
export function JavaRunMarkerMenu({
  marker,
  position,
  onRun,
  onEditConfiguration,
  onClose,
}: JavaRunMarkerMenuProps) {
  const { t } = useTranslation();
  const items: MenuItem[] = [
    {
      id: "run-marker",
      label: t("run.runTarget", { target: marker.label }),
      icon: <Play />,
      keybinding: <Keybinding keys={["Ctrl", "Shift", "F10"]} className="opacity-60" />,
      onClick: onRun,
    },
    ...(onEditConfiguration
      ? [
          { id: "run-marker-separator", label: "", separator: true, onClick: () => {} },
          {
            id: "run-marker-edit",
            label: t("run.modifyRunConfiguration"),
            icon: <PenLine />,
            onClick: onEditConfiguration,
          },
        ]
      : []),
  ];
  return (
    <Dropdown
      isOpen
      point={position}
      items={items}
      onClose={onClose}
      style={{ zIndex: EDITOR_CONSTANTS.Z_INDEX.CONTEXT_MENU }}
    />
  );
}
