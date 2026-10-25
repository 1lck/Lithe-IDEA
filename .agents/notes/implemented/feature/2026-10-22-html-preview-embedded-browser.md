# Agent 笔记：macOS HTML 预览是一个内嵌的单标签浏览器

状态：已实现

## 先说结论

macOS 的 HTML 预览不再是“把 HTML 字符串塞进 WebView、点什么都取消”的静态画面，而是一个内嵌的单标签浏览器：有后退、前进、刷新/停止、可输入的地址栏、页面缩放（− / 百分比 / +）、常驻滚动条、系统浏览器按钮和开发者工具；页面里的链接、锚点、`alert`/`confirm`/`prompt`、文件选择、下载和 `window.open` 都按浏览器的方式工作；此外还有页内查找、右键菜单、打印 / 导出 PDF，以及页面申请摄像头 / 麦克风时的确认弹窗和地址栏右侧的“设备使用中”指示器。功能范围对标 VS Code 的 Simple Browser，多标签、书签、历史以后做成插件，不要加在这里。当前编辑的文档来自编辑器缓冲区（所以没保存的修改也能看到），其余资源按只读的静态网站从磁盘提供。开发者以后要改预览行为，改 `HTMLPreviewBrowserController` 和它旁边的纯规则文件，不要回到 `loadHTMLString` 加“取消全部导航”的做法。页面（或其子视图）有焦点时，⌘F / ⌘G / ⇧⌘G、⌘P 和缩放快捷键归页面，应用键位监听器必须让路，否则默认键位会先把 ⌘F 交给编辑器（见“页面快捷键与应用键位的先后”）。摄像头 / 麦克风这部分代码已经就位，但目前在运行的应用里是休眠的（Info.plist 没有用途说明，页面里没有 `navigator.mediaDevices`）；2026-10-22 决定继续保持休眠，因为 Lithe 启动的子孙进程会继承摄像头授权，不经过这里的任何弹窗，原因和以后启用的前提见“补用途说明之前必须知道的事”。

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
- 页面缩放：“−”、百分比按钮（点击恢复 100%）、“+”，⌘+ / ⌘= / ⌘− / ⌘0 在页面获得焦点时同样生效。缩放用 `WKWebView.pageZoom`（与浏览器的页面缩放一致，布局宽度随之变化），按浏览器菜单的固定档位（25%、33%、50%、67%、75%、80%、90%、100%、110%、125%、150%、175%、200%、250%、300%、400%、500%）逐档调整，档位和快捷键映射在纯规则 `HTMLPreviewZoom` 中。缩放比例由控制器持有，在同一预览里跳转页面、后退前进、刷新后都保持，像浏览器标签一样只由使用者重置；恢复 100% 时一并复位捏合产生的 `magnification`，因为捏合缩放与页面缩放是两套独立的缩放，不会体现在百分比上。快捷键由 `WKWebView` 子类 `HTMLPreviewWebViewSurface` 处理，且只有页面（或其子视图）是第一响应者时才响应：快捷键会被派发给窗口里所有视图，预览与编辑器分屏时不能抢走编辑器里的 ⌘+。反过来，页面有焦点时应用键位监听器也要对这些按键让路，见“页面快捷键与应用键位的先后”。
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

- 快捷键映射放在纯规则 `HTMLPreviewFind.command(forKey:modifiers:)`，和缩放、打印一起由 `HTMLPreviewWebViewSurface.performKeyEquivalent` 处理，同样只在页面（或其子视图）是第一响应者时才响应：预览与编辑器分屏时，焦点在编辑器里的 ⌘F / ⌘G / ⌘P 仍属于编辑器。代价是焦点在查找条输入框里时（输入框不在页面里）⌘F / ⌘G / ⇧⌘G 不由预览处理，仍按应用键位走编辑器的查找命令，那时用 Return / ⇧Return 或箭头按钮。
- WebKit 的回答只有“找到 / 没找到”（`WKFindResult.matchFound`），没有匹配总数和当前序号，所以查找条不显示“3 / 12”，只在没有匹配时显示“No matches”。不要为了计数自己往页面里注入脚本去数匹配项：它和 WebKit 的选中、高亮对不上。
- `find` 从当前选中内容的末尾继续往后找。使用者多输入一个字母时，如果不处理，就会跳过仍然匹配的当前位置去找下一处。所以输入变化和重新打开查找条时，先在独立的内容世界 `LitheHTMLPreviewFind`（页面脚本看不到）里把选区折叠到开头，再查找；⌘G 这类“下一个”不折叠。
- 每次查找带一个递增编号，较早的回答（输入太快、页面已换）直接丢弃；换页后清空结果，但保留查找条和里面的文字。`completedSearches` 记录 WebKit 已经回答的次数，测试靠它判断“这一步结束了”，因为连续两次都找到时 `status` 不会变。
- 没有匹配、清空输入、关闭查找条时，通过私有方法 `_hideFindUI` 清掉 WebKit 画的黄色指示（调用前检查 `responds(to:)`，没有这个方法时指示自行淡出）。关闭查找条后最后一个匹配保持选中。

