# Agent 笔记：大型未跟踪目录按目录汇总，变更列表只构建可见行

状态：已实现

## 先说结论

一个没被忽略的构建目录（例如 `rust/lithe-core/target/`）曾让 Commit 面板出现 5,000 多条变更，帧率掉到 2 FPS（Issue #1385）。现在 Core 只把"整个目录都未跟踪、且里面没有嵌套仓库"的大目录报告成一条带文件数的目录汇总，用户展开时再一层一层列出。macOS 和 Windows 都接入了这个汇总。macOS 变更列表的每个标题和每一行都直接交给 `LazyVStack`（SwiftUI 的懒加载栈，只为屏幕上可见的行创建视图），变更再多也只构建可见行；Windows 的列表本来就是虚拟列表。

## 问题

问题有两层，任何一层单独存在都会让面板随变更数量变慢：

1. **Core 把一个目录拆成成千上万条记录。** `git.status` 使用 `--untracked-files=all`，Git 会把未跟踪目录下的每个文件都列出来。每次文件监听触发刷新（构建过程中非常频繁），这些记录都要经过 JSON 编解码、比较、分组和项目树着色。
2. **视图把整组行包在一个子视图里。** 多仓库模式下，每个仓库的标题和全部文件行被包在一个普通 `VStack` 里。外层的 `LazyVStack` 只能按"仓库"这一级懒加载，仓库一出现在屏幕上，它下面的 5,000 行（每行带按钮、复选框、图标、右键菜单和提示）就会全部创建。

## 决策

**Core 的汇总规则**（`rust/lithe-core/src/git/untracked_directories.rs`）：

- `git.status` 新增可选参数 `summarizeUntrackedDirectories`。打开后改用 Git 的 `--untracked-files=normal` 视图，Git 在每个整体未跟踪的目录处停下，只报告 `dir/`。
- 对这些目录，Core 用一次 `git ls-files --others --exclude-standard` 拿到其中的文件，再逐个决定：超过 100 个文件就报告成一条汇总（`path` 以 `/` 结尾并带 `untrackedFileCount`）；不超过 100 个文件仍按文件逐条报告，所以新建的小源码目录照常显示。
- **含嵌套仓库的目录绝不汇总。** 例如 `.worktrees/` 里有 linked worktree（关联工作树），暂存 `.worktrees/` 会把这些独立仓库记成 gitlink（父仓库里的子仓库指针）。这种目录会继续向下拆分，直到每个汇总里都没有嵌套仓库。这样，对汇总路径执行暂存、丢弃或 diff，作用范围正好是它统计的那些文件。
- `git.untrackedDirectory` 每次只列一层：直接子文件，以及每个子目录的汇总。
- 不传这个参数时行为不变，一次性读取（例如 Windows 的 Shelf）仍拿到逐文件列表。

**围绕汇总条目的操作也必须按目录工作**，否则会悄悄出错：

- `git.diff` 带 `untracked` 且路径是目录时，展开成目录下的每个文件分别做 diff。如果不这样做，"搁置"（Shelve）功能会先给目录生成一个空补丁，然后又把目录清掉，造成数据丢失。
- 目录 diff 遇到无法导出的文件（例如名字含 `:`，路径校验会拒绝）时，整个 diff 报错，不能跳过。Shelve 保存补丁后会把整个目录清掉，跳过的文件就会被删掉而且没有备份。逐文件操作时，这类文件会被路径校验直接拒绝，所以以前不会出问题。
- macOS 的 Shelve 必须区分"读不到补丁"和"补丁为空"：`workingDiffPatch` / `stagedDiffPatch` 读不到时返回 nil，任何一条读不到，整个搁置就中止，不保存也不清理。以前把读取失败当成空补丁跳过，接着照样清理这条变更。
- `discardAll` 能把 `dir/` 识别为未跟踪路径，用 `git clean` 删除，而不是对它执行 `git restore`。

**macOS 端：**

- 变更面板使用 `changesSnapshot`；分支对比和 worktree 详情仍拿逐文件列表，行为不变。
- 展开的目录内容由 `GitFeatureModel` 直接插入到 `gitChanges` 中、紧跟在汇总条目后面，每次刷新都重新列出。因此暂存、丢弃、选择和 diff 都把这些子项当作普通变更处理，不需要另外维护一套状态。
- `GitTreeStatusProjection`（把 Git 状态映射到项目树和编辑器的那层）对汇总目录下的文件，会合成一条逐文件的未跟踪记录。项目树着色、编辑器行标记和 Show Diff 的结果与之前一致。
- 计数按文件统计（`gitChangedFileCount`）：一条汇总按它的文件数计；已展开的子项已经算在汇总里，不重复计数。
- 逐条执行的写操作（Rollback、Shelve）先去掉同一批里被汇总覆盖的子项。否则同一个文件会在搁置补丁里写两次，恢复时 `git apply` 失败；或者汇总被清理后，子项的 `git restore` 报错并中断。
- 把汇总移到 ChangeList 后，ChangeList 只记录 `dir/` 这一个键，目录下的文件继承它的归属。Core 的提交范围检查（`PathScope`）只按字面路径比较，所以 `commitScope` 会把继承归属的文件逐个列出。否则在该 ChangeList 中提交会被拒，而默认列表的提交会把这些文件一起带走。
- 刷新在等待目录内容时，用户可能折叠或展开目录。列出结果后，如果展开集合变了，就按当前集合重建结果（已经读到的列表直接复用），不能用刷新开始时的旧集合覆盖用户的操作。只有本次读取一开始就请求过、但结果里已经没有的汇总，才会被忘掉。Windows 的 `listExpandedUntrackedDirectories` 遵循同样的规则。
- `GitChangeSectionsCache.rows` 把仓库标题、ChangeList 标题和每一条变更拍平成一个行数组，`ForEach` 直接放在 `LazyVStack` 中。

