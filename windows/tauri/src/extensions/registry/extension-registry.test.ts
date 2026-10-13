import { afterEach, describe, expect, test } from "bun:test";
import { ExtensionRegistry, extensionRegistry } from "./extension-registry";
import type { ExtensionManifest } from "../types/extension-manifest";

const extensionId = "test.disabled-language-lifecycle";
const manifest: ExtensionManifest = {
  id: extensionId,
  name: "disabled-language-lifecycle",
  displayName: "Disabled Language Lifecycle",
  description: "Test language extension",
  version: "1.0.0",
  publisher: "test",
  categories: ["Language"],
  languages: [{ id: "disabled-language", extensions: [".disabled-language"] }],
  lsp: {
    server: { default: "test-language-server" },
    fileExtensions: [".disabled-language"],
    languageIds: ["disabled-language"],
  },
};

afterEach(() => extensionRegistry.unregisterExtension(extensionId));

describe("disabled language extension", () => {
  test("stops contributing language and LSP lookup immediately", async () => {
    await extensionRegistry.ensureInitialized();
    const filePath = "C:/work/example.disabled-language";

    extensionRegistry.registerExtension(manifest, { isEnabled: true, state: "installed" });
    expect(extensionRegistry.getLspServerPath(filePath)).toBe("test-language-server");
    expect(extensionRegistry.isLspSupported(filePath)).toBe(true);

    extensionRegistry.registerExtension(manifest, { isEnabled: false, state: "deactivated" });
    expect(extensionRegistry.getExtensionForFilePath(filePath)).toBeUndefined();
    expect(extensionRegistry.getExtensionByLanguageId("disabled-language")).toBeUndefined();
    expect(extensionRegistry.getLspServerPath(filePath)).toBeNull();
    expect(extensionRegistry.isLspSupported(filePath)).toBe(false);
  });
});

describe("extension startup", () => {
  test("does not register built-in icon resources as extensions", async () => {
    const registry = new ExtensionRegistry();
    await registry.ensureInitialized();

    expect(registry.getExtension("lithe.icon-theme.idea-icons")).toBeUndefined();
    expect(registry.getAllExtensions()).toEqual([]);
  });
});
