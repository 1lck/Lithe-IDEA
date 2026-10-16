# Agent 笔记：工具窗口停靠与布局保存

状态：已实现

## 先说结论

macOS 的工具窗口位置由工作台维护，功能模块继续维护自己的内容、连接和会话。
用户可以移动入口、调整组内顺序，并在左侧、右侧和底部的两个分组中分别打开窗口。
模块默认位置与用户保存的位置分开处理；本次不开放第三方插件 UI 注册或独立浮动窗口。编辑器标签分屏另由编辑分组维护，见同目录的编辑器标签分屏 Note。

## 问题

旧工作台把 Maven 和 Agent 固定在右侧，其余工具放到底部，导航侧栏另有一套状态。
只移动图标不能改变实际内容位置，标题栏收起还可能关闭最后选中的侧栏。

## 决策

位置包含停靠边缘及主、次分组。一个分组只显示一个窗口，其他分组保持独立。
内置窗口使用稳定标识，位置与顺序由 `WorkbenchFeatureModel` 管理；已有模块注册表负责动作和内容查找。
左侧栏下部保留原底部窗口入口，右侧栏下部承载底部第二组入口。拖到工作区边缘或使用入口右键菜单，明确选择实际停靠分组。

本次依据 IDEA Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade`：

- [WindowInfoImpl.kt](https://github.com/JetBrains/intellij-community/blob/c7f91397daa3a961b4e78bc634fe467a0a7d9ade/platform/platform-impl/src/com/intellij/openapi/wm/impl/WindowInfoImpl.kt) 的 anchor、isSplit、order 和 isVisible 分开表示位置与展开状态。
- [ToolWindowManagerImpl.kt](https://github.com/JetBrains/intellij-community/blob/c7f91397daa3a961b4e78bc634fe467a0a7d9ade/platform/platform-impl/src/com/intellij/openapi/wm/impl/ToolWindowManagerImpl.kt) 的 setSideToolAndAnchor 在布局所有者处提交位置与分组。
- [ToolWindowDragHelper.kt](https://github.com/JetBrains/intellij-community/blob/c7f91397daa3a961b4e78bc634fe467a0a7d9ade/platform/platform-impl/src/com/intellij/toolWindow/ToolWindowDragHelper.kt) 将拖动预览与最终提交分开。
- [ManyIslandsDark.theme.json](https://github.com/JetBrains/intellij-community/blob/c7f91397daa3a961b4e78bc634fe467a0a7d9ade/platform/platform-resources/src/themes/islands/ManyIslandsDark.theme.json) 与同目录 Light 主题的 ToolWindow.DragAndDrop.areaBackground 为深色 #366ACF4D、浅色 #A0BDF84D；入口提示使用 Button.DragAndDrop.buttonDropBackground 的 #3671E580 / #3671E540。保留已有 37×40pt 槽位、30pt 按钮与 20pt IDEA 图标。

拖动复用编辑器标签的原生浮动预览方式：AppKit 捕获当前入口一次，非激活面板只跟随鼠标移动，工具状态与落点预览留在当前视图。入口按固定窗口坐标记录；拖动源的槽位高度归零，后续按钮立即补齐，但接收鼠标事件的原生视图保留到松开或取消。按钮命中使用补齐后的可见矩形；鼠标在蓝色插入槽的纵向范围内时保留当前目标；这同样适用于鼠标已水平移入内容区的情况，避免占位推动按钮后反复换目标。侧栏插入槽与内容区落点分别显示，空分组也保留落点槽。
按 IDEA createStripeButtonDragImage 的顺序，先绘制浮动图标，再隐藏原入口。拖动预览单独使用已有 IDEA SVG、普通图标前景色和浮动按钮外框，不截取源按钮的选中或悬停底色。Community `SquareStripeButtonLook.paintDraggingButton` → `IdeaActionButtonLook` 分别绘制背景、图标和同色 1pt 圆角边框；Islands `ToolWindow.DragAndDrop.buttonFloatingBackground` 为深色 #40434A / 浅色 #DDDFE4。普通灰色浮动背景与激活蓝底是不同状态，不能为去掉蓝底而删除全部按钮表面。拖动覆盖层仅通过鼠标事件监听处理按下与拖动，命中测试透传，保留原按钮 hover 底色和提示。像素回归检查浮动图标内容及透明边角，不能只检查面板存在。
工具入口按 `bounds.intersection(visibleRect)` 处理按下与非拖动释放，隐藏祖先不参与命中；拖动开始快照也只记录裁剪后的可见矩形，滚出 280pt 视口的图标不能截获另一组点击或成为插入落点。
鼠标经过落点时不写业务位置；松开后原子移动并保存。Esc、无效落点、失去应用激活状态和卸载清理预览，窗口外释放不创建浮动窗口；Esc 后同次按住不能重新开始拖动。

落点与蓝色遮罩共用一次拖动开始时捕获的真实面板和编辑区矩形。
依据同一 revision 的 `ToolWindowDropArea.kt`、`ToolWindowToolbar.kt` 和
`ToolWindowDragHelper.kt`：有可见面板时优先用它的完整边界；已有双组时用各组的实际尺寸，
只有单组时才按目标方向二分。底部面板左右二分保留原高度，侧面板上下二分保留原宽度，
不能用整个工作区三分之一代替实际面板，也不能用全窗口中线判定侧面分组。
侧面尚无面板时沿编辑区高度扩展，底部尚无面板时采用 `max(200, paneHeight / 4)`；
侧宽使用已有工作台尺寸，未提供时沿用 Community 默认 350pt。
落点重叠时优先拖动源停靠边，确保从底部入口水平移入底部内容区仍预测 Bottom Left/Right；
直接指向其他侧栏按钮时仍以该按钮的分组和插入位置为准。
所有矩形记录是视图本地状态，连续拖动不发布布局业务状态，也不写设置。
卸载锚点时仅注销同一视图拥有的记录，避免旧视图清掉新布局的几何数据。

布局按工作区通过已有设置存储保存，旧数据缺少新字段时保留尺寸并采用默认位置。
恢复时忽略未知或重复窗口标识，纠正负顺序和同组多个可见窗口；不把缓存写到应用包内。
展开状态恢复后先等待旧模块图退出，再通过既有激活入口恢复所需内容；模块依赖的 renderer 使用已有 featureIdentity 区分加载占位与真实功能对象，防止内容比较把就绪状态缓存成占位。

主工具栏最右侧的设置齿轮复用现有 IDEA settings SVG、共享动作菜单和设置分类。按同一 Community revision 的 `MainToolbar.kt` 右侧分组、`intellij.platform.ide.impl.actions.xml` 的 `SettingsEntryPoint` 动作定义定位入口；仅提供用户要求的设置/插件与主题/快捷键两区，用一条分隔线区分。点击齿轮先打开菜单，主题进入现有通用设置的主题配置，不新增一套主题状态或系统弹窗；当前 Keymap 生成设置快捷键提示。齿轮沿用右侧活动栏宽度并居中，主工具栏末端不另加右内边距，保证它和通知、数据库入口共用竖直中心线；移除右侧重复插件入口，插件仍可从齿轮菜单进入。

运行配置/运行/调试仍在右侧区域，但与末端设置菜单分开布局。Community `MainToolbar.kt` 和 `resources/idea/PlatformActions.xml` 分开维护主工具栏的组；参考截图的运行组之后还有更多与搜索等操作。Lithe 当前动作数量更少，使用最多四个工具栏高度的可收缩留白补足视觉间距，窄窗口收缩留白，设置仍与活动栏对齐。这是当前产品对参考布局的适配值，不是 IDEA 源码规定的固定间距；如果后续加入右端动作，应以真实动作宽度替换预留空间，避免重复留白。

组内分隔复用 `LitheSplitPaneView`，高频尺寸留在局部容器，只在结束时保存比例。
松开后继续显示最终局部尺寸，直到父布局传回新的默认尺寸才交回控制，避免先回到旧尺寸再跳到新尺寸。保存比例允许完整的 0～1 范围，实际最小面板尺寸由分隔容器按当前可用空间约束；不能在保存时再限制到 10%～90%，否则合法的窄面板会在松开和重启时变大。
每个可见分组分别使用现有工作台面板背景和圆角；圆角不能包在整个停靠边缘外层，否则 Project 与下方 Terminal 会连成一个面板。组间保留工作台间距，不绘制额外亮线；背景图片和窗口渐变继续使用原样式入口。深浅主题的原生像素回归覆盖左、右、底部两个分组的间距及相邻圆角。

正确做法：Terminal 移到左侧第二组后，打开它只替换该组的活动窗口；原右侧 Agent 和底部 Run 保持各自状态。
不要这样做：给 Terminal 内容重新创建连接，或在每次鼠标移动时写入位置和设置。

## 考虑过的备选方案

- 只对图标添加拖动：无法改变窗口实际位置，旧固定分配仍会把内容送回原区域。
- 直接引入 IDEA Swing 容器：与当前 SwiftUI/AppKit 和 React/Tauri 技术栈不同，需要更换整个呈现层。本次参照其状态和提交边界，复用本仓库原生分隔容器。
- 同时开放插件 UI 和编辑器分屏：涉及外部代码契约、编辑器文档及视图生命周期，独立 PR 更容易验证。

## 后果

收益是现有内容可以在不同区域显示，位置、顺序与尺寸可以重启恢复。
代价是新增内置工具窗口必须提供稳定标识和默认布局；Windows 尚未同步此次移动能力，功能矩阵明确记录差距。
移动可能重建原生呈现容器，但功能状态仍归原模块所有；终端与编辑器等原生资源必须继续遵守既有挂载生命周期。

## 验证

- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`
- `./scripts/test-macos.sh --filter 'ToolWindowDockingTests|WorkbenchFeatureModelTests|WorkbenchMavenLayoutTests'`
- `./scripts/verify-service-boundaries.sh`
- `./scripts/verify-runtime-bundle-immutability.sh`
- `./scripts/verify-platform-feature-matrix.sh`
- `./scripts/verify-agent-notes.sh`
- `LitheSplitPaneCollapseTests.releaseWaitsForCommittedSize` 使用原生按下、拖动、松开事件，故意延迟父布局回传，检查松开后的最终尺寸、回传后继续跟随父布局及内容不重新挂载；`ToolWindowDockingTests.narrowGroupFractionSurvivesCommitAndReload` 检查窄面板比例保存和恢复。
- 实际工作台检查跨边缘移动、同组排序、双组打开、收起正确窗口、Esc/窗口外取消、窄窗口及重启恢复；模型检查不能替代原生拖放验收。

