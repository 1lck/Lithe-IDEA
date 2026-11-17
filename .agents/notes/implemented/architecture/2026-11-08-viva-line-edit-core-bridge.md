# Agent 笔记：Viva 编辑器行操作的 Core 接口

状态：已实现

## 先说结论

切换行注释、复制、删除、移动行的变换规则只在 Core 的 `editor.lineEdit`；Core 不认识任何语言，行注释符号由桌面端语言注册表给出。桌面端只取选中行及前后各一行交给 Core，在后台调用，结果核对文档版本后作为一次可撤销编辑写回。

## 问题

行变换需要正确处理跨行选区、UTF-16 代理对、CRLF 和无操作边界，Go 中再实现一遍会与 Core 分叉。注释符号是语言知识：Core 曾用一张写死的扩展名表回答 `editor.lineCommentToken`，与编辑器语言注册表重复，插件声明的语言也进不了那张表，违反 Core 对语言零特判的约束（[#1856](https://github.com/1lck/Lithe-IDEA/issues/1856) 第 5 项）。Core 需要文本，在键盘事件里同步传入整份大文档会阻塞输入。

## 决策

- 变换规则：`editor.lineEdit` 返回 UTF-16 偏移的替换范围和选区；`applied: false` 是无操作，不改写文档。`toggleLineComment` 必须带 `commentToken`。
- 注释符号：`syntax.Registry.CommentsForPath` 是唯一来源。内置语言在 `desktop/internal/editor/syntax/languages.go` 声明 `Comments`；插件语言用 `languages[].configuration.lineComment` 声明，替换同 ID 内置语言时未声明的字段沿用内置值；只为服务器或调试器认领文件、既无语法也无注释的插件语言（如调试插件的 `clangd`）沿用按文件名选出的内置语言的注释，与 `SyntaxForPath` 沿用其配色一致。没有行注释符号时提示 `desktop.editor.noLineComment`，不调用 Core。
- 有界输入：`editorview.View.LineEditInput` 只取选中行及前后各一行，超过 1 MiB 不处理；输入法组合中或只读视图不处理。
- 接线：快捷键（Alt+上下、Alt+Shift+上下、Primary+Shift+K、Primary+/）和编辑器右键菜单都走 `workbench.runLineOperation`；Core 在后台调用，`ApplyLineEdit` 在文档版本变化后丢弃迟到结果。

整份文档复制的剩余成本跟踪 [#1805](https://github.com/1lck/Lithe-IDEA/issues/1805)。

## 考虑过的备选方案

- 各平台独立计算注释和行范围：空行、行尾和选区行为会分叉，故复用 Core。
- Core 保留注释符号表：与语言注册表是两份来源，插件新增语言时还要改 Core，违反 Core 零语言特判；已于 #1856 删除 `editor.lineCommentToken`。
- 整份文档同步调用 Core：大文件的序列化和处理会阻塞输入，改为局部窗口加后台调用。

## 后果

新增语言只需在内置表或插件清单里声明注释，Core 和行操作代码不用改。`.json` 按内置语言表使用 `//`（与 VS Code 一致），不再提示没有行注释。接口只处理内存快照，不创建资源或写入发行包。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/editor/syntax -run '^TestCommentsForPath$' -count=1 -timeout=60s`：旧 Core 表覆盖的扩展名全部保留符号；插件声明覆盖、同 ID 继承、无语法插件语言回退、自带语法的插件语言不回退。
- `scripts/desktop/desktop-go.sh test ./internal/core -run '^TestLineEditsUseCoreFixtures$' -count=1 -timeout=90s`：共享行变换 fixture。
- `scripts/desktop/desktop-go.sh test ./internal/workbench -run '^Test(LineOperationKeys|LineOperationsThroughCore|EditorContextMenuRunsLineOperation)$' -count=1 -timeout=120s`：快捷键映射、经 Core 的注释切换与右键菜单。
- `scripts/desktop/desktop-go.sh test ./internal/core -run '^$' -bench '^BenchmarkCoreToggleLineComment$' -benchtime=3x -count=1 -timeout=90s`：Apple M4 上合成 100 KiB、1 MiB 和 8 MiB 文档的平均调用约为 5.37、31.2 和 248.6 ms；8 MiB 的 Go 分配约 29.5 MiB，不包含 Rust 分配或峰值。该单机基准不代表真实窗口或 Windows 性能。

## 适用范围

- `desktop/internal/core/line_edit.go`
- `desktop/internal/core/line_edit_test.go`
- `desktop/internal/editorview/lineedit.go`
- `desktop/internal/workbench/lineedit.go`
- `desktop/internal/workbench/editor_menu.go`
- `desktop/internal/editor/syntax/language.go`
- `desktop/internal/editor/syntax/languages.go`
- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/fixtures/editor/line-edit-v1.json`
- `shared/platform-feature-matrix/features/editor-line-operations.json`
