#!/usr/bin/env node

import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const sourceRoots = [
  "rust/lithe-core/src",
  "macos/Sources",
  "windows/tauri/src",
];
const forbidden = [
  "is_main_method",
  "main_declaration_index",
  "main_class_exists",
  "containsJavaMainMethod",
  "java.runConfigurations",
  "java.testMethods",
];
const extensions = new Set([".rs", ".swift", ".ts", ".tsx"]);
const violations = [];

function visit(relative) {
  const absolute = path.join(root, relative);
  const stat = statSync(absolute);
  if (stat.isDirectory()) {
    for (const name of readdirSync(absolute).sort()) visit(path.join(relative, name));
    return;
  }
  if (!extensions.has(path.extname(relative))) return;
  const lines = readFileSync(absolute, "utf8").split(/\r?\n/);
  lines.forEach((line, index) => {
    for (const token of forbidden) {
      if (line.includes(token)) violations.push(`${relative}:${index + 1}: ${token}`);
    }
  });
}

sourceRoots.forEach(visit);
if (violations.length > 0) {
  console.error("Java semantic ownership violations: JDT must remain the only entry/test authority.");
  violations.forEach((violation) => console.error(violation));
  process.exit(1);
}
console.log("Java semantic ownership verified: no retired local entry/test scanners remain.");
