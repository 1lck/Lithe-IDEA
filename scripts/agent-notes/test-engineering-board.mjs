#!/usr/bin/env node
// Tests for the engineering board: reference scanning and relations, Note history, the GitHub
// cache refresh against a fake GraphQL endpoint, board assembly, the page template and the
// local server. Nothing here touches the network or the real GitHub cache.
//
//   node --test scripts/agent-notes/test-engineering-board.mjs
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { request } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, test } from "node:test";
import vm from "node:vm";
import links from "./engineering-board-links.mjs";
import * as github from "./engineering-board-github.mjs";
import { SHARD_NAME, assembleBoard, renderPage, repoInfo, shardName, writeSite } from "./engineering-board-model.mjs";
import { createBoardServer } from "./serve-agent-notes-board.mjs";

const WAIT_MS = 5_000;
const APP = "example/app";
const CORE = "ExampleOrg/core";
const PLUGIN = "ExampleOrg/lithe-plugin-sample";
const NOTE_A = "implemented/process/2026-01-01-alpha.md";
const NOTE_B = "implemented/process/2026-01-02-beta.md";

// Rejects with `what` when `promise` has not settled within WAIT_MS.
async function within(promise, what) {
    let timer;
    const timeout = new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(`等待超时（${WAIT_MS} ms）：${what}`)), WAIT_MS);
    });
    try {
        return await Promise.race([promise, timeout]);
    } finally {
        clearTimeout(timer);
    }
}

function deferred() {
    let resolve;
    let reject;
    const promise = new Promise((res, rej) => {
        resolve = res;
        reject = rej;
    });
    return { promise, resolve, reject };
}

function tempDir(t) {
    const dir = mkdtempSync(join(tmpdir(), "lithe-board-test-"));
    t.after(() => rmSync(dir, { recursive: true, force: true }));
    return dir;
}

describe("reference scanner", () => {
    const scanner = links.createRefScanner({
        repos: [APP, CORE, PLUGIN],
        prefixes: { core: CORE, "桌面": APP },
    });
    const refs = (text, ctx = APP) => scanner.scan(text, ctx).map((r) => [`${r.repo}#${r.number}`, r.verb]);

    test("resolves URLs, full names, prefixes, plugin short names and bare numbers", () => {
        assert.deepEqual(refs(
            "see https://github.com/ExampleOrg/core/pull/7#discussion_r1, example/app#8, Core #9, "
            + "桌面#10, sample#11, lithe-plugin-sample#12 and #13",
        ), [
            [`${CORE}#7`, "mention"],
            [`${APP}#8`, "mention"],
            [`${CORE}#9`, "mention"],
            [`${APP}#10`, "mention"],
            [`${PLUGIN}#11`, "mention"],
            [`${PLUGIN}#12`, "mention"],
            [`${APP}#13`, "mention"],
        ]);
    });

    test("reads the verb before a reference", () => {
        assert.deepEqual(refs("Fixes #1. Closes: Core #2. Refs #3. Part of #4. 关联 #5"), [
            [`${APP}#1`, "closes"],
            [`${CORE}#2`, "closes"],
            [`${APP}#3`, "refs"],
            [`${APP}#4`, "refs"],
            [`${APP}#5`, "refs"],
        ]);
    });

    test("skips bare numbers without a repository and HTML entities", () => {
        assert.deepEqual(refs("#1 and &#35;", null), []);
        assert.deepEqual(refs("a&#35;b"), []);
    });

    test("canonicalizes the case of known repositories", () => {
        assert.deepEqual(refs("EXAMPLEORG/CORE#3"), [[`${CORE}#3`, "mention"]]);
    });

    test("ignores HTML comments and fenced code in prose", () => {
        const text = "<!-- Closes #1 -->\n```\n#2\n```\nCloses #3\n.agents/notes/implemented/process/2026-01-01-alpha.md";
        const { refs: found, notes } = links.extractRefs(text, APP, scanner);
        assert.deepEqual(found.map((r) => r.number), [3]);
        assert.deepEqual(notes, [NOTE_A]);
    });

    test("ignores references in inline code but keeps Note paths written as code", () => {
        const text = "Core PR `#4` and ``Fixes #5``, see `.agents/notes/implemented/process/2026-01-01-alpha.md`; Fixes #6";
        const { refs: found, notes } = links.extractRefs(text, APP, scanner);
        assert.deepEqual(found.map((r) => [r.number, r.verb]), [[6, "closes"]]);
        assert.deepEqual(notes, [NOTE_A]);
    });
});