### 页面快捷键与应用键位的先后

页面（或其子视图）是第一响应者（当前接收键盘输入的对象）时，缩放（⌘+ / ⌘= / ⌘− / ⌘0）、查找（⌘F / ⌘G / ⇧⌘G）和打印（⌘P）归页面，应用键位不能先把它们拿走。按键的处理顺序决定了这件事不会自动成立：

1. 应用级键盘监听器（`MacShortcutDetector` 里的本地 `NSEvent` 监听，负责把按键匹配到应用命令）最先看到按键，早于 AppKit 把按键交给任何视图；
2. 然后 AppKit 把按键交给 key window（当前接收键盘输入的窗口），沿它的视图层级调用 `performKeyEquivalent`（“这个按键是不是你的快捷键”），页面的 `HTMLPreviewWebViewSurface` 在这里认领按键；
3. 视图都没有认领，才轮到主菜单。

第 2、3 步的先后在真实的 key window 里实测过：用一个只做验证、没有放进仓库的独立 AppKit 小程序，让一个视图和一个主菜单项绑同一个 ⌘F，视图先回答，菜单不再被问到。窗口不是 key window 时 AppKit 不问视图，直接问主菜单；这不影响本决策，因为按键总是发给 key window，监听器读到的 `event.window?.firstResponder` 就是正在接收输入的响应者。

默认键位把 ⌘F / ⌘G / ⇧⌘G 绑给编辑器的“查找 / 查找下一个 / 查找上一个”，监听器匹配到就吞掉事件（返回 nil），第 2 步永远轮不到页面：在预览页面里按 ⌘F 会去驱动编辑器的查找，页面自己的查找条打不开。评审机器人在 PR 1421 上指出了这个问题（2026-10-22）；之前的测试直接调用 `performKeyEquivalent`，绕过了监听器，所以没有发现。

决策：页面有焦点、并且按键正是页面认领的那几个时，监听器放行事件，交给 AppKit 继续派发。

- “页面认领哪些按键”只有一个来源：`HTMLPreviewPageShortcut`，它把缩放、查找、打印三张纯规则表合并成一个识别器。页面自己的 `performKeyEquivalent` 和监听器的放行规则 `MacShortcutInputPolicy.shouldDeferToPreviewPage` 读同一个识别器，页面认领什么监听器就让什么，两边不会漂移。
- “页面有焦点”用 `HTMLPreviewWebViewSurface.containing(_:)` 沿父视图链向上找：WebKit 通常把页面内部的某个子视图设为第一响应者，而不是 `WKWebView` 本身。
- 这条放行规则和终端的纯 Control 按键、输入法组合文字这两条放行规则并列，都在监听器里先于键位匹配判断。
- 这条判断在每次按键时都会执行，所以先判断按键是不是页面认领的（几次比较），只有是才沿视图层级向上找页面；普通打字不会为此遍历视图。
- 对用户自定义键位同样成立：用户把 ⌘P 绑给别的命令时，焦点在预览页面里 ⌘P 仍是打印，焦点在其他位置时仍执行用户的绑定。页面不认领的按键（例如 ⇧⌘F、⌘S、不带修饰键的字母）照旧走应用键位。
- 回归测试 `HTMLPreviewPageShortcutMonitorTests` 经 `NSApplication.sendEvent` 驱动真实监听器。测试宿主的窗口不会成为 key window，AppKit 不会把按键交给页面，所以测试把两半分开验证：页面自己的回答（直接调用 `performKeyEquivalent`，它只看第一响应者），以及监听器的让路。让路这一半先在页面有焦点时按页面认领的所有按键，再按只属于键位的 ⌘S，命令按按键顺序到达，所以 ⌘S 之前出现任何命令，就是监听器拿走了页面的按键；再把焦点移到页面外，同样的按键必须全部归键位，这证明碰撞是真实的，监听器也确实在工作。监听器只登记这几个按键，不会吞掉同一进程里别的测试发出的按键。

对照：

- 正确：焦点在预览页面里按 ⌘F，打开并驱动预览自己的查找条；焦点在编辑器里按 ⌘F，仍是编辑器的查找。
- 错误：只用直接调用 `performKeyEquivalent` 的测试证明页面快捷键可用。它绕过了先于页面看到按键的监听器，测试全绿时用户按 ⌘F 仍然去了编辑器。

### 右键菜单

WebKit 自己构建右键菜单：链接菜单里有“拷贝链接”，各个菜单底部有“检查元素”（`developerExtrasEnabled` 打开后出现）。预览保留这两项，只做两处调整，并且靠 `NSMenuItem` 的标识符而不是标题识别 WebKit 的条目（标题随系统语言变化）：

- 删掉“在新窗口中打开链接 / 图片”：预览只有一个标签，新窗口请求本来就在当前标签里加载，这个菜单项会让使用者误以为会开新窗口。
- 在页面空白处的菜单（带“重新载入”的那一个）里，“检查元素”上方加入“Print…”和“Export as PDF…”，并清理多余的分隔线。链接、图片、文字的菜单其余条目不动。

