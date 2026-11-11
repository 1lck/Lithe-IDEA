# Agent 笔记：工作台根窗口改为一个 Viva Page，面板是组件，拖拽用 DragState

状态：已实现

## 先说结论

工作台主窗口现在就是一个 Viva Page：`ui.NewPage(ui.PageConfig{View: a.page, ...}).Config(base)` 产生窗口配置，`a.page(c)` 在没有项目时画欢迎页，有项目时画“标题栏 → 左侧栏、主列、右侧栏 → 状态栏”，再依次声明所有弹窗和 Toast。每个工具窗口、标签栏、编辑器和终端都是这个 Page 调用的组件函数；没有项目、窗口和面板各自一个 Page 再由宿主转发输入的做法了。Viva 同时升级到 `189ed59`（上游 main），那里已删除 `Page.Key/Pointer/Owns/Overlay`，旧的“Page 嵌进 Frame 窗口”写法在编译层面就不再成立。

## 问题

迁移期间，工作台外壳（标题栏、侧栏、标签栏、编辑器分组、终端、拖拽）仍是 `ui.Frame` 写法，已迁移的面板各自是一个 `*ui.Page`，用 `Slot` 嵌进 Frame，再由 `pagehost.go` 在窗口回调里把指针、键盘、滚轮、输入法转发给“这一帧画过的 Page”。这有三个代价：

- 转发规则（层级、阻断、谁先看到键）是应用自己写的一套，和 Viva 的真实路由会悄悄分叉；
- 手写的 `gfx.Tree` 标识、命中测试、拖拽状态机（`drag.go`、`tabdrag.go` 里的按下/移动/松开）和“画完再捕获位置”的后处理（`capture`）都是只为 Frame 分发而存在的代码；
- Viva 上游要把 Frame 收为底层引擎，应用层继续依赖它会卡住升级。

## 决策

- **一个窗口一个 Page。** `workbench/root.go` 是入口：`Config` 把 `a.page` 交给 Viva，窗口背景取当次的 Chrome 色；`beginPaint` 在每次绘制前更新主题、清掉上一次声明的位置记录。弹窗（Clone、搜索、导航、语言弹窗、插件审核与提示、Git 分支与同步对话框、新建项目 `ui.Modal`）在工作台之后声明，`ui.Toasts` 最后。新建项目的 `internal/sheet` 随之删除。
- **面板是组件。** 外壳 `shellMain` 用 `ui.Splitter` 排列左、右、下三个工具窗口区和编辑器区，尺寸仍由 `layoutState` 管（偏好宽度、窗口太窄时临时压缩的语义不变，只是 Splitter 状态在下一次绘制开头采纳用户的拖动）。工具窗口内容直接调用已有组件（项目树、Git 日志、提交、Run/Tests/Debug、Problems、Find、Agent、终端）。
- **编辑器区。** 编辑器分组用 `ui.Splitter`（用 `SplitterState.Ratio` 保持比例）递归排列，每组是一个标签栏组件加一个 body。文档和终端各是一个 `ui.Control`：绘制仍调用 `editorview` / `termview` 的 `Paint`，键盘、指针、滚轮和输入法走 `ui.Handlers`；两个视图新增 `Bind(hit, parts)`，让它们的命中区域成为 Control 的 `Parts`，页面才能把事件送到 Handlers。焦点请求用 `ui.FocusBind`。
- **标签栏。** 编辑器分组和终端工具窗口共用 `tabBar`（`workbench/tabstrip.go`），保留“单行滚动 / 压缩 / 多行”三种设置语义和隐藏标签菜单（`ui.Menu`）。单行滚动由自己管理偏移并在 `OnScroll` 里处理滚轮，因为这一版 Viva 没有横向滚动容器。`internal/hscroll` 删除。
- **拖拽用 `ui.DragState`。** 工具按钮在侧栏、标题栏、状态栏之间拖动，终端标签重排和拆分分组，都是 `DragSource` 加一个覆盖整个工作台的 `DropTarget`；落点由 `accept` 回调用现有的纯函数（`dragLocate`、`dropAt`、`splitEdgeAt` 等，及其测试）按指针位置算，`drop` 回调执行。拖拽幽灵与落点预览是一个无命中的绘制层。`drag.go`、`tabdrag.go` 里的按下/移动/松开状态机删除。
- **文件树。** 升级后用 `TreeState.RowID` 让选中跟随键盘焦点：方向键移动选中，点击行把焦点放到行，“定位当前文件”把焦点移到行。
- **窗口回调只剩三件上游没给的事**：`OnKey`（Splitter 的方向键、Search Everywhere 的方向键与 Enter）、`OnShortcut`（终端和编辑器的复制、剪切、粘贴、Ctrl 系列等“chord”，`Handlers` 只收键、不收 chord）、`OnScroll`/`OnPointer`（树的横向滚轮、标签栏滚轮、纵向滑动时去掉横向分量、指针离开窗口时关悬停）。它们都只做这一件事，不再有分发层。

