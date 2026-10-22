# Agent 笔记：macOS HTML 预览是一个内嵌的单标签浏览器

状态：已实现

## 先说结论

macOS 的 HTML 预览不再是“把 HTML 字符串塞进 WebView、点什么都取消”的静态画面，而是一个内嵌的单标签浏览器：有后退、前进、刷新/停止、可输入的地址栏、页面缩放（− / 百分比 / +）、常驻滚动条、系统浏览器按钮和开发者工具；页面里的链接、锚点、`alert`/`confirm`/`prompt`、文件选择、下载和 `window.open` 都按浏览器的方式工作。当前编辑的文档来自编辑器缓冲区（所以没保存的修改也能看到），其余资源按只读的静态网站从磁盘提供。开发者以后要改预览行为，改 `HTMLPreviewBrowserController` 和它旁边的纯规则文件，不要回到 `loadHTMLString` 加“取消全部导航”的做法。

## 问题

旧实现用 `loadHTMLString(_:baseURL:)` 加载文本，并在 `WKNavigationDelegate` 里取消所有链接点击，没有设置 `WKUIDelegate`。使用者看到的是“只能看不能用”：

- 点击链接、表单提交、`#锚点` 全部被取消；`target="_blank"`、`window.open` 没有任何反应。
- `alert`、`confirm`、`prompt` 和 `<input type="file">` 在没有 UI 委托时被 WebKit 直接当作“取消”，页面脚本拿到的是假结果。
- 页面实际在 `file://` 或 `about:blank` 来源下运行：`<script type="module">`、`fetch`、`XMLHttpRequest` 被浏览器安全策略拒绝，`/assets/app.js` 这类以斜杠开头的路径指向磁盘根目录而不是项目。
- 没有地址、历史和刷新，页面一旦被改写就没有办法回到起点。
- 没有开发者工具，页面脚本出错时无从排查。

## 决策

### 页面由自定义协议提供，而不是 `file://`

文档通过 `lithe-html://preview/<相对路径>` 加载，由 `HTMLPreviewSchemeHandler`（`WKURLSchemeHandler`，负责响应自定义协议请求的 WebKit 接口）提供。它给页面一个真实的、同源的、安全上下文来源，所以模块脚本、`fetch`、`XHR`、锚点和以斜杠开头的路径都像在本地开发服务器上一样工作。

- 服务根目录（`HTMLPreviewScope`）：文档在工作区内时是工作区，否则是文档所在目录。`/assets/app.js` 指向服务根目录下的 `assets/app.js`。
- 被预览的文档本身来自编辑器缓冲区；其它文件只读，不写回磁盘。
- 响应规则放在纯函数 `HTMLPreviewResponder.respond` 中：只允许 `GET`/`HEAD`，支持单段 `Range`（视频、音频拖动进度需要），固定 `Cache-Control: no-store`（磁盘上的修改刷新后立刻可见），并为 `js`、`mjs`、`css`、`wasm`、`woff2` 等补充系统类型表缺失的 MIME 类型（WebKit 会拒绝类型错误的模块脚本和样式表）。
- 请求按完整路径分量判断是否仍在服务根目录内，`..`、百分号编码的 `..` 和指向根目录外的符号链接都得到 404。
- 目录请求返回其 `index.html`。Web 服务器会把 `/docs` 重定向到 `/docs/`，自定义协议的处理器做不到，所以地址栏里的目录地址由 `HTMLPreviewURL.url(forFile:in:)` 补上结尾斜杠，否则目录首页里的相对链接会按上一级解析。页面里不带斜杠的目录链接（`<a href="docs">`）仍然如此，这是已知限制。
- 资源请求在并发队列上处理，一个大的媒体文件不会挡住同一页面的脚本和样式。

### 页面不能借同源 `fetch` 读走本地机密

打开的仓库里可能有一个恶意 HTML。如果它能通过 `fetch('/.env')` 读到旁边的凭据，同源服务就成了泄露通道。因此：

- `HTMLPreviewAccessPolicy` 拒绝（403）路径中任何以 `.` 开头的分量（`.env`、`.git`、`.ssh`）以及 `pem`、`key`、`p12`、`pfx`、`keystore`、`jks` 扩展名。被预览的文档本身例外（它来自缓冲区，用户已经打开了它）。
- 子资源请求的顶层文档或 `Referer` 不在 `lithe-html://preview` 内时拒绝。这样在地址栏打开的远程网页即使嵌入了 `lithe-html://` 地址，也读不到本地文件。
- 导航策略永远不加载 `file:`：远程页面不能跳到本地文件，地址栏输入的本地路径会被改写为 `lithe-html://` 地址，并且只允许服务根目录内的文件。
- 页面使用非持久化的 `WKWebsiteDataStore`：Cookie、本地存储和缓存随预览关闭而消失，不在磁盘留下状态，也不触碰 app bundle（见 AGENTS.md 的运行时只读边界）。

