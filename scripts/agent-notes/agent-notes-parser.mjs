const LitheAgentNotesParser = (() => {
const LIFECYCLES = ["implemented", "proposed", "rejected", "archived"];

function normalizeNotePath(path) {
    const parts = String(path).replaceAll("\\", "/").split("/");
    const normalized = [];
    for (const part of parts) {
        if (!part || part === ".") continue;
        if (part === "..") {
            normalized.pop();
            continue;
        }
        normalized.push(part);
    }
    return normalized.join("/");
}

function basename(path) {
    return normalizeNotePath(path).split("/").pop() ?? "";
}

function withoutExtension(path) {
    return path.replace(/\.md$/i, "");
}

function proseLines(input) {
    const lines = Array.isArray(input) ? input : String(input).split(/\r?\n/);
    let inFence = false;
    return lines.filter((line) => {
        if (line.startsWith("```")) {
            inFence = !inFence;
            return false;
        }
        return !inFence;
    });
}

function extractSection(input, headings) {
    const lines = Array.isArray(input) ? input : String(input).split(/\r?\n/);
    const accepted = new Set(
        (Array.isArray(headings) ? headings : [headings]).map((heading) =>
            heading.startsWith("## ") ? heading : `## ${heading}`,
        ),
    );
    const start = lines.findIndex((line) => accepted.has(line.trimEnd()));
    if (start === -1) return "";

    const section = [];
    for (let index = start + 1; index < lines.length; index += 1) {
        if (lines[index].startsWith("## ")) break;
        section.push(lines[index]);
    }
    return section.join("\n").trim();
}

function markdownLinks(raw) {
    const links = [];
    for (const match of String(raw).matchAll(/!?\[[^\]]*]\(([^)]+)\)/g)) {
        const href = match[1]?.trim() ?? "";
        if (!href || href.startsWith("#")) continue;
        if (/^[a-z][a-z0-9+.-]*:/i.test(href)) continue;
        links.push(href.split("#")[0].trim());
    }
    return links;
}

function titleFrom(raw, slug) {
    const h1 = /^#\s*(?:Agent 笔记|Agent Note)\s*[:：]\s*(.+?)\s*$/m.exec(raw);
    return h1?.[1]?.trim() || slug;
}

function sectionWithAliases(raw, aliases) {
    return extractSection(raw, aliases);
}

function resolveLink(noteRel, href, slugToId) {
    const candidate = normalizeNotePath(
        `${noteRel.split("/").slice(0, -1).join("/")}/${href}`,
    );
    if (slugToId.has(candidate)) return slugToId.get(candidate);

    const targetSlug = withoutExtension(basename(href));
    return slugToId.get(targetSlug) ?? "";
}

function parseNote(raw, relPath, slugToId = new Map()) {
    const id = normalizeNotePath(relPath);
    const fileName = basename(id);
    const slug = withoutExtension(fileName);
    const parts = id.split("/");
    const lifecycle = parts[0] ?? "";
    const cls = parts[1] || "architecture";
    const date = /^(\d{4}-\d{2}-\d{2})/.exec(slug)?.[1] ?? "";
    const statusLine = /^状态：(.+)$/m.exec(raw)?.[1]?.trim() ?? lifecycle;
    const outLinks = [];

    for (const href of markdownLinks(raw)) {
        if (!href.endsWith(".md")) continue;
        const target = resolveLink(id, href, slugToId);
        if (target && target !== id) outLinks.push(target);
    }

    return {
        id,
        slug,
        lifecycle,
        cls,
        date,
        title: titleFrom(raw, slug),
        status: lifecycle,
        statusText: statusLine,
        problem: sectionWithAliases(raw, ["问题", "Problem"]),
        decision: sectionWithAliases(raw, ["决策", "Decision", "Proposal", "提案"]),
        alternatives: sectionWithAliases(raw, [
            "考虑过的备选方案",
            "考虑过的替代方案",
            "Alternatives considered",
        ]),
        consequences: sectionWithAliases(raw, ["后果", "Consequences"]),
        outLinks: [...new Set(outLinks)],
        rawBody: raw,
    };
}

return {
    LIFECYCLES,
    basename,
    normalizeNotePath,
    proseLines,
    extractSection,
    markdownLinks,
    parseNote,
};
})();

if (typeof globalThis !== "undefined") {
    globalThis.LitheAgentNotesParser = LitheAgentNotesParser;
}

export default LitheAgentNotesParser;
