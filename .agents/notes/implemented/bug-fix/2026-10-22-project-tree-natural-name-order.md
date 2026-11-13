# Agent 笔记：项目树同级文件名使用 IDEA 自然排序

状态：已实现

## 先说结论

项目树里 `v0.1.12.md` 曾排在 `v0.1.4.md` 前面。当前 Viva 项目树直接显示 Rust Core 的 `workspace.listDirectories` 顺序：目录在文件前，名称采用 IDEA 自然排序；macOS 和 Windows 共用这条路径。快照和搜索索引仍使用各自的遍历顺序。Viva 在 macOS 和 Windows 用共享的递归监听接收外部变化，再重新采用 Core 列表；旧版 Swift 兜底扫描和完整增量插入验证属于迁移前历史。

以下有关 Swift、Tauri 和旧版快速打开的实现描述记录迁移前决策，不代表当前桌面实现。

## 问题

项目树有三处各自排序：Rust Core 的 `visible_children`（主路径，只比较小写字节）、macOS 兜底扫描（`localizedCaseInsensitiveCompare`，不把数字当数）和 `FileNodePathLookup` 的插入位置（小写后比较）。它们既都不是 IDEA 的顺序，也彼此不完全一致：版本号文件名、`file2`/`file10` 这类名字会按字典序排列，文件系统事件新增一个文件后还可能落在和重新扫描不同的位置。

## 决策

IDEA 的项目视图用 `AlphaComparator` 比较同级节点，而它调用的是 `FileNameComparator`，即 `NaturalComparator.naturalCompare(ignoreCase = true, likeFileNames = true)`。Lithe 逐行移植这套算法（参照 intellij-community `d8c6714c7a3c110c56994d6b0f10814f902100e7`）：

- 连续数字按数值比较，位数多的更大：`v0.1.4` < `v0.1.12`；值相同时没有前导零或空格的排在前面：`a1` < `a01`。
- 先忽略大小写比较；全部相同时再按大小写区分，保证顺序稳定：`A.txt` < `a.txt` < `B.txt`。
- `-` 与 `_` 相邻（IDEA-80435）：`foo.bar` < `foo-bar` < `foo_bar`。
- 目录先于文件的规则不变，由树负责，比较器不处理。

### 正确做法

- Rust Core 在 `rust/crates/core/src/project/file_name_order.rs` 提供 `FileNameKey`，`visible_children` 在 `ChildOrder::Tree` 下用 `sort_by_cached_key` 排序；每个名字只转换一次，大目录排序不会按比较次数分配内存。
- `visible_children` 必须由调用方说明要哪种顺序（`ChildOrder`）：只有 `workspace.listDirectories` 使用 `Tree`；快照（`scan_node`、`collect_snapshot_files`）和搜索索引使用 `Traversal`，仍按小写名字排序。
- Swift 在 `NaturalNameOrder`（`LitheCoreContracts`）里持有算法。兜底扫描用 `sortedAsProjectTreeSiblings`，插入文件用 `compareFileNames`；Git 的分支名排序（`GitGraphHeadOrdering.naturalCompare`，不带 `likeFileNames`）也委托给它，不再保留第二份拷贝。
- 新增或调整规则时先改 `Lithe-core-rust/rust/fixtures/workspace/file-name-order-v1.json`，再让 Rust 和 Swift 测试一起通过。

### 树行顺序与遍历顺序分开

快照的 `files` 清单不是显示顺序，而是一条被截断使用的序列：Windows 快速打开（`fffSearchFiles`）先按子串过滤，再只取前 100 项，并以位置给分。如果显示顺序的修改同时改变这条序列，同一个查询在 Windows 上返回的前 100 项会悄悄变化，却没有任何 Windows 改动或验证。所以显示顺序只作用于 `Tree`，`Traversal` 保持原有规则；`workspace_snapshot_keeps_its_traversal_order_while_the_tree_rows_are_natural` 固定这一点。

### 不要这样做

