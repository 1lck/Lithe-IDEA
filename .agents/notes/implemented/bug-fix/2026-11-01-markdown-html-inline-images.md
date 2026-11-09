# Agent 笔记：Markdown 内嵌 HTML 的图片行内排版与安全对齐

状态：已实现

## 先说结论

README 同一段中的多个徽章应当在宽度足够时同行显示，而不是每张图片独占一行。
macOS Markdown 预览让图片保留行内排版，空间不足时由浏览器自然折行；共享过滤器保留
容器、段落和标题的 `align` 对齐属性。这不是开放完整网页执行能力，脚本、事件处理器、
危险链接和任意行内样式仍然被删除。

## 问题

Issue #1623 中 README 徽章纵向堆叠、标题丢失居中，看起来像是 `<p>` 被插入了换行。
实际是预览样式把所有图片都设为块级元素（每个元素另起一行），同时安全过滤删除了
`div`、`p` 和标题上的 `align`。Markdown 解析器并没有为每个徽章插入 `<br>`。

## 决策

- 图片使用行内块（`inline-block`，可在同一文本行内排放的图片盒子），去掉全局图片外边距，
  服从父容器对齐。段落间距仍由 `p` 提供，视频保留原来的块级布局。
- 共享 Rust 渲染继续复用 Comrak（Markdown 解析器）和 Ammonia（HTML 安全过滤器）。
  仅为 `div`、`p`、`h1` 至 `h6` 保留 `align`，不增加任意 CSS 样式权限。
- 正确例子：`<div align="center"><p><img ...> <img ...></p></div>` 由浏览器计算同行、
  居中和窄预览折行。不要用全局 `img { display: block }`、强制不换行或删除 `<p>` 修补。
- 新共享 fixture 描述安全 HTML 和恶意属性混合输入；原生测试经过真实 Rust bridge、
  打包预览模板、资源处理器和 WebKit 浏览器引擎，检查几何位置而不模拟布局结果。

## 考虑过的备选方案

- 只对徽章或 README 域名特判：会漏掉其他图片地址和普通内嵌 HTML，不采用。
- 给段落套不换行或弹性布局：会破坏正文行内图片和显式换行，窄分栏也可能横向溢出，不采用。
- 放开所有 `style`：能覆盖更多网页布局，但也允许文档覆盖预览界面；本次只需安全对齐属性，不采用。
- 重写解析器或扩大到 Windows 方言迁移：不是本缺陷的根因。本次不改变 Windows 的简化解析器，
  不宣称两端 Markdown、公式或图表能力已完全一致。

## 后果

常见 README 的徽章行和 HTML 对齐恢复，普通行内图片不再拆段；单独图片默认不再被全局强制居中，
作者需要时可以使用安全对齐容器。GitHub 专有媒体转换、任意 CSS、可执行嵌入不属于这次支持范围。

渲染结果和网页状态仅在内存及非持久 WebKit 存储中使用，资源处理器仍只读用户工作区。
不新增运行时下载、缓存目录或跨工作树共享资源，不写 app bundle，不改变代码签名和 Sparkle 增量更新基线。

## 验证

- `cargo test --manifest-path rust/Cargo.toml -p lithe-core project::markdown::tests`：
  直接测试生产解析与过滤，保留对齐和尺寸，同时剥离脚本、事件、样式和危险 URL。
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter MarkdownPreviewHTMLTests`：
  深浅主题实际测量徽章同行、居中、窄视口折行，检查段落、显式换行、相对资源和图片放大。
- `./scripts/macos/verify/verify-runtime-bundle-immutability.sh`。
- `./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`。

原生组件回归不替代完整应用手动验收，Windows 运行时未在本次验证。

## 适用范围

- Lithe-core-rust 锁定修订：[rust/lithe-core/src/project/markdown.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/project/markdown.rs)
- ~~`macos/Sources/Lithe/Resources/MarkdownPreview/preview.css`~~（已随 #1794 移除）
- ~~`macos/Tests/LitheTests/MarkdownPreviewHTMLTests.swift`~~（已随 #1794 移除）
- `shared/fixtures/editor/markdown-html-v1.json`
- `shared/platform-feature-matrix/features/markdown-rendering.json`