Swift 里没有公开 `WKMenuItemIdentifier…` 这些常量，所以 `HTMLPreviewContextMenu` 用原始字符串匹配；`HTMLPreviewContextMenuTests` 用在真实 web view 上记录下来的菜单布局手工构造 `NSMenu` 来验证（空白处是 重新载入、分隔线、分隔线、检查元素；链接是 打开链接、在新窗口打开、下载链接文件、拷贝链接、共享、检查元素，等等）。系统更新后标识符若改了，对应的调整不再生效（“在新窗口打开”留着，打印条目不出现或挂在菜单末尾），不会崩溃，⌘P 仍然可用。

### 打印和导出 PDF

页面有焦点时按 ⌘P，或在页面空白处右键选“Print…”，以窗口 sheet 的形式打开系统打印面板（`WKWebView.printOperation(with:)`）。这个操作的视图一开始 frame 是空的，不先设成 `webView.bounds` 会打出空白页，所以 `printPage()` 先设置 frame 再运行；任务名取页面标题，也就是打印面板 PDF 菜单里的默认文件名。

“Export as PDF…”弹出保存面板，用 `WKWebView.pdf()` 把整页保存成**一页连续的 PDF**，不按纸张分页（测试用 3000 pt 高的页面确认导出的页高超过 1500 pt）。要分页的版本，用打印面板左下角的 PDF 菜单。写文件失败（例如目标目录不存在）经 `report(_:)` 显示在工具栏下方的横幅里；取消保存面板不写文件也不报错。文件名来自页面标题（`HTMLPreviewPDF`）：路径分隔符换成 `-`，去掉两端的点和空白，最长 100 个字符，标题为空时用文件名或域名。

### 摄像头和麦克风

**原则：谁都没有默认权限。** Lithe 里每个能显示网页的地方都必须回答 `requestMediaCapturePermissionFor`：没人回答时 WebKit 会退回它自己的提示框，而不是拒绝。回答只有两种方式，而且把请求变成授权的只有一个地方，`WebMediaCapture.decide`（`WebMediaCapture.swift`）：

- **询问**（HTML 预览、插件页）：`decide` 先检查请求点名了设备、应用有对应的 Info.plist 用途说明，都满足才把问题交给 `WebMediaCaptureConfirming`。使用者明确点“Allow”才得到 `.grant`；点“Don’t Allow”、没有窗口可弹、缺用途说明、没有点名设备，一律 `.deny`，回调恰好执行一次。每个到达委托的请求都重新询问，Lithe 自己什么也不记。
- **不问直接拒绝**（Lithe 自己的页面：Markdown 预览、Monaco 编辑器和 diff、发行说明、Agent 可视化卡片）：它们把 `WebMediaCaptureDenier.shared` 设为 `uiDelegate`，没有任何理由使用设备。
- `WebMediaCaptureCoverageTests` 扫描 `macos/Sources`：每个创建 `WKWebView`（或其子类）的文件都要登记由谁回答，并且 `.grant` 只能出现在 `WebMediaCapture.swift`。新增网页入口时在这个测试里登记，不要绕过。

HTML 预览里，`WKUIDelegate` 的 `requestMediaCapturePermissionFor` 把请求交给 `HTMLPreviewBrowserController.requestMediaCapture`，它再调用 `decide`：

- 弹出 `NSAlert` sheet（`AppKitWebMediaCaptureConfirmer`），标题写明是哪个页面（本地文件显示文件名，网页显示域名）想用摄像头、麦克风还是两者。按钮顺序是“Don’t Allow”（默认，Return 选它）、“Allow”：只有明确点“Allow”才授权。弹窗没有给 Esc 单独映射按钮，要拒绝就点“Don’t Allow”或按 Return。
- 地理位置和剪贴板读取不做自定义弹窗，使用 WebKit 自带的确认；这次没有单独实测它们在预览里的表现。
- 请求的设备类型转成 `WebMediaDevices`；`WKMediaCaptureType` 里将来新增的类型视为“没有任何已知设备”，直接拒绝。屏幕共享不提供：私有偏好 `screenCaptureEnabled` 设为 `false`（设置前先检查 `_setScreenCaptureEnabled:`），页面看不到 `getDisplayMedia`。
- WebKit 默认要求页面处于焦点才处理 `getUserMedia`（偏好 `getUserMediaRequiresFocus`），否则请求静默挂起，没有任何提示。产品里保持 WebKit 的默认值，所以使用者正在编辑器里输入、预览刚重新加载时，页面一加载就发起的请求要等到使用者点一下预览才会弹出确认；只有测试会关掉这个要求。

