# Agent 笔记：插件可以自带网页界面，窗口外壳仍归宿主

状态：提议中

## 先说结论

插件可以在自己的工具窗口里放一个包内 HTML 页面（Web 内容，用宿主的 WebView 渲染），但这只是可选项：不写界面的插件仍由宿主按声明画窗口，构建系统用的就是宿主照抄 Maven 窗口做出来的通用视图。不管用哪种内容，停靠、标题、活动栏、顺序、显隐、布局和生命周期都只能由宿主管理。Core 已经能校验这份契约（`ui` 能力版本 2、`ui.toolWindows[].web`、`ui.web` 权限），两端宿主都还没有实现，所以 Core 目前在 macOS 上拒绝 `ui` 2 插件。

## 问题

[公共扩展契约提案](2026-10-13-public-extension-contract-and-provider-api.md)原本规定第三方界面只能用版本化 JSON 组件树（宿主用原生控件渲染的界面声明），不加载插件的 HTML。这样宿主最好管，但组件树要等 Issue #40 做完才有。在那之前，想要定制界面的社区插件只有纯文本窗口可用。

2026-10-18 用户调整了方向：允许插件自己写界面，但窗口外壳必须走框架，否则窗口没法统一管理。同时明确这不是强制要求，Maven 这类已有界面的功能照搬原来的界面和注入方式。

## 提案

### 两条路并存

- **默认：宿主绘制。** 插件只写声明。文本窗口照旧；构建系统由宿主为每个启用的构建系统画一个 IDEA 风格的窗口，画法照抄现有 `MavenView`，具体放什么由声明字段决定（见[构建系统插件契约](../../implemented/architecture/2026-10-17-build-system-plugin-contract.md)第 11 节）。
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
- 凡是会启动进程的请求（刷新模型、跑任务、跑测试），都要经过与宿主自身按钮相同的信任和同意流程，输出进入宿主的 Build Output。页面拿不到 argv，也不能自己拼命令。
- 选项写入沿用 `build.resolveOptions` 和宿主的选项存储，因此构建选项转交给 JDT 的方式与宿主自己的选项列表一致。

### 正确做法

- 想做依赖图可视化的插件：声明一个 `web` 窗口，页面用 `build.dependencies` 取树，自己画图；窗口位置和开关交给宿主。
- Maven、Gradle 插件：不写页面，只写 `category`、`presentation` 等声明，由宿主照 Maven 窗口的样子绘制。

### 不要这样做

- 页面里自己实现停靠、标签栏或窗口开关，或者要求宿主按插件 ID 打开特殊窗口。
- 为了让页面联网而放宽 CSP；需要网络的数据应该由构建命令或 Provider 获取，再经 Core 解码。
- 把宿主的 Swift 视图移进插件包，或者为一个插件在宿主里写 `if pluginID == …`。

## 考虑过的备选方案

### 只做 JSON 组件树

最有吸引力的理由：原生控件，宿主完全掌握外观与无障碍。暂不作为唯一途径，因为它要等 Issue #40，范围大，复杂可视化（图、表格编辑器）也难以用有限组件表达。组件树仍是原生界面的方向，两者并存。

### 允许第三方 Swift Bundle

最有吸引力的理由：与内置视图同样原生。不采用：没有稳定 ABI，签名、隔离和 Windows 都无法覆盖。

### 让页面自己管窗口

最有吸引力的理由：插件作者自由度最大。不采用：用户布局、窗口菜单、禁用插件时的清理都依赖宿主知道每个窗口的身份和生命周期，外壳一旦交给插件就没法统一管理。

## 验收标准

- macOS 宿主用 WKWebView 实现：只提供包内文件、强制 CSP、使用非持久数据存储、注入桥接对象，并在 `hostCapabilities` 里声明 `ui: [1, 2]`。
- `fixtures/web-panel.plugin.json` 能装上并显示；禁用、更新、卸载插件时页面被销毁，窗口从布局中移除，重新启用后恢复位置。
- 页面越界调用、未知方法和错误参数分别返回 `plugin.web.forbidden`、`plugin.web.unknownMethod`、`plugin.web.invalidRequest`。
- `scripts/verify-runtime-bundle-immutability.sh` 在打开过网页窗口后仍然通过。
- Windows 用 Tauri/WebView2 实现同一份桥接契约之前，不声明 `ui: [2]`。

## 风险

- 第三方脚本是新的执行面。CSP 和桥接白名单是主要防线，所以桥接方法要逐个审查，不能变成任意命令代理。
- 两端的 WebView 行为不同。共享契约只规定桥接和加载规则，不规定渲染细节。
- 页面会被频繁创建、销毁，插件作者需要自己从状态恢复界面。README 和示例插件要把这一点写清楚。

## 适用范围

- `shared/contracts/plugins/v1/`
- `rust/lithe-core/src/plugins/declarative.rs`
- `rust/lithe-core/src/plugins/capabilities.rs`
- `macos/Sources/Lithe/Views/Workbench/`
- `windows/`
