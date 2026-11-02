import assert from "node:assert/strict";
import test from "node:test";
import { createHash } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { isAbsolute, join, relative } from "node:path";
import { check, loadConfig, localReleaseAssets, pendingIndex, plan, planWithDrafts, publishDraft, releaseFor, updateIndex } from "./official-plugin-releases.mjs";

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
  assert.deepEqual(releaseFor(java).assets.map((asset) => asset.platforms), [["darwin-arm64"], ["darwin-x64"], ["windows-x64"], ["windows-arm64"]]);
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

const frozenSample = () => ({ ...releaseFor(sample, readManifest), revision: "a".repeat(40), releaseEnabled: true });
const draftFor = (release) => ({ draft: true, tag_name: release.tag, target_commitish: release.revision, assets: [] });

test("recovery tooling in another checkout receives absolute verified assets and preserves publication gate", async () => {
  const directory = mkdtempSync(join(tmpdir(), "lithe-publish-assets-"));
  try {
    const release = frozenSample();
    const content = Buffer.from("controlled archive");
    const sha256 = createHash("sha256").update(content).digest("hex");
    for (const asset of release.assets) {
      writeFileSync(join(directory, asset.assetName), content);
      writeFileSync(join(directory, `${asset.assetName}.sha256`), `${sha256}\n`);
    }
    const assets = await localReleaseAssets(release, relative(process.cwd(), directory));
    assert.equal(assets.length, release.assets.length * 2);
    assert.ok(assets.every((asset) => isAbsolute(asset.path) && asset.path === join(directory, asset.name)));
    await assert.rejects(localReleaseAssets({ ...release, releaseEnabled: false }, directory), /disabled/);
    writeFileSync(join(directory, release.assets[0].assetName), "replaced");
    await assert.rejects(localReleaseAssets(release, directory), /checksum mismatch/);
  } finally { rmSync(directory, { recursive: true, force: true }); }
});

test("draft recovery plans frozen inputs with or without a Git tag and after a version upgrade", () => {
  const release = frozenSample();
  const newer = { ...release, version: "1.2.0", tag: `${sample.tagPrefix}1.2.0` };
  for (const tagged of [null, release.revision]) {
    assert.deepEqual(planWithDrafts([draftFor(release)], [sample], {
      fresh: () => [release, newer], revisionFor: () => tagged,
      freeze: (id, revision) => { assert.equal(id, sample.id); assert.equal(revision, release.revision); return release; },
    }), [release, newer]);
  }
  for (const change of [{ target_commitish: "preview" }, { tag_name: `${sample.tagPrefix}9.0.0` }]) {
    assert.throws(() => planWithDrafts([{ ...draftFor(release), ...change }], [sample], {
      fresh: () => [], freeze: () => release, revisionFor: () => null,
    }), /immutable|identity/);
  }
  assert.throws(() => planWithDrafts([draftFor(release)], [sample], {
    fresh: () => [], freeze: () => release, revisionFor: () => "b".repeat(40),
  }), /another revision/);
  assert.deepEqual(planWithDrafts([draftFor(release)], [{ ...sample, releaseEnabled: false }], {
    fresh: () => [], freeze: () => { throw new Error("disabled draft must stay closed"); },
  }), []);
});

function releaseClient(release) {
  let draft;
  const calls = [];
  const client = {
    calls, tagRevision: () => null, find: async () => structuredClone(draft),
    create: async () => { calls.push("create"); draft = draftFor(release); },
    upload: async (_tag, assets) => { calls.push("upload"); draft.assets = assets.map((asset) => ({ name: asset.name, digest: asset.sha256 })); },
    digest: async (_tag, asset) => asset.digest,
    publish: async () => { calls.push("publish"); draft.draft = false; },
    set: (value) => { draft = structuredClone(value); },
  };
  return client;
}

test("create then upload/publish failure resumes the same draft without recreating or moving its tag", async () => {
  const release = frozenSample();
  const assets = release.assets.map((asset) => ({ name: asset.assetName, sha256: "1".repeat(64) }));
  for (const stage of ["upload", "publish"]) {
    const client = releaseClient(release), original = client[stage];
    client[stage] = async () => { throw new Error("injected interruption"); };
    await assert.rejects(publishDraft(release, assets, client), /injected interruption/);
    client[stage] = original;
    await publishDraft(release, assets, client);
    assert.equal(client.calls.filter((call) => call === "create").length, 1);
    assert.equal(client.calls.at(-1), "publish");
    await assert.rejects(publishDraft(release, assets, client), /published/);
  }
});

