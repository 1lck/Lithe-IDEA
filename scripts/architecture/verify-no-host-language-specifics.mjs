#!/usr/bin/env node

// Host code must not name specific languages or build tools: that knowledge
// belongs to plugins. Until the Java extraction (#1495) finishes, a per-file
// baseline only allows counts to go down; `--strict` is the final mode.
// Note: .agents/notes/proposed/architecture/2026-11-04-java-extraction-generic-apis-and-gate.md

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export const SCAN_ROOTS = Object.freeze([
  "rust/lithe-core/src",
  // Synchronous rules shared with the Windows frontend through wasm; still host Core code.
  "rust/lithe-core-rules/src",
  "macos/Sources",
  "frontend/editor/src",
  "shared/contracts/plugins/v1",
  "windows/tauri/src",
  "windows/tauri/src-tauri/src",
]);

export const BASELINE_PATH = "scripts/architecture/language-specifics-baseline.json";
export const ALLOWLIST_PATH = "scripts/architecture/language-specifics-allowlist.json";

// Matched against whole words after identifiers and strings are split on
// camelCase, snake_case, digits, ".", "/" and "-".
export const WORDS = Object.freeze(new Set([
  "java", "jdt", "jdtls", "jvm", "maven", "mvn", "gradle", "spring",
  "mybatis", "lombok", "junit", "testng", "m2e", "surefire",
]));
// Compound words that contain a listed word but name something else.
const NEUTRAL_WORDS = new Set(["javascript"]);
// A Rust string table naming any of these is a closed list of tools.
const TOOL_TABLE_NAMES = new Set([...WORDS, "node", "go", "python"]);

// Retired Java entry/test scanners; they fail in every mode.
export const LEGACY_TOKENS = Object.freeze([
  "is_main_method",
  "main_declaration_index",
  "main_class_exists",
  "containsJavaMainMethod",
  "java.runConfigurations",
  "java.testMethods",
]);

const CODE_EXTENSIONS = new Set([".rs", ".swift", ".ts", ".tsx", ".js", ".mjs", ".cjs"]);
const TEXT_EXTENSIONS = new Set([...CODE_EXTENSIONS, ".json", ".md", ".html", ".css"]);
const SKIPPED_DIRECTORIES = new Set(["vendor", "node_modules"]);
const CATEGORIES = Object.freeze(["words", "nameComparisons", "toolTables", "schemaEnums"]);
const ALLOWLIST_KEYS = Object.freeze(["glob", "reason", "issue", "removeWhen"]);
const ISSUE_PATTERN = /^#\d+$/;

// ---------------------------------------------------------------------------
// Tokenizing

const WORD_PART = /[A-Z]+(?![a-z])|[A-Z]?[a-z]+|[0-9]+/g;

/** Returns every listed word in `text`, in order of appearance. */
export function listedWords(text) {
  const hits = [];
  for (const run of text.matchAll(/[A-Za-z0-9]+/g)) {
    const parts = run[0].match(WORD_PART) ?? [];
    let index = 0;
    while (index < parts.length) {
      // Brand names keep their internal capitals (JUnit, MyBatis, TestNG,
      // JavaScript) and m2e keeps its digit, so rejoin up to three parts.
      let width = 1;
      let word = parts[index].toLowerCase();
      for (const candidate of [3, 2]) {
        if (index + candidate > parts.length) continue;
        const joined = parts.slice(index, index + candidate).join("").toLowerCase();
        if (WORDS.has(joined) || NEUTRAL_WORDS.has(joined)) {
          width = candidate;
          word = joined;
          break;
        }
      }
      if (WORDS.has(word)) hits.push(word);
      index += width;
    }
  }
  return hits;
}

// ---------------------------------------------------------------------------
// Comment removal: words in comments do not couple code to a language, so
// only identifiers and string literals of source files are counted.

function languageOf(file) {
  const extension = path.extname(file);
  if (extension === ".rs") return "rust";
  if (extension === ".swift") return "swift";
  if (CODE_EXTENSIONS.has(extension)) return "script";
  return null;
}

const REGEX_PRECEDERS = new Set(["", "(", ",", "=", ":", "[", "!", "&", "|", "?", "{", "}", ";", "+", "-", "*", "%", "<", ">", "~", "^"]);
// Keywords after which `/` starts a regular expression, not a division.
const REGEX_KEYWORDS = new Set(["return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw", "case", "do", "else", "yield", "await"]);

