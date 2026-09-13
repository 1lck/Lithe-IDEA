#!/usr/bin/env node

import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import parser from "./agent-notes-parser.mjs";

const __filename = fileURLToPath(import.meta.url);
const rootDir = resolve(dirname(__filename), "..");
const notesRoot = resolve(rootDir, ".agents/notes");
const { extractSection, markdownLinks, proseLines } = parser;

const lifecycles = new Set(["proposed", "implemented", "rejected"]);
const allLifecycles = new Set(["implemented", "proposed", "rejected", "archived"]);
const classes = new Set(["feature", "bug-fix", "simplification", "architecture", "process", "testing"]);
const ignoredDirs = new Set([".git", ".build", ".swiftpm", ".artifacts", "target", "dist", "node_modules"]);

const statusByLifecycle = {
    proposed: /^状态：提议中$/,
    implemented: /^状态：已实现$/,
    rejected: /^状态：已否决：.+$/,
};

const requiredHeadings = {
    proposed: ["## 问题", "## 提案", "## 考虑过的备选方案", "## 验收标准", "## 风险", "## 适用范围"],
    implemented: ["## 问题", "## 决策", "## 考虑过的备选方案", "## 后果", "## 验证", "## 适用范围"],
    rejected: ["## 问题", "## 提案", "## 考虑过的备选方案", "## 否决理由", "## 适用范围"],
};

const errors = [];

function fail(scope, message) {
    errors.push(`${scope} — ${message}`);
}

function toRepoRelative(path) {
    return relative(rootDir, path).replaceAll("\\", "/");
}

function listMarkdownFiles(dir) {
    const files = [];
    if (!existsSync(dir)) return files;
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
        if (entry.name.startsWith(".")) continue;
        const path = join(dir, entry.name);
        if (entry.isDirectory()) {
            files.push(...listMarkdownFiles(path));
        } else if (entry.isFile() && entry.name.endsWith(".md")) {
            files.push(path);
        }
    }
    return files.sort((a, b) => a.localeCompare(b));
}

function isLifecycleGuide(path) {
    const relToNotesRoot = relative(notesRoot, path).replaceAll("\\", "/");
    const segments = relToNotesRoot.split("/");
    return segments.length === 2 && allLifecycles.has(segments[0]) && segments[1] === "AGENTS.md";
}

function listNoteMarkdownFiles(dir) {
    return listMarkdownFiles(dir).filter((path) => !isLifecycleGuide(path));
}

function validateRequiredStructure() {
    const requiredFiles = ["AGENTS.md", "README.md", "manifest.json"];
    for (const file of requiredFiles) {
        if (!existsSync(resolve(notesRoot, file))) {
            fail(`structure: .agents/notes/${file}`, "缺少 Note 目录入口文件");
        }
    }

    let manifest;
    try {
        manifest = JSON.parse(readFileSync(resolve(notesRoot, "manifest.json"), "utf8"));
    } catch (error) {
        fail("structure: .agents/notes/manifest.json", `manifest 不是合法 JSON：${error.message}`);
        manifest = {};
    }

    const expectedLifecycles = [...allLifecycles].sort();
    const expectedClasses = [...classes].sort();
    const manifestLifecycles = Array.isArray(manifest.lifecycles) ? [...manifest.lifecycles].sort() : [];
    const manifestClasses = Array.isArray(manifest.classes) ? [...manifest.classes].sort() : [];
    if (JSON.stringify(manifestLifecycles) !== JSON.stringify(expectedLifecycles)) {
        fail("structure: .agents/notes/manifest.json", "lifecycles 必须与校验脚本一致");
    }
    if (JSON.stringify(manifestClasses) !== JSON.stringify(expectedClasses)) {
        fail("structure: .agents/notes/manifest.json", "classes 必须与校验脚本一致");
    }

    for (const lifecycle of allLifecycles) {
        const lifecycleDir = resolve(notesRoot, lifecycle);
        if (!existsSync(lifecycleDir)) {
            fail(`structure: .agents/notes/${lifecycle}`, "缺少生命周期目录");
            continue;
        }
        if (!existsSync(resolve(lifecycleDir, "AGENTS.md"))) {
            fail(`structure: .agents/notes/${lifecycle}/AGENTS.md`, "缺少生命周期局部规则");
        }
        for (const cls of classes) {
            if (!existsSync(resolve(lifecycleDir, cls))) {
                fail(`structure: .agents/notes/${lifecycle}/${cls}`, "缺少分类目录");
            }
        }
    }
}

