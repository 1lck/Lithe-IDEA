# Agent 笔记：大型未跟踪目录按目录汇总，变更列表只构建可见行

状态：已实现

## 先说结论

一个没被忽略的构建目录（例如 `rust/target/`）曾让 Commit 面板出现 5,000 多条变更，帧率掉到 2 FPS（Issue #1385）。现在 Core 只把"整个目录都未跟踪、且里面没有嵌套仓库"的大目录报告成一条带文件数的目录汇总，用户展开时再一层一层列出。桌面端的变更列表和项目树都按这条汇总工作，列表只构建当前可见的行。

## 问题

问题有两层，任何一层单独存在都会让面板随变更数量变慢：

1. **Core 把一个目录拆成成千上万条记录。** `git.status` 使用 `--untracked-files=all`，Git 会把未跟踪目录下的每个文件都列出来。每次文件监听触发刷新（构建过程中非常频繁），这些记录都要经过 JSON 编解码、比较、分组和项目树着色。
2. **界面把整组行包成一个大块去绘制。** 每个仓库的标题和全部文件行如果被当作一个整体创建，仓库一出现在可见区域，它下面的几千行（每行带按钮、复选框、图标和提示）就会全部构建。

## 决策

**Core 的汇总规则**（Core 仓库的 `rust/crates/git/src/untracked_directories.rs`）：

- `git.status` 的可选参数 `summarizeUntrackedDirectories` 打开后改用 Git 的 `--untracked-files=normal` 视图，Git 在每个整体未跟踪的目录处停下，只报告 `dir/`。桌面端的状态读取默认打开它（`desktop/internal/core/git.go`）。
- 对这些目录，Core 用一次 `git ls-files --others --exclude-standard` 拿到其中的文件，再逐个决定：超过 100 个文件就报告成一条汇总（`path` 以 `/` 结尾并带 `untrackedFileCount`）；不超过 100 个文件仍按文件逐条报告，所以新建的小源码目录照常显示。
- **含嵌套仓库的目录绝不汇总。** 例如 `.worktrees/` 里有 linked worktree，暂存 `.worktrees/` 会把这些独立仓库记成 gitlink（父仓库里的子仓库指针）。这种目录会继续向下拆分，直到每个汇总里都没有嵌套仓库。这样，对汇总路径执行暂存、丢弃或 diff，作用范围正好是它统计的那些文件。
- `git.untrackedDirectory` 每次只列一层：直接子文件，以及每个子目录的汇总。桌面端通过 `GitUntrackedDirectory`（`desktop/internal/core/git_untracked.go`）调用它。
- 不打开这个参数时行为不变，一次性读取仍拿到逐文件列表。

**桌面端的展开与显示：**

- 汇总目录的展开状态保存在工作台的变更状态里（`desktop/internal/workbench/gitreview.go` 的 `openUntracked` 与 `enterUntracked` / `leaveUntracked`），每次只列出一层。展开的内容在刷新时重新列出，因此暂存、丢弃和选择都把这些子项当作普通变更处理。
- 项目树（`desktop/internal/workbench/filetree_status.go`）把汇总目录下的文件视为未跟踪文件：颜色、计数和行标记与逐文件时一致。提交面板（`desktop/internal/workbench/commit_view.go`）在汇总条目旁显示它的文件数。
- 展开集合在列出结果后如果已经变化，要按当前集合重建结果，不能用刷新开始时的旧集合覆盖用户的操作。

**围绕汇总条目的操作也必须按目录工作**，否则会悄悄出错：

