# Agent 笔记：插件可以自带网页界面，窗口外壳仍归宿主

状态：已实现

## 先说结论

插件界面优先使用宿主的 SwiftUI 原生控件，Maven、Gradle 的任务树、工具栏和选项都由宿主按插件声明原生绘制。允许插件在需要时使用包内 HTML 页面（Web 内容，用宿主的 WebView 渲染），只是保留一种可选方式，不要求插件网页化，也不是原生构建插件的前置依赖。不管用哪种内容，停靠、标题、活动栏、顺序、显隐、布局和生命周期都只能由宿主管理。Core 校验这份契约（`ui` 能力版本 2、`ui.toolWindows[].web`、`ui.web` 权限）。macOS 已用 WKWebView 实现并声明 `ui: [1, 2]`；Windows 还没有实现，继续只声明 `ui: [1]`，Core 会在那里拒绝 `ui` 2 插件。

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

### 桥接对象

宿主在页面脚本执行前注入 `window.lithe`（第 1 版）：`context`、`request(method, params)` 和 `on(event, listener)`。方法和事件的全集写在 `shared/contracts/plugins/v1/README.md` 的 “Web content (`ui` 2)” 一节，这里只记录边界：

- 页面只能操作本插件声明的构建系统和当前工作区，越界返回 `plugin.web.forbidden`。
- 凡是会启动进程的请求（刷新模型、跑任务、跑测试），都要经过与宿主自身按钮相同的信任和同意流程，输出进入宿主的 Build Output。页面不能提交或修改进程 argv，也不能自己拼命令；模型保留 Core 返回的声明运行项 `run` 和任务 `category` 供展示，执行入口仍只有宿主校验过的任务与测试。
- 选项写入沿用 `build.resolveOptions` 和宿主的选项存储，因此构建选项转交给 JDT 的方式与宿主自己的选项列表一致。

### 正确做法

- 想做依赖图可视化的插件：声明一个 `web` 窗口，页面用 `build.dependencies` 取树，自己画图；窗口位置和开关交给宿主。
- Maven、Gradle 插件：不写页面，只写 `category`、`presentation` 等声明，由宿主照 Maven 窗口的样子绘制。

### 不要这样做

- 页面里自己实现停靠、标签栏或窗口开关，或者要求宿主按插件 ID 打开特殊窗口。
- 为了让页面联网而放宽 CSP；需要网络的数据应该由构建命令或 Provider 获取，再经 Core 解码。
- 把宿主的 Swift 视图移进插件包，或者为一个插件在宿主里写 `if pluginID == …`。

### macOS 的落点

代码按分层放置，任何一层都不按插件 ID 写分支：

- `Application/Features/PluginWebBridge.swift`：平台无关的桥接。逐个方法校验参数，未知字段算 `plugin.web.invalidRequest`；实例必须属于页面自己的插件和其声明的构建系统，路径必须在打开页面时的工作区内（符号链接逃逸也算越界）；工作区换了或页面关了一律 `plugin.web.forbidden`。每次异步激活、检测或加载依赖后都重新检查工作区；等待受构建服务的 15 分钟模型预算约束，页面关闭或请求取消会释放等待。项目、目标和模型任务只按 `name`、`path` 在已加载的模型里找，再用模型里的值重建选择，所以页面塞进来的 `properties` 不会进入 argv。
- `Application/Features/PluginWebPages.swift`：每个项目窗口一份页面登记表（按工具窗口 ID）。第一次显示时创建，隐藏时只把视图摘下、页面保留；每个容器把登记表弱引用登记到进程共享的 `PluginWebPageLifecycle`；插件管理器在停用、替换包、更新、回滚或卸载之前同步通知所有项目窗口，工作区关闭也释放页面。关闭不依赖窗口当前可见，因此隐藏页面不会继续从被替换的包读取资源。安装和回滚在候选包、签名、入口与版本校验后、实际修改安装记录或包字节前通知；校验失败保留旧页面，开始修改后发生 I/O 失败则保持关闭，防止恢复不完整的包重新加载。登记表同时禁止旧视图在停用中重建页面；关闭工作区保留停用和更新记录，成功重新启用原包才解除停用记录；更新、回滚和卸载使用独立的“直到进程重启”记录，防止另一项目窗口持有的旧管理器误解除。后注册的窗口继承当前记录，弱引用不会让关闭的项目窗口继续存活。
- 构建服务的任务和测试启动方法返回本次创建的运行 ID，未启动返回空值。页面只登记这个 ID，不能通过读取共享的“当前运行”认领宿主或其他页面的任务；`build.cancel` 也只能停止本页实际启动且仍在运行的任务。
- `Platform/MacOS/Plugins/Web/`：`lithe-plugin://<pluginID>/<path>` 自定义 scheme 只读取已安装包内的普通文件（拒绝空段、`.`、`..`、编码分隔符、符号链接和越出包根的路径，单文件不超过 16 MiB），每个响应都带 CSP、`nosniff` 和 `no-store`；WKWebView 使用 `nonPersistent()` 数据存储，用户脚本在文档开始时定义冻结的 `window.lithe`，只接受主框架、本插件源的消息；跳出本插件源的导航、弹窗、无法显示的 MIME（会变成下载）一律取消。只有本地开发包可以打开 Web Inspector。
- `ui.setState` 由 `MacPluginWebStateStore` 写到平台 adapter 解析的 `Application Support/Lithe/PluginState/<plugin>/web-state/<window>/<工作区摘要>.json`，单窗口/工作区上限 64 KiB，随插件状态目录卸载清理。它是用户可变状态，没有可复用的构建身份；`worktree-resources.json` 的 `plugin-web-state` 明确禁止任何阶段跨工作树复制。包内网页和脚本始终只读，不改变签名或 Sparkle delta 的源基线。
- 安装校验（`MacPluginPackageStore.validatePackage`）要求每个 `web.entry` 是包内存在的 `.html` 普通文件。

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
- 契约里有几处 macOS 先自行取值、待共享契约确认：实例 `state` 取 `notLoaded`、`loading`、`loaded`、`failed`；`error` 为 `{ message }`；`options` 为用户已存且 Core 接受的值（按选项 ID）；依赖加载失败报 `plugin.build.unavailable`；`--lithe-*` 变量名见 `MacPluginWebTheme`。

