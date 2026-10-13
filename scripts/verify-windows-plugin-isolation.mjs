#!/usr/bin/env node
import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
const root = fileURLToPath(new URL("../", import.meta.url));
async function files(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const groups = await Promise.all(entries.map((entry) => entry.isDirectory() ? files(path.join(directory, entry.name)) : [path.join(directory, entry.name)]));
  return groups.flat();
}
// Inspect production imports, including dynamic imports and re-exports. Type-only SDK imports are allowed.
for (const file of await files(path.join(root, "windows/tauri/src"))) {
  if (!/\.[cm]?[jt]sx?$/.test(file) || /\.(test|spec)\./.test(file)) continue;
  const source = await readFile(file, "utf8");
  assert(!/[@/]lithe\/php|(?:Official\/PhpSupport|PhpSupport\/)/.test(source), `PHP implementation imported by host: ${file}`);
  if (/extensions\/languages\/full-extensions\.ts$/.test(file)) assert(!source.includes("intelephense"), "PHP language configuration must live in its package");
}
const pkgPath = path.join(root, ".artifacts/windows-plugins/lithe.php-1.0.0.lithe-extension");
const pkg = JSON.parse(await readFile(pkgPath, "utf8"));
assert.equal(pkg.manifest.id, "lithe.php");
assert.equal(pkg.manifest.main, "plugin.js");
assert(pkg.source.includes("discoverRunActions"));
assert(!/(?:from\s*["']@\/|import\s*\(["']@\/)/.test(pkg.source), "Plugin must not import application services");
console.log("Windows PHP plugin package is independent of host production imports.");
if (process.argv.includes("--dist")) {
  for (const file of await files(path.join(root, "windows/tauri/dist"))) {
    if (!/\.(js|json)$/.test(file)) continue;
    const source = await readFile(file, "utf8");
    assert(!/intelephense|vendor\/bin\/phpunit|composer:/.test(source), `PHP implementation leaked into application output: ${file}`);
  }
  console.log("Built application contains no PHP worker implementation or Intelephense configuration.");
}
