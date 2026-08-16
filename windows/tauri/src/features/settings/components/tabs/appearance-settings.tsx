import { invoke } from "@/platform/tauri-core";
import { FilePlusIcon, TrashIcon, UploadIcon } from "@/ui/icons";
import { iconThemeRegistry } from "@/extensions/icon-themes/icon-theme-registry";
import { useRegisteredIconThemes } from "@/extensions/icon-themes/use-registered-icon-themes";
import { themeRegistry } from "@/extensions/themes/theme-registry";
import { useRegisteredThemes } from "@/extensions/themes/use-registered-themes";
import { useMemo, useState } from "react";
import { useShallow } from "zustand/react/shallow";
import { getServiceUrls } from "@/config/services";
import { CustomThemeCreatorDialog } from "@/features/settings/components/custom-theme-creator-dialog";
import {
  formatUiFontSize,
  UI_FONT_SIZE_MAX,
  UI_FONT_SIZE_MIN,
  UI_FONT_SIZE_STEP,
} from "@/features/settings/lib/ui-font-size";
import { getDefaultSetting, useSettingsStore } from "@/features/settings/stores/settings.store";
import type {
  TabCloseButtonVisibility,
  WindowChromeDensity,
} from "@/features/settings/types/settings.types";
import { Button } from "@/ui/button";
import NumberInput from "@/ui/number-input";
import Section, { SETTINGS_CONTROL_WIDTHS, SettingsView, SettingRow } from "../settings-section";
import Select from "@/ui/select";
import Switch from "@/ui/switch";
import { cn } from "@/utils/cn";
import { IS_LINUX, IS_MAC, IS_WINDOWS } from "@/utils/platform";
import { FontSelector } from "../font-selector";
import { toast } from "sonner";
import {
  chooseThemeFile,
  deleteCustomTheme,
  uploadTheme,
} from "@/features/settings/utils/theme-upload";
import { useTranslation } from "@/i18n/locale-provider";

