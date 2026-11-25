# Agent 笔记：插件可以自带网页界面，窗口外壳仍归宿主

状态：已实现

## 先说结论

插件界面优先使用宿主的原生控件，Maven、Gradle 的任务树、工具栏和选项都由宿主按插件声明原生绘制。允许插件在需要时使用包内 HTML 页面（Web 内容，用宿主的 WebView 渲染），只是保留一种可选方式，不要求插件网页化，也不是原生构建插件的前置依赖。不管用哪种内容，停靠、标题、活动栏、顺序、显隐、布局和生命周期都只能由宿主管理。Core 校验这份契约（`ui` 能力版本 2、`ui.toolWindows[].web`、`ui.web` 权限）。2026-11-11 起 Viva 桌面端（macOS、Windows、Linux 共用一套 Go 代码）声明 `ui: [1, 2]`：页面的加载和桥接规则在 Rust Core 的 `plugins.web.*` 命令里，桌面端只负责 Web 视图和 I/O。

## 问题

[公共扩展契约提案](../../proposed/architecture/2026-10-13-public-extension-contract-and-provider-api.md)原本规定第三方界面只能用版本化 JSON 组件树（宿主用原生控件渲染的界面声明），不加载插件的 HTML。这样宿主最好管，但组件树要等 Issue #40 做完才有。在那之前，想要定制界面的社区插件只有纯文本窗口可用。

2026-10-18 用户调整了方向：允许插件自己写界面，但窗口外壳必须走框架，否则窗口没法统一管理。同时明确这不是强制要求，Maven 这类已有界面的功能照搬原来的界面和注入方式。

## 决策

### 两条路并存

- **默认：宿主绘制。** 插件只写声明。文本窗口照旧；构建系统由宿主为每个启用的构建系统画一个 IDEA 风格的窗口，画法照抄现有 `MavenView`，具体放什么由声明字段决定（见[构建系统插件契约](2026-10-17-build-system-plugin-contract.md)第 11 节）。
- **可选：插件自带页面。** 窗口声明 `web.entry`（包内 `.html` 文件），而不是 `text`。需要 `pluginAPIVersion` 3、`requires.ui: 2` 和 `ui.web` 权限；安装审查会列出这项权限。只用文本窗口却声明 `ui` 2 的清单会被拒绝，免得它在只支持 `ui` 1 的宿主上无端消失。

### 外壳与内容的分工

宿主负责窗口本身：初始停靠位置、标题、图标、顺序来自声明，用户保存的布局优先。页面只负责填满窗口正文，不能打开、移动、改尺寸或改标题。

宿主加载页面时：

- 只提供已安装插件包里的文件，只读，使用插件私有的源（origin）。
- 用内容安全策略（CSP，浏览器拦截哪些资源的规则）禁止联网、远程资源、iframe、内联脚本和 `eval`；禁止跳出插件包、弹窗和下载。
- 网页存储不持久，状态通过桥接对象保存在宿主里。这样运行时不会往插件包或 app bundle 写东西，符合运行时只读规则。
- 窗口第一次显示时创建页面，隐藏时可以销毁，禁用、更新或卸载插件时一定销毁。页面要能从保存的状态恢复。
- 摄像头和麦克风默认没有权限：页面调用 `getUserMedia` 时由宿主弹窗确认，问题写明这是插件并附插件 ID，每个到达宿主的请求都重新询问，宿主什么也不记，只有明确点“Allow”才授权。只响应本插件的主框架；页面不在窗口里（窗口被隐藏而页面还保留着）时直接拒绝，页面使用设备期间窗口被隐藏就结束采集，点“Allow”之后页面才被隐藏时才启动的设备也会被立即停掉。统一的门和实测见[HTML 预览笔记](../feature/2026-10-22-html-preview-embedded-browser.md)的“摄像头和麦克风”。

### 桥接对象

宿主在页面脚本执行前注入 `window.lithe`（当前第 2 版，`lithe.version` 给出版本号）：`context`、`request(method, params)` 和 `on(event, listener)`。方法和事件的全集写在 `Lithe-core-rust/shared/plugins/contract/v1/README.md` 的 “Web content (`ui` 2)” 一节，这里只记录边界：