- 不要在树里再加一处 `lowercased()` 或 `localizedCaseInsensitiveCompare` 排序；它会让重新扫描和增量插入的顺序不同。
- 不要为了让 Rust 的排序“看起来更简单”改成 `localeCompare` 一类系统排序：它不是确定性的，也不是 IDEA 的顺序。
- 不要让快照或搜索索引的遍历改用 `ChildOrder::Tree`；要改变快照 `files` 的顺序，必须同时评估 Windows 快速打开等只取前 N 项的使用方。

## 考虑过的备选方案

### 使用系统的 `localizedStandardCompare`

它同样把数字当数，仓库其它列表已经在用。没有采用，是因为它依赖系统区域设置，Rust Core 无法复现；而且不处理 `-`/`_` 相邻和大小写决胜，和 IDEA 的树仍会出现差异。

### 只改 Swift，不改 Rust Core

macOS 项目树的主路径是 Rust Core 的目录列表，兜底扫描只在 Core 失败时使用。只改 Swift 看不到效果。

## 后果

- 项目树和 IDEA 的同级顺序一致，版本号、编号文件名按预期排列。
- 快照 `files`、其中的 `root` 树节点（`includeTree` 为 true 时）和搜索索引保持小写排序；macOS 项目树只使用 `workspace.listDirectories` 的行，所以不受影响。
- Rust 的排序不能接受违反全序的比较函数（可能 panic）。测试里用固定种子的随机名字检查反对称与传递性，移植时不要省略空格、`#`、`-`、`_` 这些特殊字符。
- Windows 项目树（`visible-file-tree-rows.ts`、`file-tree-utils.ts`）仍使用 `localeCompare`，只有 Git 文件树使用 `compareGitFileNames`；是否统一见功能矩阵 `file-explorer`。

## 验证

- `scripts/desktop/desktop-go.sh test -race ./internal/core -run TestWorkspaceDirectoryTreeUsesCoreNaturalOrder -count=3`：真实 Core 消费共享版本号 fixture，验证目录优先及文件自然排序。
- 旧版 Swift 兜底扫描、树内增量插入和快照遍历的历史验证见下方；Viva 的原生窗口和大项目监听覆盖仍需验收。

## 适用范围

- Lithe-core-rust 锁定修订：[rust/lithe-core/src/project/file_name_order.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/project/file_name_order.rs)
- Lithe-core-rust 锁定修订：[rust/lithe-core/src/project/files.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/project/files.rs)
- Lithe-core-rust 锁定修订：[rust/lithe-core/src/project/search_index.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/project/search_index.rs)
- `desktop/internal/core/workspace.go`
- `desktop/internal/core/workspace_tree_test.go`
- `desktop/internal/workbench/filetree.go`
- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/fixtures/workspace/file-name-order-v1.json`

## 迁移前的实现与验证记录

旧版路径固定在提交 [5a54c41](https://github.com/1lck/Lithe-IDEA/tree/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36)：[NaturalNameOrder.swift](https://github.com/1lck/Lithe-IDEA/blob/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/macos/Sources/LitheCoreContracts/Workspace/NaturalNameOrder.swift)、[FileNodePathLookup.swift](https://github.com/1lck/Lithe-IDEA/blob/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/macos/Sources/LitheCoreContracts/Workspace/FileNodePathLookup.swift)、[MacWorkspaceSnapshotBuilder.swift](https://github.com/1lck/Lithe-IDEA/blob/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/macos/Sources/Lithe/Platform/MacOS/FileSystem/MacWorkspaceSnapshotBuilder.swift)。当时的 Rust 排序测试覆盖 fixture、全序检查和快照遍历顺序；[macOS 测试入口](https://github.com/1lck/Lithe-IDEA/blob/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/scripts/macos/test/test-macos.sh)运行 ProjectTreeNameOrderTests 和 GitGraphLayoutTests，并人工检查外部新增文件的插入位置。这些历史记录不能证明 Viva 在原生窗口中的表现。
