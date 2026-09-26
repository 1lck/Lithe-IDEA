import { expect, spyOn, test } from "bun:test";
import manifestJson from "../../../../../Plugins/win/Official/PhpSupport/plugin.json";
import * as native from "@/platform/tauri-core";
import { extensionInstaller } from "../installer/extension-installer";
import { localExtensionPackages } from "../packages/local-extension-package";
import type { ExtensionManifest } from "../types/extension-manifest";
import { loadInstalledExtensionsSnapshot } from "./extension-store-bootstrap";
import * as runtime from "./extension-store-runtime";
import * as enabledState from "./extension-enabled-state";
import { extensionRegistry } from "./extension-registry";
const manifest = manifestJson as ExtensionManifest;

for (const state of ["removed", "incomplete", "disabled", "enabled"] as const) {
  test(`restart respects ${state} independent package state`, async () => {
    const commands: string[] = [];
    const call = spyOn(native, "invoke").mockImplementation((async (command: string) => {
      commands.push(command);
      return [];
    }) as typeof native.invoke);
    const parsers = spyOn(extensionInstaller, "listInstalled").mockResolvedValue([
      { languageId: "php", extensionId: manifest.id, version: "1.0.0", size: 1 },
    ]);
    const packages = spyOn(localExtensionPackages, "list").mockReturnValue(
      state === "removed"
        ? []
        : [
            {
              format: "lithe-worker-plugin",
              version: 1,
              manifest,
              source: "unused",
              installed: state !== "incomplete",
            },
          ],
    );
    const disabled = spyOn(enabledState, "readDisabledExtensionIds").mockReturnValue(
      new Set(state === "disabled" ? [manifest.id] : []),
    );
    const tools = spyOn(runtime, "resolveToolPaths").mockResolvedValue({
      toolPaths: { lsp: "C:/fixture/intelephense.cmd" },
      issues: [],
    });
    const provider = spyOn(runtime, "registerLanguageProvider").mockResolvedValue(undefined);
    try {
      const snapshot = await loadInstalledExtensionsSnapshot(
        new Map([
          [
            manifest.id,
            {
              manifest,
              isInstalled: state === "enabled" || state === "disabled",
              isEnabled: state === "enabled",
              isInstalling: false,
            },
          ],
        ]),
      );
      expect(tools.mock.calls.length).toBe(state === "enabled" ? 1 : 0);
      expect(provider.mock.calls.length).toBe(state === "enabled" ? 1 : 0);
      expect(snapshot.backendInstalled.length).toBe(
        state === "enabled" || state === "disabled" ? 1 : 0,
      );
      if (state === "enabled")
        expect(tools).toHaveBeenCalledWith("php", manifest, { repairMissing: false });
      expect(commands).not.toContain("install_language_tools");
    } finally {
      for (const spy of [call, parsers, packages, disabled, tools, provider]) spy.mockRestore();
      extensionRegistry.unregisterExtension(manifest.id);
    }
  });
}
