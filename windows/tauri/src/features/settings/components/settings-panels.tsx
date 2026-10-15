import SettingsSelect from "@/ui/settings-select";
import { FontSelector } from "./font-selector";
import { MIN_EDITOR_FONT_SIZE, MAX_EDITOR_FONT_SIZE } from "../lib/editor-font-size";
import { buildFontFamilyStack } from "../lib/font-family-resolution";
import { DEFAULT_MONO_FONT_FAMILY } from "../config/typography-defaults";
import { AiCommitSettingsPanel } from "./ai-commit-settings-panel";
import { AISettings } from "./tabs/ai-settings";
import { getVersion } from "@tauri-apps/api/app";
import { lazy, Suspense, useEffect, useMemo, useState, useSyncExternalStore } from "react";
import { themeRegistry } from "@/extensions/themes/theme-registry";
import { useRegisteredThemes } from "@/extensions/themes/use-registered-themes";
import { useUpdater } from "@/features/settings/hooks/use-updater";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import type { EditorTabLayoutMode } from "@/features/settings/types/settings.types";
import {
  getSystemThemePreference,
  resolveEffectiveTheme,
  subscribeSystemThemePreference,
} from "@/features/settings/lib/theme-resolution";
import {
  getProjectOpenPreference,
  getProjectOpenPreferencePatch,
  type ProjectOpenPreference,
} from "@/features/settings/lib/project-open-preference";
import {
  SYSTEM_DEFAULT_SHELL_VALUE,
  getDefaultShellOptions,
} from "@/features/settings/lib/default-shell-options";
import { useTerminalShellsStore } from "@/features/terminal/stores/shells.store";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import NumberInput from "@/ui/number-input";
import Switch from "@/ui/switch";
import Textarea from "@/ui/textarea";
import { ToggleGroup } from "@/ui/toggle-group";
import { SETTINGS_CONTROL_WIDTHS } from "./settings-section";
import SettingsGroup from "./settings-section";
import { SettingRow as SettingsRow } from "./settings-section";
export { SettingsGroup, SettingsRow };
import { LogSettingsPanel } from "./log-settings-panel";
import { MavenSettingsPanel } from "./tabs/maven-settings-panel";
import { GitSettings } from "./tabs/git-settings";
import { KeyboardSettings } from "./tabs/keyboard-settings";
import { McpConfigurationSettings } from "./mcp-configuration-settings";
import { ProjectEnvironmentSettings } from "./project-environment-settings";

import { RunConfigurationSettings } from "./run-configuration-settings";

export type SettingsCategory =
  | "run"
  | "project"
  | "mcp"
  | "git"
  | "general"
  | "editor"
  | "keyboard"
  | "plugins"
  | "terminal"
  | "lsp"
  | "maven"
  | "ai"
  | "ai-commit"
  | "logs"
  | "updates";

const PluginsPanel = lazy(() =>
  import("@/extensions/ui/components/extensions-sidebar").then(({ ExtensionsSidebar }) => ({
    default: ExtensionsSidebar,
  })),
);

