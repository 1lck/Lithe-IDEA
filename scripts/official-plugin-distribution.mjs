#!/usr/bin/env node
// A package must opt into the base application; all other official plugins
// remain separately buildable and installable through plugin management.
import { pathToFileURL } from "node:url";
export function isBundledOfficialPlugin(id) {
  return id === "dev.lithe.plugin.go-support";
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = isBundledOfficialPlugin(process.argv[2]) ? 0 : 1;
}
