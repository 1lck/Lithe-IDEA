# Agent 笔记：macOS HTML 预览是一个内嵌的单标签浏览器

状态：已实现

## 先说结论

macOS 的 HTML 预览不再是“把 HTML 字符串塞进 WebView、点什么都取消”的静态画面，而是一个内嵌的单标签浏览器：有后退、前进、刷新/停止、可输入的地址栏、页面缩放（− / 百分比 / +）、常驻滚动条、系统浏览器按钮和开发者工具；页面里的链接、锚点、`alert`/`confirm`/`prompt`、文件选择、下载和 `window.open` 都按浏览器的方式工作；此外还有页内查找、右键菜单、打印 / 导出 PDF，以及页面申请摄像头 / 麦克风时的确认弹窗和地址栏右侧的“设备使用中”指示器。功能范围对标 VS Code 的 Simple Browser，多标签、书签、历史以后做成插件，不要加在这里。当前编辑的文档来自编辑器缓冲区（所以没保存的修改也能看到），其余资源按只读的静态网站从磁盘提供。开发者以后要改预览行为，改 `HTMLPreviewBrowserController` 和它旁边的纯规则文件，不要回到 `loadHTMLString` 加“取消全部导航”的做法。

## 问题

旧实现用 `loadHTMLString(_:baseURL:)` 加载文本，并在 `WKNavigationDelegate` 里取消所有链接点击，没有设置 `WKUIDelegate`。使用者看到的是“只能看不能用”：

- 点击链接、表单提交、`#锚点` 全部被取消；`target="_blank"`、`window.open` 没有任何反应。
- `alert`、`confirm`、`prompt` 和 `<input type="file">` 在没有 UI 委托时被 WebKit 直接当作“取消”，页面脚本拿到的是假结果。
- 页面实际在 `file://` 或 `about:blank` 来源下运行：`<script type="module">`、`fetch`、`XMLHttpRequest` 被浏览器安全策略拒绝，`/assets/app.js` 这类以斜杠开头的路径指向磁盘根目录而不是项目。
- 没有地址、历史和刷新，页面一旦被改写就没有办法回到起点。
- 没有开发者工具，页面脚本出错时无从排查。

## 决策

### 范围：对标 VS Code Simple Browser，完整浏览器以后做成插件

预览的定位是“编辑器里够用的内嵌浏览器”，参照 VS Code 的 Simple Browser，而不是第二个 Safari。

- 在范围内：单标签导航、页面缩放、页内查找、右键菜单、打印和导出 PDF、开发者工具、页面申请摄像头 / 麦克风时的确认与使用指示，以及 WebAssembly（`fetch` 和 `WebAssembly.instantiateStreaming` 能在 `lithe-html://preview` 下加载 `.wasm`，由 `HTMLPreviewBrowserTests` 在真实 `WKWebView` 里证明）。
- 不在范围内：多标签、书签、浏览历史、持久登录状态、下载管理器、扩展。完整浏览器以后作为插件交付；宿主不为它写按插件名区分的分支，也不为它预留私有入口。
- 取舍：范围小，使用者要标签页或书签时只能用“在系统浏览器中打开”；换来的是预览区不增加标签条、历史库和持久存储这类需要长期维护、又会写磁盘的状态，也不和插件里的完整浏览器重复。

### 页面由自定义协议提供，而不是 `file://`

文档通过 `lithe-html://preview/<相对路径>` 加载，由 `HTMLPreviewSchemeHandler`（`WKURLSchemeHandler`，负责响应自定义协议请求的 WebKit 接口）提供。它给页面一个真实的、同源的、安全上下文来源，所以模块脚本、`fetch`、`XHR`、锚点和以斜杠开头的路径都像在本地开发服务器上一样工作。