地址栏右侧的“设备使用中”指示器（`HTMLPreviewCaptureIndicator`）只在有设备被使用时出现：红色的摄像头 / 麦克风图标，静音后变灰；点击打开菜单，可以对每个设备“Mute / Unmute”或“Stop”。它不自己记状态：`HTMLPreviewCaptureModel` 用 KVO 观察 `WKWebView.cameraCaptureState` / `microphoneCaptureState`，操作经 `setCameraCaptureState` / `setMicrophoneCaptureState` 回到 web view，所以页面自己停止、系统静音或另一个页面抢走设备时，指示器也跟着变。

停掉最后一个设备后，WebKit 约 3 秒（实测 3000 毫秒）才把状态降为 none，页面里的轨道则马上结束，所以点“Stop”后指示器还会停留约 3 秒；还有别的设备在用时，被停掉的设备会立刻从指示器上消失。不要为了“立刻消失”乐观地隐藏它：这 3 秒内页面若又开始采集，WebKit 的状态一直是 active、不会再发通知，乐观隐藏会在设备正在被使用时藏起指示器，宁可多显示 3 秒也不能少显示。

**插件页**（`MacPluginWebPage`）与 HTML 预览走同一个 `decide`，差别如下：

- 弹窗写“插件“X”想使用你的摄像头。”，说明文字列出插件 ID。插件名是插件自己起的，所以问题明说这是插件并附上 ID；名字经 `displayText` 去掉换行、控制字符和方向覆盖等不可见字符，并截到 80 个字符，防止它改写或冒充问题本身。
- 只响应插件自己的主框架（scheme `lithe-plugin`、host 等于插件 ID、端口 0）。页面所在视图不在窗口里（隐藏工具窗口时页面还保留着）则直接拒绝，不弹窗。使用者回答时再检查一次：问题开着的时候页面被隐藏或关闭，点“Allow”也按拒绝处理。实测 WebKit 自己就不会把没有窗口的页面发出的请求转给委托（脱离窗口时委托没有被调用，装回窗口后才询问一次并授权成功），所以隐藏中的插件页提出的请求要等工具窗口再次显示才会弹窗；上面的拒绝检查不依赖这个行为，是保险。
- 页面使用设备期间，视图离开窗口（隐藏工具窗口）就立刻结束采集（`setCameraCaptureState(.none)`），不会在后台继续录。授权先于设备启动：使用者点“Allow”之后、WebKit 真正启动设备之前，页面可能已经离开窗口，那时还没有采集可停。所以 `MacPluginWebPage` 还用 KVO 观察 `cameraCaptureState` / `microphoneCaptureState`，任何设备在页面不在窗口里时变成非 none，就立刻停掉。
- HTML 预览没有这一条：页面随 `HTMLPreviewView` 的 `@StateObject` 一起销毁，切到别的编辑器标签页时视图被替换，采集随之结束（读代码得出的结论，没有单独测试）；地址栏右侧的指示器也只在预览显示时可见。
- 插件页没有应用内“设备使用中”指示器，只有系统菜单栏的绿点 / 橙点，所以弹窗里说明“在你关闭或隐藏它的窗口之前，它可以一直使用该设备”。

**记住选择（没做）**：使用者接受“记住偏好”，但记住只能让弹窗变少，不能让任何请求在没有记录时默认有权限。以后做的时候：记录按“请求者（页面来源或插件 ID）加设备”存到平台存储 adapter 解析的用户目录，不能写进 app bundle；必须同时提供查看和撤销入口（设置页，归属见 `2026-10-15-macos-settings-hierarchy.md`）；记住的“允许”仍要先过 `decide` 的用途说明检查，“拒绝”优先于“允许”。没有撤销入口就不该开始存，所以这次没做。

**为什么现在是休眠的**：WebKit 是否向页面提供 `navigator.mediaDevices`，默认取决于宿主应用的 Info.plist 有没有摄像头 / 麦克风用途说明。当前构建没有 `NSCameraUsageDescription` 和 `NSMicrophoneUsageDescription`，在本机实测页面里 `navigator.mediaDevices` 是 `undefined`，页面发不出请求，也不会出现系统权限框。这是想要的安全默认：macOS 会结束一个没有用途说明却去访问摄像头 / 麦克风的进程。`decide` 把同一个检查再做一遍（`WebMediaAccess.outcome`）：请求到了委托但缺少用途说明时，直接拒绝，不弹授权框；HTML 预览里还会提示一次“此版本无法让页面使用摄像头或麦克风”。生产代码不会去打开 WebKit 的私有开关 `mediaDevicesEnabled`，只有测试会。

要让功能真正可用，需要在 `macos/Resources/Info.plist` 增加 `NSCameraUsageDescription` 和 `NSMicrophoneUsageDescription`（以及它们的本地化文案）。隐私用途说明和 entitlements 属于要先经维护者确认的改动，所以这次没有动它们，功能保持休眠。**2026-10-22 维护者的决定：继续保持休眠，不改 Info.plist 和 entitlements，不做真机验证，也不做子进程隔离**；原因是下一段的子进程继承问题，用途说明不能单独补，必须和子进程隔离一起上。打包脚本 `scripts/package-app.sh` 用 `codesign --force --deep --sign "$SIGNING_IDENTITY"`，默认是 ad-hoc 签名（`-`），不带 `--options runtime`，也没有 entitlements 文件，没有启用 hardened runtime 或沙盒，所以从系统要求看，补用途说明就能让功能跑起来（能不能补见下一段）；以后启用 hardened runtime 时还要加 `com.apple.security.device.camera` 和 `com.apple.security.device.audio-input`。ad-hoc 签名的应用，系统记录的摄像头 / 麦克风授权很可能跟着代码签名哈希走，应用更新后需要重新授权（未实测）。