function globSegmentToRegExp(segment) {
    const escaped = segment.replace(/[.+^${}()|[\]\\]/g, "\\$&").replaceAll("*", ".*");
    return new RegExp(`^${escaped}$`);
}

function pathPatternExists(repoPattern) {
    const normalized = repoPattern.replace(/^\.\//, "").replace(/\/+$/, "");
    const requireDirectory = repoPattern.endsWith("/");
    const segments = normalized.split("/").filter(Boolean);
    let candidates = [rootDir];
    for (let index = 0; index < segments.length; index += 1) {
        const segment = segments[index];
        const isLast = index === segments.length - 1;
        const next = [];
        for (const base of candidates) {
            if (!existsSync(base)) continue;
            if (segment.includes("*")) {
                const pattern = globSegmentToRegExp(segment);
                for (const entry of readdirSync(base, { withFileTypes: true })) {
                    if (entry.name.startsWith(".")) continue;
                    if (!pattern.test(entry.name)) continue;
                    if (!isLast && !entry.isDirectory()) continue;
                    if (isLast && requireDirectory && !entry.isDirectory()) continue;
                    next.push(join(base, entry.name));
                }
            } else {
                const path = join(base, segment);
                if (!existsSync(path)) continue;
                if (!isLast && !statSync(path).isDirectory()) continue;
                if (isLast && requireDirectory && !statSync(path).isDirectory()) continue;
                next.push(path);
            }
        }
        candidates = next;
        if (candidates.length === 0) return false;
    }
    return candidates.length > 0;
}

function validateScopePaths(noteRel, lines) {
    const scope = extractSection(lines, "## 适用范围").split(/\r?\n/);
    for (const line of scope) {
        const match = /^\s*-\s+`([^`]+)`/.exec(line);
        if (!match) continue;
        const target = match[1].trim();
        if (!target || target.includes("<") || /^[a-z][a-z0-9+.-]*:/i.test(target)) continue;
        if (!pathPatternExists(target)) {
            fail(`scope: ${noteRel}`, `适用范围路径不存在：${target}`);
        }
    }
}

function validateVerificationCommands(noteRel, lines) {
    const verification = extractSection(lines, "## 验证").split(/\r?\n/);
    for (const line of verification) {
        for (const match of line.matchAll(/`([^`]+)`/g)) {
            const command = match[1].trim();
            const first = command.split(/\s+/)[0]?.replace(/^\.\//, "");
            if (!first) continue;
            if (!first.startsWith("scripts/") && !first.startsWith(".agents/")) continue;
            if (!existsSync(resolve(rootDir, first))) {
                fail(`verification: ${noteRel}`, `验证命令不存在：${first}`);
            }
        }
    }
}