function GeneralPanel() {
  const { t } = useTranslation();
  const settings = useSettingsStore((state) => state.settings);
  const updateSetting = useSettingsStore((state) => state.actions.updateSetting);
  const projectPlacement = getProjectOpenPreference(settings);
  const registeredThemes = useRegisteredThemes();
  const systemTheme = useSyncExternalStore(
    subscribeSystemThemePreference,
    getSystemThemePreference,
    getSystemThemePreference,
  );
  const effectiveTheme = resolveEffectiveTheme(settings, systemTheme);
  const [gitPolicy, setGitPolicy] = useState("ask");
  const [directoryPatterns, setDirectoryPatterns] = useState(
    settings.hiddenDirectoryPatterns.join("\n"),
  );
  const [filePatterns, setFilePatterns] = useState(settings.hiddenFilePatterns.join("\n"));

  const appearanceMode = settings.syncSystemTheme
    ? "system"
    : themeRegistry.getTheme(effectiveTheme)?.isDark === false
      ? "light"
      : "dark";

  const themeOptions = useMemo(
    () =>
      registeredThemes.map((theme) => ({
        value: theme.id,
        label: theme.name,
      })),
    [registeredThemes],
  );

  const normalizedThemeOptions = useMemo(() => {
    if (themeOptions.some((option) => option.value === effectiveTheme)) {
      return themeOptions;
    }

    const fallbackTheme = themeRegistry.getTheme(effectiveTheme);
    if (!fallbackTheme) {
      return themeOptions;
    }

    return [{ value: fallbackTheme.id, label: fallbackTheme.name }, ...themeOptions];
  }, [themeOptions, effectiveTheme]);

  const handleThemeChange = (themeId: string) => {
    const theme = themeRegistry.getTheme(themeId);
    if (!settings.syncSystemTheme || !theme) {
      void updateSetting("theme", themeId);
      return;
    }

    void updateSetting(theme.isDark ? "autoThemeDark" : "autoThemeLight", themeId);
  };

  const applyVisibilityPatterns = () => {
    const parse = (value: string) =>
      value
        .split(/\r?\n/)
        .map((entry) => entry.trim())
        .filter(Boolean);
    void updateSetting("hiddenDirectoryPatterns", parse(directoryPatterns));
    void updateSetting("hiddenFilePatterns", parse(filePatterns));
  };

  return (
    <div className="flex flex-col gap-4">
      <SettingsGroup title={t("settings.mac.appearance")}>
        <SettingsRow label={t("settings.mac.colorTheme")}>
          <SettingsSelect
            aria-label={t("settings.mac.colorTheme")}
            className="w-40"
            value={effectiveTheme}
            onChange={(selectedValue) => handleThemeChange(selectedValue)}
            options={normalizedThemeOptions}
          />
        </SettingsRow>
        <SettingsRow
          label={t("settings.mac.appearanceMode")}
          description={t("settings.mac.appearanceDescription")}
        >
          <ToggleGroup
            ariaLabel={t("settings.mac.appearanceMode")}
            size="sm"
            variant="segmented"
            wrap={false}
            className="rounded-sm border border-border bg-background"
            value={appearanceMode}
            onValueChange={(selectedValue) => {
              const value = selectedValue;
              if (value === "system") {
                void updateSetting("syncSystemTheme", true);
                return;
              }
              void updateSetting("syncSystemTheme", false);
              void updateSetting("theme", value === "light" ? "lithe-light" : "lithe-dark");
            }}
            options={[
              { value: "system", label: t("settings.mac.followSystem") },
              { value: "light", label: t("settings.mac.light") },
              { value: "dark", label: t("settings.mac.dark") },
            ]}
          />
        </SettingsRow>
      </SettingsGroup>

      <SettingsGroup title={t("settings.mac.language")}>
        <SettingsRow
          label={t("settings.mac.language")}
          description={t("settings.mac.languageDescription")}
        >
          <SettingsSelect
            aria-label={t("settings.mac.language")}
            className="w-40"
            value={settings.displayLanguage}
            onChange={(selectedValue) =>
              void updateSetting("displayLanguage", selectedValue as "en-US" | "zh-CN")
            }
            options={[
              { value: "en-US", label: "English" },
              { value: "zh-CN", label: "简体中文" },
            ]}
          />
        </SettingsRow>
      </SettingsGroup>

      <SettingsGroup title={t("settings.mac.projects")}>
        <SettingsRow
          label={t("settings.mac.openProjectsIn")}
          description={t("settings.mac.openProjectsDescription")}
        >
          <SettingsSelect
            aria-label={t("settings.mac.openProjectsIn")}
            className="w-40"
            value={projectPlacement}
            onChange={(selectedValue) => {
              const patch = getProjectOpenPreferencePatch(selectedValue as ProjectOpenPreference);
              if (patch.projectOpenDefaultDestination !== undefined) {
                void updateSetting(
                  "projectOpenDefaultDestination",
                  patch.projectOpenDefaultDestination,
                );
              }
              void updateSetting("askWhereToOpenProjects", patch.askWhereToOpenProjects ?? true);
            }}
            options={[
              { value: "ask", label: t("settings.mac.askEveryTime") },
              { value: "this-window", label: t("settings.mac.thisWindow") },
              { value: "new-window", label: t("settings.mac.newWindow") },
              { value: "attach", label: t("settings.mac.attach") },
            ]}
          />
        </SettingsRow>
      </SettingsGroup>

      <SettingsGroup title={t("settings.mac.files")}>
        <SettingsRow label={t("settings.mac.autoSave")}>
          <Switch
            checked={settings.autoSave}
            onChange={(checked) => void updateSetting("autoSave", checked)}
            size="sm"
          />
        </SettingsRow>
      </SettingsGroup>

      <SettingsGroup title={t("settings.mac.git")}>
        <SettingsRow
          label={t("settings.mac.saveLocalChangesWith")}
          description={t("settings.mac.gitPolicyDescription")}
        >
          <SettingsSelect
            aria-label={t("settings.mac.saveLocalChangesWith")}
            className="w-40"
            value={gitPolicy}
            onChange={(selectedValue) => setGitPolicy(selectedValue)}
            options={[
              { value: "ask", label: t("settings.mac.askEveryTime") },
              { value: "shelf", label: t("settings.mac.shelf") },
              { value: "stash", label: t("settings.mac.gitStash") },
            ]}
          />
        </SettingsRow>
      </SettingsGroup>

      <SettingsGroup title={t("settings.mac.hiddenPaths")}>
        <p className="ui-text-caption leading-relaxed text-subtle-foreground">
          {t("settings.mac.hiddenPathsDescription")}
        </p>
        <label className="flex flex-col gap-1.5 ui-text-sm text-foreground">
          {t("settings.mac.directories")}
          <Textarea
            className="min-h-18 font-mono"
            value={directoryPatterns}
            onChange={(event) => setDirectoryPatterns(event.target.value)}
          />
        </label>
        <label className="flex flex-col gap-1.5 ui-text-sm text-foreground">
          {t("settings.mac.filePatterns")}
          <Textarea
            className="min-h-14 font-mono"
            value={filePatterns}
            onChange={(event) => setFilePatterns(event.target.value)}
          />
        </label>
        <div className="flex justify-end">
          <Button variant="accent" size="sm" onClick={applyVisibilityPatterns}>
            {t("settings.mac.apply")}
          </Button>
        </div>
      </SettingsGroup>
    </div>
  );
}

