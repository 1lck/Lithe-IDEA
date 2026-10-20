import assert from "node:assert/strict";
import test from "node:test";
import { check, loadConfig, pendingIndex, plan, releaseFor, updateIndex } from "./official-plugin-releases.mjs";

// Go and PHP Support moved to Lithe Store, so no downloadable official plugin
// is configured right now. The release flow is kept for future official
// plugins and tested with a synthetic one.
const sample = {
  id: "dev.lithe.plugin.sample-support",
  tagPrefix: "plugin-sample-support-v",
  packageDirectory: "Plugins/mac/Official/SampleSupport",
  assetName: "Lithe-Sample-Support-{version}-darwin.zip",
  platforms: ["darwin-arm64", "darwin-x64"],
  index: {
    name: "Sample Support",
    author: "Lithe",
    repository: "https://github.com/Lithe-IDEA/Lithe-IDEA",
    description: "Sample official plugin.",
    tags: ["language"],
    license: "Apache-2.0",
  },
};
const plugins = [sample];
const readManifest = (directory) => {
  assert.equal(directory, sample.packageDirectory);
  return { id: sample.id, version: "1.0.0" };
};

test("the repository configuration currently lists no downloadable official plugin", () => {
  assert.deepEqual(loadConfig(), []);
  assert.deepEqual(plan(), []);
  assert.deepEqual(check(), []);
  assert.deepEqual(pendingIndex(), []);
});

test("each official plugin has its own tag series", () => {
  const release = releaseFor(sample, readManifest);
  assert.equal(release.tag, `plugin-sample-support-v${release.version}`);
  assert.equal(release.assetName, `Lithe-Sample-Support-${release.version}-darwin.zip`);
  assert.throws(() => releaseFor(sample, () => ({ id: "dev.lithe.plugin.other", version: "1.0.0" })));
  assert.throws(() => releaseFor(sample, () => ({ id: sample.id, version: "1.0" })));
});

test("only untagged versions are planned", () => {
  assert.equal(plan(plugins, () => true, readManifest).length, 0);
  assert.deepEqual(plan(plugins, () => false, readManifest).map((release) => release.id), [sample.id]);
});

test("changing a released plugin without a new version fails", () => {
  assert.deepEqual(check(plugins, () => true, () => false, readManifest), []);
  assert.equal(check(plugins, () => true, () => true, readManifest).length, plugins.length);
  // A version that was never tagged is released on merge instead.
  assert.deepEqual(check(plugins, () => false, () => true, readManifest), []);
});

test("index update keeps versions newest first and points at the tag asset", () => {
  const sha = "a".repeat(64);
  let index = { schemaVersion: 1, plugins: [] };
  index = updateIndex(index, sample, { version: "1.0.0", sha256: sha, releaseDate: "2026-10-12" });
  index = updateIndex(index, sample, { version: "1.2.0", sha256: sha, releaseDate: "2026-11-01" });
  index = updateIndex(index, sample, { version: "1.1.0", sha256: sha, releaseDate: "2026-10-20" });
  const entry = index.plugins[0];
  assert.deepEqual(entry.versions.map((version) => version.version), ["1.2.0", "1.1.0", "1.0.0"]);
  assert.equal(
    entry.versions[0].downloads[0].downloadURL,
    "https://github.com/Lithe-IDEA/Lithe-IDEA/releases/download/plugin-sample-support-v1.2.0/Lithe-Sample-Support-1.2.0-darwin.zip",
  );
  assert.deepEqual(entry.versions[0].downloads[0].platforms, ["darwin-arm64", "darwin-x64"]);
  assert.throws(() => updateIndex(index, sample, { version: "1.3.0", sha256: "ABC", releaseDate: "2026-11-02" }));
});

test("tagged versions missing from the index are pending, so a failed listing is retried", () => {
  const sha = "a".repeat(64);
  const tags = (prefix) => (prefix === sample.tagPrefix
    ? [`${prefix}1.0.0`, `${prefix}1.1.0`, `${prefix}not-a-version`]
    : []);
  // Nothing listed yet: every released version is pending.
  assert.deepEqual(
    pendingIndex(plugins, { schemaVersion: 1, plugins: [] }, tags).map((release) => release.tag),
    [`${sample.tagPrefix}1.0.0`, `${sample.tagPrefix}1.1.0`],
  );
  // 1.0.0 was listed but 1.1.0's index pull request failed: only 1.1.0 is
  // retried, with the asset name of that version.
  const index = updateIndex({ schemaVersion: 1, plugins: [] }, sample, { version: "1.0.0", sha256: sha, releaseDate: "2026-10-12" });
  const pending = pendingIndex(plugins, index, tags);
  assert.deepEqual(pending.map((release) => release.version), ["1.1.0"]);
  assert.equal(pending[0].assetName, "Lithe-Sample-Support-1.1.0-darwin.zip");
  // Once listed, nothing is pending.
  const listed = updateIndex(index, sample, { version: "1.1.0", sha256: sha, releaseDate: "2026-10-20" });
  assert.deepEqual(pendingIndex(plugins, listed, tags), []);
});
