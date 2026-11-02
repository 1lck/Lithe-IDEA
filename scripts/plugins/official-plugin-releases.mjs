#!/usr/bin/env node
// Plan immutable official plugin releases and list their exact tagged inputs.
// An index retry must never describe an old archive using today's manifest.
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { createReadStream, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = join(fileURLToPath(new URL(".", import.meta.url)), "../..");
const configFile = "Plugins/marketplace/official-plugins.json";
const configPath = join(root, configFile);
const indexPath = join(root, "Plugins/marketplace/index.json");
const versionPattern = /^\d+\.\d+\.\d+$/;

export function loadConfig(path = configPath) {
  const config = JSON.parse(readFileSync(path, "utf8"));
  if (config.schemaVersion !== 1 || !Array.isArray(config.plugins)) {
    throw new Error("official-plugins.json must use schemaVersion 1");
  }
  return config.plugins;
}

function git(args, encoding = "utf8") {
  const result = execFileSync("git", args, {
    cwd: root, encoding, stdio: ["ignore", "pipe", "pipe"], timeout: 30_000,
  });
  return encoding === "buffer" ? result : result.trim();
}

function tagExists(tag) {
  try { git(["rev-parse", "--verify", "--quiet", `refs/tags/${tag}`]); return true; }
  catch (error) { if (error.status === 1) return false; throw error; }
}

function tagsWithPrefix(prefix) {
  return git(["tag", "--list", `${prefix}*`]).split("\n").filter(Boolean);
}

function changedSince(tag, paths) {
  try { git(["diff", "--quiet", tag, "HEAD", "--", ...paths]); return false; }
  catch (error) { if (error.status === 1) return true; throw error; }
}

function readPackageManifest(directory) {
  return JSON.parse(readFileSync(join(root, directory, "plugin.json"), "utf8"));
}

export function releaseFor(plugin, readManifest = readPackageManifest) {
  const manifest = readManifest(plugin.packageDirectory);
  if (manifest.id !== plugin.id) throw new Error("Plugin manifest ID does not match its release configuration");
  if (!versionPattern.test(manifest.version)) throw new Error(`${plugin.id} version must be major.minor.patch`);
  if (![1, 2, 3].includes(manifest.pluginAPIVersion)) throw new Error("Missing or unsupported pluginAPIVersion");
  if (!/^[a-z0-9-]+-v$/.test(plugin.tagPrefix)) throw new Error("Invalid plugin tag prefix");
  const repository = plugin.index.repository.replace(/\/$/, "");
  if (!/^https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository)) {
    throw new Error("Invalid plugin release repository");
  }
  const metadata = (value) => JSON.stringify([value.pluginAPIVersion, Object.entries(value.requires ?? {}).sort()]);
  const platforms = new Set();
  const names = new Set();
  const assets = (plugin.assets ?? [{ assetName: plugin.assetName, platforms: plugin.platforms }]).map((asset) => {
    const assetName = asset.assetName?.replaceAll("{version}", manifest.version);
    if (!assetName || !/^[A-Za-z0-9_.-]+\.zip$/.test(assetName) || names.has(assetName)) {
      throw new Error("Invalid or duplicate plugin asset name");
    }
    names.add(assetName);
    if (!Array.isArray(asset.platforms) || !asset.platforms.length) throw new Error("An asset needs platforms");
    for (const platform of asset.platforms) {
      if (!/^[a-z0-9]+-[a-z0-9]+$/.test(platform) || platforms.has(platform)) {
        throw new Error("Invalid or duplicate plugin platform");
      }
      platforms.add(platform);
    }
    const packageDirectory = asset.packageDirectory ?? plugin.packageDirectory;
    if (!/^Plugins\/(mac|win)\/Official\/[A-Za-z0-9_-]+$/.test(packageDirectory)) throw new Error("Invalid packageDirectory");
    const assetManifest = readManifest(packageDirectory);
    if (assetManifest.id !== manifest.id || assetManifest.version !== manifest.version
        || metadata(assetManifest) !== metadata(manifest)) {
      throw new Error("Asset manifests must have identical identity, API and requires for one index version");
    }
    const os = asset.platforms.every((platform) => platform.startsWith("windows-")) ? "windows" : "macos";
    if (asset.platforms.some((platform) => !platform.startsWith(os === "windows" ? "windows-" : "darwin-"))
        || !packageDirectory.startsWith(os === "windows" ? "Plugins/win/" : "Plugins/mac/")) {
      throw new Error("Asset platform and packageDirectory disagree");
    }
    if (os === "windows" && !asset.arch) throw new Error("Windows assets require a runtime architecture");
    if (asset.arch !== undefined && !["arm64", "x86_64", "universal"].includes(asset.arch)) {
      throw new Error("Invalid runtime architecture");
    }
    if (asset.arch && asset.platforms.some((platform) =>
      !((os === "windows" ? { arm64: ["windows-arm64"], x86_64: ["windows-x64"], universal: [] } : { arm64: ["darwin-arm64"], x86_64: ["darwin-x64"], universal: ["darwin-arm64", "darwin-x64"] })[asset.arch]).includes(platform))) {
      throw new Error("Plugin asset platforms do not match its runtime architecture");
    }
    return { assetName, platforms: [...asset.platforms], os, packageDirectory,
      pluginAPIVersion: assetManifest.pluginAPIVersion, ...(assetManifest.requires ? { requires: assetManifest.requires } : {}),
      ...(asset.arch ? { arch: asset.arch } : {}) };
  });
  if (!assets.length) throw new Error("A release needs assets");
  if (assets.some((asset) => asset.os === "windows")
      && !["windows-x64", "windows-arm64"].every((platform) => platforms.has(platform))) {
    throw new Error("Windows release requires both architectures");
  }
  if ((plugin.requiredPlatforms ?? []).some((platform) => !platforms.has(platform))) throw new Error("Missing required release platform");
  let requires;
  if (manifest.pluginAPIVersion === 3) {
    if (!manifest.requires || typeof manifest.requires !== "object" || Array.isArray(manifest.requires)
        || !Object.keys(manifest.requires).length
        || Object.entries(manifest.requires).some(([id, v]) => !/^[a-z][A-Za-z0-9]*$/.test(id) || !Number.isSafeInteger(v) || v < 1)) {
      throw new Error("API 3 requires the manifest's capability versions");
    }
    requires = Object.fromEntries(Object.entries(manifest.requires).sort(([a], [b]) => a.localeCompare(b)));
  }
  return {
    id: plugin.id, version: manifest.version, tag: `${plugin.tagPrefix}${manifest.version}`,
    packageDirectory: plugin.packageDirectory, pluginAPIVersion: manifest.pluginAPIVersion,
    ...(requires ? { requires } : {}), index: { ...plugin.index, repository }, assets,
  };
}

