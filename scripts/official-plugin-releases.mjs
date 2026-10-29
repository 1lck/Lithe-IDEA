#!/usr/bin/env node
// Plan immutable official plugin releases and list their exact tagged inputs.
// An index retry must never describe an old archive using today's manifest.
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = join(fileURLToPath(new URL(".", import.meta.url)), "..");
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

function git(args) {
  return execFileSync("git", args, {
    cwd: root, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 30_000,
  }).trim();
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
    if (asset.arch !== undefined && !["arm64", "x86_64", "universal"].includes(asset.arch)) {
      throw new Error("Invalid macOS runtime architecture");
    }
    if (asset.arch && asset.platforms.some((platform) =>
      !({ arm64: ["darwin-arm64"], x86_64: ["darwin-x64"], universal: ["darwin-arm64", "darwin-x64"] }[asset.arch]).includes(platform))) {
      throw new Error("Plugin asset platforms do not match its runtime architecture");
    }
    return { assetName, platforms: [...asset.platforms], ...(asset.arch ? { arch: asset.arch } : {}) };
  });
  if (!assets.length) throw new Error("A release needs assets");
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
    .map((plugin) => releaseFor(plugin, readManifest)).filter((release) => !exists(release.tag));
}

// Read both configuration and manifest at the immutable release tag, including
// old asset names, API levels, and requires after subsequent plugin upgrades.
function readTaggedRelease(plugin, tag) {
  const config = JSON.parse(git(["show", `${tag}:${configFile}`]));
  const tagged = config.plugins.find((entry) => entry.id === plugin.id);
  if (!tagged) throw new Error(`${tag} has no release configuration for ${plugin.id}`);
  return releaseFor(tagged, (directory) => JSON.parse(git(["show", `${tag}:${directory}/plugin.json`])));
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
    if (exists(release.tag) && changed(release.tag, [plugin.packageDirectory, ...(plugin.inputPaths ?? [])])) {
      problems.push(`${release.id}: release inputs changed since ${release.tag}; bump the version in plugin.json`);
    }
  }
  return problems;
}

/** List all assets atomically; a partial download cannot publish a version. */
export function updateIndex(index, release, { checksums, releaseDate }) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(releaseDate)) throw new Error("releaseDate must be YYYY-MM-DD");
  if (!checksums || Array.isArray(checksums) || typeof checksums !== "object"
      || Object.keys(checksums).length !== release.assets.length) throw new Error("Expected every release asset checksum");
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
    process.stdout.write(`${JSON.stringify(plan())}\n`);
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
  } else if (command === "update-index") {
    const [id, version, checksumsJSON, releaseDate] = args;
    const plugin = loadConfig().find((entry) => entry.id === id);
    if (!plugin || !versionPattern.test(version)) throw new Error("Unknown plugin or invalid version");
    const tag = `${plugin.tagPrefix}${version}`;
    const release = readTaggedRelease(plugin, tag);
    if (release.tag !== tag) throw new Error("Release tag disagrees with manifest");
    writeFileSync(indexPath, `${JSON.stringify(updateIndex(readIndex(), release, {
      checksums: JSON.parse(checksumsJSON), releaseDate,
    }), null, 2)}\n`);
  } else {
    throw new Error("Usage: official-plugin-releases.mjs plan | pending-index | check | describe <id> | update-index <id> <version> <checksums-json> <YYYY-MM-DD>");
  }
}
