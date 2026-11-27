// GitHub records for the engineering board: the PRs and Issues of the primary repository and
// of every public, unarchived repository of the organizations the board follows.
//
// Only the records themselves are read (title, body, state, labels, review and CI summary,
// comment count). Code, diffs and comment text are never requested. The cache file keeps
// every record so a later run only asks GitHub for what changed since; it lives under
// .artifacts/agent-notes-board/cache/, is private to the checkout and can be deleted at any time.
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

export const CACHE_SCHEMA = 1;
const ENDPOINT = "https://api.github.com/graphql";
const REQUEST_TIMEOUT_MS = 90_000;
const MAX_ATTEMPTS = 4;
const STREAMS_PER_QUERY = 6;
const PAGE_SIZE = { pr: 50, issue: 100 };
const MIN_PAGE_SIZE = 10;

const PR_FIELDS = `
  number title state isDraft createdAt updatedAt closedAt mergedAt
  author { login __typename } authorAssociation baseRefName headRefName body
  labels(first: 20) { nodes { name color } }
  closingIssuesReferences(first: 20) { nodes { number repository { nameWithOwner } } }
  mergeCommit { oid }
  comments { totalCount }`;

// Review, merge and CI state matter only while a PR is open and are costly to compute, so
// only the stream of open PRs asks for them.
const OPEN_PR_FIELDS = `${PR_FIELDS}
  reviewDecision mergeable
  commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }`;

const ISSUE_FIELDS = `
  number title state stateReason createdAt updatedAt closedAt
  author { login __typename } authorAssociation body
  labels(first: 20) { nodes { name color } }
  comments { totalCount }
  timelineItems(itemTypes: [CROSS_REFERENCED_EVENT, CONNECTED_EVENT], first: 50) {
    nodes {
      ... on CrossReferencedEvent { source { ... on PullRequest { number repository { nameWithOwner } } ... on Issue { number repository { nameWithOwner } } } }
      ... on ConnectedEvent { subject { ... on PullRequest { number repository { nameWithOwner } } ... on Issue { number repository { nameWithOwner } } } }
    }
  }`;

export class GitHubError extends Error {
    // retryable: the request may succeed when repeated or made smaller (timeouts, 5xx).
    constructor(message, { retryable = false } = {}) {
        super(message);
        this.retryable = retryable;
    }
}

// Token order: GITHUB_TOKEN (Actions), GH_TOKEN, then the logged-in gh CLI.
export function resolveToken(env = process.env) {
    if (env.GITHUB_TOKEN) return { token: env.GITHUB_TOKEN, source: "GITHUB_TOKEN" };
    if (env.GH_TOKEN) return { token: env.GH_TOKEN, source: "GH_TOKEN" };
    try {
        const token = execFileSync("gh", ["auth", "token"], {
            encoding: "utf8",
            stdio: ["ignore", "pipe", "ignore"],
            timeout: 15_000,
        }).trim();
        if (token) return { token, source: "gh auth token" };
    } catch {
        // gh is missing or not logged in; the caller reports that no token is available.
    }
    return null;
}

function isRetryable(status) {
    return status === 502 || status === 503 || status === 504;
}

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// `fetchImpl` and `sleep` are replaced by the tests; the defaults talk to GitHub.
async function graphql(token, query, { fetchImpl = fetch, sleep = wait } = {}) {
    let lastError = null;
    for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt += 1) {
        try {
            const response = await fetchImpl(ENDPOINT, {
                method: "POST",
                headers: {
                    authorization: `bearer ${token}`,
                    "content-type": "application/json",
                    "user-agent": "lithe-engineering-board",
                },
                body: JSON.stringify({ query }),
                signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
            });
            const text = await response.text();
            if (!response.ok) {
                throw new GitHubError(`GitHub GraphQL 请求失败（HTTP ${response.status}）：${text.slice(0, 300)}`, {
                    retryable: isRetryable(response.status),
                });
            }
            const json = JSON.parse(text);
            if (json.errors?.length) {
                const timedOut = json.errors.some((e) => /timeout|timed out|something went wrong/i.test(e.message ?? ""));
                throw new GitHubError(`GitHub GraphQL 返回错误：${json.errors.map((e) => e.message).join("；")}`, {
                    retryable: timedOut,
                });
            }
            return json.data;
        } catch (error) {
            lastError = error instanceof GitHubError
                ? error
                : new GitHubError(`GitHub GraphQL 请求失败：${error.message}`, { retryable: true });
            if (!lastError.retryable) throw lastError;
        }
        if (attempt < MAX_ATTEMPTS) await sleep(1500 * attempt);
    }
    throw lastError;
}