**补用途说明之前必须知道的事**：系统的摄像头 / 麦克风授权属于整个 Lithe，不属于某个页面或插件。使用者在任何一个弹窗里点过“Allow”并通过系统权限框之后，系统记下的是“Lithe 可以用摄像头”。网页这一侧有 `decide` 把关，但 Lithe 启动的子孙进程（插件后端、语言服务器、内置终端里的命令、Agent CLI 和它的 shell 工具）这一侧没有。目前没有用途说明，系统会直接拒绝这些访问，所以现在不存在这个口子；补用途说明就是把它打开。

2026-10-22 在 macOS 27.2 上做过一次只读评估（只问系统的责任进程关系和沙盒策略，不碰摄像头、麦克风和系统隐私数据库），结论如下：

- **责任进程（responsible process，系统决定把子进程的隐私请求算在哪个应用头上的那个进程）沿子孙链继承，这是实测，不是推测。** 探针自己的祖先链是 `probe → zsh → claude`，三者的责任进程都是 `claude`；探针 `posix_spawn` 出的 `sh`，以及 `sh` 再起的 `sleep`，责任进程也都是 `claude`，不是它们的直接父进程。所以只要 Lithe 拿到了摄像头授权，它的任何子孙进程访问摄像头时，系统都会把请求算在 Lithe 头上。
- **脱钩责任进程（disclaim，`posix_spawn` 的私有属性 `responsibility_spawnattrs_setdisclaim`）能让子进程自成责任进程，并传给它的后代，这是实测，也有先例**（Claude 桌面应用用自带的 `Contents/Helpers/disclaimer` 启动 `claude` 命令行）。但它切断的是子进程与 Lithe 的**全部**系统授权：项目放在 Documents / Desktop / Downloads 时，`git`、`java`、`node`、`mvn` 会逐个弹文件夹授权或被拒，给了 Lithe 完全磁盘访问的使用者则整体失效。对 IDE 是回归，不选。
- **只禁设备的办法是沙盒 deny（sandbox deny，给子进程套一份“不许碰摄像头和麦克风”的沙盒策略，其它授权照旧继承）。** 策略包括 `(deny device-camera)`、`(deny device-microphone)`、相机相关的 Mach 服务（`com.apple.applecamerad`、`com.apple.appleh13camerad`、`com.apple.cmio.registerassistantservice`、`com.apple.cmio.registerassistantservice.system-extensions`）和麦克风的 IOKit 类 `AppleHDAEngineInput`；音频**输出**需要的 `com.apple.audio.coreaudiod` 保持允许，子进程放声音不受影响。这些名字正是 App Sandbox 给摄像头 / 麦克风权限用的那一组（`/System/Library/Sandbox/Profiles/appsandbox-common.sb` 里的 `(camera)` 和 `(audio-input)`）。用 `sandbox_check` 验证过：操作存在、加 deny 后答案翻转、经 `sh` 再起的后代同样被拒。`sandbox-exec` 的手册标为 DEPRECATED（已弃用），27.2 上仍可用，启动开销约 5 毫秒。
- **没有验证的部分**：沙盒 deny 是否真能让没有沙盒的进程采集失败（`sandbox_check` 只问策略引擎，要证明必须真的打开设备，需要使用者点一次系统弹窗、摄像头会短暂亮起，所以没有做）；tccd（系统的隐私授权守护进程）是否把命令行子进程的请求算到责任应用头上并复用它的授权（业界通行行为，Terminal、iTerm、VS Code 都如此，这里没有触发）；Apple Silicon 内置麦克风是否确实走 `AppleHDAEngineInput`，USB 和蓝牙设备可能走别的路径，而且麦克风 IOKit 这一条规则只确认了策略能解析，没有单独验证效果；`sandbox-exec` 在以后的 macOS 里还在不在。
- **要覆盖三套启动栈，漏掉任何一套就是一个口子**：Swift 的 `MacManagedProcess.spawn`（运行、构建、测试、调试等，唯一的 `posix_spawn` 入口）；内置终端的 SwiftTerm（它自己 `openpty` 加 `posix_spawn`，Lithe 拿不到 spawn 属性，只能改被启动的可执行文件）；Rust Core 的 `SystemProcessLauncher`（插件后端和所有语言服务器）加 `lithe-agent-host`（Agent CLI）。Lithe 自己的重启和监督进程（`MacProcessSupervisor`、`MacApplicationRelauncher`、`MacStableRollback`）必须豁免，它们就是 Lithe。