describe("relations", () => {
    const scanner = links.createRefScanner({ repos: [APP, CORE], prefixes: { core: CORE } });
    const item = (repo, number, kind, extra = {}) => [links.itemKey(repo, number), { repo, number, kind, body: "", ...extra }];

    test("keeps the strongest relation of each pair with its stated direction", () => {
        const items = new Map([
            item(APP, 1, "pr", {
                body: "Fixes #2, mentions Core #3 and .agents/notes/implemented/process/2026-01-01-alpha.md, ignores #99",
                closing: [{ repo: APP, number: 2 }],
            }),
            item(APP, 2, "issue", { body: "see #1", crossRefs: [{ repo: CORE, number: 3 }] }),
            item(CORE, 3, "pr"),
        ]);
        const notes = [
            { id: NOTE_A, repo: APP, body: "", history: [{ pr: `${APP}#1`, action: "A" }] },
            { id: NOTE_B, repo: APP, body: "follows .agents/notes/implemented/process/2026-01-01-alpha.md and #2", history: [] },
        ];
        assert.deepEqual(links.buildRelations({ items, notes, scanner }), [
            [`${APP}#1`, `${APP}#2`, "closes"],
            [`${APP}#1`, `${CORE}#3`, "mention"],
            [`${CORE}#3`, `${APP}#2`, "mention"],
            [`note:${NOTE_A}`, `${APP}#1`, "A"],
            [`note:${NOTE_B}`, `${APP}#2`, "mention"],
            [`note:${NOTE_B}`, `note:${NOTE_A}`, "mention"],
        ]);
    });

    test("ranks every known relation ahead of unknown ones", () => {
        assert.ok(links.relRank("closes") < links.relRank("A"));
        assert.ok(links.relRank("body") < links.relRank("mention"));
        assert.ok(links.relRank("mention") < links.relRank("unknown"));
    });
});

describe("note history", () => {
    test("reads PR numbers from squash and merge commit subjects", () => {
        assert.equal(links.prFromSubject("feat: thing (#12)"), 12);
        assert.equal(links.prFromSubject("Merge pull request #34 from someone/branch"), 34);
        assert.equal(links.prFromSubject("fix: see #56 for details"), null);
    });

    test("follows renames back to the commit that created a Note", () => {
        const archived = "archived/process/2026-01-01-alpha.md";
        const log = [
            "@@ccc\t2026-03-01\tdocs: archive alpha (#30)",
            `R100\t.agents/notes/${NOTE_A}\t.agents/notes/${archived}`,
            "",
            "@@bbb\t2026-02-01\tdocs: edit alpha",
            `M\t.agents/notes/${NOTE_A}`,
            "M\tdocs/unrelated.md",
            "",
            "@@aaa\t2026-01-01\tfeat: add alpha (#10)",
            `A\t.agents/notes/${NOTE_A}`,
            `A\t.agents/notes/${NOTE_B}`,
        ].join("\r\n");
        const history = links.parseNoteHistory(log, [archived]);
        assert.deepEqual([...history.keys()], [archived]);
        assert.deepEqual(history.get(archived).map((e) => [e.sha, e.action, e.prNumber, e.from]), [
            ["ccc", "R", 30, NOTE_A],
            ["bbb", "M", null, null],
            ["aaa", "A", 10, null],
        ]);
    });
});

