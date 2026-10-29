import assert from "node:assert/strict";
import test from "node:test";
import { check, loadConfig, pendingIndex, plan, releaseFor, updateIndex } from "./official-plugin-releases.mjs";

const sample = {
  id: "dev.lithe.plugin.sample-support", tagPrefix: "plugin-sample-support-v",
  packageDirectory: "Plugins/mac/Official/SampleSupport",
  assets: [
    { assetName: "Sample-{version}-arm64.zip", platforms: ["darwin-arm64"], arch: "arm64" },
    { assetName: "Sample-{version}-x64.zip", platforms: ["darwin-x64"], arch: "x86_64" },
  ],
  inputPaths: ["third_party/sample/manifest.json"],
  index: { name: "Sample", author: "Lithe", repository: "https://github.com/example/ide", description: "Sample official plugin", license: "MIT" },
};
const manifest = { id: sample.id, version: "1.1.0", pluginAPIVersion: 3, requires: { languages: 1, packageTrust: 1 } };
const readManifest = () => structuredClone(manifest);
const empty = () => ({ schemaVersion: 1, plugins: [] });
const checksumsFor = (release) => Object.fromEntries(release.assets.map((asset, i) => [asset.assetName, String(i + 1).repeat(64)]));
const list = (index, release) => updateIndex(index, release, { checksums: checksumsFor(release), releaseDate: "2026-10-25" });

test("Java release inputs are configured but automatic publication waits for host rollout", () => {
  const config = loadConfig();
  const java = config.find((entry) => entry.id === "dev.lithe.plugin.java-support");
  assert.equal(java.releaseEnabled, false);
  assert.deepEqual(releaseFor(java).assets.map((asset) => asset.platforms), [["darwin-arm64"], ["darwin-x64"]]);
  assert.deepEqual(plan(config, () => false), []);
  assert.deepEqual(pendingIndex(config, empty(), () => ["plugin-java-support-v1.1.0"], () => {
    throw new Error("A paused plugin must not be indexed even if a tag exists");
  }), []);
});

test("plans carry the actual API and capability metadata plus every architecture", () => {
  const release = releaseFor(sample, readManifest);
  assert.equal(release.pluginAPIVersion, 3);
  assert.deepEqual(release.requires, manifest.requires);
  assert.equal(release.tag, "plugin-sample-support-v1.1.0");
  assert.deepEqual(release.assets.map((asset) => asset.assetName), ["Sample-1.1.0-arm64.zip", "Sample-1.1.0-x64.zip"]);
  assert.deepEqual(plan([sample], () => true, readManifest), []);
  assert.equal(plan([sample], () => false, readManifest).length, 1);
});

test("rejects inconsistent manifest, overlapping platforms, assets and missing capability metadata", () => {
  assert.throws(() => releaseFor(sample, () => ({ ...manifest, id: "wrong" })));
  assert.throws(() => releaseFor(sample, () => ({ ...manifest, version: "1.0" })));
  assert.throws(() => releaseFor(sample, () => ({ ...manifest, requires: undefined })));
  assert.throws(() => releaseFor({ ...sample, assets: [sample.assets[0], sample.assets[0]] }, readManifest));
  assert.throws(() => releaseFor({ ...sample, assets: [{ ...sample.assets[0], assetName: "../bad.zip" }] }, readManifest));
  assert.throws(() => releaseFor({ ...sample, assets: [{ ...sample.assets[0], platforms: [] }] }, readManifest));
  assert.throws(() => releaseFor({ ...sample, assets: [{ ...sample.assets[0], arch: "x86_64" }] }, readManifest));
});

test("released plugin resources and shared upstream inputs require a version bump", () => {
  assert.deepEqual(check([sample], () => true, () => false, readManifest), []);
  assert.equal(check([sample], () => true, (_tag, paths) => {
    assert.deepEqual(paths, [sample.packageDirectory, ...sample.inputPaths]); return true;
  }, readManifest).length, 1);
  assert.deepEqual(check([sample], () => false, () => true, readManifest), []);
});

test("index lists all architectures with actual manifest metadata and no partial version", () => {
  const release = releaseFor(sample, readManifest);
  const index = list(empty(), release);
  const version = index.plugins[0].versions[0];
  assert.equal(version.pluginAPIVersion, 3);
  assert.deepEqual(version.requires, manifest.requires);
  assert.equal(version.downloads.length, 2);
  assert.equal(version.downloads[1].downloadURL, "https://github.com/example/ide/releases/download/plugin-sample-support-v1.1.0/Sample-1.1.0-x64.zip");
  assert.equal(version.downloads[1].sha256, "2".repeat(64));
  for (const checksums of [{}, { [release.assets[0].assetName]: "1".repeat(64) }, { ...checksumsFor(release), extra: "3".repeat(64) }, { ...checksumsFor(release), [release.assets[0].assetName]: "ABC" }]) {
    assert.throws(() => updateIndex(index, release, { checksums, releaseDate: "2026-10-25" }));
  }
  assert.deepEqual(empty(), { schemaVersion: 1, plugins: [] });
});

test("index retry uses old tagged API, requirements and asset names after a source upgrade", () => {
  const old = releaseFor({ ...sample, assets: [{ assetName: "Original-{version}.zip", platforms: ["darwin-arm64", "darwin-x64"] }] }, () => ({ id: sample.id, version: "1.0.0", pluginAPIVersion: 1 }));
  const current = releaseFor(sample, readManifest);
  const readTagged = (_plugin, tag) => tag.endsWith("1.0.0") ? old : current;
  const tags = () => [old.tag, current.tag, `${sample.tagPrefix}not-a-version`];
  const pending = pendingIndex([sample], empty(), tags, readTagged);
  assert.deepEqual(pending, [old, current]);
  const oldIndex = list(empty(), pending[0]);
  assert.equal(oldIndex.plugins[0].versions[0].pluginAPIVersion, 1);
  assert.equal(oldIndex.plugins[0].versions[0].requires, undefined);
  assert.match(oldIndex.plugins[0].versions[0].downloads[0].downloadURL, /Original-1.0.0.zip$/);
  assert.deepEqual(pendingIndex([sample], oldIndex, tags, readTagged), [current]);
  const complete = list(oldIndex, current);
  assert.deepEqual(pendingIndex([sample], complete, tags, readTagged), []);
  assert.deepEqual(complete.plugins[0].versions.map((version) => version.version), ["1.1.0", "1.0.0"]);
});

test("refuses a tag whose package version disagrees rather than listing another release", () => {
  assert.throws(() => pendingIndex([sample], empty(), () => [`${sample.tagPrefix}1.0.0`], () => releaseFor(sample, readManifest)));
});
