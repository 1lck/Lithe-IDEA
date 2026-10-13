import { useMemo, useRef, useState } from "react";
import { useUpdater } from "@/features/settings/hooks/use-updater";
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
import { CaretDownIcon, ClockIcon, DownloadIcon, FileTextIcon, XCircleIcon } from "@/ui/icons";
import { cn } from "@/utils/cn";

export function AppUpdateControl({ showWhenIdle = false }: { showWhenIdle?: boolean }) {
  const {
    status,
    checking,
    downloading,
    installing,
    error: updateError,
    updateInfo,
    downloadProgress,
    checkForUpdates,
    openDetails,
    remindLater,
    skipVersion,
    viewReleaseNotes,
  } = useUpdater(false);
  const { t } = useTranslation();
  const [isUpdateMenuOpen, setIsUpdateMenuOpen] = useState(false);
  const updateMenuRef = useRef<HTMLDivElement>(null);
  const updateBusy = downloading || installing;
  const showUpdateIndicator =
    status === "available" ||
    status === "downloading" ||
    status === "installing" ||
    status === "failed";

  const updateMenuItems = useMemo(
    () => [
      {
        id: "release-notes",
        label: t("update.viewReleaseNotes"),
        icon: <FileTextIcon />,
        onClick: viewReleaseNotes,
        disabled: updateBusy || !updateInfo,
      },
      {
        id: "remind-later",
        label: t("update.downloadLater"),
        icon: <ClockIcon />,
        onClick: () => remindLater(),
        disabled: updateBusy || !updateInfo,
      },
      {
        id: "skip-version",
        label: t("update.skipVersion", {
          version: updateInfo?.targetVersion ?? t("update.version"),
        }),
        icon: <XCircleIcon />,
        onClick: skipVersion,
        disabled: updateBusy || !updateInfo,
      },
    ],
    [remindLater, skipVersion, updateBusy, updateInfo, viewReleaseNotes, t],
  );

  if (!showUpdateIndicator) {
    if (!showWhenIdle) return null;

    return (
      <Button
        type="button"
        variant="ghost"
        size="xs"
        tooltip={t("welcome.checkUpdates")}
        tooltipSide="bottom"
        disabled={checking}
        onClick={() => void checkForUpdates({ userInitiated: true })}
        className="font-sans ui-text-sm font-medium text-subtle-foreground"
      >
        {checking ? <Spinner label={t("update.checking")} compact /> : <DownloadIcon />}
        <span>{checking ? t("update.checking") : t("welcome.checkUpdates")}</span>
      </Button>
    );
  }

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
        : t("update.availableVersion", { version: updateInfo?.targetVersion ?? "" });
  const showDetails = () => {
    if (updateInfo) {
      openDetails();
      return;
    }

    void checkForUpdates({ userInitiated: true });
  };

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
                if (!updateBusy) showDetails();
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
