import { getVersion } from "@tauri-apps/api/app";
import { useEffect, useState, type ReactNode } from "react";
import { useUpdater } from "@/features/settings/hooks/use-updater";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import {
  getProjectOpenPreference,
  getProjectOpenPreferencePatch,
  type ProjectOpenPreference,
} from "@/features/settings/lib/project-open-preference";
import { useTranslation } from "@/i18n/locale-provider";
import { Button } from "@/ui/button";
import Switch from "@/ui/switch";
import { LogSettingsPanel } from "./log-settings-panel";

export type MacSettingsCategory =
  | "general"
  | "editor"
  | "keyboard"
  | "terminal"
  | "lsp"
  | "ai"
  | "logs"
  | "updates";

const controlClassName =
  "h-8 rounded-md border border-input bg-background px-2.5 text-foreground outline-none focus:border-primary";

export function SettingsGroup({ title, children }: { title: string; children: ReactNode }) {
  // Avoid overflow:hidden/clip here: WebView2 latches wheel onto those boxes and
  // blocks scrolling the settings panel. Radius is applied on the chrome pieces.
  return (
    <section className="rounded-md border border-border bg-surface/35">
      <h3 className="rounded-t-md border-border border-b px-3 py-2 ui-text-sm font-medium text-subtle-foreground">
        {title}
      </h3>
      <div className="flex flex-col gap-3 rounded-b-md p-3">{children}</div>
    </section>
  );
}

