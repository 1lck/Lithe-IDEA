# 原版视觉与交互基线

本页是原版 macOS 客户端的视觉与交互基线。原版源码已从仓库删除，下文源码链接固定在修订
`5a54c41aa37a4e6e6b68918a4b05765b9dd07a36`（下称 5a54c41），仅供查阅原版实现。
Viva 的界面改动按本页的几何尺寸、交互行为和共享所有权规则实现，并复用 Viva 现有共享控件，不另建视觉体系。

适用于界面、共享控件及视觉交互改动；通用架构、i18n、设置和连续列表规则见
[Lithe 开发规范](../SKILL.md)。本页的仓库路径均相对于仓库根目录。

## 视觉依据与共享所有权

已批准的基线是 Git Log 的 Branch/User/Date/Paths 下拉、设置窗口下拉，以及 Project 侧栏的
Project/Dependencies 下拉。顶部项目切换器只是消费者，不是其他控件的视觉参照。

- 业务调用方提供内容、选择与动作，不另定义背景、边框、圆角、行尺寸或开启动画。
- 约束仅适用于已有共享组件覆盖的控件。修改共享实现前，检查对应 IDEA Community 动作、控件或主题源码，
  在所属 Agent Note 记录源码路径与 revision。
- 截图用于验证，不用于猜测几何尺寸或补造 Lithe 尚无的 IDEA 功能。
  缺少共享控件也不是在样式修复中另建视觉体系的理由。
- 决策及消费者清单见
  `.agents/notes/implemented/simplification/2026-09-30-macos-shared-dropdown-style.md`。

## 菜单与下拉

### 统一入口

下表左侧为原版入口，右侧为 Viva 中的对应实现。Viva 的控件定义位于 Viva 库（`github.com/vivaui/viva`，
即 `desktop/go.mod` 固定的 fork），表中列出的是本仓库内的调用处。

