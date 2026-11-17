# Agent 笔记：编辑器复制代码引用位置

状态：已实现

## 先说结论

Viva 编辑器的右键菜单提供复制源码位置，默认把所点行复制到剪贴板。有语言服务器同步提供的文档符号时，Rust Core 把包、类、方法及原始签名组成引用；没有可靠符号时只复制文件路径和行号，不推测源码。macOS 与 Windows 共用实现，避免两端产生不同格式。

## 问题

#2015 需要从编辑器快速得到方法引用及行号。原有标签页“复制路径/引用”只处理文件路径；从文件名和源码文本自己猜方法签名会在重载方法、嵌套类和未保存编辑时产生错误引用。

## 决策

- 使用语言服务器协议（LSP）的 `documentSymbols`：先确认当前文档已同步，随后由现有异步请求链获取符号；优先使用与文档修订相同的 Structure 缓存。
- 桌面端只捕获右键坐标、管理请求生命周期并写入系统剪贴板；格式规则属于 Rust Core 的 `editor.copyReferenceLocation`。
- Core 只消费上游提供的符号名称、类型、作用域及方法签名，没有可靠信息就按 `文件路径#L行号` 回退。用户看到的一基行号由 Core 统一处理。
- 旧文档或项目、关闭的标签、后续编辑以及新一次复制都不能接收过期操作。插件会话失败与缺少符号不阻断文件路径回退。
- 等语言服务器的文档符号最多 3 秒（`referenceSymbolsTimeout`）。提交请求有 `semanticStartTimeout`，但回答没有期限；正在索引或卡住的服务器会让菜单项点了没有结果。超时后取消请求、记录日志，按没有服务器时的规则复制 `文件路径#L行号`。
- 右键坐标只属于它打开的那一次菜单：选中“复制源码位置”时使用；菜单没选这一项就关闭（Esc、点别处、选其他项）时丢弃。之后用 Shift+F10 打开的菜单读取光标位置，不会复制很久以前右键的行。
- 菜单复用现有共享 i18n 的“复制源码位置”（`native.copySourceLocation`），而不是在桌面端增加无法生成的硬编码界面文案。

## 考虑过的备选方案

- **直接解析 Java 源文件提取类/方法**：不采用。需要为每门语言维护解析规则，还会误识别重载方法与泛型，违反 Core 不特判语言的约束。
- **直接复制文件行号，不请求 LSP**：只作为缺失服务器的回退；否则无法实现 Issue 要求的符号级引用。
- **把格式规则写入 Go/Viva**：不采用。相同功能在两个平台的语义必须由共享 Core 定义。

## 后果

右键复制不启动新的常驻服务，也不阻塞编辑器线程。符号质量取决于语言服务器提供的名字与签名；有些服务器不提供包名或方法参数时，输出会相应变短。未保存修改尚未完成 LSP 同步时，优先保证位置正确并回退文件路径，不能拿旧符号当新信息。

## 验证

- Core: `cargo test -p lithe-editor`；`cargo test -p lithe-core copy_reference_location`。
- Viva: `scripts/desktop/desktop-go.sh test ./internal/workbench -run 'TestCopyReferenceLocation|TestEditorContextMenuCopiesReference|TestEditorContextMenuForgetsPress' -count=1`，其中包括服务器不回答时超时回退，以及右键菜单关闭后改用光标位置。
- 视觉: `LITHE_VISUAL_OUTPUT_DIR=.artifacts/issue-2015 scripts/desktop/desktop-go.sh test -tags 'vivahead lithevisual' ./internal/workbench -run '^TestVisualCopyReferenceLocation$' -count=1`。
- 两个平台原生集成与粘贴结果仍需实际执行，不能以静态源代码检查替代。

## 适用范围

`desktop/internal/workbench/copy_reference.go`、`desktop/internal/workbench/editor_menu.go`、`desktop/internal/core/reference_location.go`、`rust/crates/editor/src/reference_location.rs`、`rust/contracts/rust-core-api.md`。
