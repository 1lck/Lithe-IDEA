import { localExtensionPackages } from "../packages/local-extension-package";
import { extensionProcessOwner } from "@/extensions/run/extension-process-owner";
import { invoke } from "@/platform/tauri-core";
import { wasmParserLoader } from "@/features/editor/lib/wasm-parser/loader";
import { useBufferStore } from "@/features/editor/stores/buffer.store";
import { PLATFORM_ARCH } from "@/utils/platform";
import { getServiceUrls } from "@/config/services";
import { isBundledContributionExtension } from "../bundled/bundled-contribution-extensions";
import { extensionInstaller } from "../installer/extension-installer";
import {
  activateExtensionContributions,
  deactivateExtensionContributions,
} from "../runtime/extension-contribution-runtime";
import {
  getManifestLanguageContributions,
  matchesLanguageContribution,
} from "../types/extension-contributions";
import type { PlatformPackage } from "../types/extension-manifest";
import {
  markBundledContributionExtensionInstalled,
  markBundledContributionExtensionUninstalled,
} from "./bundled-contribution-install-state";
import { extensionRegistry } from "./extension-registry";
import {
  buildRuntimeManifest,
  installLanguageExtensionManifest,
  registerLanguageProvider,
  resolveToolPaths,
} from "./extension-store-runtime";
import type { AvailableExtension, ExtensionInstallationMetadata } from "./extension-store-types";

const languageInstalls = new Map<string, { cancelled: boolean; done: Promise<void> }>();

async function cancelLanguageInstall(extensionId: string, languageIds: string[]) {
  const pending = languageInstalls.get(extensionId);
  if (pending) pending.cancelled = true;
  for (const id of languageIds) extensionInstaller.cancelInstallation(id);
  await Promise.all(
    languageIds.map((languageId) => invoke("cancel_language_tool_install", { languageId })),
  );
  if (pending) await pending.done.catch(() => undefined);
}

async function refreshSyntaxHighlightingForActiveBuffer(extension: AvailableExtension) {
  const languages = getManifestLanguageContributions(extension.manifest);
  if (languages.length === 0) {
    return;
  }

  const bufferState = useBufferStore.getState();
  const activeBuffer = bufferState.buffers.find((buffer) => buffer.isActive);

  if (!activeBuffer) {
    return;
  }

  const matchesLanguage = languages.some((language) =>
    matchesLanguageContribution(activeBuffer.path, language),
  );

  if (!matchesLanguage) {
    return;
  }

  const { setSyntaxHighlightingFilePath } =
    await import("@/features/editor/extensions/builtin/syntax-highlighting");
  setSyntaxHighlightingFilePath(activeBuffer.path);
}

async function unloadLanguageProviders(extensionId: string, languageIds: string[]) {
  const { extensionManager } = await import("@/features/editor/extensions/manager");
  for (const providerId of [
    ...languageIds.map((languageId) => `${extensionId}:${languageId}`),
    extensionId, // Backward compatibility for previously loaded single-id providers.
  ]) {
    if (extensionManager.isExtensionLoaded(providerId)) {
      await extensionManager.unloadLanguageExtension(providerId);
    }
  }
}

async function uninstallLanguageArtifacts(languageIds: string[]) {
  await Promise.all(
    languageIds.map(async (languageId) => {
      wasmParserLoader.unloadParser(languageId);
      await extensionInstaller.uninstallLanguage(languageId);
    }),
  );
}

function withCdnCacheBuster(url: string): string {
  const extensionsCdnBaseUrl = getServiceUrls().extensionsCdnBaseUrl;
  if (!extensionsCdnBaseUrl || !url.startsWith(`${extensionsCdnBaseUrl}/`)) {
    return url;
  }

  const separator = url.includes("?") ? "&" : "?";
  return `${url}${separator}v=${Date.now()}`;
}

function resolveExtensionPackage(extension: AvailableExtension): PlatformPackage {
  const installation = extension.manifest.installation;
  const platformPackages = installation?.platformArch;
  const platformPackage = platformPackages?.[PLATFORM_ARCH];

  if (platformPackages) {
    if (isCompleteExtensionPackage(platformPackage)) {
      return {
        ...platformPackage,
        downloadUrl: withCdnCacheBuster(platformPackage.downloadUrl),
      };
    }

    throw new Error(
      `No compatible package for ${extension.manifest.displayName} on ${PLATFORM_ARCH}`,
    );
  }

  const genericPackage = installation
    ? {
        downloadUrl: installation.downloadUrl,
        checksum: installation.checksum,
        size: installation.size,
      }
    : undefined;

  if (isCompleteExtensionPackage(genericPackage)) {
    return {
      ...genericPackage,
      downloadUrl: withCdnCacheBuster(genericPackage.downloadUrl),
    };
  }

  throw new Error(
    `No compatible package for ${extension.manifest.displayName} on ${PLATFORM_ARCH}`,
  );
}