- 页面只能操作本插件声明的构建系统和当前工作区，越界返回 `plugin.web.forbidden`。
- 凡是会启动进程的请求（刷新模型、跑任务、跑测试），都要经过与宿主自身按钮相同的信任和同意流程，输出进入宿主的 Build Output。页面不能提交或修改进程 argv，也不能自己拼命令；模型保留 Core 返回的声明运行项 `run` 和任务 `category` 供展示，执行入口仍只有宿主校验过的任务与测试。
- 选项写入沿用 `build.resolveOptions` 和宿主的选项存储，因此构建选项转交给 JDT 的方式与宿主自己的选项列表一致。
- 第 2 版只多了文件对话框 `dialog.openFile` / `dialog.saveFile`，供数据库这类带后端的插件导入导出文件。对话框由宿主弹出，说明里写明是哪个插件在请求；同一页面同时只能开一个；页面只拿到用户选中的绝对路径，真正的读写交给插件后端，页面本身仍然碰不到文件。页面在对话框打开期间被关闭，就拿不到选择结果。旧宿主没有这两个方法（返回 `plugin.web.unknownMethod`），所以页面先看 `lithe.version` 再决定是否提供导入导出。之所以加桥接方法而不是让后端自己弹窗，是因为后端是无界面的子进程，弹窗必须由宿主窗口负责，也只有宿主能把插件身份写进对话框，防止页面冒充 Lithe。

### 正确做法

- 想做依赖图可视化的插件：声明一个 `web` 窗口，页面用 `build.dependencies` 取树，自己画图；窗口位置和开关交给宿主。
- Maven、Gradle 插件：不写页面，只写 `category`、`presentation` 等声明，由宿主照 Maven 窗口的样子绘制。

### 不要这样做

- 页面里自己实现停靠、标签栏或窗口开关，或者要求宿主按插件 ID 打开特殊窗口。
- 为了让页面联网而放宽 CSP；需要网络的数据应该由构建命令或 Provider 获取，再经 Core 解码。
- 把宿主的原生视图移进插件包，或者为一个插件在宿主里写 `if pluginID == …`。
- 让某个插件免于摄像头 / 麦克风确认，或者绕过 `WebMediaCapture.decide` 直接授权；插件名只用在提问文字里，不影响是否询问。

### Viva 的落点

规则放在 Core，I/O 放在桌面端。这是 develop-lithe“可共享逻辑进 Core”的要求：三个平台共用同一份判断，桌面端不再各写一套。

- **Core（`rust/crates/plugin-web-content/src/lib.rs`）**：`plugins.web.open` 为一个已声明的 web 窗口登记页面，返回私有源 URL 和限额；`resource` 判断一个请求路径能不能读、读包里的哪几段路径（拒绝 `..`、空段、编码分隔符和保留的 `.lithe-host/`）；`document` 在 HTML 文档最前面注入 CSP meta 和桥接脚本；`request` 校验页面发来的每条消息，要么直接给出拒绝回复，要么交回一个已规范化的动作；`reply` 和 `event` 把结果、进度和主题变化封装成发给页面的消息。调用 ID 不可复用、同时最多 16 个调用、一次只开一个对话框，这些计数也都在 Core 里。
- **`desktop/internal/pluginweb`**：一个 `Page` 对应一个页面。它按 Core 给出的路径段逐级 `Lstat` 读取包文件，不跟随任何符号链接，并且限制大小；把 Core 交回的动作交给 `Host` 执行（状态读写、后端调用和进度、文件对话框、在编辑器里打开文件），再把 Core 封装好的回复投递给页面。等待、读写文件和弹对话框都在窗口线程之外进行。页面关闭时取消它的全部调用，之后的结果不再投递。
- **`desktop/internal/workbench`**：插件工具窗口加进每个窗口自己的 chrome 目录，由 Core 统一排列。停用插件期间，保存的布局仍保留它的位置，重新启用后回到原处。网页窗口用 `app.WebHost` 打开 Web 视图，并用 `NativeView` 填满窗口正文。一帧没有声明某个页面，这个页面就在 `endPaint` 里关闭。所以隐藏或移动窗口、关闭项目、停用或更新插件，都走同一条关闭路径。
- **同窗口的项目标签（2026-11-24）**：原生窗口只有一个网页宿主（`app.WebHost`，负责为该窗口创建网页视图），它和就绪状态一起由 `windowSessions` 持有；后续项目标签使用已经绑定到窗口的同一宿主，关闭首个项目不结束宿主。每个项目仍独立持有 `pluginPages`、网页视图、页面桥接与编辑区预览；不能把页面对象或当前选中内容放进窗口级状态。切换项目显示该项目自己的页面，`ui.getState/setState` 仍按工作区保存。原因及回归见[项目标签网页宿主生命周期](../bug-fix/2026-11-24-project-tabs-web-host-lifetime.md)。
- **覆盖层与错误传递（2026-11-24）**：原生网页属于窗口的正文层。工作台自己的补全、悬停说明和导航弹层通过 `ui.Overlay` 明确放进 `LayerPaneChrome`（Viva 的面板覆盖层），由框架同时计算原生视图遮罩和点击区域；框架菜单、对话框仍使用更高层。后端函数失败经过 `pluginservice` 与 `pluginweb` 时保留原有 `code`、`message`、`pluginErrorCode`，桌面适配器只转换数据，不重新分配业务错误码。
- **状态（`pluginservice.SetPageState`）**：写到每用户插件根目录下的 `.state/<plugin>/pages/workspaces/<工作区键>/<窗口摘要>.json`，与插件后端的工作区状态放在一起，按窗口和工作区隔离，写入时先写临时文件再改名。它不在插件包或应用 bundle 里，所以不改变签名或增量更新的基线；`plugin-web-state` 仍然禁止跨工作树复用。

