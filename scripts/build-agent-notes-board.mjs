#!/usr/bin/env node

import {
    existsSync,
    mkdirSync,
    readdirSync,
    readFileSync,
    writeFileSync,
} from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import parser from "./agent-notes-parser.mjs";

const __filename = fileURLToPath(import.meta.url);
const rootDir = resolve(dirname(__filename), "..");
const templatePath = resolve(rootDir, "assets/agent-notes-board.html");
const parserPath = resolve(dirname(__filename), "agent-notes-parser.mjs");
const logoPath = resolve(rootDir, "macos/Resources/AppIcon.png");
const args = process.argv.slice(2);

const isInitMode = args.includes("--init");
const isBundleMode = args.includes("--bundle");
const isForce = args.includes("--force") || args.includes("-f");
const isMetadataOnly = args.includes("--metadata-only");
const cleanArgs = args.filter((arg) => !arg.startsWith("--") && !arg.startsWith("-"));

const LIFECYCLES = new Set(["implemented", "proposed", "rejected", "archived"]);

function usage() {
    console.error(
        [
            "用法：",
            "  node scripts/build-agent-notes-board.mjs --init [输出路径] [项目名称]",
            "  node scripts/build-agent-notes-board.mjs --bundle [Note目录] [输出路径] [项目名称]",
            "",
            "可选参数：--metadata-only、--force",
        ].join("\n"),
    );
    process.exit(1);
}

function escapeHtml(value) {
    return String(value)
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;")
        .replaceAll("'", "&#39;");
}

function checkTargetSafety(targetPath) {
    if (!existsSync(targetPath) || isForce) return;
    try {
        const existing = readFileSync(targetPath, "utf8");
        const isBoard =
            existing.includes('generator" content="agent-notes-board"') ||
            existing.includes('id="brand-project-title"');
        if (!isBoard) {
            console.error(`目标文件已存在且不是 Lithe Agent Notes 看板：${targetPath}`);
            console.error("请指定其他输出路径，或传入 --force 确认覆盖。");
            process.exit(1);
        }
    } catch {
        // The write below will report an ordinary filesystem error.
    }
}

function ensureParentDirectory(path) {
    mkdirSync(dirname(path), { recursive: true });
}

function walkNoteFiles(notesDir) {
    const files = new Map();

    function scan(currentDir) {
        for (const entry of readdirSync(currentDir, { withFileTypes: true })) {
            if (entry.name.startsWith(".")) continue;
            const fullPath = join(currentDir, entry.name);
            if (entry.isDirectory()) {
                scan(fullPath);
                continue;
            }
            if (!entry.isFile() || !entry.name.endsWith(".md")) continue;

            const relPath = relative(notesDir, fullPath).replaceAll("\\", "/");
            const parts = relPath.split("/");
            if (parts.length !== 3 || !LIFECYCLES.has(parts[0])) continue;
            files.set(relPath, fullPath);
        }
    }

    scan(notesDir);
    return files;
}

function parseNotes(notesDir) {
    const noteFiles = walkNoteFiles(notesDir);
    const slugToId = new Map();

    for (const relPath of noteFiles.keys()) {
        const slug = relPath.split("/").pop().replace(/\.md$/, "");
        slugToId.set(relPath, relPath);
        slugToId.set(slug, relPath);
    }

    const notes = [];
    for (const [relPath, fullPath] of noteFiles.entries()) {
        try {
            notes.push(parser.parseNote(readFileSync(fullPath, "utf8"), relPath, slugToId));
        } catch (error) {
            console.warn(`跳过无法读取的 Note ${relPath}:`, error);
        }
    }
    return notes.sort((left, right) => left.id.localeCompare(right.id));
}

function redactNotes(notes) {
    return notes.map((note) => ({
        ...note,
        problem: "[正文已脱敏]",
        decision: "[正文已脱敏]",
        alternatives: "",
        consequences: "",
        rawBody: `# Agent 笔记：${note.title}\n\n状态：${note.statusText}\n\n<!-- content redacted -->`,
    }));
}

function readBrowserParserSource() {
    return readFileSync(parserPath, "utf8").replace(
        /^\s*export default LitheAgentNotesParser;\s*$/m,
        "",
    );
}

function readLogoDataUri() {
    if (!existsSync(logoPath)) {
        throw new Error(`Lithe Logo 不存在：${logoPath}`);
    }
    return `data:image/png;base64,${readFileSync(logoPath).toString("base64")}`;
}

function renderTemplate(projectName, notes = null) {
    let template = readFileSync(templatePath, "utf8");
    const safeProjectName = escapeHtml(projectName);

    template = template.replace(
        "<title>Lithe 工程决策看板</title>",
        `<title>${safeProjectName}</title>`,
    );
    template = template.replace(
        'id="brand-project-title">Lithe 工程决策看板<',
        `id="brand-project-title">${safeProjectName}<`,
    );
    template = template.replace("__LITHE_AGENT_NOTES_LOGO__", readLogoDataUri());
    template = template.replace(
        "/* __LITHE_AGENT_NOTES_PARSER__ */",
        readBrowserParserSource(),
    );

    if (notes) {
        const json = JSON.stringify(notes).replaceAll("<", "\\u003c");
        template = template.replace(
            "window.__INLINE_DATA__ = null;",
            `window.__INLINE_DATA__ = ${json};`,
        );
    }
    return template;
}

function build() {
    if (!existsSync(templatePath)) {
        console.error(`看板模板不存在：${templatePath}`);
        process.exit(1);
    }
    if (!isInitMode && !isBundleMode) usage();
    if (isInitMode && isBundleMode) {
        console.error("--init 和 --bundle 只能选择一个。");
        process.exit(1);
    }

    if (isInitMode) {
        const targetPath = resolve(cleanArgs[0] || join(rootDir, "board.html"));
        const projectName = cleanArgs[1] || "Lithe 工程决策看板";
        checkTargetSafety(targetPath);
        ensureParentDirectory(targetPath);
        writeFileSync(targetPath, renderTemplate(projectName), "utf8");
        console.log(`已生成本地开发看板：${targetPath}`);
        console.log("打开页面后选择项目根目录，浏览器会读取 .agents/notes 并定时刷新。");
        return;
    }

    const notesDir = resolve(cleanArgs[0] || join(rootDir, ".agents/notes"));
    const outputPath = resolve(cleanArgs[1] || join(rootDir, "demo.html"));
    const projectName = cleanArgs[2] || "Lithe 工程决策看板";
    if (!existsSync(notesDir)) {
        console.error(`Note 目录不存在：${notesDir}`);
        process.exit(1);
    }

    checkTargetSafety(outputPath);
    const notes = parseNotes(notesDir);
    const outputNotes = isMetadataOnly ? redactNotes(notes) : notes;
    ensureParentDirectory(outputPath);
    writeFileSync(outputPath, renderTemplate(projectName, outputNotes), "utf8");
    console.log(`已解析 ${notes.length} 篇 Note，生成看板：${outputPath}`);
    if (isMetadataOnly) {
        console.log("已启用 --metadata-only，仅发布元数据和引用关系。");
    }
}

build();
