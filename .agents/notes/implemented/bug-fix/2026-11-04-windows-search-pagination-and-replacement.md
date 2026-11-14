# Agent 笔记：内容搜索的过滤顺序与替换一致性

状态：已实现

## 先说结论

内容搜索的路径过滤必须在截断之前生效，匹配行和列由 Core 提供，才能保证后面的文件不会因为前面的命中被截掉。替换先由 Core 对已读取的文本快照生成计划，Core 不写文件；宿主在写入前确认缓冲区或磁盘身份。

## 问题

旧接口把一批命中数当作分页状态，过滤发生在截断之后，后面的文件可能永远不可见。搜索使用 Core 的逐行规则，而替换若使用另一套正则实现，例如整词 `foo` 会错误替换 `$foo`。Unicode 小写展开还会让小写文本与原始文本的字节偏移不同。

## 决策

- **过滤先于截断。** 包含与排除条件在 Core 截断前生效，原始行与 UTF-16 匹配范围用于显示和定位（`desktop/internal/core/workspace.go` 的 `SearchWorkspace` 调用 `workspace.search`）。搜索结果的数量上限在 Core 侧统一执行。
- **替换只生成计划。** 替换先向 Core 提交文本快照和匹配选项，由 `workspace.replacePreview` 与 `workspace.replaceText` 返回替换结果（`desktop/internal/core/workspace_replace.go`）。Core 不写文件，写入由宿主完成。
- **写入前确认身份。** 打开的文件在更新前检查所属工作区生命周期、缓冲区身份和原文；未打开的本地文件用平台条件保存检查字节身份并保留编码。非本地文件（例如 WSL）目前没有原子条件写接口，只能在写入前重新读取并检查；不要把该检查宣称为原子保证。

正确例子：搜索到 `😀 foo` 时，Core 返回 UTF-16 范围，替换前再次确认原文仍是快照。不要先按小写文本的字节位置切原始 Unicode 字符，也不要在过滤前截断后宣称已搜完。

## 考虑过的备选方案

- **只在界面层丢弃被过滤的结果**：仍可能丢失被截断的后续结果；再维护一套正则替换会让搜索和替换分歧。
- **预先读取所有命中并在界面分页**：扩大首屏内存和延迟。

## 后果

批量替换在失败时等待已开始的写入结束，不能承诺跨文件事务回滚；非本地文件的原子条件写仍需平台能力。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/core/...`：`workspace_search_test.go` 覆盖搜索匹配与 Core 返回的范围。
- Core 仓库的项目搜索与替换测试（`tests::project::search_` 与 `project::files::event_filter_tests::`）覆盖过滤优先、Unicode 与替换计划。
- `scripts/desktop/verify/verify-runtime-bundle-immutability.sh`

## 适用范围

- `desktop/internal/core/workspace.go`
- `desktop/internal/core/workspace_replace.go`
- `desktop/internal/core/workspace_search_test.go`
- Core 仓库的项目搜索实现（project/files.rs、project/search_paging.rs），以 [Lithe-core-rust](https://github.com/Lithe-IDEA/Lithe-core-rust) 当前固定的修订为准。