// True when `/` at `index` follows one of REGEX_KEYWORDS used as a keyword,
// that is, not as a property name such as `options.in`.
function followsRegexKeyword(text, index) {
  let end = index;
  while (end > 0 && /\s/.test(text[end - 1])) end -= 1;
  let start = end;
  while (start > 0 && /[A-Za-z0-9_$]/.test(text[start - 1])) start -= 1;
  return text[start - 1] !== "." && REGEX_KEYWORDS.has(text.slice(start, end));
}

/**
 * Replaces comments with spaces and keeps strings, so line numbers and string
 * contents survive. The lexer is approximate; it only has to be deterministic.
 */
export function stripComments(text, language) {
  const output = [];
  const length = text.length;
  let index = 0;
  let lastSignificant = "";
  const blank = (from, to) => {
    for (let position = from; position < to; position += 1) output.push(text[position] === "\n" ? "\n" : " ");
  };
  const copy = (from, to) => {
    output.push(text.slice(from, to));
  };
  // Returns the index after a quoted literal starting at `start`.
  const quoted = (start, quote, multiline) => {
    let position = start + 1;
    while (position < length) {
      const character = text[position];
      if (character === "\\") { position += 2; continue; }
      if (character === quote) return position + 1;
      if (character === "\n" && !multiline) return position;
      position += 1;
    }
    return length;
  };
  while (index < length) {
    const character = text[index];
    const next = text[index + 1];
    if (character === "/" && next === "/") {
      const end = text.indexOf("\n", index);
      const stop = end === -1 ? length : end;
      blank(index, stop);
      index = stop;
      continue;
    }
    if (character === "/" && next === "*") {
      const nested = language === "rust" || language === "swift";
      let depth = 1;
      let position = index + 2;
      while (position < length && depth > 0) {
        if (nested && text[position] === "/" && text[position + 1] === "*") { depth += 1; position += 2; continue; }
        if (text[position] === "*" && text[position + 1] === "/") { depth -= 1; position += 2; continue; }
        position += 1;
      }
      blank(index, position);
      index = position;
      continue;
    }
    if (language === "rust" && (character === "r" || (character === "b" && next === "r"))) {
      const raw = /^b?r(#*)"/.exec(text.slice(index, index + 260));
      if (raw && !/[A-Za-z0-9_]/.test(text[index - 1] ?? "")) {
        const terminator = `"${raw[1]}`;
        const end = text.indexOf(terminator, index + raw[0].length);
        const stop = end === -1 ? length : end + terminator.length;
        copy(index, stop);
        index = stop;
        lastSignificant = "\"";
        continue;
      }
    }
    if (language === "swift" && (character === "#" || character === "\"")) {
      const opener = /^(#*)("""|")/.exec(text.slice(index, index + 260));
      if (opener && (opener[1].length > 0 || character === "\"")) {
        const terminator = `${opener[2]}${opener[1]}`;
        let stop;
        if (opener[1].length === 0 && opener[2] === "\"") {
          stop = quoted(index, "\"", false);
        } else {
          const end = text.indexOf(terminator, index + opener[0].length);
          stop = end === -1 ? length : end + terminator.length;
        }
        copy(index, stop);
        index = stop;
        lastSignificant = "\"";
        continue;
      }
    }
    if (character === "\"") {
      const stop = quoted(index, "\"", language === "rust");
      copy(index, stop);
      index = stop;
      lastSignificant = "\"";
      continue;
    }
    if (character === "'") {
      if (language === "rust") {
        // Character literal; otherwise a lifetime or label.
        const literal = /^'(?:\\u\{[0-9A-Fa-f]+\}|\\.|[^'\\\n])'/.exec(text.slice(index, index + 16));
        const stop = literal ? index + literal[0].length : index + 1;
        copy(index, stop);
        index = stop;
        lastSignificant = "'";
        continue;
      }
      if (language === "script") {
        const stop = quoted(index, "'", false);
        copy(index, stop);
        index = stop;
        lastSignificant = "'";
        continue;
      }
    }
    if (character === "`" && language === "script") {
      const stop = quoted(index, "`", true);
      copy(index, stop);
      index = stop;
      lastSignificant = "`";
      continue;
    }
    if (character === "/" && language === "script" && (REGEX_PRECEDERS.has(lastSignificant) || (lastSignificant === "a" && followsRegexKeyword(text, index)))) {
      // Regular expression literal: skip it so quotes inside are not strings.
      let position = index + 1;
      let inClass = false;
      while (position < length && text[position] !== "\n") {
        const current = text[position];
        if (current === "\\") { position += 2; continue; }
        if (current === "[") inClass = true;
        else if (current === "]") inClass = false;
        else if (current === "/" && !inClass) { position += 1; break; }
        position += 1;
      }
      copy(index, position);
      index = position;
      lastSignificant = "/";
      continue;
    }
    output.push(character);
    if (!/\s/.test(character)) {
      lastSignificant = /[A-Za-z0-9_$)\].]/.test(character) ? "a" : character;
    }
    index += 1;
  }
  return output.join("");
}

