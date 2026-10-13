#!/usr/bin/env node

import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const sourcePath = resolve(root, "shared/platform-feature-matrix");
const outputIndex = process.argv.indexOf("--output-dir");
if (outputIndex !== -1 && !process.argv[outputIndex + 1]) throw new Error("--output-dir requires a path");
const outputDir = resolve(root, outputIndex === -1 ? ".artifacts/platform-feature-matrix" : process.argv[outputIndex + 1]);
const outputPath = resolve(outputDir, "platform-parity-matrix.md");
const csvOutputPath = resolve(outputDir, "platform-parity-matrix.csv");
const checkOnly = process.argv.includes("--check");
const source = JSON.parse(readFileSync(resolve(sourcePath, "metadata.json"), "utf8"));
if (source.schemaVersion !== 4 || Object.hasOwn(source, "features")) throw new Error("expected split matrix schema version 4");
const featureDir = resolve(sourcePath, "features");
source.features = readdirSync(featureDir).sort().map((name) => {
  if (!/^[a-z0-9]+(?:-[a-z0-9]+)*\.json$/.test(name)) throw new Error(`invalid feature filename: ${name}`);
  const feature = JSON.parse(readFileSync(resolve(featureDir, name), "utf8"));
  if (`${feature.id}.json` !== name) throw new Error(`feature ID must match filename: ${name}`);
  return feature;
});
const statusDefinitions = source.statusDefinitions;
const implementationDefinitions = statusDefinitions?.implementation;
const verificationDefinitions = statusDefinitions?.verification;
const features = source.features;

const validateDefinitions = (kind, definitions) => {
  if (!definitions || typeof definitions !== "object" || Array.isArray(definitions) || Object.keys(definitions).length === 0) {
    throw new Error(`${kind} status definitions must be a non-empty object`);
  }
  for (const [status, definition] of Object.entries(definitions)) {
    if (!definition || typeof definition.label !== "string" || !definition.label || typeof definition.icon !== "string" || !definition.icon || typeof definition.description !== "string" || !definition.description) {
      throw new Error(`invalid ${kind} status definition: ${status}`);
    }
  }
};

validateDefinitions("implementation", implementationDefinitions);
validateDefinitions("verification", verificationDefinitions);

if (!Array.isArray(features) || features.length === 0) {
  throw new Error("platform feature matrix must contain at least one feature");
}

const ids = new Set();
for (const feature of features) {
  if (!feature.id || ids.has(feature.id)) throw new Error(`duplicate or missing feature id: ${feature.id}`);
  if (!feature.area || !feature.group || !feature.capability || !feature.owner || !feature.verification) {
    throw new Error(`missing capability metadata for ${feature.id}`);
  }
  if (feature.notes !== undefined && (typeof feature.notes !== "string" || !feature.notes)) {
    throw new Error(`invalid notes for ${feature.id}`);
  }
  ids.add(feature.id);
  for (const platform of ["macos", "windows"]) {
    const entry = feature[platform];
    if (!entry || !Object.hasOwn(implementationDefinitions, entry.implementationStatus) || !Object.hasOwn(verificationDefinitions, entry.verificationStatus) || !Array.isArray(entry.evidence) || entry.evidence.length === 0) {
      throw new Error(`invalid ${platform} entry for ${feature.id}`);
    }
    for (const evidencePath of entry.evidence) {
      if (!existsSync(resolve(root, evidencePath))) throw new Error(`missing evidence path: ${evidencePath}`);
    }
  }
}