function EditorPanel() {
  const { t } = useTranslation();
  const settings = useSettingsStore((state) => state.settings);
  const updateSetting = useSettingsStore((state) => state.actions.updateSetting);

  return (
    <div className="flex flex-col gap-4">
      <SettingsGroup title={t("settings.mac.display")}>
        <SettingsRow
          label={t("settings.editor.fontFamily")}
          description={t("settings.editor.fontFamilyDescription")}
        >
          <FontSelector
            value={settings.fontFamily}
            onChange={(family) => void updateSetting("fontFamily", family)}
            monospaceOnly={false}
            aria-label={t("settings.editor.fontFamily")}
            className="w-64 max-w-full"
          />
        </SettingsRow>
        <SettingsRow
          label={t("settings.mac.fontSize")}
          description={t("settings.editor.fontSizeDescription")}
        >
          <NumberInput
            min={MIN_EDITOR_FONT_SIZE}
            max={MAX_EDITOR_FONT_SIZE}
            step={1}
            size="md"
            className={SETTINGS_CONTROL_WIDTHS.numberCompact}
            aria-label={t("settings.mac.fontSize")}
            value={settings.fontSize}
            onChange={(value) => void updateSetting("fontSize", value)}
          />
        </SettingsRow>
        <SettingsRow
          label={t("settings.editor.fontLigatures")}
          description={t("settings.editor.fontLigaturesDescription")}
        >
          <Switch
            checked={settings.editorFontLigatures}
            onChange={(enabled) => void updateSetting("editorFontLigatures", enabled)}
            aria-label={t("settings.editor.fontLigatures")}
            size="sm"
          />
        </SettingsRow>
        <pre
          aria-label={t("settings.editor.fontPreview")}
          className="mx-3 overflow-x-auto rounded-lg bg-secondary/40 p-3"
          style={{
            fontFamily: buildFontFamilyStack(settings.fontFamily, DEFAULT_MONO_FONT_FAMILY),
            fontSize: settings.fontSize,
            fontVariantLigatures: settings.editorFontLigatures ? "normal" : "none",
            fontFeatureSettings: settings.editorFontLigatures
              ? '"liga" 1, "calt" 1'
              : '"liga" 0, "calt" 0',
          }}
        >
          {"const ready = a != b && count <= 10;\n(a, b) => a === b   中文字体预览 0123456789"}
        </pre>
        <SettingsRow label={t("settings.mac.showCodeVision")}>
          <Switch
            checked={settings.codeLens}
            onChange={(checked) => void updateSetting("codeLens", checked)}
            size="sm"
          />
        </SettingsRow>
        <SettingsRow label={t("settings.editor.showMinimap")}>
          <Switch
            checked={settings.showMinimap}
            onChange={(checked) => void updateSetting("showMinimap", checked)}
            size="sm"
          />
        </SettingsRow>
      </SettingsGroup>
      <SettingsGroup title={t("settings.mac.editorTabs")}>
        <SettingsRow label={t("settings.mac.layout")}>
          <SettingsSelect
            aria-label={t("settings.mac.layout")}
            className="w-40"
            value={settings.editorTabLayoutMode}
            onChange={(selectedValue) =>
              void updateSetting("editorTabLayoutMode", selectedValue as EditorTabLayoutMode)
            }
            options={[
              { value: "singleLine", label: t("settings.mac.singleRow") },
              { value: "multipleRows", label: t("settings.mac.wrapRows") },
            ]}
          />
        </SettingsRow>
      </SettingsGroup>
      <SettingsGroup title={t("settings.mac.indentation")}>
        <SettingsRow label={t("settings.mac.tabWidth")}>
          <SettingsSelect
            aria-label={t("settings.mac.tabWidth")}
            className="w-32"
            value={String(settings.tabSize)}
            onChange={(selectedValue) => void updateSetting("tabSize", Number(selectedValue))}
            options={[2, 4, 8].map((size) => ({
              value: String(size),
              label: `${size} ${t("settings.mac.spaces")}`,
            }))}
          />
        </SettingsRow>
      </SettingsGroup>
    </div>
  );
}

