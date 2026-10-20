#!/usr/bin/env node
// Plans and records official plugin releases. Each official downloadable
// plugin has its own tag series (`<tagPrefix><version>`); a tag is created
// only when the plugin's package directory changed and its plugin.json
// declares a version that has no tag yet. See
// .agents/notes/implemented/feature/2026-10-12-plugin-marketplace.md.
//
//   plan                       JSON list of plugins whose version is untagged
//   pending-index              JSON list of tagged versions missing from
//                              index.json; publishing and listing are separate
//                              steps, so a failed listing is retried from here
//   check                      fail when a tagged version's directory changed
//   update-index <id> <version> <sha256> <releaseDate>
//                              add the released archive to the official index
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = join(fileURLToPath(new URL(".", import.meta.url)), "..");
const configPath = join(root, "Plugins/marketplace/official-plugins.json");
const indexPath = join(root, "Plugins/marketplace/index.json");

export function loadConfig(path = configPath) {
  const config = JSON.parse(readFileSync(path, "utf8"));
  if (config.schemaVersion !== 1) throw new Error("official-plugins.json must use schemaVersion 1");
  return config.plugins;
}

function git(args, options = {}) {
  return execFileSync("git", args, { cwd: root, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], ...options }).trim();
}

function tagExists(tag) {
  try {
    git(["rev-parse", "--verify", "--quiet", `refs/tags/${tag}`]);
    return true;
  } catch {
    return false;
  }
}

function tagsWithPrefix(prefix) {
  const output = git(["tag", "--list", `${prefix}*`]);
  return output ? output.split("\n") : [];
}

function directoryChangedSince(tag, directory) {
  try {
    git(["diff", "--quiet", tag, "HEAD", "--", directory]);
    return false;
  } catch {
    return true;
  }
}

function readPackageManifest(directory) {
  return JSON.parse(readFileSync(join(root, directory, "plugin.json"), "utf8"));
}

export function releaseFor(plugin, readManifest = readPackageManifest) {
  const manifest = readManifest(plugin.packageDirectory);
  if (manifest.id !== plugin.id) {
    throw new Error(`${plugin.packageDirectory}/plugin.json has id ${manifest.id}, expected ${plugin.id}`);
  }
  if (!/^\d+\.\d+\.\d+$/.test(manifest.version)) {
    throw new Error(`${plugin.id} version must be major.minor.patch`);
  }
  const version = manifest.version;
  return {
    id: plugin.id,
    version,
    tag: `${plugin.tagPrefix}${version}`,
    assetName: plugin.assetName.replace("{version}", version),
    packageDirectory: plugin.packageDirectory,
  };
}

/** Plugins whose current version has no tag yet. */
export function plan(plugins = loadConfig(), exists = tagExists, readManifest = readPackageManifest) {
  return plugins.map((plugin) => releaseFor(plugin, readManifest)).filter((release) => !exists(release.tag));
}

/** Released (tagged) versions that the official index does not list yet.
 *  Every tag of each series is considered, so a version whose listing
 *  failed is still picked up after the plugin has moved on. */
export function pendingIndex(plugins = loadConfig(), index = readIndex(), tags = tagsWithPrefix) {
  const pending = [];
  for (const plugin of plugins) {
    const listed = new Set(
      (index.plugins.find((entry) => entry.id === plugin.id)?.versions ?? []).map((entry) => entry.version),
    );
    for (const tag of tags(plugin.tagPrefix)) {
      const version = tag.slice(plugin.tagPrefix.length);
      if (!/^\d+\.\d+\.\d+$/.test(version) || listed.has(version)) continue;
      pending.push({
        id: plugin.id,
        version,
        tag,
        assetName: plugin.assetName.replace("{version}", version),
      });
    }
  }
  return pending;
}

function readIndex() {
  return JSON.parse(readFileSync(indexPath, "utf8"));
}

/** Changing a released plugin without a new version would ship two
 *  different packages under one version, so it is an error. */
export function check(
  plugins = loadConfig(),
  exists = tagExists,
  changed = directoryChangedSince,
  readManifest = readPackageManifest,
) {
  const problems = [];
  for (const plugin of plugins) {
    const release = releaseFor(plugin, readManifest);
    if (exists(release.tag) && changed(release.tag, release.packageDirectory)) {
      problems.push(`${release.id}: ${release.packageDirectory} changed since ${release.tag}; bump the version in plugin.json`);
    }
  }
  return problems;
}

/** Inserts the released archive, keeping versions newest first. */
export function updateIndex(index, plugin, { version, sha256, releaseDate }) {
  if (!/^[0-9a-f]{64}$/.test(sha256)) throw new Error("sha256 must be 64 lowercase hex characters");
  if (!/^\d{4}-\d{2}-\d{2}$/.test(releaseDate)) throw new Error("releaseDate must be YYYY-MM-DD");
  const repository = plugin.index.repository.replace(/\/$/, "");
  const tag = `${plugin.tagPrefix}${version}`;
  const versionEntry = {
    version,
    pluginAPIVersion: 1,
    releaseDate,
    downloads: [{
      platforms: plugin.platforms,
      downloadURL: `${repository}/releases/download/${tag}/${plugin.assetName.replace("{version}", version)}`,
      sha256,
    }],
  };
  const plugins = index.plugins.filter((entry) => entry.id !== plugin.id);
  const existing = index.plugins.find((entry) => entry.id === plugin.id);
  const versions = (existing?.versions ?? []).filter((entry) => entry.version !== version);
  versions.push(versionEntry);
  const numeric = (value) => value.split(".").map(Number);
  versions.sort((left, right) => {
    const [a, b] = [numeric(left.version), numeric(right.version)];
    return b[0] - a[0] || b[1] - a[1] || b[2] - a[2];
  });
  plugins.push({ id: plugin.id, ...plugin.index, versions });
  plugins.sort((left, right) => left.id.localeCompare(right.id));
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
    for (const problem of problems) console.error(problem);
    process.exitCode = problems.length ? 1 : 0;
  } else if (command === "update-index") {
    const [id, version, sha256, releaseDate] = args;
    const plugin = loadConfig().find((entry) => entry.id === id);
    if (!plugin) throw new Error(`${id} is not an official released plugin`);
    const index = readIndex();
    writeFileSync(indexPath, `${JSON.stringify(updateIndex(index, plugin, { version, sha256, releaseDate }), null, 2)}\n`);
  } else {
    console.error("Usage: official-plugin-releases.mjs plan | pending-index | check | update-index <id> <version> <sha256> <YYYY-MM-DD>");
    process.exitCode = 2;
  }
}