### 导航规则是一张可测试的表

`HTMLPreviewNavigationPolicy.decide` 不依赖 WebKit 对象（`WKNavigationAction` 无法在测试中构造），输入是 URL、导航类型、目标框架和是否下载：

- `lithe-html`、`http`、`https`：在预览内跟随；新窗口请求（`target="_blank"`、`window.open`）也在当前标签中加载，因为预览只有一个标签。
- `mailto`、`tel`、`sms`：只有使用者点击链接时交给系统；脚本自动触发的一律取消，避免远程页面拉起任意应用。
- 顶层 `data:`、`blob:` 取消（钓鱼常用手法），框架内允许；`file:` 和其它未知协议取消。
- `javascript:` 允许（它在页面自己的上下文执行）。
- 下载：附件响应和 `<a download>` 走 `WKDownload`，保存位置由原生保存面板选择；`lithe-html` 资源 WebKit 无法下载，直接从缓冲区或磁盘复制到选择的位置（`HTMLPreviewFileSaver`）。这条路径同时覆盖“点击了一个预览视图无法显示的文件链接”（压缩包、二进制等，响应阶段才知道类型）；否则这类链接什么都不会发生。选择的位置就是源文件自身时不能先删除再复制，否则会删掉唯一的一份，所以按文件身份（不是路径）判断后直接跳过。

### 浏览器功能

`HTMLPreviewBrowserController`（`@MainActor`，`ObservableObject`）拥有 `WKWebView`，并向 SwiftUI 发布地址、可否后退/前进、是否加载中、错误文案和开发者工具状态。视图 `HTMLPreviewView` 只负责工具栏：

- 后退、前进、刷新/停止（刷新时按住 Shift 为强制刷新）、地址栏、“在系统浏览器中打开”、开发者工具开关。
- 页面缩放：“−”、百分比按钮（点击恢复 100%）、“+”，⌘+ / ⌘= / ⌘− / ⌘0 在页面获得焦点时同样生效。缩放用 `WKWebView.pageZoom`（与浏览器的页面缩放一致，布局宽度随之变化），按浏览器菜单的固定档位（25%、33%、50%、67%、75%、80%、90%、100%、110%、125%、150%、175%、200%、250%、300%、400%、500%）逐档调整，档位和快捷键映射在纯规则 `HTMLPreviewZoom` 中。缩放比例由控制器持有，在同一预览里跳转页面、后退前进、刷新后都保持，像浏览器标签一样只由使用者重置；恢复 100% 时一并复位捏合产生的 `magnification`，因为捏合缩放与页面缩放是两套独立的缩放，不会体现在百分比上。快捷键由 `WKWebView` 子类 `HTMLPreviewWebViewSurface` 处理，且只有页面（或其子视图）是第一响应者时才响应：快捷键会被派发给窗口里所有视图，预览与编辑器分屏时不能抢走编辑器里的 ⌘+。
- 地址栏显示“本地文件的 `file://` 路径”而不是内部协议；输入时不会被页面加载完成覆盖，按 Esc 还原；输入 `example.com` 补全为 `https://`，`localhost`/`127.0.0.1` 补全为 `http://`，普通单词不当作地址。
- 编辑器切换到另一个 HTML 文件时预览视图会被复用：第一次渲染时 `HTMLPreviewContent` 还保存着上一个文件的文字，所以先向文档本身取文字（`html(for:)`）。控制器里，正在加载这个文档时再来的更新要重新发起加载，不能调用 `reload`：`reload` 作用于屏幕上已有的页面，会把上一个文档重新加载回来并取消新文档的加载。
- WebKit 在独立进程里运行页面，系统可能因内存压力结束它，预览会一直空白到下一次编辑。`webViewWebContentProcessDidTerminate` 会重新加载页面；连续两次恢复后仍然崩溃的页面保持空白，不无限重试。
- 编辑器内容变化经 150 ms 防抖后更新缓冲区：正在显示该文档时重新加载，使用者已经跳到别的页面时不打扰，回到该文档时自然是新内容。重新加载前先从页面读出滚动位置，通过一次性的 `WKUserScript` 在新文档解析完成时放回去，并在页面里把 `history.scrollRestoration` 设为 `manual`。原因是 WebKit 自己的恢复依赖历史条目里保存的位置，而这个位置是延迟更新的（实测滚动后约 1 秒内重新加载仍会回到顶部），而且它在加载完成后才恢复，会覆盖我们放回去的位置。这两个脚本在加载完成或失败后移除，不影响之后的后退/前进。
- “在系统浏览器中打开”：本地页面沿用已有的 `MacHTMLBrowserOpener` 打开磁盘文件（所以未保存修改不包含在内），远程页面直接打开当前网址。
- JavaScript 对话框用 `NSAlert`/`NSOpenPanel`/`NSSavePanel` 的 sheet 呈现，页面脚本在 sheet 关闭前保持阻塞，与浏览器一致；对话框标题标明来源文件或域名。窗口缺失时返回取消结果，保证每个回调恰好执行一次。
- 页面加载失败显示在工具栏下方的横幅里；被取消的加载和被策略中断的框架（`WebKitErrorDomain` 102）不报错。

