# Agent 笔记：macOS 下拉菜单只保留 Project 的共享样式

状态：已实现

## 先说结论

Project 标题下拉框是 macOS 操作菜单的唯一视觉基准。Git Log 设置、Terminal、欢迎页和右键菜单均使用同一个菜单呈现器（负责弹窗定位、键盘操作和关闭的组件），不再允许调用方选择另一套外观。设置页选择控件仍保留选择值、定位和关闭的交互逻辑，但复用相同外框和尺寸定义。

## 问题

`LitheContextMenuPresenter` 原先通过 `settingsStyle` 在两套背景、边框、行高和文字尺寸之间切换。Git Log 设置按钮虽然接入了共享组件，实际使用的仍是另一套样式，因此看起来与 Project 不一致。

## 决策

- 删除 `settingsStyle` 参数和所有外观分支，以 Project 的 8pt 外框圆角、1pt 内描边、24pt 行高、12.5pt 文字、6pt 外留白和 8pt 行内边距为准。
- `litheContextMenuSurface` 统一绘制下拉外框并裁剪内部内容，防止搜索栏或其他不透明背景覆盖圆角；`LitheDropdownMetrics` 统一保存菜单行尺寸，`LitheDropdownRowStyle` 统一绘制操作菜单与 Git Log 可搜索下拉列表的行背景和内边距，设置选择弹窗直接复用这两处定义。
- 图标、勾选、快捷键和子菜单属于菜单内容。按内容预留必要空间，不用它们切换外观；纯文字的 Project 菜单保留原先无图标栏的布局。
- Branch、User、Paths 的可搜索内容也由 `LitheContextMenuPresenter` 的透明无边框面板承载，去掉 `NSPopover` 自带的系统外框；内容变化时保持同一面板并更新尺寸，Esc、点击外部与切换菜单共用关闭逻辑。
- Git Log 筛选弹窗的原生锚点只负责定位，`hitTest` 返回空，避免覆盖底层按钮的 hover 和点击。
- Branch、User、Date、Paths 都按触发按钮左下角定位。Date 原先按点击坐标弹出，造成同一按钮点击不同位置时菜单偏移；现在也使用同一个原生锚点，并保留操作菜单的键盘导航、选中勾与关闭回调。右键菜单仍以点击位置定位。
- 产品下拉框直接显示透明面板，`animationBehavior = .none`，不使用 SwiftUI `Menu`、菜单式 `Picker` 或系统 `NSPopover` 的弹跳展开，也不添加缩放或弹簧过渡。新增或修改产品下拉框时必须走共享组件；AI 的强制入口规则位于 `develop-lithe` Skill。
- 调用方只提交条目、动作、可用条件和定位信息。例如 Git Log 设置调用 `show(items:at:appearance:locale:)`；不要重新增加样式布尔值或局部绘制另一套菜单。

## 考虑过的备选方案

仅让 Git Log 传入 `settingsStyle: true` 可以修复当前截图，但会继续保留两个外观，其他调用方仍可能选错，因此删除分支。将设置选择控件的交互也替换成操作菜单会丢失当前选中值、选项刷新和锚点定位行为；本次共享视觉实现，保留它的交互职责。

## 后果

共享菜单的外观只需要修改一处；原来的普通操作菜单和右键子菜单也会采用 Project 的紧凑行高。带图标的条目仍按需显示，菜单宽度按实际内容留白计算，长菜单继续滚动并限制在屏幕内。安装原生视图宿主后显式恢复计算好的弹窗尺寸，避免首次显示时暂时使用零尺寸。

Git Log 四个筛选、Project 与设置选择器已经共享外框和尺寸，但设置选择器保留值选择的键盘和关闭职责。Debug、Database、Agent 等其他模块仍有历史内置 `Menu`；本次没有把这些入口全部迁移，不能将局部共享描述为全项目已经迁移完成。系统应用菜单、编辑器补全与悬停文档也不属于产品下拉框。

## 验证

- `ContextMenuCoverageTests.projectAndActionDropdownsRenderTheSameChrome` 捕获真实原生菜单面板，检查 Project 与设置菜单在明暗主题下的背景、边框和高度。
- `ContextMenuCoverageTests` 验证键盘跳过禁用条目、子菜单导航、长菜单可见范围和动作调用；`filterPopoverAnchorLeavesMouseEventsToItsButton` 验证定位锚点不截获按钮的鼠标命中。
- `ContextMenuCoverageTests.searchableFilterContentCannotCoverSharedRoundedCorners` 在明暗主题渲染真实 Branch/User 内容，检查四个圆角透明、内部仍为不透明底色。
- `ContextMenuCoverageTests.searchableDropdownUsesSharedWindowAndDismissal` 验证可搜索面板的透明无边框窗口、动态尺寸、Esc 关闭与关闭回调只执行一次。
- `ContextMenuCoverageTests.anchoredActionAndSearchableDropdownsShareTopLeft` 验证相同锚点下 Date 操作菜单与可搜索内容的左上角一致、无动画、键盘关闭回调及屏幕边界限制。
- `SettingsSelectPopupGeometryTests` 验证设置选择控件定位边界。
- 执行 `./scripts/verify-agent-notes.sh`、`./scripts/verify-service-boundaries.sh`、`./scripts/verify-runtime-bundle-immutability.sh` 和 `./scripts/verify-platform-feature-matrix.sh`。
- 按用户要求不启动预览；最终鼠标视觉对比仍需在当前开发版本中确认。

## 适用范围

- `macos/Sources/Lithe/Views/Components/LitheContextMenu.swift`
- `macos/Sources/Lithe/Views/Components/LitheSettingsControls.swift`
- `macos/Sources/Lithe/Theme/LitheTheme.swift`
- `macos/Sources/Lithe/Views/Workspace/ProjectSidebarView.swift`
- `macos/Sources/Lithe/Views/Git/GitLogView.swift`
- `macos/Sources/Lithe/Views/Git/GitLogFilterPopover.swift`
- `macos/Sources/Lithe/Views/Terminal/TerminalView.swift`
- `macos/Sources/Lithe/Views/App/WelcomeView.swift`
