// Assembles the engineering board data: Agent Notes from the working tree, their delivery
// history from Git, and the PR and Issue records from the GitHub cache, joined by the
// relations in engineering-board-links.mjs.
//
// The result is an index (everything the lists, filters and relation lanes need) and body
// shards that the page loads when a PR or Issue is opened, so the first load stays small.
import { execFileSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import parser from "./agent-notes-parser.mjs";
import links from "./engineering-board-links.mjs";
import * as github from "./engineering-board-github.mjs";

const scriptDir = dirname(fileURLToPath(import.meta.url));
export const ROOT_DIR = resolve(scriptDir, "../..");
export const TEMPLATE_PATH = resolve(ROOT_DIR, "assets/agent-notes-board.html");
export const DEFAULT_CACHE_PATH = resolve(ROOT_DIR, ".artifacts/agent-notes-board/cache/github.json");
const LINKS_PATH = resolve(scriptDir, "engineering-board-links.mjs");
export const LOGO_PATH = resolve(ROOT_DIR, "desktop/assets/icon.png");

export const BOARD_SCHEMA = 1;
export const SHARD_SIZE = 100;

export const BOARD_CONFIG = {
    primaryRepo: "1lck/Lithe-IDEA",
    // Every public, unarchived repository of these organizations is followed.
    orgs: ["Lithe-IDEA"],
    // Words written before a reference to point it at another repository, as in "Core #12".
    prefixes: {
        core: "Lithe-IDEA/Lithe-core-rust",
        store: "Lithe-IDEA/Lithe-store",
        fork: "Lithe-IDEA/Lithe-viva",
        "上游": "vivaui/viva",
        "桌面": "1lck/Lithe-IDEA",
        "主仓库": "1lck/Lithe-IDEA",
    },
    labels: {
        "1lck/Lithe-IDEA": "Lithe",
        "Lithe-IDEA/Lithe-core-rust": "Core",
        "Lithe-IDEA/Lithe-store": "Store",
        "Lithe-IDEA/Lithe-viva": "Viva fork",
    },
};

export function repoInfo(full, config = BOARD_CONFIG) {
    const name = full.split("/")[1] ?? full;
    const plugin = /^lithe-plugin-(.+)$/.exec(name);
    let role = "other";
    if (full === config.primaryRepo) role = "app";
    else if (full === config.prefixes.core) role = "core";
    else if (full === config.prefixes.store) role = "store";
    else if (full === config.prefixes.fork) role = "fork";
    else if (plugin) role = "plugin";
    return {
        full,
        label: config.labels[full] ?? (plugin ? plugin[1] : name),
        role,
        url: `https://github.com/${full}`,
    };
}

// Every name shardName returns matches SHARD_NAME; the local server serves nothing else.
export const SHARD_NAME = /^[A-Za-z0-9_-]+--\d+\.json$/;

export function shardName(repo, number) {
    const safe = repo.replace(/[^A-Za-z0-9_-]/g, "_");
    return `${safe}--${Math.floor(number / SHARD_SIZE)}.json`;
}

function walkNoteFiles(notesDir) {
    const files = new Map();
    const scan = (dir) => {
        for (const entry of readdirSync(dir, { withFileTypes: true })) {
            if (entry.name.startsWith(".")) continue;
            const full = join(dir, entry.name);
            if (entry.isDirectory()) {
                scan(full);
                continue;
            }
            if (!entry.isFile() || !entry.name.endsWith(".md")) continue;
            const rel = relative(notesDir, full).replaceAll("\\", "/");
            const parts = rel.split("/");
            if (parts.length === 3 && links.NOTE_LIFECYCLES.includes(parts[0])) files.set(rel, full);
        }
    };
    if (existsSync(notesDir)) scan(notesDir);
    return files;
}

function rejectionReason(note) {
    const status = note.statusText.replace(/^(?:已否决|rejected)\s*[—–:：-]?\s*/i, "").trim();
    return status && status !== note.statusText ? status : note.problem;
}

// Reads every Note from the working tree, including uncommitted edits.
export function collectNotes(rootDir) {
    const files = walkNoteFiles(join(rootDir, ".agents/notes"));
    const slugToId = new Map();
    for (const rel of files.keys()) {
        slugToId.set(rel, rel);
        slugToId.set(rel.split("/").pop().replace(/\.md$/, ""), rel);
    }
    const notes = [];
    for (const [rel, full] of files) {
        const raw = readFileSync(full, "utf8");
        const { rawBody, status, ...note } = parser.parseNote(raw, rel, slugToId);
        notes.push({ ...note, raw, reason: note.lifecycle === "rejected" ? rejectionReason(note) : "" });
    }
    return notes.sort((a, b) => a.id.localeCompare(b.id));
}

// Commits on the first-parent line of `ref` that touched each Note. A shallow clone yields
// only the commits it has; the Pages workflow checks out the full history.
export function noteHistoryFromGit(rootDir, noteIds, ref = "HEAD") {
    const log = execFileSync("git", [
        "-C", rootDir, "log", ref, "--first-parent", "--diff-merges=first-parent", "-M",
        "--name-status", "--format=@@%H%x09%as%x09%s", "--", ".agents/notes",
    ], { encoding: "utf8", maxBuffer: 256 << 20 });
    return links.parseNoteHistory(log, noteIds);
}

// A commit counts as a PR's delivery when GitHub confirms that PR was merged as this exact
// commit, or when the commit subject is the PR title followed by "(#N)" (a PR closed after its
// change was committed to main by hand). Any other "(#N)" stays a plain commit.
function deliveryPr(event, items, primaryRepo) {
    if (!event.prNumber) return null;
    const key = links.itemKey(primaryRepo, event.prNumber);
    const pr = items.get(key);
    if (!pr || pr.kind !== "pr") return null;
    if (pr.state === "MERGED" && (!pr.mergeCommit || pr.mergeCommit === event.sha)) return key;
    const title = event.subject.replace(/\s*\(#\d+\)\s*$/, "").trim();
    return title && title === pr.title.trim() ? key : null;
}

function compactItem(item) {
    const out = {
        k: links.itemKey(item.repo, item.number),
        repo: item.repo,
        n: item.number,
        kind: item.kind,
        title: item.title,
        state: item.state,
        author: item.author,
        bot: item.bot,
        assoc: item.association,
        created: item.createdAt,
        updated: item.updatedAt,
        closed: item.closedAt,
        labels: item.labels,
        comments: item.comments,
        bodySize: item.body.length,
    };
    if (item.kind === "pr") {
        Object.assign(out, {
            draft: item.draft,
            merged: item.mergedAt,
            base: item.base,
            head: item.head,
            review: item.review,
            mergeable: item.mergeable,
            ci: item.ci,
        });
    } else {
        out.reason = item.stateReason;
    }
    return out;
}

// github: the cache from engineering-board-github.mjs, or null when GitHub was not read.
export function assembleBoard({ notes, history, github, config = BOARD_CONFIG, source }) {
    const repos = github?.repos?.length ? github.repos : [config.primaryRepo];
    const scanner = links.createRefScanner({
        repos: [...new Set([...repos, ...Object.values(config.prefixes)])],
        prefixes: config.prefixes,
    });

    const items = new Map();
    for (const item of Object.values(github?.items ?? {})) {
        items.set(links.itemKey(item.repo, item.number), item);
    }

    const boardNotes = notes.map((note) => {
        const events = (history.get(note.id) ?? []).map((event) => ({
            sha: event.sha,
            date: event.date,
            subject: event.subject,
            action: event.action,
            from: event.from,
            prNumber: event.prNumber,
            pr: deliveryPr(event, items, config.primaryRepo),
        }));
        return { note, events };
    });

    const relations = links.buildRelations({
        items,
        notes: boardNotes.map(({ note, events }) => ({
            id: note.id,
            repo: config.primaryRepo,
            body: note.raw,
            history: events,
        })),
        scanner,
    });

    const shards = new Map();
    for (const item of items.values()) {
        const name = shardName(item.repo, item.number);
        if (!shards.has(name)) shards.set(name, {});
        shards.get(name)[item.number] = item.body;
    }

    const index = {
        schema: BOARD_SCHEMA,
        generatedAt: new Date().toISOString(),
        source: {
            mode: source.mode,
            githubFetchedAt: github?.fetchedAt ?? null,
            githubError: source.githubError ?? null,
            refreshing: Boolean(source.refreshing),
        },
        primaryRepo: config.primaryRepo,
        prefixes: config.prefixes,
        repos: repos.map((full) => repoInfo(full, config)),
        shardSize: SHARD_SIZE,
        items: [...items.values()]
            .sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))
            .map(compactItem),
        notes: boardNotes.map(({ note, events }) => {
            const { raw, ...rest } = note;
            return { ...rest, history: events };
        }),
        relations,
    };
    return { index, shards };
}

// Reads the Notes and their history, brings the GitHub cache up to date and assembles the
// board. With `offline` (or without a token in live mode) the cache is used as it is.
export async function loadBoard({
    rootDir = ROOT_DIR,
    cachePath = DEFAULT_CACHE_PATH,
    mode,
    offline = false,
    requireGitHub = false,
    log = () => {},
}) {
    const notes = collectNotes(rootDir);
    const history = noteHistoryFromGit(rootDir, notes.map((note) => note.id));
    let cache = github.readCache(cachePath);
    let githubError = null;
    if (!offline) {
        const auth = github.resolveToken();
        if (!auth) {
            githubError = "没有可用的 GitHub 令牌：设置 GITHUB_TOKEN 或 GH_TOKEN，或先运行 gh auth login。";
        } else {
            try {
                const result = await github.refreshCache(cache, {
                    token: auth.token,
                    primaryRepo: BOARD_CONFIG.primaryRepo,
                    orgs: BOARD_CONFIG.orgs,
                    log,
                });
                cache = result.cache;
                github.writeCache(cachePath, cache);
                log(`GitHub 读取完成：${result.rounds} 批请求，更新 ${result.fetched} 条记录（令牌来源：${auth.source}）`);
            } catch (error) {
                githubError = error.message;
            }
        }
        if (githubError && requireGitHub) throw new Error(githubError);
    }
    return assembleBoard({
        notes,
        history,
        github: cache.fetchedAt ? cache : null,
        source: { mode, githubError },
    });
}

function inlineScript(source) {
    return source.replace(/^\s*export default \w+;\s*$/m, "").replaceAll("</script", "<\\/script");
}

// The page with the link scanner inlined; `mode` is "static" for the published site and
// "live" for the local server. The logo is served beside the page as logo.png.
export function renderPage(mode) {
    return readFileSync(TEMPLATE_PATH, "utf8")
        .replace("/* __LITHE_BOARD_LINKS__ */", () => inlineScript(readFileSync(LINKS_PATH, "utf8")))
        .replace('window.__LITHE_BOARD_MODE__ = "static";', () => `window.__LITHE_BOARD_MODE__ = ${JSON.stringify(mode)};`)
        .replaceAll("__LITHE_BOARD_LOGO__", "logo.png");
}

export function writeSite(outDir, { index, shards }, html) {
    const dataDir = join(outDir, "data");
    rmSync(dataDir, { recursive: true, force: true });
    mkdirSync(join(dataDir, "bodies"), { recursive: true });
    writeFileSync(join(outDir, "index.html"), html);
    copyFileSync(LOGO_PATH, join(outDir, "logo.png"));
    writeFileSync(join(dataDir, "index.json"), JSON.stringify(index));
    for (const [name, bodies] of shards) {
        writeFileSync(join(dataDir, "bodies", name), JSON.stringify(bodies));
    }
}