// ---------------------------------------------------------------------------
// Structural rules

const DOUBLE = String.raw`"((?:\\.|[^"\\\n])*)"`;
const SINGLE = String.raw`'((?:\\.|[^'\\\n])*)'`;
const BACKTICK = String.raw`\x60((?:\\.|[^\x60\\\n])*)\x60`;

function literalPattern(language) {
  if (language === "script") return `(?:${DOUBLE}|${SINGLE}|${BACKTICK})`;
  return `(?:${DOUBLE})`;
}

function comparisonPatterns(language) {
  const literal = literalPattern(language);
  const patterns = [
    new RegExp(String.raw`(?:===?|!==?)\s*${literal}`, "g"),
    new RegExp(String.raw`${literal}\s*(?:===?|!==?)`, "g"),
  ];
  if (language === "rust") {
    // Match arms are read one line at a time. `\s` would let `^\s*` run
    // across the blank lines left by removed comments and backtrack
    // quadratically on large files.
    const arm = String.raw`(?:Some\([ \t]*)?${literal}[ \t]*\)?`;
    patterns.push(new RegExp(String.raw`^[ \t]*(?:\|[ \t]*)?${arm}(?:[ \t]*\|[ \t]*${arm})*[ \t]*(?:if\b[^\n]*)?=>`, "gm"));
    patterns.push(new RegExp(String.raw`\beq_ignore_ascii_case\(\s*${literal}`, "g"));
    patterns.push(new RegExp(String.raw`\bmatches!\s*\([^,\n]*,\s*${literal}(?:\s*\|\s*${literal})*`, "g"));
  } else {
    patterns.push(new RegExp(String.raw`\bcase\s+\.?${literal}(?:\s*,\s*${literal})*\s*:`, "g"));
  }
  return patterns;
}

const comparisonCache = new Map();

/** Counts comparisons of a value with a literal that names a listed word. */
export function nameComparisons(code, language) {
  if (!comparisonCache.has(language)) {
    comparisonCache.set(language, {
      patterns: comparisonPatterns(language),
      // A repeated group only captures its last repetition, so the literals
      // of `"a" | "b" | "c" =>` are read again from the whole match.
      literals: new RegExp(literalPattern(language), "g"),
    });
  }
  const { patterns, literals } = comparisonCache.get(language);
  let count = 0;
  for (const pattern of patterns) {
    for (const match of code.matchAll(pattern)) {
      const values = [...match[0].matchAll(literals)].flatMap((literal) => literal.slice(1).filter((value) => value !== undefined));
      if (values.some((value) => listedWords(value).length > 0)) count += 1;
    }
  }
  return count;
}

const RUST_STRING_TABLE = /\b(?:const|static)\s+[A-Za-z_][A-Za-z0-9_]*\s*:\s*&?\s*(?:'static\s+)?\[\s*&\s*(?:'static\s+)?str\s*(?:;\s*[^\]]+)?\]\s*=\s*&?\s*\[([^\]]*)\]\s*;/g;

/**
 * Counts the entries of Rust string tables that list a language or tool name.
 * Every entry counts, so adding a tool to an existing table raises the count.
 */
export function toolTables(code) {
  let count = 0;
  for (const match of code.matchAll(RUST_STRING_TABLE)) {
    const values = [...match[1].matchAll(/"((?:\\.|[^"\\])*)"/g)].map((value) => value[1]);
    if (values.some((value) => TOOL_TABLE_NAMES.has(value.toLowerCase()) || listedWords(value).length > 0)) count += values.length;
  }
  return count;
}