function TerminalPanel() {
  const { t } = useTranslation();
  const settings = useSettingsStore((state) => state.settings);
  const updateSetting = useSettingsStore((state) => state.actions.updateSetting);
  const shells = useTerminalShellsStore.use.shells();
  const hasLoadedShells = useTerminalShellsStore.use.hasLoaded();
  const isDetectingShells = useTerminalShellsStore.use.isLoading();
  const shellDetectionError = useTerminalShellsStore.use.error();
  const shellOptions = getDefaultShellOptions({
    shells,
    selectedShellId: settings.terminalDefaultShellId,
    hasLoaded: hasLoadedShells,
  });

  useEffect(() => {
    void useTerminalShellsStore.getState().actions.loadShells();
  }, []);

  return (
    <SettingsGroup title={t("settings.mac.shell")}>
      <SettingsRow
        label={t("settings.mac.defaultShell")}
        description={t("settings.mac.defaultShellDescription")}
      >
        <SettingsSelect
          aria-label={t("settings.mac.defaultShell")}
          className="w-64"
          value={settings.terminalDefaultShellId}
          onChange={(selectedValue) => void updateSetting("terminalDefaultShellId", selectedValue)}
          options={shellOptions.map((option) => ({
            value: option.value,
            label:
              option.value === SYSTEM_DEFAULT_SHELL_VALUE
                ? t("settings.mac.systemDefault")
                : option.isAvailable
                  ? (option.shellName ?? option.value)
                  : `${option.value} (${t("terminal.shellUnavailable")})`,
          }))}
        />
      </SettingsRow>
      <div className="flex items-center gap-3">
        <Button
          variant="default"
          size="sm"
          disabled={isDetectingShells}
          onClick={() => void useTerminalShellsStore.getState().actions.loadShells({ force: true })}
        >
          {t(isDetectingShells ? "terminal.detectingShells" : "terminal.detectShells")}
        </Button>
        {shellDetectionError ? (
          <p role="alert" className="ui-text-caption text-destructive">
            {t("terminal.detectShellsFailed")}
          </p>
        ) : null}
      </div>
    </SettingsGroup>
  );
}

