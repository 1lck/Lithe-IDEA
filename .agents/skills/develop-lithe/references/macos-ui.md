# macOS 共享控件规范

适用于 macOS 界面、共享控件及视觉交互改动；通用架构、i18n、设置和连续列表规则见
[Lithe 开发规范](../SKILL.md)。本页路径均相对于仓库根目录。

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

| 用途 | 入口 | 所属源码 |
| --- | --- | --- |
| 动作下拉、勾选动作、开关与子菜单 | `LitheMenu` | `macos/Sources/Lithe/Views/Components/LitheDropdown.swift` |
| 产品原生右键菜单 | `litheContextMenu` / `LitheContextMenuPresenter` | `macos/Sources/Lithe/Views/Components/LitheContextMenu.swift` |
| 可搜索选择器与自定义弹层内容 | `litheDropdown(isPresented:opensUpward:content:)` / `LitheDropdownPopover` | `macos/Sources/Lithe/Views/Components/LitheDropdown.swift` |
| 值选择（含设置表单） | `LitheSettingsSelect` | `macos/Sources/Lithe/Views/Components/LitheSettingsControls.swift` |
| 动作/自定义下拉窗口、定位与关闭 | `LitheContextMenuPresenter` | `macos/Sources/Lithe/Views/Components/LitheContextMenu.swift` |
| 值选择弹窗与键盘选择 | 私有 `LitheSettingsSelectPopupPresenter`，仅通过 `LitheSettingsSelect` 使用 | `macos/Sources/Lithe/Views/Components/LitheSettingsControls.swift` |
| Monaco/WebKit 编辑器右键菜单（仅上游已解析动作） | `installNativeContextMenu` -> `MonacoEditorContextMenu` -> `LitheContextMenuPresenter` | `macos/EditorFrontend/context-menu.ts` / `macos/Sources/Lithe/Views/Editor/MonacoEditorContextMenu.swift` |
| 共享行尺寸与高亮 | `LitheDropdownMetrics` / `LitheDropdownRowStyle` | `macos/Sources/Lithe/Views/Components/LitheContextMenu.swift` |
| 共享外层背景、8pt 圆角、边框与裁剪 | `litheContextMenuSurface` | `macos/Sources/Lithe/Theme/LitheTheme.swift` |

### 呈现、锚点与宽度

- 新增或修改产品下拉时，禁止使用 SwiftUI `Menu`、`.menu` 样式的 `Picker`、SwiftUI `.popover`、
  `NSPopover` 或 `NSPopUpButton` 呈现。共享面板设置 `animationBehavior = .none`，
  直接打开，不加系统弹出/弹跳、spring 或 scale 过渡。
- 工具栏下拉锚定触发控件左下角，不跟随指针；保留屏幕边缘夹取、键盘导航、选中态、外部点击关闭与焦点行为。
- 主工具栏 Project/Branch 锚定完整工具栏槽位，保留按钮绘制区域下方既有间距。
  宽度使用 `LitheDropdownMetrics`：Project 测量内容，Branch 使用 Community New UI 的 375pt 基线。
  不复制顶部项目切换器旧固定宽度，不再造搜索框；搜索使用完整 `LitheSearchField`，与 Git Log 一致。
- 宽度按角色决定，不全局强制相同。动作菜单由 presenter 测量本地化标题、图标、快捷键与勾选位；
  设置选择器保留共享触发器/内容测量，不在业务调用处加魔法宽度或偏移。
- 子菜单跟随实际可见触发行，包括滚动与分隔项；屏幕边缘修正只由共享 presenter 处理。
- Project/Branch 弹层打开时，通过 `litheRowHover` 与 `activeBackground: LitheTheme.hoverBackground`
  保留正常悬停背景；不改成蓝色选中态或新增按下色，关闭后解除保留状态。此规则不改变菜单行勾选/选中样式。

### Monaco 菜单与例外边界