const renderStatusDefinitionTable = (definitions) => [
  "| 状态 | 含义 |",
  "| --- | --- |",
  ...Object.entries(definitions).map(([status, definition]) => `| ${definition.icon} ${definition.label}<br><sub>${status}</sub> | ${definition.description} |`)
];
const renderStatus = (entry) => {
  const implementation = implementationDefinitions[entry.implementationStatus];
  const verification = verificationDefinitions[entry.verificationStatus];
  return `${implementation.icon} ${implementation.label}<br><sub>${verification.icon} ${verification.label}</sub>`;
};
const renderEvidence = (entry) => entry.evidence.map((path) => `\`${path}\``).join("、");
const countStatuses = (platform, field, definitions) => {
  const counts = Object.fromEntries(Object.keys(definitions).map((status) => [status, 0]));
  for (const feature of features) counts[feature[platform][field]] += 1;
  return Object.entries(definitions).map(([status, definition]) => `${definition.icon} ${counts[status]} ${definition.label}`).join("，");
};
const renderCounts = (platform) => `实现：${countStatuses(platform, "implementationStatus", implementationDefinitions)}；验证：${countStatuses(platform, "verificationStatus", verificationDefinitions)}`;
const areaGroups = [];
for (const feature of features) {
  let areaGroup = areaGroups.find((group) => group.area === feature.area);
  if (!areaGroup) {
    areaGroup = { area: feature.area, features: [] };
    areaGroups.push(areaGroup);
  }
  areaGroup.features.push(feature);
}
const renderFeatureRow = (feature) => `| ${feature.group} | **${feature.capability}**<br><sub>${feature.id}</sub> | ${renderStatus(feature.macos)}<br><sub>${renderEvidence(feature.macos)}</sub> | ${renderStatus(feature.windows)}<br><sub>${renderEvidence(feature.windows)}</sub> | ${feature.owner} | ${feature.verification} | ${feature.notes ?? ""} |`;
const areaSections = areaGroups.flatMap(({ area, features: areaFeatures }) => [
  "<details>",
  `<summary><strong>${area}</strong> · ${areaFeatures.length} 个能力点</summary>`,
  "",
  "| 功能组 | 能力点 | macOS | Windows | 负责人 | 验证方式 | 备注 |",
  "| --- | --- | --- | --- | --- | --- | --- |",
  ...areaFeatures.map(renderFeatureRow),
  "",
  "</details>",
  ""
]);

const markdown = [
  "# macOS / Windows 功能对齐矩阵",
  "",
  "> 本页由 `shared/platform-feature-matrix/features/*.json` 自动生成。不要直接编辑本文件；新增或变更功能时更新源数据，再运行 `node scripts/generate-platform-feature-matrix.mjs`。",
  "",
  `- 最后复核：${source.lastReviewed}`,
  `- 盘点状态：${source.review.status}（${source.review.method}）`,
  `- 功能项：${features.length}`,
  `- macOS：${renderCounts("macos")}`,
  `- Windows：${renderCounts("windows")}`,
  "",
  "## 实现状态定义",
  "",
  ...renderStatusDefinitionTable(implementationDefinitions),
  "",
  "## 验证状态定义",
  "",
  ...renderStatusDefinitionTable(verificationDefinitions),
  "",
  "## 功能矩阵",
  "",
  "> 每一行对应一个可以单独验收的用户能力；区域和功能组只用于导航，不作为状态统计单位。单元格第一行是实现状态，第二行是验证状态。",
  "",
  ...areaSections,
  "",
  "## 使用规则",
  "",
  "1. 功能开发或修复的 PR 必须更新对应能力点的实现状态、验证状态、证据路径和验证方式；如果一项功能包含多个独立用户动作，应拆成多行。",
  "2. `implementationStatus` 和 `verificationStatus` 分别表达实现程度和运行验证结果；只有实现状态为 `implemented` 且验证状态为 `verified` 才能表示已完成验收。",
  "3. 代码入口存在但没有真实运行验证时，保留实现状态并将验证状态设为 `pending`；不要把静态盘点写成 `verified`。",
  "4. 新的共享行为先更新 `shared/contracts/` 和 fixture，再按验证方式完成两端验证后将验证状态推进到 `verified`。",
  "5. 功能 PR 必须同时包含源数据变更；纯重构如确实没有用户可观察变化，可由 reviewer 添加 `matrix-exempt` label 作为显式例外。",
].join("\n") + "\n";