### 滚动条常驻显示

WebKit 默认画系统的叠加式（overlay）滚动条，只在滚动时短暂出现。页面比预览区域宽或高时，使用者看不到任何提示，也找不到页面底部的横向滚动条（缩放到 500% 时尤其明显）。预览因此给页面注入一份样式，让纵向和横向滚动条像桌面浏览器那样在内容溢出时常驻显示在右边缘和下边缘，内容放得下时不出现：

- 样式由 `HTMLPreviewScrollbars` 生成，通过 `WKUserScript`（文档开始时、所有 frame）注入，运行在独立的 `WKContentWorld.defaultClient` 里，页面脚本看不到它。使用可构造样式表（`adoptedStyleSheets`），不依赖内联 `<style>`，页面设置了 CSP 也不受影响；系统不支持时退回 `<style>`。
- 规则放在 `@layer lithe-scrollbars` 里。任何页面自己的样式（哪怕优先级更低）都高于未命名层之外的层规则，所以页面自己写了 `::-webkit-scrollbar` 时保持页面的外观。
- 样式单位是 CSS 像素，会被页面缩放放大，所以脚本按缩放比例反向换算（厚度恒为 14 pt）。缩放变化时用 `installUserScripts()` 重建脚本集合，并在当前页面里重新执行同一段源码替换样式表，这样当前页和之后加载的页面都是新尺寸。
- `WKUserContentController` 只能一次性移除全部脚本，所以脚本集合由控制器的状态重建（滚动条样式 + 重新加载期间的滚动位置恢复脚本），不要在别处直接 `addUserScript`/`removeAllUserScripts`。

考虑过但没有采用的做法：

- `WKWebView` 的私有方法 `_setAlwaysShowsHorizontalScroller:`/`_setAlwaysShowsVerticalScroller:`：实测在叠加式滚动条下没有任何可见变化。
- 给应用设置 `AppleShowScrollBars = Always`：会让 Monaco、Markdown 预览、插件网页等所有 WebView 和未显式设置样式的 AppKit 滚动视图一起变成经典滚动条，影响面太大。

### 开发者工具使用 WebKit 私有接口

WebKit 没有公开的 Web Inspector 开关，所以：

- 打开 `developerExtrasEnabled`（偏好设置私有键）并设置 `isInspectable`（macOS 13.3+ 公开属性）。
- 通过 `webView.value(forKey: "_inspector")` 取得 `_WKInspector`，用 `show`/`close`/`isVisible` 控制。每次调用前都先检查 `responds(to:)`；不可用时按钮置灰而不是崩溃。
- `WKWebView` 外面包一个普通 `NSView` 容器（`containerView`）。WebKit 通过在被检查视图旁边加一个兄弟视图把检查器停靠在底部，如果 `WKWebView` 本身就是 SwiftUI 管理的根视图，停靠会破坏布局。
- 检查器开关状态通过 `NSView.frameDidChangeNotification`（停靠/关闭都会改变被检查视图的尺寸）刷新，使用者在检查器内点关闭按钮时按钮状态也会同步。

这使用了私有接口，发布到 Mac App Store 的版本不能使用；Lithe 以 Developer ID 分发，可以接受。系统更新若移除接口，`isDeveloperToolsAvailable` 会变成 false（有测试把它当作金丝雀）。

### 正确做法

- 新增导航规则时，在 `HTMLPreviewNavigationPolicy` 增加一行并补 `HTMLPreviewNavigationTests`，不要在 `decidePolicyFor` 里直接写协议分支。
- 新增服务端行为（例如新的类型、请求头）时，改 `HTMLPreviewResponder`（纯函数）并补 `HTMLPreviewResourcesTests`。
- 新增页面能力（对话框、权限、下载）时，用 `HTMLPreviewDialogPresenting` 注入，测试里用记录型替身，不要在测试里弹真实面板。

### 不要这样做

