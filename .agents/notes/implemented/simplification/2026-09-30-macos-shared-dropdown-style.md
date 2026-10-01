# Agent 笔记：macOS 下拉菜单只保留 Project 的共享样式

状态：已实现

## 先说结论

项目侧边栏的 Project/Dependencies 标题下拉框，与 Git Log Branch/User/Date/Paths、设置窗口下拉框共同使用的样式，是 macOS 产品下拉框的唯一视觉基准。Git Log 设置、Terminal、欢迎页和右键菜单均使用同一个菜单呈现器（负责弹窗定位、键盘操作和关闭的组件），不再允许调用方选择另一套外观。设置页选择控件仍保留选择值、定位和关闭的交互逻辑，但复用相同外框和尺寸定义。

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

- 为 Monaco 复制一份相同 CSS：拒绝，因为网页和原生菜单会各自持有圆角、行高和颜色，后续共享样式修改无法自动覆盖编辑区。
- 按 IDEA 手写菜单动作：拒绝，因为会绕过 Monaco 的条件和命令，并引入 Lithe 没有的功能。

仅让 Git Log 传入 `settingsStyle: true` 可以修复当前截图，但会继续保留两个外观，其他调用方仍可能选错，因此删除分支。将设置选择控件的交互也替换成操作菜单会丢失当前选中值、选项刷新和锚点定位行为；本次共享视觉实现，保留它的交互职责。

## 后果

Monaco 的动作系统保留原有语义，macOS 菜单外观只有一个持有者。代价是渲染挂钩依赖已锁定的 Monaco 0.55.1 内部 `contextMenuHandler` 入口；升级版本必须运行真实 WebKit 回归，不能静默恢复网页菜单。

共享菜单的外观只需要修改一处；原来的普通操作菜单和右键子菜单也会采用 Project 的紧凑行高。带图标的条目仍按需显示，菜单宽度按实际内容留白计算，长菜单继续滚动并限制在屏幕内。安装原生视图宿主后显式恢复计算好的弹窗尺寸，避免首次显示时暂时使用零尺寸。

视觉基准明确指 Git Log 的 Branch/User/Date/Paths、设置窗口和项目侧边栏 Project/Dependencies 共同使用的样式；顶部项目切换器是消费者，不能拿它原有的箭头气泡与圆角当基准。

SwiftUI 产品菜单已迁移：操作列表经 `LitheDropdown.swift` 的 `LitheMenu` 提交给同一个 `LitheContextMenuPresenter`；自定义搜索、选择及表单内容经 `litheDropdown` / `LitheDropdownPopover` 使用相同面板与 `litheContextMenuSurface`。设置选值仍用 `LitheSettingsSelect`，保留值选择的键盘和关闭职责，共用相同外框与尺寸。Debug 会话/线程/作用域/断点，Database 类型/排序/SQL/数据工具，Agent 切换/历史/供应商/模式/模型，以及 Git、GitHub、Search、编码选择、欢迎页和快捷键菜单都不再依赖系统菜单展开。

面板内打开另一个动作菜单或 `LitheSettingsSelect` 选值下拉框时，使用当前面板的原生子窗口关系。父面板不因焦点移到可见子面板而关闭；父事件监视器不拦截子面板的键盘，不把子面板内的点击当作外部点击。每个锚点持有自己的呈现器，移出窗口或卸载时关闭面板并清理事件监视器。自定义内容完整继承原视图环境，包括语言、颜色模式、环境对象、项目窗口范围与主题。

Monaco 编辑区右键菜单由网页内部渲染，原来的 SwiftUI 菜单扫描无法覆盖这个入口。macOS 现在通过 `macos/EditorFrontend/context-menu.ts` 的 `installNativeContextMenu` 替换 Monaco 0.55.1 的菜单渲染器，把已生成的条目交给 `MonacoEditorContextMenu` 和共享 `LitheContextMenuPresenter`。Monaco 仍然负责上下文条件、分组顺序、快捷键和动作执行；这里只传菜单展示信息与选中条目，不调用 Rust 或新增 IDEA 独有动作。取消、替换与卸载必须结束原来的菜单回调，旧响应不得执行动作。

图标以 IDEA 的动作定义 `Presentation.icon` 和 `PlatformIconMappings.json` 为依据。剪切、复制、粘贴、格式化及已有 Run/Debug 动作使用已确认的官方 SVG；跳转、重命名、更改所有匹配与命令面板保留空图标位。图标显示为原始 16pt，保留 SVG 路径、描边、原色和明暗资源，禁用透明度由共享行处理。不能按菜单文字猜图标或用 SF Symbols 补齐空位。