export function plan(plugins = loadConfig(), exists = tagExists, readManifest = readPackageManifest) {
  return plugins.filter((plugin) => plugin.releaseEnabled !== false)
    .map((plugin) => releaseFor(plugin, readManifest)).filter((release) => !exists(release.tag))
    .map((release) => readManifest === readPackageManifest ? freezeRelease(release.id, "HEAD") : release);
}

function tagRevision(tag) {
  return tagExists(tag) ? git(["rev-parse", `${tag}^{commit}`]) : null;
}

/** Recover drafts even when GitHub has not created their tag yet. Their exact
 * target SHA, rather than today's checkout, owns the frozen release inputs. */
export function planWithDrafts(drafts, plugins = loadConfig(), {
  fresh = () => plan(plugins), freeze = freezeRelease, revisionFor = tagRevision,
} = {}) {
  const recovered = new Map();
  for (const draft of drafts.filter((entry) => entry.draft)) {
    const plugin = plugins.find((entry) => draft.tag_name?.startsWith(entry.tagPrefix));
    if (!plugin || plugin.releaseEnabled === false) continue;
    if (!/^[0-9a-f]{40}$/.test(draft.target_commitish)) throw new Error("Draft target must be an immutable Git revision");
    const release = freeze(plugin.id, draft.target_commitish);
    if (release.tag !== draft.tag_name || release.releaseEnabled === false) throw new Error("Draft identity disagrees with frozen inputs");
    const tagged = revisionFor(release.tag);
    if (tagged && tagged !== release.revision) throw new Error("Draft tag points to another revision");
    if (recovered.has(release.tag)) throw new Error("Duplicate draft release");
    recovered.set(release.tag, release);
  }
  return [...recovered.values(), ...fresh().filter((release) => !recovered.has(release.tag))];
}

/** A public release is immutable. Only a matching draft can receive uploads;
 * verify the entire asset set and bytes before making that draft public. */
