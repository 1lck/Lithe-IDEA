# Agent 笔记：省略文字的全文悬浮提示

状态：提议中

## 先说结论

用户需要把鼠标放在省略文字上就能看到完整内容。通用排版与提示由 Viva 界面框架负责；Lithe 只在自己提前缩短文字时传入原文，保持行点击、筛选和选择的原有行为。本地实现已接线并进行无头联调，正式 Viva 依赖尚未包含这项能力，因此本笔记留在 proposed。

## 问题

普通标签、下拉选项、日志单元格和自绘列表使用不同的截短入口。只在业务页面检查文字末尾是否为 `…` 会把用户输入的省略号误认为截断，也无法找回提前缩短时丢失的中间部分。

把每段文字变成新的鼠标目标会改变点击落点。日志的折叠按钮覆盖消息开头，画布的父分组也有自己的提示；这些位置需要全文可见，同时保留原操作。

## 提案

- Viva 根据真实排版结果登记非交互提示区域（`HoverHint`，只描述可显示的文字与几何位置，不是按钮或点击目标）。普通省略标签和达到最大行数的段落自动登记原文，不靠省略号字符推断。
- Lithe 提前截短的文字显式保留原文。日志消息及字段、工具链路径、Git 自绘标签、通用画布和信任对话框均走同一提示呈现入口，不复制悬停计时或弹层样式。
- 提示区域随裁剪、缓存回放、嵌入画布和动画变换一起移动。后绘制控件与焦点限制仍能遮挡提示；控件自己稍后登记的点击区域不能把自己的全文提示遮住。
- 悬停时间读取主题，等待只申请下一次需要的绘制，不轮询。按下隐藏，离开后才解除抑制。全文提示优先于同一区域的动作说明，避免同时出现两张卡片。
- 下拉框（Select）的触发器和选项原来直接绘制文字，超出边界就硬裁剪，没有省略号。改动后，放不下的值和其他控件一样以“…”结尾，悬停时显示全文。窄下拉框绘制出的文字因此会变短，例如 112 宽的运行配置作用域选择器里，“All configurations (3)”显示为“All configuration…”。测试检查这类文字时，要按省略后的显示来判断，并用悬停验证全文。
- 框架改动先进入组织 Viva fork 的 main（Lithe-IDEA/Lithe-viva#61，同一改动的上游 PR 为 vivaui/viva#454），随后升级 Lithe 的固定修订。不得提交本地目录替换，也不把本地联调截图写成正式包已支持。

正确做法：工具链路径经过中间省略后，对显示路径的标签传入完整安装目录，点击仍由原单选行处理。

不要这样做：给截短文字增加一个透明按钮接管悬停；它会抢走表格行的点击或焦点。

## 考虑过的备选方案

- 在所有页面逐个增加普通 Tooltip：会漏掉共享控件和自绘入口，也可能增加新的点击目标；放弃。
- 在最底层文本绘制中看到 `…` 就登记提示：无法区分原始内容和实际截短，也拿不到提前省略的内容；放弃。
- 在 Lithe 中复制框架的悬停检测和跨平台窗口逻辑：会制造第二套命中与生命周期规则；放弃，通用能力直接修改 Viva。

## 验收标准

普通标签和自绘文字实际省略时显示原文；未省略及原文自带省略号时不增加全文提示。滚动、缓存回放、遮挡弹层、点击隐藏和鼠标离开均正确，原行选择、字段筛选及复选框不受影响。

Viva 改动合入 fork main 并升级正式 pin 后，才把本笔记迁入 implemented；macOS、Windows 原生验收分别记录，不能用无头结果代替。

## 风险

每帧多保存可见截短文字的提示描述，占用少量与可见区域规模相关的内存。原文引用随 Canvas 的 Reset、Trim、Rewind 和缓存回放清理；手工组合的字段和画布原文按不可变输入缓存，避免逐帧拼接。

完整提示需要排版原文，特别长的单条记录仍可能增加悬停时开销。局部基准只能说明无头排版与绘制开销，不能证明原生 GPU 或常驻内存表现。当前普通正式依赖尚不能构建新增接线，联调必须使用已打补丁的 fork 副本与临时 modfile。

## 验证

- `scripts/desktop/desktop-go.sh test`：通过本地 modfile 运行日志、工具链、通用画布、Git 列表和信任对话框的相关回归；测试实际移动指针并推进虚拟帧时间。
- `desktop/internal/logwindow/visual_capture_test.go`、`desktop/internal/settingswindow/visual_capture_test.go`、`desktop/internal/pluginview/view_visual_test.go`、`desktop/internal/workbench/status_path_visual_test.go`、`desktop/internal/workbench/ellipsis_visual_test.go`：生产视图的明暗主题与中英文截图，每处各有悬停前和悬停后两张。日志、工具链和通用画布输入是明确的测试 fixture，画布截图按客户端窗口的做法使用 `uistyle.Tooltip` 提示样式；状态栏、Git 日志和信任对话框使用真实临时文件、临时仓库和临时目录，Git 日志与信任对话框按默认窗口尺寸 1280×800 截图。截图不是原生应用验收证据。
- `.agents/skills/write-stable-tests/scripts/test-stability-macos.sh`：只运行本次相关场景并检查逐项计时；竞态检查覆盖相同交互。
- `scripts/platform-feature-matrix/verify-platform-feature-matrix.sh` 与 `scripts/agent-notes/verify-agent-notes.sh`：检查功能状态与笔记结构。

## 适用范围

`desktop/internal/logwindow/`、`desktop/internal/settingswindow/toolchains_view.go`、`desktop/internal/pluginview/`、`desktop/internal/workbench/gitgraph.go`、`desktop/internal/workbench/pluginprompt.go`、`desktop/internal/workbench/workspace_trust.go`，以及 Viva 的排版、Canvas、共享控件与提示绘制层。不改变插件契约、数据预算省略或源码编辑器的悬停文档。
