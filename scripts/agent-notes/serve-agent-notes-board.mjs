#!/usr/bin/env node
// Serves the engineering board locally with live data:
//
//   node scripts/agent-notes/serve-agent-notes-board.mjs [--port <端口>] [--open] [--cache <文件>]
//
// On start the board is built from the Notes and the GitHub cache, then the cache is brought up
// to date. While a page is open GitHub is read again every 10 minutes (the open PRs' review,
// CI and conflict state each time); saving a Note rebuilds the board without asking GitHub.
// Pages learn about a new board through /events and fetch it again.
//
// The server listens on 127.0.0.1 only, keeps the board in memory and writes nothing but the
// GitHub cache under .artifacts/agent-notes-board/cache/.
import { spawn } from "node:child_process";
import { readFileSync, watch } from "node:fs";
import { createServer } from "node:http";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { DEFAULT_CACHE_PATH, LOGO_PATH, ROOT_DIR, SHARD_NAME, loadBoard, renderPage } from "./engineering-board-model.mjs";

export const REFRESH_INTERVAL_MS = 10 * 60_000;
const HEARTBEAT_MS = 25_000;
const WATCH_DEBOUNCE_MS = 300;
const SHUTDOWN_TIMEOUT_MS = 3_000;
const DEFAULT_PORT = 8790;