function isCompleteExtensionPackage(
  extensionPackage: Partial<PlatformPackage> | undefined,
): extensionPackage is PlatformPackage {
  return (
    typeof extensionPackage?.downloadUrl === "string" &&
    extensionPackage.downloadUrl.length > 0 &&
    typeof extensionPackage.size === "number" &&
    extensionPackage.size > 0 &&
    typeof extensionPackage.checksum === "string" &&
    extensionPackage.checksum.length > 0
  );
}

export async function installExtensionLifecycle(params: {
  extensionId: string;
  extension: AvailableExtension;
  activateAfterInstall?: boolean;
  onProgress: (progress: number) => void;
  onLanguageInstalled: (
    runtimeManifest: AvailableExtension["manifest"],
    runtimeIssues: AvailableExtension["runtimeIssues"],
  ) => void;
  onNonLanguageInstalled: () => void;
  reloadInstalledExtensions: () => Promise<void>;
}) {
  const {
    extensionId,
    extension,
    activateAfterInstall = true,
    onProgress,
    onLanguageInstalled,
    onNonLanguageInstalled,
    reloadInstalledExtensions,
  } = params;

  const languageConfigs = getManifestLanguageContributions(extension.manifest);
  if (languageConfigs.length > 0) {
    if (languageInstalls.has(extensionId))
      throw new Error("Extension installation is already running");
    let complete!: () => void;
    const pending = {
      cancelled: false,
      done: new Promise<void>((resolve) => {
        complete = resolve;
      }),
    };
    languageInstalls.set(extensionId, pending);
    const checkCancelled = () => {
      if (pending.cancelled) throw new Error("Extension installation cancelled");
    };
    try {
      if (
        extension.manifest.installation?.type === "local" &&
        !localExtensionPackages.get(extensionId)
      )
        throw new Error("Import the plugin package before installing its language tools.");
      await installLanguageExtensionManifest(extensionId, extension.manifest, onProgress);
      checkCancelled();

      const primaryLanguageId = languageConfigs[0].id;
      const resolvedTools = await resolveToolPaths(primaryLanguageId, extension.manifest, {
        ensureInstalled: true,
      });
      checkCancelled();
      const runtimeManifest = buildRuntimeManifest(extension.manifest, resolvedTools.toolPaths);

      if (extension.manifest.lsp && !runtimeManifest.lsp) {
        const runtimeIssue =
          resolvedTools.issues.find((issue) => issue.tool === "lsp")?.message ||
          "Language server could not be installed. Reinstall the language tools.";
        throw new Error(runtimeIssue);
      }

      extensionRegistry.registerExtension(runtimeManifest, {
        isBundled: false,
        isEnabled: activateAfterInstall,
        state: activateAfterInstall ? "installed" : "deactivated",
      });

      if (activateAfterInstall) {
        await Promise.all(
          languageConfigs.map((languageConfig) =>
            registerLanguageProvider({
              extensionId,
              languageId: languageConfig.id,
              displayName: extension.manifest.displayName,
              version: extension.manifest.version,
              extensions: languageConfig.extensions,
              aliases: languageConfig.aliases,
            }),
          ),
        );
        checkCancelled();
        await refreshSyntaxHighlightingForActiveBuffer(extension);
        checkCancelled();
        await activateExtensionContributions(extensionId, runtimeManifest);
      }
      checkCancelled();
      if (extension.manifest.installation?.type === "local")
        localExtensionPackages.markInstalled(extensionId);
      onLanguageInstalled(runtimeManifest, resolvedTools.issues);
    } catch (error) {
      if (!extension.isInstalled) {
        await deactivateExtensionContributions(extensionId, extension.manifest);
        extensionRegistry.registerExtension(extension.manifest, {
          isBundled: false,
          isEnabled: false,
          state: "not-installed",
        });
        await unloadLanguageProviders(
          extensionId,
          languageConfigs.map((language) => language.id),
        );
        await uninstallLanguageArtifacts(languageConfigs.map((language) => language.id));
        if (extension.manifest.installation?.type === "local") {
          await Promise.all(
            languageConfigs.map((language) =>
              invoke("uninstall_language_tools", { languageId: language.id }),
            ),
          );
          localExtensionPackages.remove(extensionId);
          extensionRegistry.unregisterExtension(extensionId);
        }
      }
      throw error;
    } finally {
      languageInstalls.delete(extensionId);
      complete();
    }
    return;
  }

  if (isBundledContributionExtension(extension.manifest)) {
    markBundledContributionExtensionInstalled(extensionId);
    extensionRegistry.registerExtension(extension.manifest, {
      isBundled: false,
      isEnabled: activateAfterInstall,
      state: activateAfterInstall ? "installed" : "deactivated",
    });
    if (activateAfterInstall) {
      await activateExtensionContributions(extensionId, extension.manifest);
    }
    onNonLanguageInstalled();
    return;
  }

  const extensionPackage = resolveExtensionPackage(extension);

  await invoke("install_extension_from_url", {
    extensionId,
    url: extensionPackage.downloadUrl,
    checksum: extensionPackage.checksum,
    size: extensionPackage.size,
  });

  await reloadInstalledExtensions();
  if (activateAfterInstall) {
    await activateExtensionContributions(extensionId, extension.manifest);
  }
  onNonLanguageInstalled();
}

