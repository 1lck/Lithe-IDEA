# Agent 笔记：插件视图——插件描述界面，宿主用 Viva 原生绘制

状态：已实现

## 先说结论

插件自己设计界面的地方有两处：工具窗口的正文，以及设置页里的设置区域（`settingRegions`）。两处都叫插件视图。插件后端的视图函数返回一棵 JSON 节点树，宿主把它交给 Core 的 `plugins.ui.applyResult` 校验，再用自己的 Viva 控件原生绘制。插件后端不接触界面库，也不需要网页。

节点分两类：

- **宿主控件**：行、分组、文字、输入框、选择、开关、按钮、表格、树等。只表达含义，样式全部来自宿主主题。
- **画布**（`canvas`）：插件描述一个有界的矢量场景（矩形、路径、文字、位图、分组），宿主保存场景并每帧自己画。悬停、按下、焦点、平移、缩放、悬停提示都在宿主本地处理，只有点击、修改这类语义事件才发给插件。

设置窗口里不嵌网页，网页只用于工具窗口。框外的一切归宿主；绑定设置的控件只改设置窗口的草稿，由宿主的「应用」经 Core 提交。

可以操作的原型：

- [`docs/design/plugin-canvas-scene.html`](../../../../docs/design/plugin-canvas-scene.html)：画布的交互、预算、故障回退和消息计数。
- [`docs/design/build-execution-settings.html`](../../../../docs/design/build-execution-settings.html)：大量插件注入时「构建、执行、部署」页的布局，见[构建、执行、部署设置页在大量插件注入时的结构](../feature/2026-11-18-build-execution-settings-at-scale.md)。

## 问题

设置页原来只能显示 Core 按清单生成的声明式设置行（`settings[]`）。插件作者做不了字段联动、「测试连接」按钮、依赖冲突图、配色预览这类界面。

旧的原生声明 `native-ui.schema.json` 只支持工具窗口里的树、列表和表单，还引用了 macOS 共享控件名（如 `LitheSettingsSelect`），换到 Viva 桌面端后已经不适用。

如果不划边界，插件会去改别的设置页、弹自己的对话框、改窗口底部按钮，宿主就没法统一管理设置窗口，也保证不了 `${setting:}`（把设置值代入启动参数的模板）的安全。

2026-11-12 的方案让插件在设置区域里用网页自绘。在 macOS 上实测，一个最简网页就额外带来三个系统进程，约 60 到 70 MB（见备选方案）。设置窗口一页可能有好几个插件区域，用户还会来回切页，这个开销太大。

## 决策

### 两处位置

| 位置 | 入口由谁决定 | 内容 |
| --- | --- | --- |
| 工具窗口正文 | 插件在 `ui.toolWindows` 里声明，带 `view: {function}` | 插件视图；树只在这里可用 |
| 设置区域 | 插件在 `settingRegions` 里声明 `page`；不写 `page` 时放在插件详情的「设置」标签。分组和位置由宿主按[设置页分类](../feature/2026-10-15-macos-settings-hierarchy.md)决定 | 插件视图画在页眉和本插件的声明式设置行之间，设置行照常显示；`setting`/`tool` 行、绑定设置的控件、带 `action` 的按钮只在这里可用 |

区域还可以声明 `keywords`：设置搜索除了页面标题和声明的设置行，也按这些词定位页面，并打开到这个插件的那一块。画布里的文字不进搜索。

### 事件与答案

- 宿主按契约发送 `open`、`close`、`click`、`change`、`select`、`activate`、`viewport`、`settings` 事件，每个事件调用一次视图函数，参数里带 `instance`、`surface`、`language` 和 `settings{effective, draft}`。
- 每个视图同一时间只发一个调用，按顺序发送。`viewport` 和 `settings` 停止变化 400 ms 后才发，等待中的同类事件合并成最新一个。输入框只在回车、失焦或提交时发一次 `change`，不按键调用。
- 函数返回整棵视图 `{view}`、补丁 `{patches}`（`set`、`replace`、`remove`、`insert`，最多 512 个）或 `{}`。宿主把答案连同清单、位置和上一次画的视图交给 Core 的 `plugins.ui.applyResult`，Core 校验并应用补丁后返回完整的下一棵视图，宿主只画这棵。宿主不保留自己的校验器或补丁引擎。
- 本版没有插件主动推送：视图只在回答事件时变化。

### 画布