Viva 的 Web 视图目前有四处达不到契约，已记录为上游缺口，补齐前按下面的方式处理：

- 自定义 scheme 不能设置响应头，所以 CSP 以 meta 标签注入到文档最前面。不要因为页面里多了这行 meta 就把它删掉。
- 不能在导航开始前拦截，只能在导航提交后发现页面离开了本插件源，再把它送回入口。
- 数据存储是持久的，与契约“网页存储不持久”不符；状态仍然只走桥接。
- 包资源回调在窗口线程上同步执行，所以读包文件要有大小上限，Core 判断要设本地期限。

另外，本宿主不向页面提供构建系统（`build.*` 返回 `plugin.web.unknownMethod`），也还不支持摄像头和麦克风。2026-11-24 起工具窗口读取声明的包内 SVG 图标：后台重载时复用 `pluginicons` 的只读加载和内存缓存，工具栏、隐藏入口列表和拖动预览在绘制时选择主题变体。缺失、被拒绝或当前绘制器不支持的资源记录一次降级，继续显示通用图标；PNG 仍不在当前矢量图标绘制器的支持范围内。

### 启动进程前的确认

宿主自己的构建按钮由用户亲手点击，没有额外确认；页面发起的请求不一定来自用户操作，所以宿主在第一次启动构建工具（非 static 的模型加载、任务、测试、依赖）前弹窗确认。同一插件在同一工作区本次会话只问一次；插件被禁用、更新后重新询问。页面提供的 `userArguments` 每次都单独确认并原样展示，而且只有声明了 `requiresUserArguments` 的任务才接受。

## 考虑过的备选方案

### 只做 JSON 组件树

最有吸引力的理由：原生控件，宿主完全掌握外观与无障碍。暂不作为唯一途径，因为它要等 Issue #40，范围大，复杂可视化（图、表格编辑器）也难以用有限组件表达。组件树仍是原生界面的方向，两者并存。

### 允许第三方 Swift Bundle

最有吸引力的理由：与内置视图同样原生。不采用：没有稳定 ABI，签名、隔离和 Windows 都无法覆盖。

### 让页面自己管窗口

最有吸引力的理由：插件作者自由度最大。不采用：用户布局、窗口菜单、禁用插件时的清理都依赖宿主知道每个窗口的身份和生命周期，外壳一旦交给插件就没法统一管理。

## 后果