- Monaco 编辑器菜单同样走原生共享 presenter；保留上游已解析动作、顺序、context key、禁用态、快捷键与 action runner。
  不杜撰 IDEA 独有功能，不在 Web CSS 复制共享样式。
- 仅用已映射的 IDEA SVG，保持原始 16pt、原色及深浅色资源；动作没有指定图标时保留空图标槽。
- macOS 适配器在固定的 Monaco 0.55.1 完成上游菜单解析后挂钩渲染器；修改挂钩或升级 Monaco 时验证真实 WebKit probe。
- SwiftUI 原生 `Picker` 只允许显式 `.segmented`、没有下拉的控件；`ContextMenuCoverageTests` 检查产品入口。
  系统对话框、macOS 应用菜单、编辑器补全/光标弹层和悬停文档属于独立交互，不被产品菜单规则替换。

## 搜索与输入

- 搜索使用完整 `LitheSearchField`（`macos/Sources/Lithe/Views/Components/LitheSearchField.swift`），
  包括外部 Bool/enum 焦点与语义 accessory。其内部原生编辑器和外观复用
  `LitheSearchTextField` / `litheSearchField`，普通调用方不自行拼配方。
- 多行 Agent 任务输入仍是独立编辑器，使用原生编辑原语及 `axis: .vertical`，不强换为搜索框。
- 普通单行、密码与多行表单使用 `macos/Sources/Lithe/Views/Components/LitheTextInput.swift` 的
  `LitheTextField`、`LitheTextEditor`，由它们拥有原生编辑、焦点、光标、外观与可选标签。
  `LitheFormField` 拥有标签间距和仅输入部分的禁用状态。
- 旧 `litheSettingsTextField` / `litheSettingsTextEditor` 配方及 `LitheSettingsSearchField` 入口已退役；
  既有专用表格、编辑器和提交对话框渲染器保留自身所有权。禁用字段或分组内的 `LitheInfoTip` 仍须可交互。
- 保留原生输入法组合及聚焦前的 I-beam 光标；高度、内边距、圆角、字体、占位符与焦点颜色读取共享尺寸。
  marked text 存在但 binding 尚为空时，不得恢复占位提示。
- 多行提交消息继续使用 `macos/Sources/Lithe/Views/Git/CommitMessageEditor.swift` 的 `CommitMessageEditor`，
  不用搜索框替换，不复制原生组合输入和撤销逻辑。

## 图标与工具窗口标题栏

- 图标使用 `macos/Sources/Lithe/Theme/LitheIcons.swift` 的 `LitheIDEAIcon` 及
  `macos/Resources/IDEAIcons` 中已批准的 SVG。保持原几何、描边/填充及深浅色变体，
  使用动作源码指定图标，不猜 SF Symbol、不另画替代品、不靠缩放/叠字模拟粗描边；没有指定图标的菜单动作留空槽。
- 普通工具窗口工具栏按钮使用 `LitheTheme.swift` 的 `litheToolbarIconButton` / `LitheIconButtonStyle`，
  保留禁用、悬停反馈与默认箭头光标。22pt 命中区不推广到所有按钮，
  主工具栏切换器等保留各自共享尺寸；指针与 I-beam 是明确的控件语义。
- 普通工具窗口标题栏使用 `LitheToolWindowHeader`，由其拥有当前 41pt 高度、13pt Bold 标题、
  外边距与动作间距。标题纯文本，不加标题图标、外框、底部分隔线或 `LitheToolWindowHeaderDivider`。
  真实会话标签栏保留标签语义，不把静态标题伪装成标签。

## 树、列表与选择

- 普通树和持久列表使用完整 `LitheTreeList`，源码为
  `macos/Sources/Lithe/Views/Components/LitheTreeList.swift`。
  调用方只提供稳定 row ID、选择、层级与业务动作；共享组件拥有边距、滚动、焦点观察/系统焦点效果抑制、
  悬停/选择绘制、键盘导航、范围选择和无障碍。递归业务树可提供 `LitheTreeListNode`，不实例化隐藏子项。