## 验证

- 固定 Swift 6.3.3，配合 `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`，`LITHE_SWIFT_BUILD_JOBS=4`、`CARGO_BUILD_JOBS=4`、`LITHE_TEST_WINDOW_MODE=isolated`，运行 `test-stability-macos.sh --suite-timeout-seconds 1200 -- --filter 'PluginWeb|PluginManagerTests|WorkbenchContributionHostTests|BuildSystemServiceTests|PluginPackageStoreTests|PluginMarketplace|Localiz'`。2026-10-18 最终增量回归 141 项、18 个 suite 全部通过，用例执行总计 2.759 秒，报告在 `.artifacts/test-stability/macos-swift.json` 与 `index.html`；首轮冷启动真实 WKWebView 用例 4.533 秒也通过。新增生命周期和模型字段修补均已纳入最终回归。
- 整合树新增同进程双项目登记表、后注册窗口、旧管理器启用不能撤销包替换、弱引用释放与安装/回滚/卸载独立回调回归。2026-10-18 固定工具链的整合回归 261 项、21 个 suite 全部通过，测试执行 19.016 秒；报告为 `.artifacts/test-stability/plugin-integration-final.{json,html,junit.xml,log}`。三项跨项目生命周期用例各 1 毫秒，包修改独立通知 17 毫秒，真实 WKWebView 643 毫秒。上述 141 项记录只证明广播修补前的版本。
- 真实 WKWebView 回归覆盖包内外部脚本执行、内联脚本与外网请求被 CSP 拒绝、桥接错误码、冻结对象、主题事件、nonPersistent 数据存储，以及加载、切换主题、关闭前后包文件字节和清单不变。
- `verify-runtime-bundle-immutability.sh`、`verify-service-boundaries.sh`、`verify-windows-boundaries.sh`、`verify-shared-contracts.sh`、`verify-rust-core-comments.sh`、`verify-agent-notes.sh` 与矩阵两项 gate 已通过；`node scripts/test-reuse-worktree-resources.mjs` 16 项通过。
- 测试稳定性 added-lines gate 通过；`--all` 扫描仍报告仓库既有 26 处真实等待，不为本任务添加例外或扩张修复范围。
- 本任务只运行隔离测试，没有启动真实 Lithe 产品实例。产品窗口安装、隐藏、停用再启用及最终外观验收保持 `pending`；Windows WebView2 尚未实现，没有执行 Windows 平台构建或产品测试。

## 适用范围

- `shared/contracts/plugins/v1/`
- `rust/lithe-core/src/plugins/declarative.rs`
- `rust/lithe-core/src/plugins/capabilities.rs`
- `macos/Sources/Lithe/Views/Workbench/`
- `macos/Sources/Lithe/Application/Features/PluginWebBridge.swift`
- `macos/Sources/Lithe/Platform/MacOS/Plugins/Web/`
- `windows/`