export function SettingsRow({
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

function GeneralPanel() {
  const { t } = useTranslation();
  const settings = useSettingsStore((state) => state.settings);
  const updateSetting = useSettingsStore((state) => state.actions.updateSetting);
  const projectPlacement = getProjectOpenPreference(settings);
  const [gitPolicy, setGitPolicy] = useState("ask");
  const [directoryPatterns, setDirectoryPatterns] = useState(
    settings.hiddenDirectoryPatterns.join("\n"),
  );
  const [filePatterns, setFilePatterns] = useState(settings.hiddenFilePatterns.join("\n"));

  const appearanceMode = settings.syncSystemTheme
    ? "system"
    : settings.theme.includes("light")
      ? "light"
      : "dark";

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
          <select className={`${controlClassName} w-36`} value="lithe" disabled>
            <option value="lithe">Lithe</option>
          </select>
        </SettingsRow>
        <SettingsRow
          label={t("settings.mac.appearanceMode")}
          description={t("settings.mac.appearanceDescription")}
        >
          <select
            className={`${controlClassName} w-40`}
            value={appearanceMode}
            onChange={(event) => {
              const value = event.target.value;
              if (value === "system") {
                void updateSetting("syncSystemTheme", true);
                return;
              }
              void updateSetting("syncSystemTheme", false);
              void updateSetting("theme", value === "light" ? "lithe-light" : "lithe-dark");
            }}
          >
            <option value="system">{t("settings.mac.followSystem")}</option>
            <option value="light">{t("settings.mac.light")}</option>
            <option value="dark">{t("settings.mac.dark")}</option>
          </select>
        </SettingsRow>
      </SettingsGroup>

      <SettingsGroup title={t("settings.mac.language")}>
        <SettingsRow
          label={t("settings.mac.language")}
          description={t("settings.mac.languageDescription")}
        >
          <select
            className={`${controlClassName} w-40`}
            value={settings.displayLanguage}
            onChange={(event) =>
              void updateSetting("displayLanguage", event.target.value as "en-US" | "zh-CN")
            }
          >
            <option value="en-US">English</option>
            <option value="zh-CN">简体中文</option>
          </select>
        </SettingsRow>
      </SettingsGroup>

      <SettingsGroup title={t("settings.mac.projects")}>
        <SettingsRow
          label={t("settings.mac.openProjectsIn")}
          description={t("settings.mac.openProjectsDescription")}
        >
          <select
            className={`${controlClassName} w-40`}
            value={projectPlacement}
            onChange={(event) => {
              const patch = getProjectOpenPreferencePatch(
                event.target.value as ProjectOpenPreference,
              );
              if (patch.openFoldersInNewWindow !== undefined) {
                void updateSetting("openFoldersInNewWindow", patch.openFoldersInNewWindow);
              }
              void updateSetting(
                "askWhereToOpenProjects",
                patch.askWhereToOpenProjects ?? true,
              );
            }}
          >
            <option value="ask">{t("settings.mac.askEveryTime")}</option>
            <option value="this-window">{t("settings.mac.thisWindow")}</option>
            <option value="new-window">{t("settings.mac.newWindow")}</option>
          </select>
        </SettingsRow>
      </SettingsGroup>

      <SettingsGroup title={t("settings.mac.files")}>
        <SettingsRow
          label={t("settings.editor.autoSave")}
          description={t("settings.editor.autoSaveDescription")}
        >
          <Switch
            checked={settings.autoSave}
            onChange={(checked) => void updateSetting("autoSave", checked)}
            size="md"
          />
        </SettingsRow>
      </SettingsGroup>

      <SettingsGroup title={t("settings.mac.git")}>
        <SettingsRow
          label={t("settings.mac.saveLocalChangesWith")}
          description={t("settings.mac.gitPolicyDescription")}
        >
          <select
            className={`${controlClassName} w-40`}
            value={gitPolicy}
            onChange={(event) => setGitPolicy(event.target.value)}
          >
            <option value="ask">{t("settings.mac.askEveryTime")}</option>
            <option value="shelf">{t("settings.mac.shelf")}</option>
            <option value="stash">{t("settings.mac.gitStash")}</option>
          </select>
        </SettingsRow>
      </SettingsGroup>

      <SettingsGroup title={t("settings.mac.hiddenPaths")}>
        <p className="ui-text-caption leading-relaxed text-subtle-foreground">
          {t("settings.mac.hiddenPathsDescription")}
        </p>
        <label className="flex flex-col gap-1.5 ui-text-sm text-foreground">
          {t("settings.mac.directories")}
          <textarea
            className="min-h-18 resize-y rounded-md border border-input bg-background p-2 font-mono ui-text-sm outline-none focus:border-primary"
            value={directoryPatterns}
            onChange={(event) => setDirectoryPatterns(event.target.value)}
          />
        </label>
        <label className="flex flex-col gap-1.5 ui-text-sm text-foreground">
          {t("settings.mac.filePatterns")}
          <textarea
            className="min-h-14 resize-y rounded-md border border-input bg-background p-2 font-mono ui-text-sm outline-none focus:border-primary"
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
      <SettingsGroup title={t("settings.mac.files")}>
        <SettingsRow
          label={t("settings.editor.autoSave")}
          description={t("settings.editor.autoSaveDescription")}
        >
          <Switch
            checked={settings.autoSave}
            onChange={(checked) => void updateSetting("autoSave", checked)}
            size="md"
          />
        </SettingsRow>
      </SettingsGroup>
      <SettingsGroup title={t("settings.mac.display")}>
        <SettingsRow label={t("settings.mac.fontSize")}>
          <input
            type="number"
            min={10}
            max={22}
            className={`${controlClassName} w-20 text-right`}
            value={settings.fontSize}
            onChange={(event) => void updateSetting("fontSize", Number(event.target.value))}
          />
        </SettingsRow>
        <SettingsRow label={t("settings.mac.showCodeVision")}>
          <Switch
            checked={settings.codeLens}
            onChange={(checked) => void updateSetting("codeLens", checked)}
            size="sm"
          />
        </SettingsRow>
      </SettingsGroup>
      <SettingsGroup title={t("settings.mac.editorTabs")}>
        <SettingsRow label={t("settings.mac.layout")}>
          <select className={`${controlClassName} w-40`} defaultValue="single">
            <option value="single">{t("settings.mac.singleRow")}</option>
            <option value="wrap">{t("settings.mac.wrapRows")}</option>
          </select>
        </SettingsRow>
      </SettingsGroup>
      <SettingsGroup title={t("settings.mac.indentation")}>
        <SettingsRow label={t("settings.mac.tabWidth")}>
          <select
            className={`${controlClassName} w-32`}
            value={settings.tabSize}
            onChange={(event) => void updateSetting("tabSize", Number(event.target.value))}
          >
            {[2, 4, 8].map((size) => (
              <option key={size} value={size}>{`${size} ${t("settings.mac.spaces")}`}</option>
            ))}
          </select>
        </SettingsRow>
      </SettingsGroup>
    </div>
  );
}

function KeyboardPanel() {
  const { t } = useTranslation();
  const settings = useSettingsStore((state) => state.settings);
  const updateSetting = useSettingsStore((state) => state.actions.updateSetting);

  return (
    <div className="flex flex-col gap-4">
      <SettingsGroup title={t("settings.mac.keymapPreset")}>
        <SettingsRow label={t("settings.mac.preset")}>
          <select
            className={`${controlClassName} w-44`}
            value={settings.keybindingPreset}
            onChange={(event) =>
              void updateSetting(
                "keybindingPreset",
                event.target.value as typeof settings.keybindingPreset,
              )
            }
          >
            <option value="none">{t("settings.mac.keymapLithe")}</option>
            <option value="vscode">{t("settings.mac.keymapVisualStudioCode")}</option>
            <option value="jetbrains">{t("settings.mac.keymapJetBrains")}</option>
            <option value="xcode">{t("settings.mac.keymapXcode")}</option>
          </select>
        </SettingsRow>
      </SettingsGroup>
      <SettingsGroup title={t("settings.mac.shortcuts")}>
        <label className="flex h-8 items-center gap-2 rounded-md border border-input bg-background px-2.5 text-subtle-foreground">
          <span aria-hidden="true">⌕</span>
          <input
            className="min-w-0 flex-1 bg-transparent text-foreground outline-none"
            placeholder={t("settings.mac.searchShortcuts")}
          />
        </label>
        <p className="ui-text-sm leading-relaxed text-subtle-foreground">
          {t("settings.mac.shortcutsDescription")}
        </p>
      </SettingsGroup>
    </div>
  );
}

function TerminalPanel() {
  const { t } = useTranslation();
  const settings = useSettingsStore((state) => state.settings);
  const updateSetting = useSettingsStore((state) => state.actions.updateSetting);

  return (
    <SettingsGroup title={t("settings.mac.shell")}>
      <SettingsRow
        label={t("settings.mac.defaultShell")}
        description={t("settings.mac.defaultShellDescription")}
      >
        <select
          className={`${controlClassName} w-44`}
          value={settings.terminalDefaultShellId}
          onChange={(event) => void updateSetting("terminalDefaultShellId", event.target.value)}
        >
          <option value="">{t("settings.mac.systemDefault")}</option>
          <option value="powershell">{t("settings.mac.shellPowerShell")}</option>
          <option value="cmd">{t("settings.mac.shellCommandPrompt")}</option>
          <option value="wsl">{t("settings.mac.shellWsl")}</option>
        </select>
      </SettingsRow>
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

function AiPanel() {
  const { t } = useTranslation();
  const settings = useSettingsStore((state) => state.settings);
  const updateSetting = useSettingsStore((state) => state.actions.updateSetting);

  return (
    <div className="flex flex-col gap-4">
      <SettingsGroup title={t("settings.mac.aiProvider")}>
        <SettingsRow label={t("settings.mac.provider")}>
          <input
            className={`${controlClassName} w-52`}
            value={settings.aiProviderId}
            onChange={(event) => void updateSetting("aiProviderId", event.target.value)}
          />
        </SettingsRow>
        <SettingsRow label={t("settings.mac.apiUrl")}>
          <input
            className={`${controlClassName} w-72`}
            value={settings.aiCustomBaseUrl}
            onChange={(event) => void updateSetting("aiCustomBaseUrl", event.target.value)}
          />
        </SettingsRow>
        <SettingsRow label={t("settings.mac.model")}>
          <input
            className={`${controlClassName} w-52`}
            value={settings.aiModelId}
            onChange={(event) => void updateSetting("aiModelId", event.target.value)}
          />
        </SettingsRow>
        <SettingsRow label={t("settings.mac.apiKey")}>
          <div className="flex items-center gap-2">
            <input
              type="password"
              className={`${controlClassName} w-52`}
              placeholder={t("settings.mac.apiKeyPlaceholder")}
            />
            <Button variant="default" size="sm">
              {t("settings.mac.saveKey")}
            </Button>
          </div>
        </SettingsRow>
      </SettingsGroup>
      <SettingsGroup title={t("settings.mac.commitMessage")}>
        <SettingsRow label={t("settings.mac.enableAiCommit")}>
          <Switch
            checked={settings.aiCompletion}
            onChange={(checked) => void updateSetting("aiCompletion", checked)}
            size="sm"
          />
        </SettingsRow>
      </SettingsGroup>
    </div>
  );
}

function UpdatesPanel() {
  const { t } = useTranslation();
  const [appVersion, setAppVersion] = useState("");
  const [hasCheckedForUpdates, setHasCheckedForUpdates] = useState(false);
  const { checking, available, updateInfo, error, checkForUpdates } = useUpdater(false);

  useEffect(() => {
    void getVersion()
      .then(setAppVersion)
      .catch(() => setAppVersion(""));
  }, []);

  return (
    <div className="flex flex-col gap-4">
      <SettingsGroup title={t("settings.mac.softwareUpdate")}>
        <SettingsRow
          label="Lithe"
          description={t("settings.mac.currentVersion", { version: appVersion || "…" })}
        >
          <Button
            variant="accent"
            size="sm"
            disabled={checking}
            onClick={() => {
              setHasCheckedForUpdates(true);
              void checkForUpdates({ ignoreSuppression: true });
            }}
          >
            {checking ? t("settings.mac.checking") : t("settings.mac.checkForUpdates")}
          </Button>
        </SettingsRow>
        <p className="ui-text-sm text-subtle-foreground" role="status">
          {error
            ? t("settings.mac.updateFailed")
            : available
              ? t("settings.mac.updateAvailable", { version: updateInfo?.version ?? "" })
              : hasCheckedForUpdates
                ? t("settings.mac.upToDate")
                : t("settings.mac.updateHint")}
        </p>
      </SettingsGroup>
    </div>
  );
}

export function MacSettingsPanel({
  category,
  onClose,
}: {
  category: MacSettingsCategory;
  onClose: () => void;
}) {
  switch (category) {
    case "general":
      return <GeneralPanel />;
    case "editor":
      return <EditorPanel />;
    case "keyboard":
      return <KeyboardPanel />;
    case "terminal":
      return <TerminalPanel />;
    case "lsp":
      return <LspPanel />;
    case "ai":
      return <AiPanel />;
    case "logs":
      return <LogSettingsPanel onClose={onClose} />;
    case "updates":
      return <UpdatesPanel />;
  }
}
