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

test("cancelling PHP during parser installation never installs tools or activates providers", async () => {
  const { spyOn } = await import("bun:test");
  const native = await import("@/platform/tauri-core");
  const { extensionInstaller } = await import("../installer/extension-installer");
  const { getFullExtensions } = await import("../languages/full-extensions");
  const { LspClient } = await import("@/features/editor/lsp/lsp-client");
  const { disableExtensionLifecycle } = await import("./extension-store-lifecycle");
  const manifest = getFullExtensions().find((entry) => entry.id === "lithe.php")!;
  const extension = { manifest, isInstalled: false, isEnabled: false, isInstalling: true };
  let rejectDownload!: (error: Error) => void;
  const download = new Promise<void>((_resolve, reject) => {
    rejectDownload = reject;
  });
  const installer = spyOn(extensionInstaller, "installLanguage").mockImplementation(() => download);
  const cancel = spyOn(extensionInstaller, "cancelInstallation").mockImplementation(() =>
    rejectDownload(new Error("cancelled")),
  );
  const uninstall = spyOn(extensionInstaller, "uninstallLanguage").mockResolvedValue(undefined);
  const commands: string[] = [];
  const invoke = spyOn(native, "invoke").mockImplementation((async (command: string) => {
    commands.push(command);
  }) as typeof native.invoke);
  const stop = spyOn(LspClient.getInstance(), "stopLanguageServers").mockResolvedValue(undefined);
  let activated = false;
  const outcome = installExtensionLifecycle({
    extensionId: manifest.id,
    extension,
    onProgress: () => {},
    onLanguageInstalled: () => {
      activated = true;
    },
    onNonLanguageInstalled: () => {},
    reloadInstalledExtensions: async () => {},
  }).then(
    () => "installed",
    () => "cancelled",
  );
  try {
    await disableExtensionLifecycle({ extensionId: manifest.id, extension });
    expect(await outcome).toBe("cancelled");
    expect(activated).toBe(false);
    expect(commands).toContain("cancel_language_tool_install");
    expect(commands).not.toContain("install_language_tools");
    expect(uninstall).toHaveBeenCalledWith("php");
    expect(extensionRegistry.getExtension(manifest.id)?.isEnabled).toBe(false);
  } finally {
    rejectDownload(new Error("test cleanup"));
    await outcome;
    for (const spy of [installer, cancel, uninstall, invoke, stop]) spy.mockRestore();
    extensionRegistry.unregisterExtension(manifest.id);
  }
});

test("disable wins over an in-flight PHP enable operation", async () => {
  const { spyOn } = await import("bun:test");
  const native = await import("@/platform/tauri-core");
  const { getFullExtensions } = await import("../languages/full-extensions");
  const { LspClient } = await import("@/features/editor/lsp/lsp-client");
  const { enableExtensionLifecycle, disableExtensionLifecycle } =
    await import("./extension-store-lifecycle");
  const manifest = getFullExtensions().find((entry) => entry.id === "lithe.php")!;
  const extension = { manifest, isInstalled: true, isEnabled: false, isInstalling: false };
  extensionRegistry.registerExtension(manifest, { isEnabled: false, state: "deactivated" });
  let release!: () => void;
  const lookup = new Promise<null>((resolve) => {
    release = () => resolve(null);
  });
  const invoke = spyOn(native, "invoke").mockImplementation(((command: string) =>
    command === "get_tool_path" ? lookup : Promise.resolve(undefined)) as typeof native.invoke);
  const stop = spyOn(LspClient.getInstance(), "stopLanguageServers").mockResolvedValue(undefined);
  const enabling = enableExtensionLifecycle({ extensionId: manifest.id, extension }).then(
    () => "enabled",
    () => "cancelled",
  );
  const disabling = disableExtensionLifecycle({ extensionId: manifest.id, extension });
  try {
    release();
    expect(await enabling).toBe("cancelled");
    await disabling;
    expect(extensionRegistry.getExtension(manifest.id)?.isEnabled).toBe(false);
  } finally {
    release();
    await Promise.all([enabling, disabling]);
    invoke.mockRestore();
    stop.mockRestore();
    extensionRegistry.unregisterExtension(manifest.id);
  }
});
