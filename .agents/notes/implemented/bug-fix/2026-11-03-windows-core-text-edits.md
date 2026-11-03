# Agent 笔记：Windows 文本编辑使用 Core 校验和应用

状态：已实现

## 先说结论

Windows 的工作区编辑和格式化都通过 `lsp.applyTextEdits` 应用整批替换。
平台层只把语言服务器的 `character` 字段转换为 Core 的 `utf16Column`，
不再自行计算位置、排序或拼接文本。任一目标的文本校验失败时，不能先修改其他目标。

## 问题

旧算法把不存在的行夹到文件末尾，也接受反向和重叠范围，可能修改错误的位置。
JavaScript 字符串使用 UTF-16（emoji 通常占两个编码单元），而 Rust 字符串使用
UTF-8 字节；自行换算容易在中文、emoji 和 Windows 换行处产生平台差异。

## 决策

复用已有 Core 命令作为文本编辑规则的唯一实现。保留 Core 对行尾列号和
代理对中间位置的规范化行为，不在 Windows 增加另一套判断。

调用变成异步后，工作区编辑必须先等待所有目标计算成功，再写入缓冲区或文件。
文档和选区格式化必须在 `try` 中等待结果，让异步校验失败仍进入原有错误处理。

正确示例：`await applyTextEditsToContent(content, edits)`，得到 Core 返回的文本后才写入。
错误示例：对每个目标边校验边写入；后续目标失败时，前面的文件已经被修改。

## 考虑过的备选方案

- 给 TypeScript 算法补范围检查：改动看似局部，但继续保留两套规则，不能消除平台分歧。
- 直接交给 Monaco 应用：无法覆盖未打开文件的编辑，也绕开 Core 校验。
- 在本次调整 Core 的代理对和列号规则：会改变 macOS 的现有行为，超出 Windows 接线范围。

## 后果

删除 Windows 的偏移计算、排序和字符串拼接，文本规则随 Core 一起维护。
代价是每个目标增加一次异步宿主调用。继续按整批编辑调用，不逐个替换发请求。
跨文件提交的版本保护、回滚与目标限制仍属于 Issue #1662 的 LSP-03。

## 验证

- `./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope Frontend`
- `node scripts/platform-feature-matrix/generate-platform-feature-matrix.mjs --check`
- `node scripts/agent-notes/verify-agent-notes.mjs`

`text-edit-core.test.ts` 检查真实请求字段及错误传播；
`editor-app.store.test.ts` 检查校验失败前不提交缓冲区，以及格式化的异步错误处理。
显式设置 `LITHE_CORE_TEST_LIBRARY` 为本地 Core 动态库路径后，原生集成测试通过
真实 C 接口执行共享样例，检查批量修改、中文、emoji、CRLF、非法和重叠范围。
未设置时跳过原生集成测试，普通单元测试不依赖本机安装的产品或语言服务器。

## 适用范围

- `windows/tauri/src/features/editor/lsp/workspace-edit.ts`
- `windows/tauri/src/features/editor/lsp/lsp-client.ts`
- `rust/lithe-core/src/lsp/lightweight/edits.rs`
- `shared/fixtures/lsp/text-edits-v1.json`