export async function publishDraft(release, assets, client) {
  const validate = (draft) => {
    if (!draft?.draft) throw new Error("Refusing to overwrite a published release");
    if (draft.tag_name !== release.tag || draft.target_commitish !== release.revision) throw new Error("Draft identity mismatch");
    const tagged = client.tagRevision(release.tag);
    if (tagged && tagged !== release.revision) throw new Error("Release tag points to another revision");
    if ((draft.assets ?? []).some((asset) => !assets.some((input) => input.name === asset.name))) throw new Error("Unexpected draft asset");
  };
  let draft = await client.find(release.tag);
  if (!draft) {
    const tagged = client.tagRevision(release.tag);
    if (tagged && tagged !== release.revision) throw new Error("Release tag points to another revision");
    await client.create(release);
    draft = await client.find(release.tag);
  }
  validate(draft);
  await client.upload(release.tag, assets);
  draft = await client.find(release.tag);
  validate(draft);
  if (draft.assets.length !== assets.length) throw new Error("Incomplete release asset set");
  for (const asset of assets) {
    const uploaded = draft.assets.filter((entry) => entry.name === asset.name);
    if (uploaded.length !== 1 || await client.digest(release.tag, uploaded[0]) !== asset.sha256) throw new Error(`Uploaded asset bytes differ: ${asset.name}`);
  }
  await client.publish(release.tag);
}

async function fileDigest(path) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest("hex");
}

export async function localReleaseAssets(release, directory) {
  // Recovery tooling may be checked out separately from the frozen builder.
  // gh runs in the tooling repository; asset paths must keep the caller's cwd.
  directory = resolve(directory);
  if (!/^[0-9a-f]{40}$/.test(release.revision)) throw new Error("Expected an immutable release revision");
  if (release.releaseEnabled !== true) throw new Error("Official plugin publication remains disabled");
  const names = release.assets.flatMap((asset) => [asset.assetName, `${asset.assetName}.sha256`]);
  if (release.assets.some((asset) => asset.os === "windows")) names.push("windows-java-release.json");
  if (names.some((name) => !/^[A-Za-z0-9_.-]+$/.test(name)) || new Set(names).size !== names.length) throw new Error("Invalid release asset names");
  const assets = await Promise.all(names.map(async (name) => ({ name, path: join(directory, name), sha256: await fileDigest(join(directory, name)) })));
  for (const asset of release.assets) {
    if (readFileSync(join(directory, `${asset.assetName}.sha256`), "utf8").trim() !== assets.find((entry) => entry.name === asset.assetName).sha256) throw new Error("Local archive checksum mismatch");
  }
  return assets;
}

async function publishFromDirectory(release, directory) {
  const assets = await localReleaseAssets(release, directory);
  const gh = (args) => execFileSync("gh", args, { cwd: root, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 300_000, maxBuffer: 16 * 1024 * 1024 });
  const scratch = mkdtempSync(join(tmpdir(), "lithe-release-verify-"));
  try {
    await publishDraft(release, assets, {
      tagRevision,
      // Listing avoids treating authentication/network failures as a missing release.
      find: (tag) => JSON.parse(gh(["api", "--paginate", "--slurp", "repos/{owner}/{repo}/releases?per_page=100"])).flat().find((entry) => entry.tag_name === tag),
      create: (input) => gh(["release", "create", input.tag, "--draft", "--latest=false", "--target", input.revision,
        "--title", `${input.id} ${input.version}`, "--notes", `Official Lithe plugin ${input.id} ${input.version}. Each architecture has its own archive and SHA-256 file.`]),
      upload: (tag, inputs) => gh(["release", "upload", tag, ...inputs.map((input) => input.path), "--clobber"]),
      digest: async (tag, asset) => {
        if (/^sha256:[0-9a-f]{64}$/.test(asset.digest ?? "")) return asset.digest.slice(7);
        gh(["release", "download", tag, "--pattern", asset.name, "--dir", scratch, "--clobber"]);
        return fileDigest(join(scratch, asset.name));
      },
      publish: (tag) => gh(["release", "edit", tag, "--draft=false", "--latest=false"]),
    });
  } finally { rmSync(scratch, { recursive: true, force: true }); }
}

// Read both configuration and manifest at the immutable release tag, including
// old asset names, API levels, and requires after subsequent plugin upgrades.
export function readTaggedRelease(plugin, tag) {
  return freezeRelease(plugin.id, `refs/tags/${tag}`);
}