export async function uninstallExtensionLifecycle(params: {
  extensionId: string;
  extension: AvailableExtension;
  onLanguageUninstalled: () => void;
  onNonLanguageUninstalled: () => void;
  reloadInstalledExtensions: () => Promise<void>;
}) {
  const {
    extensionId,
    extension,
    onLanguageUninstalled,
    onNonLanguageUninstalled,
    reloadInstalledExtensions,
  } = params;

  const languageConfigs = getManifestLanguageContributions(extension.manifest);
  if (languageConfigs.length > 0) {
    const languageIds = languageConfigs.map((language) => language.id);

    await disableExtensionLifecycle({ extensionId, extension });
    await uninstallLanguageArtifacts(languageIds);
    await Promise.all(
      languageIds.map((languageId) => invoke("uninstall_language_tools", { languageId })),
    );
    extensionRegistry.registerExtension(extension.manifest, {
      isBundled: false,
      isEnabled: false,
      state: "not-installed",
    });
    if (extension.manifest.installation?.type === "local") {
      localExtensionPackages.remove(extensionId);
      extensionRegistry.unregisterExtension(extensionId);
    }
    onLanguageUninstalled();
    return;
  }

  if (isBundledContributionExtension(extension.manifest)) {
    await disableExtensionLifecycle({ extensionId, extension });
    markBundledContributionExtensionUninstalled(extensionId);
    extensionRegistry.registerExtension(extension.manifest, {
      isBundled: false,
      isEnabled: false,
      state: "not-installed",
    });
    onNonLanguageUninstalled();
    return;
  }

  await disableExtensionLifecycle({ extensionId, extension });
  await invoke("uninstall_extension_new", { extensionId });
  await reloadInstalledExtensions();
  onNonLanguageUninstalled();
}

export async function enableExtensionLifecycle(params: {
  extensionId: string;
  extension: AvailableExtension;
}) {
  const { extensionId, extension } = params;
  const languageConfigs = getManifestLanguageContributions(extension.manifest);

  if (languageConfigs.length > 0) {
    if (languageInstalls.has(extensionId))
      throw new Error("A language operation is already running");
    let complete!: () => void;
    const pending = {
      cancelled: false,
      done: new Promise<void>((resolve) => {
        complete = resolve;
      }),
    };
    languageInstalls.set(extensionId, pending);
    const checkCancelled = () => {
      if (pending.cancelled) throw new Error("Extension activation cancelled");
    };
    try {
      const primaryLanguageId = languageConfigs[0].id;
      const resolvedTools = await resolveToolPaths(primaryLanguageId, extension.manifest, {
        ensureInstalled: false,
      });
      checkCancelled();
      const runtimeManifest = buildRuntimeManifest(extension.manifest, resolvedTools.toolPaths);

      extensionRegistry.registerExtension(runtimeManifest, {
        isBundled: false,
        isEnabled: true,
        state: "installed",
      });

      await Promise.all(
        languageConfigs.map((languageConfig) =>
          registerLanguageProvider({
            extensionId,
            languageId: languageConfig.id,
            displayName: extension.manifest.displayName,
            version: extension.manifest.version,
            extensions: languageConfig.extensions,
            aliases: languageConfig.aliases,
          }),
        ),
      );

      checkCancelled();
      await refreshSyntaxHighlightingForActiveBuffer(extension);
      checkCancelled();
      await activateExtensionContributions(extensionId, runtimeManifest);
      checkCancelled();
    } catch (error) {
      extensionRegistry.registerExtension(extension.manifest, {
        isBundled: false,
        isEnabled: false,
        state: "deactivated",
      });
      await deactivateExtensionContributions(extensionId, extension.manifest);
      await extensionProcessOwner.stop(undefined, extensionId);
      const { LspClient } = await import("@/features/editor/lsp/lsp-client");
      await LspClient.getInstance().stopLanguageServers(
        languageConfigs.map((language) => language.id),
      );
      await unloadLanguageProviders(
        extensionId,
        languageConfigs.map((language) => language.id),
      );
      for (const language of languageConfigs) wasmParserLoader.unloadParser(language.id);
      throw error;
    } finally {
      languageInstalls.delete(extensionId);
      complete();
    }
    return;
  }

  extensionRegistry.registerExtension(extension.manifest, {
    isBundled: false,
    isEnabled: true,
    state: "installed",
  });
  await activateExtensionContributions(extensionId, extension.manifest);
}

