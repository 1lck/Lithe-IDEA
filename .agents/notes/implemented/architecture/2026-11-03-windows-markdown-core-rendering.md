# Agent 笔记：Windows Markdown 预览接入共享渲染

状态：已实现

## 先说结论

Windows 文档预览、Notebook、发布说明及 GitHub 内容改用已有的
`markdown.render`，删除原来的正则解析器。Markdown 方言和 HTML 安全过滤
只由 Rust Core 决定，前端保留代码着色、布局及点击交互。
与 macOS 一样，文档开头闭合的 YAML front matter（文档属性区）隐藏，不再显示属性卡片。

## 问题

Issue #1662 的 LSP-07 指出 Windows 仍独立解释 Markdown，导致列表嵌套、
代码块空白、front matter 及 HTML 过滤与共享实现不同。
原解析器还被 Notebook、发布说明和 GitHub 视图使用，只改编辑器会留下第二份实现。

## 决策

- 复用现有 Comrak（Markdown 解析器）和 Ammonia（HTML 安全过滤器），不增加 API、
  依赖、下载资源或另一套安全白名单。前端通过中央平台派发器异步调用。
- React effect（组件副作用）拥有当前请求的展示生命周期；输入变化或卸载后，
  已过期的解析与着色结果不能再更新预览，也不能继续启动着色。
  正确做法是检查当前生命周期；不要让较慢的旧文档覆盖新文档。
- 继续保持一次替换完整的已着色预览，避免编辑时先闪回无着色版本。
  着色失败保留已过滤 HTML；解析失败显示本地化文本，不回退到旧解析器。
- 着色器接受 Core 生成的源码位置属性，保留原标签，只修改已转义的代码内容。
  使用浏览器文本解码一次后再按 token（着色片段）转义输出；不要把代码直接当 HTML 插入，
  也不要用字符串替换模板解释代码里的 `$&`。

## 考虑过的备选方案

- 保留旧解析器作失败回退：会让同一文档随运行状态改变语义和安全边界，拒绝。
- 在 TypeScript 中继续提取 YAML 并绘制属性卡片：扩大第二份文档解释规则，拒绝。
- 为 Windows 另加 Markdown 库或独立 Tauri 命令：已有公共命令能够完成工作，不采用。
- 重建整个文档 DOM 后再着色：增加整页解析和序列化；沿用单次扫描重建字符串，
  仅借助浏览器文本元素解码代码实体。

## 后果

两端共用文档解析和安全规则，Windows 属性卡片被移除。首个 HTML 需要等待异步结果；
既有预览在编辑期间保留，空文档清空，过期结果丢弃。
Windows 的数学公式与图表展示没有因此自动达到 macOS 的能力，不能据此宣称完全一致。

本次不新增常驻服务、磁盘缓存、运行时资源或发行目录写入；请求与结果只在内存中使用，
组件卸载释放其展示状态，不影响代码签名与 Sparkle 增量更新基线。

共享调度器同时最多执行 2 个原生渲染，排队上限 64 个；视图关闭或内容过期会撤销未执行请求，已执行任务释放前仍占用并发槽。GitHub 不再删除 Core 输出中的 `<br>` 或折叠代码空白。

## 验证

- `./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope Frontend`：
  运行 Markdown 相关用例；原生集成用例通过 `LITHE_CORE_TEST_LIBRARY` 指向 Core 动态库。
  共享输入覆盖列表、代码空白、中文、emoji、CRLF、front matter 和恶意 HTML；
  可控 Promise 验证乱序、卸载、清空、失败与高亮回退。
- `./scripts/windows/verify/verify-windows-boundaries.sh`。
- `./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`。
- `./scripts/macos/verify/verify-runtime-bundle-immutability.sh`。

自动化组件及动态库测试不替代真实 WebView2（Windows 内嵌浏览器）交互验收，
功能矩阵保留 pending。

## 适用范围

- `windows/tauri/src/features/editor/markdown/`
- `windows/tauri/src/features/github/components/github-markdown.tsx`
- `rust/lithe-core/src/project/markdown.rs`
- `shared/fixtures/editor/markdown-render-v1.json`
- `shared/platform-feature-matrix/features/markdown-rendering.json`
