#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIRECTORY = path.dirname(fileURLToPath(import.meta.url));
const REPOSITORY_ROOT = path.resolve(SCRIPT_DIRECTORY, "../../../..");

const RULES = {
  swift: [
    {
      id: "swift-unbounded-wait",
      pattern: /\.wait\(\s*\)/,
      message: "Use a bounded wait and assert the timeout result; a bare wait can hang CI.",
    },
    {
      id: "swift-real-sleep",
      pattern: /\b(?:Task|Thread)\.sleep\s*\(|\busleep\s*\(/,
      message: "Use an injected clock, event, or continuation instead of real-time sleep.",
    },
    {
      id: "swift-process-wait",
      pattern: /\.waitUntilExit\s*\(/,
      message: "Wait for subprocesses through a watchdog that can terminate the process tree.",
    },
    {
      id: "swift-detached-blocking",
      pattern: /Task\.detached\b.*\bwait\w*\s*\(/,
      message: "Do not hide a blocking wait in Task.detached; use bounded asynchronous signaling.",
    },
    {
      id: "swift-run-loop-wait",
      pattern: /RunLoop\.current\.run\s*\(/,
      message: "Do not spin a run loop to synchronize a test; await an observable event.",
    },
  ],
  typescript: [
    {
      id: "typescript-real-timer",
      pattern: /\b(?:globalThis\.|window\.)?set(?:Timeout|Interval)\s*\(/,
      message: "Inject a manual timer or scheduler instead of using a real timer in a test.",
    },
    {
      id: "typescript-atomic-wait",
      pattern: /\bAtomics\.wait\s*\(/,
      message: "Atomics.wait blocks the test worker; use a deferred promise with owned cleanup.",
    },
    {
      id: "typescript-infinite-loop",
      pattern: /\bwhile\s*\(\s*true\s*\)/,
      message: "Test polling loops require an explicit deadline and timeout diagnostic.",
    },
  ],
  rust: [
    {
      id: "rust-real-sleep",
      pattern: /\b(?:std::)?thread::sleep\s*\(/,
      message: "Use a channel, barrier, or injected clock instead of sleeping to coordinate a test.",
    },
    {
      id: "rust-unbounded-receive",
      pattern: /\.recv\(\s*\)/,
      message: "Use recv_timeout or another bounded receive in test synchronization.",
    },
  ],
};

function normalizePath(filePath) {
  return filePath.split(path.sep).join("/").replace(/^\.\//, "");
}

function languageFor(filePath) {
  const normalized = normalizePath(filePath);
  if (
    normalized.endsWith(".swift") &&
    (normalized.includes("/Tests/") || normalized.startsWith("macos/Tests/"))
  ) {
    return "swift";
  }
  if (/\.(?:test|spec)\.tsx?$/.test(normalized)) return "typescript";
  if (normalized.endsWith(".rs")) return "rust";
  return null;
}

function belongsToPlatform(filePath, platform) {
  if (platform === "all") return true;
  const normalized = normalizePath(filePath);
  if (platform === "macos") {
    return (
      normalized.startsWith("macos/") ||
      normalized.startsWith("Plugins/mac/") ||
      normalized.startsWith("rust/")
    );
  }
  return normalized.startsWith("windows/") || normalized.startsWith("rust/lithe-core/");
}

function stripStringsAndLineComments(line) {
  let result = "";
  let quote = null;
  let escaped = false;
  for (let index = 0; index < line.length; index += 1) {
    const character = line[index];
    const next = line[index + 1];
    if (quote) {
      if (escaped) escaped = false;
      else if (character === "\\") escaped = true;
      else if (character === quote) quote = null;
      result += " ";
      continue;
    }
    if (character === "/" && next === "/") break;
    if (character === '"' || character === "'") {
      quote = character;
      result += " ";
      continue;
    }
    result += character;
  }
  return result;
}

function rustTestLineMask(lines, filePath) {
  const normalized = normalizePath(filePath);
  if (normalized.includes("/tests/") || /(?:^|\/)tests\.rs$/.test(normalized)) {
    return lines.map(() => true);
  }

  const mask = lines.map(() => false);
  let depth = 0;
  let pendingTestModule = false;
  let pendingTestFunction = false;
  const activeDepths = [];

  for (let index = 0; index < lines.length; index += 1) {
    const structural = stripStringsAndLineComments(lines[index]);
    if (/^\s*#\s*\[\s*cfg\s*\(\s*test\s*\)\s*\]/.test(structural)) {
      pendingTestModule = true;
    }
    if (/^\s*#\s*\[\s*(?:[A-Za-z_][\w:]*::)?test(?:\s*\([^\]]*\))?\s*\]/.test(structural)) {
      pendingTestFunction = true;
    }

    const startsModule = pendingTestModule && /\bmod\s+[A-Za-z_]\w*\s*\{/.test(structural);
    const startsFunction = pendingTestFunction && /\bfn\s+[A-Za-z_]\w*[^;]*\{/.test(structural);
    const startsTestRegion = startsModule || startsFunction;
    if (activeDepths.length > 0 || pendingTestFunction || startsTestRegion) mask[index] = true;

    const opens = (structural.match(/\{/g) ?? []).length;
    const closes = (structural.match(/\}/g) ?? []).length;
    if (startsTestRegion) activeDepths.push(depth + 1);
    depth += opens - closes;
    while (activeDepths.length > 0 && depth < activeDepths[activeDepths.length - 1]) {
      activeDepths.pop();
    }

    if (startsModule) pendingTestModule = false;
    if (startsFunction) pendingTestFunction = false;
  }

  return mask;
}

function exceptionReason(lines, lineIndex, ruleID) {
  const candidates = [lines[lineIndex], lines[lineIndex - 1]].filter(Boolean);
  const escapedRule = ruleID.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const pattern = new RegExp(
    `test-stability:\\s*allow\\(${escapedRule}\\)\\s*reason:\\s*(.+)$`,
  );
  for (const candidate of candidates) {
    const match = candidate.match(pattern);
    if (match) return match[1].trim();
  }
  return null;
}

export function scanFile(filePath, content, selectedLineNumbers = null, platform = "all") {
  const normalized = normalizePath(filePath);
  const language = languageFor(normalized);
  if (!language || !belongsToPlatform(normalized, platform)) return [];

  const lines = content.split(/\r?\n/);
  const rustMask = language === "rust" ? rustTestLineMask(lines, normalized) : null;
  const selected = selectedLineNumbers ? new Set(selectedLineNumbers) : null;
  const violations = [];

  for (let index = 0; index < lines.length; index += 1) {
    const lineNumber = index + 1;
    if (selected && !selected.has(lineNumber)) continue;
    if (rustMask && !rustMask[index]) continue;

    for (const rule of RULES[language]) {
      if (!rule.pattern.test(lines[index])) continue;
      const reason = exceptionReason(lines, index, rule.id);
      if (reason && reason.length >= 16) continue;
      violations.push({
        file: normalized,
        line: lineNumber,
        rule: rule.id,
        message: reason
          ? `Exception reason is too short. ${rule.message}`
          : rule.message,
        source: lines[index].trim(),
      });
    }
  }
  return violations;
}

export function parseAddedLines(diff) {
  const files = new Map();
  let currentPath = null;
  let newLine = 0;
  for (const line of diff.split(/\r?\n/)) {
    if (line.startsWith("+++ ")) {
      const value = line.slice(4);
      currentPath = value === "/dev/null" ? null : value.replace(/^b\//, "");
      continue;
    }
    const hunk = line.match(/^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/);
    if (hunk) {
      newLine = Number(hunk[1]);
      continue;
    }
    if (!currentPath || line.startsWith("\\ No newline")) continue;
    if (line.startsWith("+") && !line.startsWith("+++")) {
      if (!files.has(currentPath)) files.set(currentPath, new Set());
      files.get(currentPath).add(newLine);
      newLine += 1;
    } else if (!line.startsWith("-")) {
      newLine += 1;
    }
  }
  return files;
}

function walk(directory, result = []) {
  if (!statSync(directory).isDirectory()) return result;
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    if ([".git", ".build", ".artifacts", "target", "node_modules"].includes(entry.name)) continue;
    const absolute = path.join(directory, entry.name);
    if (entry.isDirectory()) walk(absolute, result);
    else result.push(normalizePath(path.relative(REPOSITORY_ROOT, absolute)));
  }
  return result;
}

function git(...arguments_) {
  return execFileSync("git", ["-c", `safe.directory=${REPOSITORY_ROOT}`, ...arguments_], {
    cwd: REPOSITORY_ROOT,
    encoding: "utf8",
    maxBuffer: 32 * 1024 * 1024,
  });
}

function parseArguments(arguments_) {
  const options = { all: false, platform: "all", base: null, head: "HEAD" };
  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (argument === "--all") options.all = true;
    else if (argument === "--platform") options.platform = arguments_[++index];
    else if (argument === "--base") options.base = arguments_[++index];
    else if (argument === "--head") options.head = arguments_[++index];
    else if (argument === "--help") options.help = true;
    else throw new Error(`Unknown argument: ${argument}`);
  }
  if (!['all', 'macos', 'windows'].includes(options.platform)) {
    throw new Error(`Unsupported platform: ${options.platform}`);
  }
  return options;
}

function changedFiles(options) {
  const diffArguments = ["-c", "core.quotePath=false", "diff", "--unified=0", "--no-color"];
  if (options.base) diffArguments.push(options.base, options.head);
  else diffArguments.push("HEAD");
  diffArguments.push("--");
  const changed = parseAddedLines(git(...diffArguments));

  if (!options.base) {
    const untracked = git("ls-files", "--others", "--exclude-standard").split(/\r?\n/).filter(Boolean);
    for (const file of untracked) changed.set(normalizePath(file), null);
  }
  return changed;
}

export function run(options) {
  const candidates = options.all
    ? new Map(walk(REPOSITORY_ROOT).map((file) => [file, null]))
    : changedFiles(options);
  const violations = [];
  for (const [file, selectedLines] of candidates) {
    if (!languageFor(file) || !belongsToPlatform(file, options.platform)) continue;
    const absolute = path.resolve(REPOSITORY_ROOT, file);
    let content;
    try {
      content = readFileSync(absolute, "utf8");
    } catch {
      continue;
    }
    violations.push(...scanFile(file, content, selectedLines, options.platform));
  }
  return violations;
}

function main() {
  let options;
  try {
    options = parseArguments(process.argv.slice(2));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 2;
    return;
  }
  if (options.help) {
    console.log("Usage: verify-test-stability.mjs [--all] [--platform all|macos|windows] [--base REV --head REV]");
    return;
  }

  const violations = run(options);
  if (violations.length === 0) {
    console.log(`Test stability check passed (${options.all ? "full tree" : "added lines"}, ${options.platform}).`);
    return;
  }

  console.error(`Test stability check found ${violations.length} blocking issue(s):`);
  for (const violation of violations) {
    console.error(`${violation.file}:${violation.line}: [${violation.rule}] ${violation.message}`);
    console.error(`  ${violation.source}`);
  }
  console.error("Use deterministic synchronization. Exceptions require a bounded implementation and a reasoned test-stability annotation.");
  process.exitCode = 1;
}

if (path.resolve(process.argv[1] ?? "") === fileURLToPath(import.meta.url)) main();
