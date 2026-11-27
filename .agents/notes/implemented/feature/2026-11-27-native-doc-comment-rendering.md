# Agent 笔记：文档注释与悬停文档原生 HTML/Javadoc/Markdown 渲染

状态：已实现

## 先说结论

Lithe 在编辑器内原生渲染含 `<p>`、`<em>`、`<pre>`、`<ul>`、`{@code}`、`{@link}`、`@since` 等标签的文档注释与悬停（Hover）文档，完全不引入 WebView。HTML、Javadoc 和 Markdown 的清洗与解析全部放在共享的 Rust Core 中，桌面端只负责用已完成的词法分析找出文档注释范围，再交给 Viva 的 `MarkdownView` 原生绘制。普通可写文件默认显示源码，只读或外部库源码文件默认自动渲染，用户可通过行号旁图标、双击、右键菜单或命令随时在渲染视图与源码之间切换。

## 问题

Java、Kotlin、TypeScript、C/C++、PHP 和 Rust 的源码及语言服务器悬停提示中大量混用 `<p>`、未闭合 `<p>`、`<em>`、`<pre>`、`<ul>`、`<table>` 等 HTML 标签以及 Javadoc 行内/块级标签。此前存在两个缺陷：

1. 悬停弹窗只把文本交给基础 Markdown 解析器，HTML 标签会原样露在界面上或被吞掉。
2. 编辑器正文只能逐行显示原始注释文本，阅读类似 JDK `ArrayList.java` 这类长文档注释时可读性差。

同时，产品要求启动快、内存占用低（每个文档的内存预算为 `2 MiB + 1.5 × 文本字节数`）、编辑和滚动帧无卡顿，且宿主代码对具体语言插件必须零依赖。

## 决策

### 1. 职责分层与数据边界

- **Rust Core（共享解析层）**：新增 `editor.renderDocComment` 和 `editor.renderHoverDoc` 两个命令，通过借用文档 C ABI（`lithe_core_execute_document_json`，直接传递不可变字节指针而不把正文复制进 JSON）读取单段注释切片或悬停文本。内部使用现有锁定的 `html5ever` 与 `comrak` 依赖，在自定义有界 DOM 接收器（`BoundedDomSink`，限制输入 64 KiB、DOM 节点 2048、嵌套深度 16、属性 16、文本 128 KiB，并在解析过程中检查任务取消）里完成解析，输出纯数据的结构化中间表示（IR：`DocBlock`、`DocSpan`、`DocAnchor`）。
- **桌面端词法发现（`desktop/internal/editor/syntax/doc_comments.go`）**：不使用正则或简化的扫描器猜注释边界，而是跑一遍完整的 TextMate 词法扫描（TextMate 语法分词器，负责准确识别字符串、正则字面量与注释状态），只提取独立整行的文档注释，并记录显式外壳类型（`block-star` 或 `line-slash`）、方言（`javadoc-html` 或 `markdown-html`）以及内容指纹（FNV-1a `ContentHash`）。
- **Viva 原生富文本组件（`Lithe-IDEA/viva`）**：在 `markdown.Document` 中新增通用无边框双列块 `Labeled`（供 `@since`/`@see`/`@author`/`@param` 等标签对齐排版，不写死 Javadoc 概念）与构建器 API；在 `components.MarkdownView` 中保留阅读顺序的同时增加四级空间索引（块 → 表格行 → 单元格 → 视觉行）与深度分桶引用条索引，确保大注释块裁剪绘制稳态零分配。
- **编辑器视图投影（`desktop/internal/editorview/docblocks.go`）**：引入显式显示行映射（`displayRow`，区分普通源码行与渲染文档块行）与稀疏激活表（`active`）。当文档未软换行、未折叠且无渲染块时，不分配逐行映射表；单帧多块布局耗时限额 500 µs，单块超过 16 ms 自动熔断回退源码；单文档缓存受 `min(512 KiB, max(0, remaining / 4))` 严格约束（无 64 KiB 保底），并优先与代码折叠保持同起止行互斥与“外层折叠优先”。

### 2. 开发者的具体动作规则

- **要这样做**：新增支持文档注释渲染的语言时，只在 `desktop/internal/editor/syntax/languages.go` 的声明表添加该语言的 `DocCommentDialects`，共享标签解析规则放进 Rust Core `rust/crates/editor/src/doc_render/`；界面标签文案统一放进 `shared/i18n/features/doc-comment-rendering.json`。
- **不要这样做**：不要在宿主 Go 代码里写新的 HTML/Javadoc 解析器，不要通过 `foldingRange` 猜测注释范围，不要在 `Paint` 阶段同步调用 Core 或分配临时切片，也不要引入 WebView 或按具体插件 ID 分支。

