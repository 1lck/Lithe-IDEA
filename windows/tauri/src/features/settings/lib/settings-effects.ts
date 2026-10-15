import {
  cacheFontsForBootstrap,
  cacheThemeForBootstrap,
} from "@/features/settings/lib/appearance-bootstrap";
import {
  resolveEffectiveTheme,
  subscribeSystemThemePreference,
} from "@/features/settings/lib/theme-resolution";
import { invoke } from "@/platform/tauri-core";
import type { Settings, Theme } from "@/features/settings/types/settings.types";
import { getUiRootAttributes } from "@/features/settings/lib/ui-preferences";

const ALL_THEME_CLASSES = [
  "force-lithe-light",
  "force-lithe-dark",
  "force-vitesse-light",
  "force-vitesse-dark",
];

function applyFallbackTheme(theme: Theme) {
  console.log(`Settings store: Falling back to class-based theme "${theme}"`);
  ALL_THEME_CLASSES.forEach((cls) => document.documentElement.classList.remove(cls));
  document.documentElement.classList.add(`force-${theme}`);
}

let removeThemeSyncListener: (() => void) | null = null;
let latestThemeSyncSettings: Settings | null = null;
let cancelPendingThemeApplication: (() => void) | null = null;

function applyWindowTransparency(enabled: boolean) {
  if (typeof document === "undefined") return;

  document.documentElement.setAttribute(
    "data-window-transparency",
    enabled ? "enabled" : "disabled",
  );

}

function applyProjectGradient(enabled: boolean) {
  if (typeof document === "undefined") return;

  document.documentElement.setAttribute("data-project-gradient", enabled ? "enabled" : "disabled");
}

function applyUiPreferences(
  settings: Pick<Settings, "reduceMotion" | "showStatusBar" | "windowChromeDensity">,
) {
  if (typeof document === "undefined") return;

  for (const [name, value] of Object.entries(getUiRootAttributes(settings))) {
    document.documentElement.setAttribute(name, value);
  }
}

function stopSystemThemeSync() {
  removeThemeSyncListener?.();
  removeThemeSyncListener = null;
  latestThemeSyncSettings = null;
}

function syncThemeWithSystem(settings: Settings) {
  latestThemeSyncSettings = settings;
  const handleChange = () => {
    if (latestThemeSyncSettings) {
      return applyTheme(resolveEffectiveTheme(latestThemeSyncSettings), true);
    }
  };

  if (removeThemeSyncListener) {
    return;
  }

  removeThemeSyncListener = subscribeSystemThemePreference(handleChange);
}

async function applyTheme(theme: Theme, syncSystemTheme: boolean) {
  if (typeof window === "undefined") return;

  try {
    const { themeRegistry } = await import("@/extensions/themes/theme-registry");

    const applyRegisteredTheme = () => {
      themeRegistry.applyTheme(theme);
      const appliedTheme = themeRegistry.getTheme(theme);
      if (appliedTheme) {
        cacheThemeForBootstrap(appliedTheme);
        return syncNativeWindowAppearance(
          syncSystemTheme ? "system" : appliedTheme.isDark ? "dark" : "light",
        );
      }
    };

    const waitForThemeRegistration = () => {
      cancelPendingThemeApplication?.();
      cancelPendingThemeApplication = themeRegistry.onRegistryChange(() => {
        if (!themeRegistry.getTheme(theme)) return;
        cancelPendingThemeApplication?.();
        cancelPendingThemeApplication = null;
        applyRegisteredTheme();
      });
    };

    if (!themeRegistry.isRegistryReady()) {
      themeRegistry.onReady(() => {
        if (themeRegistry.getTheme(theme)) {
          applyRegisteredTheme();
        } else {
          waitForThemeRegistration();
        }
      });
      return;
    }

    if (!themeRegistry.getTheme(theme)) {
      waitForThemeRegistration();
      return;
    }

    cancelPendingThemeApplication?.();
    cancelPendingThemeApplication = null;
    return applyRegisteredTheme();
  } catch (error) {
    console.error("Failed to apply theme via registry:", error);
    applyFallbackTheme(theme);
  }
}

