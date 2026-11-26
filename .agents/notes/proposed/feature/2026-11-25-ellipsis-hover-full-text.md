# Agent 笔记：省略文字的全文悬浮提示

状态：提议中

## 先说结论

用户把鼠标停在以“…”结尾的文字上，就能看到完整内容。通用的排版和提示由 Viva 界面框架负责；Lithe 只在自己提前缩短文字时传入原文，行点击、筛选和选择的行为保持不变。

这项能力在 Viva 里默认关闭，由页面自己开启：Lithe 的主窗口、设置窗口和日志窗口都要开。提示框开向内容一侧，不压住同一列表里相邻的行。开关和方向所在的 Viva 版本还在 fork PR 里，Lithe 暂时固定在该 PR 的 head 上，所以本笔记仍留在 proposed。

## 问题

普通标签、下拉选项、日志单元格和自绘列表各有自己的截短入口。如果只在业务页面检查文字末尾是不是 `…`，用户自己输入的省略号会被误认为截断，提前缩短时丢掉的中间部分也找不回来。

把每段文字变成新的鼠标目标会改变点击落点。日志的折叠按钮盖住消息开头，画布的父分组也有自己的提示；这些位置需要显示全文，同时保留原来的操作。

提示框的方向也有问题。框架默认把提示开在文字下方，但侧栏和工具窗口里的文字下方是同一列表的下一行，提示会把它们盖住。底部工具窗口更不一致：上面几行开在下方，靠近窗口底边的行放不下，才翻到上方。

## 提案

### 框架负责找出截断并显示全文

- Viva 根据真实排版结果登记非交互提示区域（`HoverHint`，只描述能显示的文字和几何位置，不是按钮，也不是点击目标）。普通省略标签和达到最大行数的段落自动登记原文，不靠省略号字符推断。
- Lithe 提前截短的文字要显式保留原文。日志消息和字段、工具链路径、Git 自绘标签、通用画布和信任对话框都走同一个提示入口，不复制悬停计时或弹层样式。
- 提示区域随裁剪、缓存回放、嵌入画布和动画变换一起移动。后绘制的控件和焦点限制仍能遮挡提示；控件自己稍后登记的点击区域不能遮住自己的全文提示。
- 悬停时间读取主题；等待时只申请下一次需要的绘制，不轮询。按下鼠标时隐藏提示，指针离开后才解除抑制。全文提示优先于同一区域的动作说明，避免同时出现两张卡片。

### 页面开关：Lithe 的三个窗口都要开

上游评审要求这项能力默认关闭，由页面通过 `PageConfig.EllipsisTooltips` 开启。Lithe 的三个窗口都开启了：

- 主窗口：`desktop/internal/workbench/root.go`
- 设置窗口：`desktop/internal/settingswindow/window.go`
- 日志窗口：`desktop/internal/logwindow/window.go`

插件视图画在宿主窗口里，跟随宿主窗口的开关；它的测试页面有自己的 `PageConfig`，测试里要单独开启。以后新增窗口时，也要在它的 `PageConfig` 里开启；否则这个窗口里的截短文字不会显示全文。

下拉框（Select）的触发器和选项原来直接绘制文字，超出边界就硬裁剪，没有省略号。开关打开后，放不下的值和其他控件一样以“…”结尾，悬停时显示全文；开关关闭时仍按原来的方式硬裁剪。所以 Lithe 里窄下拉框显示的文字会变短，例如宽 112 的运行配置作用域选择器里，“All configurations (3)”显示为“All configuration…”。测试检查这类文字时，要按省略后的显示来判断，并通过悬停验证全文。

### 方向：朝向内容，不压住相邻的行

Viva 的 `EllipsisTooltipOn(side)` 给一个容器及其内部的文字指定提示方向（上、右、下、左）。离文字最近的设置生效；那一侧放不下时，翻到对侧。没有指定的地方默认开在下方。

Lithe 按区域指定方向，不给单个标签指定：

| 区域 | 方向 | 设置位置 |
| --- | --- | --- |
| 左侧工具窗口 | 右，朝向编辑器 | `desktop/internal/workbench/shell_view.go` 的 `tooltipSide` |
| 右侧工具窗口 | 左，朝向编辑器 | 同上 |
| 底部工具窗口 | 上，朝向编辑器 | 同上 |
| 状态栏 | 上 | `desktop/internal/workbench/chrome_view.go` 的状态栏行 |
| 设置窗口侧栏 | 右，开在页面上 | `desktop/internal/settingswindow/window_view.go` 的侧栏列 |
| 日志窗口通道侧栏 | 右，开在表格上 | `desktop/internal/logwindow/window.go` 的侧栏列 |

方向跟着工具窗口所在的位置走：用户把提交工具窗口从左边拖到右边，它的提示也跟着改成开向左侧。编辑器、对话框和表格正文没有相邻行被盖住的问题，保持默认的下方。

正确做法：工具链路径经过中间省略后，给显示路径的标签传入完整安装目录，点击仍由原来的单选行处理；新的侧栏在它的列容器上指定一次方向。

