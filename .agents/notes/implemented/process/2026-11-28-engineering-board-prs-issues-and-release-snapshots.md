# Agent 笔记：工程看板加入跨仓库 PR 与 Issue，发版时发布快照

状态：已实现

## 先说结论

原来的 Agent Notes 看板只展示决策。现在它是“工程看板”：除了 Note，还列出主仓库和 Lithe-IDEA 组织所有公开、未归档仓库的 PR 与 Issue，并把它们和 Note 互相关联。点任何一项都在右侧抽屉里展开，只看 PR 或 Issue 本身（标题、正文、状态、标签、关联），不看代码差异和评论内容。

公开的 Pages 页面不再随每次合并更新，而是在每次桌面端发版成功后生成一份快照；要看实时的评审、CI 和冲突状态，在本地运行 `node scripts/agent-notes/serve-agent-notes-board.mjs`。Note 仍是决策的唯一来源，PR 和 Issue 的数据只是 GitHub 的只读副本。

## 问题

维护者每天要处理主仓库、Rust Core、插件仓库、Store 和 Viva fork 的 PR 与 Issue，外部贡献者也会在这些仓库里提交。原看板只读 `.agents/notes/`，看不到“哪个 PR 落地了哪个决策、哪个 Issue 还没有 PR、哪个外部 PR 在等评审”。在 GitHub 上逐个仓库翻又会丢失跨仓库的关联，例如桌面 PR 依赖的 Core PR。

同时，看板要公开发布，所以不能带私有仓库的内容；已经归档的仓库不再需要处理，也不应出现在待处理列表里。

## 决策

### 数据从哪里来

- **Note**：构建时从当前工作区读取 `.agents/notes/`，解析规则与校验器共用 [`scripts/agent-notes/agent-notes-parser.mjs`](../../../../scripts/agent-notes/agent-notes-parser.mjs)。每篇 Note 的演进时间线来自 `main` 的第一父提交历史：提交标题以 `(#N)` 结尾、且 GitHub 记录该 PR 正是以这个提交合入（或标题与 PR 标题一致）时，才算这个 PR 交付了这篇 Note。
- **PR 与 Issue**：[`scripts/agent-notes/engineering-board-github.mjs`](../../../../scripts/agent-notes/engineering-board-github.mjs) 用 GitHub GraphQL 读取。仓库范围是 `1lck/Lithe-IDEA`，加上每次刷新时重新发现的 `Lithe-IDEA` 组织下所有公开、未归档仓库；仓库归档或转为私有后，下次刷新就把它的记录从缓存里删掉。
- **增量缓存**：读取结果写在 `.artifacts/agent-notes-board/cache/github.json`（先写临时文件再改名，进程中断也不会留下半个文件）。每个仓库按更新时间保存水位线，下次只读更新过的记录；打开的 PR 每次都重新读，因为评审、CI 和冲突状态会变但不一定改变更新时间。缓存可以随时删除，删除后下一次构建全量读取。

### 关联怎么算

[`scripts/agent-notes/engineering-board-links.mjs`](../../../../scripts/agent-notes/engineering-board-links.mjs) 从 PR、Issue 和 Note 的正文里找引用，规则尽量和 GitHub 的显示一致：完整链接、`owner/repo#N`、裸 `#N`（指当前仓库）都算；HTML 注释、代码块和行内代码里的编号不算。跨仓库的简写由 `BOARD_CONFIG.prefixes` 声明，例如 `Core #12` 指 Rust Core，插件仓库可以用 `go #26` 这类短名。

每对条目只保留最强的一种关系：关闭（`Fixes`、`Closes`）、Note 交付（新增、改名、修改、删除）、`Refs` 类引用、正文提到。看板用它画“问题 → 交付 → 决策”的关联链路。

### 页面怎么用

页面模板是 [`assets/agent-notes-board.html`](../../../../assets/agent-notes-board.html)，构建时把关联扫描器内联进去。四个页签：

- **待处理**：只看打开的 PR 和 Issue，标出草稿、待评审、已批准、要求修改、CI 失败或运行中、有冲突、外部贡献者、多少天没动、没有回复的 Issue（只看评论数）；上方按仓库汇总，没有打开项的仓库默认折叠。
- **PR**、**Issue**：全部记录，可按状态、类型、关联和仓库筛选。
- **决策**：原来的架构基线、演进时间线、避坑智库和决策清单。

点任何一项都在右侧抽屉展开，抽屉里的关联可以继续点，不跳转到 GitHub；只保留一个“GitHub ↗”按钮。PR 和 Issue 的正文不放进首屏数据，而是按仓库和编号分片（`data/bodies/<仓库>--<编号/100>.json`），打开抽屉时才加载。公开页面请求索引和分片时用 `no-cache`：浏览器保留副本，每次只向服务器确认是否有新快照，没有就收到 304，不会每次访问都重新下载几 MB；本地实时模式的数据在内存里随时变化，用 `no-store`。

### 公开快照和本地实时模式

