import SettingsSelect from "@/ui/settings-select";
import Input from "@/ui/input";
import { open, save } from "@tauri-apps/plugin-dialog";
import { useCallback, useEffect, useRef, useState } from "react";
import {
  clearLitheLogs,
  discardDiagnosticBundle,
  queryLitheLogs,
  type LogSelection,
  type LogTimeline,
  exportDiagnosticBundle,
  getLogSettings,
  openLogDirectory,
  previewDiagnosticBundle,
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
import SettingsGroup, { SettingRow as SettingsRow } from "./settings-section";

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
  const [selection, setSelection] = useState<LogSelection>({
    session: "current",
    minimumLevel: "info",
  });
  const [timeline, setTimeline] = useState<LogTimeline | null>(null);
  const queryGeneration = useRef(0);
  useEffect(() => {
    queryGeneration.current += 1;
    setTimeline(null);
    return () => {
      queryGeneration.current += 1;
    };
  }, [selection]);
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

  const refreshTimeline = useCallback(
    async (manageBusy = true) => {
      const generation = ++queryGeneration.current;
      if (manageBusy) setBusy(true);
      try {
        const result = await queryLitheLogs(selection);
        if (generation === queryGeneration.current) {
          setTimeline({
            ...result,
            content: result.content.slice(-200_000),
            truncated: result.truncated || result.content.length > 200_000,
          });
        }
      } catch (error) {
        if (generation === queryGeneration.current)
          showToast({ message: errorMessage(error), type: "error" });
      } finally {
        await load();
        // Mutating callers retain busy until their whole workflow completes.
        if (manageBusy) setBusy(false);
      }
    },
    [selection, load, showToast],
  );

  const initialLoadStarted = useRef(false);
  useEffect(() => {
    if (initialLoadStarted.current) return;
    initialLoadStarted.current = true;
    void refreshTimeline();
  }, [refreshTimeline]);

  useEffect(() => {
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

  const finishDirectoryChange = async (result: Awaited<ReturnType<typeof setLogDirectory>>) => {
    setSettings(result.settings);
    await refreshTimeline(false);
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
      const snapshot = await setDiagnosticLogging(enabled, selection.category ?? null);
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
      setTimeline(null);
      await refreshTimeline(false);
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

  const exportDiagnostics = async () => {
    setBusy(true);
    const exportSelection = { ...selection };
    let preview: Awaited<ReturnType<typeof previewDiagnosticBundle>>;
    try {
      preview = await previewDiagnosticBundle(exportSelection);
    } catch (error) {
      showToast({
        message: t("settings.logs.exportBundlePreviewFailed", { error: errorMessage(error) }),
        type: "error",
      });
      return;
    } finally {
      setBusy(false);
    }

    try {
      const confirmed = await showConfirmDialog(
        <div className="flex flex-col gap-2">
          <p>{t("settings.logs.exportBundleIntro")}</p>
          <p>
            {t("settings.logs.selectionSummary", {
              module: t(`settings.logs.category.${exportSelection.category ?? "all"}`),
              session: t(`settings.logs.session.${exportSelection.session ?? "current"}`),
              level: (exportSelection.minimumLevel ?? "info").toUpperCase(),
            })}
          </p>
          <ul className="flex max-h-48 flex-col gap-1 overflow-y-auto ui-text-caption text-subtle-foreground">
            {preview.manifest.files.map((file) => (
              <li key={file.relativePath} className="flex items-center justify-between gap-3">
                <span className="truncate">{file.relativePath}</span>
                <span className="shrink-0">{formatBytes(file.sizeBytes)}</span>
              </li>
            ))}
          </ul>
        </div>,
        {
          title: t("settings.logs.exportBundleTitle"),
          confirmLabel: t("settings.logs.exportBundleConfirm"),
          cancelLabel: t("settings.logs.cancel"),
        },
      );
      if (!confirmed) return;

      const destination = await save({
        defaultPath: `lithe-diagnostics-${new Date().toISOString().split("T")[0]}.zip`,
        title: t("settings.logs.exportBundleChooseDestination"),
        filters: [{ name: t("settings.logs.exportBundleFilter"), extensions: ["zip"] }],
      });
      if (!destination) return;

      setBusy(true);
      try {
        const result = await exportDiagnosticBundle(destination, preview.snapshotId);
        showToast({
          message: t("settings.logs.exportBundleSuccess", { path: result.destinationPath }),
          type: "success",
        });
      } catch (error) {
        showToast({
          message: t("settings.logs.exportBundleFailed", { error: errorMessage(error) }),
          type: "error",
        });
      } finally {
        setBusy(false);
      }
    } finally {
      await discardDiagnosticBundle(preview.snapshotId).catch(() => {});
    }
  };

  const fallbackReason = settings?.fallback_reason
    ? t(`settings.logs.fallback.${settings.fallback_reason as LogFallbackReason}`)
    : null;

  return (
    <div className="flex flex-col gap-4">
      <p className="ui-text-sm text-subtle-foreground">{t("settings.logs.workflow")}</p>
      <SettingsGroup title={t("settings.logs.timeline")}>
        <div className="flex flex-wrap gap-2">
          <SettingsSelect
            aria-label={t("settings.logs.module")}
            value={selection.category ?? "all"}
            options={["all", "application", "language", "run", "git", "plugins", "performance"].map(
              (value) => ({ value, label: t(`settings.logs.category.${value}`) }),
            )}
            onChange={(category) =>
              setSelection((previous) => ({
                ...previous,
                category: category === "all" ? null : category,
              }))
            }
          />
          <SettingsSelect
            aria-label={t("settings.logs.session")}
            value={selection.session ?? "current"}
            options={["current", "previous", "all"].map((value) => ({
              value,
              label: t(`settings.logs.session.${value}`),
            }))}
            onChange={(session) =>
              setSelection((previous) => ({
                ...previous,
                session: session as LogSelection["session"],
              }))
            }
          />
          <SettingsSelect
            aria-label={t("settings.logs.level")}
            value={selection.minimumLevel ?? "info"}
            options={["debug", "info", "warn", "error"].map((value) => ({
              value,
              label: value.toUpperCase(),
            }))}
            onChange={(minimumLevel) => setSelection((previous) => ({ ...previous, minimumLevel }))}
          />
        </div>
        <Input
          aria-label={t("settings.logs.search")}
          placeholder={t("settings.logs.search")}
          value={selection.search ?? ""}
          onChange={(event) =>
            setSelection((previous) => ({ ...previous, search: event.target.value }))
          }
        />
        <div className="flex gap-2">
          <Input
            aria-label={t("settings.logs.since")}
            placeholder={t("settings.logs.since")}
            value={selection.since ?? ""}
            onChange={(event) =>
              setSelection((previous) => ({ ...previous, since: event.target.value || null }))
            }
          />
          <Input
            aria-label={t("settings.logs.until")}
            placeholder={t("settings.logs.until")}
            value={selection.until ?? ""}
            onChange={(event) =>
              setSelection((previous) => ({ ...previous, until: event.target.value || null }))
            }
          />
        </div>
        <Button size="sm" disabled={busy} onClick={() => void refreshTimeline()}>
          {t("settings.logs.refreshTimeline")}
        </Button>
        {timeline && (
          <>
            {timeline.truncated && <p>{t("settings.logs.incomplete")}</p>}
            <pre
              className="max-h-72 overflow-auto whitespace-pre-wrap break-all ui-text-caption font-mono"
              role="log"
            >
              {timeline.content || t("settings.logs.empty")}
            </pre>
          </>
        )}
        <p className="ui-text-caption text-subtle-foreground">
          {t("settings.logs.health", {
            dropped: settings?.dropped_events ?? 0,
            failures: settings?.write_failures ?? 0,
          })}
        </p>
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
        <p className="ui-text-caption text-subtle-foreground">
          {settings?.diagnostic_enabled
            ? t("settings.logs.diagnosticOn", {
                module: t(`settings.logs.category.${settings.diagnostic_category ?? "all"}`),
              })
            : t("settings.logs.diagnosticOff")}
        </p>
        <p className="ui-text-caption text-subtle-foreground">
          {t("settings.logs.diagnosticExpiry")}
        </p>
      </SettingsGroup>

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
              <Button
                variant="default"
                size="sm"
                disabled={busy}
                onClick={() => void chooseDirectory()}
              >
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

      <SettingsGroup title={t("settings.logs.diagnosticBundle")}>
        <SettingsRow
          label={t("settings.logs.exportBundle")}
          description={t("settings.logs.diagnosticBundleDescription")}
        >
          <Button
            variant="default"
            size="sm"
            disabled={busy}
            onClick={() => void exportDiagnostics()}
          >
            {t("settings.logs.previewExport")}
          </Button>
        </SettingsRow>
      </SettingsGroup>
    </div>
  );
}