同一操作菜单的子菜单必须跟随触发行的可见位置，不能与父菜单顶部对齐。
共享呈现器读取父菜单行的实际几何位置，因此分隔线和父菜单滚动都会参与定位；
打开、关闭或切换子菜单时固定主菜单位置，仅在屏幕边缘限制子菜单偏移，长子菜单
继续滚动。菜单标题直接测量相同字体与语言的 SwiftUI 文字布局，避免小数字号下原生
字宽与实际绘制宽度不同而截断 `Copy Relative Path`；菜单行间距显式计算，
并为快捷键、勾选和箭头按实际布局留足宽度。

顶部项目/分支按钮只使用普通悬停背景，菜单打开状态不作为按钮选中状态。系统应用菜单、系统对话框、编辑器补全与悬停文档保留原生职责；显式 segmented 的原生 Picker 没有下拉框，也不属于本次迁移。

## 顶部项目和分支菜单的尺寸与内容

对照 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade`：
`ProjectToolbarWidgetAction` 通过 `ListPopupImpl` 按 renderer 的内容尺寸布局，
没有统一固定为 390pt；`GitBranchesPopupBase` 新 UI 的最小宽度是 375pt，
并允许 IDEA 自身保存用户调整后的大小。因此两个菜单不要求一样宽。
Lithe 的项目菜单按本地化命令、项目名称与显示路径测量，复用
`LitheContextMenuPresenter.menuWidth` 和 `LitheDropdownMetrics` 的宽度边界；
360pt 上限是 Lithe 现有共享规则，不宣称是 IDEA 的固定宽度。
分支菜单的 375pt 基准也集中在 `LitheDropdownMetrics` 中。

`ExpandableComboAction.showUnderneathOf` 按完整工具栏控件的下缘定位；
`ToolbarComboButtonUI`/`JBUI.CurrentTheme.MainToolbar.Dropdown` 把 margin
计入控件尺寸。Lithe 将顶部两个菜单的原生锚点放到现有 40pt 工具栏槽位，
内部项目按钮 30pt、分支按钮 32pt，按钮下方分别自然留出 5pt、4pt。
这不是给所有菜单增加偏移；Git Log 四个筛选和设置选择的锚点保持原有规则。

项目徽标对照 `RecentProjectIconHelper.unscaledProjectIconSize` 缩到 20pt，
名称用 13pt 常规字重，路径按 `JBFont.smallOrNewUiMedium` 使用 12pt。
行内间距为 8pt；当前项目保持激活动作，不再被持续染成蓝色或显示额外勾选。
项目颜色与名称徽标复用 `ProjectAvatarBadge`，不复制 JetBrains 产品标志。

分支搜索使用 Git Log 已有的 `LitheSearchTextField` + `litheSearchField`，
因此继承输入法占位文本、hover I-beam、背景和焦点边框修复。
项目命令、分支命令、分支/命名空间列表用 `LitheDropdownRowStyle`，
沿用同一 24pt 行高、8pt 行内边距、6pt 弹窗留白和蓝色 hover。
图标使用官方 16pt 明暗 SVG 原色，不用 SF Symbols 加粗或重绘；
Checkout Tag or Revision 没有图标，只留对齐位置。
快捷键/上游提示采用与行文字一致的常规字号及次要文本颜色，
不再单独缩成 11.5pt。共享行样式同时提供主、次文字颜色，分支快捷键与上游提示
按层级读取颜色，选中/hover 时与行文字一起变亮。当前分支用 `GitBranchesTreeIconProvider` 对应的
`dvcs/currentBranchLabel.svg`，没有依据当前状态虚构“收藏”。
现有两个分支搜索栏动作仍执行各自原来的回调，没有新增 IDEA 的 fetch/resize 功能。

## 验证

- `MonacoEditorContextMenuTests` 检查真实原生菜单面板在明暗主题下的共享尺寸、无动画、禁用跳过、选中/取消回复、官方 SVG 的 16×16 尺寸与资源可解析性，以及非法展示数据拒绝。
- `./scripts/probe-macos-monaco.sh --workbench-tests` 使用正式 macOS 前端入口，验证真实 Monaco 菜单经过原生桥接而不产生网页菜单，同时保留既有菜单事件。`context-menu.integration.ts` 验证动态条目、分组、快捷键、实例前缀映射、动作上下文、原 action runner、取消/失败/替换和卸载后的旧响应。

- `ContextMenuCoverageTests.contextMenusCannotSilentlyBypassSharedStyle` 阻止产品重新使用 SwiftUI `Menu`、`.popover`、`NSPopUpButton` 或非 segmented 的原生 `Picker`。
- `nestedDropdownKeepsParentAndRoutesKeysToChild` 验证子菜单不关闭父面板、按键只选择子菜单动作、两层独立关闭。
- `sharedContentInheritsEnvironmentAndClosesWhenAnchorDetaches` 验证真实宿主继承环境对象和语言，锚点移出窗口立即关闭并清理。
- `itemBuilderKeepsConditionalActionsDisabledChoicesAndSubmenus` 验证条件、动态条目、勾选、禁用、子菜单及危险动作类型保留。
- `WorkbenchRenderingSafetyTests` 检查项目/分支使用共享入口，菜单打开状态不会染色原按钮。

- `ContextMenuCoverageTests.projectPopupMeasuresContentInsteadOfKeepingA390PointWidth` 检查短路径自然宽度与长路径共享上限。
- `ContextMenuCoverageTests.topbarDropdownsLeaveToolbarMarginAndRenderRealSharedContent` 渲染真实项目/分支菜单的明暗原生窗口，检查锚点槽位、无动画、宽度限制、卸载关闭，并可保存捕获图。
- `ContextMenuCoverageTests.projectAndActionDropdownsRenderTheSameChrome` 捕获真实原生菜单面板，检查 Project 与设置菜单在明暗主题下的背景、边框和高度。
- `ContextMenuCoverageTests.submenuStartsAtItsTriggerRowAndKeepsCopyTitlesVisible` 捕获真实明暗菜单，验证靠下的触发行、子菜单上方透明区、主菜单位置固定及完整复制标题的宽度。
- `ContextMenuCoverageTests` 验证键盘跳过禁用条目、子菜单导航、长菜单可见范围和动作调用；`filterPopoverAnchorLeavesMouseEventsToItsButton` 验证定位锚点不截获按钮的鼠标命中。
- `ContextMenuCoverageTests.searchableFilterContentCannotCoverSharedRoundedCorners` 在明暗主题渲染真实 Branch/User 内容，检查四个圆角透明、内部仍为不透明底色。
- `ContextMenuCoverageTests.searchableDropdownUsesSharedWindowAndDismissal` 验证可搜索面板的透明无边框窗口、动态尺寸、Esc 关闭与关闭回调只执行一次。
- `ContextMenuCoverageTests.anchoredActionAndSearchableDropdownsShareTopLeft` 验证相同锚点下 Date 操作菜单与可搜索内容的左上角一致、无动画、键盘关闭回调及屏幕边界限制。
- `SettingsSelectPopupGeometryTests` 验证设置选择控件定位边界；真实父/子面板验证 Database 一类表单弹窗内打开选值菜单时保留父面板，Esc 只关闭子菜单并解除窗口关系。
- 执行 `./scripts/verify-agent-notes.sh`、`./scripts/verify-service-boundaries.sh`、`./scripts/verify-runtime-bundle-immutability.sh` 和 `./scripts/verify-platform-feature-matrix.sh`。
- 按用户要求不启动预览；最终鼠标视觉对比仍需在当前开发版本中确认。

## 适用范围

- `macos/Sources/Lithe/Views/Components/LitheDropdown.swift`
- `macos/Sources/Lithe/Views/Components/LitheContextMenu.swift`
- `macos/Sources/Lithe/Views/Components/LitheSettingsControls.swift`
- `macos/Sources/Lithe/Theme/LitheTheme.swift`
- `macos/Sources/Lithe/Views/Workspace/ProjectSidebarView.swift`
- `macos/Sources/Lithe/Views/Workspace/ProjectSwitcherPopover.swift`
- `macos/Sources/Lithe/Views/Git/BranchSwitcherPopover.swift`
- `macos/Sources/Lithe/Views/Workbench/WorkbenchView.swift`
- `macos/Sources/Lithe/Views/Git/GitLogView.swift`
- `macos/Sources/Lithe/Views/Git/GitLogFilterPopover.swift`
- `macos/Sources/Lithe/Views/Terminal/TerminalView.swift`
- `macos/Sources/Lithe/Views/App/WelcomeView.swift`

- `macos/EditorFrontend/context-menu.ts`
- `macos/Sources/Lithe/Views/Editor/MonacoEditorContextMenu.swift`