/** Counts the values that `enum` and `const` close, including nested alternatives. */
function closedValues(schema) {
  if (Array.isArray(schema)) return schema.reduce((sum, item) => sum + closedValues(item), 0);
  if (!schema || typeof schema !== "object") return 0;
  let count = Array.isArray(schema.enum) ? schema.enum.length : Object.hasOwn(schema, "const") ? 1 : 0;
  for (const key of ["items", "oneOf", "anyOf", "allOf"]) count += closedValues(schema[key]);
  return count;
}

/**
 * Counts the closed values of schema fields that name tools, runtimes, or
 * build imports, so adding a member to an existing enum raises the count. A
 * `hostIntegration` field counts its integration names (an object form names
 * them in `id`) and at least one, because the field itself names a host-built
 * integration.
 */
export function schemaEnums(schema) {
  let count = 0;
  const visit = (node, parentProperty) => {
    if (Array.isArray(node)) { node.forEach((item) => visit(item, parentProperty)); return; }
    if (!node || typeof node !== "object") return;
    if (node.properties && typeof node.properties === "object" && !Array.isArray(node.properties)) {
      for (const [name, property] of Object.entries(node.properties)) {
        if (name === "hostIntegration") count += Math.max(1, closedValues(property) + closedValues(property?.properties?.id));
        else if (name === "tool" || name === "runtime") count += closedValues(property);
        else if (name === "kind" && parentProperty === "languageImport") count += closedValues(property);
      }
    }
    for (const [key, value] of Object.entries(node)) {
      if (key === "properties" && value && typeof value === "object" && !Array.isArray(value)) {
        for (const [name, property] of Object.entries(value)) visit(property, name);
      } else {
        visit(value, parentProperty);
      }
    }
  };
  visit(schema, null);
  return count;
}

// ---------------------------------------------------------------------------
// Scanning

function listFiles(root) {
  const files = [];
  const walk = (relative) => {
    const absolute = path.join(root, relative);
    if (!existsSync(absolute)) return;
    for (const entry of readdirSync(absolute, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const child = `${relative}/${entry.name}`;
      if (entry.isDirectory()) {
        if (SKIPPED_DIRECTORIES.has(entry.name) || entry.name.startsWith(".")) continue;
        walk(child);
      } else if (entry.isFile() && TEXT_EXTENSIONS.has(path.extname(entry.name))) {
        files.push(child);
      }
    }
  };
  SCAN_ROOTS.forEach(walk);
  return files;
}

/** Counts every rule for one file's text. */
export function scanText(file, text) {
  const counts = {};
  const legacy = [];
  text.split(/\r?\n/).forEach((line, index) => {
    for (const token of LEGACY_TOKENS) {
      if (line.includes(token)) legacy.push(`${file}:${index + 1}: ${token}`);
    }
  });
  const language = languageOf(file);
  const code = language ? stripComments(text, language) : text;
  counts.words = listedWords(code).length;
  if (language) counts.nameComparisons = nameComparisons(code, language);
  if (language === "rust") counts.toolTables = toolTables(code);
  if (file.startsWith("shared/contracts/plugins/v1/") && file.endsWith(".schema.json")) {
    try {
      counts.schemaEnums = schemaEnums(JSON.parse(text));
    } catch (error) {
      throw new Error(`${file}: cannot parse schema: ${error.message}`);
    }
  }
  for (const category of CATEGORIES) if (!counts[category]) delete counts[category];
  return { counts, legacy };
}

// ---------------------------------------------------------------------------
// Allowlist

/** Converts a glob with `**`, `*`, `?` and unnested `{a,b}` into an anchored regex. */
export function globToRegExp(glob) {
  let source = "";
  for (let index = 0; index < glob.length; index += 1) {
    const character = glob[index];
    if (character === "*" && glob[index + 1] === "*") {
      const slash = glob[index + 2] === "/";
      source += slash ? "(?:.*/)?" : ".*";
      index += slash ? 2 : 1;
    } else if (character === "*") {
      source += "[^/]*";
    } else if (character === "?") {
      source += "[^/]";
    } else if (character === "{") {
      const end = glob.indexOf("}", index);
      if (end === -1) throw new Error(`unclosed "{" in glob ${glob}`);
      if (glob.slice(index + 1, end).includes("{")) throw new Error(`nested "{" is not supported in glob ${glob}; split the entry`);
      const options = glob.slice(index + 1, end).split(",").map((option) => option.replace(/[.+^$()|[\]\\]/g, "\\$&").replace(/\*/g, "[^/]*"));
      source += `(?:${options.join("|")})`;
      index = end;
    } else {
      source += character.replace(/[.+^$()|[\]\\]/g, "\\$&");
    }
  }
  return new RegExp(`^${source}$`);
}

function loadAllowlist(root, errors) {
  const absolute = path.join(root, ALLOWLIST_PATH);
  if (!existsSync(absolute)) return [];
  let document;
  try {
    document = JSON.parse(readFileSync(absolute, "utf8"));
  } catch (error) {
    errors.push(`${ALLOWLIST_PATH}: invalid JSON: ${error.message}`);
    return [];
  }
  if (!Array.isArray(document?.entries)) {
    errors.push(`${ALLOWLIST_PATH}: "entries" must be an array`);
    return [];
  }
  const entries = [];
  document.entries.forEach((entry, index) => {
    const label = `${ALLOWLIST_PATH} entry ${index + 1}${typeof entry?.glob === "string" ? ` (${entry.glob})` : ""}`;
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
      errors.push(`${label}: must be an object with ${ALLOWLIST_KEYS.join(", ")}`);
      return;
    }
    let valid = true;
    for (const key of ALLOWLIST_KEYS) {
      if (typeof entry[key] !== "string" || entry[key].trim() === "") {
        errors.push(`${label}: missing "${key}"`);
        valid = false;
      }
    }
    for (const key of Object.keys(entry)) {
      if (!ALLOWLIST_KEYS.includes(key)) {
        errors.push(`${label}: unknown key "${key}"`);
        valid = false;
      }
    }
    if (typeof entry.issue === "string" && entry.issue.trim() !== "" && !ISSUE_PATTERN.test(entry.issue)) {
      errors.push(`${label}: "issue" must look like #1495`);
      valid = false;
    }
    if (!valid) return;
    try {
      entries.push({ ...entry, pattern: globToRegExp(entry.glob), used: false });
    } catch (error) {
      errors.push(`${label}: ${error.message}`);
    }
  });
  return entries;
}

