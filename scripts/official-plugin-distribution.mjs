#!/usr/bin/env node
// A package must opt into the base application; all other official plugins
// remain separately buildable and installable through plugin management.
// Go Support and PHP Support are both downloaded from the plugin marketplace,
// so no official plugin is bundled today; add an ID here to ship one inside
// Lithe.app (its manifest must then use `sameTeamAsHost`).
import { pathToFileURL } from "node:url";
const bundledOfficialPluginIDs = new Set();
export function isBundledOfficialPlugin(id) {
  return bundledOfficialPluginIDs.has(id);
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = isBundledOfficialPlugin(process.argv[2]) ? 0 : 1;
}
