import { expect, test } from "bun:test";
import { BuildFileInputs, buildCatalogMayChange } from "./build-file-inputs";

test("Core watch paths respect Windows aliases, containment, directory removal and source preparation", () => {
  const files = new BuildFileInputs("C:/work");
  files.remember("app", ["app/project.marker", ".lithe/build/options.json"]);
  files.begin("model", "new", true); files.begin("discovery", "app", false);
  expect(files.changed("c:\\WORK\\app\\PROJECT.MARKER", false).owners).toEqual(new Set(["app", "new"]));
  const source = files.changed("C:/work/app/src/Test.java", false);
  expect(source.owners).toEqual(new Set(["new"])); expect(source.cancelled).toEqual(["discovery"]);
  files.finish("model"); files.finish("discovery");
  expect(files.changed("C:/work/app", false).owners).toEqual(new Set(["app"]));
  expect(files.changed("C:/work-other/app/project.marker", true).owners.size).toBe(0);
  expect(files.changed("C:/work", true).owners).toEqual(new Set(["app"]));
  files.forget("app"); expect(files.changed("C:/work/app/project.marker", false).owners.size).toBe(0);
}, 5000);

test("catalog refresh uses generic declared markers and the team document across Windows path casing", () => {
  const manifests = { example: { buildSystems: [{ detection: { markers: ["project.marker", "tools/workspace.config"] } }] } };
  expect(buildCatalogMayChange(manifests, "C:/work", "c:\\WORK\\nested\\PROJECT.MARKER", false)).toBe(true);
  expect(buildCatalogMayChange(manifests, "C:/work", "C:/work/nested/tools/workspace.config", false)).toBe(true);
  expect(buildCatalogMayChange({}, "C:/work", "C:/work/.LITHE/BUILD/OPTIONS.JSON", false)).toBe(true);
  expect(buildCatalogMayChange(manifests, "C:/work", "C:/work/nested/Test.java", false)).toBe(false);
  expect(buildCatalogMayChange(manifests, "C:/work", "C:/work-other/project.marker", true)).toBe(false);
  expect(buildCatalogMayChange(manifests, "//wsl.localhost/distro/work", "//wsl.localhost/distro/work/PROJECT.MARKER", false)).toBe(false);
}, 5000);
