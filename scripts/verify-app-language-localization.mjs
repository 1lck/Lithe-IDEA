#!/usr/bin/env node
// Product copy built outside a SwiftUI `Text` must go through `L10n.string` (LitheModuleAPI).
// Direct `String(localized:)` / `NSLocalizedString` pick the `.lproj` from the system language
// unless given a bundle, so they are rejected unless the caller injects its own bundle
// (any `bundle:` other than `.main` / `.appLanguage`, for example a test or Agent language bundle).
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";

const root = new URL("..", import.meta.url).pathname;
const sourceRoot = join(root, "macos/Sources");

// Returns the index just past the string literal that starts at `i`, skipping `\( … )` interpolation.
function skipString(s, i) {
  const triple = s.startsWith('"""', i);
  i += triple ? 3 : 1;
  while (i < s.length) {
    if (s[i] === "\\") {
      i = s[i + 1] === "(" ? findClose(s, i + 2) + 1 : i + 2;
    } else if (triple ? s.startsWith('"""', i) : s[i] === '"') {
      return i + (triple ? 3 : 1);
    } else i += 1;
  }
  throw new Error("unterminated string literal");
}

// Returns the index of the `)` matching an already-consumed `(`.
function findClose(s, i) {
  let depth = 1;
  while (i < s.length) {
    if (s[i] === '"') { i = skipString(s, i); continue; }
    if (s[i] === "(") depth += 1;
    else if (s[i] === ")" && --depth === 0) return i;
    i += 1;
  }
  throw new Error("unbalanced parentheses");
}

// Value of the `bundle:` argument, or null when absent.
function bundleArgument(body) {
  let depth = 0, start = 0, found = null;
  const take = (end) => {
    const m = /^\s*bundle\s*:\s*([\s\S]*?)\s*$/.exec(body.slice(start, end));
    if (m) found = m[1];
  };
  for (let i = 0; i < body.length; i += 1) {
    const c = body[i];
    if (c === '"') { i = skipString(body, i) - 1; continue; }
    if ("([{".includes(c)) depth += 1;
    else if (")]}".includes(c)) depth -= 1;
    else if (c === "," && depth === 0) { take(i); start = i + 1; }
  }
  take(body.length);
  return found;
}

function swiftFiles(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) =>
    e.isDirectory() ? swiftFiles(join(dir, e.name)) : e.name.endsWith(".swift") ? [join(dir, e.name)] : []);
}

