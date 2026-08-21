import { open } from "@tauri-apps/plugin-dialog";
import { useCallback, useEffect, useState, type ReactNode } from "react";
import {
  clearLitheLogs,
  getLogSettings,
  openLogDirectory,
  resolvePreviousLogCleanup,
  setDiagnosticLogging,
  setLogDirectory,
  type LogFallbackReason,
  type LogSettingsSnapshot,
} from "@/features/logging/log-api";
import { setFrontendDiagnosticEnabled } from "@/features/logging/frontend-log-runtime";
import { useToast } from "@/features/layout/contexts/toast-context";
import {
  openLitheLogBuffer,
  refreshOpenLitheLogBuffer,
} from "@/features/settings/services/lithe-log-service";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import { showConfirmDialog } from "@/ui/dialog";
import Switch from "@/ui/switch";
import { writeClipboardText } from "@/utils/clipboard";

function SettingsGroup({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="overflow-clip rounded-md border border-border bg-surface/35">
      <h3 className="border-border border-b px-3 py-2 ui-text-sm font-medium text-subtle-foreground">
        {title}
      </h3>
      <div className="flex flex-col gap-3 p-3">{children}</div>
    </section>
  );
}

function SettingsRow({
  label,
  description,
  children,
}: {
  label: string;
  description?: string;
  children: ReactNode;
}) {
  return (
    <div className="flex min-h-8 items-center gap-4">
      <div className="min-w-0 flex-1">
        <div className="ui-text-sm text-foreground">{label}</div>
        {description ? (
          <p className="mt-1 ui-text-caption leading-relaxed text-subtle-foreground">
            {description}
          </p>
        ) : null}
      </div>
      <div className="shrink-0">{children}</div>
    </div>
  );
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

function formatBytes(bytes: number) {
  if (bytes < 1_024) return `${bytes} B`;
  if (bytes < 1_024 * 1_024) return `${(bytes / 1_024).toFixed(1)} KB`;
  return `${(bytes / (1_024 * 1_024)).toFixed(1)} MB`;
}

export function LogSettingsPanel({ onClose }: { onClose: () => void }) {
  const { t } = useTranslation();
  const { showToast } = useToast();
  const [settings, setSettings] = useState<LogSettingsSnapshot | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      setSettings(await getLogSettings());
    } catch (error) {
      showToast({
        message: t("settings.logs.loadFailed", { error: errorMessage(error) }),
        type: "error",
      });
    }
  }, [showToast, t]);

  useEffect(() => {
    void load();
    const handleRuntimeFallback = (event: Event) => {
      setSettings((event as CustomEvent<LogSettingsSnapshot>).detail);
    };
    window.addEventListener("lithe-log-runtime-fallback", handleRuntimeFallback);
    return () => {
      window.removeEventListener("lithe-log-runtime-fallback", handleRuntimeFallback);
    };
  }, [load]);

  const refreshOpenLogAfterMutation = async () => {
    try {
      await refreshOpenLitheLogBuffer();
    } catch (error) {
      showToast({
        message: t("settings.logs.refreshFailed", { error: errorMessage(error) }),
        type: "warning",
      });
    }
  };

  const finishDirectoryChange = async (
    result: Awaited<ReturnType<typeof setLogDirectory>>,
  ) => {
    setSettings(result.settings);
    await refreshOpenLogAfterMutation();
    if (!result.previous_custom_path || result.previous_log_bytes <= 0) return;
    const shouldDelete = await showConfirmDialog(
      t("settings.logs.previousDirectoryPrompt", {
        path: result.previous_custom_path,
        size: formatBytes(result.previous_log_bytes),
      }),
      {
        title: t("settings.logs.previousDirectoryTitle"),
        confirmLabel: t("settings.logs.deleteLogs"),
        cancelLabel: t("settings.logs.keepLogs"),
      },
    );
    try {
      await resolvePreviousLogCleanup(shouldDelete);
    } catch (error) {
      showToast({
        message: t("settings.logs.cleanupFailed", { error: errorMessage(error) }),
        type: "error",
      });
    }
  };

  const chooseDirectory = async () => {
    const selected = await open({
      directory: true,
      multiple: false,
      title: t("settings.logs.chooseDirectory"),
    });
    if (!selected || Array.isArray(selected)) return;
    setBusy(true);
    try {
      await finishDirectoryChange(await setLogDirectory(selected));
      showToast({ message: t("settings.logs.directoryChanged"), type: "success" });
    } catch (error) {
      showToast({
        message: t("settings.logs.directoryChangeFailed", { error: errorMessage(error) }),
        type: "error",
      });
    } finally {
      setBusy(false);
    }
  };

  const restoreDefault = async () => {
    setBusy(true);
    try {
      await finishDirectoryChange(await setLogDirectory(null));
      showToast({ message: t("settings.logs.defaultRestored"), type: "success" });
    } catch (error) {
      showToast({
        message: t("settings.logs.directoryChangeFailed", { error: errorMessage(error) }),
        type: "error",
      });
    } finally {
      setBusy(false);
    }
  };

  const toggleDiagnostic = async (enabled: boolean) => {
    setBusy(true);
    try {
      const snapshot = await setDiagnosticLogging(enabled);
      setFrontendDiagnosticEnabled(snapshot.diagnostic_enabled);
      setSettings(snapshot);
    } catch (error) {
      showToast({
        message: t("settings.logs.diagnosticFailed", { error: errorMessage(error) }),
        type: "error",
      });
    } finally {
      setBusy(false);
    }
  };

  const clearLogs = async () => {
    const confirmed = await showConfirmDialog(t("settings.logs.clearPrompt"), {
      title: t("settings.logs.clearTitle"),
      confirmLabel: t("settings.logs.clearLogs"),
      cancelLabel: t("settings.logs.cancel"),
    });
    if (!confirmed) return;
    setBusy(true);
    try {
      const result = await clearLitheLogs();
      await refreshOpenLogAfterMutation();
      showToast({
        message: t("settings.logs.cleared", {
          count: result.deleted_files,
          size: formatBytes(result.freed_bytes),
        }),
        type: "success",
      });
    } catch (error) {
      showToast({
        message: t("settings.logs.cleanupFailed", { error: errorMessage(error) }),
        type: "error",
      });
    } finally {
      setBusy(false);
    }
  };

  const openCurrentLog = async () => {
    try {
      await openLitheLogBuffer();
      onClose();
    } catch (error) {
      showToast({
        message: t("settings.logs.openFailed", { error: errorMessage(error) }),
        type: "error",
      });
    }
  };

  const openDirectory = async () => {
    if (!settings) return;
    try {
      await openLogDirectory();
    } catch (error) {
      showToast({
        message: t("settings.logs.openDirectoryFailed", { error: errorMessage(error) }),
        type: "error",
      });
    }
  };

  const copyEffectivePath = async () => {
    if (!settings) return;
    try {
      await writeClipboardText(settings.effective_path);
      showToast({ message: t("settings.logs.pathCopied"), type: "success" });
    } catch (error) {
      showToast({
        message: t("settings.logs.copyFailed", { error: errorMessage(error) }),
        type: "error",
      });
    }
  };

  const fallbackReason = settings?.fallback_reason
    ? t(`settings.logs.fallback.${settings.fallback_reason as LogFallbackReason}`)
    : null;

  return (
    <div className="flex flex-col gap-4">
      <SettingsGroup title={t("settings.logs.locations")}>
        <SettingsRow
          label={t("settings.logs.effectivePath")}
          description={fallbackReason ?? t("settings.logs.effectivePathDescription")}
        >
          <div className="flex max-w-88 flex-col items-end gap-2">
            <code className="max-w-full break-all text-right ui-text-caption text-subtle-foreground">
              {settings?.effective_path ?? t("settings.logs.loading")}
            </code>
            <div className="flex flex-wrap justify-end gap-2">
              <Button
                variant="default"
                size="sm"
                disabled={!settings}
                onClick={() => void openCurrentLog()}
              >
                {t("settings.logs.openCurrent")}
              </Button>
              <Button
                variant="default"
                size="sm"
                disabled={!settings}
                onClick={() => void openDirectory()}
              >
                {t("settings.logs.openDirectory")}
              </Button>
              <Button
                variant="default"
                size="sm"
                disabled={!settings}
                onClick={() => void copyEffectivePath()}
              >
                {t("settings.logs.copyPath")}
              </Button>
            </div>
          </div>
        </SettingsRow>
        <SettingsRow
          label={t("settings.logs.defaultPath")}
          description={t("settings.logs.defaultPathDescription")}
        >
          <code className="max-w-88 break-all text-right ui-text-caption text-subtle-foreground">
            {settings?.default_path ?? t("settings.logs.loading")}
          </code>
        </SettingsRow>
        <SettingsRow
          label={t("settings.logs.customPath")}
          description={t("settings.logs.customPathDescription")}
        >
          <div className="flex max-w-88 flex-col items-end gap-2">
            <code className="max-w-full break-all text-right ui-text-caption text-subtle-foreground">
              {settings?.configured_path ?? t("settings.logs.usingDefault")}
            </code>
            <div className="flex gap-2">
              <Button variant="default" size="sm" disabled={busy} onClick={() => void chooseDirectory()}>
                {t("settings.logs.choose")}
              </Button>
              <Button
                variant="default"
                size="sm"
                disabled={busy || !settings?.configured_path}
                onClick={() => void restoreDefault()}
              >
                {t("settings.logs.restoreDefault")}
              </Button>
            </div>
          </div>
        </SettingsRow>
      </SettingsGroup>

      <SettingsGroup title={t("settings.logs.diagnostics")}>
        <SettingsRow
          label={t("settings.logs.diagnosticMode")}
          description={t("settings.logs.diagnosticModeDescription")}
        >
          <Switch
            checked={settings?.diagnostic_enabled ?? false}
            disabled={!settings || busy}
            onChange={(enabled) => void toggleDiagnostic(enabled)}
            size="sm"
          />
        </SettingsRow>
      </SettingsGroup>

      <SettingsGroup title={t("settings.logs.retention")}>
        <p className="ui-text-sm leading-relaxed text-subtle-foreground">
          {t("settings.logs.retentionDescription")}
        </p>
        <SettingsRow
          label={t("settings.logs.clearCurrent")}
          description={t("settings.logs.clearCurrentDescription")}
        >
          <Button variant="default" size="sm" disabled={busy} onClick={() => void clearLogs()}>
            {t("settings.logs.clearLogs")}
          </Button>
        </SettingsRow>
      </SettingsGroup>
    </div>
  );
}