// A GraphQL endpoint that answers the board's queries from fixed records. Records of each
// repository and kind are listed newest-updated first, as GitHub returns them.
function fakeGitHub({ orgRepos, records, failures = [] }) {
    const queries = [];
    const fetchImpl = async (_url, init) => {
        const { query } = JSON.parse(init.body);
        queries.push(query);
        const failure = failures.shift();
        if (failure) return new Response(failure.body ?? "fail", { status: failure.status });
        const org = /organization\(login: "([^"]+)"\)/.exec(query);
        if (org) {
            return Response.json({
                data: {
                    organization: {
                        repositories: {
                            pageInfo: { hasNextPage: false, endCursor: null },
                            nodes: orgRepos.map((nameWithOwner) => ({ nameWithOwner })),
                        },
                    },
                },
            });
        }
        const data = { rateLimit: { remaining: 4900, resetAt: "2026-01-01T00:00:00Z" } };
        const field = /s(\d+): repository\(owner: "([^"]+)", name: "([^"]+)"\) \{ (pullRequests|issues)\(first: (\d+)(?:, after: "(\d+)")?(, states: OPEN)?/g;
        for (const m of query.matchAll(field)) {
            const [, alias, owner, name, connection, first, after, openOnly] = m;
            const kind = connection === "pullRequests" ? "pr" : "issue";
            const all = (records[`${owner}/${name}`]?.[kind] ?? []).filter((n) => !openOnly || n.state === "OPEN");
            const start = after ? Number(after) : 0;
            const end = start + Number(first);
            data[`s${alias}`] = {
                [connection]: {
                    pageInfo: { hasNextPage: end < all.length, endCursor: String(end) },
                    nodes: all.slice(start, end),
                },
            };
        }
        return Response.json({ data });
    };
    return { fetchImpl, queries };
}

const at = (day) => `2026-03-${String(day).padStart(2, "0")}T00:00:00Z`;
function prNode(number, updatedAt, extra = {}) {
    return {
        number, title: `PR ${number}`, state: "MERGED", isDraft: false, createdAt: at(1), updatedAt,
        closedAt: updatedAt, mergedAt: updatedAt, author: { login: "dev", __typename: "User" },
        authorAssociation: "MEMBER", baseRefName: "main", headRefName: `branch-${number}`, body: `body ${number}`,
        labels: { nodes: [{ name: "feat", color: "00ff00" }] }, closingIssuesReferences: { nodes: [] },
        mergeCommit: { oid: `sha${number}` }, comments: { totalCount: 1 }, ...extra,
    };
}
function issueNode(number, updatedAt, extra = {}) {
    return {
        number, title: `Issue ${number}`, state: "OPEN", stateReason: null, createdAt: at(1), updatedAt,
        closedAt: null, author: { login: "github-actions", __typename: "Bot" }, authorAssociation: "NONE",
        body: "", labels: { nodes: [] }, comments: { totalCount: 0 }, timelineItems: { nodes: [] }, ...extra,
    };
}
const openPr = (number, updatedAt, ci) => prNode(number, updatedAt, {
    state: "OPEN", closedAt: null, mergedAt: null, mergeCommit: null,
    reviewDecision: "REVIEW_REQUIRED", mergeable: "MERGEABLE",
    commits: { nodes: [{ commit: { statusCheckRollup: { state: ci } } }] },
});

describe("GitHub cache refresh", () => {
    const options = (fake, extra = {}) => ({
        token: "test-token",
        primaryRepo: APP,
        orgs: ["ExampleOrg"],
        fetchImpl: fake.fetchImpl,
        sleep: async () => {},
        now: () => new Date("2026-03-20T00:00:00Z"),
        ...extra,
    });

    test("reads every page on the first run and only what changed afterwards", async () => {
        const coreIssues = Array.from({ length: 120 }, (_, i) =>
            issueNode(120 - i, new Date(Date.UTC(2026, 1, 1) + (120 - i) * 60_000).toISOString()));
        const first = fakeGitHub({
            orgRepos: [CORE],
            records: {
                [APP]: {
                    pr: [openPr(3, at(3), "PENDING"), prNode(2, at(2)), prNode(1, at(1))],
                    issue: [issueNode(10, at(5), {
                        timelineItems: { nodes: [{ source: { number: 2, repository: { nameWithOwner: APP } } }] },
                    })],
                },
                [CORE]: { pr: [], issue: coreIssues },
            },
        });
        const { cache } = await github.refreshCache(github.emptyCache(), options(first));
        assert.deepEqual(cache.repos, [APP, CORE]);
        assert.equal(cache.fetchedAt, "2026-03-20T00:00:00.000Z");
        assert.equal(Object.keys(cache.items).length, 4 + 120);
        assert.deepEqual(
            [cache.items[`${APP}#3`].ci, cache.items[`${APP}#3`].review, cache.items[`${APP}#3`].mergeable],
            ["PENDING", "REVIEW_REQUIRED", "MERGEABLE"],
        );
        assert.equal(cache.items[`${APP}#2`].mergeCommit, "sha2");
        assert.deepEqual(cache.items[`${APP}#10`].crossRefs, [{ repo: APP, number: 2 }]);
        assert.equal(cache.items[`${APP}#10`].bot, true);
        assert.deepEqual(cache.items[`${APP}#1`].labels, [["feat", "00ff00"]]);
        assert.ok(first.queries.some((q) => q.includes(`after: "100"`)), "the 120 Core issues span two pages");
        assert.deepEqual(cache.watermarks, {
            [`${APP}:pr`]: at(3),
            [`${APP}:issue`]: at(5),
            [`${CORE}:issue`]: coreIssues[0].updatedAt,
        });
        for (const query of first.queries) {
            for (const name of ["BoardPr", "BoardOpenPr", "BoardIssue"]) {
                assert.equal(query.includes(`fragment ${name} `), query.includes(`...${name}`), `${name} is defined only where used`);
            }
        }

        // Core is archived now; PR 2 was edited, PR 3's CI finished without touching updatedAt.
        const second = fakeGitHub({
            orgRepos: [],
            records: {
                [APP]: {
                    pr: [prNode(2, at(9), { title: "PR 2 renamed" }), openPr(3, at(3), "FAILURE"), prNode(1, at(1))],
                    issue: [issueNode(10, at(5))],
                },
            },
        });
        const { cache: next, fetched } = await github.refreshCache(cache, options(second));
        // PR 2 (newer than the watermark), PR 3 (open, always read) and Issue 10 (at the
        // watermark); PR 1 is older than the watermark and stays from the cache.
        assert.equal(fetched, 3);
        assert.deepEqual(next.repos, [APP]);
        assert.equal(Object.keys(next.items).filter((key) => key.startsWith(CORE)).length, 0);
        assert.equal(next.items[`${APP}#2`].title, "PR 2 renamed");
        assert.equal(next.items[`${APP}#3`].ci, "FAILURE");
        assert.equal(next.items[`${APP}#1`].title, "PR 1");
        assert.equal(next.watermarks[`${APP}:pr`], at(9));
        assert.ok(second.queries.every((q) => !q.includes("after:")), "the second run stops on the first page");
    });

    test("stops at the first error that a retry cannot fix", async () => {
        const fake = fakeGitHub({ orgRepos: [], records: {}, failures: [{ status: 401, body: "Bad credentials" }] });
        await assert.rejects(github.refreshCache(github.emptyCache(), options(fake)), (error) => {
            assert.ok(error instanceof github.GitHubError);
            assert.match(error.message, /HTTP 401/);
            return true;
        });
        assert.equal(fake.queries.length, 1);
    });

    test("retries server errors with backoff, then asks for smaller pages", async () => {
        const fake = fakeGitHub({
            orgRepos: [],
            records: { [APP]: { pr: [prNode(1, at(1))], issue: [] } },
            failures: [null, ...Array.from({ length: 4 }, () => ({ status: 502 }))],
        });
        const sleeps = [];
        const messages = [];
        const { cache } = await github.refreshCache(github.emptyCache(), options(fake, {
            sleep: async (ms) => { sleeps.push(ms); },
            log: (message) => messages.push(message),
        }));
        assert.deepEqual(sleeps, [1500, 3000, 4500]);
        assert.ok(messages.some((m) => m.includes("缩小每页数量")));
        assert.equal(fake.queries.length, 6);
        assert.match(fake.queries[5], /pullRequests\(first: 25,/);
        assert.match(fake.queries[5], /issues\(first: 50,/);
        assert.equal(cache.items[`${APP}#1`].title, "PR 1");
    });

    test("prefers the Actions token, then GH_TOKEN", () => {
        assert.deepEqual(github.resolveToken({ GITHUB_TOKEN: "a", GH_TOKEN: "b" }), { token: "a", source: "GITHUB_TOKEN" });
        assert.deepEqual(github.resolveToken({ GH_TOKEN: "b" }), { token: "b", source: "GH_TOKEN" });
    });

    test("rebuilds a missing, damaged or outdated cache from scratch", (t) => {
        const dir = tempDir(t);
        const path = join(dir, "cache", "github.json");
        assert.deepEqual(github.readCache(path), github.emptyCache());
        mkdirSync(join(dir, "cache"));
        writeFileSync(path, "{ truncated");
        assert.deepEqual(github.readCache(path), github.emptyCache());
        writeFileSync(path, JSON.stringify({ schema: github.CACHE_SCHEMA + 1, items: { x: 1 } }));
        assert.deepEqual(github.readCache(path), github.emptyCache());
        const cache = { ...github.emptyCache(), fetchedAt: at(1), repos: [APP] };
        github.writeCache(path, cache);
        assert.deepEqual(github.readCache(path), cache);
        assert.equal(existsSync(`${path}.${process.pid}.tmp`), false);
    });

    test("writes one sorted record per line so git stores only what changed", (t) => {
        const path = join(tempDir(t), "github.json");
        const record = (number, title) => ({ repo: APP, number, kind: "pr", title });
        const cache = {
            ...github.emptyCache(),
            fetchedAt: at(2),
            repos: [APP],
            watermarks: { [`${APP}:pr`]: at(2) },
            items: { [`${APP}#2`]: record(2, "two"), [`${APP}#10`]: record(10, "ten"), [`${APP}#1`]: record(1, "one") },
        };
        github.writeCache(path, cache);
        const first = readFileSync(path, "utf8");
        assert.deepEqual(github.readCache(path), cache);
        const lines = first.trimEnd().split("\n");
        assert.equal(lines.length, 5);
        assert.deepEqual(lines.slice(1, 4).map((line) => JSON.parse(`{${line.replace(/,$/, "")}}`)), [
            { [`${APP}#1`]: record(1, "one") },
            { [`${APP}#10`]: record(10, "ten") },
            { [`${APP}#2`]: record(2, "two") },
        ]);

        // The same records in another insertion order give the same bytes; changing one record
        // changes exactly one record line besides the header.
        github.writeCache(path, { ...cache, items: Object.fromEntries(Object.entries(cache.items).reverse()) });
        assert.equal(readFileSync(path, "utf8"), first);
        github.writeCache(path, { ...cache, fetchedAt: at(3), items: { ...cache.items, [`${APP}#10`]: record(10, "TEN") } });
        const changed = readFileSync(path, "utf8").trimEnd().split("\n");
        assert.deepEqual(changed.map((line, index) => line !== lines[index]), [true, false, true, false, false]);

        github.writeCache(path, github.emptyCache());
        assert.deepEqual(github.readCache(path), github.emptyCache());
    });
});

describe("board assembly", () => {
    const config = {
        primaryRepo: APP,
        orgs: ["ExampleOrg"],
        prefixes: { core: CORE },
        labels: { [APP]: "App" },
    };
    const item = (number, kind, extra) => ({
        repo: APP, number, kind, title: `T${number}`, state: "MERGED", author: "dev", bot: false,
        association: "MEMBER", createdAt: at(1), updatedAt: at(number), closedAt: null, labels: [],
        comments: 0, body: `body ${number}`, draft: false, mergedAt: at(number), base: "main",
        head: "b", mergeCommit: null, review: null, mergeable: null, ci: null, closing: [], ...extra,
    });

    test("links Note history only to the PR that delivered it", () => {
        const notes = [
            { id: NOTE_A, title: "Alpha", lifecycle: "implemented", raw: "Builds on Core #5 and .agents/notes/implemented/process/2026-01-02-beta.md" },
            { id: NOTE_B, title: "Beta", lifecycle: "implemented", raw: "" },
        ];
        const history = new Map([[NOTE_A, [
            { sha: "s2", date: "2026-03-02", subject: "feat: two (#2)", action: "A", from: null, prNumber: 2 },
            { sha: "s3", date: "2026-03-03", subject: "Closed by hand (#3)", action: "M", from: null, prNumber: 3 },
            { sha: "s4", date: "2026-03-04", subject: "unrelated (#4)", action: "M", from: null, prNumber: 4 },
            { sha: "s6", date: "2026-03-06", subject: "issue number (#6)", action: "M", from: null, prNumber: 6 },
        ]]]);
        const cache = {
            fetchedAt: at(20),
            repos: [APP, CORE],
            items: {
                [`${APP}#2`]: item(2, "pr", { mergeCommit: "s2" }),
                [`${APP}#3`]: item(3, "pr", { state: "CLOSED", mergedAt: null, title: "Closed by hand" }),
                [`${APP}#4`]: item(4, "pr", { mergeCommit: "other" }),
                [`${APP}#6`]: { ...item(6, "issue"), title: "issue number", stateReason: "COMPLETED", crossRefs: [] },
                [`${CORE}#5`]: { ...item(5, "issue"), repo: CORE, stateReason: null, crossRefs: [] },
            },
        };
        const { index, shards } = assembleBoard({
            notes, history, github: cache, config, source: { mode: "static", githubError: "boom" },
        });

        assert.deepEqual(index.notes[0].history.map((e) => e.pr), [`${APP}#2`, `${APP}#3`, null, null]);
        assert.equal("raw" in index.notes[0], false);
        assert.deepEqual(index.relations.filter(([from]) => from === `note:${NOTE_A}`), [
            [`note:${NOTE_A}`, `${APP}#2`, "A"],
            [`note:${NOTE_A}`, `${APP}#3`, "M"],
            [`note:${NOTE_A}`, `${CORE}#5`, "mention"],
            [`note:${NOTE_A}`, `note:${NOTE_B}`, "mention"],
        ]);
        assert.deepEqual(index.items.map((i) => i.k), [`${APP}#6`, `${CORE}#5`, `${APP}#4`, `${APP}#3`, `${APP}#2`]);
        assert.equal(index.items.find((i) => i.k === `${APP}#2`).bodySize, "body 2".length);
        assert.equal(index.items.some((i) => "body" in i), false);
        assert.deepEqual(index.source, { mode: "static", githubFetchedAt: at(20), githubError: "boom", refreshing: false });
        assert.deepEqual(index.repos.map((r) => [r.full, r.label, r.role]), [[APP, "App", "app"], [CORE, "core", "core"]]);
        assert.deepEqual(shards.get(shardName(CORE, 5)), { 5: "body 5" });
        assert.equal(shards.get(shardName(APP, 2))[3], "body 3");
    });

    test("shows the Notes alone when GitHub was never read", () => {
        const { index, shards } = assembleBoard({
            notes: [{ id: NOTE_A, title: "Alpha", raw: "#1" }],
            history: new Map(),
            github: null,
            config,
            source: { mode: "live" },
        });
        assert.deepEqual(index.repos.map((r) => r.full), [APP]);
        assert.deepEqual([index.items, index.relations, shards.size], [[], [], 0]);
        assert.equal(index.source.githubFetchedAt, null);
    });

    test("names shards so the server accepts them and nothing else", () => {
        assert.equal(shardName("Example.Org/x.y", 250), "Example_Org_x_y--2.json");
        assert.match(shardName("Example.Org/x.y", 250), SHARD_NAME);
        assert.doesNotMatch("../secret--1.json", SHARD_NAME);
        assert.doesNotMatch("a--1.json/../b", SHARD_NAME);
    });

    test("labels plugin repositories by their short name", () => {
        assert.deepEqual(repoInfo(PLUGIN, config), {
            full: PLUGIN, label: "sample", role: "plugin", url: `https://github.com/${PLUGIN}`,
        });
    });
});

describe("page", () => {
    test("inlines the link scanner and leaves no placeholder", () => {
        const html = renderPage("live");
        assert.doesNotMatch(html, /__LITHE_BOARD_(LINKS|LOGO)__/);
        assert.match(html, /window\.__LITHE_BOARD_MODE__ = "live";/);
        const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => m[1]);
        assert.ok(scripts.length >= 3);
        for (const source of scripts) assert.doesNotThrow(() => new vm.Script(source));
        const context = vm.createContext({});
        vm.runInContext(scripts[0], context);
        const scan = vm.runInContext("LitheEngineeringBoardLinks.createRefScanner({ repos: ['a/b'] }).scan('Fixes #3', 'a/b')", context);
        assert.deepEqual([scan[0].number, scan[0].verb], [3, "closes"]);
    });

    test("writes the site and drops bodies of an earlier build", (t) => {
        const out = tempDir(t);
        mkdirSync(join(out, "data", "bodies"), { recursive: true });
        writeFileSync(join(out, "data", "bodies", "stale--0.json"), "{}");
        const index = { schema: 1, items: [] };
        writeSite(out, { index, shards: new Map([["a--0.json", { 1: "x" }]]) }, "<html>");
        assert.equal(readFileSync(join(out, "index.html"), "utf8"), "<html>");
        assert.deepEqual(JSON.parse(readFileSync(join(out, "data", "index.json"), "utf8")), index);
        assert.deepEqual(JSON.parse(readFileSync(join(out, "data", "bodies", "a--0.json"), "utf8")), { 1: "x" });
        assert.equal(existsSync(join(out, "data", "bodies", "stale--0.json")), false);
        assert.ok(readFileSync(join(out, "logo.png")).subarray(1, 4).equals(Buffer.from("PNG")));
    });
});

// ---- local server ----

function fakeBoard({ githubError = null } = {}) {
    return {
        index: { schema: 1, source: { mode: "live", githubFetchedAt: at(20), githubError }, items: [] },
        shards: new Map([["example_app--0.json", { 1: "body 1" }]]),
    };
}

// Starts a server on a free port with `load` and closes it after the test.
async function startServer(t, load, extra = {}) {
    const board = createBoardServer({
        load,
        html: () => "<!doctype html><title>board</title>",
        logo: Buffer.from("logo-bytes"),
        refreshIntervalMs: 60 * 60_000,
        heartbeatMs: 60 * 60_000,
        now: () => 1_000_000,
        ...extra,
    });
    const port = await board.listen(0);
    t.after(() => board.close());
    return { board, port, base: `http://127.0.0.1:${port}` };
}

function rawRequest(port, { method = "GET", path = "/", headers = {} } = {}) {
    return within(new Promise((resolve, reject) => {
        const req = request({ host: "127.0.0.1", port, method, path, headers }, (res) => {
            let body = "";
            res.setEncoding("utf8");
            res.on("data", (chunk) => { body += chunk; });
            res.on("end", () => resolve({ status: res.statusCode, body }));
        });
        req.on("error", reject);
        req.end();
    }), `${method} ${path}`);
}

// Reads the server's event stream. `next(match)` resolves with the first status not yet
// consumed that satisfies `match`, skipping the ones before it.
function openEvents(t, port) {
    const statuses = [];
    const waiters = [];
    let ended = false;
    const flush = () => {
        for (let i = 0; i < waiters.length; i += 1) {
            const waiter = waiters[i];
            const at = statuses.findIndex(waiter.match);
            if (at >= 0) {
                waiter.resolve(statuses[at]);
                statuses.splice(0, at + 1);
                waiters.splice(i, 1);
                i -= 1;
            }
        }
    };
    const endedPromise = deferred();
    const req = request({ host: "127.0.0.1", port, path: "/events" }, (res) => {
        let buffer = "";
        res.setEncoding("utf8");
        res.on("data", (chunk) => {
            buffer += chunk;
            let split;
            while ((split = buffer.indexOf("\n\n")) >= 0) {
                const block = buffer.slice(0, split);
                buffer = buffer.slice(split + 2);
                if (!block.startsWith("event: status\n")) continue;
                statuses.push(JSON.parse(block.slice(block.indexOf("data: ") + 6)));
                flush();
            }
        });
        res.on("end", () => { ended = true; endedPromise.resolve(); });
    });
    req.on("error", (error) => endedPromise.reject(error));
    req.end();
    t.after(() => req.destroy());
    return {
        next(match, what) {
            const waiter = { match, ...deferred() };
            waiters.push(waiter);
            flush();
            return within(waiter.promise, what);
        },
        ended: () => within(endedPromise.promise, "event stream end"),
        get isEnded() { return ended; },
        close: () => req.destroy(),
    };
}

describe("local server", () => {
    test("serves the page, the board and its shards", async (t) => {
        const { board, base } = await startServer(t, async () => fakeBoard());
        assert.equal((await fetch(`${base}/data/index.json`)).status, 503);
        await within(board.schedule("notes"), "notes build");

        const page = await fetch(`${base}/`);
        assert.equal(page.headers.get("content-type"), "text/html; charset=utf-8");
        assert.match(await page.text(), /<title>board/);
        const index = await (await fetch(`${base}/data/index.json`)).json();
        assert.equal(index.source.revision, 1);
        assert.deepEqual(await (await fetch(`${base}/data/bodies/example_app--0.json`)).json(), { 1: "body 1" });
        assert.equal(await (await fetch(`${base}/logo.png`)).text(), "logo-bytes");
        assert.equal((await fetch(`${base}/data/bodies/missing--0.json`)).status, 404);
        assert.equal((await fetch(`${base}/data/bodies/..%2Fpackage.json`)).status, 404);
        assert.equal((await fetch(`${base}/other`)).status, 404);
        assert.equal((await fetch(`${base}/`, { method: "POST" })).status, 404);
    });

    test("refuses other hosts and cross-site origins", async (t) => {
        const { board, port } = await startServer(t, async () => fakeBoard());
        await within(board.schedule("notes"), "notes build");
        assert.equal((await rawRequest(port, { headers: { host: `evil.example:${port}` } })).status, 403);
        assert.equal((await rawRequest(port, { headers: { host: `localhost:${port}` } })).status, 200);
        assert.equal((await rawRequest(port, {
            method: "POST", path: "/refresh", headers: { origin: "http://evil.example" },
        })).status, 403);
        assert.equal((await rawRequest(port, {
            path: "/data/index.json", headers: { origin: `http://127.0.0.1:${port}` },
        })).status, 200);
    });

    test("runs one build at a time and folds repeated GitHub requests", async (t) => {
        const calls = [];
        const gates = [];
        const load = ({ github: withGitHub }) => {
            calls.push(withGitHub ? "github" : "notes");
            const gate = deferred();
            gates.push(gate);
            return gate.promise;
        };
        const { board } = await startServer(t, load);

        // GitHub starts, a second GitHub request joins it, a Notes rebuild waits behind it.
        const first = board.schedule("github");
        assert.equal(board.schedule("github"), first);
        board.schedule("notes");
        assert.deepEqual(calls, ["github"]);
        assert.equal(board.status().refreshing, true);
        gates[0].resolve(fakeBoard());
        await within(new Promise((resolve) => setImmediate(resolve)), "drain step");
        assert.deepEqual(calls, ["github", "notes"]);
        assert.equal(board.status().refreshing, false);
        gates[1].resolve(fakeBoard());
        await within(first, "queued builds");
        assert.equal(board.status().revision, 2);

        // During a Notes rebuild a GitHub request is kept and a later Notes request folds into it.
        const second = board.schedule("notes");
        board.schedule("github");
        board.schedule("notes");
        gates[2].resolve(fakeBoard());
        await within(new Promise((resolve) => setImmediate(resolve)), "drain step");
        assert.deepEqual(calls, ["github", "notes", "notes", "github"]);
        gates[3].resolve(fakeBoard({ githubError: "rate limited" }));
        await within(second, "queued builds");
        assert.deepEqual(board.status(), {
            revision: 4, refreshing: false, githubFetchedAt: at(20), error: "GitHub 数据没有更新：rate limited",
        });
    });

    test("tells connected pages about every build and refreshes on request", async (t) => {
        const calls = [];
        let fail = false;
        const load = async ({ github: withGitHub }) => {
            calls.push(withGitHub ? "github" : "notes");
            if (fail) throw new Error("boom");
            return fakeBoard();
        };
        let clock = 1_000_000;
        const { board, port, base } = await startServer(t, load, { now: () => clock });
        await within(board.schedule("github"), "first GitHub read");
        assert.deepEqual(calls, ["github"]);

        // A page connecting within the interval gets the current status and no extra read.
        const events = openEvents(t, port);
        assert.equal((await events.next(() => true, "initial status")).revision, 1);
        assert.equal(board.clientCount, 1);

        const refresh = await fetch(`${base}/refresh`, { method: "POST" });
        assert.equal(refresh.status, 202);
        await events.next((s) => s.refreshing, "refresh start");
        assert.deepEqual(await events.next((s) => !s.refreshing, "refresh end"), {
            revision: 2, refreshing: false, githubFetchedAt: at(20), error: null,
        });

        fail = true;
        board.schedule("notes");
        assert.equal((await events.next((s) => s.error, "failed build")).error, "生成看板失败：boom");
        fail = false;
        board.schedule("notes");
        assert.equal((await events.next((s) => !s.error, "recovered build")).revision, 3);
        assert.deepEqual(calls, ["github", "github", "notes", "notes"]);

        // A page that connects after the interval has passed triggers a read right away.
        events.close();
        await within((async () => { while (board.clientCount) await new Promise((r) => setImmediate(r)); })(), "client disconnect");
        clock += 60 * 60_000;
        const later = openEvents(t, port);
        await later.next((s) => s.refreshing, "refresh on reconnect");
        await later.next((s) => !s.refreshing && s.revision === 4, "refresh on reconnect end");
        assert.deepEqual(calls.slice(-1), ["github"]);
    });

    test("ends event streams and stops listening on close", async (t) => {
        const { board, port, base } = await startServer(t, async () => fakeBoard());
        await within(board.schedule("github"), "first GitHub read");
        const events = openEvents(t, port);
        await events.next(() => true, "initial status");
        await within(board.close(), "server close");
        await events.ended();
        await assert.rejects(fetch(`${base}/`));
    });
});
