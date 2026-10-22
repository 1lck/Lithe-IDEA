# Agent 笔记：大型未跟踪目录按目录汇总，变更列表只构建可见行

状态：已实现

## 先说结论

一个没被忽略的构建目录（例如 `rust/lithe-core/target/`）曾让 Commit 面板出现 5,000 多条变更，帧率掉到 2 FPS（Issue #1385）。现在 Core 只把"整个目录都未跟踪、且里面没有嵌套仓库"的大目录报告成一条带文件数的目录汇总，用户展开时再一层一层列出。macOS 变更列表的每个标题和每一行都直接交给 `LazyVStack`（SwiftUI 的懒加载栈，只为屏幕上可见的行创建视图），变更再多也只构建可见行。

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
- 不传这个参数时行为不变，Windows 目前仍拿到逐文件列表。

**围绕汇总条目的操作也必须按目录工作**，否则会悄悄出错：

- `git.diff` 带 `untracked` 且路径是目录时，展开成目录下的每个文件分别做 diff。如果不这样做，"搁置"（Shelve）功能会先给目录生成一个空补丁，然后又把目录清掉，造成数据丢失。
- `discardAll` 能把 `dir/` 识别为未跟踪路径，用 `git clean` 删除，而不是对它执行 `git restore`。

**macOS 端：**

- 变更面板使用 `changesSnapshot`；分支对比和 worktree 详情仍拿逐文件列表，行为不变。
- 展开的目录内容由 `GitFeatureModel` 直接插入到 `gitChanges` 中、紧跟在汇总条目后面，每次刷新都重新列出。因此暂存、丢弃、选择和 diff 都把这些子项当作普通变更处理，不需要另外维护一套状态。
- `GitTreeStatusProjection`（把 Git 状态映射到项目树和编辑器的那层）对汇总目录下的文件，会合成一条逐文件的未跟踪记录。项目树着色、编辑器行标记和 Show Diff 的结果与之前一致。
- 计数按文件统计（`gitChangedFileCount`）：一条汇总按它的文件数计；已展开的子项已经算在汇总里，不重复计数。
- `GitChangeSectionsCache.rows` 把仓库标题、ChangeList 标题和每一条变更拍平成一个行数组，`ForEach` 直接放在 `LazyVStack` 中。

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
- Windows 尚未接入汇总，仍然逐文件显示。

## 验证

- `cargo test --manifest-path rust/Cargo.toml -p lithe-core --lib untracked`
- `./scripts/test-macos.sh --filter 'GitChangeSectionsCacheTests|GitLocalChangelistsTests|treeStatus|untrackedDirectorySummary|GitStatusObservationTests'`
- `./scripts/verify-rust-core.sh`
- `./scripts/verify-service-boundaries.sh`
- `./scripts/verify-platform-feature-matrix.sh`
- `./scripts/verify-agent-notes.sh`

实机验收步骤见功能矩阵 `git-large-untracked-directories`。组件测试不能替代真实仓库下的滚动和帧率检查。

## 适用范围

- `rust/lithe-core/src/git/untracked_directories.rs`
- `rust/lithe-core/src/git/mod.rs`
- `macos/Sources/LitheGitModule/Application/GitFeatureModel.swift`
- `macos/Sources/LitheGitModule/Models/GitModels.swift`
- `macos/Sources/Lithe/Views/Git/ChangesSidebarView.swift`
- `macos/Sources/Lithe/Views/Git/GitChangeSectionsCache.swift`
