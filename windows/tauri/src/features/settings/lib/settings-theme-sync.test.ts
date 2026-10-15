import { expect, spyOn, test } from "bun:test";
import { getLitheDefaultTheme } from "@/extensions/themes/default-theme";
import { themeRegistry } from "@/extensions/themes/theme-registry";
import * as native from "@/platform/tauri-core";
import { installHappyDom } from "@/test-utils/happy-dom";
import { getDefaultSettingsSnapshot } from "../config/default-settings";
import { applySettingSideEffect } from "./settings-effects";

test("system theme releases a manual WebView appearance and tracks OS changes without leaking listeners", async () => {
  const restoreDom = installHappyDom();
  const settings = getDefaultSettingsSnapshot();
  const light = getLitheDefaultTheme("light").definition;
  const dark = getLitheDefaultTheme("dark").definition;
  const previousThemes = [themeRegistry.getTheme(light.id), themeRegistry.getTheme(dark.id)];
  const previousTheme = themeRegistry.getCurrentTheme();
  const ready = spyOn(themeRegistry, "isRegistryReady").mockReturnValue(true);
  const listeners = new Set<() => void | Promise<unknown>>();
  let osDark = true;
  let webViewDark = false;
  let nativeMode = "light";
  const mediaQuery = {
    get matches() { return webViewDark; },
    addEventListener: (_event: string, callback: () => void) => { listeners.add(callback); },
    removeEventListener: (_event: string, callback: () => void) => { listeners.delete(callback); },
  };
  const media = spyOn(window, "matchMedia").mockReturnValue(mediaQuery as unknown as MediaQueryList);
  const invoke = spyOn(native, "invoke").mockImplementation(async <T>(command: string, args?: Parameters<typeof native.invoke>[1]) => {
    if (command !== "set_native_window_appearance") throw new Error(`Unexpected native command: ${command}`);
    nativeMode = (args as { themeType: string }).themeType;
    // WebView2 sees the forced window theme until the native override is released.
    webViewDark = nativeMode === "system" ? osDark : nativeMode === "dark";
    return undefined as T;
  });
  const emitSystemChange = async (nextDark: boolean) => {
    osDark = nextDark;
    if (nativeMode === "system") webViewDark = osDark;
    for (const callback of listeners) await callback();
  };
  const appliedTheme = () => document.documentElement.getAttribute("data-theme");
  const apply = (key: "theme" | "syncSystemTheme" | "autoThemeDark") =>
    applySettingSideEffect(key, settings[key], () => settings);

  try {
    themeRegistry.registerTheme(light);
    themeRegistry.registerTheme(dark);
    settings.theme = light.id;
    settings.syncSystemTheme = false;
    await apply("theme");
    expect(appliedTheme()).toBe(light.id);
    expect(webViewDark).toBe(false);

    settings.syncSystemTheme = true;
    await apply("syncSystemTheme");
    expect(nativeMode).toBe("system");
    expect(webViewDark).toBe(true);
    expect(listeners.size).toBe(1);
    // The native ThemeChanged event follows the override reset, then future OS changes.
    await emitSystemChange(true);
    expect(appliedTheme()).toBe(dark.id);
    await emitSystemChange(false);
    expect(appliedTheme()).toBe(light.id);
    await emitSystemChange(true);
    expect(appliedTheme()).toBe(dark.id);
    expect(nativeMode).toBe("system");
    await apply("autoThemeDark");
    expect(listeners.size).toBe(1);

    settings.theme = dark.id;
    settings.syncSystemTheme = false;
    await apply("syncSystemTheme");
    expect(nativeMode).toBe("dark");
    expect(listeners.size).toBe(0);
    await emitSystemChange(false);
    expect(appliedTheme()).toBe(dark.id);

    settings.syncSystemTheme = true;
    await apply("syncSystemTheme");
    await emitSystemChange(false);
    expect(appliedTheme()).toBe(light.id);
    expect(listeners.size).toBe(1);
  } finally {
    settings.syncSystemTheme = false;
    try {
      await apply("syncSystemTheme");
    } finally {
      invoke.mockRestore();
      media.mockRestore();
      ready.mockRestore();
      themeRegistry.unregisterTheme(light.id);
      themeRegistry.unregisterTheme(dark.id);
      for (const theme of previousThemes) if (theme) themeRegistry.registerTheme(theme);
      if (previousTheme) themeRegistry.applyTheme(previousTheme);
      restoreDom();
    }
  }
});