function literal(value) {
    return JSON.stringify(String(value));
}

export async function discoverRepos(token, { primaryRepo, orgs }, transport = {}) {
    const repos = new Map([[primaryRepo.toLowerCase(), primaryRepo]]);
    for (const org of orgs) {
        let cursor = null;
        do {
            const after = cursor ? `, after: ${literal(cursor)}` : "";
            const data = await graphql(token, `query {
                organization(login: ${literal(org)}) {
                    repositories(first: 100, privacy: PUBLIC, isArchived: false${after}, orderBy: { field: NAME, direction: ASC }) {
                        pageInfo { hasNextPage endCursor }
                        nodes { nameWithOwner }
                    }
                }
            }`, transport);
            const connection = data.organization?.repositories;
            if (!connection) throw new GitHubError(`读取组织 ${org} 的仓库列表失败`);
            for (const node of connection.nodes) repos.set(node.nameWithOwner.toLowerCase(), node.nameWithOwner);
            cursor = connection.pageInfo.hasNextPage ? connection.pageInfo.endCursor : null;
        } while (cursor);
    }
    return [...repos.values()];
}

function refList(nodes) {
    return (nodes ?? [])
        .filter((node) => node?.number && node.repository?.nameWithOwner)
        .map((node) => ({ repo: node.repository.nameWithOwner, number: node.number }));
}

export function normalizeNode(node, kind, repo) {
    const base = {
        repo,
        number: node.number,
        kind,
        title: node.title ?? "",
        state: node.state,
        author: node.author?.login ?? "ghost",
        bot: node.author?.__typename === "Bot",
        association: node.authorAssociation ?? "NONE",
        createdAt: node.createdAt,
        updatedAt: node.updatedAt,
        closedAt: node.closedAt ?? null,
        labels: (node.labels?.nodes ?? []).map((label) => [label.name, label.color]),
        comments: node.comments?.totalCount ?? 0,
        body: node.body ?? "",
    };
    if (kind === "pr") {
        return {
            ...base,
            draft: Boolean(node.isDraft),
            mergedAt: node.mergedAt ?? null,
            base: node.baseRefName ?? null,
            head: node.headRefName ?? null,
            mergeCommit: node.mergeCommit?.oid ?? null,
            review: node.reviewDecision ?? null,
            mergeable: node.mergeable ?? null,
            ci: node.commits?.nodes?.[0]?.commit?.statusCheckRollup?.state ?? null,
            closing: refList(node.closingIssuesReferences?.nodes),
        };
    }
    return {
        ...base,
        stateReason: node.stateReason ?? null,
        crossRefs: refList((node.timelineItems?.nodes ?? []).map((n) => n?.source ?? n?.subject)),
    };
}

function fragmentOf(stream) {
    if (stream.kind === "issue") return "BoardIssue";
    return stream.openOnly ? "BoardOpenPr" : "BoardPr";
}

function connectionField(stream) {
    const after = stream.cursor ? `, after: ${literal(stream.cursor)}` : "";
    const states = stream.openOnly ? ", states: OPEN" : "";
    const field = stream.kind === "pr" ? "pullRequests" : "issues";
    return `${field}(first: ${stream.pageSize}${after}${states}, orderBy: { field: UPDATED_AT, direction: DESC }) {
        pageInfo { hasNextPage endCursor }
        nodes { ...${fragmentOf(stream)} }
    }`;
}

const FRAGMENTS = {
    BoardPr: `fragment BoardPr on PullRequest { ${PR_FIELDS} }`,
    BoardOpenPr: `fragment BoardOpenPr on PullRequest { ${OPEN_PR_FIELDS} }`,
    BoardIssue: `fragment BoardIssue on Issue { ${ISSUE_FIELDS} }`,
};

// GitHub rejects a query that defines a fragment it does not use, so only the fragments of
// this batch are included.
export function batchQuery(streams) {
    const fields = streams.map((stream, index) => {
        const [owner, name] = stream.repo.split("/");
        return `s${index}: repository(owner: ${literal(owner)}, name: ${literal(name)}) { ${connectionField(stream)} }`;
    });
    const fragments = [...new Set(streams.map(fragmentOf))].map((name) => FRAGMENTS[name]);
    return `query {
        ${fields.join("\n")}
        rateLimit { remaining resetAt }
    }
    ${fragments.join("\n")}`;
}

export function emptyCache() {
    return { schema: CACHE_SCHEMA, fetchedAt: null, repos: [], watermarks: {}, items: {} };
}