const escapeCsv = (value) => {
  const text = String(value ?? "");
  return /[",\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
};
const csvHeader = ["id", "area", "feature group", "capability", "macOS implementation", "macOS verification", "Windows implementation", "Windows verification", "owner", "verification", "notes", "macOS evidence", "Windows evidence"];
const csvRows = features.map((feature) => [
  feature.id,
  feature.area,
  feature.group,
  feature.capability,
  implementationDefinitions[feature.macos.implementationStatus].label,
  verificationDefinitions[feature.macos.verificationStatus].label,
  implementationDefinitions[feature.windows.implementationStatus].label,
  verificationDefinitions[feature.windows.verificationStatus].label,
  feature.owner,
  feature.verification,
  feature.notes ?? "",
  feature.macos.evidence.join("; "),
  feature.windows.evidence.join("; ")
]);
const csv = [csvHeader, ...csvRows].map((row) => row.map(escapeCsv).join(",")).join("\n") + "\n";

// Escape every source string: PR-controlled capability text must remain inert in published HTML.
const escapeHtml = (value) => value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");
const renderPlatformHtml = (entry) => `<strong>${escapeHtml(implementationDefinitions[entry.implementationStatus].label)}</strong><br>${escapeHtml(verificationDefinitions[entry.verificationStatus].label)}<details><summary>证据路径</summary><pre>${escapeHtml(entry.evidence.join("\n"))}</pre></details>`;
const html = `<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Lithe 功能矩阵</title>
<style>body{font:16px system-ui;margin:2rem;line-height:1.6}table{border-collapse:collapse;width:100%}th,td{border:1px solid #888;padding:.5rem;text-align:left;vertical-align:top}pre{white-space:pre-wrap;overflow-wrap:anywhere}td{min-width:8rem}small{overflow-wrap:anywhere}.table{overflow-x:auto}</style>
<h1>Lithe 功能矩阵</h1><p>数据版本：${escapeHtml(process.env.GITHUB_SHA ?? "本地工作树")}</p>
<p><a href="platform-parity-matrix.md">Markdown</a> · <a href="platform-parity-matrix.csv">CSV</a> · <a href="platform-feature-matrix.json">JSON</a></p>
<p>macOS：${escapeHtml(renderCounts("macos"))}</p><p>Windows：${escapeHtml(renderCounts("windows"))}</p>
<p>实现状态与运行验证相互独立；代码存在不代表已通过实机验收。</p>
<div class="table"><table><thead><tr><th>分类</th><th>能力</th><th>macOS</th><th>Windows</th><th>负责人</th><th>验证方式 / 备注</th></tr></thead>
<tbody>${features.map((feature) => `<tr><td>${escapeHtml(feature.area)} / ${escapeHtml(feature.group)}</td><td>${escapeHtml(feature.capability)}<br><small>${escapeHtml(feature.id)}</small></td><td>${renderPlatformHtml(feature.macos)}</td><td>${renderPlatformHtml(feature.windows)}</td><td>${escapeHtml(feature.owner)}</td><td>${escapeHtml(feature.verification)}<br>${escapeHtml(feature.notes ?? "")}</td></tr>`).join("\n")}</tbody></table></div></html>\n`;
if (checkOnly) {
  console.log(`validated ${features.length} platform capabilities`);
} else {
  mkdirSync(outputDir, { recursive: true });
  writeFileSync(outputPath, markdown);
  writeFileSync(csvOutputPath, csv);
  writeFileSync(resolve(outputDir, "platform-feature-matrix.json"), JSON.stringify(source, null, 2) + "\n");
  writeFileSync(resolve(outputDir, "index.html"), html);
  console.log(`generated matrix views in ${outputDir}`);
}
