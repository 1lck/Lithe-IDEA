import { getVersion } from "@tauri-apps/api/app";
import { invoke } from "@/platform/tauri-core";
import { useEffect, useMemo, useRef, useState } from "react";
import { IdeSettingsImportDialog } from "@/features/file-system/components/ide-settings-import-dialog";
import { useToast } from "@/features/layout/contexts/toast-context";
import { TypedConfirmAction } from "@/features/settings/components/typed-confirm-action";
import { useUpdater } from "@/features/settings/hooks/use-updater";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import Command, {
  CommandEmpty,
  CommandHeader,
  CommandInput,
  CommandItemRow,
  CommandList,
} from "@/ui/command";
import { Progress } from "@/ui/progress";
import Select from "@/ui/select";
import { writeClipboardText } from "@/utils/clipboard";
import { matchesSearchQuery } from "@/utils/search-match";
import { SETTINGS_CONTROL_WIDTHS, SettingsView, SettingRow } from "../settings-section";

const REPORT_BUG_CHANNELS = [
  {
    id: "github",
    label: "GitHub",
    detailKey: "settings.general.githubReportDescription",
    url: "https://github.com/1lck/Lithe-IDEA/issues/new",
  },
] as const;

type ReportBugChannel = (typeof REPORT_BUG_CHANNELS)[number];

