import { useExtensionStore } from "@/extensions/registry/extension-store";
import { extensionRegistry } from "@/extensions/registry/extension-registry";
import { initializeGeneratedUIExtensions } from "./generated-ui-extension-installer";
import { uiExtensionHost } from "./ui-extension-host";

export async function initializeUIExtensions(): Promise<void> {
  const { availableExtensions, installedExtensions } = useExtensionStore.getState();

  const uiExtensions = Array.from(availableExtensions.values()).filter(
    (ext) =>
      Boolean(ext.manifest.main) &&
      ext.isEnabled &&
      extensionRegistry.getExtension(ext.manifest.id)?.isEnabled === true &&
      installedExtensions.get(ext.manifest.id)?.enabled !== false &&
      installedExtensions.has(ext.manifest.id),
  );

  const loadPromises = uiExtensions.map((ext) =>
    uiExtensionHost.loadExtension(ext.manifest, "").catch((error) => {
      console.error(`Failed to initialize UI extension ${ext.manifest.id}:`, error);
    }),
  );

  await Promise.allSettled(loadPromises);
  initializeGeneratedUIExtensions();
}
