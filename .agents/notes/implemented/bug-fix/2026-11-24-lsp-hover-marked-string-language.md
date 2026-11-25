# Agent 笔记：悬停文档保留 Markdown 与代码块语言

状态：已实现

## 先说结论

语言服务器返回的悬停文档有几种合法格式，不能统一当作纯文本。Core 必须按语言服务器协议（LSP）区分 Markdown 字符串、带语言的代码片段和显式的纯文本；桌面端再用代码块声明的语言选择已有语法规则。修复位于共享解析层，两端不需要各写一份转换，也不需要提升插件协议版本。

## 问题

[#2373](https://github.com/1lck/Lithe-IDEA/issues/2373) 报告悬停弹窗直接显示 Markdown 围栏。Core 的 `hover_contents` 把裸字符串形式的 `MarkedString` 标记为纯文本；处理 `{language, value}` 时又只取正文，丢掉语言与代码块语义。桌面端因此把 Markdown 源码整体包进纯文本代码块，或无法选择声明的语法规则。该逻辑在 Core 拆分提交 `7ae0c16`（Core #28）中已经存在。

## 决策

- 在 Core 的 LSP 结果解析入口修正格式：裸 `MarkedString` 是 Markdown；带语言的片段转换为保留语言标识的 Markdown 代码块；`MarkupContent` 继续遵循显式的 `kind`。
- 代码内容可能包含反引号，生成围栏时必须长于内容里的最长连续反引号，防止代码提前结束。数组按原顺序拼接已经归一化的条目，空结果仍不打开弹窗。
- 桌面端继续使用现有的后台语法着色与 Markdown 视图。正确示例是在 Java 文档中返回 Rust 代码块，代码块按 Rust 上色；没有对应语法规则时保留正常的代码块呈现。
- 不要根据语言服务器名称判断格式，也不要把所有返回值都改成 Markdown，否则显式纯文本里的星号和反引号会被误解释。

## 考虑过的备选方案

在弹窗里猜测是否包含 Markdown 围栏只能修复部分表象，无法恢复已经丢掉的语言信息，也会误判合法纯文本。为某个服务器或插件加特例会让其他使用相同标准格式的服务器继续出错，因此选择在 Core 按协议类型处理。

## 后果

两端通过相同的归一化结果保留 Markdown 和代码块语言，现有高亮器不需要新增依赖。代价是带语言的原始片段需要生成围栏并扫描一次反引号；语法着色仍取决于宿主当前可用的语法规则。Core 修复必须合入后再更新宿主的固定修订；本地验证使用 `LITHE_CORE_RUST_DIR` 指向修复检出，不把未合入的修订当作发行依赖。

## 验证

Core 的 `client_hover_contents_match_fixture` 使用共享 `rust/fixtures/lsp/hover-contents-v1.json`，修复前发现裸字符串、语言片段和数组等四项不符，修复后 `lithe-lsp-client` 全部 61 个测试通过。fixture 同时保护显式纯文本、Markdown、内容内反引号、空数组和空结果。Core 的[注释检查脚本](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/scripts/rust-core/verify-rust-core-comments.sh)对 lsp-client 的注释规范与 Rustdoc 检查通过，使用该 Core 检出自己的 `rust/target` 复用编译产物。

宿主通过 `scripts/desktop/desktop-go.sh` 读取同一个 Core fixture，运行 `TestHoverContentsContractRendersLanguageCodeBlocks` 以及已有悬停渲染、高亮与纯文本用例，并完成定向竞态检查。逐项计时由 `.agents/skills/write-stable-tests/scripts/test-stability-macos.sh` 记录于 `.artifacts/test-stability/hover-regression.json`；新增用例总耗时 590 ms，最慢子用例 220 ms。

`TestVisualHoverContentsContract` 以 `vivahead,lithevisual` 标签运行，输出两种返回格式在明暗主题、中英文、1000×640 布局下的八张截图；已检查代码着色和正文排版。这是共享契约与无头呈现证据，不代表真实语言服务器或 macOS、Windows 原生窗口验收；两端原生验证保持 pending。

## 适用范围

- [Core 的 LSP 结果解析](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/crates/lsp-client/src/client/results.rs)
- `desktop/internal/workbench/pluginsemantics_hover.go`
- `desktop/internal/workbench/pluginsemantics_hover_test.go`
- `desktop/internal/workbench/pluginsemantics_hover_visual_test.go`
- `shared/platform-feature-matrix/features/lsp-completion-hover.json`
