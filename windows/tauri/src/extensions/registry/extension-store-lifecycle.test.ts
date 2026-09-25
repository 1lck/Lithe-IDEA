import { afterEach, expect, test } from "bun:test";
import { v0ExtensionManifest } from "@lithe/v0/manifest";
import { getProvider } from "@/features/ai/services/providers/ai-provider-registry";
import { unregisterAIProviderExtension } from "@/features/ai/services/providers/ai-provider-registry";
import { deactivateExtensionContributions } from "../runtime/extension-contribution-runtime";
import { markBundledContributionExtensionUninstalled } from "./bundled-contribution-install-state";
import { extensionRegistry } from "./extension-registry";
import { installExtensionLifecycle, updateExtensionLifecycle } from "./extension-store-lifecycle";

afterEach(async () => {
  await deactivateExtensionContributions(v0ExtensionManifest.id, v0ExtensionManifest);
  unregisterAIProviderExtension(v0ExtensionManifest.id);
  markBundledContributionExtensionUninstalled(v0ExtensionManifest.id);
  extensionRegistry.unregisterExtension(v0ExtensionManifest.id);
});

test("updating a disabled bundled plugin never activates its runtime contribution", async () => {
  const extension = {
    manifest: v0ExtensionManifest,
    isInstalled: true,
    isEnabled: false,
    isInstalling: false,
  };
  extensionRegistry.registerExtension(v0ExtensionManifest, {
    isEnabled: false,
    state: "deactivated",
  });

  await updateExtensionLifecycle({
    extensionId: v0ExtensionManifest.id,
    extension,
    clearInstalledStateForUpdate: () => {},
    reinstall: (activateAfterInstall) =>
      installExtensionLifecycle({
        extensionId: v0ExtensionManifest.id,
        extension,
        activateAfterInstall,
        onProgress: () => {},
        onLanguageInstalled: () => {},
        onNonLanguageInstalled: () => {},
        reloadInstalledExtensions: async () => {},
      }),
  });

  expect(extensionRegistry.getExtension(v0ExtensionManifest.id)?.isEnabled).toBe(false);
  expect(getProvider("v0")).toBeUndefined();
});