- **Pages**：[`.github/workflows/deploy-agent-notes-board.yml`](../../../../.github/workflows/deploy-agent-notes-board.yml) 在 `Desktop Release` 工作流成功完成后运行（`workflow_run`），也可以手动运行。它校验 Note、生成功能矩阵，再执行 `scripts/agent-notes/build-agent-notes-board.mjs` 读取 GitHub 并输出静态站点。读不到 GitHub 时构建失败，Pages 保留上一版，不会发布一份没有 PR 和 Issue 的看板。同一站点里的平台功能矩阵也随之改为发版时更新。
- **本地实时模式**：[`scripts/agent-notes/serve-agent-notes-board.mjs`](../../../../scripts/agent-notes/serve-agent-notes-board.mjs) 只监听 `127.0.0.1`，数据放在内存里。启动时先用 Note 和缓存出一版，再增量读取 GitHub；页面开着时每 10 分钟刷新一次，也可以点“刷新”；保存 Note 会立即重建，但不访问 GitHub。页面通过 `/events`（服务器推送事件）得知新版本后重新拉取数据。令牌按 `GITHUB_TOKEN`、`GH_TOKEN`、`gh auth token` 的顺序查找，只在服务器进程里使用，不交给页面。

### 正确做法

- 新增一个需要简写的跨仓库前缀：在 `BOARD_CONFIG.prefixes` 里加一行，并在 [`scripts/agent-notes/test-engineering-board.mjs`](../../../../scripts/agent-notes/test-engineering-board.mjs) 的引用扫描测试里加例子。
- 想看评审和 CI 的最新状态：运行本地实时模式，而不是手动触发 Pages 工作流。

### 不要这样做

- 不要把生成的站点或 GitHub 缓存提交到仓库；它们都在 `.artifacts/` 下，可以随时重建。
- 不要让页面直接带着令牌调用 GitHub。公开页面没有令牌，本地页面拿到令牌也会扩大泄露面。
- 不要为了“更完整”去读评论内容或代码差异。看板只回答“这项工作是什么、和谁有关、现在卡在哪”。

## 考虑过的备选方案

### 每次合并 main 都重新发布

这是原来的做法，公开页面总是最新的。但现在每次发布都要读二十多个仓库的 GitHub 数据；维护者也只需要在发版节点看一次全局，日常的实时状态用本地模式更准确。因此改为发版后发布，功能矩阵一起改为发版时更新。

### 由 `desktop-v*` 标签直接触发

这样最直观。但仓库的 `github-pages` 环境只允许从 `main` 部署，标签触发的任务会被环境规则拒绝；要放开就得改仓库设置。`workflow_run` 任务运行在默认分支上，不用改设置，也只在发版成功后运行。

### 页面在浏览器里直接调用 GitHub API

不需要构建步骤。但公开页面没有令牌，未认证请求每小时只有 60 次；本地模式如果把令牌交给页面，任何能读页面的脚本都能拿到它。所以读取放在构建脚本和本地服务器里。

### 读取评论和代码差异

信息更全。但数据量会成倍增长，公开快照还会复制所有评论；维护者在看板上只需要判断优先级，细节仍在 GitHub 看。最后只保留评论数，用来判断 Issue 有没有人回复。

### 继续把全部数据内嵌到一个 HTML 文件

原来的单文件看板可以离线打开。现在有两千多个 PR、八百多个 Issue，全部正文内嵌后首屏要下载十几 MB。改为首屏只加载索引，正文按需加载。

### 包含私有仓库

能看到全部工作。但 Pages 是公开的，会把私有仓库的标题和正文发布出去，因此只读公开仓库。

## 后果

- 维护者在一个页面里看到所有公开仓库需要处理的 PR 和 Issue，以及它们和决策的关联；外部贡献、CI 失败、冲突和无人回复的 Issue 都有单独的信号。
- 代价一：公开快照在两次发版之间会落后，评审、CI 和冲突状态可能已经变化；页面会写明快照时间，并提示用本地实时模式。
- 代价二：首屏索引包含全部 Note 正文和全部 PR、Issue 的摘要字段，目前约 4.8 MB（gzip 后约 1.4 MB），会随仓库增长。
- 代价三：Pages 工作流不在两次运行之间保存缓存，每次发版都从空缓存全量读取。2026-11-28 在本机实测，全量读取 3102 条记录用了 33 次请求、约 2 分钟；有缓存时增量读取用了 11 次请求、约 24 秒，其中多数记录是每次都要重读的打开 PR。每次发版只运行一次，没有为它另加缓存步骤。
- 代价四：Actions 的 `GITHUB_TOKEN` 要能读取其他组织的公开仓库。如果某次发版后构建因权限失败，Pages 保留旧版，需要改用有只读权限的令牌。
- 需要重新评估的情况：首屏索引超过 10 MB，或组织转为私有仓库为主，或 Pages 不再公开。

## 验证

- `./scripts/agent-notes/verify-agent-notes.sh`
- `node --test scripts/agent-notes/test-engineering-board.mjs`
- `node scripts/agent-notes/build-agent-notes-board.mjs --offline`
- `git diff --check`

## 适用范围

- `assets/agent-notes-board.html`
- `scripts/agent-notes/build-agent-notes-board.mjs`
- `scripts/agent-notes/serve-agent-notes-board.mjs`
- `scripts/agent-notes/engineering-board-model.mjs`
- `scripts/agent-notes/engineering-board-github.mjs`
- `scripts/agent-notes/engineering-board-links.mjs`
- `scripts/agent-notes/test-engineering-board.mjs`
- `scripts/agent-notes/agent-notes-parser.mjs`
- `.agents/skills/agent-notes/SKILL.md`
- `.github/workflows/deploy-agent-notes-board.yml`
- `.github/workflows/verify-agent-notes.yml`
- `.agents/notes/`