const violations = [];
for (const file of swiftFiles(sourceRoot)) {
  if (file.endsWith("Localization/InterfaceLanguage.swift")) continue; // the L10n implementation itself
  const text = readFileSync(file, "utf8");
  for (const m of text.matchAll(/(?<![\w.])(String\(localized:|NSLocalizedString\()/g)) {
    // Skip mentions in comments.
    const lineStart = text.lastIndexOf("\n", m.index) + 1;
    if (/^\s*\/\//.test(text.slice(lineStart, m.index))) continue;
    const open = text.indexOf("(", m.index);
    const body = text.slice(open + 1, findClose(text, open + 1));
    const bundle = bundleArgument(body);
    if (bundle === null || bundle === ".main" || bundle === ".appLanguage") {
      const line = text.slice(0, m.index).split("\n").length;
      violations.push(`${relative(root, file)}:${line}`);
    }
  }
}


// Every literal key must exist in the table generated from shared/i18n, otherwise the call
// silently falls back to English. Interpolations match any single format specifier.
const tablePath = join(root, "macos/Resources/zh-Hans.lproj/Localizable.strings");
const unescape = (v) => v.replace(/\\(["n\\])/g, (_, c) => (c === "n" ? "\n" : c));
const tableKeys = new Set(
  existsSync(tablePath)
    ? [...readFileSync(tablePath, "utf8").matchAll(/^"((?:[^"\\]|\\.)*)"\s*=/gm)].map((m) => unescape(m[1]))
    : []);
// Literals in these files are developer diagnostics (module and plugin-manifest registry
// consistency checks), not interface copy.
const diagnosticFiles = ["ModuleContracts.swift", "PluginManifestValidator.swift", "ModuleCapabilityStore.swift", "WorkbenchModuleUIRegistry.swift"];
// SwiftUI initializers and modifiers whose first string literal becomes a LocalizedStringKey.
const viewTextPattern = /(?<![\w.])(?:Text|Button|Label|Toggle|Section|TextField|SecureField|GroupBox|DisclosureGroup)\("|\.(?:help|navigationTitle|accessibilityLabel|accessibilityHint|accessibilityValue|prompt)\("/g;
// Language-neutral literals (product names, sample values, patterns) that need no translation.
const neutralLiterals = new Set(["Markdown", "localhost", "GitHub", "main", "Esc", "*.java", "feature/my-change", "project-name",
  "https://github.com/example/project.git", "~/Projects",
  "Lithe \\(updateInfo.currentVersion) → \\(updateInfo.targetVersion)", "Lithe \\(memoryUsageMonitor.litheText)"]);
const specifier = "(?:%@|%lld|%llu|%d|%ld|%lu|%f)";
const escapeRegex = (v) => v.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

for (const file of swiftFiles(sourceRoot)) {
  if (file.endsWith("Localization/InterfaceLanguage.swift")) continue;
  const text = readFileSync(file, "utf8");
  const where = (index) => `${relative(root, file)}:${text.slice(0, index).split("\n").length}`;

  for (const m of text.matchAll(/L10n\.string\(\s*"/g)) {
    const start = m.index + m[0].length - 1;
    const end = skipString(text, start);
    const raw = text.slice(start + 1, end - 1);
    const parts = []; // literal text between interpolations
    let last = 0;
    for (let i = 0; i < raw.length; i += 1) {
      if (raw[i] === "\\" && raw[i + 1] === "(") {
        parts.push(raw.slice(last, i));
        i = findClose(raw, i + 2);
        last = i + 1;
      } else if (raw[i] === "\\") i += 1;
    }
    parts.push(raw.slice(last));
    const pattern = new RegExp(`^${parts.map((p) => escapeRegex(unescape(p))).join(specifier)}$`);
    if (!parts.some((p) => /[A-Za-z]{2}/.test(p))) continue;
    if (parts.length === 1 ? !tableKeys.has(unescape(parts[0])) : ![...tableKeys].some((k) => pattern.test(k))) {
      violations.push(`${where(m.index)} (key missing from shared/i18n)`);
    }
  }

  // SwiftUI text literals are looked up as localization keys; a key missing from the table
  // shows English in every language.
  for (const m of text.matchAll(viewTextPattern)) {
    const start = m.index + m[0].length - 1;
    const raw = text.slice(start + 1, skipString(text, start) - 1);
    const parts = [];
    let last = 0;
    for (let i = 0; i < raw.length; i += 1) {
      if (raw[i] === "\\" && raw[i + 1] === "(") {
        parts.push(raw.slice(last, i));
        i = findClose(raw, i + 2);
        last = i + 1;
      } else if (raw[i] === "\\") i += 1;
    }
    parts.push(raw.slice(last));
    const words = parts.join(" ");
    if (!/[A-Za-z]{3}/.test(words) || neutralLiterals.has(raw)) continue;
    // SwiftUI doubles a literal `%` in the key only when the literal also interpolates values.
    const keyParts = parts.map((p) => (parts.length > 1 ? unescape(p).replaceAll("%", "%%") : unescape(p)));
    const pattern = new RegExp(`^${keyParts.map(escapeRegex).join(specifier)}$`);
    const known = parts.length === 1 ? tableKeys.has(keyParts[0]) : [...tableKeys].some((k) => pattern.test(k));
    if (!known) violations.push(`${where(m.index)} (view text "${raw.slice(0, 40)}" missing from shared/i18n)`);
  }

  if (diagnosticFiles.some((f) => file.endsWith(f))) continue;
  // User-facing sinks that must not hold a bare English literal.
  const sinks = [
    /(?:messageText|informativeText)\s*=\s*"/g,
    /addButton\(withTitle:\s*"/g,
    /NSLocalizedDescriptionKey:\s*"/g,
  ];
  for (const sink of sinks) {
    for (const m of text.matchAll(sink)) {
      const literal = text.slice(m.index + m[0].length - 1, skipString(text, m.index + m[0].length - 1));
      if (/[A-Za-z]{3}/.test(literal)) violations.push(`${where(m.index)} (bare literal; use L10n.string)`);
    }
  }
  for (const m of text.matchAll(/var errorDescription: String\? \{/g)) {
    let depth = 1, i = m.index + m[0].length;
    while (depth > 0) {
      if (text[i] === '"') { i = skipString(text, i); continue; }
      if (text[i] === "{") depth += 1;
      else if (text[i] === "}") depth -= 1;
      i += 1;
    }
    const body = text.slice(m.index + m[0].length, i - 1);
    for (let j = 0; j < body.length; j += 1) {
      if (body[j] === "/" && body[j + 1] === "/") { j = body.indexOf("\n", j); if (j < 0) break; continue; }
      if (body[j] !== '"') continue;
      const end = skipString(body, j);
      const literal = body.slice(j, end);
      const before = body.slice(Math.max(0, j - 16), j);
      if (!/L10n\.string\(\s*$/.test(before) && /[A-Za-z]{3}/.test(literal.replace(/\\\(.*\)/g, ""))) {
        violations.push(`${where(m.index)} (errorDescription literal; use L10n.string)`);
        break;
      }
      j = end - 1;
    }
  }
}

if (violations.length > 0) {
  console.error("Localization violations (use `L10n.string(...)` with a key defined in shared/i18n):");
  for (const v of violations) console.error(`  ${v}`);
  process.exit(1);
}
console.log("App-language localization check passed.");