- 收益：插件作者可以做宿主声明画不出的界面（依赖图、表格编辑器），而窗口布局、菜单和清理仍由宿主统一管理。
- 收益：页面只能经过白名单桥接接触构建系统，所有进程仍由宿主按 Core 计划启动，输出进入 Build Output。
- 代价：第三方脚本是新的执行面；每新增一个桥接方法都要逐个审查，不能做成通用命令代理。
- 代价：页面会被销毁重建，插件作者必须从 `ui.getState` 恢复界面。
- 重新评估：Windows 实现 WebView2 宿主时，要用同一组越界、未知方法、错误参数用例验证两端一致。

## 风险与未决

- 第三方脚本是新的执行面。CSP 和桥接白名单是主要防线，所以桥接方法要逐个审查，不能变成任意命令代理。
- 两端的 WebView 行为不同。共享契约只规定桥接和加载规则，不规定渲染细节。
- 页面会被频繁创建、销毁，插件作者需要自己从状态恢复界面。README 和示例插件要把这一点写清楚。
- 契约里有几处宿主先自行取值、待共享契约确认：实例 `state` 取 `notLoaded`、`loading`、`loaded`、`failed`；`error` 为 `{ message }`；`options` 为用户已存且 Core 接受的值（按选项 ID）；依赖加载失败报 `plugin.build.unavailable`。

## 验证

- Viva：`scripts/desktop/desktop-go.sh test -race -count=1 ./internal/pluginweb` 用真实 Core 和共享 web-panel 夹具，验证文档注入、包外路径和链接被拒、大小上限、状态往返、调用结果与只属于本调用的进度、页面取消和关闭页面取消调用、调用 ID 不可复用、对话框、越界的 `workspace.openFile`、离开插件源的导航被送回入口、主题事件。`./internal/pluginservice -run TestPage` 覆盖进度路由和按窗口、工作区隔离的状态；`./internal/workbench -run TestPluginToolWindows` 覆盖文本窗口内容、网页窗口在引擎未就绪和打不开时的提示、隐藏即关闭页面、停用期间保存的布局仍保留窗口位置。Core 侧有 `web_content_tests.rs` 9 项。无界面驱动没有 Web 引擎，真实页面显示、CSP 拦截和主题切换的产品验收保持 pending。
- `TestProjectTabsShareWindowWebHost` 覆盖后续标签、首个项目关闭后再开标签、不同窗口的宿主隔离；`TestPluginToolWindowsKeepWebPagesPerProjectTab` 覆盖就绪回调的两种时序，以及每个项目的页面对象、桥接状态和显隐生命周期隔离。`TestVisualPluginWebProjectTabs` 采集第二项目的加载与无引擎错误表面，不能替代原生网页引擎验收。
- `./scripts/desktop/verify/verify-runtime-bundle-immutability.sh`：确认没有新增写入 bundle 的路径。
- `./scripts/agent-notes/verify-agent-notes.sh`：Note 格式与路径。

2026-11-24 的层级修复在用户停止验证前已运行定向回归：修复前悬停弹层与正文同为 0 层，修复后层级断言通过；`TestVisualPointerHover` 生成浅色、深色和中英文的悬停与导航截图。网页错误回归 `TestPagePreservesBackendFunctionFailure` 在修复前丢失 `pluginErrorCode`，修复后保留三个结构化字段。组件结果不代替原生 WebView 遮挡验收。用户随后要求自行验收，此后的图标接线、矩阵、Note 和提交收尾没有再运行验证，原生 macOS 与 Windows 状态仍为 pending。图标用例 `TestInstalledToolWindowKeepsPackageIconDeclaration` 与 `TestPluginToolWindowUsesPackageIconAcrossThemes` 已编写，尚未执行。

## 适用范围

- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/shared/plugins/contract/v1/`
- Lithe-core-rust：`rust/crates/plugin-web-content/src/lib.rs`（Lithe-IDEA/Lithe-core-rust#9）
- `desktop/internal/pluginweb/`
- `desktop/internal/workbench/pluginpages.go`、`desktop/internal/workbench/plugintools.go`
- `desktop/internal/pluginservice/pages.go`、`desktop/internal/pluginservice/toolwindows.go`
- Lithe-core-rust 锁定修订：[rust/lithe-core/src/plugins/declarative.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/plugins/declarative.rs)
- Lithe-core-rust 锁定修订：[rust/lithe-core/src/plugins/capabilities.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/plugins/capabilities.rs)
