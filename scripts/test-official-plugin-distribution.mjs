import assert from "node:assert/strict";
import { isBundledOfficialPlugin } from "./official-plugin-distribution.mjs";
assert.equal(isBundledOfficialPlugin("dev.lithe.plugin.go-support"), true);
assert.equal(isBundledOfficialPlugin("dev.lithe.plugin.php-support"), false);
assert.equal(isBundledOfficialPlugin("new.optional.plugin"), false);
console.log("Official plugin distribution checks passed");
