# Agent 笔记：Markdown 内嵌 HTML 的图片行内排版与安全对齐

状态：已实现

## 先说结论

README 同一段中的多个徽章应当在宽度足够时同行显示，而不是每张图片独占一行。Markdown 渲染由 Core 的 Comrak 解析、Ammonia 过滤共同完成；过滤器保留容器、段落和标题的 `align` 对齐属性，图片保持行内排版，空间不足时自然折行。这不是开放完整网页执行能力，脚本、事件处理器、危险链接和任意行内样式仍然被删除。

## 问题

Issue #1623 中 README 徽章纵向堆叠、标题丢失居中。原因是预览把所有图片都当作块级元素（每个元素另起一行），同时安全过滤删除了 `div`、`p` 和标题上的 `align`。Markdown 解析器并没有为每个徽章插入换行。

## 决策

- **过滤器保留安全对齐。** 共享渲染复用 Comrak（Markdown 解析器）和 Ammonia（HTML 安全过滤器），仅为 `div`、`p`、`h1` 至 `h6` 保留 `align`，不增加任意 CSS 样式权限。桌面端的渲染入口在 `desktop/internal/core/markdown.go`。
- **图片不强制成块级。** 预览样式不能对所有图片设置块级显示；图片服从父容器对齐，段落间距仍由段落提供。
- 正确例子：`<div align="center"><p><img ...> <img ...></p></div>` 由浏览器计算同行、居中和窄预览折行。不要用全局的块级图片样式、强制不换行或删除 `<p>` 来修补。
- 共享 fixture 描述安全 HTML 和恶意属性混合输入：保留对齐和尺寸，同时剥离脚本、事件、样式和危险 URL。

## 考虑过的备选方案

- 只对徽章或 README 域名特判：会漏掉其他图片地址和普通内嵌 HTML，不采用。
- 给段落套不换行或弹性布局：会破坏正文行内图片和显式换行，窄分栏也可能横向溢出，不采用。
- 放开所有 `style`：能覆盖更多网页布局，但也允许文档覆盖预览界面；本次只需安全对齐属性，不采用。

## 后果

常见 README 的徽章行和 HTML 对齐恢复，普通行内图片不再拆段。GitHub 专有媒体转换、任意 CSS、可执行嵌入不属于这次支持范围。

渲染结果和网页状态仅在内存及非持久的网页存储中使用，资源读取仍只读用户工作区。不新增运行时下载、缓存目录，不写应用包，不改变代码签名和 Sparkle 增量更新基线。

## 验证

- Core 仓库的 `project::markdown` 测试：直接测试生产解析与过滤，保留对齐和尺寸，同时剥离脚本、事件、样式和危险 URL。
- `scripts/desktop/desktop-go.sh test ./internal/core/... ./internal/webpreview/...`
- `scripts/desktop/verify/verify-runtime-bundle-immutability.sh`
- `scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`

## 适用范围

- `desktop/internal/core/markdown.go`
- `desktop/internal/webpreview/webpreview.go`
- Core 仓库的 [`rust/crates/project/src/markdown.rs`](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/crates/project/src/markdown.rs) 与 [`markdown-html-v1.json`](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/fixtures/editor/markdown-html-v1.json) 夹具
- `shared/platform-feature-matrix/features/markdown-rendering.json`