- 服务根目录（`HTMLPreviewScope`）：文档在工作区内时是工作区，否则是文档所在目录。`/assets/app.js` 指向服务根目录下的 `assets/app.js`。
- 被预览的文档本身来自编辑器缓冲区；其它文件只读，不写回磁盘。
- 响应规则放在纯函数 `HTMLPreviewResponder.respond` 中：只允许 `GET`/`HEAD`，支持单段 `Range`（视频、音频拖动进度需要），固定 `Cache-Control: no-store`（磁盘上的修改刷新后立刻可见），并为 `js`、`mjs`、`css`、`wasm`、`woff2` 等补充系统类型表缺失的 MIME 类型（WebKit 会拒绝类型错误的模块脚本和样式表）。
- 请求按完整路径分量判断是否仍在服务根目录内，`..`、百分号编码的 `..` 和指向根目录外的符号链接都得到 404。
- 目录请求返回其 `index.html`。Web 服务器会把 `/docs` 重定向到 `/docs/`，否则目录首页里的相对链接会按上一级解析。自定义协议的处理器没有公开的重定向 API，所以这件事放在导航层：`HTMLPreviewURL.folderRedirect(for:in:)` 判断一个不带斜杠的地址是不是目录，`decidePolicyFor navigationAction` 取消这次导航并改为加载带斜杠的地址（查询串和片段保留）。主框架直接 `load`；页面里的 iframe 没有自己的 web view，由控制器在该 frame 里执行 `location.replace`。地址栏输入目录时 `HTMLPreviewURL.url(forFile:in:)` 直接补上斜杠，省掉一次往返。
- 资源请求在并发队列上处理，一个大的媒体文件不会挡住同一页面的脚本和样式。任务簿记（“WebKit 调用 `stop` 之后不能再碰这个任务”）和根目录包含检查与 Markdown 预览的资源处理器共用 `LocalFileSchemeSupport.swift` 里的 `LocalFileSchemeTasks` 和 `LocalFileContainment`：任务在 `start` 时登记，应答前必须 `claim`（只成功一次，`stop` 之后永远失败），并且在主线程上投递，这样 `stop` 不可能插在 claim 与投递之间。新增读本地文件的 scheme 处理器应复用它们，不要再各写一份。

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
- 样式单位是 CSS 像素，会被页面缩放放大，所以样式表按缩放比例反向换算（厚度恒为 14 pt）。缩放变化时用 `installUserScripts()` 重建脚本集合（之后加载的页面用新尺寸），并更新已显示的页面：主框架由控制器直接执行 `updateScript`；页面里的 iframe 无法用公开 API 一次性批量执行脚本，所以每个子 frame 的脚本在启动时通过消息处理器 `litheScrollbarFrame` 上报自己（带一个标识当前文档的随机 token），控制器保存收到的 `WKFrameInfo`，缩放后逐个 `evaluateJavaScript(in:)`。返回的 token 与上报时不同或执行失败，说明该 frame 已经消失或换了文档，就从列表里删除；主框架每次提交新文档时清空列表，列表上限 128 个。
- `WKUserContentController` 只能一次性移除全部脚本，所以脚本集合由控制器的状态重建（滚动条样式 + 重新加载期间的滚动位置恢复脚本），不要在别处直接 `addUserScript`/`removeAllUserScripts`。

考虑过但没有采用的做法：

- `WKWebView` 的私有方法 `_setAlwaysShowsHorizontalScroller:`/`_setAlwaysShowsVerticalScroller:`：实测在叠加式滚动条下没有任何可见变化。
- 给应用设置 `AppleShowScrollBars = Always`：会让 Monaco、Markdown 预览、插件网页等所有 WebView 和未显式设置样式的 AppKit 滚动视图一起变成经典滚动条，影响面太大。
- 让每个 frame 自己发现缩放变化：`resize` 事件在 CSS 尺寸固定的 iframe 里不可靠，`matchMedia('(resolution: …)')` 的 `change` 在 WebKit 缩放时实测不触发；定时轮询 `devicePixelRatio` 会让空闲的预览持续唤醒页面进程。所以改为原生端记录 frame、缩放时主动推送。

### 页内查找

⌘F 在工具栏下方打开查找条，⌘G / ⇧⌘G（或 Return / ⇧Return、条上的两个箭头）在匹配项之间前进 / 后退并回绕，Esc 或关闭按钮收起查找条并把键盘还给页面。查找本身交给 `WKWebView.find`：WebKit 在页面里选中并高亮匹配项，不区分大小写。

