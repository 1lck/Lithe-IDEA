import { describe, expect, test } from "bun:test";
import { bundledExtensionManifests } from "./bundled/bundled-extension-manifests";

describe("bundled file icon themes", () => {
  test("ships IDEA Icons without the retired Lithe icon theme", () => {
    const extensionIds = bundledExtensionManifests.map(({ manifest }) => manifest.id);

    expect(extensionIds).toContain("lithe.icon-theme.idea-icons");
    expect(extensionIds).not.toContain("lithe.icon-theme.lithe-icons");
  });
});
