# Agent 笔记：快速修复必须保留原始诊断

状态：已实现

## 先说结论

Windows 问题面板把诊断等级转成文字用于显示，快速修复却又把这些文字传回只接受整数的 Rust Core，请求因此失败。
现在保留 Core 返回的完整诊断，界面只从中派生显示字段；请求快速修复时直接传回原对象。
问题面板、快捷键和编辑器灯泡都遵守这个约束，不能从显示文字或波浪线标记重建诊断。

## 问题

Issue #1662 的 LSP-01 / BUG-3 指出 `severity`（诊断等级）从整数变成了字符串。
简单反向映射也不能修复全部问题：信息和提示在界面里都显示为 `info`，无法还原；标签与关联位置也已经被丢弃。
关联位置里的列号与主诊断一样，按 UTF-16 编码单元计数，不能只转换最外层范围。

## 决策

- Core 的 `LspClientDiagnostic` 是请求数据的唯一来源。Windows 声明同形类型，诊断批次保持原对象和 `utf16Column` 字段，不再递归转换为编辑器坐标。
- 展示模型通过 `lspDiagnostic` 引用原对象，不复制关联信息。等级名称、行列和错误文字只是呈现字段。
- 快速修复使用原诊断的范围和完整上下文。编辑器灯泡根据 Monaco（编辑器组件）的可见标记找到对应展示记录，再使用同一入口。
- 本地检查器等非 LSP 来源没有原诊断时，只发送范围和空诊断上下文，不伪造语言服务器诊断。
- Core 继续负责协议解析与请求构造，没有新增 Core 命令，也不改变 macOS 的请求路径。

正确做法：保留整数等级为 `4` 的原诊断，即使界面将它显示为 `info`。
不要这样做：读取 `info` 后猜测原等级为 `3`，或从编辑器为便于点击而加宽的波浪线还原请求范围。

## 考虑过的备选方案

- 仅将 `error`、`warning`、`info` 反向映射为整数：仍会丢失提示等级、未指定等级、标签和关联位置。
- 在界面层重新构造完整诊断：需要维护第二套诊断模型与默认值，新增字段时仍容易漏传。
- 新增 Core 修复接口：现有接口已经接受完整诊断，无须增加协议和维护成本。

## 后果

快速修复不再受到展示格式影响，未知标签与关联位置也能保留。
展示记录多持有一个原诊断引用，但不深拷贝数据；生命周期仍跟随已有的有界诊断 store，清除和关闭工作区时一并释放。
非 LSP 诊断只提供范围，是否返回操作由语言服务器决定。

## 验证

- `shared/fixtures/lsp/diagnostic-code-actions-v1.json` 同时供 Rust 与 Windows 回归测试使用，覆盖 1～4 级和空等级、未知标签、关联位置。
- `windows/tauri/src/features/editor/lsp/lsp-client-code-actions.test.ts` 覆盖批次接收、store 与请求数据。
- `windows/tauri/src/platform/lsp-core-adapter.test.ts` 覆盖 Core 事件与请求边界。
- `rust/lithe-core/src/lsp/tests.rs` 的 `client_diagnostic_code_action_fixture_preserves_core_fields` 验证 Core 反序列化以及协议往返。
- 在真实项目中分别通过问题面板右键、灯泡和快捷键执行快速修复；自动化通过不代表真机工作流已验收。
- 运行 `./scripts/agent-notes/verify-agent-notes.sh`。

## 适用范围

- `windows/tauri/src/core/lsp-diagnostic.ts`
- `windows/tauri/src/features/diagnostics/`
- `windows/tauri/src/features/editor/lsp/lsp-client.ts`
- `windows/tauri/src/features/editor/engines/monaco/lsp-providers.ts`
- `windows/tauri/src/platform/lsp-core-adapter.ts`