export const GeneralSettings = () => {
  const displayLanguage = useSettingsStore((state) => state.settings.displayLanguage);
  const updateSetting = useSettingsStore((state) => state.actions.updateSetting);
  const { t } = useTranslation();
  const {
    available,
    checking,
    downloading,
    installing,
    error,
    updateInfo,
    downloadProgress,
    checkForUpdates,
    downloadAndInstall,
  } = useUpdater(false);
  const { showToast } = useToast();

  const [cliInstalled, setCliInstalled] = useState<boolean>(false);
  const [cliChecking, setCliChecking] = useState(true);
  const [cliInstalling, setCliInstalling] = useState(false);
  const [appVersion, setAppVersion] = useState<string>("");
  const [isImportDialogOpen, setIsImportDialogOpen] = useState(false);
  const [isReportBugDialogOpen, setIsReportBugDialogOpen] = useState(false);

  useEffect(() => {
    const checkCliStatus = async () => {
      try {
        const installed = await invoke<boolean>("check_cli_installed");
        setCliInstalled(installed);
      } catch (error) {
        console.error("Failed to check CLI status:", error);
      } finally {
        setCliChecking(false);
      }
    };

    checkCliStatus();
  }, []);

  useEffect(() => {
    getVersion().then(setAppVersion);
  }, []);

  const handleInstallCli = async () => {
    setCliInstalling(true);
    try {
      const result = await invoke<string>("install_cli_command");
      showToast({ message: result, type: "success" });
      setCliInstalled(true);
    } catch (error) {
      showToast({
        message: t("settings.general.cliInstallFailed", { error: String(error) }),
        type: "error",
      });
    } finally {
      setCliInstalling(false);
    }
  };

  const handleUninstallCli = async () => {
    setCliInstalling(true);
    try {
      const result = await invoke<string>("uninstall_cli_command");
      showToast({ message: result, type: "success" });
      setCliInstalled(false);
    } catch (error) {
      showToast({ message: t("settings.general.cliUninstallFailed", { error: String(error) }), type: "error" });
    } finally {
      setCliInstalling(false);
    }
  };

  const handleCopyInstallCommand = async () => {
    try {
      const command = await invoke<string>("get_cli_install_command");
      await writeClipboardText(command);
      showToast({ message: t("settings.general.installCommandCopied"), type: "success" });
    } catch (error) {
      showToast({ message: t("settings.general.copyCommandFailed", { error: String(error) }), type: "error" });
    }
  };

  const handleCheckForUpdates = async () => {
    const result = await checkForUpdates({ ignoreSuppression: true });
    if (result === "up-to-date") {
      showToast({ message: t("settings.general.latestVersion"), type: "success" });
    }
  };

  const buildBugReport = async () => {
    const version = await getVersion();
    const os = await import("@tauri-apps/plugin-os");
    const plat = os.platform();
    const ver = os.version();

    return t("settings.general.bugReportTemplate", { version, platform: plat, osVersion: ver });
  };

  const handleReportBug = async (channel: ReportBugChannel) => {
    try {
      const { openUrl } = await import("@tauri-apps/plugin-opener");
      const report = await buildBugReport();

      await writeClipboardText(report);
      await openUrl(channel.url);
      showToast({ message: t("settings.general.reportTemplateCopied"), type: "success" });

      setIsReportBugDialogOpen(false);
    } catch (err) {
      console.error("Failed to prepare bug report:", err);
      showToast({ message: t("settings.general.prepareReportFailed"), type: "error" });
    }
  };

  return (
    <SettingsView>
      <SettingRow
        label={t("settings.displayLanguage")}
        description={t("settings.displayLanguageDescription")}
      >
        <Select
          value={displayLanguage}
          options={[
            { value: "en-US", label: t("settings.languageEnglish") },
            { value: "zh-CN", label: t("settings.languageChinese") },
          ]}
          onChange={(value) => updateSetting("displayLanguage", value as "en-US" | "zh-CN")}
          className={SETTINGS_CONTROL_WIDTHS.default}
          size="md"
          variant="default"
        />
      </SettingRow>
      <SettingRow
        label={t("settings.general.version")}
        description={t("settings.general.versionDescription")}
      >
        <div className="flex flex-wrap justify-end gap-2">
          {available ? (
            <Button
              onClick={downloadAndInstall}
              disabled={downloading || installing}
              variant="default"
              size="sm"
            >
              {downloading
                ? t("settings.general.downloading")
                : installing
                  ? t("settings.general.installing")
                  : t("settings.general.installUpdate", {
                      version: updateInfo?.version ?? t("settings.general.update"),
                    })}
            </Button>
          ) : (
            <Button
              onClick={handleCheckForUpdates}
              disabled={checking || downloading || installing}
              variant="default"
              size="sm"
            >
              {checking ? t("settings.general.checking") : t("settings.general.check")}
            </Button>
          )}
        </div>
      </SettingRow>

      <div className="font-sans ui-text-sm -mt-3 px-1 text-subtle-foreground/75">
        {downloading
          ? t("settings.general.updateProgress", {
              version: appVersion || "...",
              percentage: downloadProgress?.percentage ?? 0,
            })
          : installing
            ? t("settings.general.updateInstalling", { version: appVersion || "..." })
            : available
              ? t("settings.general.updateAvailable", {
                  version: appVersion || "...",
                  availableVersion: updateInfo?.version ?? "",
                })
              : error
                ? t("settings.general.updateCheckFailed", { version: appVersion || "..." })
                : t("settings.general.upToDate", { version: appVersion || "..." })}
      </div>

      {downloading && downloadProgress ? (
        <Progress
          value={downloadProgress.percentage}
          aria-label={t("settings.general.updateDownloadProgress")}
          className="px-3"
        />
      ) : null}

      {error && <div className="font-sans ui-text-sm px-3 text-destructive">{error}</div>}

      <SettingRow
        label={t("settings.general.terminalCommand")}
        description={t("settings.general.terminalCommandDescription")}
      >
        <div className="flex gap-2">
          {cliInstalled ? (
            <TypedConfirmAction
              actionLabel={t("settings.general.uninstall")}
              busyLabel={t("settings.general.uninstalling")}
              isBusy={cliInstalling}
              onConfirm={handleUninstallCli}
            />
          ) : (
            <>
              <Button
                onClick={() => void handleInstallCli()}
                disabled={cliInstalling || cliChecking}
                variant="default"
                size="sm"
              >
                {cliInstalling ? t("settings.general.installing") : t("settings.general.install")}
              </Button>
              <Button
                onClick={handleCopyInstallCommand}
                disabled={cliChecking}
                variant="default"
                tooltip={t("settings.general.copyInstallCommand")}
                size="sm"
              >
                {t("settings.general.copy")}
              </Button>
            </>
          )}
        </div>
      </SettingRow>

      <div className="font-sans ui-text-sm -mt-3 px-1 text-subtle-foreground/75">
        {cliChecking
          ? t("settings.general.checking")
          : cliInstalled
            ? t("settings.general.cliInstalled")
            : t("settings.general.cliNotInstalled")}
      </div>

      <SettingRow
        label={t("settings.general.importSettings")}
        description={t("settings.general.importSettingsDescription")}
      >
        <Button onClick={() => setIsImportDialogOpen(true)} variant="default" size="sm">
          {t("settings.general.importSettings")}
        </Button>
      </SettingRow>

      <SettingRow
        label={t("settings.general.reportBug")}
        description={t("settings.general.reportBugDescription")}
      >
        <Button onClick={() => setIsReportBugDialogOpen(true)} variant="default" size="sm">
          {t("settings.general.open")}
        </Button>
      </SettingRow>

      {isImportDialogOpen && (
        <IdeSettingsImportDialog onClose={() => setIsImportDialogOpen(false)} />
      )}
      {isReportBugDialogOpen && (
        <ReportBugCommandDialog
          onClose={() => setIsReportBugDialogOpen(false)}
          onSelect={(channel) => void handleReportBug(channel)}
        />
      )}
    </SettingsView>
  );
};