**决定（2026-10-22，维护者）：继续保持休眠。** 不改 Info.plist 和 entitlements，不做真机验证，也不做子进程隔离。以后有人要补 `NSCameraUsageDescription` / `NSMicrophoneUsageDescription` 时，用途说明和子进程隔离必须在同一个 PR 里一起上，并且隔离自检失败时 `WebMediaAccess.outcome` 像缺用途说明时一样返回 `.unavailable`，门直接拒绝、不弹系统授权框。方案比较、验收标准和动手前的真机验证步骤记在提议 Note `2026-10-22-child-process-media-isolation.md`（`proposed/architecture/`）。

**测试**：`WebMediaCaptureTests` 覆盖门的决策（没回答前什么都没授权、只有明确的 yes 才授权、每次都重新问）、问题文字和 `displayText`、拒绝委托，以及上面的源码扫描。`HTMLPreviewMediaCaptureTests` 和 `PluginWebCaptureTests` 在真实 `WKWebView` 里用 WebKit 的模拟摄像头 / 麦克风做端到端：授权后指示器出现、静音 / 恢复 / 停止、摄像头和麦克风分开停止、拒绝时页面收到 `NotAllowedError`、屏幕共享不存在；插件页还覆盖没有窗口、没有用途说明、隐藏时结束采集、隐藏后才回答的 yes，以及点“Allow”之后页面才被隐藏时才启动的设备会被停掉。模拟设备需要私有偏好 `mediaDevicesEnabled`、`mockCaptureDevicesEnabled` 和 `getUserMediaRequiresFocus = false`，只通过 `configure` 回调在测试里设置（`MockCapture.configure`），缺任何一个就整组跳过。实测得到几条约束：

- 同一进程里第二个页面开始采集，会把第一个页面的采集静音（诊断实测：第一页 active，第二页开始后第一页变 muted；再恢复第一页，两者都是 active）。所以所有端到端采集测试都放在根 suite `MockCaptureTests`（`.serialized`，对嵌套 suite 递归生效，不论写在哪个文件）里串行执行，不要改成并行，否则两个测试会互相静音，间歇性失败。
- 同一个文档里第二次请求同一种设备，在模拟设备下会超时：不论第一个流还在用还是已经停止，第二次请求都没有再到达委托，15 秒内也没有完成或失败（探针实测）。请求另一种设备（先视频后音频）则再次到达委托并授权成功，重新加载得到的新文档也会再次询问。推测 WebKit 在同一文档内复用了已经批准的授权，所以一次“Allow”在该文档存活期间对同一种设备有效，包括停止后再次开始；这只是推测，模拟设备下无法确认，也没有在真实设备上验证。这和“记住选择”不同：它不跨文档、不跨重启，也不是 Lithe 记的。因此每个端到端用例只对每种设备发一次请求。
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
- 新增页面里的快捷键时，在纯规则里加 `command(forKey:modifiers:)` 并补测试，再并入 `HTMLPreviewPageShortcut`，经 `HTMLPreviewWebViewSurface.performKeyEquivalent` 派发；页面的派发和应用键位监听器的放行规则读同一个识别器，所以新按键会同时被两边认得。回归测试要经 `NSApplication.sendEvent` 走真实监听器（见 `HTMLPreviewPageShortcutMonitorTests`）。不要另外注册全局或窗口级快捷键，它们会抢走编辑器的按键。
- 调整右键菜单时改 `HTMLPreviewContextMenu.customize`，用记录下来的 WebKit 菜单布局补 `HTMLPreviewContextMenuTests`，不要在测试里弹真实菜单。
- 新增读取 `WKWebView` 私有接口的代码时，先 `responds(to:)` 检查，缺失时退化为“功能不可用”而不是崩溃，并写进本笔记的私有接口清单（见“后果”）。

### 不要这样做

