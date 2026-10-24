#!/usr/bin/env node
// A package must opt into the base application; all other official plugins
// remain separately buildable and installable through plugin management.
// Go Support and PHP Support moved to community plugins in Lithe Store. Java
// Support ships inside Lithe.app so Java works offline on first launch; its
// manifest uses `sameTeamAsHost`, and the user can remove and restore it in
// plugin management.
import { pathToFileURL } from "node:url";
const bundledOfficialPluginIDs = new Set(["dev.lithe.plugin.java-support"]);
export function isBundledOfficialPlugin(id) {
  return bundledOfficialPluginIDs.has(id);
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = isBundledOfficialPlugin(process.argv[2]) ? 0 : 1;
}
