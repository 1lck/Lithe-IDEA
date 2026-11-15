# Agent 笔记：Markdown 方言与 HTML 安全过滤只由 Core 决定

状态：已实现

## 先说结论

文档预览、Notebook、发布说明及 GitHub 内容的 Markdown 渲染都调用 Core 的 `markdown.render`，Markdown 方言和 HTML 安全过滤只由 Core 决定。界面只负责排版、代码着色和点击交互，不保留第二份解析器。与 macOS 一样，文档开头闭合的 YAML front matter（文档属性区）隐藏，不再显示属性卡片。

## 问题

界面独立解释 Markdown，会造成列表嵌套、代码块空白、front matter 和 HTML 过滤与 Core 不一致（Issue #1662 的 LSP-07）。Notebook、发布说明和 GitHub 视图也使用同一份解析逻辑，只改编辑器会留下第二份实现。

## 决策

- 复用 Core 已有的 Comrak（Markdown 解析器）和 Ammonia（HTML 安全过滤器），不增加 API、依赖、下载资源或另一套安全白名单。
- 异步渲染的生命周期由所属视图持有：输入变化或视图卸载后，已过期的解析与着色结果不能再更新预览，也不能继续启动着色。较慢的旧文档不能覆盖新文档。
- 保持一次替换完整的已着色预览，避免编辑时先闪回无着色版本。
- 着色失败时保留已过滤的 HTML；解析失败显示本地化文本，不回退到旧解析器。
- 着色器只修改已转义的代码内容：使用浏览器文本解码一次后，再按片段转义输出。不要把代码直接当 HTML 插入，也不要用字符串替换模板解释代码里的 `$&`。

## 考虑过的备选方案

- 保留旧解析器作失败回退：同一文档会随运行状态改变语义和安全边界，拒绝。
- 在界面里继续提取 YAML 并绘制属性卡片：扩大第二份文档解释规则，拒绝。
- 为某个视图另加 Markdown 库或独立命令：已有公共命令能够完成工作，不采用。

## 后果

所有预览入口共用文档解析和安全规则。首个 HTML 需要等待异步结果；编辑期间保留既有预览，空文档清空，过期结果丢弃。数学公式与图表的展示效果不等同于 macOS 旧版，不能据此宣称完全一致。

渲染请求有界排队。遇到队列满时，视图等待容量并重试，不把暂时繁忙当作渲染失败；视图关闭或内容过期时撤销未执行的请求。

本次不新增常驻服务、磁盘缓存、运行时资源或发行目录写入；请求与结果只在内存中使用，不影响代码签名与 Sparkle 增量更新。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/core/...`：`markdown_test.go` 覆盖共享输入，包括列表、代码空白、中文、emoji、CRLF、front matter 和恶意 HTML。
- `./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`
- `./scripts/desktop/verify/verify-runtime-bundle-immutability.sh`
- 自动化测试不替代真实 WebView 交互验收，功能矩阵保留待验收状态。

## 适用范围

- `desktop/internal/core/markdown.go`
- `desktop/internal/core/markdown_test.go`
- `desktop/internal/workbench/markdown_web.go`
- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/fixtures/editor/markdown-render-v1.json`
- `shared/platform-feature-matrix/features/markdown-rendering.json`