// ---------------------------------------------------------------------------
// Baseline

function readJson(text, label, errors) {
  try {
    return JSON.parse(text);
  } catch (error) {
    errors.push(`${label}: invalid JSON: ${error.message}`);
    return null;
  }
}

function baselineFiles(document, label, errors) {
  if (!document) return null;
  if (!document.files || typeof document.files !== "object" || Array.isArray(document.files)) {
    errors.push(`${label}: "files" must be an object`);
    return null;
  }
  for (const [file, counts] of Object.entries(document.files)) {
    for (const [category, value] of Object.entries(counts ?? {})) {
      if (!CATEGORIES.includes(category) || !Number.isInteger(value) || value <= 0) {
        errors.push(`${label}: ${file} has invalid ${category}=${JSON.stringify(value)}`);
      }
    }
  }
  return document.files;
}

const BASELINE_DESCRIPTION = "Per-file counts of language and build-tool names in host code. Counts may only go down; regenerate with --update-baseline after removing names. Deleted by the final Java extraction PR (#1495), which switches to --strict.";

/**
 * Writes one line per file, sorted, so parallel PRs that lower different
 * files rarely touch the same lines.
 */
function serializeBaseline(files) {
  const lines = Object.keys(files).sort().map((file) => {
    const counts = {};
    for (const category of CATEGORIES) if (files[file][category]) counts[category] = files[file][category];
    return `    ${JSON.stringify(file)}: ${JSON.stringify(counts)}`;
  });
  const body = lines.length > 0 ? `{\n${lines.join(",\n")}\n  }` : "{}";
  return `{\n  "description": ${JSON.stringify(BASELINE_DESCRIPTION)},\n  "files": ${body}\n}\n`;
}

/** Lists every increase from `before` to `after`, including new files. */
function increases(before, after) {
  const found = [];
  for (const [file, counts] of Object.entries(after)) {
    for (const category of CATEGORIES) {
      const now = counts[category] ?? 0;
      const was = before[file]?.[category] ?? 0;
      if (now > was) found.push(`${file}: ${category} ${was} -> ${now}${was === 0 && !before[file] ? " (new file)" : ""}`);
    }
  }
  return found;
}