- 快捷键映射放在纯规则 `HTMLPreviewFind.command(forKey:modifiers:)`，和缩放、打印一起由 `HTMLPreviewWebViewSurface.performKeyEquivalent` 处理，同样只在页面（或其子视图）是第一响应者时才响应：预览与编辑器分屏时，焦点在编辑器里的 ⌘F / ⌘G / ⌘P 仍属于编辑器。代价是焦点在查找条输入框里时 ⌘G 不会交给预览，那时用 Return / ⇧Return 或箭头按钮。
- WebKit 的回答只有“找到 / 没找到”（`WKFindResult.matchFound`），没有匹配总数和当前序号，所以查找条不显示“3 / 12”，只在没有匹配时显示“No matches”。不要为了计数自己往页面里注入脚本去数匹配项：它和 WebKit 的选中、高亮对不上。
- `find` 从当前选中内容的末尾继续往后找。使用者多输入一个字母时，如果不处理，就会跳过仍然匹配的当前位置去找下一处。所以输入变化和重新打开查找条时，先在独立的内容世界 `LitheHTMLPreviewFind`（页面脚本看不到）里把选区折叠到开头，再查找；⌘G 这类“下一个”不折叠。
- 每次查找带一个递增编号，较早的回答（输入太快、页面已换）直接丢弃；换页后清空结果，但保留查找条和里面的文字。`completedSearches` 记录 WebKit 已经回答的次数，测试靠它判断“这一步结束了”，因为连续两次都找到时 `status` 不会变。
- 没有匹配、清空输入、关闭查找条时，通过私有方法 `_hideFindUI` 清掉 WebKit 画的黄色指示（调用前检查 `responds(to:)`，没有这个方法时指示自行淡出）。关闭查找条后最后一个匹配保持选中。

### 右键菜单

WebKit 自己构建右键菜单：链接菜单里有“拷贝链接”，各个菜单底部有“检查元素”（`developerExtrasEnabled` 打开后出现）。预览保留这两项，只做两处调整，并且靠 `NSMenuItem` 的标识符而不是标题识别 WebKit 的条目（标题随系统语言变化）：

- 删掉“在新窗口中打开链接 / 图片”：预览只有一个标签，新窗口请求本来就在当前标签里加载，这个菜单项会让使用者误以为会开新窗口。
- 在页面空白处的菜单（带“重新载入”的那一个）里，“检查元素”上方加入“Print…”和“Export as PDF…”，并清理多余的分隔线。链接、图片、文字的菜单其余条目不动。

Swift 里没有公开 `WKMenuItemIdentifier…` 这些常量，所以 `HTMLPreviewContextMenu` 用原始字符串匹配；`HTMLPreviewContextMenuTests` 用在真实 web view 上记录下来的菜单布局手工构造 `NSMenu` 来验证（空白处是 重新载入、分隔线、分隔线、检查元素；链接是 打开链接、在新窗口打开、下载链接文件、拷贝链接、共享、检查元素，等等）。系统更新后标识符若改了，对应的调整不再生效（“在新窗口打开”留着，打印条目不出现或挂在菜单末尾），不会崩溃，⌘P 仍然可用。

### 打印和导出 PDF

页面有焦点时按 ⌘P，或在页面空白处右键选“Print…”，以窗口 sheet 的形式打开系统打印面板（`WKWebView.printOperation(with:)`）。这个操作的视图一开始 frame 是空的，不先设成 `webView.bounds` 会打出空白页，所以 `printPage()` 先设置 frame 再运行；任务名取页面标题，也就是打印面板 PDF 菜单里的默认文件名。

“Export as PDF…”弹出保存面板，用 `WKWebView.pdf()` 把整页保存成**一页连续的 PDF**，不按纸张分页（测试用 3000 pt 高的页面确认导出的页高超过 1500 pt）。要分页的版本，用打印面板左下角的 PDF 菜单。写文件失败（例如目标目录不存在）经 `report(_:)` 显示在工具栏下方的横幅里；取消保存面板不写文件也不报错。文件名来自页面标题（`HTMLPreviewPDF`）：路径分隔符换成 `-`，去掉两端的点和空白，最长 100 个字符，标题为空时用文件名或域名。

### 摄像头和麦克风

页面调用 `getUserMedia` 时，`WKUIDelegate` 的 `requestMediaCapturePermissionFor` 把请求交给 `HTMLPreviewBrowserController.requestMediaCapture`：