test("draft publication rejects wrong identity, tag, partial/extra assets and altered bytes", async () => {
  const release = frozenSample();
  const assets = release.assets.map((asset) => ({ name: asset.assetName, sha256: "1".repeat(64) }));
  for (const mutation of [
    (client) => client.set({ ...draftFor(release), target_commitish: "b".repeat(40) }),
    (client) => { client.tagRevision = () => "b".repeat(40); },
    (client) => { client.upload = async () => {}; },
    (client) => client.set({ ...draftFor(release), assets: [{ name: "foreign.zip" }] }),
    (client) => { client.digest = async () => "2".repeat(64); },
  ]) {
    const client = releaseClient(release);
    client.set(draftFor(release)); mutation(client);
    await assert.rejects(publishDraft(release, assets, client), /identity|revision|Incomplete|Unexpected|bytes/);
    assert.ok(!client.calls.includes("publish"));
  }
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

const windowsSample = () => ({ ...sample, assets: [
  ...sample.assets,
  ...[["x86_64", "windows-x64"], ["arm64", "windows-arm64"]].map(([arch, platform]) => ({
    assetName: `Sample-{version}-${platform}.zip`, platforms: [platform], arch,
    packageDirectory: "Plugins/win/Official/SampleSupport",
  })),
] });

test("platform assets retain their real manifest and cannot mix directories, capabilities or architectures", () => {
  const plugin = windowsSample();
  const missingArch = structuredClone(plugin); delete missingArch.assets[2].arch;
  assert.throws(() => releaseFor(missingArch, readManifest), /require a runtime architecture/);
  const release = releaseFor(plugin, readManifest);
  assert.equal(release.assets[2].packageDirectory, "Plugins/win/Official/SampleSupport");
  assert.deepEqual(release.assets[2].requires, manifest.requires);
  assert.throws(() => releaseFor({ ...plugin, assets: plugin.assets.slice(0, 3) }, readManifest), /both architectures/);
  assert.throws(() => releaseFor({ ...plugin, assets: plugin.assets.map((a) => ({ ...a, packageDirectory: sample.packageDirectory })) }, readManifest), /disagree/);
  for (const override of [{ version: "2.0.0" }, { requires: { languages: 1 } }, { pluginAPIVersion: 2 }]) {
    assert.throws(() => releaseFor(plugin, (dir) => ({ ...manifest, ...(dir.includes("/win/") ? override : {}) })), /identical/);
  }
});

test("Windows index atomically binds verified ZIP hashes, platform, manifest, revision and tag", () => {
  const release = { ...releaseFor(windowsSample(), readManifest), revision: "a".repeat(40), inputFiles: { "sample/input": "f".repeat(64) } };
  for (const asset of release.assets) asset.manifestSHA256 = "f".repeat(64);
  const checksums = checksumsFor(release);
  const evidence = { schemaVersion: 1, complete: true, mode: "verify", kind: "windows-java-release", publisherVerification: "verified-existing-signer",
    inputFiles: release.inputFiles, revision: release.revision, tag: release.tag, pluginId: release.id, version: release.version,
    assets: release.assets.filter((a) => a.os === "windows").map((a) => ({
      ...a, architecture: a.arch, sha256: checksums[a.assetName],
    })),
  };
  const options = { checksums, releaseDate: "2026-11-01", assetEvidence: evidence };
  assert.equal(updateIndex(empty(), release, options).plugins[0].versions[0].downloads.length, 4);
  for (const mutate of [
    (e) => { e.publisherVerification = "not-performed"; }, (e) => { e.revision = "b".repeat(40); },
    (e) => { e.tag += "-wrong"; }, (e) => { e.inputFiles["sample/input"] = "0".repeat(64); }, (e) => { e.assets.pop(); },
    ...["sha256", "packageDirectory", "architecture", "manifestSHA256"].map((key) => (e) => { e.assets[0][key] = "replaced"; }),
    (e) => { e.assets[0].platforms = ["darwin-arm64"]; },
  ]) {
    const changed = structuredClone(evidence); mutate(changed);
    assert.throws(() => updateIndex(empty(), release, { ...options, assetEvidence: changed }));
  }
  assert.throws(() => updateIndex(empty(), release, { checksums, releaseDate: options.releaseDate }));
});
