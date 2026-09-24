#!/usr/bin/env node

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const sourcePath = resolve(root, "shared/platform-feature-matrix.json");
const outputPath = resolve(root, "docs/development/platform-parity-matrix.md");
const csvOutputPath = resolve(root, "docs/development/platform-parity-matrix.csv");
const checkOnly = process.argv.includes("--check");
const source = JSON.parse(readFileSync(sourcePath, "utf8"));
const allowedStatuses = new Set(Object.keys(source.statusDefinitions));
const features = source.features;

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
    if (!entry || !allowedStatuses.has(entry.status) || !Array.isArray(entry.evidence) || entry.evidence.length === 0) {
      throw new Error(`invalid ${platform} entry for ${feature.id}`);
    }
    for (const evidencePath of entry.evidence) {
      if (!existsSync(resolve(root, evidencePath))) throw new Error(`missing evidence path: ${evidencePath}`);
    }
  }
}

const statusLabel = {
  implemented: "已实现",
  partial: "部分实现",
  missing: "未实现",
  "needs-verification": "待验证",
  "platform-specific": "平台专属"
};
const statusIcon = {
  implemented: "✅",
  partial: "🟡",
  missing: "❌",
  "needs-verification": "🔍",
  "platform-specific": "🧩"
};
const renderStatus = (entry) => `${statusIcon[entry.status]} ${statusLabel[entry.status]}`;
const renderEvidence = (entry) => entry.evidence.map((path) => `\`${path}\``).join("、");
const platformCounts = Object.fromEntries(["macos", "windows"].map((platform) => [
  platform,
  Object.fromEntries(Object.keys(statusLabel).map((status) => [status, 0]))
]));
for (const feature of features) {
  platformCounts.macos[feature.macos.status] += 1;
  platformCounts.windows[feature.windows.status] += 1;
}
const renderCounts = (platform) => {
  const counts = platformCounts[platform];
  return `✅ ${counts.implemented} 已实现，🟡 ${counts.partial} 部分实现，❌ ${counts.missing} 未实现，🔍 ${counts["needs-verification"]} 待验证，🧩 ${counts["platform-specific"]} 平台专属`;
};
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
  `- 功能项：${features.length}`,
  `- macOS：${renderCounts("macos")}`,
  `- Windows：${renderCounts("windows")}`,
  "",
  "## 状态定义",
  "",
  "| 状态 | 含义 |",
  "| --- | --- |",
  ...Object.entries(source.statusDefinitions).map(([status, description]) => `| ${statusIcon[status]} ${statusLabel[status]} | ${description} |`),
  "",
  "## 功能矩阵",
  "",
  "> 每一行对应一个可以单独验收的用户能力；区域和功能组只用于导航，不作为状态统计单位。",
  "",
  ...areaSections,
  "",
  "## 使用规则",
  "",
  "1. 功能开发或修复的 PR 必须更新对应能力点的状态、证据路径和验证方式；如果一项功能包含多个独立用户动作，应拆成多行。",
  "2. `已实现` 只表示两端都有代码入口和产品接入，不等于本机已经完成跨平台运行验证；真实运行结果用 `待验证` 或 PR 验证记录补充。",
  "3. 新的共享行为先更新 `shared/contracts/` 和 fixture，再把矩阵状态从 `待验证` 推进到 `已实现`。",
  "4. 每次发布前生成此页并检查 `未实现`、`部分实现` 和 `待验证` 项，避免 macOS 新功能无意中成为 Windows 隐藏缺口。",
].join("\n") + "\n";

const escapeCsv = (value) => {
  const text = String(value ?? "");
  return /[",\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
};
const csvHeader = ["id", "area", "feature group", "capability", "macOS", "Windows", "owner", "verification", "macOS evidence", "Windows evidence"];
const csvRows = features.map((feature) => [
  feature.id,
  feature.area,
  feature.group,
  feature.capability,
  statusLabel[feature.macos.status],
  statusLabel[feature.windows.status],
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