不要这样做：给截短文字加一个透明按钮来接管悬停，它会抢走表格行的点击或焦点；也不要在每个列表行的标签上分别指定方向，否则工具窗口换位置后，方向就和所在区域对不上。

### 依赖

框架改动先合入组织 Viva fork 的 main，然后升级 Lithe 的固定修订。默认开启的第一版（fork PR Lithe-IDEA/Lithe-viva#61）已合入 fork main，并由 Lithe 固定使用。可选开启和方向在上游 vivaui/viva#454，同步进 fork 的 PR 是 Lithe-IDEA/Lithe-viva#64；Lithe 暂时固定在 #64 的 head，#64 合入后要换成 fork main 上的合并提交。不得提交本地目录替换。

## 考虑过的备选方案

- 在所有页面逐个加普通 Tooltip：会漏掉共享控件和自绘入口，也可能增加新的点击目标；放弃。
- 在最底层文本绘制里看到 `…` 就登记提示：分不清原始内容和真正的截短，也拿不到提前省略的内容；放弃。
- 在 Lithe 里复制框架的悬停检测和跨平台窗口逻辑：会多出第二套命中和生命周期规则；放弃，通用能力直接改 Viva。
- 保持默认开启：上游评审没有接受；默认开启会改变所有使用 Viva 的应用。改为页面开关后，Lithe 要在每个窗口自己开启。
- 所有提示都开在下方：侧栏和工具窗口里的提示会盖住下一行，底部工具窗口的方向也随行的位置变化；放弃。

## 验收标准

普通标签和自绘文字真正被省略时显示原文；没有省略、或者原文本身带省略号时，不加全文提示。滚动、缓存回放、遮挡弹层、点击隐藏和鼠标离开都正确，原来的行选择、字段筛选和复选框不受影响。上表各区域的提示开在指定一侧，放不下时翻到对侧。

fork PR #64 合入 fork main、Lithe 改为固定 fork main 上的提交后，才把本笔记迁入 implemented。macOS 和 Windows 的原生验收分别记录，不能用无头结果代替。

## 风险

每帧要多保存可见截短文字的提示描述，占用的内存很少，与可见区域的规模有关。原文引用随 Canvas 的 Reset、Trim、Rewind 和缓存回放一起清理。字段原文在第一次被截短时拼接，并随字段缓存；画布原文按不可变输入缓存；都不逐帧拼接。日志消息只有在被截短、又被搜索高亮分成多段时，才多包一层容器来承载整段的提示；其他消息直接在标签上登记，不改变原来的节点结构。

完整提示需要排版原文，特别长的单条记录仍可能增加悬停时的开销。局部基准只能说明无头排版和绘制的开销，不能证明原生 GPU 或常驻内存的表现。

新窗口忘记开启开关时，截短文字不会显示全文，也没有报错。新增窗口时要检查 `PageConfig`。

状态栏贴着窗口底边，不指定方向时提示也会翻到上方。所以它的方向测试即使去掉设置也会通过，只能防止提示开到下方，不能证明设置本身生效。

## 验证

- `scripts/desktop/desktop-go.sh test`：运行日志、工具链、通用画布、Git 列表、信任对话框和插件视图的相关回归。测试真的移动指针，并推进虚拟帧时间。
- `desktop/internal/workbench/ellipsis_side_test.go`、`desktop/internal/settingswindow/ellipsis_side_test.go`、`desktop/internal/logwindow/ellipsis_side_test.go`：检查提交工具窗口在左侧、右侧和底部时，以及状态栏、设置侧栏和日志通道侧栏里，全文提示开在哪一侧。去掉区域的方向设置后，除状态栏外的测试都会失败。
- `desktop/internal/logwindow/visual_capture_test.go`、`desktop/internal/settingswindow/visual_capture_test.go`、`desktop/internal/pluginview/view_visual_test.go`、`desktop/internal/workbench/status_path_visual_test.go`、`desktop/internal/workbench/ellipsis_visual_test.go`：截取生产视图在深浅主题和中英文下的画面，截图和测试命令见 `docs/assets/ellipsis-hover-full-text/README.md`。截图不是原生应用的验收证据。
- `.agents/skills/write-stable-tests/scripts/test-stability-macos.sh`：只运行本次相关场景，并检查每个测试的耗时；竞态检查覆盖相同的交互。
- `scripts/platform-feature-matrix/verify-platform-feature-matrix.sh` 和 `scripts/agent-notes/verify-agent-notes.sh`：检查功能状态和笔记结构。

## 适用范围

`desktop/internal/logwindow/`、`desktop/internal/settingswindow/toolchains_view.go`、`desktop/internal/settingswindow/window.go`、`desktop/internal/settingswindow/window_view.go`、`desktop/internal/pluginview/`、`desktop/internal/workbench/root.go`、`desktop/internal/workbench/shell_view.go`、`desktop/internal/workbench/chrome_view.go`、`desktop/internal/workbench/gitgraph.go`、`desktop/internal/workbench/pluginprompt.go`、`desktop/internal/workbench/workspace_trust.go`，以及 Viva 的排版、Canvas、共享控件和提示绘制层。不改变插件契约、数据预算省略或源码编辑器的悬停文档。