function decreases(before, after) {
  return increases(after, before).map((line) => line.replace(/^(.*): (\w+) (\d+) -> (\d+).*$/, "$1: $2 $4 -> $3"));
}

// ---------------------------------------------------------------------------
// Entry point

function parseArguments(args) {
  const options = { root: null, strict: false, update: false, base: null };
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (argument === "--strict") options.strict = true;
    else if (argument === "--update-baseline") options.update = true;
    else if (argument === "--base" || argument === "--root") {
      const value = args[index + 1];
      if (!value || value.startsWith("--")) throw new Error(`${argument} needs a value`);
      options[argument.slice(2)] = value;
      index += 1;
    } else throw new Error(`unknown argument ${argument}`);
  }
  if (options.strict && options.update) throw new Error("--strict and --update-baseline cannot be combined");
  return options;
}

function gitShow(root, revision, file) {
  const run = (args) => execFileSync("git", ["-C", root, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 10_000 });
  try {
    run(["rev-parse", "--verify", "--quiet", `${revision}^{commit}`]);
  } catch {
    throw new Error(`--base ${revision} is not a commit`);
  }
  try {
    return run(["show", `${revision}:${file}`]);
  } catch {
    return null;
  }
}

function summarize(counts, allowlisted) {
  const lines = [];
  const totals = Object.fromEntries(CATEGORIES.map((category) => [category, 0]));
  const perRoot = new Map(SCAN_ROOTS.map((root) => [root, { files: 0, words: 0 }]));
  for (const [file, fileCounts] of Object.entries(counts)) {
    for (const category of CATEGORIES) totals[category] += fileCounts[category] ?? 0;
    const owner = perRoot.get([...SCAN_ROOTS].sort((a, b) => b.length - a.length).find((root) => file.startsWith(`${root}/`)));
    owner.files += 1;
    owner.words += fileCounts.words ?? 0;
  }
  lines.push(`Host language specifics: ${totals.words} word hits in ${Object.keys(counts).length} files; nameComparisons ${totals.nameComparisons}, toolTables ${totals.toolTables}, schemaEnums ${totals.schemaEnums}; ${allowlisted} allowlisted files not counted.`);
  for (const [root, { files, words }] of perRoot) lines.push(`  ${root}: ${words} word hits in ${files} files`);
  return lines;
}

/**
 * Runs the gate. Returns the exit code and output lines instead of exiting,
 * so tests can call it in-process.
 */
