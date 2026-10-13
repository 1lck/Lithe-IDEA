import { useSettingsStore } from "@/features/settings/stores/settings.store";
import { logger } from "@/features/editor/utils/logger";
import { registerBuiltinIconTheme } from "../runtime/extension-contribution-runtime";
import { loadBundledIconThemeAssets } from "./bundled-icon-theme-assets";
import { iconThemeRegistry } from "./icon-theme-registry";
import { builtinIconThemes } from "./builtin-icon-themes";

let initialized = false;
let requestedThemeId = "";
let requestVersion = 0;

export async function initializeIconThemes(): Promise<void> {
  if (initialized) return;
  initialized = true;

  const activateSelectedTheme = async (themeId: string, version: number) => {
    const entry = builtinIconThemes.find((theme) => theme.id === themeId);
    if (!entry) {
      iconThemeRegistry.unregisterThemesByExtension("builtin.icon-themes");
      return;
    }

    try {
      const manifest = await entry.load();
      const assets = await loadBundledIconThemeAssets(manifest.id);
      if (version !== requestVersion) return;
      registerBuiltinIconTheme(manifest, themeId, assets);
    } catch (error) {
      logger.error("IconThemes", `Failed to load built-in icon theme ${themeId}:`, error);
    }
  };

  const selectTheme = () => {
    const themeId = useSettingsStore.getState().settings.iconTheme;
    if (themeId === requestedThemeId) return Promise.resolve();
    requestedThemeId = themeId;
    return activateSelectedTheme(themeId, ++requestVersion);
  };

  useSettingsStore.subscribe((state, previousState) => {
    if (state.settings.iconTheme !== previousState.settings.iconTheme) {
      void selectTheme();
    }
  });

  await selectTheme();
}
