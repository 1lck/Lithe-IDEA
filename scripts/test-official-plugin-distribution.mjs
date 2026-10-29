import assert from "node:assert/strict";
import test from "node:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { isBundledOfficialPlugin, readDistributionIndex } from "./official-plugin-distribution.mjs";
import { loadConfig, releaseFor, updateIndex } from "./official-plugin-releases.mjs";
const id = "dev.lithe.plugin.java-support";
const config = loadConfig();
const java = config.find((entry) => entry.id === id);
const release = releaseFor(java);
const empty = { schemaVersion: 1, plugins: [] };
function published() {
  return structuredClone(updateIndex(empty, release, {
    checksums: Object.fromEntries(release.assets.map((asset, i) => [asset.assetName, String(i + 1).repeat(64)])),
    releaseDate: "2026-10-25",
  }));
}
test("unknown and retired plugins never enter the default app", () => {
  for (const plugin of ["dev.lithe.plugin.go-support", "dev.lithe.plugin.php-support", "new.optional.plugin"]) {
    assert.equal(isBundledOfficialPlugin(plugin), false);
  }
});
test("empty official source retains the transition Java package", () => {
  assert.equal(isBundledOfficialPlugin(id, empty), true);
  assert.equal(readDistributionIndex().schemaVersion, 1);
});
test("both published architectures remove the default package even while automatic release is paused", () => {
  assert.equal(java.releaseEnabled, false);
  assert.equal(isBundledOfficialPlugin(id, published()), false);
});
test("partial, ambiguous, invalid or foreign downloads keep the transition copy", () => {
  const changes = [
    (entry) => entry.versions[0].downloads.pop(),
    (entry) => { entry.versions[0].downloads[1] = entry.versions[0].downloads[0]; },
    (entry) => { entry.versions[0].downloads[0].sha256 = "invalid"; },
    (entry) => { entry.versions[0].downloads[0].downloadURL += "?wrong"; },
    (entry) => { entry.repository = "https://github.com/untrusted/plugin"; },
    (entry) => { entry.versions[0].requires.packageTrust = 2; },
    (entry) => { delete entry.versions[0].requires.packageTrust; },
    (entry) => { entry.versions[0].pluginAPIVersion = 1; },
    (entry) => { entry.versions[0].version = "1.0.0"; },
  ];
  for (const change of changes) {
    const index = published(); change(index.plugins[0]);
    assert.equal(isBundledOfficialPlugin(id, index), true);
  }
});
test("later compatible published versions also satisfy the transition cutoff", () => {
  const index = published();
  const version = index.plugins[0].versions[0];
  version.version = "1.2.0";
  for (const download of version.downloads) download.downloadURL = download.downloadURL.replaceAll(release.version, version.version);
  assert.equal(isBundledOfficialPlugin(id, index), false);
});

test("broken index input fails the CLI instead of returning an omit decision", { timeout: 15000 }, () => {
  const directory = mkdtempSync(join(tmpdir(), "lithe-package-verification."));
  try {
    const index = join(directory, "published-index.fixture.json");
    for (const contents of ["{broken", '{"schemaVersion":2,"plugins":[]}']) {
      writeFileSync(index, contents);
      const result = spawnSync(process.execPath, [
        fileURLToPath(new URL("./official-plugin-distribution.mjs", import.meta.url)), id, index,
      ], { encoding: "utf8", timeout: 5000, maxBuffer: 1024 * 1024 });
      assert.equal(result.error, undefined);
      assert.notEqual(result.status, 0);
      assert.equal(result.stdout, "");
    }
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