| 用途 | 原版入口 | 原版源码（5a54c41） | Viva 对应实现 |
| --- | --- | --- | --- |
| 动作下拉、勾选动作、开关与子菜单 | `LitheMenu` | [LitheDropdown.swift](https://github.com/1lck/Lithe-IDEA/blob/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/macos/Sources/Lithe/Views/Components/LitheDropdown.swift) | `ui.Menu`，调用处 `desktop/internal/workbench/title_run_view.go` |
| 产品原生右键菜单 | `litheContextMenu` / `LitheContextMenuPresenter` | [LitheContextMenu.swift](https://github.com/1lck/Lithe-IDEA/blob/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/macos/Sources/Lithe/Views/Components/LitheContextMenu.swift) | `ui.ContextMenu`，调用处 `desktop/internal/workbench/tabstrip.go` |
| 可搜索选择器与自定义弹层内容 | `litheDropdown(isPresented:opensUpward:content:)` / `LitheDropdownPopover` | [LitheDropdown.swift](https://github.com/1lck/Lithe-IDEA/blob/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/macos/Sources/Lithe/Views/Components/LitheDropdown.swift) | `ui.Combobox`，调用处 `desktop/internal/settingswindow/fonts_view.go` |
| 值选择（含设置表单） | `LitheSettingsSelect` | [LitheSettingsControls.swift](https://github.com/1lck/Lithe-IDEA/blob/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/macos/Sources/Lithe/Views/Components/LitheSettingsControls.swift) | `ui.Select`，调用处 `desktop/internal/settingswindow/window_view.go` |
| 动作/自定义下拉窗口、定位与关闭 | `LitheContextMenuPresenter` | [LitheContextMenu.swift](https://github.com/1lck/Lithe-IDEA/blob/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/macos/Sources/Lithe/Views/Components/LitheContextMenu.swift) | `ui.Menu`，锚点由调用处传入 |
| 值选择弹窗与键盘选择 | 仅由 `LitheSettingsSelect` 内部使用 | [LitheSettingsControls.swift](https://github.com/1lck/Lithe-IDEA/blob/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/macos/Sources/Lithe/Views/Components/LitheSettingsControls.swift) | `ui.Select`，同上 |
| 共享行尺寸与高亮 | `LitheDropdownMetrics` / `LitheDropdownRowStyle` | [LitheContextMenu.swift](https://github.com/1lck/Lithe-IDEA/blob/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/macos/Sources/Lithe/Views/Components/LitheContextMenu.swift) | Viva 尚无共享实现。`desktop/internal/workbench/chrome.go` 中的 `chromeMenuRow` 只是项目菜单的局部常量 |
| 共享外层背景、8pt 圆角、边框与裁剪 | `litheContextMenuSurface` | [LitheTheme.swift](https://github.com/1lck/Lithe-IDEA/blob/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/macos/Sources/Lithe/Theme/LitheTheme.swift) | 背景颜色见 `desktop/internal/workbench/theme.go`。8pt 菜单外层圆角与裁剪 Viva 尚无共享实现；`theme.go` 中的控件圆角为 `Radius: 4` |

### 呈现、锚点与宽度

- 新增或修改产品下拉时，不使用系统菜单、系统弹出框或原生下拉按钮呈现。
  共享面板直接打开，不播放系统弹出或弹跳动画，不加 spring 或缩放过渡。
- 工具栏下拉锚定触发控件左下角，不跟随指针；保留屏幕边缘夹取、键盘导航、选中态、外部点击关闭与焦点行为。
- 主工具栏 Project/Branch 锚定完整工具栏槽位，保留按钮绘制区域下方既有间距。
  宽度规则：Project 按内容测量，Branch 使用 IDEA Community New UI 的 375pt 基线。
  不复制顶部项目切换器的旧固定宽度，不另造搜索框；搜索使用共享搜索框，与 Git Log 一致。
- 宽度按角色决定，不全局强制相同。动作菜单按本地化标题、图标、快捷键与勾选位测量；
  设置选择器按共享触发器与内容测量。业务调用处不加魔法宽度或偏移。
- 子菜单跟随实际可见的触发行，包括滚动与分隔项；屏幕边缘修正只由共享呈现层处理。
- Project/Branch 弹层打开期间，触发行保留正常悬停背景，不改成蓝色选中态，也不新增按下色；
  弹层关闭后解除保留。此规则不改变菜单行的勾选或选中样式。

### 编辑器菜单与例外边界

- 原版编辑器菜单曾由 Monaco 网页渲染，该实现已删除。本页不再约束网页样式。
- 产品下拉只使用共享菜单、共享选择器和共享分段控件。系统对话框、应用菜单、编辑器补全与光标弹层、
  悬停文档属于独立交互，不被产品菜单规则替换。
- 项目文件的“打开方式”是系统集成例外：右键菜单仍走共享菜单入口，应用列表、默认项及图标来自系统，
  业务调用方不指定尺寸、字体或颜色。见
  `.agents/notes/implemented/feature/2026-11-03-macos-open-with.md`。

## 搜索与输入

- 搜索使用完整共享搜索框（原版源码：[LitheSearchField.swift](https://github.com/1lck/Lithe-IDEA/blob/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/macos/Sources/Lithe/Views/Components/LitheSearchField.swift)），
  包括外部焦点状态与语义附件。普通调用方不自行拼装样式。
- 普通单行、密码与多行表单使用共享输入控件（原版源码：
  [LitheTextInput.swift](https://github.com/1lck/Lithe-IDEA/blob/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/macos/Sources/Lithe/Views/Components/LitheTextInput.swift)）。
  输入控件拥有编辑、焦点、光标、外观与可选标签；表单字段拥有标签间距，以及仅输入部分的禁用状态。
- 保留输入法组合输入及聚焦前的文本光标（I-beam）。高度、内边距、圆角、字体、占位符与焦点颜色读取共享尺寸。
  存在未提交的组合文本但绑定值为空时，不得恢复占位提示。
- 多行提交消息使用多行编辑器（原版源码：
  [CommitMessageEditor.swift](https://github.com/1lck/Lithe-IDEA/blob/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/macos/Sources/Lithe/Views/Git/CommitMessageEditor.swift)），
  不用单行搜索框替换，也不复制输入法组合与撤销逻辑。
- 禁用字段或分组内的信息提示仍须可交互。

## 图标与工具窗口标题栏

- 图标使用原版已批准的 IDEA 图标集（原版源码：
  [LitheIcons.swift](https://github.com/1lck/Lithe-IDEA/blob/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/macos/Sources/Lithe/Theme/LitheIcons.swift)，
  SVG 位于 [IDEAIcons](https://github.com/1lck/Lithe-IDEA/tree/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/macos/Resources/IDEAIcons)）。
  保持原几何、描边或填充，以及深浅色变体。使用动作源码指定的图标，不猜测系统符号，不另画替代品，
  不用缩放或叠字模拟粗描边。没有指定图标的菜单动作保留空图标槽。
- 普通工具窗口工具栏按钮使用共享图标按钮，保留禁用、悬停反馈与默认箭头光标。
  22pt 命中区不推广到所有按钮；主工具栏切换器等保留各自的共享尺寸。指针与文本光标是明确的控件语义。
- 普通工具窗口标题栏使用共享标题栏组件，由它拥有 41pt 高度、13pt 粗体标题、外边距与动作间距。
  标题为纯文本，不加标题图标、外框或底部分隔线。真实会话标签栏保留标签语义，
  不把静态标题伪装成标签。

## 树、列表与选择

- 普通树和持久列表使用共享树列表组件（原版源码：
  [LitheTreeList.swift](https://github.com/1lck/Lithe-IDEA/blob/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/macos/Sources/Lithe/Views/Components/LitheTreeList.swift)）。
  调用方只提供稳定的行 ID、选择、层级与业务动作。共享组件拥有边距、滚动、焦点、悬停与选中绘制、
  键盘导航、范围选择和无障碍。递归业务树可提供节点描述，不实例化隐藏子项。
- 不在调用处自行拼装滚动区域、行样式或焦点修饰，只使用共享组件。
- 原生视口走共享外观与导航策略，保留现有渲染器与虚拟化，不把整棵树改成每行一个独立视图。
- 项目树保留拖拽、剪贴板与异步编辑器焦点的所有权，选择与导航决策仍共享。项目树保留可配置的行高；
  其他行使用树尺寸，多行列表保留内容几何。
- 选择变化与主点击或激活分开。键盘移动游标不得意外打开编辑器或运行任务。
  全局搜索保留由搜索输入驱动的焦点与分类快捷键。表格、提交图、菜单和编辑器补全保留自身的所有权。
- 列表焦点由平台的焦点与活动窗口状态决定，不接受调用方传入布尔值伪造焦点。
  验证相邻输入框、非活动窗口、深浅色、多选、键盘边界、右键菜单目标、展开与滚动。
- 行选择不等于复选框的纳入状态、设置值、状态徽标、活动栏按钮、菜单高亮、工具窗口标签或编辑器文字选择。
  它们保留各自的样式。不为原本没有持久选择的视图添加选择状态。
- 验证焦点移到相邻列表或编辑器、整窗失活与恢复、输入框与列表之间的焦点转换、键盘导航，以及深浅色下的
  聚焦与非聚焦行。组件测试通过不等于整个产品通过验收。

## 字体与滚动条

- 普通界面使用统一的 UI 字体，代码与已有等宽呈现使用等宽字体，由主题统一拥有。
  使用已打包的真实字体变体（原版为 Inter 或 JetBrains Mono），不硬编码新字体族，
  不在选定字体上合成字重，也不把所有标签强制成同字号、同字重；尺寸与强调由控件规范决定。
- 项目首字母使用项目头像徽标（原版源码：
  [ProjectIdentityAppearance.swift](https://github.com/1lck/Lithe-IDEA/blob/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/macos/Sources/Lithe/Views/Workspace/ProjectIdentityAppearance.swift)），
  遵循 IDEA `AvatarUtils` New UI 的 Mono DemiBold，不改为普通 UI 粗体。
- 系统窗口装饰和系统对话框保留平台字体。编辑器字体在加载后重新测量。
  字体不在运行时下载，也不写入发行包内的资源目录。
- 产品滚动条使用共享滚动条样式（原版源码：
  [LitheScrollViewChrome.swift](https://github.com/1lck/Lithe-IDEA/blob/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/macos/Sources/Lithe/Views/Components/LitheScrollViewChrome.swift)）。
  Viva 的滚动条几何由 `desktop/internal/uistyle/uistyle.go` 的 `Bars` 统一提供。
  Diff 使用编辑器角色的滚动条。调用方保留滚动动作与比例，不另定滑块或轨道颜色。
  修改共享实现前，读取
  `.agents/notes/archived/feature/2026-10-02-macos-shared-scrollbar.md`，区分编辑器覆盖与普通产品颜色。

## 验证范围

修改共享实现前，检查已有调用方，选择受影响的界面行为测试，并覆盖深浅色主题。
在 `desktop/` 下运行受影响包的 Go 测试；不为局部改动运行无关的全量构建。

不得通过增加覆盖检查的豁免来过关，也不得因为组件测试通过就宣称整个工作台视觉验收完成。
