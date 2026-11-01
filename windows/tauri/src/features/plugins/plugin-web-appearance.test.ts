import { expect, spyOn, test } from "bun:test";
import { readFileSync } from "node:fs";
import { Window } from "happy-dom";
import { themeRegistry } from "@/extensions/themes/theme-registry";
import { useSettingsStore } from "@/features/settings/stores/settings.store";
import * as native from "@/platform/tauri-core";
import { installHappyDom } from "@/test-utils/happy-dom";
import { getPluginWebAppearance, initializePluginWebAppearanceSync } from "./plugin-web-appearance";

test("plugin appearance uses resolved workbench colors, fonts and locale", () => {
  const restore = installHappyDom();
  const current = useSettingsStore.getState();
  const getState = spyOn(useSettingsStore, "getState").mockReturnValue({
    ...current,
    settings: {
      ...current.settings,
      uiFontFamily: "Test UI",
      uiFontSize: 15,
      fontFamily: "Test Mono",
    },
  });
  try {
    const root = document.documentElement;
    root.setAttribute("data-theme-type", "dark");
    root.style.setProperty("--background", "#101010");
    root.style.setProperty("--app-font-family", "Test UI");
    root.style.setProperty("--editor-font-family", "Test Mono");
    const appearance = getPluginWebAppearance();
    expect(appearance.locale).toBe(useSettingsStore.getState().settings.displayLanguage);
    expect(appearance.theme).toBe("dark");
    expect(appearance.variables["--lithe-background"]).toBe("#101010");
    expect(appearance.variables["--lithe-font-family"]).toStartWith('"Test UI",');
    expect(appearance.variables["--lithe-font-size"]).toBe("15px");
    expect(appearance.variables["--lithe-code-font-family"]).toStartWith('"Test Mono",');
    expect(appearance.variables["--lithe-code-font-size"]).toBe(
      `${useSettingsStore.getState().settings.fontSize}px`,
    );
  } finally {
    getState.mockRestore();
    restore();
  }
});

test("theme updates reach native pages and unsubscribe at bootstrap cleanup", () => {
  const restore = installHappyDom();
  let changed = () => {};
  let stopped = false;
  const subscribe = spyOn(themeRegistry, "onThemeChange").mockImplementation((callback) => {
    changed = () => callback("fixture");
    return () => {
      stopped = true;
    };
  });
  const invoke = spyOn(native, "invoke").mockResolvedValue(undefined);
  const stop = initializePluginWebAppearanceSync();
  try {
    document.documentElement.setAttribute("data-theme-type", "dark");
    changed();
    expect(invoke).toHaveBeenCalledWith("declarative_plugins_web_update_appearance", {
      appearance: expect.objectContaining({ theme: "dark" }),
    });
  } finally {
    stop();
    expect(stopped).toBe(true);
    subscribe.mockRestore();
    invoke.mockRestore();
    restore();
  }
});

// Execute the exact native document-start bootstrap rather than a JS copy.
const source = readFileSync(
  new URL("../../../src-tauri/src/plugin_host/web.rs", import.meta.url),
  "utf8",
);
const template = source.match(/fn const_bridge_script[\s\S]*?r#"([\s\S]*?)"#/u)?.[1];
if (!template) throw new Error("native plugin bootstrap not found");
const bootstrap = template
  .replace("__LITHE_PAGE_GENERATION__", "1")
  .replace(
    "__LITHE_CONTEXT__",
    JSON.stringify({
      pluginID: "acme.php",
      windowID: "panel",
      platform: "windows",
      locale: "zh-CN",
    }),
  )
  .replace(
    "__LITHE_APPEARANCE__",
    JSON.stringify({
      locale: "zh-CN",
      theme: "dark",
      variables: { "--lithe-background": "#101010" },
    }),
  );

function runBootstrap(page: Window) {
  new Function("window", "document", bootstrap)(page, page.document);
  return page as unknown as {
    lithe?: {
      context: { locale: string; theme: string };
      on: (event: string, listener: (payload: { theme: string }) => void) => () => void;
    };
    __litheDeliverEvent: (event: string, payload: unknown) => void;
  };
}

test("native bridge provides context and root tokens before page code and updates them live", () => {
  const page = new Window({ url: "http://lithe-plugin.acme.php/ui/index.html" });
  try {
    const bridge = runBootstrap(page);
    expect(Object.isFrozen(bridge.lithe!.context)).toBe(true);
    expect(bridge.lithe!.context.locale).toBe("zh-CN");
    expect(bridge.lithe!.context.theme).toBe("dark");
    expect(page.document.documentElement.dataset.theme).toBe("dark");
    expect(page.document.documentElement.style.getPropertyValue("--lithe-background")).toBe(
      "#101010",
    );
    const received: string[] = [];
    bridge.lithe!.on("ui.themeChanged", (value) => {
      received.push(value.theme);
    });
    bridge.__litheDeliverEvent("ui.themeChanged", {
      locale: "en-US",
      theme: "light",
      variables: { "--lithe-background": "#ffffff" },
    });
    expect(bridge.lithe!.context.theme).toBe("light");
    expect(bridge.lithe!.context.locale).toBe("en-US");
    expect(received).toEqual(["light"]);
    expect(page.document.documentElement.dataset.theme).toBe("light");
    expect(page.document.documentElement.style.getPropertyValue("--lithe-background")).toBe(
      "#ffffff",
    );
  } finally {
    page.close();
  }
});

test("document-start bootstrap exposes no bridge to a foreign document", () => {
  for (const url of [
    "https://example.test/",
    "http://lithe-plugin.other.plugin/ui/index.html",
    "about:blank",
  ]) {
    const page = new Window({ url });
    try {
      expect(runBootstrap(page).lithe).toBeUndefined();
    } finally {
      page.close();
    }
  }
});