function LspPanel() {
  const { t } = useTranslation();
  const settings = useSettingsStore((state) => state.settings);
  const updateSetting = useSettingsStore((state) => state.actions.updateSetting);

  return (
    <div className="flex flex-col gap-4">
      <SettingsGroup title={t("settings.mac.languageServices")}>
        <SettingsRow
          label={t("settings.mac.autoCompletion")}
          description={t("settings.mac.autoCompletionDescription")}
        >
          <Switch
            checked={settings.autoCompletion}
            onChange={(checked) => void updateSetting("autoCompletion", checked)}
            size="sm"
          />
        </SettingsRow>
        <SettingsRow label={t("settings.mac.parameterHints")}>
          <Switch
            checked={settings.parameterHints}
            onChange={(checked) => void updateSetting("parameterHints", checked)}
            size="sm"
          />
        </SettingsRow>
        <SettingsRow label={t("settings.mac.semanticHighlighting")}>
          <Switch
            checked={settings.semanticTokens}
            onChange={(checked) => void updateSetting("semanticTokens", checked)}
            size="sm"
          />
        </SettingsRow>
      </SettingsGroup>
      <SettingsGroup title={t("settings.mac.detectedServers")}>
        <p className="ui-text-sm leading-relaxed text-subtle-foreground">
          {t("settings.mac.detectedServersDescription")}
        </p>
      </SettingsGroup>
    </div>
  );
}

function UpdatesPanel() {
  const { t } = useTranslation();
  const [appVersion, setAppVersion] = useState("");
  const {
    status,
    checking,
    available,
    downloading,
    installing,
    updateInfo,
    error,
    downloadProgress,
    checkForUpdates,
    downloadAndInstall,
  } = useUpdater(false);
  const busy = checking || downloading || installing;
  // An update found here is installed from this panel: the check and the
  // install action sit side by side, so no dialog opens over Settings.
  const installFailed = status === "failed" && updateInfo !== null;
  const installable = updateInfo !== null && (available || installFailed);

  useEffect(() => {
    void getVersion()
      .then(setAppVersion)
      .catch(() => setAppVersion(""));
  }, []);

  const statusMessage = () => {
    if (checking) return t("settings.mac.checking");
    if (downloading) {
      return t("update.updatingProgress", { percentage: downloadProgress?.percentage ?? 0 });
    }
    if (installing) return t("settings.general.installing");
    if (installFailed) return error;
    if (error) return t("settings.mac.updateFailed");
    if (available) {
      return t("settings.mac.updateAvailable", { version: updateInfo?.targetVersion ?? "" });
    }
    return status === "upToDate" ? t("settings.mac.upToDate") : t("settings.mac.updateHint");
  };

  return (
    <div className="flex flex-col gap-4">
      <SettingsGroup title={t("settings.mac.softwareUpdate")}>
        <SettingsRow
          label="Lithe"
          description={t("settings.mac.currentVersion", { version: appVersion || "…" })}
        >
          <div className="flex flex-wrap justify-end gap-2">
            <Button
              variant={installable ? "ghost" : "accent"}
              size="sm"
              disabled={busy}
              onClick={() => {
                void checkForUpdates({ ignoreSuppression: true });
              }}
            >
              {checking ? t("settings.mac.checking") : t("settings.mac.checkForUpdates")}
            </Button>
            {installable && updateInfo ? (
              <Button
                variant="accent"
                size="sm"
                disabled={busy}
                onClick={() => void downloadAndInstall()}
              >
                {installFailed
                  ? t("ui.retry")
                  : t("settings.general.installUpdate", { version: updateInfo.targetVersion })}
              </Button>
            ) : null}
          </div>
        </SettingsRow>
        <p className="ui-text-sm text-subtle-foreground" role="status">
          {statusMessage()}
        </p>
      </SettingsGroup>
    </div>
  );
}

export function SettingsPanel({
  category,
  onClose,
}: {
  category: SettingsCategory;
  onClose: () => void;
}) {
  switch (category) {
    case "run":
      return <RunConfigurationSettings />;
    case "mcp":
      return <McpConfigurationSettings />;
    case "project":
      return <ProjectEnvironmentSettings />;
    case "git":
      return <GitSettings />;
    case "general":
      return <GeneralPanel />;
    case "editor":
      return <EditorPanel />;
    case "keyboard":
      return <KeyboardSettings />;
    case "plugins":
      return (
        <Suspense fallback={null}>
          <PluginsPanel presentation="settings" />
        </Suspense>
      );
    case "terminal":
      return <TerminalPanel />;
    case "lsp":
      return <LspPanel />;
    case "maven":
      return <MavenSettingsPanel />;
    case "ai":
      return <AISettings />;
    case "ai-commit":
      return <AiCommitSettingsPanel />;
    case "logs":
      return <LogSettingsPanel onClose={onClose} />;
    case "updates":
      return <UpdatesPanel />;
  }
}
