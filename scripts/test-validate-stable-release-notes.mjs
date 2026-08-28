#!/usr/bin/env node

import assert from "node:assert/strict";
import test from "node:test";

import { validateStableReleaseNotes } from "./validate-stable-release-notes.mjs";

const validNotes = `## 中文

本版本改进了发布可靠性。

### 下载

- [Windows x64](https://example.com/windows)

### 重点更新

- Windows 更新包现在包含签名。

### 升级说明

请安装对应平台的软件包。

### 兼容性与已知问题

Windows 旧版本需要先手动升级。

[完整变更](https://example.com/compare)

---

## English

This release improves publishing reliability.

### Downloads

- [Windows x64](https://example.com/windows)

### Highlights

- Windows updater bundles now include signatures.

### Upgrade instructions

Install the package for your platform.

### Compatibility and known issues

Older Windows versions require one manual upgrade.

[Full changelog](https://example.com/compare)
`;

test("accepts complete bilingual stable release notes", () => {
  assert.doesNotThrow(() => validateStableReleaseNotes(validNotes, "valid.md"));
});

test("rejects whitespace-only release notes", () => {
  assert.throws(
    () => validateStableReleaseNotes(" \n\t\n", "whitespace.md"),
    /file must contain non-whitespace content/,
  );
});

test("rejects a missing language section", () => {
  const chineseOnly = validNotes.slice(0, validNotes.indexOf("## English"));
  assert.throws(
    () => validateStableReleaseNotes(chineseOnly, "missing-english.md"),
    /required heading "## English" must appear exactly once/,
  );
});

test("rejects required headings in the wrong order", () => {
  const outOfOrder = validNotes
    .replace("### 下载", "### TEMP")
    .replace("### 重点更新", "### 下载")
    .replace("### TEMP", "### 重点更新");
  assert.throws(
    () => validateStableReleaseNotes(outOfOrder, "out-of-order.md"),
    /required heading "### 重点更新" is out of order/,
  );
});

test("rejects an empty required section", () => {
  const emptyDownloads = validNotes.replace(
    "### 下载\n\n- [Windows x64](https://example.com/windows)\n\n### 重点更新",
    "### 下载\n\n### 重点更新",
  );
  assert.throws(
    () => validateStableReleaseNotes(emptyDownloads, "empty-downloads.md"),
    /section "### 下载" must contain content before the next heading/,
  );
});

test("ignores required-looking headings inside fenced code blocks", () => {
  const missingEnglish = validNotes.slice(0, validNotes.indexOf("## English"));
  const fencedHeadings = `${missingEnglish}\n\`\`\`markdown\n## English\n### Downloads\n### Highlights\n### Upgrade instructions\n### Compatibility and known issues\n\`\`\`\n`;
  assert.throws(
    () => validateStableReleaseNotes(fencedHeadings, "fenced.md"),
    /required heading "## English" must appear exactly once; found 0/,
  );
});