**Windows 端：**

- 只有写入 `repositoryStatuses`（Windows 唯一的状态真源）的读取 `getRepositoryGitStatuses` 打开汇总。Shelf、Diff 审查、GitHub 等一次性读取继续使用逐文件的 `getGitStatus`。
- 展开状态保存在 `git-untracked-directory-expansions.ts`，按仓库记录，不持久化。展开的内容在同一次状态读取中列出，并紧跟汇总写进仓库快照，然后像其他状态一样发布一次。这样 Commit 面板、项目树、页脚和编辑器看到的是同一份结果，没有第二份可写的状态。
- 文件夹视图中，展开后的内容会形成一个同名文件夹，由这个文件夹代表该汇总：汇总行被移除，折叠这个文件夹就是收起汇总。已记住的文件夹折叠状态不会挡住展开的内容。
- 项目树颜色、页脚计数、编辑器装订线和行历史查询，都按"汇总目录下的文件是未跟踪文件"处理；ChangeList 的继承规则和提交范围与 macOS 一致；删除时去掉被汇总覆盖的子项；汇总本身不参与 Diff。

正确做法：新增大列表时，让每一行都是懒加载栈的直接子项，汇总和分组数据在缓存里一次算好。

不要这样做：

```swift
LazyVStack {
    ForEach(groups) { group in
        VStack { header(group); ForEach(group.rows) { row($0) } } // 整组被当成一个子项，所有行都会被创建
    }
}
```

## 考虑过的备选方案

- **只改 `.gitignore`。** 只能解决本仓库这一种目录。用户项目里任何未忽略的 `target/`、`node_modules/` 仍会让面板卡死，没有修到产品本身。
- **只修视图懒加载。** 渲染会变快，但每次刷新仍要传输和处理与文件数成正比的 JSON（5,280 个文件约 721 KiB）；一个未忽略的 `node_modules/` 会让每次刷新都处理几十万条记录，真正有意义的改动也被淹没。
- **直接使用 `--untracked-files=normal` 的原始结果。** 新建的小源码目录也会变成需要展开的目录行，日常体验变差；而且 `.worktrees/` 这种只含嵌套仓库的目录会被整个折叠，暂存时会产生 gitlink。
- **对未跟踪文件总数设硬上限后截断。** 截断后计数、暂存范围和用户看到的内容不一致，丢弃和提交操作也难以保证正确。

## 后果

收益：在 issue 的场景里，变更面板 status 从 5,281 条、721 KiB、49 ms 降到 2 条、不到 1 KiB、22.5 ms；视图开销只与可见行数有关，暂存后出现的数千条已跟踪变更也不会再卡住界面。

代价：

- 汇总目录本身不能直接查看 diff，要展开后逐个文件查看。
- 展开状态下，每次刷新都要为每个展开的目录多调用一次 Git。
- 一个已跟踪目录里直接放着大量未跟踪文件（不在子目录中）时，Core 无法安全地汇总，因为暂存这个目录会连同已跟踪文件的修改一起暂存。这种情况只依靠视图懒加载保证流畅。
- Windows 每次读取状态时，每个展开的目录都要多调用一次 Core。

## 验证

- `cargo test --manifest-path rust/Cargo.toml -p lithe-core --lib untracked`
- `./scripts/macos/test/test-macos.sh --filter 'GitChangeSectionsCacheTests|GitLocalChangelistsTests|treeStatus|untrackedDirectorySummary|GitStatusObservationTests'`
- `./scripts/rust-core/verify-rust-core.sh`
- `./scripts/architecture/verify-service-boundaries.sh`
- `./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`
- `./scripts/agent-notes/verify-agent-notes.sh`
- `./scripts/windows/verify/verify-windows-boundaries.sh`
- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`

实机验收步骤见功能矩阵 `git-large-untracked-directories`。组件测试不能替代真实仓库下的滚动和帧率检查。

## 适用范围

- `rust/lithe-core/src/git/untracked_directories.rs`
- `rust/lithe-core/src/git/mod.rs`
- `macos/Sources/LitheGitModule/Application/GitFeatureModel.swift`
- `macos/Sources/LitheGitModule/Models/GitModels.swift`
- `macos/Sources/Lithe/Views/Git/ChangesSidebarView.swift`
- `macos/Sources/Lithe/Views/Git/GitChangeSectionsCache.swift`
- `windows/tauri/src/features/git/api/git-status-api.ts`
- `windows/tauri/src/features/git/services/git-untracked-directory-expansions.ts`
- `windows/tauri/src/features/git/utils/git-untracked-directories.ts`
- `windows/tauri/src/features/git/components/status/git-status-panel.tsx`