- 节点是 `rect`、`path`、`text`、`image`、`group`，用 `viewBox` 坐标，画在和视图一样宽、`height` 点高的区域里。
- 缩放为 1 时，不写 `pan` 的画布显示整个 `viewBox`：按视图宽度缩放，但不超过 `height`，从左上角开始；写了 `pan` 的画布按视图宽度缩放，缩小到比区域窄时水平居中。设置区域的预览大多不写 `pan`，插件按区域最窄时的宽度设计场景（桌面端最小窗口里语言页约 613 点，构建系统页和编译器页的详情约 344 点），窗口变宽时场景大小不变、完整显示，不会像只按宽度缩放那样裁掉下半部分（Core [#107](https://github.com/Lithe-IDEA/Lithe-core-rust/pull/107)）。
- 颜色可以是固定值、主题令牌（`$accent`、`$text` 等）、深浅两套值，或线性渐变；令牌和深浅两套值跟随主题。宿主控件不接受颜色、字体、尺寸和坐标。
- 可点击的分组必须有 `id`、`w`、`h` 和 `label`。悬停、按下、选中的样式写在 `states`（`hover`、`pressed`、`selected`）里，由宿主本地切换。
- 普通滚轮滚动页面；⌘ 或 Ctrl 加滚轮缩放，拖动空白处平移，缩放按钮由宿主画。悬停提示停留 500 ms 后显示。
- 画布里没有文本框，需要输入时用旁边的宿主控件。
- 图片只能是插件包里的 PNG，宿主只读加载，单个文件不超过 256 KiB，每边不超过 1024 像素。

### 预算与失败

预算以 Core 契约为准：一棵视图 3 MiB、宿主控件节点 512 个、嵌套 16 层、一棵树 2000 项、一棵视图 8 个画布、每个画布 2000 个节点、每个画布场景 256 KiB。超出时 Core 拒绝整个答案。

每次调用 2 秒超时。调用失败、超时或被 Core 拒绝时，保留上一次画好的视图，在视图自己的框里显示宿主文案加插件原文，并提供「重试」；窗口其他部分照常可用。设置区域还没画出视图时，只显示声明式设置行，这些设置行照样能改。

### 生命周期

视图显示时发 `open`，消失时发 `close`。关闭、停用、更新或卸载插件、关闭项目、切换界面语言时，宿主取消未完成的调用并丢弃晚到的答案；切换语言后用新的 `instance` 重新打开。视图状态只存在后端和宿主内存里，不写进插件包或应用包。

### Viva 尚不支持的画布能力

宿主按以下方式降级绘制，缺口在 Lithe-IDEA/viva fork 补齐后再接上（[#2182](https://github.com/1lck/Lithe-IDEA/issues/2182)），不在 Lithe 里绕过：

- `dash` 只区分实线和虚线，用 Viva 固定的虚线样式，不按插件给的长短。
- 路径的渐变填充只取第一个和最后一个色标；矩形支持全部色标。
- 分组透明度按每个子节点的颜色分别相乘，不是整层合成，重叠的子节点会互相透出；位图不跟随透明度。
- 分组裁剪只做矩形裁剪，不带圆角。
- 不支持双指捏合缩放。

### 正确做法

- 数据库插件在「设置」标签放一个区域，用宿主控件画连接表单，输入框绑定它声明的 `host`、`port`，「测试连接」按钮发 `click` 给后端。用户点宿主的「应用」后，Core 校验并写入设置。
- 依赖分析插件在构建系统页放一个区域，用画布画依赖图。悬停、平移、缩放都在宿主本地完成；用户点了冲突节点，插件回 `set` 或 `insert` 补丁，在旁边放一个带 `action` 的「排除」按钮，写构建文件仍走插件的设置动作，遵守[设置反映工具真实配置](2026-10-25-settings-native-configuration-editing.md)。
- 主题插件用画布画配色预览，预览里用固定颜色；「变体」分段控件绑定设置，切换只改草稿，插件收到 `settings` 事件后按草稿重画，点「取消」后预览恢复。
- 新增宿主控件或画布能力时，先改 Core 契约和 `plugins.ui.applyResult`，再在 `desktop/internal/pluginview` 里绘制。

### 不要这样做

- 不要在宿主里校验或应用补丁，也不要在 Core 拒绝答案后画出一部分。
- 不要让插件在框外画任何东西，也不要在宿主里按插件名加专用页面分支。插件需要新页面时只能用 `page` 声明。
- 不要绕过 Core 直接写偏好目录或 `.lithe/plugin-settings.json`，否则 `${setting:}` 可能把未校验的值带进启动命令。
- 不要把悬停、拖动、每帧重画发给插件处理。
- 不要在画布里自己做文本框或键盘输入。
- 不要在设置窗口的插件区域里嵌网页。
- 不要为 Viva 缺少的画布能力在 Lithe 里写绕过代码，按上面的方式降级并在 fork 里补。

### 已确认

- 2026-11-12：渲染归 API-13，读写设置归 API-19，插件文字本地化归 API-37，都是现有编号的扩展，不新增编号。契约在 v0 里直接删掉 `native-ui`，换成插件视图，不升版本号（版本已于 2026-11-11 全部归 0）。
- 2026-11-18：设置区域只用插件视图，需要自由绘制时用画布（保留场景），不嵌网页；网页只用于工具窗口，沿用[插件自带网页界面](2026-10-18-plugin-web-content-in-host-windows.md)。顺序是先合设计和原型，再做 Core 契约加 SDK，最后做桌面端 Viva 渲染。

## 考虑过的备选方案

### 只保留声明式设置行，不允许自由绘制

宿主最好管：样式统一、没有网页引擎、无障碍有保证。用户在 2026-11-12 否定了这一点：图形预览、可视化编辑这类插件确实需要自己绘制，只给设置行会把它们挡在外面。画布满足了这个需求。

### 设置区域用自绘网页（2026-11-12 提议，2026-11-18 放弃）

插件提供包内 HTML，Viva 用 `canvas.NativeView(id, rect)` 在区域里放系统网页引擎（macOS 是 WKWebView，Windows 是 WebView2，Linux 是 WebKitGTK）。插件作者能直接用 Canvas、WebGL、SVG。

放弃的原因：

- 内存。在 macOS 上实测一个最简页面，额外带来三个系统进程。两次测量分别是 WebContent 41、42 MB，GPU 22、12 MB，Networking 6、5 MB，合计约 69、59 MB。画布只在宿主进程里多存一份场景，通常几 KB 到几十 KB，没有额外进程。Windows 的 WebView2 没测。
- 一页可能有多个插件区域，用户频繁切页，每次都要启动和销毁网页进程。
- 原生视图挖洞后，宿主的下拉弹层必须画在更高一层，否则会被网页盖住；三端网页引擎的行为也不一致。

### 即时绘制的远程画布

插件后端每一帧都发绘图指令，宿主把所有鼠标和键盘事件转发回去。每次交互都要跨进程往返，拖动会卡；文字输入和输入法要宿主重做；插件作者还要学一套新接口。2026-11-12 用户决定不采用。保留场景的画布只让语义事件跨进程，输入仍用宿主控件，场景词汇和 SVG 接近。

### 把插件进程的原生窗口嵌进框里

各平台嵌入方式完全不同，插件进程也能借此操作宿主窗口，安全边界守不住。不采用。

### 在宿主进程里运行 WASM 绘制

省掉跨进程往返，但插件代码跑进宿主进程，资源和崩溃难隔离，还要维护一套 WASM 运行时和接口版本。不采用。

## 后果

- 旧的原生树、列表、表单已删除（`core/plugin_native.go`、`pluginservice/hostnative.go`、`workbench/plugin_native.go`），声明 `native-ui` 的插件要改用插件视图。旧决策「声明式原生插件界面契约」（2026-10-21）已归档，不再作为依据。
- 工具窗口和设置区域共用 `desktop/internal/pluginview` 这一个渲染器：`session.go` 管事件队列、去抖、取消和重试，`render.go` 画宿主控件和树，`canvas.go` 画画布。新增节点只改这一处。
- 视图只在回答事件时变化，构建进度这类实时内容要等以后的版本加推送。
- 画布图片的大小上限（256 KiB、1024 像素）目前只在宿主实现里，需要写进 Core 契约。
- 降级项在 Viva fork 补齐之前，插件不能依赖自定义虚线、多色路径渐变、整层透明度、位图透明度、圆角裁剪和捏合缩放。
- 画布可点击分组的无障碍名称用 Viva 的命中区域（`HitWithOptions` 的 `Role` 和 `label`）提供，读屏的实际效果需要在原生整机上验收。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/pluginview/ ./internal/pluginservice/ ./internal/workbench/ ./internal/settingswindow/ ./internal/core/ -count=1`：覆盖事件顺序与去抖、晚到答案丢弃、失败重试、节点解析、画布路径与颜色、图片限制、嵌套树高度、视图事件参数（Core 契约 fixture）、区域绑定设置与搜索关键词。
- `scripts/desktop/desktop-go.sh test -count=1 -tags 'vivahead lithevisual' -run 'TestVisualPluginView' ./internal/pluginview/` 和 `scripts/desktop/desktop-go.sh test -count=1 -tags 'vivahead lithevisual' -run 'TestVisualPluginRegion' ./internal/settingswindow/`：设置 `LITHE_VISUAL_OUTPUT_DIR` 后输出工具窗口视图和设置区域的深浅主题截图。
- `scripts/desktop/verify/verify-runtime-bundle-immutability.sh`：确认插件包和应用包在运行中不被写入。
- 原生整机验收：安装一个声明了视图工具窗口和设置区域的测试插件，检查点击、编辑、树选择与激活、画布平移缩放、绑定设置的应用与取消、后端报错后的重试、停用插件后视图关闭；macOS 上打开插件区域时不出现新的 `com.apple.WebKit` 进程。Windows 在虚拟机上重复。

## 适用范围

- `desktop/internal/pluginview/`
- `desktop/internal/pluginservice/hostview.go`
- `desktop/internal/core/plugin_view.go`
- `desktop/internal/workbench/plugin_view.go`
- `desktop/internal/settingswindow/plugin_region_view.go`
- `desktop/internal/settingswindow/settings_surfaces.go`
- `docs/design/plugin-canvas-scene.html`
- Lithe-core-rust 的 `shared/plugins/contract/v1/`（插件视图、设置区域的契约、schema 与 fixture）
