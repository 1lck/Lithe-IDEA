#!/usr/bin/env node

import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REQUIRED_HEADINGS = [
  "## 中文",
  "### 下载",
  "### 重点更新",
  "### 升级说明",
  "### 兼容性与已知问题",
  "## English",
  "### Downloads",
  "### Highlights",
  "### Upgrade instructions",
  "### Compatibility and known issues",
];

function markdownHeadings(lines) {
  const headings = [];
  let fence = null;

  for (const [index, line] of lines.entries()) {
    const trimmed = line.trim();
    const fenceMatch = trimmed.match(/^(`{3,}|~{3,})/);
    if (fenceMatch) {
      const marker = fenceMatch[1][0];
      if (fence === null) fence = marker;
      else if (fence === marker) fence = null;
      continue;
    }
    if (fence !== null) continue;

    const headingMatch = trimmed.match(/^(#{1,6})\s+(.+?)\s*#*$/);
    if (headingMatch) {
      headings.push({
        line: index,
        level: headingMatch[1].length,
        text: `${headingMatch[1]} ${headingMatch[2].trim()}`,
      });
    }
  }

  return headings;
}

function hasSectionContent(lines, start, end) {
  return lines.slice(start, end).some((line) => {
    const trimmed = line.trim();
    return trimmed.length > 0
      && !/^#{1,6}\s+/.test(trimmed)
      && !/^([-*_])(?:\s*\1){2,}$/.test(trimmed)
      && !/^<!--.*-->$/.test(trimmed);
  });
}

export function validateStableReleaseNotes(contents, source = "release notes") {
  const errors = [];
  if (contents.trim().length === 0) {
    errors.push("file must contain non-whitespace content");
  }

  const lines = contents.replaceAll("\r\n", "\n").split("\n");
  const headings = markdownHeadings(lines);
  const required = [];

  for (const expected of REQUIRED_HEADINGS) {
    const matches = headings.filter((heading) => heading.text === expected);
    if (matches.length !== 1) {
      errors.push(`required heading "${expected}" must appear exactly once; found ${matches.length}`);
      continue;
    }
    required.push(matches[0]);
  }

  if (required.length === REQUIRED_HEADINGS.length) {
    for (let index = 1; index < required.length; index += 1) {
      if (required[index - 1].line >= required[index].line) {
        errors.push(`required heading "${REQUIRED_HEADINGS[index]}" is out of order`);
        break;
      }
    }

    for (const heading of required) {
      const headingIndex = headings.indexOf(heading);
      const nextHeadingLine = headings[headingIndex + 1]?.line ?? lines.length;
      if (!hasSectionContent(lines, heading.line + 1, nextHeadingLine)) {
        errors.push(`section "${heading.text}" must contain content before the next heading`);
      }
    }
  }

  if (errors.length > 0) {
    throw new Error(`${source} is not a valid stable release note:\n- ${errors.join("\n- ")}`);
  }
}

function main() {
  const notesPath = process.argv[2];
  if (!notesPath || process.argv.length !== 3) {
    throw new Error("Usage: validate-stable-release-notes.mjs <release-notes.md>");
  }
  const resolvedPath = path.resolve(notesPath);
  validateStableReleaseNotes(readFileSync(resolvedPath, "utf8"), notesPath);
  console.log(`Stable release notes validated: ${notesPath}`);
}

if (path.resolve(process.argv[1] ?? "") === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
