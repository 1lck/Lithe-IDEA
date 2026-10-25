import { themeRegistry } from "@/extensions/themes/theme-registry";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { DEFAULT_MONO_FONT_FAMILY, DEFAULT_UI_FONT_FAMILY, getTypographyFontFallbacks } from "@/features/settings/config/typography-defaults";
import { buildFontFamilyStack } from "@/features/settings/lib/font-family-resolution";
import { normalizeUiFontSize } from "@/features/settings/lib/ui-font-size";
import { invoke } from "@/platform/tauri-core";
import { IS_WINDOWS } from "@/utils/platform";

export interface PluginWebAppearance {
  locale: string;
  theme: "light" | "dark";
  variables: Record<string, string>;
}

/** Shares the workbench's resolved tokens with package pages, like macOS. */
export function getPluginWebAppearance(): PluginWebAppearance {
  const root = document.documentElement;
  const style = getComputedStyle(root);
  const read = (name: string) => style.getPropertyValue(name).trim();
  const settings = useSettingsStore.getState().settings;
  const colorTokens: Record<string, string> = {
    background: "--background", surface: "--surface", header: "--tab-bar-bg",
    "popup-background": "--popover", foreground: "--foreground",
    "secondary-foreground": "--muted-foreground", border: "--border", accent: "--accent",
    link: "--info", success: "--success", warning: "--warning", error: "--destructive",
  };
  const variables = Object.fromEntries(Object.entries(colorTokens).map(([name, token]) =>
    [`--lithe-${name}`, read(token) || read("--foreground")],
  ));
  // Settings subscriptions run before FontStyleInjector's React effect. Reuse
  // its font resolution helpers so pages receive the new values immediately.
  const { mono, sans } = getTypographyFontFallbacks(IS_WINDOWS);
  variables["--lithe-font-family"] = buildFontFamilyStack(settings.uiFontFamily || DEFAULT_UI_FONT_FAMILY, sans);
  variables["--lithe-font-size"] = `${normalizeUiFontSize(settings.uiFontSize)}px`;
  variables["--lithe-code-font-family"] = buildFontFamilyStack(settings.fontFamily || DEFAULT_MONO_FONT_FAMILY, mono);
  variables["--lithe-code-font-size"] = `${settings.fontSize}px`;
  return {
    locale: settings.displayLanguage,
    theme: root.getAttribute("data-theme-type") === "dark" ? "dark" : "light",
    variables,
  };
}

/** Owns and releases both subscriptions with the workspace bootstrap. */
export function initializePluginWebAppearanceSync(): () => void {
  const sync = () => {
    void invoke("declarative_plugins_web_update_appearance", { appearance: getPluginWebAppearance() })
      .catch((error) => console.warn("Plugin page appearance update failed", error));
  };
  const stopTheme = themeRegistry.onThemeChange(sync);
  const stopSettings = useSettingsStore.subscribe((state, previous) => {
    if (state.settings.displayLanguage !== previous.settings.displayLanguage ||
        state.settings.fontSize !== previous.settings.fontSize ||
        state.settings.fontFamily !== previous.settings.fontFamily ||
        state.settings.uiFontFamily !== previous.settings.uiFontFamily ||
        state.settings.uiFontSize !== previous.settings.uiFontSize) sync();
  });
  return () => { stopTheme(); stopSettings(); };
}