- `git.diff` 带 `untracked` 且路径是目录时，展开成目录下的每个文件分别做 diff。如果不这样做，"搁置"（Shelve）功能会先给目录生成一个空补丁，然后又把目录清掉，造成数据丢失。
- 目录 diff 遇到无法导出的文件（例如名字含 `:`，路径校验会拒绝）时，整个 diff 报错，不能跳过。搁置保存补丁后会把整个目录清掉，跳过的文件就会被删掉而且没有备份。
- 搁置必须区分"读不到补丁"和"补丁为空"：任何一条补丁读不到，整个搁置就中止，不保存也不清理。
- 丢弃全部（`discardAll`）能把 `dir/` 识别为未跟踪路径，用 `git clean` 删除，而不是对它执行 `git restore`。
- `discardAll` 的状态查询只传本次路径，不在每个回滚文件上重复执行全库 `--untracked-files=all`；解析重命名源路径时要消费 NUL 记录，避免把以 `?? ` 开头的源文件名误当未跟踪文件。查询和清理按路径参数预算分批，并采用字面路径语义，保护方括号等特殊文件名的邻居。
- 汇总只在提交范围内记录 `dir/` 这一个键。Core 的提交范围检查只按字面路径比较，所以归属需要逐个文件列出，否则在该变更列表中提交会被拒，而默认列表的提交会把这些文件一起带走。

正确做法：大列表的每一行只在可见时构建，汇总和分组数据在缓存里一次算好，不要把整组子项当作一个整体去渲染。

## 考虑过的备选方案

- **只改 `.gitignore`。** 只能解决本仓库这一种目录。用户项目里任何未忽略的 `target/`、`node_modules/` 仍会让面板卡死，没有修到产品本身。
- **只修界面渲染。** 渲染会变快，但每次刷新仍要传输和处理与文件数成正比的数据（5,280 个文件约 721 KiB）；一个未忽略的 `node_modules/` 会让每次刷新都处理几十万条记录。
- **直接使用 `--untracked-files=normal` 的原始结果。** 新建的小源码目录也会变成需要展开的目录行，日常体验变差；而且 `.worktrees/` 这种只含嵌套仓库的目录会被整个折叠，暂存时会产生 gitlink。
- **对未跟踪文件总数设硬上限后截断。** 截断后计数、暂存范围和用户看到的内容不一致，丢弃和提交操作也难以保证正确。

## 后果

收益：在 issue 的场景里，变更面板的 status 从 5,281 条、721 KiB、49 ms 降到 2 条、不到 1 KiB、22.5 ms；界面开销只与可见行数有关，暂存后出现的数千条已跟踪变更也不会再卡住界面。

代价：

- 汇总目录本身不能直接查看 diff，要展开后逐个文件查看。
- 展开状态下，每次刷新都要为每个展开的目录多调用一次 Git。
- 一个已跟踪目录里直接放着大量未跟踪文件（不在子目录中）时，Core 无法安全地汇总，因为暂存这个目录会连同已跟踪文件的修改一起暂存。这种情况只依靠界面按可见行绘制保证流畅。

## 验证

- Core 仓库的未跟踪目录单元测试（`cargo test -p lithe-core --lib untracked` 所在的 Core 检出）。
- `desktop/internal/core/git_review_test.go`、`desktop/internal/workbench/filetree_status_test.go`、`desktop/internal/workbench/shelf_test.go`：覆盖汇总状态、项目树着色与搁置。
- `scripts/desktop/desktop-go.sh test ./internal/core/... ./internal/workbench/...`
- `scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`
- `scripts/agent-notes/verify-agent-notes.sh`

实机验收步骤见功能矩阵 `git-large-untracked-directories`。组件测试不能替代真实仓库下的滚动和帧率检查。

## 适用范围

- `desktop/internal/core/git.go`
- `desktop/internal/core/git_untracked.go`
- `desktop/internal/workbench/gitreview.go`
- `desktop/internal/workbench/filetree_status.go`
- `desktop/internal/workbench/commit_view.go`
- Core 仓库的 [`rust/crates/git/src/untracked_directories.rs`](https://github.com/Lithe-IDEA/Lithe-core-rust/tree/main/rust/crates/git/src/untracked_directories.rs)，以 [Lithe-core-rust](https://github.com/Lithe-IDEA/Lithe-core-rust) 当前固定的修订为准。
