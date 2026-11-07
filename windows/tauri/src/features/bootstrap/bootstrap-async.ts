import { reportBootstrapResults } from "./bootstrap-errors";
import { isBackendCapabilityAvailable } from "@/config/backend-capabilities";

const asyncBootstrapSteps = [
  {
    name: "settings store",
    run: async () => {
      const { initializeSettingsStore } = await import("@/features/settings/stores/settings.store");
      await initializeSettingsStore();
      const { initializeIconThemes } =
        await import("@/extensions/icon-themes/icon-theme-initializer");
      await initializeIconThemes();
    },
  },
  {
    name: "theme system",
    run: async () => {
      const { initializeThemeSystem } = await import("@/extensions/themes/theme-initializer");
      await initializeThemeSystem();
    },
  },
  {
    name: "wasm tokenizer",
    run: async () => {
      const { initializeWasmTokenizer } =
        await import("@/features/editor/lib/wasm-parser/wasm-parser-api");
      await initializeWasmTokenizer();
    },
  },
  {
    name: "extension loader",
    run: async () => {
      const { extensionLoader } = await import("@/extensions/loader/extension-loader");
      await extensionLoader.initialize();
    },
  },
  {
    name: "extension store",
    run: async () => {
      if (!isBackendCapabilityAvailable("extensions")) return;
      const { initializeExtensionStore } = await import("@/extensions/registry/extension-store");
      await initializeExtensionStore();
    },
  },
  {
    name: "declarative plugins",
    run: async () => {
      const { rescanDeclarativePlugins } =
        await import("@/features/plugins/declarative-plugin-launch");
      const { initializePluginWebListeners } = await import("@/features/plugins/plugin-web-open-file");
      await initializePluginWebListeners();
      await rescanDeclarativePlugins();
      const { refreshDeclarativeUI } = await import("@/features/plugins/declarative-plugin-ui");
      await refreshDeclarativeUI();
      const { startBuildSystemsRuntime } = await import(
        "@/features/build-systems/build-systems-service"
      );
      // Registers the plugin-lifecycle listener (catalog and registry
      // revocation on disable/replace/uninstall) and warms the catalog.
      // Detection runs when a build tool window mounts for the active
      // workspace; the sync watcher lives with that window and is released
      // when its last tool window unmounts. The returned cleanup is also
      // wired to pagehide inside the service, so a destroyed window never
      // keeps the listener alive.
      await startBuildSystemsRuntime();
    },
  },
] as const;

export async function runAsyncBootstrapSteps(): Promise<void> {
  const results = await Promise.allSettled(asyncBootstrapSteps.map((step) => step.run()));
  reportBootstrapResults(asyncBootstrapSteps, results);

  const extensionStoreResult = results[4];
  if (!isBackendCapabilityAvailable("extensions") || extensionStoreResult.status === "rejected") {
    return;
  }

  const uiExtensionSteps = [
    {
      name: "ui extensions",
      run: async () => {
        const { initializeUIExtensions } =
          await import("@/extensions/ui/services/ui-extension-initializer");
        await initializeUIExtensions();
      },
    },
  ] as const;
  const uiExtensionResults = await Promise.allSettled(uiExtensionSteps.map((step) => step.run()));
  reportBootstrapResults(uiExtensionSteps, uiExtensionResults);
}