/** Freeze exact Git blob bytes. Assembly exports these bytes, never today's checkout. */
export function freezeRelease(id, ref = "HEAD") {
  const revision = git(["rev-parse", "--verify", `${ref}^{commit}`]);
  if (!/^[0-9a-f]{40}$/.test(revision)) throw new Error("Expected an immutable Git revision");
  const read = (path) => git(["show", `${revision}:${path}`], "buffer");
  const config = JSON.parse(read(configFile));
  const plugin = config.plugins.find((entry) => entry.id === id);
  if (!plugin) throw new Error("Unknown official plugin at revision");
  const release = releaseFor(plugin, (directory) => JSON.parse(read(`${directory}/plugin.json`)));
  const paths = [...new Set([configFile, plugin.packageDirectory, ...release.assets.map((asset) => asset.packageDirectory), ...(plugin.inputPaths ?? [])])];
  const inputFiles = {};
  const entries = git(["ls-tree", "-rz", revision, "--", ...paths]).split("\0").filter(Boolean).map((entry) => {
    const [header, path] = entry.split("\t");
    if (!/^(100644|100755) blob [0-9a-f]{40}$/.test(header)) throw new Error("Release inputs must be regular Git files");
    return { path, oid: header.split(" ")[2] };
  });
  const blobs = execFileSync("git", ["cat-file", "--batch"], { cwd: root,
    input: entries.map((entry) => `${entry.oid}\n`).join(""), maxBuffer: 32 * 1024 * 1024, timeout: 30_000 });
  let offset = 0;
  for (const { path, oid } of entries) {
    const end = blobs.indexOf(10, offset);
    const [actualOID, kind, sizeText] = blobs.subarray(offset, end).toString().split(" ");
    const size = Number(sizeText);
    if (actualOID !== oid || kind !== "blob" || !Number.isSafeInteger(size) || size < 0 || end + size + 2 > blobs.length) throw new Error("Invalid Git blob response");
    inputFiles[path] = createHash("sha256").update(blobs.subarray(end + 1, end + 1 + size)).digest("hex");
    offset = end + size + 2;
  }
  for (const path of paths) {
    if (!Object.keys(inputFiles).some((file) => file === path || file.startsWith(`${path}/`))) throw new Error(`Missing release input: ${path}`);
  }
  return { ...release, revision, releaseEnabled: plugin.releaseEnabled !== false, inputFiles,
    assets: release.assets.map((asset) => ({ ...asset, manifestSHA256: inputFiles[`${asset.packageDirectory}/plugin.json`] })) };
}

export function pendingIndex(plugins = loadConfig(), index = readIndex(), tags = tagsWithPrefix, readTagged = readTaggedRelease) {
  const pending = [];
  for (const plugin of plugins) {
    if (plugin.releaseEnabled === false) continue;
    const listed = new Set((index.plugins.find((entry) => entry.id === plugin.id)?.versions ?? []).map((entry) => entry.version));
    for (const tag of tags(plugin.tagPrefix)) {
      const version = tag.slice(plugin.tagPrefix.length);
      if (!versionPattern.test(version) || listed.has(version)) continue;
      const release = readTagged(plugin, tag);
      if (release.tag !== tag || release.version !== version) throw new Error(`${tag} disagrees with its manifest`);
      pending.push(release);
    }
  }
  return pending;
}

function readIndex() { return JSON.parse(readFileSync(indexPath, "utf8")); }

export function check(plugins = loadConfig(), exists = tagExists, changed = changedSince, readManifest = readPackageManifest) {
  const problems = [];
  for (const plugin of plugins) {
    const release = releaseFor(plugin, readManifest);
    if (exists(release.tag) && changed(release.tag, [...new Set([plugin.packageDirectory, ...(plugin.assets ?? []).map((asset) => asset.packageDirectory ?? plugin.packageDirectory), ...(plugin.inputPaths ?? [])])])) {
      problems.push(`${release.id}: release inputs changed since ${release.tag}; bump the version in plugin.json`);
    }
  }
  return problems;
}