- 不要把 `allowFileAccessFromFileURLs` 之类的私有开关打开，用 `file://` 绕过同源限制；那会让任何 HTML 都能读取使用者的整个磁盘。
- 不要放宽 `HTMLPreviewAccessPolicy` 的隐藏文件/密钥拒绝，也不要去掉 `Referer`/主文档检查；它们是自定义协议提供同源服务时唯一的泄露防线。
- 不要在 `updateNSView` 里无条件给 `@Published` 属性赋值（即使值相同也会触发 SwiftUI 的“视图更新期间发布变更”警告）；控制器用 `clearLoadError()` 只在有变化时赋值。
- 不要把 `WKWebView` 直接作为 `NSViewRepresentable` 返回的视图，会破坏开发者工具停靠。
- 不要在应用键位监听器里单独列一份页面快捷键清单。清单只在 `HTMLPreviewPageShortcut` 维护，否则页面改了而监听器没改，按键又会被监听器吞掉。
- 不要只用直接调用 `performKeyEquivalent` 的测试证明页面快捷键可用：它绕过了先于页面看到按键的应用键位监听器。
- 不要在生产代码里打开 `mediaDevicesEnabled`、`mockCaptureDevicesEnabled` 这类私有开关来“让摄像头可用”：没有用途说明却去访问摄像头 / 麦克风，macOS 会结束进程。要启用功能，先补 Info.plist 的用途说明（需要维护者确认，并且必须和子进程隔离在同一个 PR 里，见“补用途说明之前必须知道的事”），不要绕过。
- 不要单独补 `NSCameraUsageDescription` / `NSMicrophoneUsageDescription`。例如只在 Info.plist 加两行，网页那道门写得再严，使用者点一次“Allow”之后，插件后端或终端里的 `ffmpeg` 也能不经任何弹窗打开摄像头。
- 不要用 `posix_spawn` 的 disclaim（脱钩责任进程）来隔离子进程的摄像头授权：它同时切断文件夹、完全磁盘访问等所有授权，项目在 Documents / Desktop / Downloads 下时 `git`、`java`、`node`、`mvn` 全部受影响。只禁设备要用沙盒 deny。
- 不要在 `WebMediaCapture.decide` 之外返回 `.grant`，也不要新建 `WKWebView` 而不回答它的摄像头 / 麦克风请求；没人回答时 WebKit 会弹它自己的提示，等于绕开了 Lithe 的确认。
- 不要让任何请求默认有权限：记住的偏好只能少问，不能让没有记录的请求通过；在有撤销入口之前不要开始记（见“记住选择”）。
- 不要在宿主里按插件名或插件 ID 给摄像头 / 麦克风写特例；所有插件页走同一条询问路径，插件名只用于提问文字。
- 不要为地理位置、剪贴板另做一套弹窗；它们使用 WebKit 自带的确认。
- 不要把端到端采集测试放到 `MockCaptureTests` 之外或改成并行：同一进程里两个页面同时采集会互相静音。

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
- 已知限制：查找条没有匹配计数（WebKit 不提供）；焦点在查找条输入框里时 ⌘F / ⌘G / ⇧⌘G 不由预览处理（输入框不在页面里，按应用键位走编辑器的查找命令）；导出的 PDF 是一页连续的长页，分页版本要走打印面板；摄像头 / 麦克风确认弹窗没有 Esc 映射；页面不在焦点时 `getUserMedia` 要等页面获得焦点；停掉最后一个设备后指示器还会停留约 3 秒；摄像头 / 麦克风在补上 Info.plist 用途说明之前休眠（`navigator.mediaDevices` 不存在），这是 2026-10-22 维护者确认的状态，补上之后才能在运行的应用里端到端验收，ad-hoc 签名下系统授权记录是否跨更新保留未实测；系统授权按整个 Lithe 记，Lithe 的子孙进程会沿责任进程规则继承它（macOS 27.2 上实测），所以用途说明必须带子进程隔离一起补，而沙盒 deny 能否真的拦住采集还没有在真实设备上验证；插件页没有应用内使用指示器，也没有“记住选择”；WebKit 可能为同一文档里已批准的设备复用授权（见“测试”一节的实测与推测），插件弹窗里“隐藏窗口前它可以一直使用该设备”的说明因此可能少说了“隐藏后重新显示，同一页面可能不再询问就重新开始使用”，真实设备上确认之后再校对文案（隐藏时和设备在页面离开窗口后启动时，采集都会被立即停掉，这一点不受影响）。
- 已知限制：`showDirectoryPicker` 等只有 Chromium 才有的 Web API 在 WebKit 中不存在，依赖它们的页面（例如 `assets/agent-notes-board.html`）需要在 Chromium 内核浏览器中使用，可用“在系统浏览器中打开”。
- Windows 端的 HTML 预览（iframe `srcDoc` 加 `<base>`）没有这些能力，已在功能矩阵中记录，另行跟进。
- 需要重新评估的触发条件：Apple 提供公开的 Web Inspector 接口；预览需要多标签；需要持久登录状态（当前使用非持久数据存储）。

## 验证

