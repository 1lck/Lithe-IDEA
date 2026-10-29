# Agent 笔记：项目树同级文件名使用 IDEA 自然排序

状态：已实现

## 先说结论

macOS 项目树里 `v0.1.12.md` 曾排在 `v0.1.4.md` 前面，因为各处只是把名字转成小写后逐字符比较。现在同一层的目录始终排在文件前，名字则沿用 IDEA 项目视图的“自然排序”：数字按数值比较、忽略大小写、`-` 与 `_` 相邻。Rust Core 的目录列表、macOS 兜底扫描和树内新增文件三处使用同一套规则，由共享 fixture 保证一致。快照 `files` 和搜索索引的遍历顺序不属于显示顺序，保持原样，因此 Windows 快速打开等依赖它的功能不受影响。

## 问题

项目树有三处各自排序：Rust Core 的 `visible_children`（主路径，只比较小写字节）、macOS 兜底扫描（`localizedCaseInsensitiveCompare`，不把数字当数）和 `FileNodePathLookup` 的插入位置（小写后比较）。它们既都不是 IDEA 的顺序，也彼此不完全一致：版本号文件名、`file2`/`file10` 这类名字会按字典序排列，文件系统事件新增一个文件后还可能落在和重新扫描不同的位置。

## 决策

IDEA 的项目视图用 `AlphaComparator` 比较同级节点，而它调用的是 `FileNameComparator`，即 `NaturalComparator.naturalCompare(ignoreCase = true, likeFileNames = true)`。Lithe 逐行移植这套算法（参照 intellij-community `d8c6714c7a3c110c56994d6b0f10814f902100e7`）：

- 连续数字按数值比较，位数多的更大：`v0.1.4` < `v0.1.12`；值相同时没有前导零或空格的排在前面：`a1` < `a01`。
- 先忽略大小写比较；全部相同时再按大小写区分，保证顺序稳定：`A.txt` < `a.txt` < `B.txt`。
- `-` 与 `_` 相邻（IDEA-80435）：`foo.bar` < `foo-bar` < `foo_bar`。
- 目录先于文件的规则不变，由树负责，比较器不处理。

### 正确做法

- Rust Core 在 `rust/lithe-core/src/project/file_name_order.rs` 提供 `FileNameKey`，`visible_children` 在 `ChildOrder::Tree` 下用 `sort_by_cached_key` 排序；每个名字只转换一次，大目录排序不会按比较次数分配内存。
- `visible_children` 必须由调用方说明要哪种顺序（`ChildOrder`）：只有 `workspace.listDirectories` 使用 `Tree`；快照（`scan_node`、`collect_snapshot_files`）和搜索索引使用 `Traversal`，仍按小写名字排序。
- Swift 在 `NaturalNameOrder`（`LitheCoreContracts`）里持有算法。兜底扫描用 `sortedAsProjectTreeSiblings`，插入文件用 `compareFileNames`；Git 的分支名排序（`GitGraphHeadOrdering.naturalCompare`，不带 `likeFileNames`）也委托给它，不再保留第二份拷贝。
- 新增或调整规则时先改 `shared/fixtures/workspace/file-name-order-v1.json`，再让 Rust 和 Swift 测试一起通过。

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

- `cargo test --manifest-path rust/lithe-core/Cargo.toml --lib file_name_order`：共享 fixture、特殊字符的全序检查、`workspace.listDirectories` 的目录优先与版本号顺序，以及快照 `files`（含与不含 `includeTree`）保持遍历顺序。
- `./scripts/macos/test/test-macos.sh --filter ProjectTreeNameOrderTests`：fixture、兜底扫描和新增文件的位置；另需运行 `GitGraphLayoutTests` 确认分支名排序不变。
- 在 macOS 打开含 `docs/releases/v0.1.4.md`、`v0.1.12.md` 的仓库，确认树中 `v0.1.4` 在 `v0.1.12` 之前，并在外部新建 `v0.1.5.md` 后插入到 `v0.1.4` 与 `v0.1.12` 之间。

## 适用范围

- `rust/lithe-core/src/project/file_name_order.rs`
- `rust/lithe-core/src/project/files.rs`
- `rust/lithe-core/src/project/search_index.rs`
- `macos/Sources/LitheCoreContracts/Workspace/NaturalNameOrder.swift`
- `macos/Sources/LitheCoreContracts/Workspace/FileNodePathLookup.swift`
- `macos/Sources/Lithe/Platform/MacOS/FileSystem/MacWorkspaceSnapshotBuilder.swift`
- `shared/fixtures/workspace/file-name-order-v1.json`
