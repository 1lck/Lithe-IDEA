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
import AppDialog from "@/ui/dialog";
import { Dropdown } from "@/ui/dropdown";
import { Spinner } from "@/ui/spinner";
import {
  CaretDownIcon,
  ClockIcon,
  DownloadIcon,
  FileTextIcon,
  OpenExternalIcon,
  XCircleIcon,
} from "@/ui/icons";
import { openExternalBrowserUrl } from "@/features/window/utils/external-navigation";
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
    downloadAndInstall,
    remindLater,
    skipVersion,
    viewReleaseNotes,
  } = useUpdater(false);
  const { t } = useTranslation();
  const [isUpdateMenuOpen, setIsUpdateMenuOpen] = useState(false);
  const [isDetailsOpen, setIsDetailsOpen] = useState(false);
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
        onClick={() => void checkForUpdates({ ignoreSuppression: true })}
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
  const openDetails = () => {
    if (updateInfo) {
      setIsDetailsOpen(true);
      return;
    }

    void checkForUpdates({ ignoreSuppression: true });
  };

  return (
    <>
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
                  if (!updateBusy) openDetails();
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
      {isDetailsOpen && updateInfo && (
        <AppDialog
          title={t("update.detailsTitle", { version: updateInfo.targetVersion })}
          icon={DownloadIcon}
          onClose={() => setIsDetailsOpen(false)}
          size="sm"
          footer={
            <>
              <Button
                variant="ghost"
                size="xs"
                onClick={() => {
                  remindLater();
                  setIsDetailsOpen(false);
                }}
              >
                {t("update.downloadLater")}
              </Button>
              <Button
                variant="ghost"
                size="xs"
                onClick={() => {
                  skipVersion();
                  setIsDetailsOpen(false);
                }}
              >
                {t("update.skipVersion", { version: updateInfo.targetVersion })}
              </Button>
              <Button
                variant="accent"
                size="xs"
                onClick={() => {
                  setIsDetailsOpen(false);
                  void downloadAndInstall();
                }}
                disabled={updateBusy}
              >
                {updateError
                  ? t("ui.retry")
                  : t("settings.general.installUpdate", { version: updateInfo.targetVersion })}
              </Button>
            </>
          }
        >
          <div className="flex flex-col gap-4 ui-text-sm">
            <div className="grid grid-cols-2 gap-x-4 gap-y-2 rounded-lg border border-border/70 bg-raised/45 px-3 py-2.5">
              <span className="text-subtle-foreground">{t("update.currentVersion")}</span>
              <span className="text-right font-medium">{updateInfo.currentVersion}</span>
              <span className="text-subtle-foreground">{t("update.targetVersion")}</span>
              <span className="text-right font-medium">{updateInfo.targetVersion}</span>
              {updateInfo.releaseDate && (
                <>
                  <span className="text-subtle-foreground">{t("update.releaseDate")}</span>
                  <span className="text-right">{updateInfo.releaseDate}</span>
                </>
              )}
            </div>
            {updateError ? (
              <p
                role="alert"
                className="rounded-md border border-destructive/25 bg-destructive/10 px-3 py-2 text-destructive"
              >
                {updateError}
              </p>
            ) : null}
            {updateInfo.releaseNotes ? (
              <section className="flex flex-col gap-1.5">
                <h3 className="font-medium text-foreground">{t("update.releaseNotes")}</h3>
                <p className="max-h-52 overflow-y-auto whitespace-pre-wrap text-subtle-foreground">
                  {updateInfo.releaseNotes}
                </p>
              </section>
            ) : null}
            <Button
              variant="ghost"
              size="xs"
              className="self-start"
              onClick={() => void openExternalBrowserUrl(updateInfo.releaseURL)}
            >
              <OpenExternalIcon />
              {t("update.openReleasePage")}
            </Button>
          </div>
        </AppDialog>
      )}
    </>
  );
}