- 弹出 `NSAlert` sheet，标题写明是哪个页面（本地文件显示文件名，网页显示域名）想用摄像头、麦克风还是两者。按钮顺序是“Don’t Allow”（默认，Return 选它）、“Allow”：只有明确点“Allow”才授权。弹窗没有给 Esc 单独映射按钮，要拒绝就点“Don’t Allow”或按 Return。窗口缺失时按拒绝处理，回调恰好执行一次。
- **每次请求都重新询问，什么也不记**：没有“记住这个页面”，没有任何持久化的授权。
- 地理位置和剪贴板读取不做自定义弹窗，使用 WebKit 自带的确认；这次没有单独实测它们在预览里的表现。
- 请求的设备类型转成 `HTMLPreviewMediaDevices`；`WKMediaCaptureType` 里将来新增的类型视为“没有任何已知设备”，直接拒绝。屏幕共享不提供：私有偏好 `screenCaptureEnabled` 设为 `false`（设置前先检查 `_setScreenCaptureEnabled:`），页面看不到 `getDisplayMedia`。
- WebKit 默认要求页面处于焦点才处理 `getUserMedia`（偏好 `getUserMediaRequiresFocus`），否则请求静默挂起，没有任何提示。产品里保持 WebKit 的默认值，所以使用者正在编辑器里输入、预览刚重新加载时，页面一加载就发起的请求要等到使用者点一下预览才会弹出确认；只有测试会关掉这个要求。

地址栏右侧的“设备使用中”指示器（`HTMLPreviewCaptureIndicator`）只在有设备被使用时出现：红色的摄像头 / 麦克风图标，静音后变灰；点击打开菜单，可以对每个设备“Mute / Unmute”或“Stop”。它不自己记状态：`HTMLPreviewCaptureModel` 用 KVO 观察 `WKWebView.cameraCaptureState` / `microphoneCaptureState`，操作经 `setCameraCaptureState` / `setMicrophoneCaptureState` 回到 web view，所以页面自己停止、系统静音或另一个页面抢走设备时，指示器也跟着变。

停掉最后一个设备后，WebKit 约 3 秒（实测 3000 毫秒）才把状态降为 none，页面里的轨道则马上结束，所以点“Stop”后指示器还会停留约 3 秒；还有别的设备在用时，被停掉的设备会立刻从指示器上消失。不要为了“立刻消失”乐观地隐藏它：这 3 秒内页面若又开始采集，WebKit 的状态一直是 active、不会再发通知，乐观隐藏会在设备正在被使用时藏起指示器，宁可多显示 3 秒也不能少显示。

**为什么现在是休眠的**：WebKit 是否向页面提供 `navigator.mediaDevices`，默认取决于宿主应用的 Info.plist 有没有摄像头 / 麦克风用途说明。当前构建没有 `NSCameraUsageDescription` 和 `NSMicrophoneUsageDescription`，在本机实测页面里 `navigator.mediaDevices` 是 `undefined`，页面发不出请求，也不会出现系统权限框。这是想要的安全默认：macOS 会结束一个没有用途说明却去访问摄像头 / 麦克风的进程。控制器把同一个检查再做一遍（`HTMLPreviewMediaAccess.outcome`）：请求到了委托但缺少用途说明时，直接拒绝并提示一次“此版本无法让页面使用摄像头或麦克风”，不弹授权框。生产代码不会去打开 WebKit 的私有开关 `mediaDevicesEnabled`，只有测试会。

要让功能真正可用，需要在 `macos/Resources/Info.plist` 增加 `NSCameraUsageDescription` 和 `NSMicrophoneUsageDescription`（以及它们的本地化文案）。隐私用途说明和 entitlements 属于要先经维护者确认的改动，所以这次没有动它们，功能保持休眠。打包脚本 `scripts/package-app.sh` 用 `codesign --force --deep --sign "$SIGNING_IDENTITY"`，默认是 ad-hoc 签名（`-`），不带 `--options runtime`，也没有 entitlements 文件，没有启用 hardened runtime 或沙盒，所以只补用途说明就够；以后启用 hardened runtime 时还要加 `com.apple.security.device.camera` 和 `com.apple.security.device.audio-input`。ad-hoc 签名的应用，系统记录的摄像头 / 麦克风授权很可能跟着代码签名哈希走，应用更新后需要重新授权（未实测）。

**测试**：`HTMLPreviewMockCaptureTests` 在真实 `WKWebView` 里用 WebKit 的模拟摄像头 / 麦克风验证授权后指示器出现、静音 / 恢复 / 停止、摄像头和麦克风分开停止、拒绝时页面收到 `NotAllowedError`、屏幕共享不存在。模拟设备需要私有偏好 `mediaDevicesEnabled`、`mockCaptureDevicesEnabled` 和 `getUserMediaRequiresFocus = false`，只通过控制器的 `configure` 回调在测试里设置，缺任何一个就整组跳过。实测得到三条约束：

