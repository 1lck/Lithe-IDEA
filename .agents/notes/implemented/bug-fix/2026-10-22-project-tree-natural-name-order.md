# Agent 笔记：项目树同级文件名使用 IDEA 自然排序

状态：已实现

## 先说结论

项目树里 `v0.1.12.md` 曾排在 `v0.1.4.md` 前面。现在项目树直接显示 Rust Core 的 `workspace.listDirectories` 顺序：目录在文件前，名称采用 IDEA 自然排序。快照和搜索索引仍使用各自的遍历顺序，不跟随树的显示顺序。

## 问题

项目树的同级排序曾有三处各自实现：Rust Core 的 `visible_children`（只比较小写字节）、宿主侧的兜底扫描（不把数字当数）和增量插入时的位置计算（小写后比较）。它们都不是 IDEA 的顺序，也彼此不完全一致：版本号文件名、`file2`/`file10` 这类名字会按字典序排列，文件系统事件新增一个文件后还可能落在和重新扫描不同的位置。

## 决策

IDEA 的项目视图用 `AlphaComparator` 比较同级节点，而它调用的是 `FileNameComparator`，即 `NaturalComparator.naturalCompare(ignoreCase = true, likeFileNames = true)`。Core 逐行移植这套算法（参照 intellij-community `d8c6714c7a3c110c56994d6b0f10814f902100e7`）：

- 连续数字按数值比较，位数多的更大：`v0.1.4` < `v0.1.12`；值相同时没有前导零或空格的排在前面：`a1` < `a01`。
- 先忽略大小写比较；全部相同时再按大小写区分，保证顺序稳定：`A.txt` < `a.txt` < `B.txt`。
- `-` 与 `_` 相邻（IDEA-80435）：`foo.bar` < `foo-bar` < `foo_bar`。
- 目录先于文件的规则不变，由树负责，比较器不处理。

### 正确做法

- Core 仓库的 `rust/crates/project/src/file_name_order.rs` 提供 `FileNameKey`，`visible_children` 在 `ChildOrder::Tree` 下用 `sort_by_cached_key` 排序；每个名字只转换一次，大目录排序不会按比较次数分配内存。
- `visible_children` 必须由调用方说明要哪种顺序（`ChildOrder`）：只有 `workspace.listDirectories` 使用 `Tree`；快照和搜索索引使用 `Traversal`，仍按小写名字排序。
- 新增或调整规则时先改 Core 仓库的 `rust/fixtures/workspace/file-name-order-v1.json`，再让 Core 与桌面端的测试一起通过。

### 树行顺序与遍历顺序分开

快照的 `files` 清单不是显示顺序，而是一条被截断使用的序列：快速打开先按子串过滤，再只取前 100 项，并以位置给分。如果显示顺序的修改同时改变这条序列，同一个查询的前 100 项会悄悄变化。所以显示顺序只作用于 `Tree`，`Traversal` 保持原有规则；`workspace_snapshot_keeps_its_traversal_order_while_the_tree_rows_are_natural` 固定这一点。

### 不要这样做

- 不要在树里再加一处小写转换或本地化字符串比较排序；它会让重新扫描和增量插入的顺序不同。
- 不要改用 `localeCompare` 一类系统排序：它依赖系统区域设置，不是确定性的，也不是 IDEA 的顺序。
- 不要让快照或搜索索引的遍历改用 `ChildOrder::Tree`；要改变快照 `files` 的顺序，必须同时评估只取前 N 项的使用方。

## 考虑过的备选方案

### 使用系统的自然排序

系统的 `localizedStandardCompare` 同样把数字当数，但它依赖系统区域设置，Core 无法复现；而且不处理 `-`/`_` 相邻和大小写决胜，和 IDEA 的树仍会出现差异。

### 只在界面层排序

项目树的主路径是 Core 的目录列表，只改界面看不到效果，也无法与增量插入保持一致。

## 后果

- 项目树和 IDEA 的同级顺序一致，版本号、编号文件名按预期排列。
- 快照 `files`、其中的根树节点和搜索索引保持小写排序，不受影响。
- Rust 的排序不能接受违反全序的比较函数（可能 panic）。测试里用固定种子的随机名字检查反对称与传递性，移植时不要省略空格、`#`、`-`、`_` 这些特殊字符。

## 验证

- `scripts/desktop/desktop-go.sh test -race ./internal/core -run TestWorkspaceDirectoryTreeUsesCoreNaturalOrder -count=3`：真实 Core 消费共享版本号 fixture，验证目录优先及文件自然排序（`desktop/internal/core/workspace_tree_test.go`）。
- 树内增量插入与外部新增文件的原生窗口表现仍需在 Viva 中目视验收。

## 适用范围

- Core 仓库的 [`rust/crates/project/src/file_name_order.rs`](https://github.com/Lithe-IDEA/Lithe-core-rust/tree/main/rust/crates/project/src/file_name_order.rs)，以 [Lithe-core-rust](https://github.com/Lithe-IDEA/Lithe-core-rust) 当前固定的修订为准。
- `desktop/internal/core/workspace.go`
- `desktop/internal/core/workspace_tree_test.go`
- `desktop/internal/workbench/filetree.go`
