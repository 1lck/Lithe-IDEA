# Agent 笔记：Viva 编辑器行操作的 Core 接口

状态：已实现

## 先说结论

Viva 的 Core 适配层可以取得语言的行注释符号，并调用共享的注释、复制、删除和移动行规则。适配层不修改文档；快捷键、菜单、撤销和窗口接线还未完成，不能将接口可调用当作用户功能已实现。

## 问题

行变换需要正确处理跨行选区、UTF-16 代理对、CRLF 和无操作边界。Go 中再实现这些规则会与 Core 和其他宿主分叉；但 Core 需要完整文本，如果直接在键盘事件中同步传入大文档，会阻塞交互并造成额外复制。

## 决策

行变换和注释符号由 `editor.lineEdit` 与 `editor.lineCommentToken` 决定。返回的替换范围和选区使用 UTF-16 偏移；`applied: false` 是无操作，不能改写文档或消费快捷键。未来接线必须核对文档身份、版本、选区和输入法组合状态，将已确认的变更作为一个可撤销编辑；迟到结果不能覆盖新内容。

完整文本同步调用的成本和局部范围方案跟踪 [#1805](https://github.com/1lck/Lithe-IDEA/issues/1805)。Core 规则未支持安全的有界输入前，不把完整文档调用直接放入 UI 线程，也不在 Go 复制无操作或行选择规则来规避约束。

## 考虑过的备选方案

- 各平台独立计算注释和行范围：会产生不同的空行、行尾和选区行为，故复用 Core。
- 整份文档同步调用 Core：小文件简单，但大文件的序列化和处理会阻塞输入；先处理性能与快捷键归属。
- 异步计算后无条件消费快捷键：无操作结果不能及时交给其他处理器，违反 Core 契约；需要先设计无损的接线方式。

## 后果

共享样例可验证桥接结果，但用户仍不能通过 Viva 执行这些命令。局部处理、界面接线、平台快捷键、组合输入、撤销与真实窗口性能验收均未完成。接口只处理内存快照，不创建资源或写入发行包。

## 验证

- `scripts/desktop/desktop-go.sh test -race ./internal/core -run 'Test(LineEditsUseCoreFixtures|LineCommentTokenUsesCoreLanguageTable)' -count=3 -timeout=90s`：macOS 验证共享行变换 fixture、语言符号和未知语言。
- `scripts/desktop/desktop-go.sh test ./internal/core -run '^$' -bench '^BenchmarkCoreToggleLineComment$' -benchtime=3x -count=1 -timeout=90s`：Apple M4 上合成 100 KiB、1 MiB 和 8 MiB 文档的平均调用约为 5.37、31.2 和 248.6 ms；8 MiB 的 Go 分配约 29.5 MiB，不包含 Rust 分配或峰值。该单机基准不代表真实窗口或 Windows 性能。

## 适用范围

- `desktop/internal/core/line_edit.go`
- `desktop/internal/core/line_edit_test.go`
- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/fixtures/editor/line-edit-v1.json`
- `shared/platform-feature-matrix/features/editor-line-operations.json`
- [固定 Core 的行变换实现](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/editor/line_edit.rs)