- 不要把 `allowFileAccessFromFileURLs` 之类的私有开关打开，用 `file://` 绕过同源限制；那会让任何 HTML 都能读取使用者的整个磁盘。
- 不要放宽 `HTMLPreviewAccessPolicy` 的隐藏文件/密钥拒绝，也不要去掉 `Referer`/主文档检查；它们是自定义协议提供同源服务时唯一的泄露防线。
- 不要在 `updateNSView` 里无条件给 `@Published` 属性赋值（即使值相同也会触发 SwiftUI 的“视图更新期间发布变更”警告）；控制器用 `clearLoadError()` 只在有变化时赋值。
- 不要把 `WKWebView` 直接作为 `NSViewRepresentable` 返回的视图，会破坏开发者工具停靠。

## 考虑过的备选方案

### 用 `loadFileURL(_:allowingReadAccessTo:)` 加载磁盘文件

最简单，页面能直接引用同目录资源。但来源是 `file://`，模块脚本、`fetch` 和 `XHR` 仍被拒绝；也不能显示尚未保存的编辑内容，每次编辑要写临时文件，而写入位置必须避开 app bundle 并清理。所以没有采用。

### 在本机启动一个 HTTP 服务器

行为最接近真实网站，但需要选择端口、管理进程生命周期并处理防火墙提示，还会让同机其它进程访问到工作区文件。自定义协议只在 WebView 内部可见，没有端口，也不留下进程。

### 只放开链接点击，不做地址栏和开发者工具

改动最小，但使用者的诉求是“把 WebView 当浏览器用”：需要回退、刷新、输入网址和排查脚本错误。只放开点击会在跳转后失去返回路径。

### 为每次 `window.open` 创建新标签或新 WebView

更接近完整浏览器，但预览位于编辑器区域，没有标签管理界面。单标签就地加载保持了界面简单，后退按钮即可回到原页面。

## 后果

- 收益：页面行为接近真实浏览器；使用者能直接在编辑器里调试前端页面；规则集中在可单测的纯函数中。
- 代价：使用 `_WKInspector` 私有接口，需要在 macOS 大版本升级时回归；预览窗口不再是透明背景，页面背景由页面样式决定。
- 已知限制：`showDirectoryPicker` 等只有 Chromium 才有的 Web API 在 WebKit 中不存在，依赖它们的页面（例如 `assets/agent-notes-board.html`）需要在 Chromium 内核浏览器中使用，可用“在系统浏览器中打开”。
- Windows 端的 HTML 预览（iframe `srcDoc` 加 `<base>`）没有这些能力，已在功能矩阵中记录，另行跟进。
- 需要重新评估的触发条件：Apple 提供公开的 Web Inspector 接口；预览需要多标签；需要持久登录状态（当前使用非持久数据存储）。

## 验证

- `./scripts/test-macos.sh --filter HTMLPreview`
- `./scripts/test-macos.sh --filter AppLocalizationTests`
- `./scripts/verify-runtime-bundle-immutability.sh`
- `./scripts/verify-platform-feature-matrix.sh`
- 在运行的应用中打开 HTML：用工具栏后退/前进/刷新，输入本地路径和网址，点击锚点和相对链接，触发 `alert`/`confirm`/`prompt`，打开开发者工具并确认停靠在页面下方。
- 打开一个比预览区域宽且高的页面，确认右边缘和下边缘常驻滚动条，缩放到 500% 后滚动条仍是正常粗细，内容放得下的页面没有滚动条。
- 点击指向压缩包的链接弹出保存面板、`<a download>` 保存、在地址栏输入带 `index.html` 的目录路径能正常加载其中的脚本、在分屏里切换到另一个 HTML 标签时预览显示新文件（对应 `HTMLPreviewBrowserTests` 里的同名用例）。
- 在运行的应用中用 − / + / 百分比按钮和 ⌘+ / ⌘− / ⌘0 缩放，确认百分比与页面实际大小一致，跳转页面后缩放保持，分屏时在编辑器里按 ⌘+ 不会缩放预览。

## 适用范围

- `macos/Sources/Lithe/Platform/MacOS/HTMLPreviewBrowser.swift`
- `macos/Sources/Lithe/Platform/MacOS/HTMLPreviewResources.swift`
- `macos/Sources/Lithe/Platform/MacOS/HTMLPreviewNavigation.swift`
- `macos/Sources/Lithe/Platform/MacOS/HTMLPreviewDialogs.swift`
- `macos/Sources/Lithe/Platform/MacOS/HTMLPreviewZoom.swift`
- `macos/Sources/Lithe/Platform/MacOS/HTMLPreviewScrollbars.swift`
- `macos/Sources/Lithe/Platform/MacOS/HTMLPreviewWebView.swift`
- `macos/Sources/Lithe/Views/Editor/HTMLPreviewView.swift`