- 不在调用处拼 ScrollView/行样式/focus modifier。旧 `litheTreeRow`、`litheSelectionRow` 已退役；
  `LitheTreeListRowSurface` 只是内部渲染，不是业务入口。
- 原生视口使用 `LitheTreeList(native:)`，共享 `LitheTreeListAppearance` / `LitheTreeListNavigation` 策略。
  保留现有渲染器与虚拟化，不把原生树改成每行一个 SwiftUI 视图。
- Project 的 `LitheTreeListNativeInteraction` 保留拖拽/剪贴板与异步编辑器焦点所有权，
  选择/导航决策仍共享；保留 Project 可配置行高。其他行用 Tree 尺寸，多行列表保留内容几何。
- 选择变化与主点击/激活分开。键盘移动游标不得意外打开编辑器或运行任务。
  Search Everywhere 保留搜索输入驱动的焦点与分类快捷键；表格、提交图、菜单和编辑器补全保留自身所有权。
- 原生列表焦点来自 first responder 与 key window，不接受页面手传布尔值伪造焦点。
  验证相邻输入框、非活动窗口、深浅色、多选、键盘边界、上下文菜单目标、展开与滚动；
  运行 `LitheTreeListTests`、`LitheTreeRowStyleTests`、受影响原生回归及真实产品流程。
  源码覆盖测试禁止恢复已退役配方。
- 行选择不等于复选框纳入状态、设置值、状态 badge、活动栏按钮、菜单高亮、工具窗口标签或编辑器文字选择。
  它们保留所属样式，工具窗口标签使用 `LitheToolWindowTabStyle`；不为原本没有持久选择的视图擅自添加选择状态。
- 验证焦点移到相邻列表或编辑器、整窗失活/恢复、共享 field editor 转换、键盘导航及深浅色的聚焦/非聚焦行。
  运行相关原生焦点回归；组件测试通过不等于整个产品通过验收。

## 字体与滚动条

- 普通界面用 `uiFont` / `uiNSFont`，代码和已有等宽呈现用 `editorFont` / `codeFont` / 等宽 `uiFont`；
  统一由 `macos/Sources/Lithe/Theme/LitheTheme.swift` 拥有。
  使用已打包的真实字体变体（Inter 或 JetBrains Mono），不硬编码新字体族、不在选定字体上合成字重，
  也不把所有标签强制成同字号/字重；尺寸与强调由控件规范决定。
- 项目首字母使用 `macos/Sources/Lithe/Views/Workspace/ProjectIdentityAppearance.swift` 的
  `ProjectAvatarBadge`，遵循 IDEA `AvatarUtils` New UI 的 Mono DemiBold，不改为普通 UI Bold。
- 系统窗口装饰和系统对话框保留平台字体。Monaco 加载已有打包代码字体后重新测量，
  不在运行时下载或写入打包资源。
- 产品原生滚动条使用 `macos/Sources/Lithe/Views/Components/LitheScrollViewChrome.swift` 的
  `litheScrollViewChrome` -> `LitheScrollBarStyle`。
  Diff 通过 `DiffStripeScroller` / `LitheScrollBarPaint` 使用编辑器角色；调用方保留滚动动作和比例，
  不另定滑块/轨道颜色。修改共享实现前读取
  `.agents/notes/implemented/feature/2026-10-02-macos-shared-scrollbar.md`，区分编辑器覆盖与普通产品颜色。

## 验证范围

修改共享实现前检查已有调用方，选择受影响的原生外观/行为测试，并覆盖深浅色主题。
相关测试包括 `ContextMenuCoverageTests`、`SettingsSelectPopupGeometryTests`、
`LitheSearchFieldStyleTests`、`LitheTreeListTests`、`LitheTreeRowStyleTests`、
`BundledUIFontTests`、`WorkbenchRenderingSafetyTests` 及对应原生回归；不为局部改动跑无关全平台工作。

不得通过添加覆盖检查豁免过关，也不得因为组件测试通过就宣称整个工作台视觉验收完成。
