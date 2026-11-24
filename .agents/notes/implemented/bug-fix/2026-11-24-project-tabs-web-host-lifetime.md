# Agent 笔记：项目标签共享窗口网页宿主，页面状态各自保留

状态：已实现

## 先说结论

同一原生窗口打开第二个项目后，插件网页不能一直停在“正在打开…”。窗口只创建一个网页宿主（`app.WebHost`，用来为这个窗口创建网页视图），就绪状态跟随窗口存活。每个项目各自创建和保留页面、桥接状态和编辑区预览，切换项目不能把另一项目的显示状态带过来。

## 问题

Viva 迁移提交 `0faecba49`（#1799；问题单 #2394）让一个窗口保存多个项目工作台，却把网页宿主和 `webReady` 放进每个项目的 `App`。真实窗口只绑定第一个工作台的配置，因此只有它能收到就绪回调。后续项目一直等待自己的未绑定宿主，插件页面停在加载态，编辑区网页预览也无法启用。

## 决策

- `windowSessions` 持有网页宿主和就绪标记，在创建时安装一次就绪回调；新项目直接使用窗口已经就绪的能力。这个适配器属于原生窗口接线，不改变 Core 的页面规则、插件契约或权限。
- 项目自己的 `App` 继续持有 `pluginPages` 和 `previews`。每次打开页面都创建独立网页视图，桥接绑定发起项目；`ui.getState/setState` 继续使用工作区键。账号凭据或业务缓存能否共享由插件决定，不据此共享页面。
- 项目关闭只释放自己的页面；关闭首个项目后仍能在其他项目和新开标签中创建网页。不同原生窗口各自持有宿主及就绪状态。

正确做法：项目甲和乙通过同一个宿主创建各自的页面，分别恢复甲、乙的筛选与选择状态。不要这样做：让两个项目指向同一个页面对象，或给每个项目复制一个没有绑定窗口的宿主。

## 考虑过的备选方案

- 只把后续项目的 `webReady` 设为 true：其宿主仍未绑定到原生窗口，页面会从无限等待变成打不开，拒绝。
- 直接共用第一个项目的网页页面：会把当前内容、滚动、桥接请求和项目生命周期混在一起，拒绝。
- 每个项目创建独立原生窗口或额外网页宿主：资源生命周期不符合“此窗口打开”的交互；Viva 的宿主本来就按原生窗口绑定，无需新增窗口。

## 后果

第二个及后续项目能够在窗口就绪后尝试打开网页，首个项目关闭也不影响其余项目。代价是项目级代码必须明确区分窗口宿主与项目页面；只共享宿主，不把页面或业务显示状态搬到窗口级。页面仍按需创建，没有新增定时器、轮询、运行时下载或可写资源路径。

## 验证

- 修复前，`TestPluginToolWindowsOpenInEveryProjectTab` 的就绪前/后两种顺序均失败，停在加载态；`TestProjectTabsShareWindowWebHost` 检出第二标签引用另一宿主。前者补充项目隔离断言后命名为 `TestPluginToolWindowsKeepWebPagesPerProjectTab`。
- `scripts/desktop/desktop-go.sh test ./internal/workbench -run 'Test(ProjectTabsShareWindowWebHost|PluginToolWindowsKeepWebPagesPerProjectTab)$' -count=1 -timeout=60s`：验证窗口就绪和生命周期、页面对象与持久桥接状态的项目隔离。
- `TestVisualPluginWebProjectTabs` 在 `vivahead,lithevisual` 下采集深浅色、中英文的第二项目加载与无引擎错误状态；无头驱动没有原生网页引擎，不能将错误表面截图记成真实插件页面成功显示。
- macOS 27.3 arm64 原生探针通过：真实 Core、Viva 和 WKWebView 使用临时契约网页窗口，通过网页桥接分别保存 alpha/beta，验证原生视图、页面对象和持久状态独立；切换保留页面，关闭首个项目不改变第二项目，重开首个项目创建新视图并恢复 alpha。探针设置 25 秒本地期限，正常执行 3.225 秒；窗口、临时探针和数据已清理。未验证滚动、实际插件业务界面或 Windows 原生引擎。
- 无头截图已实际生成并检查，覆盖第二项目加载与引擎不可用状态、深浅主题、中英文、1100×720 逻辑尺寸。状态读写回归使用插件声明的窗口 ID。
- Windows 原生流程和实际插件的滚动、选择保持仍待验收；功能矩阵继续保持 pending。

## 适用范围

- `desktop/internal/workbench/window_sessions.go`
- `desktop/internal/workbench/root.go`
- `desktop/internal/workbench/pluginpages.go`
- `desktop/internal/workbench/preview_pages.go`
- `desktop/internal/workbench/window_sessions_test.go`
- `desktop/internal/workbench/plugintools_test.go`
- `desktop/internal/workbench/pluginpages_visual_test.go`