## 考虑过的备选方案

- 先在 `339e133` 上做完根 Page 再升级 Viva：该版本没有 `DragState` 和 `RowID`，拖拽会先写一遍临时状态机再删，所以直接在新版本上做。
- 继续让面板各自一个 Page：被上游删除的 API 决定了这条路不可行，且回调转发本来就是要消除的重复。
- 项目菜单用 `ui.Menu`：菜单项没有头像、第二行路径和分支，放不下现有的项目行，所以项目菜单是 `ui.Popover` 加自绘行；齿轮菜单用 `ui.Menu`。
- 标签栏用单行 `ui.List` 滚动：该 List 的视口宽度与盒子宽度不一致，隐藏标签和“滚动到选中”算不准，改为自己管偏移。

## 后果

- 新面板写成 `func (a *App) xxxPanel(c ui.C)` 并从 `toolBody` 或相应位置调用，不再建 Page、不再注册到宿主。
- 标签栏的“隐藏标签”菜单没有逐行关闭按钮；顶部细滚动条没有了（滚轮、隐藏标签菜单和滚到选中仍在）。文本区的光标样式取决于 Control 的命中选项。
- Agent 输入框仍是 Primary+Enter 发送：Viva 的 `TextArea` 仍没有 Enter 提交入口（vivaui/viva#200）。

## 已知缺口（Viva）

vivaui/viva#187 已合入，Lithe 固定的 Viva 版本已包含：等宽文字按格子测量、断行和截断。Git 日志详情的标题、作者行和引用标签改用 `ui.Wrap` 与 `ui.Flow`，删除了手工断行和 `monogrid` 包；Git 控制台每段文字不再自己设宽度，但一行有多种颜色和可点击的折叠开关，仍按格子自己折行；日志窗口的等宽文字不再补宽，详情 JSON 改为 `ui.Scroll(...).Sideways().Scrollbars()`，和 macOS 一样横向滚动并显示滚动条，不再按列折行。#201、#202 已关闭；#200、#203、#204 仍是 open：Splitter 的方向键不由 Page 路由（#204）；`Handlers` 没有 chord 钩子；Tree 不处理横向滚轮（#203）；List 在纵向滑动时会带走横向分量。以上都在窗口回调里做了最小规避。

## 验证

- `desktop/internal/workbench` 全量测试通过，原有断言未删，只把依赖 Frame 内部的部分改成按名字或 Viva 标识驱动；新增根 Page 下的标签拖放、文件树选中跟随焦点测试。
- `viva vet ./...`、`go vet ./...`、i18n 三项、功能矩阵 `--check`、`scripts/macos/verify/verify-runtime-bundle-immutability.sh`。
- 编辑器基准（`scripts/desktop/perf/editor-bench.sh`）在改动前后各跑一次，结果写在 PR 说明里。

## 适用范围

- `desktop/internal/workbench/root.go`
- `desktop/internal/workbench/chrome_view.go`
- `desktop/internal/workbench/shell_view.go`
- `desktop/internal/workbench/shell.go`
- `desktop/internal/workbench/editor_view.go`
- `desktop/internal/workbench/tabstrip.go`
- `desktop/internal/workbench/drag.go`
- `desktop/internal/workbench/tabdrag.go`
- `desktop/internal/editorview/`
- `desktop/internal/termview/`
- `desktop/go.mod`
