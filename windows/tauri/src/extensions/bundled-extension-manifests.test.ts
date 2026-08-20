import { describe, expect, test } from "bun:test";
import { bundledExtensionManifests } from "./bundled/bundled-extension-manifests";

function getIdeaIconTheme() {
  const manifest = bundledExtensionManifests.find(
    ({ manifest }) => manifest.id === "lithe.icon-theme.idea-icons",
  )?.manifest;
  const iconTheme = manifest?.icons?.find(({ id }) => id === "idea-icons");

  if (!iconTheme) {
    throw new Error("Bundled IDEA icon theme is missing");
  }

  return iconTheme;
}

const IDEA_TREE_ICON_IDS = [
  "idea-maven",
  "idea-class",
  "idea-interface",
  "idea-enum",
  "idea-annotation",
  "idea-record",
  "idea-exception",
  "idea-sourceRoot",
  "idea-testRoot",
  "idea-resourcesRoot",
  "idea-testResourcesRoot",
  "idea-package",
];

describe("bundled file icon themes", () => {
  test("ships IDEA Icons without the retired Lithe icon theme", () => {
    const extensionIds = bundledExtensionManifests.map(({ manifest }) => manifest.id);

    expect(extensionIds).toContain("lithe.icon-theme.idea-icons");
    expect(extensionIds).not.toContain("lithe.icon-theme.lithe-icons");
  });

  test("maps the common IDEA project tree entries to ExpUI icons", () => {
    const iconTheme = getIdeaIconTheme();

    expect(iconTheme.fileExtensions?.[".java"]).toBe("idea-java");
    expect(iconTheme.filenames?.["pom.xml"]).toBe("idea-maven");
    expect(iconTheme.filenames?.[".gitignore"]).toBe("idea-gitignore");
    expect(iconTheme.filenames?.["\0lithe:java.class"]).toBe("idea-class");
    expect(iconTheme.filenames?.["\0lithe:java.exception"]).toBe("idea-exception");
    expect(iconTheme.folders?.["\0lithe:folder.source-root"]).toBe("idea-sourceRoot");
    expect(iconTheme.folders?.["\0lithe:folder.package"]).toBe("idea-package");
    expect(iconTheme.expandedFolders).toEqual(iconTheme.folders);
  });

  test("declares dark and light assets for every added IDEA tree icon", () => {
    const iconTheme = getIdeaIconTheme();

    for (const iconId of IDEA_TREE_ICON_IDS) {
      expect(iconTheme.iconDefinitions[iconId]).toMatch(/_dark\.svg$/);
      expect(iconTheme.lightIconDefinitions?.[iconId]).toMatch(/(?<!_dark)\.svg$/);
    }
  });

  test("preserves the upstream copyright header in added IDEA assets", async () => {
    const iconTheme = getIdeaIconTheme();

    for (const iconId of IDEA_TREE_ICON_IDS) {
      const assetPaths = [
        iconTheme.iconDefinitions[iconId],
        iconTheme.lightIconDefinitions?.[iconId],
      ];

      for (const assetPath of assetPaths) {
        expect(assetPath).toBeDefined();
        const contents = await Bun.file(
          new URL(`./bundled/icon-themes/idea/${assetPath!.replace(/^\.\//, "")}`, import.meta.url),
        ).text();
        expect(contents.startsWith("<!-- Copyright ")).toBe(true);
        expect(contents).toContain("Apache 2.0 license");
      }
    }
  });
});
