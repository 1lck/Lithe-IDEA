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
  assert(!/[@/]lithe\/php|(?:Official\/(?:Php|Go)Support|(?:Php|Go)Support\/)/.test(source), `Language plugin implementation imported by host: ${file}`);
  if (/extensions\/languages\/full-extensions\.ts$/.test(file)) assert(!source.includes("intelephense"), "PHP language configuration must live in its package");
}
for (const id of ["lithe.php", "lithe.go"]) {
const candidates = (await readdir(path.join(root, ".artifacts/windows-plugins")))
  .filter((file) => file.startsWith(`${id}-`) && file.endsWith(".lithe-extension"));
assert(candidates.length > 0, `Missing package ${id}`);
const bundle = JSON.parse(await readFile(path.join(root, ".artifacts/windows-plugins", candidates[0]), "utf8"));
assert.equal(bundle.format, "lithe-native-worker-plugin");
const pkg = { manifest: JSON.parse(Buffer.from(bundle.files["plugin.json"], "base64").toString()),
  source: Buffer.from(bundle.files["plugin.js"], "base64").toString() };
assert(bundle.files[pkg.manifest.lsp.server.default], "Packaged LSP entrypoint is missing");
assert.equal(pkg.manifest.lsp.runtime, "package");
assert.equal(pkg.manifest.id, id);
assert.equal(pkg.manifest.main, "plugin.js");
assert(pkg.source.includes("discoverRunActions"));
assert(!/(?:from\s*["']@\/|import\s*\(["']@\/)/.test(pkg.source), "Plugin must not import application services");
}
console.log("Windows PHP and Go plugin packages are independent of host production imports.");
if (process.argv.includes("--dist")) {
  for (const file of await files(path.join(root, "windows/tauri/dist"))) {
    if (!/\.(js|json)$/.test(file)) continue;
    const source = await readFile(file, "utf8");
    assert(!/intelephense|vendor\/bin\/phpunit|composer:/.test(source), `PHP implementation leaked into application output: ${file}`);
  }
  console.log("Built application contains no PHP worker implementation or Intelephense configuration.");
}