export async function disableExtensionLifecycle(params: {
  extensionId: string;
  extension: AvailableExtension;
}) {
  const { extensionId, extension } = params;
  const languageConfigs = getManifestLanguageContributions(extension.manifest);

  if (languageConfigs.length > 0) {
    const previous = extensionRegistry.getExtension(extensionId);
    // Gate all registry-backed launch paths before waiting for in-flight LSP
    // starts and stopping the sessions owned by this language extension.
    extensionRegistry.registerExtension(previous?.manifest ?? extension.manifest, {
      isBundled: previous?.isBundled ?? false,
      isEnabled: false,
      state: "deactivated",
    });
    try {
      // Cancel an in-flight worker activation before waiting for its owner.
      await deactivateExtensionContributions(extensionId, extension.manifest);
      await cancelLanguageInstall(
        extensionId,
        languageConfigs.map((language) => language.id),
      );
      // Cancellation may race a provider registration: close the gate again
      // after installation has settled before stopping its resources.
      extensionRegistry.registerExtension(previous?.manifest ?? extension.manifest, {
        isBundled: previous?.isBundled ?? false,
        isEnabled: false,
        state: "deactivated",
      });
      await deactivateExtensionContributions(extensionId, extension.manifest);
      await extensionProcessOwner.stop(undefined, extensionId);
      const { LspClient } = await import("@/features/editor/lsp/lsp-client");
      await LspClient.getInstance().stopLanguageServers(
        languageConfigs.map((language) => language.id),
      );
      await unloadLanguageProviders(
        extensionId,
        languageConfigs.map((language) => language.id),
      );
      for (const language of languageConfigs) {
        wasmParserLoader.unloadParser(language.id);
      }
    } catch (error) {
      if (previous) {
        extensionRegistry.registerExtension(previous.manifest, {
          path: previous.path,
          isBundled: previous.isBundled,
          isEnabled: previous.isEnabled,
          state: previous.state,
        });
      } else {
        extensionRegistry.unregisterExtension(extensionId);
      }
      throw error;
    }
    try {
      await refreshSyntaxHighlightingForActiveBuffer(extension);
    } catch (error) {
      console.warn(`Could not refresh syntax highlighting after disabling ${extensionId}:`, error);
    }
    return;
  }

  const previous = extensionRegistry.getExtension(extensionId);
  extensionRegistry.registerExtension(previous?.manifest ?? extension.manifest, {
    isBundled: previous?.isBundled ?? false,
    isEnabled: false,
    state: "deactivated",
  });
  try {
    await deactivateExtensionContributions(extensionId, extension.manifest);
  } catch (error) {
    if (previous) {
      extensionRegistry.registerExtension(previous.manifest, {
        path: previous.path,
        isBundled: previous.isBundled,
        isEnabled: previous.isEnabled,
        state: previous.state,
      });
    } else {
      extensionRegistry.unregisterExtension(extensionId);
    }
    throw error;
  }
}

export async function updateExtensionLifecycle(params: {
  extensionId: string;
  extension: AvailableExtension;
  clearInstalledStateForUpdate: () => void;
  reinstall: (activateAfterInstall: boolean) => Promise<void>;
}) {
  const { extensionId, extension, clearInstalledStateForUpdate, reinstall } = params;
  const restoreDisabledState = extension.isEnabled === false;

  const languageIds = getManifestLanguageContributions(extension.manifest).map(
    (language) => language.id,
  );

  await disableExtensionLifecycle({ extensionId, extension });
  if (languageIds.length > 0) {
    await uninstallLanguageArtifacts(languageIds);
  }

  extensionRegistry.unregisterExtension(extensionId);

  clearInstalledStateForUpdate();
  await reinstall(!restoreDisabledState);
}

export function buildInstalledExtensionMetadata(
  extensionId: string,
  extension: AvailableExtension,
  enabled = true,
): ExtensionInstallationMetadata {
  return {
    id: extensionId,
    name: extension.manifest.displayName,
    version: extension.manifest.version,
    installed_at: new Date().toISOString(),
    enabled,
  };
}
