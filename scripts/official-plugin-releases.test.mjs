import assert from "node:assert/strict";
import test from "node:test";
import { check, loadConfig, pendingIndex, plan, releaseFor, updateIndex } from "./official-plugin-releases.mjs";

const plugins = loadConfig();
const php = plugins.find((plugin) => plugin.id === "dev.lithe.plugin.php-support");

test("each official plugin has its own tag series", () => {
  const release = releaseFor(php);
  assert.equal(release.tag, `plugin-php-support-v${release.version}`);
  assert.equal(release.assetName, `Lithe-PHP-Support-${release.version}-darwin.zip`);
  const prefixes = plugins.map((plugin) => plugin.tagPrefix);
  assert.equal(new Set(prefixes).size, prefixes.length);
});

test("only untagged versions are planned", () => {
  assert.equal(plan(plugins, () => true).length, 0);
  assert.deepEqual(plan(plugins, () => false).map((release) => release.id), plugins.map((plugin) => plugin.id));
});

test("changing a released plugin without a new version fails", () => {
  assert.deepEqual(check(plugins, () => true, () => false), []);
  assert.equal(check(plugins, () => true, () => true).length, plugins.length);
  // A version that was never tagged is released on merge instead.
  assert.deepEqual(check(plugins, () => false, () => true), []);
});

test("index update keeps versions newest first and points at the tag asset", () => {
  const sha = "a".repeat(64);
  let index = { schemaVersion: 1, plugins: [] };
  index = updateIndex(index, php, { version: "1.0.0", sha256: sha, releaseDate: "2026-10-12" });
  index = updateIndex(index, php, { version: "1.2.0", sha256: sha, releaseDate: "2026-11-01" });
  index = updateIndex(index, php, { version: "1.1.0", sha256: sha, releaseDate: "2026-10-20" });
  const entry = index.plugins[0];
  assert.deepEqual(entry.versions.map((version) => version.version), ["1.2.0", "1.1.0", "1.0.0"]);
  assert.equal(
    entry.versions[0].downloads[0].downloadURL,
    "https://github.com/Lithe-IDEA/Lithe-IDEA/releases/download/plugin-php-support-v1.2.0/Lithe-PHP-Support-1.2.0-darwin.zip",
  );
  assert.deepEqual(entry.versions[0].downloads[0].platforms, ["darwin-arm64", "darwin-x64"]);
  assert.throws(() => updateIndex(index, php, { version: "1.3.0", sha256: "ABC", releaseDate: "2026-11-02" }));
});

test("tagged versions missing from the index are pending, so a failed listing is retried", () => {
  const sha = "a".repeat(64);
  const tags = (prefix) => (prefix === php.tagPrefix
    ? [`${prefix}1.0.0`, `${prefix}1.1.0`, `${prefix}not-a-version`]
    : []);
  // Nothing listed yet: every released version is pending.
  assert.deepEqual(
    pendingIndex(plugins, { schemaVersion: 1, plugins: [] }, tags).map((release) => release.tag),
    [`${php.tagPrefix}1.0.0`, `${php.tagPrefix}1.1.0`],
  );
  // 1.0.0 was listed but 1.1.0's index pull request failed: only 1.1.0 is
  // retried, with the asset name of that version.
  const index = updateIndex({ schemaVersion: 1, plugins: [] }, php, { version: "1.0.0", sha256: sha, releaseDate: "2026-10-12" });
  const pending = pendingIndex(plugins, index, tags);
  assert.deepEqual(pending.map((release) => release.version), ["1.1.0"]);
  assert.equal(pending[0].assetName, "Lithe-PHP-Support-1.1.0-darwin.zip");
  // Once listed, nothing is pending.
  const listed = updateIndex(index, php, { version: "1.1.0", sha256: sha, releaseDate: "2026-10-20" });
  assert.deepEqual(pendingIndex(plugins, listed, tags), []);
});