- `./scripts/test-macos.sh --filter HTMLPreview`
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter HTMLPreview`：带单测试计时运行。这些用例都跑真实 `WKWebView`，每项要在 1 秒告警线以内；模拟摄像头 / 麦克风那一组必须串行，原因见“摄像头和麦克风”。
- `./scripts/test-macos.sh --filter HTMLPreviewPageShortcut`：页面快捷键的放行规则，以及经 `NSApplication.sendEvent` 驱动真实监听器的回归测试（先确认页面认领每个按键，再装上监听器确认页面有焦点时按键没有被键位拿走，最后把焦点移到页面外确认同样的按键归键位）。
- `./scripts/test-macos.sh --filter AppLocalizationTests`
- `./scripts/verify-runtime-bundle-immutability.sh`
- `./scripts/verify-platform-feature-matrix.sh`
- `./scripts/verify-agent-notes.sh`
- 在运行的应用中打开 HTML：用工具栏后退/前进/刷新，输入本地路径和网址，点击锚点和相对链接，触发 `alert`/`confirm`/`prompt`，打开开发者工具并确认停靠在页面下方。
- 打开一个比预览区域宽且高的页面，确认右边缘和下边缘常驻滚动条，缩放到 500% 后滚动条仍是正常粗细，内容放得下的页面没有滚动条。
- 点击指向压缩包的链接弹出保存面板、`<a download>` 保存、在地址栏输入带 `index.html` 的目录路径或点击不带斜杠的目录链接（包括 iframe 里的）能正常加载其中的脚本、缩放时 iframe 里的滚动条保持同样粗细、在分屏里切换到另一个 HTML 标签时预览显示新文件（对应 `HTMLPreviewBrowserTests` 里的同名用例）。
- 在运行的应用中用 − / + / 百分比按钮和 ⌘+ / ⌘− / ⌘0 缩放，确认百分比与页面实际大小一致，跳转页面后缩放保持，分屏时在编辑器里按 ⌘+ 不会缩放预览。
- 在运行的应用中按 ⌘F 打开查找条，输入文字确认页面里的匹配项被选中；⌘G / ⇧⌘G 与 Return / ⇧Return 前进、后退并回绕；输入页面里没有的文字显示 “No matches”；Esc 收起后键盘回到页面；用默认键位，焦点在预览页面里按 ⌘F / ⌘G / ⇧⌘G 打开并驱动的是预览的查找条而不是编辑器的查找；分屏时焦点在编辑器里按 ⌘F / ⌘G / ⌘P 仍归编辑器。
- 在页面空白处、链接和图片上右键：没有“在新窗口中打开”，链接上有“拷贝链接”，空白处在“检查元素”上方有 Print… 和 Export as PDF…。⌘P 或 Print… 以窗口 sheet 打开系统打印面板；Export as PDF… 保存整页，文件名取页面标题。
- 补上 Info.plist 用途说明之后，在运行的应用中打开调用 `getUserMedia` 的页面：弹窗写明页面名称，默认按钮是 Don’t Allow；允许后地址栏右侧出现指示器，菜单里的静音 / 停止生效；再次打开同一页面仍会询问；页面里没有 `getDisplayMedia`。再用一个调用 `getUserMedia` 的插件页确认：弹窗写“插件“X”……”并带插件 ID，点 Don’t Allow 页面收到 `NotAllowedError`，允许后隐藏该工具窗口，系统菜单栏的绿点 / 橙点随之消失；再显示窗口并让页面第二次调用 `getUserMedia`，记录是否再次询问，并据此校对插件弹窗里的说明。当前构建没有这些用途说明，这一步还不能做；补用途说明时还要同时验证子进程隔离（在 Lithe 的内置终端和插件后端里尝试打开摄像头应当失败），验收标准见提议 Note `2026-10-22-child-process-media-isolation.md`。
- `./scripts/test-macos.sh --filter 'WebMedia|MockCapture|PluginMediaCapture|HTMLPreviewMediaCapture'`：门的决策、源码扫描、拒绝委托和两条端到端路径（HTML 预览、插件页）。

## 适用范围

- `macos/Sources/Lithe/Platform/MacOS/HTMLPreviewBrowser.swift`
- `macos/Sources/Lithe/Platform/MacOS/HTMLPreviewResources.swift`
- `macos/Sources/Lithe/Platform/MacOS/HTMLPreviewNavigation.swift`
- `macos/Sources/Lithe/Platform/MacOS/HTMLPreviewDialogs.swift`
- `macos/Sources/Lithe/Platform/MacOS/HTMLPreviewZoom.swift`（含页面快捷键识别器 `HTMLPreviewPageShortcut`）
- `macos/Sources/Lithe/Platform/MacOS/UI/MacShortcutDetector.swift`（应用键位监听器对预览页面快捷键让路）
- `macos/Sources/Lithe/Platform/MacOS/HTMLPreviewFind.swift`
- `macos/Sources/Lithe/Platform/MacOS/HTMLPreviewPrint.swift`
- `macos/Sources/Lithe/Platform/MacOS/HTMLPreviewMediaCapture.swift`
- `macos/Sources/Lithe/Platform/MacOS/WebMediaCapture.swift`（摄像头 / 麦克风的统一门和 Lithe 自有页面的拒绝委托）
- `macos/Sources/Lithe/Platform/MacOS/Plugins/Web/MacPluginWebPage.swift`（插件页的询问、隐藏即停止）
- `macos/Sources/Lithe/Platform/MacOS/MonacoDiffEditor.swift`、`MonacoWorkbenchEditor.swift`、`Updates/ReleaseNotesWebView.swift`（各一行 `uiDelegate`）
- `macos/Sources/Lithe/Platform/MacOS/HTMLPreviewScrollbars.swift`
- `macos/Sources/Lithe/Platform/MacOS/HTMLPreviewWebView.swift`
- `macos/Sources/Lithe/Platform/MacOS/LocalFileSchemeSupport.swift`
- `macos/Sources/Lithe/Platform/MacOS/MarkdownPreviewWebView.swift`（共用任务簿记与包含检查）
- `macos/Sources/Lithe/Views/Editor/HTMLPreviewView.swift`
