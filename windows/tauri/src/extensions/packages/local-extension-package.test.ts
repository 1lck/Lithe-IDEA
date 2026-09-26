import { afterEach, expect, test } from "bun:test";
import manifest from "../../../../../Plugins/win/Official/PhpSupport/plugin.json";
import { LocalExtensionPackageStore, parseLocalExtensionPackage } from "./local-extension-package";

const values = new Map<string, string>();
const localExtensionPackages = new LocalExtensionPackageStore(() => ({
  get length() {
    return values.size;
  },
  key: (index) => [...values.keys()][index] ?? null,
  getItem: (key) => values.get(key) ?? null,
  setItem: (key, value) => {
    values.set(key, value);
  },
  removeItem: (key) => {
    values.delete(key);
  },
}));

const packageText = (changes: Record<string, unknown> = {}) =>
  JSON.stringify({
    format: "lithe-worker-plugin",
    version: 1,
    source: "export function activate() {}",
    manifest: { ...manifest, ...changes },
  });
afterEach(() => localExtensionPackages.remove(manifest.id));

test("import is inactive until installation commits and uninstall removes the worker source", () => {
  const pkg = parseLocalExtensionPackage(packageText());
  localExtensionPackages.stage(pkg);
  expect(localExtensionPackages.get(manifest.id)?.installed).toBe(false);
  expect(
    localExtensionPackages.list().find((entry) => entry.manifest.id === manifest.id)?.manifest.lsp
      ?.requiredExecutables,
  ).toEqual(["node"]);
  localExtensionPackages.markInstalled(manifest.id);
  expect(localExtensionPackages.get(manifest.id)?.installed).toBe(true);
  expect(() => localExtensionPackages.stage(pkg)).toThrow("Uninstall");
  localExtensionPackages.remove(manifest.id);
  expect(localExtensionPackages.get(manifest.id)).toBeUndefined();
});

test("package input cannot grant arbitrary services or escape declared root files", () => {
  const pkg = parseLocalExtensionPackage(
    packageText({
      permissions: { secrets: true, network: ["*"] },
      formatter: { name: "unexpected" },
    }),
  );
  expect(pkg.manifest.permissions).toBeUndefined();
  expect(pkg.manifest.formatter).toBeUndefined();
  for (const file of ["../secret", "/secret", "C:\\secret", "a/b"]) {
    expect(() =>
      parseLocalExtensionPackage(
        packageText({ runActions: { manifestFiles: [file], executables: ["php"] } }),
      ),
    ).toThrow();
  }
  expect(() => parseLocalExtensionPackage(packageText({ main: "../plugin.js" }))).toThrow();
});

test("malformed and oversized packages fail before storage", () => {
  expect(() => parseLocalExtensionPackage("x")).toThrow();
  expect(() => parseLocalExtensionPackage(" ".repeat(256 * 1024 + 1))).toThrow();
  expect(() => parseLocalExtensionPackage(packageText({ languages: [] }))).toThrow();
  expect(localExtensionPackages.get(manifest.id)).toBeUndefined();
});
