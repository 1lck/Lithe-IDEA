import { useUpdater } from "@/features/settings/hooks/use-updater";
import { openExternalBrowserUrl } from "@/features/window/utils/external-navigation";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import AppDialog from "@/ui/dialog";
import { DownloadIcon, OpenExternalIcon } from "@/ui/icons";

/**
 * The single update details dialog for a window. The title bar, the Welcome
 * control and user-initiated checks all open it through the update store, so
 * an update found by a menu check can be installed without first locating the
 * title bar indicator.
 */
export function AppUpdateDetailsDialog() {
  const {
    detailsOpen,
    updateInfo,
    error: updateError,
    downloading,
    installing,
    closeDetails,
    downloadAndInstall,
    remindLater,
    skipVersion,
  } = useUpdater(false);
  const { t } = useTranslation();
  const updateBusy = downloading || installing;

  if (!detailsOpen || !updateInfo) return null;

  return (
    <AppDialog
      title={t("update.detailsTitle", { version: updateInfo.targetVersion })}
      icon={DownloadIcon}
      onClose={closeDetails}
      size="sm"
      footer={
        <>
          <Button
            variant="ghost"
            size="xs"
            onClick={() => remindLater()}
          >
            {t("update.downloadLater")}
          </Button>
          <Button
            variant="ghost"
            size="xs"
            onClick={() => skipVersion()}
          >
            {t("update.skipVersion", { version: updateInfo.targetVersion })}
          </Button>
          <Button
            variant="accent"
            size="xs"
            onClick={() => {
              // Close first: saving unsaved buffers before the restart may
              // open its own dialog.
              closeDetails();
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
  );
}