/** List all assets atomically; a partial download cannot publish a version. */
export function updateIndex(index, release, { checksums, releaseDate, assetEvidence }) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(releaseDate)) throw new Error("releaseDate must be YYYY-MM-DD");
  if (!checksums || Array.isArray(checksums) || typeof checksums !== "object"
      || Object.keys(checksums).length !== release.assets.length) throw new Error("Expected every release asset checksum");
  const windows = release.assets.filter((asset) => asset.os === "windows");
  if (windows.length) {
    if (!assetEvidence || assetEvidence.kind !== "windows-java-release" || assetEvidence.schemaVersion !== 1
        || assetEvidence.complete !== true || !["package", "verify"].includes(assetEvidence.mode)
        || assetEvidence.publisherVerification !== "verified-existing-signer" || assetEvidence.revision !== release.revision
        || assetEvidence.tag !== release.tag || assetEvidence.pluginId !== release.id || assetEvidence.version !== release.version
        || JSON.stringify(Object.entries(assetEvidence.inputFiles ?? {}).sort()) !== JSON.stringify(Object.entries(release.inputFiles ?? {}).sort())
        || assetEvidence.assets?.length !== windows.length) throw new Error("Expected verified Windows asset evidence for this revision/tag");
    for (const asset of windows) {
      const evidence = assetEvidence.assets.filter((item) => item.assetName === asset.assetName);
      if (evidence.length !== 1 || evidence[0].sha256 !== checksums[asset.assetName]
          || evidence[0].packageDirectory !== asset.packageDirectory || evidence[0].architecture !== asset.arch
          || JSON.stringify(evidence[0].platforms) !== JSON.stringify(asset.platforms)
          || evidence[0].manifestSHA256 !== asset.manifestSHA256
          || evidence[0].pluginAPIVersion !== asset.pluginAPIVersion
          || JSON.stringify(Object.entries(evidence[0].requires ?? {}).sort()) !== JSON.stringify(Object.entries(asset.requires ?? {}).sort())) throw new Error("Windows asset evidence identity mismatch");
    }
  }
  const downloads = release.assets.map((asset) => {
    const sha256 = checksums[asset.assetName];
    if (typeof sha256 !== "string" || !/^[0-9a-f]{64}$/.test(sha256)) throw new Error(`Invalid checksum for ${asset.assetName}`);
    return {
      platforms: [...asset.platforms],
      downloadURL: `${release.index.repository}/releases/download/${release.tag}/${asset.assetName}`,
      sha256,
    };
  });
  const versionEntry = {
    version: release.version, pluginAPIVersion: release.pluginAPIVersion,
    ...(release.requires ? { requires: release.requires } : {}), releaseDate, downloads,
  };
  const plugins = index.plugins.filter((entry) => entry.id !== release.id);
  const existing = index.plugins.find((entry) => entry.id === release.id);
  const versions = (existing?.versions ?? []).filter((entry) => entry.version !== release.version);
  versions.push(versionEntry);
  versions.sort((a, b) => {
    const left = a.version.split(".").map(Number), right = b.version.split(".").map(Number);
    return right[0] - left[0] || right[1] - left[1] || right[2] - left[2];
  });
  plugins.push({ id: release.id, ...release.index, versions });
  plugins.sort((a, b) => a.id.localeCompare(b.id));
  return { schemaVersion: 1, plugins };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [command, ...args] = process.argv.slice(2);
  if (command === "plan") {
    const drafts = args[0] ? JSON.parse(readFileSync(args[0], "utf8")).flat() : [];
    process.stdout.write(`${JSON.stringify(planWithDrafts(drafts))}\n`);
  } else if (command === "publish") {
    await publishFromDirectory(JSON.parse(readFileSync(args[0], "utf8")), args[1]);
  } else if (command === "pending-index") {
    process.stdout.write(`${JSON.stringify(pendingIndex())}\n`);
  } else if (command === "check") {
    const problems = check();
    for (const problem of problems) process.stderr.write(`${problem}\n`);
    process.exitCode = problems.length ? 1 : 0;
  } else if (command === "describe") {
    const plugin = loadConfig().find((entry) => entry.id === args[0]);
    if (!plugin) throw new Error("Unknown official plugin");
    process.stdout.write(`${JSON.stringify(releaseFor(plugin))}\n`);
  } else if (command === "freeze") {
    process.stdout.write(`${JSON.stringify(freezeRelease(args[0], args[1] ?? "HEAD"))}\n`);
  } else if (command === "update-index") {
    const [id, version, checksumsJSON, releaseDate, evidencePath] = args;
    const plugin = loadConfig().find((entry) => entry.id === id);
    if (!plugin || !versionPattern.test(version)) throw new Error("Unknown plugin or invalid version");
    const tag = `${plugin.tagPrefix}${version}`;
    const release = readTaggedRelease(plugin, tag);
    if (release.releaseEnabled === false && release.assets.some((asset) => asset.os === "windows")) throw new Error("Windows release remains disabled");
    if (release.tag !== tag) throw new Error("Release tag disagrees with manifest");
    writeFileSync(indexPath, `${JSON.stringify(updateIndex(readIndex(), release, {
      checksums: JSON.parse(checksumsJSON), releaseDate,
      assetEvidence: evidencePath ? JSON.parse(readFileSync(evidencePath, "utf8")) : undefined,
    }), null, 2)}\n`);
  } else {
    throw new Error("Usage: official-plugin-releases.mjs plan [drafts.json] | publish <plan.json> <asset-directory> | pending-index | check | freeze <id> [revision] | describe <id> | update-index <id> <version> <checksums-json> <YYYY-MM-DD> [verified-evidence.json]");
  }
}