- 同一进程里第二个页面开始采集，会把第一个页面的采集静音（诊断实测：第一页 active，第二页开始后第一页变 muted；再恢复第一页，两者都是 active）。所以这组测试串行执行（`@Suite(.serialized)`），不要改成并行，否则两个测试会互相静音，间歇性失败。
- 同一个页面里第二次、第三次 `getUserMedia` 在模拟设备下会超时，所以每个页面只发一次请求。
- 隔离模式下窗口透明度为零，页面的 `visibilityState` 是 `hidden`，采集依然保持 active，所以这些测试不依赖窗口可见。
- 最后一个设备停止后，指示器状态要 3 秒才降为 inactive（上面的实测）。测试因此用页面轨道的 `ended` 事件确认“停止生效”，只在另一个设备仍在使用时才等指示器变化，不让每条用例白等 3 秒触发性能警告。

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
- 新增页面里的快捷键时，在纯规则里加 `command(forKey:modifiers:)` 并补测试，经 `HTMLPreviewWebViewSurface.performKeyEquivalent` 派发。不要另外注册全局或窗口级快捷键，它们会抢走编辑器的按键。
- 调整右键菜单时改 `HTMLPreviewContextMenu.customize`，用记录下来的 WebKit 菜单布局补 `HTMLPreviewContextMenuTests`，不要在测试里弹真实菜单。
- 新增读取 `WKWebView` 私有接口的代码时，先 `responds(to:)` 检查，缺失时退化为“功能不可用”而不是崩溃，并写进本笔记的私有接口清单（见“后果”）。

### 不要这样做

- 不要把 `allowFileAccessFromFileURLs` 之类的私有开关打开，用 `file://` 绕过同源限制；那会让任何 HTML 都能读取使用者的整个磁盘。
- 不要放宽 `HTMLPreviewAccessPolicy` 的隐藏文件/密钥拒绝，也不要去掉 `Referer`/主文档检查；它们是自定义协议提供同源服务时唯一的泄露防线。
- 不要在 `updateNSView` 里无条件给 `@Published` 属性赋值（即使值相同也会触发 SwiftUI 的“视图更新期间发布变更”警告）；控制器用 `clearLoadError()` 只在有变化时赋值。
- 不要把 `WKWebView` 直接作为 `NSViewRepresentable` 返回的视图，会破坏开发者工具停靠。
- 不要在生产代码里打开 `mediaDevicesEnabled`、`mockCaptureDevicesEnabled` 这类私有开关来“让摄像头可用”：没有用途说明却去访问摄像头 / 麦克风，macOS 会结束进程。要启用功能，先补 Info.plist 的用途说明（需要维护者确认），不要绕过。
- 不要记住摄像头 / 麦克风的授权（按页面、按域名或按会话）；每次请求都要重新问。
- 不要为地理位置、剪贴板另做一套弹窗；它们使用 WebKit 自带的确认。
- 不要把 `HTMLPreviewMockCaptureTests` 改成并行：同一进程里两个页面同时采集会互相静音。

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
- 私有接口清单（都先 `responds(to:)` 检查，缺失时功能退化而不崩溃，大版本升级时一起回归）：`_inspector` 与偏好 `developerExtrasEnabled`（开发者工具和“检查元素”）；`_hideFindUI`（清除查找高亮，缺失时高亮自行淡出）；`_setScreenCaptureEnabled:` 与偏好 `screenCaptureEnabled`（不向页面提供屏幕共享，缺失时保持 WebKit 默认）。`mediaDevicesEnabled`、`mockCaptureDevicesEnabled`、`getUserMediaRequiresFocus` 只在测试里设置。
- 已知限制：查找条没有匹配计数（WebKit 不提供）；焦点在查找条输入框里时 ⌘G 不由预览处理；导出的 PDF 是一页连续的长页，分页版本要走打印面板；摄像头 / 麦克风确认弹窗没有 Esc 映射；页面不在焦点时 `getUserMedia` 要等页面获得焦点；停掉最后一个设备后指示器还会停留约 3 秒；摄像头 / 麦克风在补上 Info.plist 用途说明之前休眠（`navigator.mediaDevices` 不存在），补上之后才能在运行的应用里端到端验收，ad-hoc 签名下系统授权记录是否跨更新保留未实测。
- 已知限制：`showDirectoryPicker` 等只有 Chromium 才有的 Web API 在 WebKit 中不存在，依赖它们的页面（例如 `assets/agent-notes-board.html`）需要在 Chromium 内核浏览器中使用，可用“在系统浏览器中打开”。
- Windows 端的 HTML 预览（iframe `srcDoc` 加 `<base>`）没有这些能力，已在功能矩阵中记录，另行跟进。
- 需要重新评估的触发条件：Apple 提供公开的 Web Inspector 接口；预览需要多标签；需要持久登录状态（当前使用非持久数据存储）。