示例（正确与错误对比）：

```text
正确：
TextMate 完整词法扫描 -> 后台提交单段注释字节给 Core editor.renderDocComment
-> 主线程校验 (docGen, revision, blockID, contentHash) -> 原子发布到 editorview

不要这样做：
用正则在源码中匹配 /** ... */ -> 在 Paint() 中直接解析 HTML -> 忽略版本直接覆盖界面
```

## 考虑过的备选方案

1. **嵌入 WebView 渲染注释卡片**：可复用浏览器排版，但会引入独立渲染进程与数百 MB 内存开销、滚动同步撕裂以及跨平台原生句柄复杂性，违背“性能好、内存少、原生渲染”的产品底线。
2. **在 Rust Core 中写简化正则/C 风格注释边界扫描器**：无法正确处理 JavaScript/TypeScript 正则字面量（如 `const r = /[/*]/;`）和各语言字符串规则，容易误把代码当注释吞掉，因此改为由桌面端已有的 TextMate 完整词法通道确认边界。
3. **仅靠 `foldingRange`（`kind == "comment"`）识别文档注释**：语言服务器不区分普通注释与文档注释，且在未启动 LSP 或单文件模式下不可用。
4. **用比例滚动锚点（`scroll / height`）在展开/收起时保持视口位置**：当阅读点下方内容高度大幅变化时，比例锚点会产生明显漂移；改用文本偏移锚点（源码 `sourceOffset` / 渲染文本 `renderedTextOffset`）可准确稳住当前阅读行。

## 后果

### 收益

- 编辑器内嵌渲染与悬停弹窗共享同一套 Rust Core 解析结果，HTML/Javadoc/Markdown 语义一致且安全有界。
- 稳态绘制与滚动保持 0 B/op、0 allocs/op，大文件与常规编辑无额外内存膨胀。
- 普通可写文件默认不打断编辑习惯，只读与外部库文件默认提供接近 IDEA Reader Mode 的阅读体验。

### 代价与限制

- 超过 2 MiB 的单文件、超过 64 KiB 的单段注释或超过单块布局时间熔断阈值的极端注释会自动保持源码视图，避免卡顿或突破内存预算。
- `{@link}` 符号引用暂不执行猜测性跳转，保持安全的无动作或外链/段内锚点跳转，待后续语言服务器符号解析接线后按需增强。
- 需要跨三个仓库协调合入顺序：先合入 Rust Core 与 Viva fork，再在 Lithe 主仓库更新 `PINNED_CORE_REVISION` 与 `desktop/go.mod` 的 `replace` 固定版本。

## 验证

- Rust Core：`cargo test --manifest-path rust/Cargo.toml -p lithe-editor -p lithe-core`、`cargo clippy --manifest-path rust/Cargo.toml -p lithe-editor -p lithe-core --all-targets -- -D warnings`
- Viva：`go test ./markdown/... ./components/...` 与 `BenchmarkMarkdownViewClippedPaintSteady`
- 桌面端：`scripts/desktop/desktop-go.sh test ./internal/core/... ./internal/editor/... ./internal/editorview/... ./internal/settingswindow/... ./internal/workbench/...`
- 视觉与文案：`node scripts/i18n/generate-i18n.mjs --check`、`node scripts/i18n/verify-app-language-localization.mjs`、`doc_comments_visual_test.go` Headless 深浅色与中英文截图检查
- 性能与不变性：`scripts/desktop/perf/editor-bench.sh`、`scripts/desktop/verify/verify-runtime-bundle-immutability.sh`、`scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`、`scripts/agent-notes/verify-agent-notes.sh`

## 适用范围

- `desktop/internal/core/doc_render.go`
- `desktop/internal/editor/syntax/doc_comments.go`
- `desktop/internal/editorview/docblocks.go`
- `desktop/internal/workbench/doc_markdown.go`
- `desktop/internal/workbench/doc_comments.go`
- `desktop/internal/workbench/pluginsemantics_hover.go`
- `desktop/internal/settingswindow/editor_preferences_view.go`
- `shared/i18n/features/doc-comment-rendering.json`
- `shared/platform-feature-matrix/features/editor-doc-comment-rendering.json`