export function verify(args, { defaultRoot } = {}) {
  const stdout = [];
  const stderr = [];
  let options;
  try {
    options = parseArguments(args);
  } catch (error) {
    stderr.push(`verify-no-host-language-specifics: ${error.message}`);
    stderr.push("Usage: verify-no-host-language-specifics.mjs [--update-baseline | --strict] [--base <git-ref>] [--root <repository>]");
    return { code: 2, stdout, stderr };
  }
  const root = path.resolve(options.root ?? defaultRoot);
  const errors = [];
  const allowlist = loadAllowlist(root, errors);
  const counts = {};
  const legacy = [];
  let allowlisted = 0;
  for (const file of listFiles(root)) {
    let result;
    try {
      result = scanText(file, readFileSync(path.join(root, file), "utf8"));
    } catch (error) {
      errors.push(error.message);
      continue;
    }
    legacy.push(...result.legacy);
    if (Object.keys(result.counts).length === 0) continue;
    const entry = allowlist.find((candidate) => candidate.pattern.test(file));
    if (entry) {
      entry.used = true;
      allowlisted += 1;
      continue;
    }
    counts[file] = result.counts;
  }
  for (const entry of allowlist) {
    if (!entry.used) errors.push(`${ALLOWLIST_PATH}: ${entry.glob} matches no file with language names; remove the entry`);
  }
  if (legacy.length > 0) {
    errors.push("Retired Java entry/test scanner tokens are back; JDT and the Java plugin own entry points and tests:");
    errors.push(...legacy.map((line) => `  ${line}`));
  }

  const baselineAbsolute = path.join(root, BASELINE_PATH);
  const baselineExists = existsSync(baselineAbsolute);
  if (options.strict) {
    for (const [file, fileCounts] of Object.entries(counts)) {
      errors.push(`${file}: ${CATEGORIES.filter((category) => fileCounts[category]).map((category) => `${category}=${fileCounts[category]}`).join(", ")}`);
    }
  } else if (options.update) {
    if (errors.length === 0 && !baselineExists) {
      // First run: record the current state. Later runs only lower it.
      mkdirSync(path.dirname(baselineAbsolute), { recursive: true });
      writeFileSync(baselineAbsolute, serializeBaseline(counts));
      stdout.push(`${BASELINE_PATH}: created.`);
    } else if (errors.length === 0) {
      const previous = baselineFiles(readJson(readFileSync(baselineAbsolute, "utf8"), BASELINE_PATH, errors), BASELINE_PATH, errors);
      if (previous) {
        const grown = increases(previous, counts);
        if (grown.length > 0) {
          errors.push("The baseline only goes down. Remove the new language names instead of recording them:");
          errors.push(...grown.map((line) => `  ${line}`));
        } else {
          const lowered = decreases(previous, counts);
          writeFileSync(baselineAbsolute, serializeBaseline(counts));
          stdout.push(`${BASELINE_PATH}: ${lowered.length} counts lowered.`);
          stdout.push(...lowered.map((line) => `  ${line}`));
        }
      }
    }
  } else if (!baselineExists) {
    errors.push(`${BASELINE_PATH} is missing; the ratchet needs it until the final PR switches to --strict.`);
  } else {
    const recorded = baselineFiles(readJson(readFileSync(baselineAbsolute, "utf8"), BASELINE_PATH, errors), BASELINE_PATH, errors);
    if (recorded) {
      const grown = increases(recorded, counts);
      if (grown.length > 0) {
        errors.push("Host code gained language or build-tool names. Move the knowledge into a plugin or a generic API (see the Note in this script's header):");
        errors.push(...grown.map((line) => `  ${line}`));
      }
      const lowered = decreases(recorded, counts);
      if (lowered.length > 0) {
        errors.push("Counts went down; lock in the progress with `node scripts/architecture/verify-no-host-language-specifics.mjs --update-baseline`:");
        errors.push(...lowered.map((line) => `  ${line}`));
      }
    }
  }

  if (options.base && !options.update) {
    try {
      const baseBaseline = gitShow(root, options.base, BASELINE_PATH);
      const baseAllowlist = gitShow(root, options.base, ALLOWLIST_PATH);
      if (baseBaseline !== null && baselineExists && !options.strict) {
        const before = baselineFiles(readJson(baseBaseline, `${options.base}:${BASELINE_PATH}`, errors), `${options.base}:${BASELINE_PATH}`, errors);
        const after = baselineFiles(readJson(readFileSync(baselineAbsolute, "utf8"), BASELINE_PATH, errors), BASELINE_PATH, errors);
        if (before && after) {
          const grown = increases(before, after);
          if (grown.length > 0) {
            errors.push(`${BASELINE_PATH} grew compared with ${options.base}; it may only go down:`);
            errors.push(...grown.map((line) => `  ${line}`));
          }
        }
      } else if (baseBaseline === null) {
        stdout.push(`${options.base} has no ${BASELINE_PATH}; skipped the base comparison.`);
      }
      if (baseAllowlist !== null) {
        const before = readJson(baseAllowlist, `${options.base}:${ALLOWLIST_PATH}`, errors);
        const known = new Set((before?.entries ?? []).map((entry) => entry?.glob));
        const added = allowlist.filter((entry) => !known.has(entry.glob)).map((entry) => entry.glob);
        if (added.length > 0) {
          errors.push(`${ALLOWLIST_PATH} gained entries compared with ${options.base}; the allowlist only shrinks:`);
          errors.push(...added.map((glob) => `  ${glob}`));
        }
      }
    } catch (error) {
      errors.push(error.message);
    }
  }

  stdout.push(...summarize(counts, allowlisted));
  if (errors.length > 0) {
    stderr.push(...errors);
    return { code: 1, stdout, stderr };
  }
  if (options.strict) stdout.push("Strict mode: no language or build-tool names outside the allowlist.");
  else if (!options.update) stdout.push("Ratchet verified: every count matches the baseline.");
  return { code: 0, stdout, stderr };
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const defaultRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
  const result = verify(process.argv.slice(2), { defaultRoot });
  for (const line of result.stdout) console.log(line);
  for (const line of result.stderr) console.error(line);
  process.exitCode = result.code;
}