## 验证

- `./scripts/test-macos.sh --filter HTMLPreview`
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter HTMLPreview`：带单测试计时运行。这些用例都跑真实 `WKWebView`，每项要在 1 秒告警线以内；模拟摄像头 / 麦克风那一组必须串行，原因见“摄像头和麦克风”。
- `./scripts/test-macos.sh --filter AppLocalizationTests`
- `./scripts/verify-runtime-bundle-immutability.sh`
- `./scripts/verify-platform-feature-matrix.sh`
- `./scripts/verify-agent-notes.sh`
- 在运行的应用中打开 HTML：用工具栏后退/前进/刷新，输入本地路径和网址，点击锚点和相对链接，触发 `alert`/`confirm`/`prompt`，打开开发者工具并确认停靠在页面下方。
- 打开一个比预览区域宽且高的页面，确认右边缘和下边缘常驻滚动条，缩放到 500% 后滚动条仍是正常粗细，内容放得下的页面没有滚动条。
- 点击指向压缩包的链接弹出保存面板、`<a download>` 保存、在地址栏输入带 `index.html` 的目录路径或点击不带斜杠的目录链接（包括 iframe 里的）能正常加载其中的脚本、缩放时 iframe 里的滚动条保持同样粗细、在分屏里切换到另一个 HTML 标签时预览显示新文件（对应 `HTMLPreviewBrowserTests` 里的同名用例）。
- 在运行的应用中用 − / + / 百分比按钮和 ⌘+ / ⌘− / ⌘0 缩放，确认百分比与页面实际大小一致，跳转页面后缩放保持，分屏时在编辑器里按 ⌘+ 不会缩放预览。
- 在运行的应用中按 ⌘F 打开查找条，输入文字确认页面里的匹配项被选中；⌘G / ⇧⌘G 与 Return / ⇧Return 前进、后退并回绕；输入页面里没有的文字显示 “No matches”；Esc 收起后键盘回到页面；分屏时焦点在编辑器里按 ⌘F / ⌘G / ⌘P 仍归编辑器。
- 在页面空白处、链接和图片上右键：没有“在新窗口中打开”，链接上有“拷贝链接”，空白处在“检查元素”上方有 Print… 和 Export as PDF…。⌘P 或 Print… 以窗口 sheet 打开系统打印面板；Export as PDF… 保存整页，文件名取页面标题。
- 补上 Info.plist 用途说明之后，在运行的应用中打开调用 `getUserMedia` 的页面：弹窗写明页面名称，默认按钮是 Don’t Allow；允许后地址栏右侧出现指示器，菜单里的静音 / 停止生效；再次打开同一页面仍会询问；页面里没有 `getDisplayMedia`。当前构建没有这些用途说明，这一步还不能做。

## 适用范围

- `macos/Sources/Lithe/Platform/MacOS/HTMLPreviewBrowser.swift`
- `macos/Sources/Lithe/Platform/MacOS/HTMLPreviewResources.swift`
- `macos/Sources/Lithe/Platform/MacOS/HTMLPreviewNavigation.swift`
- `macos/Sources/Lithe/Platform/MacOS/HTMLPreviewDialogs.swift`
- `macos/Sources/Lithe/Platform/MacOS/HTMLPreviewZoom.swift`
- `macos/Sources/Lithe/Platform/MacOS/HTMLPreviewFind.swift`
- `macos/Sources/Lithe/Platform/MacOS/HTMLPreviewPrint.swift`
- `macos/Sources/Lithe/Platform/MacOS/HTMLPreviewMediaCapture.swift`
- `macos/Sources/Lithe/Platform/MacOS/HTMLPreviewScrollbars.swift`
- `macos/Sources/Lithe/Platform/MacOS/HTMLPreviewWebView.swift`
- `macos/Sources/Lithe/Platform/MacOS/LocalFileSchemeSupport.swift`
- `macos/Sources/Lithe/Platform/MacOS/MarkdownPreviewWebView.swift`（共用任务簿记与包含检查）
- `macos/Sources/Lithe/Views/Editor/HTMLPreviewView.swift`
