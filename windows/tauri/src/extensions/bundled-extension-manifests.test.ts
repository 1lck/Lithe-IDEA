import { afterEach, describe, expect, test } from "bun:test";
import { builtinIconThemes } from "./icon-themes/builtin-icon-themes";
import { iconThemeRegistry } from "./icon-themes/icon-theme-registry";
import { registerBuiltinIconTheme } from "./runtime/extension-contribution-runtime";

afterEach(() => iconThemeRegistry.unregisterThemesByExtension("builtin.icon-themes"));

async function getIdeaIconTheme() {
  const manifest = await builtinIconThemes.find(({ id }) => id === "idea-icons")?.load();
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
  test("keeps only the selected built-in theme registered", async () => {
    const idea = await builtinIconThemes[0].load();
    const material = await builtinIconThemes.at(-1)!.load();

    registerBuiltinIconTheme(idea, "idea-icons", {});
    expect(iconThemeRegistry.getThemeIdsByExtension("builtin.icon-themes")).toEqual(["idea-icons"]);

    registerBuiltinIconTheme(material, "material", {});
    expect(iconThemeRegistry.getThemeIdsByExtension("builtin.icon-themes")).toEqual(["material"]);
  });

  test("each appearance option resolves to an icon theme contribution", async () => {
    for (const entry of builtinIconThemes) {
      const manifest = await entry.load();
      expect(manifest.icons?.some((theme) => theme.id === entry.id)).toBe(true);
    }
  });

  test("lists IDEA Icons without the retired Lithe icon theme", () => {
    const themeIds = builtinIconThemes.map(({ id }) => id);

    expect(themeIds).toContain("idea-icons");
    expect(themeIds).not.toContain("lithe-icons");
  });

  test("maps the common IDEA project tree entries to ExpUI icons", async () => {
    const iconTheme = await getIdeaIconTheme();

    expect(iconTheme.fileExtensions?.[".java"]).toBe("idea-java");
    expect(iconTheme.filenames?.["pom.xml"]).toBe("idea-maven");
    expect(iconTheme.filenames?.[".gitignore"]).toBe("idea-gitignore");
    expect(iconTheme.filenames?.["\0lithe:java.class"]).toBe("idea-class");
    expect(iconTheme.filenames?.["\0lithe:java.exception"]).toBe("idea-exception");
    expect(iconTheme.folders?.["\0lithe:folder.source-root"]).toBe("idea-sourceRoot");
    expect(iconTheme.folders?.["\0lithe:folder.package"]).toBe("idea-package");
    expect(iconTheme.expandedFolders).toEqual(iconTheme.folders);
  });

  test("declares dark and light assets for every added IDEA tree icon", async () => {
    const iconTheme = await getIdeaIconTheme();

    for (const iconId of IDEA_TREE_ICON_IDS) {
      expect(iconTheme.iconDefinitions[iconId]).toMatch(/_dark\.svg$/);
      expect(iconTheme.lightIconDefinitions?.[iconId]).toMatch(/(?<!_dark)\.svg$/);
    }
  });

  test("preserves the upstream copyright header in added IDEA assets", async () => {
    const iconTheme = await getIdeaIconTheme();

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
