# Agent 笔记：编辑区的 web view 预览（Markdown、图片、SVG、PDF）

状态：已实现

## 先说结论

Viva 桌面端在系统有 web 引擎时（macOS 的 WKWebView、Windows 的 WebView2），Markdown 预览、图片查看器、
SVG 图片和 PDF 都显示在编辑区内嵌的 web view（网页视图）里。页面和它用到的脚本、字体全部编进应用二进制，
经应用自己的 `lithe-preview` 协议提供，不访问网络。页面能读到用户的哪个文件由宿主决定：Markdown 的链接和图片
按 Core 的 `markdown.resolveReference` 解析，查看器只能读它显示的那一个文件或缓冲区。Linux 没有 web 引擎，
继续使用 Viva 原生的 Markdown 渲染和 Go 自绘的图片画布，两边遵循同一套图片查看规则。

## 问题

Viva 的原生 Markdown 组件只排版 Markdown 本身。README 里常见的内嵌 HTML（徽章、`align`、`details`）、
内嵌 `<svg>`、数学公式、Mermaid 和代码高亮都显示不出来；旧 macOS 版本用 WKWebView 显示了这些内容，
迁移到 Viva 后成了功能倒退。图片查看器也只能解码 PNG、JPEG、GIF，打不开 WebP、TIFF、HEIC，
SVG 只能当文本看，PDF 只能交给外部应用。

自己在 Viva 里实现一个 HTML/CSS 排版引擎不现实。系统已经带有 web 引擎，Viva 0.2.2 起也提供 web view，
问题是怎样让网页显示内容，同时不让网页读到工作区的任意文件、不联网、不在发行目录写东西。

## 决策

- **Core 负责 Markdown 方言和过滤**。宿主把源码交给 Core 的 `markdown.render`，Core 用 Ammonia
  （HTML 白名单过滤库）去掉脚本、事件属性、危险 URL 和任意 `style`，并按白名单保留内嵌 SVG 的绘图元素
  （Lithe-core-rust#32）。页面只负责排版，并在文档用到时才加载 KaTeX、Highlight.js、Mermaid、markmap。
  页面不自己解析 Markdown，所以 Windows 旧版、macOS 旧版和 Viva 看到的是同一种方言。
- **页面只在自己的源里**。`desktop/internal/webpreview` 用 `go:embed` 打包页面，每个页面一个
  `lithe-preview` 协议服务器。页面请求图片时发 `res/<src>`，宿主问 Core 这个 `src` 指向工作区里的哪个文件、
  能不能加载，再读出文件内容回答；`http`/`https` 图片由宿主统一下载，下载走应用代理，结果放在内存 LRU
  （最近最少使用淘汰）里，最多 64 张、48 MiB，所有页面共用。页面要跳到别处时，跳转被拦下，交给宿主按
  Core 的解析结果打开源文件、定位标题或交给系统浏览器。页面不能开新窗口，也不能下载文件。
- **查看器只读一个文件**。图片和 PDF 走 `file` 路由，只回答该标签的那个文件，大小有上限（图片 64 MiB、
  PDF 256 MiB）；SVG 走 `document` 路由，回答的是编辑器当前的文本。PDF 直接交给 web 引擎自带的 PDF 查看器。
- **图片规则对齐旧 macOS 查看器**（`MediaViewerView.swift`）：34 点工具栏显示文件名、“宽 × 高 · 大小”和
  −/百分比/+；打开时四周留 24 点边距适配视口，但从不放大小图；缩放范围从“适配比例与 25% 中较小者”到 400%，
  每步 25%，点百分比回到 100%；背景是 16 点棋盘格，颜色在编辑器底色上叠加 7% 黑或白。web 页面
  （`assets/image.js`）和 Linux 的 Go 画布（`viewer_image.go`）各实现一次，常量必须一起改。
- **SVG 跟随编辑**。SVG 文件按 Markdown 的方式打开：源码与图片两栏，标签栏末尾切换源码 / 两者 / 仅图片。
  编辑后最多每 150 毫秒把文本交给页面一次，地址带上编辑版本号，避免引擎画出缓存的旧图；更新时保持用户的
  缩放和滚动位置。改成画不出来的内容时保留上一张图，只有从未画成功过才显示失败提示。超过 4 MiB 不绘制。
- **页面生命周期**。文档或标签打开期间页面一直存在；没有被这一帧声明的页面隐藏起来，保留滚动位置和排版，
  切回来时原样显示。隐藏的页面最多保留 6 个，超出时关闭隐藏最久的那个，标签再次显示时重新打开。
  窗口的 web host 还没准备好、系统没有 web 引擎、或者某个页面打开失败后，编辑区改用原生预览。
