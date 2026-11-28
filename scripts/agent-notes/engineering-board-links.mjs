// Reference scanning and relation building for the engineering board.
//
// The build scripts use this module to compute the links between PRs, Issues and Agent Notes,
// and the board page inlines the same source to turn references in PR, Issue and Note text
// into chips, so a reference is resolved the same way in both places. It therefore must not
// import anything and must stay valid as a classic browser script once the trailing export is
// removed.
const LitheEngineeringBoardLinks = (() => {
const NOTE_ROOT = ".agents/notes/";
const NOTE_LIFECYCLES = ["implemented", "proposed", "rejected", "archived"];
const NOTE_PATH_RE = /\.agents\/notes\/((?:implemented|proposed|rejected|archived)\/[a-z0-9-]+\/[\w.-]+\.md)/g;

// Lower rank wins when two sources relate the same pair.
const REL_RANK = { closes: 0, A: 1, R: 2, M: 3, D: 3, refs: 4, body: 5, mention: 6 };

const CLOSE_VERB_RE = /(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s*:?\s*$/i;
const REFS_VERB_RE = /(?:refs?|references|part of|related to|关联|相关)\s*:?\s*$/i;

function itemKey(repo, number) {
    return `${repo}#${number}`;
}

function noteKey(id) {
    return `note:${id}`;
}

function escapeRegExp(value) {
    return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// Builds the resolver for repository prefixes. `prefixes` are words written before a
// reference, such as "Core #12"; a space between the word and "#" is allowed. Every
// repository can also be written as "<name>#12", and a lithe-plugin-* repository as
// "<plugin>#12" (for example "java#5"), without a space.
function createRefScanner({ repos = [], prefixes = {} } = {}) {
    const canonical = new Map();
    const shortNames = new Map();
    for (const repo of repos) {
        canonical.set(repo.toLowerCase(), repo);
        const name = repo.split("/")[1] ?? "";
        shortNames.set(name.toLowerCase(), repo);
        const plugin = /^lithe-plugin-(.+)$/i.exec(name);
        if (plugin) shortNames.set(plugin[1].toLowerCase(), repo);
    }
    const spaced = new Map(Object.entries(prefixes).map(([word, repo]) => [word.toLowerCase(), repo]));
    for (const word of spaced.keys()) shortNames.delete(word);

    const byLength = (a, b) => b.length - a.length;
    const spacedWords = [...spaced.keys()].sort(byLength).map(escapeRegExp);
    const shortWords = [...shortNames.keys()].sort(byLength).map(escapeRegExp);

    const patterns = [
        {
            re: /https?:\/\/github\.com\/([\w.-]+)\/([\w.-]+)\/(?:pull|issues)\/(\d+)(?:[/#?][^\s)<>\]"'`]*)?/g,
            resolve: (m) => [resolveRepo(`${m[1]}/${m[2]}`), m[3]],
        },
        {
            re: /(?<![\w./-])([\w.-]+)\/([\w.-]+)#(\d+)\b/g,
            resolve: (m) => [resolveRepo(`${m[1]}/${m[2]}`), m[3]],
        },
    ];
    if (spacedWords.length) {
        patterns.push({
            re: new RegExp(`(?<![\\w-])(${spacedWords.join("|")}) ?#(\\d+)\\b`, "gi"),
            resolve: (m) => [spaced.get(m[1].toLowerCase()), m[2]],
        });
    }
    if (shortWords.length) {
        patterns.push({
            re: new RegExp(`(?<![\\w./-])(${shortWords.join("|")})#(\\d+)\\b`, "gi"),
            resolve: (m) => [shortNames.get(m[1].toLowerCase()), m[2]],
        });
    }
    patterns.push({
        re: /(?<![\w&#/])#(\d{1,6})\b/g,
        resolve: (m, ctxRepo) => [ctxRepo, m[1]],
    });

    function resolveRepo(full) {
        return canonical.get(full.toLowerCase()) ?? full;
    }

    function verbBefore(text, index) {
        const before = text.slice(Math.max(0, index - 24), index);
        if (CLOSE_VERB_RE.test(before)) return "closes";
        if (REFS_VERB_RE.test(before)) return "refs";
        return "mention";
    }

    // Returns non-overlapping references in text order. A bare "#12" resolves to ctxRepo,
    // the repository the text belongs to; without ctxRepo bare numbers are skipped.
    function scan(text, ctxRepo = null) {
        const source = String(text ?? "");
        const found = [];
        for (const { re, resolve } of patterns) {
            re.lastIndex = 0;
            for (const m of source.matchAll(re)) {
                const [repo, number] = resolve(m, ctxRepo);
                if (!repo) continue;
                found.push({
                    index: m.index,
                    end: m.index + m[0].length,
                    text: m[0],
                    repo,
                    number: Number(number),
                    verb: verbBefore(source, m.index),
                });
            }
        }
        found.sort((a, b) => a.index - b.index || b.end - a.end);
        const result = [];
        let reached = -1;
        for (const ref of found) {
            if (ref.index < reached) continue;
            result.push(ref);
            reached = ref.end;
        }
        return result;
    }

    return { scan };
}

// Text that GitHub does not render as a reference: HTML comments (the PR template's hints)
// and fenced code blocks.
function stripNonProse(text) {
    return String(text ?? "")
        .replace(/<!--[\s\S]*?-->/g, " ")
        .replace(/^\s*```[\s\S]*?^\s*```\s*$/gm, " ");
}

function notePathsIn(text) {
    const ids = new Set();
    for (const m of String(text ?? "").matchAll(NOTE_PATH_RE)) ids.add(m[1]);
    return [...ids];
}

// GitHub does not link references inside inline code either ("Core PR `#215`" is not #215 of
// this repository). Note paths are usually written as code, so they are read before this.
function stripInlineCode(text) {
    return text.replace(/(`+)[^`\n]+?\1/g, " ");
}

function extractRefs(text, ctxRepo, scanner) {
    const prose = stripNonProse(text);
    return { refs: scanner.scan(stripInlineCode(prose), ctxRepo), notes: notePathsIn(prose) };
}

function relRank(rel) {
    return REL_RANK[rel] ?? 9;
}

// Relations between board entries. Keys are "owner/name#N" for PRs and Issues and
// "note:<id>" for Agent Notes. Each unordered pair keeps its strongest relation and the
// direction it was stated in: "closes" and "refs" go from the PR or Issue that wrote them,
// note history goes from the Note to the PR that changed it.
function createRelationSet() {
    const pairs = new Map();
    function add(from, to, rel) {
        if (!from || !to || from === to) return;
        const id = from < to ? `${from}\u0000${to}` : `${to}\u0000${from}`;
        const current = pairs.get(id);
        if (current && relRank(current[2]) <= relRank(rel)) return;
        pairs.set(id, [from, to, rel]);
    }
    function list() {
        return [...pairs.values()].sort((a, b) =>
            a[0].localeCompare(b[0]) || a[1].localeCompare(b[1]));
    }
    return { add, list };
}

// items: Map key -> { repo, number, kind, body, closing: [{repo, number}], crossRefs: [{repo, number}] }
// notes: [{ id, body, history: [{ pr: key | null, action }] }]
function buildRelations({ items, notes, scanner }) {
    const relations = createRelationSet();
    const noteIds = new Set(notes.map((note) => note.id));

    for (const [key, item] of items) {
        const { refs, notes: notePaths } = extractRefs(item.body, item.repo, scanner);
        for (const ref of refs) {
            const target = itemKey(ref.repo, ref.number);
            if (items.has(target)) relations.add(key, target, ref.verb);
        }
        for (const id of notePaths) {
            if (noteIds.has(id)) relations.add(key, noteKey(id), "body");
        }
        for (const ref of item.closing ?? []) {
            const target = itemKey(ref.repo, ref.number);
            if (items.has(target)) relations.add(key, target, "closes");
        }
        for (const ref of item.crossRefs ?? []) {
            const source = itemKey(ref.repo, ref.number);
            if (items.has(source)) relations.add(source, key, "mention");
        }
    }

    for (const note of notes) {
        const key = noteKey(note.id);
        for (const event of note.history) {
            if (event.pr && items.has(event.pr)) relations.add(key, event.pr, event.action);
        }
        const { refs, notes: notePaths } = extractRefs(note.body, note.repo, scanner);
        for (const ref of refs) {
            const target = itemKey(ref.repo, ref.number);
            if (items.has(target)) relations.add(key, target, "mention");
        }
        for (const id of notePaths) {
            if (noteIds.has(id) && id !== note.id) relations.add(key, noteKey(id), "mention");
        }
    }
    return relations.list();
}

function notePathId(path) {
    if (!path.startsWith(NOTE_ROOT)) return null;
    const id = path.slice(NOTE_ROOT.length);
    const parts = id.split("/");
    if (parts.length !== 3 || !NOTE_LIFECYCLES.includes(parts[0]) || !parts[2].endsWith(".md")) {
        return null;
    }
    return id;
}

function prFromSubject(subject) {
    const squash = /\(#(\d+)\)\s*$/.exec(subject);
    if (squash) return Number(squash[1]);
    const merge = /^Merge pull request #(\d+) from /.exec(subject);
    return merge ? Number(merge[1]) : null;
}

// Parses `git log --first-parent --diff-merges=first-parent -M --name-status
// --format=@@%H%x09%as%x09%s -- .agents/notes`, newest commit first. Renames are followed
// back, so a Note moved from implemented/ to archived/ keeps the commits that created it.
// Returns Map currentId -> events, newest first.
function parseNoteHistory(logText, currentIds) {
    const alias = new Map([...currentIds].map((id) => [id, id]));
    const history = new Map();
    let commit = null;

    const record = (id, event) => {
        if (!history.has(id)) history.set(id, []);
        const events = history.get(id);
        if (events.some((e) => e.sha === event.sha)) return;
        events.push(event);
    };

    for (const rawLine of String(logText).split("\n")) {
        const line = rawLine.replace(/\r$/, "");
        if (line.startsWith("@@")) {
            const [sha, date, ...subject] = line.slice(2).split("\t");
            const text = subject.join("\t");
            commit = { sha, date, subject: text, prNumber: prFromSubject(text) };
            continue;
        }
        if (!commit || !line.trim()) continue;
        const fields = line.split("\t");
        const status = fields[0]?.[0];
        if (status === "R" || status === "C") {
            const fromId = notePathId(fields[1] ?? "");
            const toId = notePathId(fields[2] ?? "");
            const current = toId ? alias.get(toId) : undefined;
            if (!current) continue;
            if (status === "R" && fromId) alias.set(fromId, current);
            record(current, {
                ...commit,
                action: status === "R" ? "R" : "A",
                from: status === "R" ? fromId : null,
            });
            continue;
        }
        if (!"AMDT".includes(status ?? "x")) continue;
        const id = notePathId(fields[1] ?? "");
        const current = id ? alias.get(id) : undefined;
        if (!current) continue;
        record(current, { ...commit, action: status === "T" ? "M" : status, from: null });
    }
    return history;
}

return {
    NOTE_LIFECYCLES,
    REL_RANK,
    itemKey,
    noteKey,
    relRank,
    createRefScanner,
    stripNonProse,
    notePathsIn,
    extractRefs,
    createRelationSet,
    buildRelations,
    notePathId,
    prFromSubject,
    parseNoteHistory,
};
})();

if (typeof globalThis !== "undefined") {
    globalThis.LitheEngineeringBoardLinks = LitheEngineeringBoardLinks;
}

export default LitheEngineeringBoardLinks;
