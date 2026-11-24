# Agent 笔记：插件网页浮层、失败传递与窗口图标

状态：已实现

## 先说结论

工作台的悬停说明、补全和导航必须显式声明在 Viva 的面板覆盖层，单靠把绘制调用放到正文之后无法盖住原生网页。后端函数失败经过网页适配器时，要保留 Core 已给出的错误码和插件业务错误码。工具窗口还必须读取已声明的包内图标，不能只识别内置图标名。这些修复都在宿主的通用呈现与数据转换边界，不依赖具体插件，也不新增协议。

## 问题

迁移到 Viva 的提交 `0faecba49`（#1799）在正文之后直接声明工作台浮层，但它们仍然属于正文的 0 层。原生 WebView 是系统视图，画布上同层的悬停面板可能被它遮住；菜单和对话框的声明顺序不能代替明确层级。

同一迁移中的网页回复只识别 `pluginweb.Failure`。后端函数返回的 `pluginservice.FunctionError` 及嵌入它的事件失败会进入兜底路径，被改写成 `plugin.web.invalidRequest`；页面失去 `pluginErrorCode`，只能显示笼统提示。

同一提交的工具窗口声明只解码 `icon.host`，包内图标路径被丢弃，因此合法的自定义图标仍显示通用工具窗口图标。宿主已有 `pluginicons` 负责包内 SVG 的只读加载，无需再做一份解码器。

## 决策

- 在 `workbench.root` 把工作台浮层放入 `ui.Overlay` 的 `LayerPaneChrome`，即 Viva 用于正文上方控件的覆盖层。框架据此同时处理原生视图遮罩、命中区域和绘制；框架菜单、对话框仍使用自己的更高层。
- `FunctionError` 提供结构化转换，`Page.answer` 通过接口获取原有 `code`、`message`、`pluginErrorCode`，再交给 Core 包装回复。桌面端不解释插件业务错误，不分配新码，也不另记一条相同失败日志。
- 工具窗口保留包内图标声明，在插件重载的后台工作中读入共享图标缓存。工具栏、隐藏入口列表和拖动预览按当前主题读取缓存，模板图标沿用控件着色，原色图标保留填充色。资源缺失或不受支持时复用现有 `plugin_icon` 降级日志，每个资源只记一次；不在绘制时读文件，不写磁盘缓存。
- 正确做法：新增悬停或导航内容继续使用工作台统一浮层入口；插件根据自己收到的业务错误选择本地提示。
- 不要这样做：给某个网页单独加窗口置底代码、用 CSS 层级操作窗口外的原生视图，或根据插件 ID 在宿主转换错误。

## 考虑过的备选方案

仅调整正文与浮层声明顺序不能改变原生视图的层级。修改 Viva 原生窗口排序会重复框架已有遮罩能力，也会影响其他原生视图，因此本次只修正调用方的覆盖层声明。

把后端错误文本拼进通用错误消息虽然能看到一部分原因，却仍然丢失机器可读的分类；让网页或宿主按文本匹配又会依赖翻译。保留契约现有字段即可，不需要新 API。

把某个品牌图标写入宿主会让插件失去独立维护能力；另建 SVG 绘制器又会重复现有包路径与资源预算保护。因此只接线既有声明和图标适配器，不扩大格式支持。

## 后果

宿主中的网页内容遵守与其他正文相同的浮层关系，插件无需配合；页面也能继续使用后端提供的受控业务提示。代价是无头画布只能证明层级声明与错误回复，不能证明系统 WebView 的真实遮挡、指针与焦点行为，仍需要目标平台验收。

## 验证

用户要求停止验证之前，定向回归已执行：`TestPointerHoverPaintsAboveTheNativeContentLayer` 在修复前报告悬停层 0 不高于正文层 0，修复后通过；`TestPagePreservesBackendFunctionFailure` 修复前丢失插件业务码，修复后通过。`TestVisualPointerHover` 采集了浅色、深色、中英文的悬停和导航画面，但无头环境没有原生网页引擎。

用户随后明确要求自行验收，此后的图标接线、文档、矩阵和提交收尾没有重新运行测试或检查。图标声明保留与明暗主题、模板着色用例已编写，尚未执行。macOS 原生 WebView 叠层与 Windows 验收均保持 pending。后续入口为 `scripts/desktop/desktop-go.sh test -race -count=1 ./internal/pluginweb -run TestPagePreservesBackendFunctionFailure`、工作台同名层级回归，以及 `./internal/pluginservice -run TestInstalledToolWindowKeepsPackageIconDeclaration`、`./internal/workbench -run TestPluginToolWindowUsesPackageIconAcrossThemes`；原生验收步骤见功能矩阵。

## 适用范围

- `desktop/internal/workbench/root.go`
- `desktop/internal/workbench/pluginsemantics_hover_test.go`
- `desktop/internal/workbench/pluginsemantics_hover_visual_test.go`
- `desktop/internal/pluginservice/backendhost.go`
- `desktop/internal/pluginservice/toolwindows.go`
- `desktop/internal/pluginservice/installed_snapshot_test.go`
- `desktop/internal/pluginweb/page.go`
- `desktop/internal/pluginweb/page_test.go`
- `desktop/internal/workbench/plugintools.go`
- `desktop/internal/workbench/plugintools_test.go`
- `desktop/internal/workbench/plugins.go`
- `desktop/internal/workbench/chrome_view.go`
- `desktop/internal/workbench/drag.go`
- [插件网页界面的边界](../architecture/2026-10-18-plugin-web-content-in-host-windows.md)