- **不写发行目录**。页面从二进制读取；回答用户文件时带 `Cache-Control: no-store`。页面不使用临时
  （ephemeral）配置，因为 WebView2 的每个临时页面都会留下一份配置目录。WebView2 的配置目录由 Viva 放在
  用户缓存目录（`%LOCALAPPDATA%\<应用>\WebView2`），WKWebView 的数据在用户的 `~/Library`，都不在 app bundle
  或安装目录里，不影响代码签名和 Sparkle 增量更新。

正确做法：页面要显示 Markdown 里写的相对图片 `docs/a.png`，就请求 `res/<base64url 编码的 src>`，由宿主问 Core 后读文件回答。

不要这样做：用 `file://` 加载页面并让它直接读相对路径，或者把工作区目录整个映射给页面。这样页面就能读到
`.env`、私钥等任何文件，Core 的解析规则也就形同虚设。

## 考虑过的备选方案

- **继续扩展 Viva 原生 Markdown 组件**：要显示任意 HTML、CSS 和 SVG，等于重写一个浏览器排版引擎，拒绝。
  原生组件保留为 Linux 和 web view 打不开时的后备。
- **在页面里用 markdown-it 一类 JS 库解析 Markdown**：会出现第二种方言，过滤规则也分散到 JS 里，
  与“通用逻辑在 Core”冲突，拒绝。
- **从 CDN 加载 KaTeX、Mermaid 等库**：离线不可用，会把用户正在看的文档暴露给第三方，也让显示结果随 CDN
  版本漂移，拒绝。库随应用内嵌，许可证见 `assets/THIRD_PARTY_NOTICES.md`。
- **用 `file://` 或把项目目录映射成虚拟主机**：页面能读到任意文件，拒绝，原因见上面的反例。
- **所有平台都用 Go 解码图片、用 Go 库栅格化 SVG**：Go 标准库不支持 WebP、TIFF、HEIC，现有的 Go SVG
  栅格化库不支持文字、滤镜和大部分 CSS，显示结果和浏览器不一致，拒绝。Go 画布只保留给 Linux。
- **隐藏的页面立即关闭，或者全部常驻**：立即关闭会在每次切标签时丢掉滚动位置并重新排版；全部常驻会让每个
  打开过的预览都占一个 web 进程的内存。折中为最多保留 6 个隐藏页面。

## 后果

收益：README 里的内嵌 HTML、SVG、数学、图表和代码高亮恢复显示；图片支持系统引擎能解码的全部格式；
SVG 和 PDF 可以在编辑区直接查看；页面能读到什么完全由宿主和 Core 决定。

代价：

- 每个打开的页面都占用一份 web 引擎内存，所以有 6 个隐藏页面的上限，切回被淘汰的页面时需要重新加载。
- 应用二进制多了约 4.3 MiB 内嵌资源，主要是 Mermaid、KaTeX 字体和 Highlight.js。升级这些库时必须同步更新
  `THIRD_PARTY_NOTICES.md` 和许可证文件。
- 图片的缩放规则在 JS 和 Go 中各有一份。它们属于视图布局，需要逐帧响应滚轮和拖动，不进 Core；
  修改时两边一起改，并分别由 `TestImageFitScaleKeepsThePaddingAndNeverEnlarges` 和页面脚本覆盖。
- Linux 仍然看不到 HTML 和富内容，SVG 只能看源码，PDF 只能交给外部应用。
- Windows 上 WebView2 能否解码 TIFF、HEIC，以及自定义协议下的 PDF 查看器是否可用，还没有真机验证；
  解码失败时会落到“无法显示”和“用外部应用打开”。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/webpreview ./internal/workbench -count=1`：覆盖页面只回答
  干净路径和内嵌文件、跳转拦截、图片只按 Core 解析结果提供、远程图片共享下载与失败重试、Markdown 页随编辑
  渲染与双向滚动、隐藏页面上限、web view 打不开时回落原生、图片查看器的工具栏与缩放、PDF 查看器、
  SVG 跟随编辑与失败保留，以及没有 web 引擎时的 Go 画布。
- `scripts/desktop/verify/verify-runtime-bundle-immutability.sh`：确认打开预览不会改写发行目录。
- 平台功能矩阵 `embedded-viewers`、`markdown-rendering`、`markdown-images-links` 记录了待真机验收的步骤。

## 适用范围

- `desktop/internal/webpreview/`
- `desktop/internal/workbench/preview_pages.go`
- `desktop/internal/workbench/markdown_web.go`
- `desktop/internal/workbench/viewer_web.go`
- `desktop/internal/workbench/viewer_image.go`
- `desktop/internal/workbench/svg_preview.go`
- `desktop/internal/core/markdown.go`
