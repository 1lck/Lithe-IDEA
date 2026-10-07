import { useRealPluginCore } from "../testing/plugin-core-backend";
import { beforeEach, afterEach, expect, test } from "bun:test";
import { enableMapSet } from "immer";
import { v0ExtensionManifest } from "@lithe/v0/manifest";
import { getProvider } from "@/features/ai/services/providers/ai-provider-registry";
import { unregisterAIProviderExtension } from "@/features/ai/services/providers/ai-provider-registry";
import { deactivateExtensionContributions } from "../runtime/extension-contribution-runtime";
import { markBundledContributionExtensionUninstalled } from "./bundled-contribution-install-state";
import { extensionRegistry } from "./extension-registry";
import { installExtensionLifecycle, updateExtensionLifecycle } from "./extension-store-lifecycle";

let restoreCore: () => void;
beforeEach(() => { restoreCore = useRealPluginCore(); });
afterEach(() => restoreCore());

afterEach(async () => {
  await deactivateExtensionContributions(v0ExtensionManifest.id, v0ExtensionManifest);
  unregisterAIProviderExtension(v0ExtensionManifest.id);
  markBundledContributionExtensionUninstalled(v0ExtensionManifest.id);
  extensionRegistry.unregisterExtension(v0ExtensionManifest.id);
});