export function readCache(path) {
    if (!path || !existsSync(path)) return emptyCache();
    try {
        const cache = JSON.parse(readFileSync(path, "utf8"));
        if (cache.schema !== CACHE_SCHEMA) return emptyCache();
        return cache;
    } catch {
        // A truncated or foreign file is rebuilt from GitHub instead of being trusted.
        return emptyCache();
    }
}

export function writeCache(path, cache) {
    mkdirSync(dirname(path), { recursive: true });
    const temp = `${path}.${process.pid}.tmp`;
    writeFileSync(temp, JSON.stringify(cache));
    renameSync(temp, path);
}

// Brings the cache up to date. Every repository and kind is read newest-updated first and
// stops at the first record older than the previous run's watermark; open PRs are always
// read again because their review and CI summary change without touching updatedAt.
export async function refreshCache(cache, {
    token,
    primaryRepo,
    orgs,
    fetchImpl = fetch,
    sleep = wait,
    now = () => new Date(),
    log = () => {},
}) {
    const transport = { fetchImpl, sleep };
    const repos = await discoverRepos(token, { primaryRepo, orgs }, transport);
    const next = {
        schema: CACHE_SCHEMA,
        fetchedAt: now().toISOString(),
        repos,
        watermarks: {},
        items: {},
    };
    const kept = new Set(repos);
    for (const [key, item] of Object.entries(cache.items ?? {})) {
        if (kept.has(item.repo)) next.items[key] = item;
    }

    const streams = [];
    for (const repo of repos) {
        for (const kind of ["pr", "issue"]) {
            const id = `${repo}:${kind}`;
            streams.push({
                id, repo, kind, cursor: null, pageSize: PAGE_SIZE[kind], openOnly: false,
                watermark: cache.watermarks?.[id] ?? null, newest: cache.watermarks?.[id] ?? null,
                done: false, fetched: 0,
            });
        }
        streams.push({
            id: `${repo}:pr:open`, repo, kind: "pr", cursor: null, pageSize: PAGE_SIZE.pr,
            openOnly: true, watermark: null, newest: null, done: false, fetched: 0,
        });
    }

    let round = 0;
    while (streams.some((stream) => !stream.done)) {
        const batch = streams.filter((stream) => !stream.done).slice(0, STREAMS_PER_QUERY);
        let data = null;
        for (let shrink = 0; !data; shrink += 1) {
            try {
                data = await graphql(token, batchQuery(batch), transport);
            } catch (error) {
                const smallest = Math.min(...batch.map((stream) => stream.pageSize));
                if (!error.retryable || shrink >= 2 || smallest <= MIN_PAGE_SIZE) throw error;
                for (const stream of batch) {
                    stream.pageSize = Math.max(MIN_PAGE_SIZE, Math.floor(stream.pageSize / 2));
                }
                log(`GitHub 请求失败，缩小每页数量后重试：${error.message}`);
            }
        }
        round += 1;
        batch.forEach((stream, index) => {
            const connection = data[`s${index}`]?.[stream.kind === "pr" ? "pullRequests" : "issues"];
            if (!connection) throw new GitHubError(`读取 ${stream.repo} 的记录失败`);
            let reachedOld = false;
            for (const node of connection.nodes) {
                if (!node?.number) continue;
                if (stream.watermark && node.updatedAt < stream.watermark) {
                    reachedOld = true;
                    break;
                }
                if (!stream.newest || node.updatedAt > stream.newest) stream.newest = node.updatedAt;
                // Open PRs come from their own stream with the review and CI fields.
                if (stream.kind === "pr" && !stream.openOnly && node.state === "OPEN") continue;
                const item = normalizeNode(node, stream.kind, stream.repo);
                next.items[`${stream.repo}#${item.number}`] = item;
                stream.fetched += 1;
            }
            if (reachedOld || !connection.pageInfo.hasNextPage) {
                stream.done = true;
            } else {
                stream.cursor = connection.pageInfo.endCursor;
            }
        });
        const remaining = data.rateLimit?.remaining;
        const fetched = streams.reduce((sum, stream) => sum + stream.fetched, 0);
        log(`GitHub 第 ${round} 批：已读取 ${fetched} 条记录${remaining == null ? "" : `，剩余额度 ${remaining}`}`);
    }

    for (const stream of streams) {
        if (!stream.openOnly && stream.newest) next.watermarks[stream.id] = stream.newest;
    }
    return {
        cache: next,
        fetched: streams.reduce((sum, stream) => sum + stream.fetched, 0),
        rounds: round,
    };
}
