import type { ExtensionManifest } from "@/extensions/types/extension-manifest";
import { V0_EXTENSION_ID } from "@lithe/v0/manifest";

interface ExtensionActivationContext {
  extensionId: string;
  manifest: ExtensionManifest;
}

interface BundledContributionModule {
  activate: (context: ExtensionActivationContext) => void | Promise<void>;
  deactivate: (context: ExtensionActivationContext) => void | Promise<void>;
}

const bundledContributionModules = new Map<string, () => Promise<BundledContributionModule>>([
  [V0_EXTENSION_ID, async () => (await import("@lithe/v0/v0-extension")).v0ExtensionModule],
]);
const activeModules = new Map<string, BundledContributionModule>();
const activatingModules = new Map<string, Promise<void>>();

export async function activateBundledContributionModule(
  extensionId: string,
  manifest: ExtensionManifest,
): Promise<void> {
  const load = bundledContributionModules.get(extensionId);
  if (!load || activeModules.has(extensionId)) return;
  const pending = activatingModules.get(extensionId);
  if (pending) return pending;
  const activation = (async () => {
    const module = await load();
    try {
      await module.activate({ extensionId, manifest });
      activeModules.set(extensionId, module);
    } catch (error) {
      await module.deactivate({ extensionId, manifest });
      throw error;
    }
  })();
  activatingModules.set(extensionId, activation);
  try {
    await activation;
  } finally {
    activatingModules.delete(extensionId);
  }
}

export async function deactivateBundledContributionModule(
  extensionId: string,
  manifest: ExtensionManifest,
): Promise<void> {
  await activatingModules.get(extensionId)?.catch(() => undefined);
  const module = activeModules.get(extensionId);
  if (!module) return;
  await module.deactivate({ extensionId, manifest });
  activeModules.delete(extensionId);
}