## 适用范围

- `macos/Sources/Lithe/Application/Features/WorkbenchFeatureModel.swift`
- `macos/Sources/Lithe/Services/Workbench/WorkbenchLayoutStore.swift`
- `macos/Sources/Lithe/Views/Workbench/`
- `macos/Tests/LitheTests/ToolWindowDockingTests.swift`

拖动回归补充：`ToolWindowDockingTests.horizontalDragUsesTheBottomPanelHeightAndActualSplitBounds`
覆盖底部平移、编辑区排除、遮罩保持实际高度及不等宽双组；
`insertionSlotRetainsItsTargetWhileButtonsReflow` 覆盖插入槽目标稳定；
`draggedStripeEntryClosesItsSlotWithoutUnmountingTheMouseOwner` 使用真实 SwiftUI 按钮样式和
原生拖动接收视图，检查源槽位消失、相邻按钮补齐、原接收者身份保留及取消后恢复。
组件回归不能代替完整工作台的实际拖动、松开和 Esc 验收。

侧栏插入顺序进一步按同一 revision 的
`platform/platform-impl/src/com/intellij/openapi/wm/impl/AbstractDroppableStripe.kt`
移植：`processDropButton` 把内容区鼠标投影到侧栏主轴，`recomputeBounds` 按每个可见按钮的中点
选择插入索引。Lithe 的 AppKit Y 轴朝上，因此按 Y 从大到小遍历，同一套中点判定同时用于
直接经过侧栏和进入内容区的拖动；不能在内容区只计算停靠边缘后将 `before` 固定成 `nil`，
否则水平拖出中间按钮会把蓝色占位强制追加到组末尾。
`ToolWindowDockingTests.horizontalContentDragProjectsInsertionOrderInsteadOfAppending` 覆盖此复现：
从四个按钮中的第二个水平拖入内容区，保留中间插槽；纵向越过按钮中点后才改变顺序，
真正低于全部按钮时才追加到末尾。Swift 继续用既有稳定窗口 ID 表示插入点，不复制 Java 的
Swing 容器或另建一份持久化顺序。