function ReportBugCommandDialog({
  onClose,
  onSelect,
}: {
  onClose: () => void;
  onSelect: (channel: ReportBugChannel) => void;
}) {
  const { t } = useTranslation();
  const inputRef = useRef<HTMLInputElement>(null);
  const [query, setQuery] = useState("");
  const [selectedIndex, setSelectedIndex] = useState(0);

  useEffect(() => {
    inputRef.current?.focus();
  }, []);

  const channels = REPORT_BUG_CHANNELS.filter((channel) =>
    matchesSearchQuery(query, [channel.label, t(channel.detailKey)]),
  );

  useEffect(() => {
    setSelectedIndex(0);
  }, [query]);

  const selectedChannel = channels[selectedIndex];

  const handleKeyDown = (event: React.KeyboardEvent<HTMLInputElement>) => {
    if (event.key === "ArrowDown") {
      event.preventDefault();
      setSelectedIndex((index) => Math.min(index + 1, channels.length - 1));
      return;
    }

    if (event.key === "ArrowUp") {
      event.preventDefault();
      setSelectedIndex((index) => Math.max(index - 1, 0));
      return;
    }

    if (event.key === "Enter" && selectedChannel) {
      event.preventDefault();
      onSelect(selectedChannel);
    }
  };

  return (
    <Command isVisible onClose={onClose} title={t("settings.general.reportBug")} className="w-130">
      <CommandHeader onClose={onClose}>
        <CommandInput
          ref={inputRef}
          value={query}
          onChange={setQuery}
          onKeyDown={handleKeyDown}
          placeholder={t("settings.general.reportVia")}
        />
      </CommandHeader>
      <CommandList>
        {channels.length === 0 ? (
          <CommandEmpty>{t("settings.general.noReportChannel", { query })}</CommandEmpty>
        ) : (
          channels.map((channel, index) => (
            <CommandItemRow
              key={channel.id}
              isSelected={index === selectedIndex}
              onClick={() => onSelect(channel)}
              onMouseEnter={() => setSelectedIndex(index)}
              title={channel.label}
              description={t(channel.detailKey)}
            />
          ))
        )}
      </CommandList>
    </Command>
  );
}
