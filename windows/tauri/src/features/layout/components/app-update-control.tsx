import { useMemo, useRef, useState } from "react";
import { useAutoUpdate } from "@/features/settings/hooks/use-auto-update";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { ButtonGroup, ButtonGroupSeparator } from "@/ui/button-group";
import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuItem,
  ContextMenuTrigger,
} from "@/ui/context-menu";
import { Dropdown } from "@/ui/dropdown";
import { Spinner } from "@/ui/spinner";
import {
  CalendarIcon,
  CaretDownIcon,
  ClockIcon,
  DownloadIcon,
  FileTextIcon,
  XCircleIcon,
} from "@/ui/icons";
import { cn } from "@/utils/cn";

export function AppUpdateControl() {
  const {
    showUpdateIndicator,
    downloading,
    installing,
    error: updateError,
    updateInfo,
    downloadProgress,
    onDownload: downloadAndInstall,
    onDismiss: dismissUpdate,
    onRemindLater,
    onSkipVersion,
    onViewReleaseNotes,
  } = useAutoUpdate();
  const { t } = useTranslation();
  const [isUpdateMenuOpen, setIsUpdateMenuOpen] = useState(false);
  const updateMenuRef = useRef<HTMLDivElement>(null);
  const updateBusy = downloading || installing;

  const updateMenuItems = useMemo(
    () => [
      {
        id: "release-notes",
        label: t("update.viewReleaseNotes"),
        icon: <FileTextIcon />,
        onClick: onViewReleaseNotes,
        disabled: updateBusy,
      },
      {
        id: "download-later",
        label: t("update.downloadLater"),
        icon: <ClockIcon />,
        onClick: dismissUpdate,
        disabled: updateBusy,
      },
      {
        id: "remind-later",
        label: t("update.remindTomorrow"),
        icon: <CalendarIcon />,
        onClick: onRemindLater,
        disabled: updateBusy,
      },
      {
        id: "skip-version",
        label: t("update.skipVersion", { version: updateInfo?.version ?? t("update.version") }),
        icon: <XCircleIcon />,
        onClick: onSkipVersion,
        disabled: updateBusy,
      },
    ],
    [
      dismissUpdate,
      onRemindLater,
      onSkipVersion,
      onViewReleaseNotes,
      updateBusy,
      updateInfo?.version,
      t,
    ],
  );

  if (!showUpdateIndicator || !updateInfo) return null;

  const updateLabel = downloading
    ? `${downloadProgress?.percentage ?? 0}%`
    : installing
      ? t("update.installing")
      : updateError
        ? t("update.failed")
        : t("update.available");
  const updateTooltip = updateError
    ? updateError
    : downloading
      ? t("update.updatingProgress", { percentage: downloadProgress?.percentage ?? 0 })
      : installing
        ? t("update.installingTooltip")
        : t("update.availableVersion", { version: updateInfo.version });

  return (
    <div className="ml-3 flex items-center">
      <ContextMenu>
        <ContextMenuTrigger
          className="contents"
          onContextMenu={(event) => {
            event.stopPropagation();
            setIsUpdateMenuOpen(false);
          }}
        >
          <ButtonGroup
            ref={updateMenuRef}
            variant="accent"
            className={
              updateError
                ? "border-destructive/25 bg-destructive/10 *:data-[slot=button-group-separator]:bg-destructive/25"
                : undefined
            }
          >
            <Button
              type="button"
              variant="ghost"
              size="xs"
              tooltip={updateTooltip}
              tooltipSide="bottom"
              disabled={updateBusy}
              onClick={() => {
                if (!updateBusy) {
                  void downloadAndInstall();
                }
              }}
              className={cn(
                "font-sans ui-text-sm font-medium",
                updateError && "text-destructive hover:bg-destructive/10 hover:text-destructive",
                updateBusy &&
                  "cursor-wait bg-primary/15 text-primary hover:bg-primary/20 hover:text-primary",
              )}
            >
              {updateBusy ? (
                <Spinner
                  label={downloading ? t("update.downloading") : t("update.installing")}
                  compact
                />
              ) : (
                <DownloadIcon />
              )}
              <span>{updateLabel}</span>
            </Button>
            <ButtonGroupSeparator />
            <Button
              type="button"
              variant="ghost"
              size="icon-xs"
              active={isUpdateMenuOpen}
              tooltip={t("update.options")}
              tooltipSide="bottom"
              onClick={() => setIsUpdateMenuOpen((open) => !open)}
              className={
                updateError
                  ? "text-destructive hover:bg-destructive/10 hover:text-destructive"
                  : undefined
              }
              aria-label={t("update.options")}
              aria-haspopup="menu"
              aria-expanded={isUpdateMenuOpen}
            >
              <CaretDownIcon />
            </Button>
          </ButtonGroup>
        </ContextMenuTrigger>
        <ContextMenuContent side="bottom" align="start" sideOffset={4} className="min-w-52">
          {updateMenuItems.map((item) => (
            <ContextMenuItem key={item.id} disabled={item.disabled} onClick={item.onClick}>
              {item.icon}
              {item.label}
            </ContextMenuItem>
          ))}
        </ContextMenuContent>
      </ContextMenu>
      <Dropdown
        isOpen={isUpdateMenuOpen}
        onClose={() => setIsUpdateMenuOpen(false)}
        anchorRef={updateMenuRef}
        anchorSide="bottom"
        anchorAlign="end"
        items={updateMenuItems}
        className="min-w-52"
      />
    </div>
  );
}