// `load({ github })` returns { index, shards } like assembleBoard; with github false it must
// not touch the network. `html()` returns the page and `logo` the bytes of logo.png. Work is
// serialized: one build at a time, and a GitHub refresh requested during a Notes rebuild runs
// right after it.
export function createBoardServer({
    load,
    html,
    logo = null,
    refreshIntervalMs = REFRESH_INTERVAL_MS,
    heartbeatMs = HEARTBEAT_MS,
    now = () => Date.now(),
    log = () => {},
}) {
    const clients = new Set();
    const errors = { build: null, github: null };
    let page = html();
    let indexJson = null;
    let shards = new Map();
    let revision = 0;
    let githubFetchedAt = null;
    let refreshing = false;
    let lastGitHubAttempt = null;
    let pending = null;
    let current = null;
    let running = null;
    let timer = null;
    let port = null;

    function status() {
        const messages = [];
        if (errors.build) messages.push(`生成看板失败：${errors.build}`);
        if (errors.github) messages.push(`GitHub 数据没有更新：${errors.github}`);
        return { revision, refreshing, githubFetchedAt, error: messages.join("；") || null };
    }
    function send(res, event, data) {
        res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
    }
    function broadcast() {
        const data = status();
        for (const res of clients) send(res, "status", data);
    }

    function apply(board) {
        revision += 1;
        board.index.source.revision = revision;
        indexJson = JSON.stringify(board.index);
        shards = new Map([...board.shards].map(([name, bodies]) => [name, JSON.stringify(bodies)]));
        githubFetchedAt = board.index.source.githubFetchedAt;
    }

    async function drain() {
        while (pending) {
            const github = pending === "github";
            current = pending;
            pending = null;
            if (github) {
                refreshing = true;
                lastGitHubAttempt = now();
                broadcast();
            }
            try {
                const board = await load({ github });
                if (github) errors.github = board.index.source.githubError ?? null;
                errors.build = null;
                apply(board);
                log(`看板已更新（第 ${revision} 版${github ? "，含 GitHub" : ""}）`);
            } catch (error) {
                errors.build = error.message;
                log(`生成看板失败：${error.message}`);
            } finally {
                current = null;
                if (github) refreshing = false;
                broadcast();
            }
        }
    }
    // Returns a promise that settles once the requested work and anything queued after it ran.
    function schedule(kind) {
        if (kind === "github" && current === "github") return running;
        if (pending !== "github") pending = kind;
        if (!running) {
            running = drain().finally(() => {
                running = null;
                if (pending) schedule(pending);
                armTimer();
            });
        }
        return running;
    }

    // The periodic GitHub refresh only runs while a page is connected. A page that connects
    // after a long pause gets a refresh right away.
    function armTimer() {
        if (timer || !clients.size) return;
        const since = lastGitHubAttempt == null ? Infinity : now() - lastGitHubAttempt;
        const wait = Math.max(0, refreshIntervalMs - since);
        timer = setTimeout(() => {
            timer = null;
            if (clients.size) schedule("github");
        }, wait);
    }
    function disarmTimer() {
        clearTimeout(timer);
        timer = null;
    }

    function allowedHost(value) {
        return value === `127.0.0.1:${port}` || value === `localhost:${port}` || value === `[::1]:${port}`;
    }
    function reply(res, code, body, type = "text/plain; charset=utf-8") {
        res.writeHead(code, { "content-type": type, "cache-control": "no-store" });
        res.end(body);
    }

    const server = createServer((req, res) => {
        // Pages from other sites must not read the board or trigger GitHub reads through a
        // rebound DNS name or a cross-site form.
        const origin = req.headers.origin;
        if (!allowedHost(req.headers.host) || (origin && !allowedHost(origin.replace(/^https?:\/\//, "")))) {
            reply(res, 403, "forbidden");
            return;
        }
        const path = new URL(req.url, "http://localhost").pathname;
        if (req.method === "GET" && (path === "/" || path === "/index.html")) {
            reply(res, 200, page, "text/html; charset=utf-8");
        } else if (req.method === "GET" && path === "/logo.png" && logo) {
            res.writeHead(200, { "content-type": "image/png", "cache-control": "max-age=86400" });
            res.end(logo);
        } else if (req.method === "GET" && path === "/data/index.json") {
            if (indexJson == null) reply(res, 503, "board is not ready");
            else reply(res, 200, indexJson, "application/json; charset=utf-8");
        } else if (req.method === "GET" && path.startsWith("/data/bodies/")) {
            const name = path.slice("/data/bodies/".length);
            const body = SHARD_NAME.test(name) ? shards.get(name) : null;
            if (body == null) reply(res, 404, "not found");
            else reply(res, 200, body, "application/json; charset=utf-8");
        } else if (req.method === "GET" && path === "/events") {
            res.writeHead(200, {
                "content-type": "text/event-stream; charset=utf-8",
                "cache-control": "no-store",
                connection: "keep-alive",
            });
            res.write("retry: 3000\n\n");
            send(res, "status", status());
            clients.add(res);
            armTimer();
            req.on("close", () => {
                clients.delete(res);
                if (!clients.size) disarmTimer();
            });
        } else if (req.method === "POST" && path === "/refresh") {
            disarmTimer();
            schedule("github");
            reply(res, 202, "accepted");
        } else {
            reply(res, 404, "not found");
        }
    });

    const heartbeat = setInterval(() => {
        for (const res of clients) res.write(": ping\n\n");
    }, heartbeatMs);
    heartbeat.unref();

    return {
        server,
        schedule,
        status,
        get clientCount() { return clients.size; },
        reloadPage() { page = html(); },
        listen(listenPort = DEFAULT_PORT) {
            return new Promise((resolveListen, rejectListen) => {
                server.once("error", rejectListen);
                server.listen(listenPort, "127.0.0.1", () => {
                    server.off("error", rejectListen);
                    port = server.address().port;
                    resolveListen(port);
                });
            });
        },
        // Ends the event streams and closes the listener. A build still running is left to
        // finish or be cut off by the process exit; the cache is written atomically.
        async close() {
            disarmTimer();
            clearInterval(heartbeat);
            for (const res of clients) res.end();
            clients.clear();
            server.closeAllConnections();
            await new Promise((resolveClose) => server.close(() => resolveClose()));
        },
    };
}

function parseArgs(argv) {
    const options = { port: DEFAULT_PORT, open: false, cache: DEFAULT_CACHE_PATH };
    for (let i = 0; i < argv.length; i += 1) {
        const arg = argv[i];
        if (arg === "--open") options.open = true;
        else if (arg === "--port" && /^\d+$/.test(argv[i + 1] ?? "")) options.port = Number(argv[++i]);
        else if (arg === "--cache" && argv[i + 1]) options.cache = resolve(argv[++i]);
        else {
            console.error(`未知参数：${arg}`);
            console.error("用法：node scripts/agent-notes/serve-agent-notes-board.mjs [--port <端口>] [--open] [--cache <文件>]");
            process.exit(2);
        }
    }
    return options;
}

function openBrowser(url) {
    const [command, args] = process.platform === "darwin" ? ["open", [url]]
        : process.platform === "win32" ? ["cmd", ["/c", "start", "", url]]
            : ["xdg-open", [url]];
    const child = spawn(command, args, { stdio: "ignore", detached: true });
    child.on("error", () => console.error(`没能自动打开浏览器，请手动打开 ${url}`));
    child.unref();
}

async function main() {
    const options = parseArgs(process.argv.slice(2));
    const log = (message) => console.log(`[${new Date().toLocaleTimeString("zh-CN", { hour12: false })}] ${message}`);
    const board = createBoardServer({
        load: ({ github }) => loadBoard({ cachePath: options.cache, mode: "live", offline: !github, log }),
        html: () => renderPage("live"),
        logo: readFileSync(LOGO_PATH),
        log,
    });

    let port;
    try {
        port = await board.listen(options.port);
    } catch (error) {
        console.error(error.code === "EADDRINUSE"
            ? `端口 ${options.port} 已被占用，用 --port 换一个。`
            : `启动失败：${error.message}`);
        process.exit(1);
    }
    const url = `http://127.0.0.1:${port}/`;
    log(`工程看板：${url}（Ctrl+C 停止）`);

    let rebuild = null;
    const watcher = watch(join(ROOT_DIR, ".agents/notes"), { recursive: true }, () => {
        clearTimeout(rebuild);
        rebuild = setTimeout(() => board.schedule("notes"), WATCH_DEBOUNCE_MS);
    });
    watcher.on("error", (error) => log(`监视 .agents/notes 失败：${error.message}`));

    let stopping = false;
    const stop = async () => {
        if (stopping) return;
        stopping = true;
        setTimeout(() => process.exit(1), SHUTDOWN_TIMEOUT_MS).unref();
        clearTimeout(rebuild);
        watcher.close();
        await board.close();
        process.exit(0);
    };
    process.on("SIGINT", stop);
    process.on("SIGTERM", stop);

    // The Notes come up first so the page has something to show while GitHub is read.
    board.schedule("notes");
    board.schedule("github");
    if (options.open) openBrowser(url);
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
    await main();
}
