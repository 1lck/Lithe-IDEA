# engineering-board-cache

这个分支只保存工程看板的 GitHub 增量缓存 `github.json`，由 Deploy Agent Notes Board 工作流在每次运行后写入，下次运行先读它，再只向 GitHub 读取变化的记录。

- 不要手动修改，也不要合并到 `main`。
- 删除这个分支后，下一次运行从空缓存全量读取并重新创建它。
- 格式和读写规则见 `scripts/agent-notes/engineering-board-github.mjs` 与 `scripts/ci/deploy-agent-notes-board/board-cache.sh`。

This branch only holds the engineering board's GitHub cache. The Pages workflow writes it; do not edit or merge it. Deleting it makes the next run read everything from GitHub.