export const AppearanceSettings = () => {
  const { t } = useTranslation();
  const settings = useSettingsStore(
    useShallow((state) => ({
      autoThemeDark: state.settings.autoThemeDark,
      autoThemeLight: state.settings.autoThemeLight,
      activityRailExpanded: state.settings.activityRailExpanded,
      activityRailWidth: state.settings.activityRailWidth,
      compactMenuBar: state.settings.compactMenuBar,
      iconTheme: state.settings.iconTheme,
      nativeMenuBar: state.settings.nativeMenuBar,
      openFoldersInNewWindow: state.settings.openFoldersInNewWindow,
      reduceMotion: state.settings.reduceMotion,
      showStatusBar: state.settings.showStatusBar,
      showTabIcons: state.settings.showTabIcons,
      sidebarWidth: state.settings.sidebarWidth,
      syncSystemTheme: state.settings.syncSystemTheme,
      tabCloseButtonVisibility: state.settings.tabCloseButtonVisibility,
      theme: state.settings.theme,
      uiFontFamily: state.settings.uiFontFamily,
      uiFontSize: state.settings.uiFontSize,
      windowTransparency: state.settings.windowTransparency,
      windowChromeDensity: state.settings.windowChromeDensity,
    })),
  );
  const updateSetting = useSettingsStore((state) => state.actions.updateSetting);
  const registeredThemes = useRegisteredThemes();
  const registeredIconThemes = useRegisteredIconThemes();
  const [isThemeCreatorOpen, setIsThemeCreatorOpen] = useState(false);
  const themeDocsUrl = `${getServiceUrls().docsUrl}/themes`;
  const customThemes = useMemo(
    () =>
      registeredThemes.filter((theme) => themeRegistry.getThemeSource(theme.id)?.kind === "custom"),
    [registeredThemes],
  );

  const themeOptions = useMemo(
    () =>
      registeredThemes.map((theme) => ({
        value: theme.id,
        label: theme.name,
      })),
    [registeredThemes],
  );

  const normalizedThemeOptions = useMemo(() => {
    if (themeOptions.some((option) => option.value === settings.theme)) {
      return themeOptions;
    }

    const fallbackTheme = themeRegistry.getTheme(settings.theme);
    if (!fallbackTheme) {
      return themeOptions;
    }

    return [{ value: fallbackTheme.id, label: fallbackTheme.name }, ...themeOptions];
  }, [themeOptions, settings.theme]);

  const lightThemeOptions = useMemo(
    () =>
      normalizedThemeOptions.filter((option) => {
        const theme = themeRegistry.getTheme(option.value);
        return theme ? !theme.isDark : true;
      }),
    [normalizedThemeOptions],
  );

  const darkThemeOptions = useMemo(
    () =>
      normalizedThemeOptions.filter((option) => {
        const theme = themeRegistry.getTheme(option.value);
        return theme ? !!theme.isDark : true;
      }),
    [normalizedThemeOptions],
  );

  const iconThemeOptions = useMemo(
    () =>
      registeredIconThemes.map((theme) => ({
        value: theme.id,
        label: theme.name,
      })),
    [registeredIconThemes],
  );

  const normalizedIconThemeOptions = useMemo(() => {
    if (iconThemeOptions.some((option) => option.value === settings.iconTheme)) {
      return iconThemeOptions;
    }

    const fallbackIconTheme = iconThemeRegistry.getTheme(settings.iconTheme);
    if (!fallbackIconTheme) {
      return iconThemeOptions;
    }

    return [{ value: fallbackIconTheme.id, label: fallbackIconTheme.name }, ...iconThemeOptions];
  }, [iconThemeOptions, settings.iconTheme]);

  const selectImportedTheme = (themeId: string) => {
    const theme = themeRegistry.getTheme(themeId);
    if (!theme) return;

    if (!settings.syncSystemTheme) {
      void updateSetting("theme", themeId);
      return;
    }

    void updateSetting(theme.isDark ? "autoThemeDark" : "autoThemeLight", themeId);
  };

  const handleUploadTheme = () => {
    chooseThemeFile((file) => {
      void uploadTheme(file).then((result) => {
        if (!result.success || !result.theme) {
          toast.error(result.error ?? t("settings.appearance.importThemeFailed"), {
            description: result.details?.slice(0, 4).join("\n"),
          });
          return;
        }

        toast.success(
          result.themes?.length === 1
            ? t("settings.appearance.importedTheme", { theme: result.theme.name })
            : t("settings.appearance.importedThemeVariants", { count: result.themes?.length ?? 0 }),
        );
        selectImportedTheme(result.theme.id);
      });
    });
  };

  const handleRemoveCustomTheme = async (themeId: string) => {
    try {
      const fallbackUpdates: Promise<void>[] = [];
      if (settings.theme === themeId) {
        fallbackUpdates.push(updateSetting("theme", getDefaultSetting("theme")));
      }
      if (settings.autoThemeLight === themeId) {
        fallbackUpdates.push(updateSetting("autoThemeLight", getDefaultSetting("autoThemeLight")));
      }
      if (settings.autoThemeDark === themeId) {
        fallbackUpdates.push(updateSetting("autoThemeDark", getDefaultSetting("autoThemeDark")));
      }
      await Promise.all(fallbackUpdates);
      await deleteCustomTheme(themeId);
      toast.success(t("settings.appearance.customThemeRemoved"));
    } catch (error) {
      toast.error(t("settings.appearance.removeCustomThemeFailed"), {
        description: error instanceof Error ? error.message : String(error),
      });
    }
  };

  const handleIconThemeChange = (themeId: string) => {
    updateSetting("iconTheme", themeId);
  };

  return (
    <SettingsView>
      <Section title={t("settings.appearance.theme")}>
        <SettingRow
          label={t("settings.appearance.syncWithOs")}
          description={t("settings.appearance.syncWithOsDescription")}
          onReset={() => updateSetting("syncSystemTheme", getDefaultSetting("syncSystemTheme"))}
          canReset={settings.syncSystemTheme !== getDefaultSetting("syncSystemTheme")}
        >
          <Switch
            checked={settings.syncSystemTheme}
            onChange={(checked) => updateSetting("syncSystemTheme", checked)}
            size="sm"
          />
        </SettingRow>

        {!settings.syncSystemTheme ? (
          <SettingRow
            label={t("settings.appearance.colorTheme")}
            description={t("settings.appearance.colorThemeDescription")}
            onReset={() => updateSetting("theme", getDefaultSetting("theme"))}
            canReset={settings.theme !== getDefaultSetting("theme")}
          >
            <Select
              value={settings.theme}
              options={normalizedThemeOptions}
              onChange={(value) => updateSetting("theme", value)}
              className={SETTINGS_CONTROL_WIDTHS.wide}
              size="sm"
              variant="default"
              searchable
              searchableTrigger="input"
            />
          </SettingRow>
        ) : null}

        {settings.syncSystemTheme ? (
          <>
            <SettingRow
              label={t("settings.appearance.preferredLightTheme")}
              description={t("settings.appearance.preferredLightThemeDescription")}
              onReset={() => updateSetting("autoThemeLight", getDefaultSetting("autoThemeLight"))}
              canReset={settings.autoThemeLight !== getDefaultSetting("autoThemeLight")}
            >
              <Select
                value={settings.autoThemeLight}
                options={lightThemeOptions}
                onChange={(value) => updateSetting("autoThemeLight", value)}
                className={SETTINGS_CONTROL_WIDTHS.wide}
                size="sm"
                variant="default"
                searchable
                searchableTrigger="input"
              />
            </SettingRow>

            <SettingRow
              label={t("settings.appearance.preferredDarkTheme")}
              description={t("settings.appearance.preferredDarkThemeDescription")}
              onReset={() => updateSetting("autoThemeDark", getDefaultSetting("autoThemeDark"))}
              canReset={settings.autoThemeDark !== getDefaultSetting("autoThemeDark")}
            >
              <Select
                value={settings.autoThemeDark}
                options={darkThemeOptions}
                onChange={(value) => updateSetting("autoThemeDark", value)}
                className={SETTINGS_CONTROL_WIDTHS.wide}
                size="sm"
                variant="default"
                searchable
                searchableTrigger="input"
              />
            </SettingRow>
          </>
        ) : null}

        <SettingRow
          label={t("settings.appearance.iconTheme")}
          description={t("settings.appearance.iconThemeDescription")}
          onReset={() => updateSetting("iconTheme", getDefaultSetting("iconTheme"))}
          canReset={settings.iconTheme !== getDefaultSetting("iconTheme")}
        >
          <Select
            value={settings.iconTheme}
            options={normalizedIconThemeOptions}
            onChange={handleIconThemeChange}
            className={SETTINGS_CONTROL_WIDTHS.wide}
            size="sm"
            variant="default"
            searchable
            searchableTrigger="input"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.appearance.customThemes")}
          description={
            <>
              {t("settings.appearance.customThemesDescription")} {" "}
              <a
                href={themeDocsUrl}
                target="_blank"
                rel="noopener noreferrer"
                className="text-primary hover:underline"
              >
                {t("settings.appearance.formatGuide")}
              </a>
            </>
          }
        >
          <div className="flex items-center gap-2">
            <Button type="button" size="sm" onClick={() => setIsThemeCreatorOpen(true)}>
              <FilePlusIcon />
              {t("settings.appearance.create")}
            </Button>
            <Button type="button" size="sm" onClick={handleUploadTheme}>
              <UploadIcon />
              {t("settings.appearance.import")}
            </Button>
          </div>
        </SettingRow>

        {customThemes.map((theme) => (
          <SettingRow
            key={theme.id}
            label={theme.name}
            description={`${theme.category} custom theme · ${theme.id}`}
          >
            <Button
              type="button"
              size="icon-xs"
              variant="danger"
              tooltip={t("settings.appearance.removeTheme", { theme: theme.name })}
              onClick={() => void handleRemoveCustomTheme(theme.id)}
            >
              <TrashIcon />
            </Button>
          </SettingRow>
        ))}
      </Section>

      <Section title={t("settings.appearance.typography")}>
        <SettingRow
          label={t("settings.appearance.uiFontFamily")}
          description={t("settings.appearance.uiFontFamilyDescription")}
          onReset={() => updateSetting("uiFontFamily", getDefaultSetting("uiFontFamily"))}
          canReset={settings.uiFontFamily !== getDefaultSetting("uiFontFamily")}
        >
          <FontSelector
            value={settings.uiFontFamily}
            onChange={(fontFamily) => updateSetting("uiFontFamily", fontFamily)}
            className={SETTINGS_CONTROL_WIDTHS.text}
            monospaceOnly={false}
          />
        </SettingRow>

        <SettingRow
          label={t("settings.appearance.uiFontSize")}
          description={t("settings.appearance.uiFontSizeDescription")}
          onReset={() => updateSetting("uiFontSize", getDefaultSetting("uiFontSize"))}
          canReset={settings.uiFontSize !== getDefaultSetting("uiFontSize")}
        >
          <NumberInput
            min={String(UI_FONT_SIZE_MIN)}
            max={String(UI_FONT_SIZE_MAX)}
            step={String(UI_FONT_SIZE_STEP)}
            value={settings.uiFontSize}
            onChange={(value) => updateSetting("uiFontSize", value)}
            className={cn(SETTINGS_CONTROL_WIDTHS.number, "tabular-nums")}
            size="sm"
            aria-label={t("settings.appearance.uiFontSizeAria", {
              size: formatUiFontSize(settings.uiFontSize),
            })}
          />
        </SettingRow>
      </Section>

      <Section title={t("settings.appearance.interface")}>
        <SettingRow
          label={t("settings.appearance.reduceMotion")}
          description={t("settings.appearance.reduceMotionDescription")}
          onReset={() => updateSetting("reduceMotion", getDefaultSetting("reduceMotion"))}
          canReset={settings.reduceMotion !== getDefaultSetting("reduceMotion")}
        >
          <Switch
            checked={settings.reduceMotion}
            onChange={(checked) => updateSetting("reduceMotion", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.appearance.showStatusBar")}
          description={t("settings.appearance.showStatusBarDescription")}
          onReset={() => updateSetting("showStatusBar", getDefaultSetting("showStatusBar"))}
          canReset={settings.showStatusBar !== getDefaultSetting("showStatusBar")}
        >
          <Switch
            checked={settings.showStatusBar}
            onChange={(checked) => updateSetting("showStatusBar", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.appearance.showTabIcons")}
          description={t("settings.appearance.showTabIconsDescription")}
          onReset={() => updateSetting("showTabIcons", getDefaultSetting("showTabIcons"))}
          canReset={settings.showTabIcons !== getDefaultSetting("showTabIcons")}
        >
          <Switch
            checked={settings.showTabIcons}
            onChange={(checked) => updateSetting("showTabIcons", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.appearance.tabCloseButtons")}
          description={t("settings.appearance.tabCloseButtonsDescription")}
          onReset={() =>
            updateSetting("tabCloseButtonVisibility", getDefaultSetting("tabCloseButtonVisibility"))
          }
          canReset={
            settings.tabCloseButtonVisibility !== getDefaultSetting("tabCloseButtonVisibility")
          }
        >
          <Select
            value={settings.tabCloseButtonVisibility}
            options={[
              { value: "active", label: t("settings.appearance.activeAndHovered") },
              { value: "hover", label: t("settings.appearance.hoveredOnly") },
              { value: "always", label: t("settings.appearance.always") },
            ]}
            onChange={(value) =>
              updateSetting("tabCloseButtonVisibility", value as TabCloseButtonVisibility)
            }
            className={SETTINGS_CONTROL_WIDTHS.wide}
            size="sm"
            variant="default"
          />
        </SettingRow>
      </Section>

      <Section title={t("settings.appearance.layout")}>
        <SettingRow
          label={t("settings.appearance.windowChromeDensity")}
          description={t("settings.appearance.windowChromeDensityDescription")}
          onReset={() =>
            updateSetting("windowChromeDensity", getDefaultSetting("windowChromeDensity"))
          }
          canReset={settings.windowChromeDensity !== getDefaultSetting("windowChromeDensity")}
        >
          <Select
            value={settings.windowChromeDensity}
            options={[
              { value: "focused", label: t("settings.appearance.focused") },
              { value: "comfortable", label: t("settings.appearance.comfortable") },
            ]}
            onChange={(value) => updateSetting("windowChromeDensity", value as WindowChromeDensity)}
            className={SETTINGS_CONTROL_WIDTHS.wide}
            size="sm"
            variant="default"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.appearance.expandedActivityBar")}
          description={t("settings.appearance.expandedActivityBarDescription")}
          onReset={() =>
            updateSetting("activityRailExpanded", getDefaultSetting("activityRailExpanded"))
          }
          canReset={settings.activityRailExpanded !== getDefaultSetting("activityRailExpanded")}
        >
          <Switch
            checked={settings.activityRailExpanded}
            onChange={(checked) => updateSetting("activityRailExpanded", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.appearance.activityBarWidth")}
          description={t("settings.appearance.activityBarWidthDescription")}
          onReset={() => updateSetting("activityRailWidth", getDefaultSetting("activityRailWidth"))}
          canReset={settings.activityRailWidth !== getDefaultSetting("activityRailWidth")}
        >
          <NumberInput
            min={140}
            max={320}
            step={10}
            value={settings.activityRailWidth}
            onChange={(value) => updateSetting("activityRailWidth", value)}
            className={SETTINGS_CONTROL_WIDTHS.number}
            size="sm"
            disabled={!settings.activityRailExpanded}
            aria-label={t("settings.appearance.activityBarWidthAria", { size: settings.activityRailWidth })}
          />
        </SettingRow>

        <SettingRow
          label={t("settings.appearance.sidebarWidth")}
          description={t("settings.appearance.sidebarWidthDescription")}
          onReset={() => updateSetting("sidebarWidth", getDefaultSetting("sidebarWidth"))}
          canReset={settings.sidebarWidth !== getDefaultSetting("sidebarWidth")}
        >
          <NumberInput
            min={140}
            max={600}
            step={10}
            value={settings.sidebarWidth}
            onChange={(value) => updateSetting("sidebarWidth", value)}
            className={SETTINGS_CONTROL_WIDTHS.number}
            size="sm"
            aria-label={t("settings.appearance.sidebarWidthAria", { size: settings.sidebarWidth })}
          />
        </SettingRow>

        {!IS_MAC && !IS_WINDOWS && !IS_LINUX && (
          <SettingRow
            label={t("settings.appearance.nativeMenuBar")}
            description={t("settings.appearance.nativeMenuBarDescription")}
            onReset={() => updateSetting("nativeMenuBar", getDefaultSetting("nativeMenuBar"))}
            canReset={settings.nativeMenuBar !== getDefaultSetting("nativeMenuBar")}
          >
            <Switch
              checked={settings.nativeMenuBar}
              onChange={(checked) => {
                updateSetting("nativeMenuBar", checked);
                invoke("toggle_menu_bar", { toggle: checked });
              }}
              size="sm"
            />
          </SettingRow>
        )}

        {!IS_MAC && (
          <SettingRow
            label={t("settings.appearance.compactMenuBar")}
            description={t("settings.appearance.compactMenuBarDescription")}
            onReset={() => updateSetting("compactMenuBar", getDefaultSetting("compactMenuBar"))}
            canReset={settings.compactMenuBar !== getDefaultSetting("compactMenuBar")}
          >
            <Switch
              checked={settings.compactMenuBar}
              disabled={settings.nativeMenuBar}
              onChange={(checked) => updateSetting("compactMenuBar", checked)}
              size="sm"
            />
          </SettingRow>
        )}

        <SettingRow
          label={t("settings.appearance.windowTransparency")}
          description={t("settings.appearance.windowTransparencyDescription")}
          onReset={() =>
            updateSetting("windowTransparency", getDefaultSetting("windowTransparency"))
          }
          canReset={settings.windowTransparency !== getDefaultSetting("windowTransparency")}
        >
          <Switch
            checked={settings.windowTransparency}
            onChange={(checked) => updateSetting("windowTransparency", checked)}
            size="sm"
          />
        </SettingRow>

        <SettingRow
          label={t("settings.appearance.openProjectsNewWindow")}
          description={t("settings.appearance.openProjectsNewWindowDescription")}
          onReset={() =>
            updateSetting("openFoldersInNewWindow", getDefaultSetting("openFoldersInNewWindow"))
          }
          canReset={settings.openFoldersInNewWindow !== getDefaultSetting("openFoldersInNewWindow")}
        >
          <Switch
            checked={settings.openFoldersInNewWindow}
            onChange={(checked) => updateSetting("openFoldersInNewWindow", checked)}
            size="sm"
          />
        </SettingRow>
      </Section>

      {isThemeCreatorOpen ? (
        <CustomThemeCreatorDialog
          baseThemeId={settings.theme}
          themes={registeredThemes}
          onClose={() => setIsThemeCreatorOpen(false)}
          onInstalled={selectImportedTheme}
        />
      ) : null}
    </SettingsView>
  );
};