function validateNote(path, lifecycle) {
    const noteRel = toRepoRelative(path);
    const relToNotesRoot = relative(notesRoot, path).replaceAll("\\", "/");
    const segments = relToNotesRoot.split("/");
    if (segments.length !== 3) {
        fail(`structure: ${noteRel}`, "路径必须是 {lifecycle}/{class}/yyyy-mm-dd-topic.md");
        return;
    }
    const cls = segments[1];
    const filename = segments[2];
    if (!classes.has(cls)) {
        fail(`structure: ${noteRel}`, `未知分类 ${cls}`);
    }
    if (!/^\d{4}-\d{2}-\d{2}-[a-z0-9][a-z0-9-]*\.md$/.test(filename)) {
        fail(`structure: ${noteRel}`, "文件名必须是 yyyy-mm-dd-topic.md，topic 使用小写英文、数字和连字符");
    }

    const raw = readFileSync(path, "utf8");
    const lines = proseLines(raw);
    if (!/^# Agent 笔记：\S/.test(lines[0] ?? "")) {
        fail(`format: ${noteRel}`, "第一行必须是 `# Agent 笔记：标题`");
    }
    if ((lines[1] ?? "") !== "") {
        fail(`format: ${noteRel}`, "第二行必须为空行");
    }
    if (!statusByLifecycle[lifecycle].test(lines[2] ?? "")) {
        fail(`format: ${noteRel}`, `第三行状态必须匹配 ${statusByLifecycle[lifecycle]}`);
    }
    if ((lines[3] ?? "") !== "") {
        fail(`format: ${noteRel}`, "第四行必须为空行");
    }

    const statusCount = lines.filter((line) => line.startsWith("状态：")).length;
    if (statusCount !== 1) {
        fail(`format: ${noteRel}`, "状态行必须且只能出现一次");
    }

    const headings = lines.filter((line) => line.startsWith("## ")).map((line) => line.trimEnd());
    if (headings[0] !== "## 先说结论" || headings[1] !== "## 问题") {
        fail(`format: ${noteRel}`, "正文必须先有 `## 先说结论`，然后进入 `## 问题`");
    }
    for (const heading of requiredHeadings[lifecycle]) {
        if (!headings.includes(heading)) {
            fail(`format: ${noteRel}`, `缺少章节：${heading}`);
        }
    }
    if (lifecycle === "implemented") {
        const banned = ["## 提案", "## 计划", "## 迁移计划", "## 验收标准", "## Proposal", "## Plan", "## Acceptance criteria"];
        for (const heading of headings) {
            if (banned.some((item) => heading.startsWith(item))) {
                fail(`format: ${noteRel}`, `已实现 Note 不应包含提案口吻章节：${heading}`);
            }
        }
    }

    for (const href of markdownLinks(raw)) {
        const target = resolve(dirname(path), decodeURI(href));
        if (!existsSync(target)) {
            fail(`links: ${noteRel}`, `Markdown 相对链接不存在：${href}`);
        }
        const targetRel = toRepoRelative(target);
        if (targetRel.startsWith(".agents/notes/archived/")) {
            fail(`links: ${noteRel}`, `active Note 不得把 archived Note 作为当前依据：${href}`);
        }
    }

    validateScopePaths(noteRel, lines);
    if (lifecycle === "implemented") {
        validateVerificationCommands(noteRel, lines);
    }
}

function validateArchivedNote(path) {
    const noteRel = toRepoRelative(path);
    const relToNotesRoot = relative(notesRoot, path).replaceAll("\\", "/");
    const segments = relToNotesRoot.split("/");
    if (segments.length !== 3 || segments[0] !== "archived" || !classes.has(segments[1])) {
        fail(`structure: ${noteRel}`, "归档路径必须是 archived/{class}/yyyy-mm-dd-topic.md");
        return;
    }
    const raw = readFileSync(path, "utf8");
    const lines = proseLines(raw);
    if (!/^# Agent 笔记：\S/.test(lines[0] ?? "")) {
        fail(`format: ${noteRel}`, "第一行必须是 `# Agent 笔记：标题`");
    }
    if (!/^状态：已实现$/.test(lines[2] ?? "")) {
        fail(`format: ${noteRel}`, "归档 Note 保留 `状态：已实现`");
    }
    if (!lines.some((line) => /^归档日期：\d{4}-\d{2}-\d{2}$/.test(line))) {
        fail(`format: ${noteRel}`, "归档 Note 必须包含 `归档日期：yyyy-mm-dd`");
    }
}

if (!existsSync(notesRoot)) {
    console.log("ok: .agents/notes 不存在，跳过 Agent Note 校验");
    process.exit(0);
}

validateRequiredStructure();

for (const entry of readdirSync(notesRoot, { withFileTypes: true })) {
    if (entry.name === "INDEX.md") {
        fail("structure: .agents/notes/INDEX.md", "禁止集中索引；按生命周期和分类检索");
    }
    if (entry.name.startsWith(".")) continue;
    if (entry.isDirectory() && !allLifecycles.has(entry.name)) {
        fail(`structure: .agents/notes/${entry.name}`, "未知生命周期目录");
    }
}

for (const lifecycle of lifecycles) {
    const lifecycleDir = resolve(notesRoot, lifecycle);
    for (const path of listNoteMarkdownFiles(lifecycleDir)) {
        validateNote(path, lifecycle);
    }
}

for (const path of listNoteMarkdownFiles(resolve(notesRoot, "archived"))) {
    validateArchivedNote(path);
}

if (errors.length > 0) {
    for (const error of errors) {
        console.error(error);
    }
    process.exit(1);
}

const count = [...lifecycles]
    .flatMap((lifecycle) => listNoteMarkdownFiles(resolve(notesRoot, lifecycle)))
    .length;
console.log(`ok: ${count} active Agent Note(s) verified`);