test("failed rollback restores the working package after stopping the failed version", async () => {
  const { spyOn } = await import("bun:test");
  const { useExtensionStore } = await import("./extension-store");
  const { LocalExtensionPackageStore, localExtensionPackages, parseLocalExtensionPackage } =
    await import("../packages/local-extension-package");
  const { default: php } = await import("../../../../../shared/fixtures/plugins/windows-php-legacy-v1.json");
  const native = await import("@/platform/tauri-core");
  const { LspClient } = await import("@/features/editor/lsp/lsp-client");
  enableMapSet();
  // Bun's test loader can also load Zustand's CommonJS Immer peer. Initialize
  // that entrypoint as well; the production bundler uses a single ESM graph.
  require("immer").enableMapSet();
  const values = new Map<string, string>();
  const packages = new LocalExtensionPackageStore(() => ({
    get length() { return values.size; }, key: (index) => [...values.keys()][index] ?? null,
    getItem: (key) => values.get(key) ?? null, setItem: (key, value) => { values.set(key, value); },
    removeItem: (key) => { values.delete(key); },
  }));
  for (const version of ["1.0.0", "1.1.0"]) {
    const pkg = await parseLocalExtensionPackage(JSON.stringify({ format: "lithe-worker-plugin",
      version: 1, manifest: { ...php, version }, source: "export function activate() {}" }));
    await packages.stage(pkg, undefined, version === "1.1.0");
    await packages.markInstalled(php.id);
  }
  const snapshot = useExtensionStore.getState();
  const current = (await packages.get(php.id))!;
  const events: string[] = [];
  const previous = spyOn(localExtensionPackages, "previous").mockImplementation(packages.previous.bind(packages));
  const rollback = spyOn(localExtensionPackages, "rollback").mockImplementation(packages.rollback.bind(packages));
  const invoke = spyOn(native, "invoke").mockImplementation((async () => undefined) as typeof native.invoke);
  const stop = spyOn(LspClient.getInstance(), "stopLanguageServers").mockImplementation(async () => { events.push("stop"); });
  try {
    useExtensionStore.setState({ availableExtensions: new Map([[php.id, {
      manifest: current.manifest, isInstalled: true, isEnabled: true, isInstalling: false,
    }]]), actions: { ...snapshot.actions, installExtension: async (id, activate) => {
      const selected = (await packages.get(id))!;
      events.push(`install:${selected.manifest.version}`);
      if (selected.manifest.version === "1.0.0") throw new Error("Retained version is damaged");
      expect(activate).toBe(true);
    } } });
    await expect(useExtensionStore.getState().actions.rollbackLocalPackage(php.id))
      .rejects.toThrow("Retained version is damaged");
    expect((await packages.get(php.id))?.manifest.version).toBe("1.1.0");
    expect(useExtensionStore.getState().availableExtensions.get(php.id)?.manifest.version).toBe("1.1.0");
    expect(events).toEqual(["stop", "install:1.0.0", "stop", "install:1.1.0"]);
  } finally {
    useExtensionStore.setState(snapshot, true);
    for (const spy of [previous, rollback, invoke, stop]) spy.mockRestore();
    extensionRegistry.unregisterExtension(php.id);
  }
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
  const { default: phpManifest } =
    await import("../../../../../shared/fixtures/plugins/windows-php-legacy-v1.json");
  const { LspClient } = await import("@/features/editor/lsp/lsp-client");
  const { disableExtensionLifecycle } = await import("./extension-store-lifecycle");
  const manifest = {
    ...phpManifest,
    installation: { type: "download" },
  } as import("../types/extension-manifest").ExtensionManifest;
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
  const { default: phpManifest } =
    await import("../../../../../shared/fixtures/plugins/windows-php-legacy-v1.json");
  const { LspClient } = await import("@/features/editor/lsp/lsp-client");
  const { enableExtensionLifecycle, disableExtensionLifecycle } =
    await import("./extension-store-lifecycle");
  const manifest = {
    ...phpManifest,
    installation: { type: "download" },
  } as import("../types/extension-manifest").ExtensionManifest;
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

test("worker activation failure closes the language gate and unloads its providers", async () => {
  const { spyOn } = await import("bun:test");
  const runtime = await import("./extension-store-runtime");
  const contributions = await import("../runtime/extension-contribution-runtime");
  const { enableExtensionLifecycle } = await import("./extension-store-lifecycle");
  const { LspClient } = await import("@/features/editor/lsp/lsp-client");
  const { default: json } =
    await import("../../../../../shared/fixtures/plugins/windows-php-legacy-v1.json");
  const manifest = json as import("../types/extension-manifest").ExtensionManifest;
  const extension = { manifest, isInstalled: true, isEnabled: false, isInstalling: false };
  const resolved = spyOn(runtime, "resolveToolPaths").mockResolvedValue({
    toolPaths: { lsp: "C:/fixture/intelephense.cmd" },
    issues: [],
  });
  const provider = spyOn(runtime, "registerLanguageProvider").mockResolvedValue(undefined);
  const activate = spyOn(contributions, "activateExtensionContributions").mockRejectedValue(
    new Error("bad worker"),
  );
  const deactivate = spyOn(contributions, "deactivateExtensionContributions").mockResolvedValue(
    undefined,
  );
  const stop = spyOn(LspClient.getInstance(), "stopLanguageServers").mockResolvedValue(undefined);
  try {
    await expect(enableExtensionLifecycle({ extensionId: manifest.id, extension })).rejects.toThrow(
      "bad worker",
    );
    expect(extensionRegistry.getExtension(manifest.id)?.isEnabled).toBe(false);
    expect(deactivate).toHaveBeenCalledWith(manifest.id, manifest);
    expect(stop).toHaveBeenCalledWith(["php"]);
  } finally {
    for (const spy of [resolved, provider, activate, deactivate, stop]) spy.mockRestore();
    extensionRegistry.unregisterExtension(manifest.id);
  }
});

for (const message of ["Bun is required", "Automatic installation is not supported"]) {
  test(`failed update preserves the installed extension: ${message}`, async () => {
    const { spyOn } = await import("bun:test");
    const runtime = await import("./extension-store-runtime");
    const { extensionInstaller } = await import("../installer/extension-installer");
    const { default: json } = await import("../../../../../shared/fixtures/plugins/windows-php-legacy-v1.json");
    const manifest = json as import("../types/extension-manifest").ExtensionManifest;
    const extension = { manifest, isInstalled: true, isEnabled: true, isInstalling: false };
    extensionRegistry.registerExtension(manifest, { isEnabled: true, state: "installed" });
    const resolved = spyOn(runtime, "checkLanguageToolRequirements").mockRejectedValue(new Error(message));
    const uninstall = spyOn(extensionInstaller, "uninstallLanguage").mockResolvedValue(undefined);
    let cleared = false;
    let reinstalled = false;
    try {
      await expect(updateExtensionLifecycle({
        extensionId: manifest.id, extension,
        clearInstalledStateForUpdate: () => { cleared = true; },
        reinstall: async () => { reinstalled = true; },
      })).rejects.toThrow(message);
      expect(cleared).toBe(false);
      expect(reinstalled).toBe(false);
      expect(uninstall).not.toHaveBeenCalled();
      expect(extensionRegistry.getExtension(manifest.id)?.isEnabled).toBe(true);
    } finally {
      resolved.mockRestore();
      uninstall.mockRestore();
      extensionRegistry.unregisterExtension(manifest.id);
    }
  });
}

test("disabling a language extension wins over an update prerequisite check", async () => {
  const { spyOn } = await import("bun:test");
  const runtime = await import("./extension-store-runtime");
  const native = await import("@/platform/tauri-core");
  const { LspClient } = await import("@/features/editor/lsp/lsp-client");
  const { disableExtensionLifecycle } = await import("./extension-store-lifecycle");
  const { default: json } = await import("../../../../../shared/fixtures/plugins/windows-php-legacy-v1.json");
  const manifest = json as import("../types/extension-manifest").ExtensionManifest;
  const extension = { manifest, isInstalled: true, isEnabled: true, isInstalling: false };
  extensionRegistry.registerExtension(manifest, { isEnabled: true, state: "installed" });
  let release!: () => void;
  const check = new Promise<void>((resolve) => { release = resolve; });
  const prerequisites = spyOn(runtime, "checkLanguageToolRequirements").mockImplementation(() => check);
  const invoke = spyOn(native, "invoke").mockResolvedValue(undefined);
  const stop = spyOn(LspClient.getInstance(), "stopLanguageServers").mockResolvedValue(undefined);
  let cleared = false;
  let reinstalled = false;
  const updating = updateExtensionLifecycle({
    extensionId: manifest.id, extension,
    clearInstalledStateForUpdate: () => { cleared = true; },
    reinstall: async () => { reinstalled = true; },
  }).then(() => "updated", () => "cancelled");
  try {
    await disableExtensionLifecycle({ extensionId: manifest.id, extension });
    release();
    expect(await updating).toBe("cancelled");
    expect(cleared).toBe(false);
    expect(reinstalled).toBe(false);
    expect(extensionRegistry.getExtension(manifest.id)?.isEnabled).toBe(false);
  } finally {
    release();
    await updating;
    for (const spy of [prerequisites, invoke, stop]) spy.mockRestore();
    extensionRegistry.unregisterExtension(manifest.id);
  }
});
