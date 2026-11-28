#!/usr/bin/env node
// Builds the published engineering board: a static site with the Agent Notes, the PRs and
// Issues of the followed repositories and the links between them.
//
//   node scripts/agent-notes/build-agent-notes-board.mjs [--out <目录>] [--cache <文件>] [--offline]
//
// The default output is .artifacts/agent-notes-board/site. GitHub is read incrementally into
// the cache file; a failed read stops the build so a release never publishes a board without
// PRs and Issues. --offline builds from the cache alone.
import { resolve } from "node:path";
import { DEFAULT_CACHE_PATH, ROOT_DIR, loadBoard, renderPage, writeSite } from "./engineering-board-model.mjs";

function parseArgs(argv) {
    const options = {
        out: resolve(ROOT_DIR, ".artifacts/agent-notes-board/site"),
        cache: DEFAULT_CACHE_PATH,
        offline: false,
    };
    for (let i = 0; i < argv.length; i += 1) {
        const arg = argv[i];
        if (arg === "--offline") options.offline = true;
        else if (arg === "--out" && argv[i + 1]) options.out = resolve(argv[++i]);
        else if (arg === "--cache" && argv[i + 1]) options.cache = resolve(argv[++i]);
        else {
            console.error(`未知参数：${arg}`);
            console.error("用法：node scripts/agent-notes/build-agent-notes-board.mjs [--out <目录>] [--cache <文件>] [--offline]");
            process.exit(2);
        }
    }
    return options;
}

const options = parseArgs(process.argv.slice(2));
try {
    const board = await loadBoard({
        cachePath: options.cache,
        mode: "static",
        offline: options.offline,
        requireGitHub: !options.offline,
        log: (message) => console.log(message),
    });
    writeSite(options.out, board, renderPage("static"));
    const { index } = board;
    const prs = index.items.filter((item) => item.kind === "pr").length;
    console.log(
        `已生成看板：${options.out}（${index.notes.length} 篇 Note，${prs} 个 PR，` +
        `${index.items.length - prs} 个 Issue，${index.repos.length} 个仓库，${index.relations.length} 条关联）`,
    );
} catch (error) {
    console.error(`生成看板失败：${error.message}`);
    process.exit(1);
}
