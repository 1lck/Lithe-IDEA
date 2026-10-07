import { useRealPluginCore } from "../testing/plugin-core-backend";
import { beforeEach, afterEach, expect, test } from "bun:test";
import manifest from "../../../../../shared/fixtures/plugins/windows-php-legacy-v1.json";
import { LocalExtensionPackageStore, parseLocalExtensionPackage } from "./local-extension-package";

let restoreCore: () => void;
beforeEach(() => { restoreCore = useRealPluginCore(); });
afterEach(() => restoreCore());

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

test("import is inactive until installation commits and uninstall removes the worker source", async () => {
  const pkg = await parseLocalExtensionPackage(packageText());
  await localExtensionPackages.stage(pkg);
  expect((await localExtensionPackages.get(manifest.id))?.installed).toBe(false);
  expect(
    (await localExtensionPackages.list()).find((entry) => entry.manifest.id === manifest.id)?.manifest.lsp
      ?.requiredExecutables,
  ).toEqual(["node"]);
  await localExtensionPackages.markInstalled(manifest.id);
  expect((await localExtensionPackages.get(manifest.id))?.installed).toBe(true);
  await expect(localExtensionPackages.stage(pkg)).rejects.toThrow("Disable");
  localExtensionPackages.remove(manifest.id);
  expect(await localExtensionPackages.get(manifest.id)).toBeUndefined();
});

test("package input cannot grant arbitrary services or escape declared root files", async () => {
  const pkg = await parseLocalExtensionPackage(
    packageText({
      permissions: { secrets: true, network: ["*"] },
      formatter: { name: "unexpected" },
    }),
  );
  expect(pkg.manifest.permissions).toBeUndefined();
  expect(pkg.manifest.formatter).toBeUndefined();
  for (const file of ["../secret", "/secret", "C:\\secret", "a/b"]) {
    await expect(
      parseLocalExtensionPackage(
        packageText({ runActions: { manifestFiles: [file], executables: ["php"] } }),
      ),
    ).rejects.toThrow();
  }
  await expect(parseLocalExtensionPackage(packageText({ main: "../plugin.js" }))).rejects.toThrow();
});

test("malformed and oversized packages fail before storage", async () => {
  await expect(parseLocalExtensionPackage("x")).rejects.toThrow();
  await expect(parseLocalExtensionPackage(" ".repeat(256 * 1024 + 1))).rejects.toThrow();
  await expect(parseLocalExtensionPackage(packageText({ languages: [] }))).rejects.toThrow();
  expect(await localExtensionPackages.get(manifest.id)).toBeUndefined();
});

test("replacement and rollback preserve the previous installed source atomically", async () => {
  const first = await parseLocalExtensionPackage(packageText());
  await localExtensionPackages.stage(first);
  await localExtensionPackages.markInstalled(manifest.id);
  const second = await parseLocalExtensionPackage(packageText({ version: "1.1.0" }));
  await localExtensionPackages.stage(second, undefined, true);
  expect((await localExtensionPackages.previous(manifest.id))?.manifest.version).toBe("1.0.0");
  await localExtensionPackages.markInstalled(manifest.id);
  await localExtensionPackages.rollback(manifest.id);
  expect((await localExtensionPackages.get(manifest.id))?.manifest.version).toBe("1.0.0");
  expect((await localExtensionPackages.previous(manifest.id))?.manifest.version).toBe("1.1.0");
});

test("interrupted replacement recovers the last committed version on startup", async () => {
  await localExtensionPackages.stage(await parseLocalExtensionPackage(packageText()));
  await localExtensionPackages.markInstalled(manifest.id);
  await localExtensionPackages.stage(await parseLocalExtensionPackage(packageText({ version: "1.2.0" })), undefined, true);
  await localExtensionPackages.recoverInterruptedReplacements();
  expect((await localExtensionPackages.get(manifest.id))?.manifest.version).toBe("1.0.0");
  expect((await localExtensionPackages.get(manifest.id))?.installed).toBe(true);
});
