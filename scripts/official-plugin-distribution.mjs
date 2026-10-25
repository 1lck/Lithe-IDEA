#!/usr/bin/env node
// Keep a transition copy until the checked-in official index offers a complete,
// compatible release. The decision is made at build time, never at app startup.
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { loadConfig, releaseFor } from "./official-plugin-releases.mjs";

export const defaultIndexPath = new URL("../Plugins/marketplace/index.json", import.meta.url);
export function readDistributionIndex(path = defaultIndexPath) {
  const index = JSON.parse(readFileSync(path, "utf8"));
  if (index.schemaVersion !== 1 || !Array.isArray(index.plugins)) throw new Error("Invalid official plugin index");
  return index;
}
const canonical = (value) => JSON.stringify(Object.entries(value ?? {}).sort(([a], [b]) => a.localeCompare(b)));
const versionParts = (value) => /^\d+\.\d+\.\d+$/.test(value ?? "") ? value.split(".").map(Number) : null;

export function isBundledOfficialPlugin(id, index = readDistributionIndex(), config = loadConfig()) {
  const plugin = config.find((entry) => entry.id === id);
  if (!plugin?.bundledUntilPublishedVersion) return false;
  const minimum = versionParts(plugin.bundledUntilPublishedVersion);
  if (!minimum) throw new Error("Invalid bundledUntilPublishedVersion");
  const current = releaseFor(plugin);
  const published = index.plugins.find((entry) => entry.id === id);
  if (published?.repository !== current.index.repository) return true;
  return !published.versions?.some((version) => {
    const parts = versionParts(version.version);
    if (!parts) return false;
    const comparison = parts[0] - minimum[0] || parts[1] - minimum[1] || parts[2] - minimum[2];
    if (comparison < 0 || version.pluginAPIVersion !== current.pluginAPIVersion
        || canonical(version.requires) !== canonical(current.requires)) return false;
    const assets = plugin.assets;
    // Exactly one download per configured asset, with no ambiguous platform.
    if (!Array.isArray(version.downloads) || version.downloads.length !== assets.length) return false;
    return assets.every((asset) => version.downloads.filter((download) =>
      JSON.stringify(download.platforms?.slice().sort()) === JSON.stringify(asset.platforms.slice().sort())
      && /^[0-9a-f]{64}$/.test(download.sha256 ?? "")
      && download.downloadURL === `${current.index.repository}/releases/download/${plugin.tagPrefix}${version.version}/${asset.assetName.replaceAll("{version}", version.version)}`
    ).length === 1);
  });
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  // Print a boolean so callers propagate malformed/missing input as a build
  // failure instead of interpreting an exception's exit code as "omit".
  const index = readDistributionIndex(process.argv[3]);
  process.stdout.write(`${isBundledOfficialPlugin(process.argv[2], index)}\n`);
}
