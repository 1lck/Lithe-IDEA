#!/usr/bin/env node
// Static gate for blocking primitives in test code.
//
// The gate is a ratchet: it fails only when a change introduces a blocking
// pattern that did not exist before. A pattern counts as pre-existing when the
// base revision already contains a line with the same rule, the same enclosing
// test declaration, and the same statement text. Moving a test module between
// files or re-indenting it therefore does not trip the gate, while adding a
// second sleep to a test that already had one does.

import { execFileSync } from "node:child_process";
import { readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIRECTORY = path.dirname(fileURLToPath(import.meta.url));
export const REPOSITORY_ROOT = path.resolve(SCRIPT_DIRECTORY, "../../../..");
const MINIMUM_REASON_LENGTH = 16;

const RULES = {
  swift: [
    {
      id: "swift-unbounded-wait",
      pattern: /\.wait\s*\(\s*\)|\.wait\s*\([^)]*\.\s*distantFuture\b[^)]*\)/,
      message: "Use a finite timeout and assert its result; bare waits and distantFuture can hang CI.",
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

// The nearest enclosing declaration names the test a pattern belongs to. It is
// part of the identity used to recognize moved code, so a sleep that moves
// together with its test is pre-existing, while the same statement in another
// test is new.
const DECLARATIONS = {
  rust: /\bfn\s+([A-Za-z_]\w*)/,
  swift: /\bfunc\s+([A-Za-z_]\w*)/,
  typescript: /\b(?:test|it|describe)\s*\(\s*(["'`])((?:(?!\1).)*)\1/,
};

const SKIPPED_DIRECTORIES = new Set([".git", ".build", ".artifacts", "target", "node_modules"]);

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

function isScanned(filePath, platform) {
  return languageFor(filePath) !== null && belongsToPlatform(filePath, platform);
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

// Rust keeps tests next to production code, so only lines inside
// `#[cfg(test)]` modules, `#[test]` functions, or `tests/` files are scanned.
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
  const pattern = new RegExp(`test-stability:\\s*allow\\(${escapedRule}\\)\\s*reason:\\s*(.+)$`);
  for (const candidate of candidates) {
    const match = candidate.match(pattern);
    if (match) return match[1].trim();
  }
  return null;
}

function enclosingDeclaration(lines, lineIndex, language) {
  const pattern = DECLARATIONS[language];
  for (let index = lineIndex; index >= 0; index -= 1) {
    const match = lines[index].match(pattern);
    if (match) return match[2] ?? match[1];
  }
  return "";
}

function violation(lines, lineIndex, rule, reason, language, reportIndex = lineIndex) {
  return {
    file: null,
    line: reportIndex + 1,
    rule: rule.id,
    message: reason ? `Exception reason is too short. ${rule.message}` : rule.message,
    source: lines[reportIndex].trim(),
    declaration: enclosingDeclaration(lines, lineIndex, language),
  };
}

function isAllowed(reason) {
  return reason !== null && reason.length >= MINIMUM_REASON_LENGTH;
}

// `.wait(` calls can span several lines, so the arguments are collected until
// the parenthesis closes before deciding whether the wait is bounded.
function swiftUnboundedWaitViolations(lines, selected) {
  const violations = [];
  const rule = RULES.swift.find((candidate) => candidate.id === "swift-unbounded-wait");

  for (let index = 0; index < lines.length; index += 1) {
    const firstLine = stripStringsAndLineComments(lines[index]);
    let searchOffset = 0;

    while (searchOffset < firstLine.length) {
      const match = firstLine.slice(searchOffset).match(/\.wait\s*\(/);
      if (!match) break;

      const waitColumn = searchOffset + match.index;
      let depth = 0;
      let callStarted = false;
      let callClosed = false;
      let callEnd = index;
      let callText = "";

      callLines: for (let callIndex = index; callIndex < lines.length; callIndex += 1) {
        const structural = stripStringsAndLineComments(lines[callIndex]);
        const columnStart = callIndex === index ? waitColumn : 0;

        for (let column = columnStart; column < structural.length; column += 1) {
          const character = structural[column];
          callText += character;
          if (character === "(") {
            depth += 1;
            callStarted = true;
          } else if (character === ")" && callStarted) {
            depth -= 1;
            if (depth === 0) {
              callEnd = callIndex;
              callClosed = true;
              break callLines;
            }
          }
        }

        callEnd = callIndex;
        callText += "\n";
      }

      if (!callStarted || !callClosed) break;

      const argumentsText = callText.slice(callText.indexOf("(") + 1, callText.lastIndexOf(")"));
      const isUnbounded =
        argumentsText.trim().length === 0 || /\.\s*distantFuture\b/.test(argumentsText);

      if (isUnbounded) {
        const selectedLines = selected
          ? [...selected].filter((lineNumber) => lineNumber >= index + 1 && lineNumber <= callEnd + 1)
          : [];

        if (!selected || selectedLines.length > 0) {
          const reportIndex = selected ? Math.min(...selectedLines) - 1 : index;
          const reason = exceptionReason(lines, index, rule.id);
          if (!isAllowed(reason)) {
            violations.push(violation(lines, index, rule, reason, "swift", reportIndex));
          }
        }
      }

      searchOffset = waitColumn + match[0].length;
    }
  }

  return violations;
}

const DETACHED_RULE = {
  id: "swift-detached-blocking",
  message: "Do not hide a blocking wait in Task.detached; use bounded asynchronous signaling.",
};

function swiftDetachedBlockingViolations(lines, selected) {
  const violations = [];
  for (let index = 0; index < lines.length; index += 1) {
    const firstLine = stripStringsAndLineComments(lines[index]);
    const detachedIndex = firstLine.search(/\bTask\.detached\b/);
    if (detachedIndex < 0) continue;

    let depth = 0;
    let blockStarted = false;
    let blockEnd = index;
    let waitLine = null;
    for (let blockIndex = index; blockIndex < lines.length; blockIndex += 1) {
      let structural = stripStringsAndLineComments(lines[blockIndex]);
      if (blockIndex === index) structural = structural.slice(detachedIndex);
      if (!blockStarted) {
        const openingBrace = structural.indexOf("{");
        if (openingBrace < 0) continue;
        structural = structural.slice(openingBrace);
        blockStarted = true;
      }
      if (waitLine === null && /\bwait\w*\s*\(/.test(structural)) waitLine = blockIndex;
      depth += (structural.match(/\{/g) ?? []).length;
      depth -= (structural.match(/\}/g) ?? []).length;
      blockEnd = blockIndex;
      if (depth <= 0) break;
    }
    if (!blockStarted || waitLine === null) continue;

    const selectedLines = selected
      ? [...selected].filter((lineNumber) => lineNumber >= index + 1 && lineNumber <= blockEnd + 1)
      : [];
    if (selected && selectedLines.length === 0) continue;
    const reportIndex = selected?.has(waitLine + 1)
      ? waitLine
      : selected
        ? Math.min(...selectedLines) - 1
        : waitLine;
    const reason = exceptionReason(lines, waitLine, DETACHED_RULE.id);
    if (isAllowed(reason)) continue;
    violations.push(violation(lines, waitLine, DETACHED_RULE, reason, "swift", reportIndex));
    index = blockEnd;
  }
  return violations;
}

/// Scans one file. `selectedLineNumbers` restricts the single-line rules to the
/// given lines; multi-line Swift rules report a match when any of its lines is
/// selected. Each violation carries the enclosing declaration so callers can
/// match it against another revision.
export function scanFile(filePath, content, selectedLineNumbers = null, platform = "all") {
  const normalized = normalizePath(filePath);
  const language = languageFor(normalized);
  if (!language || !belongsToPlatform(normalized, platform)) return [];

  const lines = content.split(/\r?\n/);
  const rustMask = language === "rust" ? rustTestLineMask(lines, normalized) : null;
  const selected = selectedLineNumbers ? new Set(selectedLineNumbers) : null;
  const violations = [];

  for (let index = 0; index < lines.length; index += 1) {
    if (selected && !selected.has(index + 1)) continue;
    if (rustMask && !rustMask[index]) continue;

    for (const rule of RULES[language]) {
      if (rule.id === "swift-unbounded-wait") continue;
      if (!rule.pattern.test(lines[index])) continue;
      const reason = exceptionReason(lines, index, rule.id);
      if (isAllowed(reason)) continue;
      violations.push(violation(lines, index, rule, reason, language));
    }
  }
  if (language === "swift") {
    violations.push(...swiftUnboundedWaitViolations(lines, selected));
    violations.push(...swiftDetachedBlockingViolations(lines, selected));
  }
  return violations.map((entry) => ({ ...entry, file: normalized }));
}

/// Parses a unified diff with zero context into the added line numbers of each
/// new path and the set of paths that existed in the base revision.
export function parseDiff(diff) {
  const added = new Map();
  const basePaths = new Set();
  let currentPath = null;
  let newLine = 0;
  for (const line of diff.split(/\r?\n/)) {
    if (line.startsWith("--- ")) {
      const value = line.slice(4);
      if (value !== "/dev/null") basePaths.add(normalizePath(value.replace(/^a\//, "")));
      continue;
    }
    if (line.startsWith("+++ ")) {
      const value = line.slice(4);
      currentPath = value === "/dev/null" ? null : normalizePath(value.replace(/^b\//, ""));
      continue;
    }
    const hunk = line.match(/^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/);
    if (hunk) {
      newLine = Number(hunk[1]);
      continue;
    }
    if (!currentPath || line.startsWith("\\ No newline")) continue;
    if (line.startsWith("+")) {
      if (!added.has(currentPath)) added.set(currentPath, new Set());
      added.get(currentPath).add(newLine);
      newLine += 1;
    } else if (!line.startsWith("-")) {
      newLine += 1;
    }
  }
  return { added, basePaths };
}

export function parseAddedLines(diff) {
  return parseDiff(diff).added;
}

function identity(entry) {
  return `${entry.rule}\u0000${entry.declaration}\u0000${entry.source.replace(/\s+/g, " ")}`;
}

/// Decides which head violations are new. `headFiles` maps each head path to
/// `{ content, addedLines }` where `addedLines` is `null` for a file that did
/// not exist in the base; `baseFiles` maps base paths to their content.
///
/// Violations on unchanged lines first claim their base counterparts, so a
/// duplicate of an existing statement inside the same test cannot hide behind
/// the original. Added lines that still find a counterpart are moves and are
/// counted instead of reported.
export function reconcile({ headFiles, baseFiles, platform = "all" }) {
  const baseline = new Map();
  for (const [file, content] of baseFiles) {
    for (const entry of scanFile(file, content, null, platform)) {
      const key = identity(entry);
      baseline.set(key, (baseline.get(key) ?? 0) + 1);
    }
  }

  const claim = (entry) => {
    const key = identity(entry);
    const remaining = baseline.get(key) ?? 0;
    if (remaining === 0) return false;
    baseline.set(key, remaining - 1);
    return true;
  };

  const candidates = [];
  for (const [file, { content, addedLines }] of headFiles) {
    const everything = scanFile(file, content, null, platform);
    if (addedLines === null) {
      candidates.push(...everything);
      continue;
    }
    for (const entry of everything) {
      if (!addedLines.has(entry.line)) claim(entry);
    }
    candidates.push(...scanFile(file, content, addedLines, platform));
  }

  const violations = [];
  let moved = 0;
  for (const entry of candidates) {
    if (claim(entry)) moved += 1;
    else violations.push(entry);
  }
  return { violations, moved };
}

function walk(root, directory = root, result = []) {
  if (!statSync(directory).isDirectory()) return result;
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    if (SKIPPED_DIRECTORIES.has(entry.name)) continue;
    const absolute = path.join(directory, entry.name);
    if (entry.isDirectory()) walk(root, absolute, result);
    else result.push(normalizePath(path.relative(root, absolute)));
  }
  return result;
}

function git(root, ...arguments_) {
  return execFileSync("git", ["-c", `safe.directory=${root}`, ...arguments_], {
    cwd: root,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
}

// Reads a file as it is at `revision`, or from the working tree when
// `revision` is null. Returns null for a path that does not exist there.
function fileAt(root, revision, file) {
  try {
    if (revision === null) return readFileSync(path.resolve(root, file), "utf8");
    return git(root, "-c", "core.quotePath=false", "show", `${revision}:${file}`);
  } catch {
    return null;
  }
}

export function parseArguments(arguments_) {
  const options = { all: false, platform: "all", base: null, head: "HEAD", help: false };
  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (argument === "--all") options.all = true;
    else if (argument === "--platform") options.platform = arguments_[++index];
    else if (argument === "--base") options.base = arguments_[++index];
    else if (argument === "--head") options.head = arguments_[++index];
    else if (argument === "--help") options.help = true;
    else throw new Error(`Unknown argument: ${argument}`);
  }
  if (!["all", "macos", "windows"].includes(options.platform)) {
    throw new Error(`Unsupported platform: ${options.platform}`);
  }
  if (!options.base && options.head !== "HEAD") {
    throw new Error("--head requires --base");
  }
  return options;
}

/// Runs the gate. Without `--base` the working tree (including untracked
/// files) is compared with HEAD; with `--base` the committed `--head` revision
/// is compared with `--base`, so results do not depend on the working tree.
export function run(options) {
  const root = options.root ?? REPOSITORY_ROOT;
  const platform = options.platform ?? "all";

  if (options.all) {
    const violations = [];
    for (const file of walk(root)) {
      if (!isScanned(file, platform)) continue;
      violations.push(...scanFile(file, fileAt(root, null, file) ?? "", null, platform));
    }
    return { violations, moved: 0 };
  }

  const baseRevision = options.base ?? "HEAD";
  const headRevision = options.base ? options.head ?? "HEAD" : null;
  // Renames are disabled so a moved file shows its content as removed and
  // added lines; the prefixes are pinned so user diff configuration cannot
  // change how paths are parsed.
  const diffArguments = [
    "-c",
    "core.quotePath=false",
    "diff",
    "--unified=0",
    "--no-color",
    "--no-renames",
    "--src-prefix=a/",
    "--dst-prefix=b/",
  ];
  diffArguments.push(baseRevision);
  if (headRevision !== null) diffArguments.push(headRevision);
  diffArguments.push("--");
  const { added, basePaths } = parseDiff(git(root, ...diffArguments));

  if (headRevision === null) {
    const untracked = git(root, "ls-files", "--others", "--exclude-standard")
      .split(/\r?\n/)
      .filter(Boolean);
    for (const file of untracked) added.set(normalizePath(file), null);
  }

  const headFiles = new Map();
  for (const [file, addedLines] of added) {
    if (!isScanned(file, platform)) continue;
    const content = fileAt(root, headRevision, file);
    if (content === null) continue;
    headFiles.set(file, { content, addedLines });
  }

  const baseFiles = new Map();
  for (const file of basePaths) {
    if (!isScanned(file, platform)) continue;
    const content = fileAt(root, baseRevision, file);
    if (content !== null) baseFiles.set(file, content);
  }

  return reconcile({ headFiles, baseFiles, platform });
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
    console.log(
      [
        "Usage: verify-test-stability.mjs [--all] [--platform all|macos|windows] [--base REV [--head REV]]",
        "",
        "Without --base, compares the working tree with HEAD. With --base, compares",
        "the committed --head revision (default HEAD) with --base. Blocking patterns",
        "that already existed in the base revision under the same rule, enclosing",
        "test and statement text are treated as moved code and are not reported.",
        "--all scans the whole tree and reports every pattern.",
      ].join("\n"),
    );
    return;
  }

  const scope = options.all ? "full tree" : options.base ? `${options.base}..${options.head}` : "working tree";
  const { violations, moved } = run(options);
  if (moved > 0) {
    console.log(`Ignored ${moved} pre-existing blocking pattern(s) that only moved.`);
  }
  if (violations.length === 0) {
    console.log(`Test stability check passed (${scope}, ${options.platform}).`);
    return;
  }

  console.error(`Test stability check found ${violations.length} blocking issue(s) (${scope}, ${options.platform}):`);
  for (const entry of violations) {
    console.error(`${entry.file}:${entry.line}: [${entry.rule}] ${entry.message}`);
    console.error(`  ${entry.source}`);
  }
  console.error(
    "Use deterministic synchronization. An unavoidable primitive needs a bounded implementation and a `test-stability: allow(<rule>) reason: …` annotation on the line or the line above.",
  );
  process.exitCode = 1;
}

if (path.resolve(process.argv[1] ?? "") === fileURLToPath(import.meta.url)) main();