function syncNativeWindowAppearance(themeType: "system" | "light" | "dark") {
  const transparencyEnabled =
    typeof document === "undefined"
      ? true
      : document.documentElement.getAttribute("data-window-transparency") !== "disabled";

  return invoke("set_native_window_appearance", { themeType, transparencyEnabled }).catch((error) => {
    console.warn("Failed to sync native window appearance", error);
  });
}

function cacheFontSettings(settings: Pick<Settings, "fontFamily" | "uiFontFamily" | "uiFontSize">) {
  cacheFontsForBootstrap(settings.fontFamily, settings.uiFontFamily, settings.uiFontSize);
}

function syncOllamaBaseUrl(baseUrl: string) {
  if (!baseUrl) {
    return;
  }

  void import("@/features/ai/services/providers/ai-provider-registry").then(
    ({ setOllamaBaseUrl }) => {
      setOllamaBaseUrl(baseUrl);
    },
  );
}

function syncCustomProviderBaseUrl(baseUrl: string) {
  void import("@/features/ai/services/providers/ai-provider-registry").then(
    ({ setCustomProviderBaseUrl }) => {
      setCustomProviderBaseUrl(baseUrl);
    },
  );
}

/**
 * Pushes the Ollama API key (stored in Tauri's secure storage) into the
 * singleton provider instance so `getModels`, connection checks, and other
 * non-streaming calls can authenticate with Ollama Cloud.
 */
async function syncOllamaApiKey() {
  const [{ setOllamaApiKey }, { getProviderApiToken }] = await Promise.all([
    import("@/features/ai/services/providers/ai-provider-registry"),
    import("@/features/ai/services/ai-token-service"),
  ]);
  const token = await getProviderApiToken("ollama");
  setOllamaApiKey(token);
}

export function applySettingsSideEffects(settings: Settings) {
  cacheFontSettings(settings);
  applyWindowTransparency(settings.windowTransparency);
  applyProjectGradient(settings.differentiateProjects);
  applyUiPreferences(settings);
  void applyTheme(resolveEffectiveTheme(settings), settings.syncSystemTheme);
  if (settings.syncSystemTheme) {
    syncThemeWithSystem(settings);
  } else {
    stopSystemThemeSync();
  }
  syncOllamaBaseUrl(settings.ollamaBaseUrl);
  syncCustomProviderBaseUrl(settings.aiCustomBaseUrl);
  void syncOllamaApiKey();
}

export function applySettingSideEffect<K extends keyof Settings>(
  key: K,
  value: Settings[K],
  getSettings: () => Settings,
) {
  if (key === "theme") {
    const settings = getSettings();
    return applyTheme(resolveEffectiveTheme(settings), settings.syncSystemTheme);
  }

  if (key === "syncSystemTheme" || key === "autoThemeLight" || key === "autoThemeDark") {
    const settings = getSettings();
    if (settings.syncSystemTheme) {
      syncThemeWithSystem(settings);
    } else {
      stopSystemThemeSync();
    }
    return applyTheme(resolveEffectiveTheme(settings), settings.syncSystemTheme);
  }

  if (key === "ollamaBaseUrl") {
    syncOllamaBaseUrl(value as string);
  }

  if (key === "aiCustomBaseUrl") {
    syncCustomProviderBaseUrl(value as string);
  }

  if (key === "fontFamily" || key === "uiFontFamily" || key === "uiFontSize") {
    cacheFontSettings(getSettings());
  }

  if (key === "windowTransparency") {
    applyWindowTransparency(value as boolean);
  }

  if (key === "differentiateProjects") {
    applyProjectGradient(value as boolean);
  }

  if (key === "reduceMotion" || key === "showStatusBar" || key === "windowChromeDensity") {
    applyUiPreferences(getSettings());
  }
}
