# Agent 笔记：文本编辑使用 Core 校验和应用

状态：已实现

## 先说结论

语言服务的整批文本编辑（工作区编辑、格式化）都通过 Core 的 `lsp.applyTextEdits` 应用。宿主只把语言服务器的 `character` 字段转换为 Core 的 `utf16Column`，不再自行计算位置、排序或拼接文本。任一目标的文本校验失败时，不能先修改其他目标。

## 问题

旧算法把不存在的行夹到文件末尾，也接受反向和重叠范围，可能修改错误的位置。JavaScript 字符串使用 UTF-16（emoji 通常占两个编码单元），而 Rust 字符串使用 UTF-8 字节；宿主自行换算容易在中文、emoji 和换行处产生分歧。

## 决策

复用 Core 的 `lsp.applyTextEdits`（桌面端调用点在 `desktop/internal/core/plugin_semantics.go`，工作台的使用在 `desktop/internal/workbench/pluginedits.go`）作为文本编辑规则的唯一实现。保留 Core 对行尾列号和代理对中间位置的规范化行为，宿主不增加另一套判断。

工作区编辑必须先等待所有目标计算成功，再写入缓冲区或文件。

正确示例：得到 Core 返回的文本后才写入。
错误示例：对每个目标边校验边写入；后续目标失败时，前面的文件已经被修改。

## 考虑过的备选方案

- **在宿主补范围检查**：改动看似局部，但继续保留两套规则，不能消除位置换算的分歧。
- **直接交给编辑器应用**：无法覆盖未打开的文件的编辑，也绕开 Core 校验。
- **在本次调整 Core 的代理对和列号规则**：会改变既有行为，超出宿主接线的范围。

## 后果

宿主不再维护偏移计算、排序和字符串拼接，文本规则随 Core 一起维护。异步结果写入前要检查当前工作区、缓冲区身份、内容和版本，拒绝覆盖期间的用户输入。范围错误保留稳定的 code 和 details，并通过共享 i18n 显示。跨文件的磁盘事务和回滚不在本条范围内。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/core/... ./internal/workbench/...`：宿主侧的请求字段与错误传播。
- Core 仓库的 [`rust/crates/text/src/edits.rs`](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/crates/text/src/edits.rs) 与 [共享样例 `text-edits-v1.json`](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/fixtures/lsp/text-edits-v1.json)：批量修改、中文、emoji、CRLF、非法和重叠范围。
- `scripts/platform-feature-matrix` 下的 `generate-platform-feature-matrix.mjs --check`，以及 `scripts/agent-notes/verify-agent-notes.sh`。

## 适用范围

- `desktop/internal/core/plugin_semantics.go`
- `desktop/internal/workbench/pluginedits.go`
- Core 仓库的 [`rust/crates/text/src/edits.rs`](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/crates/text/src/edits.rs)，以 [Lithe-core-rust](https://github.com/Lithe-IDEA/Lithe-core-rust) 当前固定的修订为准。
