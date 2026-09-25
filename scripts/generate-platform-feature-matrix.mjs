#!/usr/bin/env node

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const sourcePath = resolve(root, "shared/platform-feature-matrix.json");
const outputPath = resolve(root, "docs/development/platform-parity-matrix.md");
const csvOutputPath = resolve(root, "docs/development/platform-parity-matrix.csv");
const checkOnly = process.argv.includes("--check");
const source = JSON.parse(readFileSync(sourcePath, "utf8"));
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
const renderFeatureRow = (feature) => `| ${feature.group} | **${feature.capability}**<br><sub>${feature.id}</sub> | ${renderStatus(feature.macos)}<br><sub>${renderEvidence(feature.macos)}</sub> | ${renderStatus(feature.windows)}<br><sub>${renderEvidence(feature.windows)}</sub> | ${feature.owner} | ${feature.verification} |`;
const areaSections = areaGroups.flatMap(({ area, features: areaFeatures }) => [
  "<details>",
  `<summary><strong>${area}</strong> · ${areaFeatures.length} 个能力点</summary>`,
  "",
  "| 功能组 | 能力点 | macOS | Windows | 负责人 | 验证方式 |",
  "| --- | --- | --- | --- | --- | --- |",
  ...areaFeatures.map(renderFeatureRow),
  "",
  "</details>",
  ""
]);

const markdown = [
  "# macOS / Windows 功能对齐矩阵",
  "",
  "> 本页由 `shared/platform-feature-matrix.json` 自动生成。不要直接编辑本文件；新增或变更功能时更新源数据，再运行 `node scripts/generate-platform-feature-matrix.mjs`。",
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
  "3. 代码入口存在但没有真实运行验证时，保留实现状态并将验证状态设为 `needs-verification`；不要把静态盘点写成 `verified`。",
  "4. 新的共享行为先更新 `shared/contracts/` 和 fixture，再按验证方式完成两端验证后将验证状态推进到 `verified`。",
  "5. 功能 PR 必须同时包含源数据变更；纯重构如确实没有用户可观察变化，可由 reviewer 添加 `matrix-exempt` label 作为显式例外。",
].join("\n") + "\n";

const escapeCsv = (value) => {
  const text = String(value ?? "");
  return /[",\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
};
const csvHeader = ["id", "area", "feature group", "capability", "macOS implementation", "macOS verification", "Windows implementation", "Windows verification", "owner", "verification", "macOS evidence", "Windows evidence"];
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
  feature.macos.evidence.join("; "),
  feature.windows.evidence.join("; ")
]);
const csv = [csvHeader, ...csvRows].map((row) => row.map(escapeCsv).join(",")).join("\n") + "\n";

if (checkOnly) {
  const existingMarkdown = readFileSync(outputPath, "utf8");
  const existingCsv = readFileSync(csvOutputPath, "utf8");
  if (existingMarkdown !== markdown) throw new Error(`generated Markdown is stale: ${outputPath}`);
  if (existingCsv !== csv) throw new Error(`generated CSV is stale: ${csvOutputPath}`);
  console.log("platform feature matrix is up to date");
} else {
  writeFileSync(outputPath, markdown);
  writeFileSync(csvOutputPath, csv);
  console.log(`generated ${outputPath}`);
  console.log(`generated ${csvOutputPath}`);
}
