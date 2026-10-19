# Agent 笔记：macOS 下拉菜单只保留 Project 的共享样式

状态：已实现

## 先说结论

项目侧边栏的 Project/Dependencies 标题下拉框，与 Git Log Branch/User/Date/Paths、设置窗口下拉框共同使用的样式，是 macOS 产品下拉框的唯一视觉基准。Git Log 设置、Terminal、欢迎页和右键菜单均使用同一个菜单呈现器（负责弹窗定位、键盘操作和关闭的组件），不再允许调用方选择另一套外观。设置页选择控件仍保留选择值、定位和关闭的交互逻辑，但复用相同外框和尺寸定义。

Project/Dependencies 标题与 Terminal shell/动作入口同样使用 `LitheMenu` 的控件锚点；
不能退回读取 currentEvent 的鼠标位置或硬编码窗口偏移，否则键盘和点击按钮不同位置
会产生不同弹出位置。命令列表与空终端禁用状态保持原语义。

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

Monaco 的原生菜单选中经过异步 WebKit 消息回调，已经失去浏览器的用户手势授权。
复制、剪切、粘贴因此由 WKWebView 原生 responder 命令执行，继续触发 Monaco
自己的 DOM 剪贴板监听和撤销逻辑；返回 `handled` 后前端不能再次执行动作。
只处理 Monaco 已启用的对应菜单项，其余动作仍走原 action runner。测试必须
同时覆盖真实 WKWebView 的剪贴板内容与前端不重复执行，不能只检查命令 ID。

Commit/Shelf 页签的留白以同一 Community revision 的 `IslandsUICustomization.getTabLayoutStart`
和 `IslandsTabPainter.getHOffsetUnscaled` 为依据：布局起点 4，加绘制内缩 4，得到首项左侧 8；
相邻页签各内缩 4，得到可见外框间距 8。`ContentLabel` 的文字 inset 为 12，减去绘制内缩后
距可见选中框为 8。Lithe 在实际外框上布局，不能直接把 12 当作选中框内部留白。

共享 `LitheSettingsSelect` 的闭合框采用 Islands `ComboBox.nonEditableBackground`：
深色 `control-bg-raised` 为 `#26282C`，浅色为白色。原来的 `#393B40` 是 expUI 父主题值，
不能绕过 Islands 覆盖。`DarculaComboBoxBorder` 经 `DarculaNewUIUtil` 绘制普通 1pt、
焦点 2pt 边框；SwiftUI 选择器在展开或键盘聚焦时使用焦点描边。继承的 `Component.arc=8`
对应半径 4，控件高 28；其余设置输入框维持原有描边宽度。弹出列表布局不变。

### Stash / Shelf 浏览

沿用 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的
`platform/vcs-impl/src/com/intellij/openapi/vcs/changes/savedPatches/SavedPatchesUi.kt`
和 `plugins/git4idea/backend/src/stash/ui/GitStashContentProvider.kt`：上下分栏默认比例
0.5，下半区承载文件树和底部恢复动作。Lithe 使用现有 `LitheSplitPaneView`、
Git Log 原生文件树与 `RepositoryDiffView`，避免为保存记录建立第二套 Diff。
Stash 分隔条关闭已有 `highlightsOnHover` 开关，悬停和拖动均保持原色，保留拖动热区。
创建 Stash / Shelf 入口按用户要求放在中间工具栏，通过 Commit 共享弹窗输入；
原有名称、Untracked（仅 Stash）、保存/恢复/删除服务不变，Shelf 记录仍可访问。
分支标签遵循 `GitStashBranchComponent` → `GitRefManager` 的
`VersionControl.GitLog.localBranchIconColor`（深色 #5FAD65、浅色 #369650）与
`headIconColor`（深色 #F5D273、浅色 #FFAF0F）；不能直接展示灰色 SVG 原色。
记录行复用 `BranchPopupRowControl` 的非激活原位展开窗口，hover 展示完整名称、日期、
分支，屏幕边界约束与滚动/关闭清理沿用原实现；展开区域也转交共享右键菜单，不能
为了 hover 丢失 Apply/Pop/Restore/Drop。

预览先固定 Stash 的对象 SHA，再用 Git 导出包含未跟踪文件的只读补丁，不能读取当前
工作区冒充保存版本。Shelf 的 index 与 worktree 补丁是两个连续版本，必须分开选择，
不能拼成同一文件的净 Diff。Core `git.patchPreview` 的 `metadataOnly` 路径仅解析安全
文件名、不检查工作区适用性，不生成应用授权 token，冲突期间仍可浏览保存内容。
当前按文件顺序解析，复杂路径交给 Git；大量文件的后续优化应批量返回 Core 文件段元数据。
异步加载由页面 task 的选择标识取消，迟到结果不覆盖新选择；Diff 使用不可变快照。
Git Log 文件点击始终走历史 Diff；保存记录内的前后文件导航由编辑器显式传入快照，
不能通过当前 Diff 类型改变 Git Log 入口的语义。补丁导出固定无颜色与 a/b 路径前缀，
避免用户 Git 配置影响下游文件段识别及路径剥离。
组件与 Core 用例不能代替真实工作区深浅主题、窄宽度、弹窗和点击操作验收。

### Worktrees

Worktrees 的列表与提交搜索直接使用共享搜索框，新增、刷新和复制按钮使用已有
IDEA SVG 与工具栏按钮样式；详情标签使用 `LitheToolWindowTabStyle`，新建表单与
操作按钮复用 `LitheCommitDialogInputStyle` / `LitheCommitDialogButtonStyle`。
详情按普通分区呈现，不另画一套卡片、搜索边框或蓝色列表描边。

工作树仍保留原生多行列表和原生滚动容器，以免样式调整恢复逐行 SwiftUI 布局成本。
列表通过自身区域的 `LitheToolWindowActivityTracker` 和窗口活动状态选择
`LitheTheme.Tree` 的焦点/失焦背景；原生绘制缓存必须在焦点变化时失效。
标题、路径和分支分别占一行，状态宽度按文字度量，避免窄栏中的状态覆盖名称。
上下键移动选择并滚动到可见行；右键动作仍捕获被点击的工作树，保留保护和忙碌条件。
`GitWorktreeAppearanceTests` 验证实际绘制的深浅选中色及键盘边界；完整页面实机验收
与组件验证分别记录，不能把后者视为前者。

### Commit 文件树

Commit 文件树参考同一 Community revision 的 `ChangesTreeCellRenderer`、
`ChangesBrowserChangeNode` 和 `ChangesBrowserNodeRenderer`：复选框在文件图标左侧，
图标表示文件类型，文件名使用 Git 状态颜色；路径和计数保持正常字号的次要文字。
复用 `LitheTheme.Tree` 的 24pt 行高、19pt 层级缩进、16pt 图标及选中/悬停表面，
文件名与路径使用 13pt Regular；分组标题加粗，但不永久绘制选中背景。
文件名颜色来自 `IslandSchemeDark.xml` 与 Light 继承的 Default：深色修改/重命名
`#70AEFF`、新增 `#73BD79`、删除 `#6F737A`、冲突 `#DE6A66`、未跟踪 `#E88F89`。
使用既有文件类型图标映射，不再用铅笔/加号色块代替类型图标。

`GitChangeInclusionCheckbox` 复用上游 expUI 三态 SVG，24pt 画布中包含 16pt 方框，
分别保留开/关/部分选中、禁用、焦点状态。深色原图不改，浅色按同 revision 的
`Checkbox ColorPalette` 生成颜色变体，图形路径不改；出处记录在图标目录 NOTICE。
这是构建期固定资源，只通过既有 bundle 图标解析器读取，不增加运行时下载或写入。
保持已有分组、暂存回调、多选目标与子模块禁用规则；样式迁移不重写提交语义。
`GitCommitTreeStyleTests` 校验真实 SVG 的明暗状态、尺寸/底色及文件类型解析；
`GitChangeSelectionTests` 与 `GitChangeSectionsCacheTests` 覆盖已有选择和分组行为。
完整工作区的深浅视觉与交互仍须单独验收。

### 居中的输入与补丁表单

新建文件、目录、变更列表及补丁表单复用 `LitheCenteredPopup`，即从原有
`ProjectItemNameDialogPresenter` 提取的原生面板生命周期。它在所属窗口中央显示，
随窗口移动或调整尺寸重新居中；轻量表单使用无边框窗口与 `litheContextMenuSurface`，Commit 对话框使用标题栏与独立共享样式。不再把共享
背景与阴影叠在系统 sheet 上，否则外层仍保留系统圆角与外框。

表单保持原动作和内容，新建文件/目录使用 plain 名称输入框、13pt 字体、
32pt 高度和左右 13pt 留白；输入区域融入浮层底色，聚焦时不画独立蓝框。
依据同一 Community revision 的 `NewItemSimplePopupPanel.createTextField`：
New UI 行高 32、左侧 empty border 为 13，`ErrorBorder` 仅在错误/警告时绘制，
不能套用设置页的常规输入框 chrome。`focusedNewItemFieldBlendsIntoPopup` 在
深浅模式下渲染真实新建文件/目录内容，聚焦后检查输入区域与弹窗背景一致。
新建文件/目录继续使用 `lithePopupNameField`；Commit 变更列表不消费轻量名称框。
Commit 新建、编辑变更列表依据 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade`
的 `NewChangelistDialog.java`、`NewEditChangelistPanel.kt`、
`DarculaEditorTextFieldBorder.java` 和 Islands 明暗主题，使用原生带标题栏对话框。
`LitheCommitDialogStyle` 统一对话框底色、直角编辑框及 72×28 按钮，由 Commit 变更列表及创建/应用补丁表单消费；
现有名称字段使用标签与输入框对齐布局。名称框获得焦点时绘制蓝色直角边框，不能套用新建文件的无框输入。
布局参数来自 `IntelliJSpacingConfiguration`：标签间距 6，表单留白上下 10、左右 12；`DialogWrapper.BASE_BUTTON_GAP` 为 12。
编辑框遵循 `DarculaEditorTextFieldBorder` 的上下 6、左右 8 内边距；
Islands `TextField.minimumSize` 高 28，浅色编辑区继承白色 `editor-bg`。
对话框失焦保留，Cancel、Esc、窗口关闭或成功保存才关闭；旧轻量浮层保持既有失焦关闭行为。
本次仅迁移外观：保留名称、取消与保存，以及原有校验和存储逻辑；不增加 Comment、
Set active、自动命名或帮助入口。`LitheCenteredPopupTests` 检查真实标题栏、焦点、
失焦保留与窗口关闭，并确认新建文件/目录轻量输入框不受影响。

创建/应用补丁也使用带标题的共享对话框、表单留白及主次按钮，保留既有文件列表、
预览、来源与目标选择及业务动作。原生打开/保存面板不是表单的 child window，因此
不能用 childWindows 判断文件选择器是否正在使用；带标题表单统一失焦保留。
共享桥接传递完整 SwiftUI environment，使字段、按钮和标题使用同一应用语言。
带标题窗口打开期间，由共享 presenter 拦截发给所属主窗口的鼠标、滚轮和键盘事件，
防止后台按钮覆盖当前编辑状态；其他窗口、原生文件选择器和内部下拉菜单照常交互。
这是所属窗口的输入隔离，不运行会阻塞异步业务的 AppKit 模态循环；关闭/卸载移除监听。
回归覆盖真实事件路由、选择器失焦保留、关闭后恢复主窗口，以及独立宿主的语言继承。

内部选择器打开子窗口时不能把轻量父表单当作失焦取消；忙碌表单禁止普通失焦关闭，
但所属主窗口关闭仍必须释放面板和观察器。`LitheCenteredPopupTests` 验证无边框、
无动画、居中跟随、子窗口保留以及主窗口关闭清理。标题栏只保留已显示的创建补丁
入口，不因为修正按钮尺寸而增加应用补丁入口。

共享桥接必须在 `updateNSView` 同步读取展示状态并构造内容，才能让 SwiftUI
跟踪状态依赖；只把原生窗口挂载延后到主队列。异步请求带更新序号，后续更新、
关闭及卸载使旧请求失效，避免等待另一次点击才显示或集中打开过期弹窗。
`stateChangesOpenCloseAndReopenWithoutAnotherInteraction` 通过真实 SwiftUI `@State`
宿主验证单次打开、重复打开、关闭、重新打开及取消后卸载；旧实现单次打开失败。

### 工作台共享悬停提示

四周工具栏、Git/Maven/Agent 等已有 `workbenchHoverHelp` 消费者统一读取
`LitheTheme.HoverTooltip` 和 `litheHoverTooltipSurface`，禁止调用处另画外框。
Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的 `HelpTooltip`、
`JBUI.CurrentTheme.Tooltip/HelpTooltip` 和 `ManyIslands{Dark,Light}.theme.json`
决定背景、文字、边框与尺寸：深色背景/边框 `#33353B`、文字 `#D1D3D9`；
浅色白底、`#D1D3D9` 边框、黑字。半径 4，内容左右 12、上 8、下 9，
常规文字 13pt。旧实现使用 expUI 的深/浅暗色表面，不能把它当 Islands 的覆盖值。

IDEA 的 `AbstractPopup` / `WindowRoundedCornersManager` 将 macOS 深色 tooltip
边框交给原生窗口层绘制，宽度 1；Lithe 在既有浮层内只绘制一次相同 token 的
内边框。原生窗口阴影不等价于背景色，不能从截图吸色后写成另一圈不明边框。
本项只调整已有提示的共享视觉，不改变范围、定位、关闭与可访问性策略。
`WorkbenchHoverTooltipTests.sharedTooltipPalette` 检查深浅实际渲染像素；原有
四周定位、窄窗换行和窗口隔离检查继续保留。

### 分支名称的原位展开

顶部项目、分支按钮使用箭头光标，分支按钮不再附加完整名称帮助提示。
完整名称在分支列表里查看：被截断的行悬停时沿原位置展开，保留整行的
选中底色、字体、图标和高度，显示完整本地分支和 upstream（跟踪的远端引用）。
已显示完整的行不展开，也不改变弹窗保存的宽度。

依据 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的
`platform/platform-impl/src/com/intellij/ui/TreeExpandableItemsHandler.java`、
`AbstractExpandableItemsHandler.java` 和
`plugins/git4idea/shared/src/com/intellij/vcs/git/branch/tree/GitBranchesTreeRenderer.kt`：
展开内容来自同一行 renderer，并沿用树的选择底色和圆角，而不是普通 `HelpTooltip`。
Lithe 使用 `BranchPopupRowView` 包装原有 SwiftUI 行，保留共享 `LitheDropdownRowStyle`；
行的原生 `mouseEntered` 直接显示一个非激活子窗口，复用同一行 renderer，
保持屏幕中的原行位置、普通字重、选择底色和高度，超出屏幕时限制右边界。
不依赖 `NSControl.allowsExpansionToolTips`：普通自定义控件附加 cell 后，
直接调用 cell 的检查通过，但用户实测仍未出现展开，不能继续把它当作可靠入口。
子窗口接收该行点击并转交原动作，键盘焦点留在父弹窗；滚轮转交原行滚动路径。
离开、打开动作菜单、禁用、脱离窗口及父窗口关闭都清理浮层及父窗口关闭观察器。
只测量当前悬停行，不给空闲行登记全局悬浮几何；展开使用当前分组里的本地名称，
不额外插入 namespace。
行点击仍通过 `LitheDropdownPopover` 打开动作菜单，无障碍按下和键盘按下保留。
滚动导致 AppKit 重建鼠标跟踪区域时，不能依赖旧区域一定发送离开事件；
`updateTrackingAreas` 按当前窗口鼠标位置重新判断行的 hover，只在结果变化时重绘。
命中同时要求行自身边界和滚动可见区包含鼠标，因为不裁剪的原生视图可见区
可能超出自身边界；只检查可见区会把同一窗口内多行同时判为悬停。
回归检查固定窗口鼠标位置、移动原生滚动区，确认 hover 随当前行转移，
已打开动作菜单的行仍保留高亮，不添加全局滚轮监听或每行滚动观察器。
固定行的宽高由外层布局分配，标签直接留在父级 SwiftUI 树中，透明的
`BranchPopupRowTracker` 只承担原生鼠标、点击及无障碍交互，不再给每行嵌套
`NSHostingView`。仅关闭内部宿主的自动尺寸约束不足以修复 #1277：窗口失焦时，
悬停展开仍可能在布局过程中更新宿主，反复请求约束计算。PR #1298 已替代该候选方案：
状态未变化时跳过刷新；`updateNSView` 和 `updateTrackingAreas` 引起的悬停展开更新
合并到布局结束后执行，脱离窗口时取消，换窗后重新安排；真实鼠标事件仍立即响应。
Stash/Shelf 复用同一边界，独立展开宿主继续测量完整名称。
`layoutReentrantUpdatesDeferHoveredExpansionRendering`、
`trackingAreaRebuildsDuringLayoutDeferHoverRendering` 和
`pendingRefreshFollowsTheRowAcrossWindows` 检查布局重入、跟踪区域重建和换窗行为。
#1298 作者报告 macOS 27.2 前后台切换与滚动实测通过；本地其他系统上的定向回归
不能替代该环境的验收，也不能把旧固有尺寸检查表述为崩溃已经消除。
原先附加 `.help` 的做法只提供独立文字提示，不能复现这种原位展开，因此移除。
`BranchSwitcherPopoverBehaviorTests` 检查深浅选中底色、尺寸、无须展开的行、
动作和禁用行为；悬停必须实际创建可见子窗口，检查完整内容、原行位置、
绘制底色、点击转交、焦点及父窗口关闭清理，不能再直接调用展开或绘制方法证明触发。
完整预览已核对分支列表、长名称截断和搜索，原生悬浮层与实际菜单的组合
尚未取得可靠的实机截图，不能用组件截图代替最终视觉验收。

右侧上游列依据同一 Community revision 的
`plugins/git4idea/shared/src/com/intellij/vcs/git/branch/popup/GitDefaultBranchesTreeRenderer.kt`：
本地名称优先占用空间，上游列靠右、末尾省略，选中时沿用行文字颜色，未选中时为
`JBColor.GRAY`。上游来自真实 Git 跟踪配置，不能通过同名远端分支猜测或为了截图
改用户的 Git 配置。Recent 和 Local 均使用 Core 返回的引用元数据。单分支 fetch 映射不能让已配置的
上游消失；Core 的补齐规则见
[Git 执行与项目控制台](../architecture/2026-09-12-git-execution-and-project-console.md#单分支抓取规则下的上游信息)，
页面不修改 Git 配置，也不自行解析跟踪信息。

领先／落后计数原本已由 Core 返回，但 macOS 丢弃了 `ahead` / `behind`；
历史和单独引用的解码路径现在都保留这些字段，缺字段的旧响应仍按零处理。
计数复用 Community `GitIncomingOutgoingUi` 的颜色、99+ 上限和
`DvcsIconMappings.json` 指向的 12pt New UI 原始 SVG，保留深浅变体。
资源是构建时打包的只读输入，不在运行时下载或写入 bundle。

### 分支弹窗尺寸

只有顶部的分支弹窗传入尺寸绑定。共享呈现器为它安装透明的原生边缘命中层，
普通菜单不安装；内容中央继续把事件交给搜索框、分支行与滚动区。
对照 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的
`GitBranchesPopupBase.kt` → `WizardPopup.java` → `AbstractPopup.java` →
`WindowResizeListenerEx.kt` / `WindowMouseListenerSupport.kt`：分支弹窗可移动、可调整尺寸，
macOS 四边命中区为 8pt，角落沿相邻边扩展至 16pt；角落优先，中央不命中。
同一个方向判断决定光标与拖动，避免出现能显示光标却不能调整的边缘。
宽度单独启用时只处理左右边，不拦截上下边。

弹窗是独立窗口，不能嵌入工作台内部的 `LitheSplitPaneView` 分隔布局。
复用原生命中组件的屏幕坐标和 `LitheDragUpdateScheduler` 事件合并，
拖动只调整原生窗口框架，不向工作台逐帧发布宽度。
默认及最小宽度沿用 375pt，最大宽度受拖动方向的屏幕可用区域限制。初始高度由内容决定；
四角支持宽高联动拖动，最小高度取 Community `GitBranchesPopupBase` 的 312pt，
最大高度受对应方向的屏幕边界限制。搜索框固定在顶部；其下的操作项、分隔线和分支列表共用一个滚动区，
不能只让 Recent／Local 等分支分组滚动。缩小弹窗后操作项也能滚出视口，
各行高度不变，保留原默认弹窗高度。
`actionsAndBranchesShareScrollingWhileSearchStaysFixed` 用小视口检查唯一原生滚动区、
操作项参与滚动内容，以及滚动时搜索框位置不变。
内容筛选、分组展开或数据刷新不能把用户调整后的宽度重置成默认值。
`NSHostingController.preferredContentSize` 会安装优先级 501 的理想宽度约束，
原生窗口启用约束布局后会据此把宽度改回 375pt。容器用一个明确的宽度约束
表达用户选择，只在原生拖动及内容尺寸校验时更新其常量；手动调整高度后也用
明确的高度约束，避免宿主在下一轮布局恢复理想高度。
不能只修改窗口 frame 而忽略约束，否则看似执行了缩放，显示时又被改回。

四边和四角共用 `ProjectReplaceCornerHandleView` 的屏幕坐标拖动与清理逻辑，
由 `LitheDropdownResizeHandle` 限制边缘命中；不建立覆盖内容中央的光标矩形或跟踪区。
JBR `46a54ec335a03d317fb2298b84a823e8ecfaceef` 的 `CCursorManager.m`
将东西、南北方向映射到 AppKit 水平、垂直双向箭头；Lithe 使用相同的公开 AppKit 光标。
对角线直接使用同一 JBR 映射的 `NSCursor.javaResizeNE/NW/SE/SW()`。
这些方法由 macOS SDK 的公开系统框架 `JavaRuntimeSupport/JRSCursor.h` 声明，
通过 `import JavaRuntimeSupport` 和产品目标的 `.linkedFramework("JavaRuntimeSupport")` 显式链接使用，无需运行 Java、复制系统图片或动态调用 selector。
先前将它们当作私有接口并以 SF Symbols 近似是不准确的；只导入 AppKit 时类别尚未加载，
不能据此判断接口不存在。此类别声明不会触发 Swift 编译产物自动链接该框架，
只加 import 会造成 unrecognized selector；必须保留 Package.swift 的显式框架链接，
并在真实测试可执行文件中设置光标。保留系统原始图案、尺寸和热点，不用 `frameResize` 或通用斜箭头替代。
四角原生鼠标事件测试逐一比较对应系统光标的 TIFF 图像、逻辑尺寸及热点。
弹窗在鼠标事件分发后设置边缘光标；回到内容区时释放调整光标，保留输入框的 I-beam。
拖动某条边时只改变对应轴，并固定相反边；角落同时改变两轴。
松开后同步原生锚点的水平与垂直位移，内容刷新不能把弹窗拉回拖动前的位置。
连续拖动以 `display: false` 修改原生窗口，把重绘交给 AppKit 下次绘制周期；
不能每个鼠标事件都同步刷新窗口。初次打开、普通菜单和持久化流程不受影响。
松开才更新宽高绑定并通过 `WorkbenchLayoutStore` 保存到当前项目的布局。
新增可选字段兼容旧布局，不改变侧栏和 Maven 面板尺寸的保存方式。
其他项目使用自己的宽高；屏幕变窄时只限制显示尺寸，不在打开弹窗时覆盖保存值。
`ContextMenuCoverageTests` 经真实窗口发送按下、拖动、松开事件，检查原生命中、
四角的方向光标、相反边固定、尺寸限制、松开回调及刷新保宽，
用连续 20 次原生拖动事件确认只合并交付一次且拖动中不保存，
并确认普通弹窗没有拖动命中区。该计时不代表复杂工作区的帧流畅度验收。
该检查必须启用原生约束引擎并强制布局；先前同步宿主未启用它，曾误报通过。
补上约束后已复现 375pt 回退，修复后检查实际窗口尺寸保持用户值；
`WorkbenchMavenLayoutTests` 检查旧数据兼容和项目隔离。2026-10-07 完整应用预览中，
实际拖动后的窗口宽度与请求值一致（仅有原生像素取整），用户确认拖动已经生效；
诊断日志随后移除。新增右下角检查经真实窗口发送双轴鼠标事件，验证命中、
松开提交、宽高上下限、宿主尺寸和关闭恢复；项目持久化和隔离由布局测试覆盖。
新增角落与上游列尚需完整应用的实机视觉验收，完整 Git 工作流仍按功能矩阵待验收。

### Agent 历史与剩余控件

Agent 历史列表使用同一弹窗外框、24pt 行高、选中和 hover。较高的历史视口
是本产品的展示规则，参考现有列表的 20 行预算；不能声称私有 AI 插件的
固定高度已经由 Community 源码证明。超出屏幕时仍由共享 host 收敛尺寸。
自定义列表的键盘处理通过 `litheDropdownKeyHandler` 登记到共享 popup 的既有
事件路径，只作用于其所在弹窗；Escape、外部点击和窗口清理由 owner 保留。
标准设置按钮不再由 Agent 页面单独覆盖为 24pt/11.5pt，供应商操作错误使用
共享通知；配置复选框、欢迎行文字/箭头和对话工具栏继续复用已有控件。
未有明确上游映射的符号保留 `LitheSystemIcon` 的原生 fallback，不猜造 SVG。

### 工作台壁纸与结构背景

工作台页面、标题栏和内容区的结构背景使用既有 `litheWorkbenchSurface`。
工作台根视图把当前是否有背景图作为环境值传下去，共享入口据此清除结构底色；
移除背景图时恢复原主题颜色。背景图是否存在仍由原背景 Feature 负责，
视图不再各自依赖整个 AppModel，也不复制壁纸透明度、调色或加载逻辑。
独立窗口默认没有壁纸宿主，保持普通底色；表单输入、菜单、通知和模态弹窗
保留专用背景，不因工作台壁纸变成透明控件。
Agent 外层、标题、历史页、欢迎页和会话标签栏，以及共享输出、模块加载、
替换预览、媒体查看、数据库结构/诊断/分页工具栏、Git 保存变更的结构背景
必须调用该入口。共享组件新增页面时也要检查内部不透明层，不能只把外层清空。
原生像素检查在同一个宿主里切换“无图→有图→无图”，验证 Agent、欢迎页、
输出和模块加载的空白区域透出背景图，并确认最后恢复原色，覆盖深浅外观。
2026-10-13 完整应用预览实测内置背景 01：Agent 标题和正文透出壁纸，
输入框与通知保留专用底色；移除背景图后回到普通底色。设置页的 WARN/FAIL
预检项实际点击后能隐藏详情。本轮 139 项相关检查通过，临时预览已经退出。

### 全局通知与右侧底部动作

面板内通知也使用共享入口：`LitheBanner` 与 `litheBannerSurface` 拥有
状态背景、边框、内边距、文字、官方图标和动作链接。业务页面只提供状态、
正文、原有动作和可见条件，不再用 warning/error 的透明度各画一套提示。
依据 Community `915c3c26029bd2f8d35907d6faf43c4a3264c5f7` 的
`InlineBanner.kt`、`InlineBannerBase.kt`、`EditorNotificationPanel.java`、`JBUI`
及 Islands 明暗主题：圆角提示内边距 12、图文间距 8、边框 1、圆角半径 8
（绘制的 arc=16 是直径）；编辑器平面提示上下 10、左右 12，只画上下边框。
原有动作按 Link.Foreground 展示，动作间距 16；有关闭动作的圆角提示沿用
26pt 按钮与 7pt 外侧留白。没有关闭动作的提示不新增关闭入口。
成功、警告、错误、信息与柔和信息均使用主题的 Banner 专用状态色，
不要套浮动通知的中性底色，也不要用通用文字色或透明度近似。
IDEA 的圆角提示与平面提示是两种控件，因此共享规则保留这两种布局。
Git、GitHub、Maven、Run、编辑器、Database、LSP、插件和 Agent 的既有提示
使用此入口。表单字段验证、日志内容与系统确认对话框保留各自的语义。
这次只统一 macOS 展示，不改通知队列、协议、后端算法或 Windows 控件。

全局短通知由 `WorkbenchNotificationBanner` 统一呈现，外框归
`LitheTheme.Notification` / `litheNotificationSurface`，不让各个业务消息
重新指定背景和边框。依据同一 Community 版本的 `NotificationsManagerImpl`、
`BalloonLayoutConfiguration`、`NotificationBalloonRoundShadowBorderProvider` 和
Islands 主题：深色背景/边框 `#33353B`、文字 `#D1D3D9`；浅色白底、
`#D1D3D9` 边框、黑字。`Notification.arc=12` 是 Java 圆角直径，对应半径 6。
阴影按 `ShadowJava2DPainter` 的 5pt 线性边缘渐变绘制，不把阴影留白误当模糊半径。
内容采用 13pt 常规文字，保留短通知的上/下留白。长消息默认显示两行，
用官方上下箭头展开/收起；展开内容最多显示十行，超出的正文在气泡内滚动。
360pt 卡片宽度沿用 Lithe 的现有上限，并非 IDEA 的固定宽度。
信息和关闭图标使用 `PlatformIconMappings.json` 指向的官方 16pt 明暗 SVG。
普通通知的显示逻辑也由原通知模型统一负责：依据 `NotificationsManagerImpl`
把停留时间改为 10 秒，应用不活跃时暂停；依据 `BalloonImpl` 按单条通知暂停
hover 计时，恢复时只用剩余时间，不能悬停一条就延长其他消息。
`ActionCenterBalloonLayout` 最多展示三条 timeline 气泡，旧消息保持在下方，
新消息向上排布。第四条到达时，把最旧气泡折叠到剩余最旧条的历史入口，
并保留每条消息的历史记录；点击入口打开通知中心并关闭临时气泡。
关闭或超时只移除气泡，不删除历史。Lithe 仍保留原有 100 条历史上限，
折叠计数不能超过可打开的历史条数。当前消息 API 只有正文，沿用普通
timeline 类型，不通过猜测消息内容创建警告、建议或 sticky 通知。
通知气泡和通知历史均由 `WorkbenchNotificationPresentation.message` 根据应用 locale
显式选取对应的 lproj，再解析正文键与重复计数。调用方保留稳定的原始键；不要先用
缺少应用 bundle 语言选择的 `String(localized:)` 翻译，否则中文进程会把已翻译的正文
传给英文界面。Java 就绪、准备、超时和启动失败通知遵守此规则；带错误详情时保留格式化键和原始参数，
展示层再按当前应用 locale 翻译并格式化。语言切换后的正文和计数由通知的两个
呈现入口共同更新，外部诊断等非资源键的文字原样保留。
气泡外沿距离工作区右边及状态栏上缘 10pt，阴影属于外绘制范围。

检查更新和背景选择放到右侧活动栏底部，使用同一
`LitheActivityBarButtonStyle`，在 37×40pt 槽位中居中绘制 30pt 按钮。
更新入口为纯图标，但保留随状态变化的可访问名称和共享悬停提示；
检查、下载、安装期间显示忙碌状态，已有详情和重试动作继续可用。
背景选择面板向上展开，以免底部锚点把内容推到屏幕外。

主工具栏保留运行配置、Run、Debug 及执行中的 Stop。用户指定的布局不包含
右上角 Search Everywhere 和 Settings 按钮，不能因为参考 IDEA 的排列就增加
产品入口。全局搜索和设置继续使用既有快捷键、应用菜单及活动栏入口。

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

再次左键点击原触发按钮时，由按钮切换打开状态；呈现器的外部点击和失焦处理
不能先清空绑定，否则同一次点击到达按钮后会重新打开菜单。动作菜单、自定义
弹窗和选值控件复用 `LitheDropdownAnchorGeometry` 判断按钮区域；点击其他按钮
仍关闭旧菜单并继续传递事件。动作/自定义呈现器只弱引用锚点，按当前窗口位置
计算命中区域，关闭时释放引用。

选值列表中的数据库列名属于用户数据，必须使用 `localizesTitles: false` 原样显示。
例如中文界面的 `Name` 和 `名称` 不能都变成“名称”。混合列表中的“所有列”等
固定命令先本地化，再与原始标识符一起交给控件，不能把整张列表作为翻译键。

共享下拉锚点显式观察 `colorScheme`，原生面板也使用同一明暗外观；
整个共享外框与内容一起应用环境。不能只读取锚点 NSView 的旧外观，或在
内容外另套未继承环境的边框，否则应用选择浅色而系统保持深色时会出现白色
面板内的黑色输入框和浅色文字。原生弹窗测试刻意使用相反的宿主窗口外观。

Monaco 编辑区右键菜单由网页内部渲染，原来的 SwiftUI 菜单扫描无法覆盖这个入口。macOS 现在通过 `macos/EditorFrontend/context-menu.ts` 的 `installNativeContextMenu` 替换 Monaco 0.55.1 的菜单渲染器，把已生成的条目交给 `MonacoEditorContextMenu` 和共享 `LitheContextMenuPresenter`。Monaco 仍然负责上下文条件、分组顺序、快捷键和动作执行；这里只传菜单展示信息与选中条目，不调用 Rust 或新增 IDEA 独有动作。取消、替换与卸载必须结束原来的菜单回调，旧响应不得执行动作。

图标以 IDEA 的动作定义 `Presentation.icon` 和 `PlatformIconMappings.json` 为依据。剪切、复制、粘贴、格式化及已有 Run/Debug 动作使用已确认的官方 SVG；跳转、重命名、更改所有匹配与命令面板保留空图标位。图标显示为原始 16pt，保留 SVG 路径、描边、原色和明暗资源，禁用透明度由共享行处理。 `LitheIcons.ideaImage` 接受带或不带 `.svg` 的已有调用，省略后缀时默认 SVG；明暗兄弟路径同样补齐后缀。避免调用缺后缀导致空图标或 SF 回退；实际打包资源探针检查两种写法都可解析。不能按菜单文字猜图标或用 SF Symbols 补齐空位。

同一操作菜单的子菜单必须跟随触发行的可见位置，不能与父菜单顶部对齐。
共享呈现器读取父菜单行的实际几何位置，因此分隔线和父菜单滚动都会参与定位；
打开、关闭或切换子菜单时固定主菜单位置，仅在屏幕边缘限制子菜单偏移，长子菜单
继续滚动。菜单标题直接测量相同字体与语言的 SwiftUI 文字布局，避免小数字号下原生
字宽与实际绘制宽度不同而截断 `Copy Relative Path`；菜单行间距显式计算，
并为快捷键、勾选和箭头按实际布局留足宽度。

顶部项目/分支按钮在菜单打开期间保持普通悬停背景，关闭后释放这项保持状态。
原生面板获得焦点会使 SwiftUI 收到 hover 离开事件，因此仅依赖鼠标悬停会让
已打开菜单的按钮变透明。复用 `litheRowHover` 的现有激活参数，将其背景明确设为
`LitheTheme.hoverBackground`，保持点击前后同一种颜色，不使用菜单行的蓝色选中色。
Community `ToolbarComboButtonUI.paintBackground` 同样在 combo model selected 时绘制
已有 hover 背景。该行为只用于顶部两个触发按钮，不改变菜单行或设置值的选中状态。
系统应用菜单、系统对话框、编辑器补全与悬停文档保留原生职责；显式 segmented 的原生 Picker 没有下拉框，也不属于本次迁移。

## 带说明的侧边选项

Agent 模型配置使用现有 `LitheMenu(opensToSide: true)`，不再把固定侧栏放进
可搜索主面板。共享 `LitheContextMenuItem` 可以携带说明和明确的标题本地化策略；
Agent 上游名称使用原文，说明由调用方按界面语言提供。没有说明的操作保持
24pt 单行样式；有说明时，呈现器按实际受限宽度下的两行文字测量行高和面板高度，
保留共享字体、背景、边框、宽度上下限、键盘及关闭行为。

核对 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的
`platform/platform-impl/src/com/intellij/ui/popup/list/PopupListElementRenderer.java`：
普通动作行使用主题行高，并把次要文字、图标和选中颜色留在共享 renderer 中。
Lithe 的名称下方说明按用户指定的 CC GUI 配置选项设计扩展，不宣称是 IDEA
普通动作行的新尺寸；只有携带说明的内容增长。正确做法是由调用方提供说明，
由共享菜单测量；不要为 Agent 另画矩形背景或按主菜单整体高度铺满子菜单留白。

长列表用方向键滚动后，原生界面会在静止指针下重新产生悬停进入事件。
共享菜单在键盘导航后忽略这类事件，等面板收到真实鼠标移动才恢复指针选择；
行样式只使用菜单选中状态，避免另一份本地 hover 把不同的行同时染蓝。
连续指针事件只在选中 ID 改变时发布菜单局部状态，不通知业务页面。
真实 `mouseMoved` 在同一事件内按已有布局测量的行矩形完成选择交接，不依赖
后续 SwiftUI 悬停回调的先后顺序。指针矩形只保存在打开的菜单内，布局没有变化
不重复保存；不发布业务状态，也不写入磁盘或缓存窗口位置。
`AgentSessionSelectorLayoutTests.modelSettingsWithWrappedDescriptionsScrollToTheLastChoice`
在滚动完成并捕获真实渲染后再按 Return，验证末项没有被静止指针抢走。
`AgentSessionSelectorInteractionTests` 另外向原生子窗口发送 `mouseMoved`，再按
Return 验证指针所在行接回选择。动作菜单的内容是打开时的快照；接入动态上游配置
的调用方需要在对应配置变化时拆除局部锚点，关闭失效子窗口，重新打开读取新选项。
Agent 仅重建变化的设置行菜单，保持可搜索父面板和其他配置菜单的状态。

## 顶部项目和分支菜单的尺寸与内容

对照 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade`：
`ProjectToolbarWidgetAction` 通过 `ListPopupImpl` 按 renderer 的内容尺寸布局，
没有统一固定为 390pt；`GitBranchesPopupBase` 新 UI 的最小宽度是 375pt，
并允许 IDEA 自身保存用户调整后的大小。因此两个菜单不要求一样宽。
Lithe 的项目菜单按本地化命令、项目名称与显示路径测量，复用
`LitheContextMenuPresenter.menuWidth` 和 `LitheDropdownMetrics` 的宽度边界；
项目菜单不再受普通操作菜单的 360pt 上限限制；按名称、路径和分支的实际字体宽度展开，由原生呈现器限制在当前屏幕可见区域。普通操作菜单的上限保持不变。宽度使用实际 frame 而不是仅提供 `idealWidth`，让异步分支到达后宿主的首选尺寸确实变大；分支文本保持单行自然宽度，不进行中间省略。

项目条目参考同一 IDEA revision 的 `ProjectToolbarWidgetAction.kt` / `ProjectWidgetRenderer`：名称和路径下方按需增加分支图标与常规小字号的第三行。`AllIcons.Vcs.Branch` 在 New UI 的 `PlatformIconMappings.json` 映射到 `expui/general/vcs.svg`，复用仓库现有的明暗 SVG，不使用旧 `vcs/branch.svg` 文件中的列表形图案。每次打开菜单时通过既有 Git 仓库检查器读取打开项目和最近项目的当前分支，不保存上次显示的分支名。读取只返回元数据，不覆盖当前工作区的 Git 身份编辑草稿；取消菜单任务后不再写入结果。没有 Git 仓库、分离 HEAD 或 Git 模块未启用时不显示分支行。这样避免每个项目启动完整 Git 状态刷新和文件扫描；代价是分支行在异步读取完成后出现。
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
字母按 Community `platform/util/ui/src/com/intellij/util/ui/AvatarUtils.kt` 的
New UI 规则使用 JetBrains Mono DemiBold（已打包的 SemiBold 字型），字号为
`floor(13 × 标识尺寸 / 20)`；20pt 标识对应 13pt。原来 Inter Bold 的字形与粗细
不符，修复放在同一共享徽标中，顶部、项目菜单和欢迎页都复用它。

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

Recent、Local、Remote、Tags 是同一个滚动区域内的可点击分组，
不是带装饰箭头的静态标题。依据 `GitBranchesPopupBase` 的单击展开树，
Recent 也按分支命名空间分组。搜索覆盖全部引用；清空搜索后恢复当前弹窗内
各组的折叠状态。搜索框复用 Git Log 的输入和焦点外框；
`GitBranchesPopupBase` 给同一 `SearchFieldWithExtension` 显式传入
`Popup.BACKGROUND`，所以共享样式允许背景参数，分支弹窗使用弹窗底色，
Git Log 保留原输入底色。打开菜单不强制搜索框获得焦点；点击输入后才显示
共享蓝色焦点边框。共享搜索输入沿用原生编辑器，在同窗口点击输入区域外时释放焦点；由既有编辑观察视图处理并在卸载时移除监听，避免各面板重复添加点击手势，也避免其他输入的观察器打断当前编辑。原生面板通过 `searchOnTyping` 保持初始焦点在菜单；
开始键入或 Cmd+F 时交给原生输入框继续处理同一个事件，保留 IME，
避免 AppKit 自动把第一个输入框染成蓝色，也避免去掉自动焦点后破坏直接搜索。
不能仅因为复用了同名组件就忽略上游传入的背景和焦点状态。
分支动作经 `LitheMenu(opensToSide: true)` 把实际行位置交给共享呈现器，
从父弹窗右侧打开，第一条动作对齐触发行；右侧空间不足时才向左展开。
分支行在子菜单打开期间保留选中色，Esc 先关闭子菜单，再关闭父弹窗。
不能在分支调用方按鼠标位置增加偏移或另建菜单窗口。

## AI 开发约束的范围

强制规则集中在 `develop-lithe` 的 `macOS shared frontend controls`，这篇 Note
只记录原因和范围。规则覆盖已有产品下拉/右键菜单、菜单定位与宽度、搜索输入、
工具栏图标按钮、树行和字体；每类都指明真实组件路径，修改样式要先检查共享所有者
和调用方，再对照对应 Community 控件/动作/主题源码。不能根据截图猜一个新样式，
也不能为对齐 IDEA 增加 Lithe 没有的功能。

例如 Search 新输入用 `LitheSearchTextField` + `litheSearchField`，修改占位或焦点色
要改共享组件；不要在 Search、Database、Git 各写一份背景和输入法判断。
Project 菜单宽度由内容测量、Branch 使用已有基准，不能因为都叫“下拉框”就强制
同宽。树行也不能代替多行项目菜单、表格或原生提交图谱。这样约束的代价是规则不
覆盖尚未实现的共享控件，但不会让 AI 为满足规则自行新增一套控件或重写原生列表。

## Maven 树与 Agent 表面接入共享样式

Maven 工具栏和树行复用 `LitheIconButtonStyle`、`litheTreeRow`、`LitheTheme.Tree`。
Agent 的画布、标题、上下文栏、输入工具栏及边框读取 `LitheTheme` 的实时 token，
避免局部固定灰色在切换应用主题后继续覆盖工作区。品牌色和会话语义色保留。

Maven 对照 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的
`plugins/maven/src/main/resources/intellij.maven.xml`、`MavenProjectsNavigatorPanel.java`
以及 `navigator/structure` 下的节点类。`AllIcons.java` / `MavenIcons.java` 决定
New UI 对应资源：RunAnything、ShowIgnored、taskGroup、libraryFolder、library、
mavenProject、mavenProfiles 和 ExternalSystem 的 task，保留 SVG 原色及明暗变体。
Profiles 上游为 17×16，其余本次资源为 16×16；`LitheIDEAIcon.width` 允许该非方形资源
保留原始宽度，已有调用仍默认使用原来的正方形尺寸。
没有用复选框替代“跳过测试”图标，也没有把生命周期节点都画成齿轮。

`ActionToolbar.DEFAULT_MINIMUM_BUTTON_SIZE` 为 22，`ActionToolbarImpl.ActionButtonBorder`
给水平按钮加上下 1、左右 2 的留白；`JBUI.CurrentTheme.Toolbar` 外围上下 5、左右 7。
`ManyIslandsDark/Light.theme.json` 及各自 `expUI` 父主题未覆盖上述 toolbar insets；
它们覆盖 ActionButton 的 hover/pressed 背景，圆角取 Button.arc=8（半径 4）。
使用已有 toolbar 专用颜色参数，不改变其他共享按钮的默认值。
树使用 Islands 的 24pt 行高、4/12 留白及现有 19pt 缩进；附加说明与名称同一行，
保留双击运行、展开、模块菜单、依赖错误提示和取消/重试语义，默认箭头光标。
完整树行（含展开箭头）绘制共享选中底色，并由既有活动区域观察器区分焦点。

这些 SVG 是构建时打包的只读源资源，不增加下载器、运行时缓存或可写 bundle 路径。
资源许可和导入路径记录于 `macos/Resources/IDEAIcons/NOTICE.txt`。

Agent 输入区底栏的切换菜单向上展开，菜单底边锚定触发控件顶边，避免覆盖状态栏。
`LitheMenu` 将展开方向交给共享呈现器，调用方不增加坐标偏移。供应商行显式提交
已有 `AgentBrandIcon` 的 16pt 品牌图标并保留独立勾选；此前只提交名称导致图标缺失。
这些资源是构建时打包的只读输入，不增加运行时写入或下载。

## 欢迎页项目动作按钮

欢迎页内容容器四周增加 8pt 留白，避免头部动作和侧栏内容紧贴窗口边缘。
这是 Lithe 本页的布局调整值，不作为 Community 的精确外边距参数；
内部按钮尺寸及项目行命中区域保持各自现有所有权，背景继续覆盖窗口安全区。

欢迎页 New Project、Open、Clone Repository 与 Commit、Test Performance 共用
`Views/Components/LitheActionButtonStyle.swift` 的 `LitheActionButtonStyle`，不再保留页面私有按钮样式。
统一圆角半径 4pt、最小宽度 72pt、内容留白 14pt、可见高度 28pt、13pt Regular；
欢迎页按钮组间距仍为 6pt。表单默认保留 3pt 外部边框留白；欢迎页使用 0pt，
悬停底色统一读取 `LitheTheme.hoverBackground`，页面不得再传入自己的按钮悬停颜色；
该规则同时适用于欢迎页、Commit、Test 和打开项目弹窗。主按钮和禁用样式保留各自语义。
依据 Community `b75ab523e6adbe1d26112219729eacbcfd24daa0`（`idea/262.9437.185`）的
`WelcomeScreenActionsUtil.java` → `DarculaButtonUI.java` / `DarculaButtonPainter.java`，
以及 `ManyIslandsDark.theme.json`：`Button.arc = 8` 是直径，`minimumSize = 72,28`，
相邻按钮组件的绘制留白形成 6pt 可见间距。仅按钮组使用此间距，搜索区保留原有布局。

按钮文字保持 13pt Regular，水平内容留白按 `DarculaButtonUI.HORIZONTAL_PADDING` 使用 14pt；
28pt 高度、边框和焦点逻辑保持不变；悬停底色由共享主题维护。
共享入口支持主按钮与禁用状态，不改变欢迎页字重及按压反馈。后续全项目普通文字动作按钮
均以此入口迁移，避免在页面另写 `.bordered`、局部悬停色或重复的按钮几何；本轮不批量迁移其他页面。
工具栏图标、标签和选择器仍由各自共享入口管理，其悬停配色继续复用主题 token。
最小宽度允许长文案继续增长，不能把全部按钮固定为 72pt。
按钮同时保留内容所需的水平宽度（`fixedSize(horizontal: true, vertical: false)`），
避免搜索区与按钮组分配空间时把长文案压缩成省略号；搜索区仍可随可用空间收缩。

同 revision 的 `ProjectsTabFactory.kt` 为搜索输入指定 `AllIcons.Actions.Search`；
`RecentProjectFilteringTree.kt.installSearchField` 去掉输入边框，并通过 `emptyText`
绘制提示。欢迎页因此保留无边框布局，复用 `LitheSearchTextField` 的 13pt Regular
提示文字、专用提示色和输入法组合处理。搜索图标使用已有 `expui/general/search.svg`
及深色变体，保留原始 16pt 和资源颜色；不使用会统一染色的兼容图标包装。

## 打开其他项目的选择弹窗

`RootView` 的项目打开位置提示复用 `LitheCenteredPopup` 的带标题居中窗口，
不使用系统 sheet 的大圆角卡片。内容使用现有 `LitheCommitDialogStyle.background`、
13pt 正常文字、原始 16pt IDEA 问号图标、`LitheSettingsCheckbox` 和 `LitheActionButtonStyle`；
主按钮保留蓝色动作语义，普通按钮使用统一边框和悬停配色，不单独绘制页脚色块。

保留取消、新窗口、此窗口与“不再询问”的原有行为。Return 选择此窗口，Escape 或标题栏关闭
取消本次打开；取消必须匹配请求 ID，避免旧弹窗回调清掉新的请求。仅发起请求的窗口显示弹窗，
并通过共享容器拦截父窗口输入，独立窗口、主题和语言沿用已有窗口环境。

## macOS 编辑器缩略图的分隔装饰

Monaco WebKit 的缩略图阴影会退化为 1pt 深色线，右侧概览标尺还有独立边框。
现有 `frontend/editor/src/theme.ts` 统一将 `scrollbar.shadow` 与 `editorOverviewRuler.border`
设为透明，主编辑器、分屏和主题切换共用该主题入口；不改第三方源码，不隐藏标尺本体。
缩略图导航、滚动和诊断标记仍保留。真实 WebKit 集成检查核对阴影颜色与标尺左边缘像素。
Windows 当前使用自己的编辑器主题适配器，本次不迁移其主题。

## 多项目标签的选中与悬停

`WorkbenchView.projectTab` 的项目切换标签使用紧凑标签语义，不套用动作按钮样式。
标签按名称、当前文档和 Agent 提醒的文字与图标度量分配宽度，限制在 120～360pt；
超长文字截断、超出容器的标签横向滚动，切换项目继续自动滚动到活动标签。
标签使用 28pt 高度、4pt 圆角、6pt 间距；选中使用 `subtleSelection` 中性底色，
未选中悬停使用 `hoverBackground`，移除焦点式外框和底部指示线。
这些是本轮 Lithe 紧凑项目标签的布局值，参考 Community `ManyIslandsDark.theme.json`
对 hover 与 selected 的区分，不声称复制 IDEA 的项目窗口标签几何。

多项目时，标签栏放在左右工具栏之间，与工作区内容组成一列；两侧工具栏与
标签栏从同一高度开始。中间列左右各保留 4pt 真实间隔，标签栏下方也保留 4pt；不拉伸标签或加装饰块填空。
标签栏外容器复用 `workbenchPaneChrome` 的 10pt 圆角和窗口渐变收口，
不再单独裁剪成 6pt 圆角；内部标签仍保留 4pt 圆角。
单项目继续隐藏标签栏并保留原间距；不改变其他面板的颜色、圆角、标题栏和内容。

项目名统一 13pt Regular；目录与关闭动作使用已有 IDEA 16pt 明暗资源，
标签与关闭按钮保留默认箭头。保持项目切换、关闭行为和 Agent 提醒。
关闭按钮仍在选中或悬停时出现，点击不触发项目切换。

## 原生窗口布局反馈的边界

SwiftUI 更新锚点时，AppKit（macOS 原生界面库）可能还在计算父窗口布局。
此时直接创建子窗口、替换浮层内容并强制布局，会把新的尺寸计算压入同一个
调用栈。首选内容尺寸变化后又立即调整窗口，也可能在调整尚未结束时再次进入
尺寸回调。因此共享呈现器保留原生窗口，但把锚点请求和尺寸通知合并到主队列
的后续执行机会；同一轮多次更新只读取最后的内容、环境和尺寸。

正确做法是由共享协调器持有一个待执行请求，弱引用锚点和父窗口；卸载、移出
窗口或关闭时使请求失效。控制器关闭后清除尺寸通知，旧通知不能调整后来打开的
面板。不要在业务菜单里加延时常数，也不要让排队闭包强持有窗口，使已关闭的
浮层重新出现。原生尺寸调整仍保留直接入口，防止重入；尺寸和约束相同就不重复
赋值，变更 frame 时不立即强制显示，由 AppKit 下一次显示处理绘制。

同一窗口角色的模型更新也不重新设置 `contentMinSize`（原生窗口的最小内容
尺寸）。窗口协调器只在绑定新窗口或切换欢迎页、工作台等角色时应用角色尺寸，
普通更新保留 SwiftUI 已测量的最小值，同时继续更新窗口标题。

对照 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的
`platform/platform-impl/src/com/intellij/ui/WindowResizeListener.java`：上游按当前
最小尺寸限制用户拖动后的 bounds。Lithe 保留已有尺寸限制，排队与重入保护处理
的是 SwiftUI/AppKit 的原生反馈边界，不照搬 Swing 窗口生命周期，也不改变样式。

这项约束处理 [#1138](https://github.com/1lck/Lithe-IDEA/issues/1138) 排查中发现的
同步反馈风险。该报告已确认主线程布局递归栈溢出，但未定位具体触发控件；回归
测试能证明上述反馈和清理边界，不能据此宣称原始会话的致命崩溃已完整复现。
代价是浮层更新晚于当前视图更新栈；不采用禁用整个窗口自动尺寸测量的方案，以免
破坏其他 SwiftUI 内容的布局。此改动不增加资源、缓存或 bundle 写入路径。

## 验证

- `AgentActivityPresentationTests` 的切换场景先完成父视图布局，再有界等待已提交的主队列更新交付，然后检查长列表滚动、最后一个文件回调和面板复用。不能把旧面板仍然 `isVisible` 当作新内容已显示，否则下一次点击可能落到旧内容的可选文本并进入原生鼠标跟踪等待。
- `preferredSizeChangesCoalesceWithoutReenteringTheCallback` 验证一轮尺寸变化只通知最终值，回调触发的新尺寸在后续执行机会交付，回调深度保持为一；`closingContentCancelsQueuedSizeFeedback` 验证移除回调后排队通知失效。
- `dropdownPresentationDefersLayoutAndUsesTheLatestContent` 在深浅外观的原生父子窗口中验证延后打开、最新内容与环境、合并为一个子窗口，以及更新或首次打开尚未交付时卸载锚点不会重新出现面板。
- `workspaceUpdatesPreserveTheHostingWindowsMeasuredMinimum` 验证同角色更新保留宿主测量的窗口最小值、标题继续更新，切换欢迎页角色仍应用声明尺寸。

`ContextMenuCoverageTests.dropdownTriggerClosesItsPopupAndSwitchesToAnother` 用原生
窗口事件覆盖深浅主题、动作及自定义菜单：重复点击原按钮关闭、另一按钮直接切换、
空白处关闭；等待都有局部期限，窗口卸载负责清理弹窗。数据库表需在中文界面用
同时含 `Name`、`名称` 的表检查筛选、排序、批量更新和替换的目标列显示。

- `AgentMavenAppearanceTests` 验证 Agent 表面在所有应用配色和明暗外观中跟随共享主题，并逐个用 AppKit 解码 Maven 的明暗 SVG，检查 16×16（Profiles 为 17×16）原始尺寸与可见像素；这些资源检查不代替完整应用交互验收。

- `MonacoEditorContextMenuTests` 检查真实原生菜单面板在明暗主题下的共享尺寸、无动画、禁用跳过、选中/取消回复、官方 SVG 的 16×16 尺寸与资源可解析性，以及非法展示数据拒绝。
- `./scripts/probe-macos-monaco.sh --workbench-tests` 使用正式 macOS 前端入口，验证真实 Monaco 菜单经过原生桥接而不产生网页菜单，同时保留既有菜单事件。`context-menu.integration.ts` 验证动态条目、分组、快捷键、实例前缀映射、动作上下文、原 action runner、取消/失败/替换和卸载后的旧响应。

- `ContextMenuCoverageTests.contextMenusCannotSilentlyBypassSharedStyle` 阻止产品重新使用 SwiftUI `Menu`、`.popover`、`NSPopUpButton` 或非 segmented 的原生 `Picker`。
- `nestedDropdownKeepsParentAndRoutesKeysToChild` 验证子菜单右侧对齐、靠右边缘时向左打开、不关闭父面板、按键只选择子菜单动作、两层独立关闭。
- `WorkbenchNotificationTests.balloonUsesSourceColorsAndWrapsLongMessages` 捕获深浅主题的真实通知组件，检查背景、边框、图标资源、短通知尺寸和长消息换行；原有模型测试继续检查队列、关闭和历史状态。
- `WorkbenchNotificationTests.notificationTimersPauseIndividuallyAndWhileTheApplicationIsInactive` 使用可推进时间和有界信号检查 10 秒超时、单条 hover、后台暂停以及剩余时间恢复；`overflowCollapsesIntoHistoryAndClosingBalloonsPreservesMessages` 检查三条上限、折叠计数和历史保留。
- `sharedContentInheritsEnvironmentAndClosesWhenAnchorDetaches` 验证真实宿主继承环境对象和语言，锚点移出窗口立即关闭并清理。
- `itemBuilderKeepsConditionalActionsDisabledChoicesAndSubmenus` 验证条件、动态条目、勾选、禁用、子菜单及危险动作类型保留。
- `WorkbenchRenderingSafetyTests` 检查项目/分支使用共享入口，打开时保持 hover 色而不是菜单选中色。

- `ContextMenuCoverageTests.projectPopupMeasuresContentInsteadOfKeepingA390PointWidth` 检查短路径自然宽度，以及长路径和分支不受普通操作菜单上限限制。
- `ContextMenuCoverageTests.topbarDropdownsLeaveToolbarMarginAndRenderRealSharedContent` 渲染真实项目/分支菜单的明暗原生窗口，检查锚点槽位、无动画、宽度限制、打开时按钮保留 hover 底色、关闭后释放、卸载关闭，并可保存捕获图。
- `ProjectSwitcherBranchTests.projectMetadataReadsCurrentBranchWithoutChangingIdentityDrafts` 通过真实 Core 仓库检查器验证普通目录省略分支、未提交仓库显示当前分支、外部切换后重新读取，以及身份编辑草稿不受影响。
- `BundledUIFontTests.packagedFontsRegisterAtProcessScopeAndRemainUnchanged` 用实际注册字体比较共享项目徽标与 JetBrains Mono SemiBold 13pt 的白色字母像素，防止回退到 Inter Bold；字体资源注册与清理沿用原测试所有权。
- `ContextMenuCoverageTests.projectAndActionDropdownsRenderTheSameChrome` 捕获真实原生菜单面板，检查 Project 与设置菜单在明暗主题下的背景、边框和高度。
- `ContextMenuCoverageTests.submenuStartsAtItsTriggerRowAndKeepsCopyTitlesVisible` 捕获真实明暗菜单，验证靠下的触发行、子菜单上方透明区、主菜单位置固定及完整复制标题的宽度。
- `ContextMenuCoverageTests` 验证键盘跳过禁用条目、子菜单导航、长菜单可见范围和动作调用；`filterPopoverAnchorLeavesMouseEventsToItsButton` 验证定位锚点不截获按钮的鼠标命中。
- `ContextMenuCoverageTests.searchableFilterContentCannotCoverSharedRoundedCorners` 在明暗主题渲染真实 Branch/User 内容，检查四个圆角透明、内部仍为不透明底色。
- `ContextMenuCoverageTests.searchableDropdownUsesSharedWindowAndDismissal` 验证可搜索面板的透明无边框窗口、动态尺寸、Esc 关闭与关闭回调只执行一次。
- `ContextMenuCoverageTests.anchoredActionAndSearchableDropdownsShareTopLeft` 验证相同锚点下 Date 操作菜单与可搜索内容的左上角一致、无动画、键盘关闭回调及屏幕边界限制。
- `SettingsSelectPopupGeometryTests` 验证设置选择控件定位边界；真实父/子面板验证 Database 一类表单弹窗内打开选值菜单时保留父面板，Esc 只关闭子菜单并解除窗口关系。
- 执行 `./scripts/verify-agent-notes.sh`、`./scripts/verify-service-boundaries.sh`、`./scripts/verify-runtime-bundle-immutability.sh` 和 `./scripts/verify-platform-feature-matrix.sh`。
- 组件检查不能替代 `./scripts/preview.sh` 的完整应用检查；实际预览还需确认
  分组开合、原生侧向子菜单、搜索焦点与输入、通知历史入口以及主工具栏动作。

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

### 统一 Repository Diff 面板

Commit 工作区、项目树文件/目录差异、编辑器行变更和冲突文件入口，与 Git Log、
Stash/Shelf 共用 `RepositoryDiffView`。它以原 Git Log 新版工具栏和原生单栏/双栏为
唯一面板，删除 `DiffReviewView`、旧单栏行、旧连接带与 `DiffMapView`，不保留备用旧路径。
仍在使用的字体/布局度量和语法高亮分别归 `DiffLayoutMetrics`、`DiffSyntaxHighlighter`。
工作区模式保留搜索、空白比较、整文件暂存/取消暂存/丢弃与差异块动作，继续调用原有
GitFeatureModel 写入及确认流程；只读历史/保存记录模式不提供这些写入动作。
差异块入口锚定该 hunk 的首个差异行；纯删除使用左栏，新版单栏也保留动作。
分支比较、本地历史与 Agent 的嵌入式预览继续复用 `DiffPaneView` → `DiffSplitPaneView`，
它们不承载仓库暂存操作，也不是被删除的旧工作区面板。


### 普通选中行与窗口焦点

项目树原先固定使用灰色选中底色，其余列表也有只用活动色或只用灰色的入口。
现在普通树和列表都通过 `litheSelectionRow(isSelected:isFocused:)` 绘制选中与
悬停表面。单行树由 `litheTreeRow` 转交；多行列表直接调用该入口，保留原行高、
内边距、字体和圆角参数。只有“区域有焦点”且“窗口接收键盘输入”同时成立才显示
主题活动色；失去任一条件都显示灰色。窗口是否活动由共享样式读取
`controlActiveState == .key`，不能让每个新调用方自行决定是否检查。

颜色依据 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的
`platform/platform-resources/src/themes/islands/ManyIslandsDark.theme.json` 与
`ManyIslandsLight.theme.json`：普通选中行读取 `selection-bg-active` 和
`selection-bg-inactive`。Lithe 默认主题的深色活动/失焦色为 `#2A4371/#33353B`，
浅色为 `#D0DFFE/#E9EAEE`；其他主题沿用既有主题定义，不逐页面复制颜色。

区域焦点沿用 `LitheToolWindowActivityTracker`，应安装在列表所在区域，不能
装在整个工作台后让多个列表同时变蓝。观察器按实际被编辑的输入框判断焦点，
不能只比较 macOS 共用的 field editor（窗口内多个输入框共用的文本编辑器）；
鼠标回调、焦点变化和卸载共用事件版本；延迟点击只有版本仍最新、窗口未变且
当前 focus owner 未变时才能发布点击状态，否则按当前 responder 重算。
卸载时立即移除观察器并使旧版本失效；清除活动状态和重新挂载同步当前可见焦点
区域均在下一次主队列回调发布。挂载、卸载及窗口通知不得同步写 SwiftUI Binding，
否则真实 NSHostingView 销毁期间会与 GraphHost.invalidate 发生独占访问冲突并
触发 SIGABRT。旧挂载或较早点击的回调不能覆盖新焦点。

项目树是已有键盘路由的特殊消费者：`ProjectTreeKeyboardCommands` 发布
键盘归属变化，颜色与实际消费方向键的区域一致。通过窗口 didUpdate 及时识别
新获得焦点的文本框，搜索框尚未输入字符时树就失焦；其他编辑器仍保留首次按键
建立基线的异步聚焦处理。直接套用普通区域观察器会在
文件打开后的 WebKit 异步聚焦中误判。惰性树内容的相等判断必须包含焦点，
否则选择不变时不会刷新颜色。保留原有多选、上下键、右键和文件打开行为。

SwiftUI 消费者包括 Project、Commit、Maven、Git Log 分支/比较/Rebase 计划、Run 的范围和配置
列表、PR 列表、Redis 键、Nacos 配置、数据库 SQL 历史、本地/项目历史、Debug
堆栈、Language Tests、Agent 历史多选、Settings 分类/项目运行时/快捷键以及
插件市场列表。各独立列表分别观察焦点。Git Log 原生提交图谱在宿主更新时结合
窗口活动状态；原生 Git 文件树保留 `isKeyWindow` 和 first responder（键盘
输入接收视图）判断，并在宿主窗口状态改变时重绘。Shelf 的原位展开行沿用
共享树色与窗口判断，不替换其已有展开 renderer（负责行绘制的组件）。

正确做法是给已有多行历史行调用
`litheSelectionRow(isSelected: selected, isFocused: historyListActive)`，再在
历史列表区域安装已有观察器。不要写 `.background(selected ?
LitheTheme.selection : .clear)`；这种写法无法在窗口失焦时切换灰色。
不要把只读详情或相邻列表的活动状态传给该历史行。

工具窗口标签、菜单高亮、活动栏、数据库单元格、编辑器文本选择、状态徽章、
复选框包含状态和选定设置值有各自语义与主题，不强制与普通行的 RGB 相同。
它们继续使用各自共享样式；没有持久选择的 Dependencies、普通 Search 结果
也不会因此新增选择功能。Windows 本次未修改；其文件树已有
`data-tree-focused` 在 `--selected` 与 `--border` 之间切换，不能把 macOS
组件验证当作 Windows 实机验收。

统一入口减少遗漏窗口判断和重复颜色的机会，代价是每个独立列表仍需明确提供
区域焦点状态。没有把所有页面强制改成 24pt 树行，也没有新增第二套焦点系统。

回归通过 `LitheTreeRowStyleTests` 检查真实绘制的深浅色、区域活动/失焦与
窗口 key/inactive 状态，以及 24pt 树和 40pt 多行尺寸；
`ProjectTreeSelectionTests` 检查方向键和多选；
`EditorTabOrderFeatureModelTests.tabActivityFollowsNativeKeyboardFocusAcrossRegions`
检查原生区域及共用输入编辑器之间的焦点转移、卸载失效和重新挂载同步；
`delayedPointerActivityCannotOverrideNewerFocusOrRemount` 用可控回调队列验证
较早鼠标写入不能覆盖新 responder（包括窗口通知尚未发布）或新挂载；
`treeYieldsToSearchBeforeTypingButRetainsAsynchronousEditorFocus` 验证搜索框
尚未输入即失焦，以及真实 WKWebView 异步聚焦仍保留项目树键盘归属。
`trackerUnmountDefersBindingWritesUntilTheLifecycleCallbackReturns` 检查生命周期内
没有同步 Binding 写入，`activityTrackerCanDestroyItsSwiftUIStateOwner` 覆盖真实
SwiftUI State 宿主销毁和主队列清理，不能只靠手写 Binding 的组件测试推断安全。
完整应用验收与组件回归分别记录，
不由编译或单一页面截图推断整个产品已验证。

深色新预览已通过真实鼠标验证 Settings 分类：点击分类显示主题色，点击右侧
内容变灰，重新点击恢复。完整应用全部入口、浅色/非默认主题和跨窗口切换仍
保留 pending；共享像素与原生焦点回归不替代这些实机验收。


### Git Log 非仓库空状态的文字度量

空状态复用 Lithe 的 Inter 字体入口，但不能直接用 SwiftUI 自然行高替代
Community 的文字行容器，否则相同 13pt 字体看起来会更挤，行首破折号也可能偏离基线。
字体和链接标签明确使用 13pt Regular，行首 `—` 与链接按首行文字基线对齐，
保留原始字符和一个空格的宽度，不画替代短线。度量与专用颜色由
`LitheTheme.ToolWindowEmptyState` 管理，供 Git Log 与 Debug 空状态共用，不修改普通页面文字颜色。

依据 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade`：
`platform/vcs-impl/src/com/intellij/openapi/vcs/changes/ui/VcsToolWindowEmptyState.kt`
选择普通链接 `LINK_PLAIN_ATTRIBUTES`；
`platform/platform-api/src/com/intellij/util/ui/StatusText.java` 使用标签字体和 2pt 行间距；
`platform/platform-api/src/com/intellij/ui/SimpleColoredComponent.java` 的每行高度还包括
上下各 1pt 内边距和上下各 1pt 边框留白。使用本机 JBR 的标准 AWT 字体度量，
仓库 Inter-Regular 13pt 的字体高度为 17pt，因此固定基准行高为 21pt，不能遗漏这 4pt。
`platform/platform-impl/src/com/intellij/ide/ui/laf/LafManagerImpl.kt` 明确使用 Inter 13、Font.PLAIN。

灰字取 `SimpleTextAttributes.GRAYED_ATTRIBUTES` 对应的 `Component.infoForeground`，
沿 Islands → ExperimentalDark/ExperimentalLightWithLightHeader → Darcula/IntelliJ
继承到深色 `#787878`、浅色 `#999999`；链接取 Islands 的 `Link.activeForeground`，
深色 `#71A1FE`、浅色 `#2F5EB9`。其他 Lithe 主题继续使用各自的语义颜色。
IDEA 此入口默认不画链接下划线；Lithe 按用户要求保留悬停手形和主题强调色下划线，
这是产品约定，不声称是 IDEA 的默认绘制。

验证需同时查看明暗主题、单个链接悬停、移开恢复、初始化确认与设置入口；
`BundledUIFontTests` 只确认真实字体资源和字体度量，不替代整个空状态的视觉验收。

### Debug 空状态与会话内容

Debug 空状态沿用同一 Community revision 的
`platform/xdebugger-impl/src/com/intellij/execution/actions/ActivateDebugToolWindowAction.kt`：
三行操作说明、配置文字链接、空行和 `general/contextHelp.svg` 帮助链接。
`StatusText` 采用左对齐文本块、水平居中、纵向三分之一定位；字体、行高、颜色及产品要求的
手形/主题色悬停下划线复用 Git Log 的共享定义。无内容时不显示配置标签、调试工具栏和 Ready 状态。

可见条件追踪到 `ToolWindowImpl.getEmptyText` →
`platform/platform-impl/src/com/intellij/ui/content/impl/ContentManagerImpl.java` 的
`MyNonOpaquePanel` → `JBPanelWithEmptyText.isStatusVisible`：没有可见子内容才绘制空状态。
`ToolWindowContentUi.ensureSelectedContentVisible` 在没有选中内容时移除内容组件。
自然结束但保留的会话继续显示。Lithe 的 Stop 停止执行，但保留 Console 输出，
不能把它等同于关闭内容标签：停止最后会话后，已有日志或错误仍属于可查看内容，
工具栏与 Console 标签必须保留；停留在 Threads & Variables 时仍可切回 Console。
只有没有会话、活动、保留输出及错误时才回到引导；显式重置继续清空历史。
Lithe 的启动失败可能尚未建立会话记录，此时保留诊断与重试界面。

上游配置链接打开 `EditConfigurationsDialog`；Lithe 复用已有 Run 面板的配置入口，
不另造配置对话框，也不自动启动调试。Lithe 尚无独立的 ChooseDebugConfiguration 快捷键，
因此不把“开始调试”的快捷键冒充配置选择快捷键。帮助链接指向 JetBrains 公开调试文档。

`DebugModuleTests.emptyStateFollowsRetainedContentRatherThanRunningStateOrOutput`
覆盖初始空状态、活跃会话、无输出的自然结束、带缓存输出的停止、启动失败/重试及重置。
`stoppingTheLastRunningSessionKeepsConsoleOutputUntilItIsCleared` 验证运行中产生输出后主动 Stop 仍可查看，清空输出后才回到引导。
完整应用还需核对明暗主题、两个文字入口及空状态/会话界面切换；模拟会话测试不替代真实 DAP 验收。

Debug 空状态标题栏使用 Git Log / Terminal 已有的 41pt 工具窗口规则：
13pt Bold 标题、左 12pt / 右 8pt 留白、两侧各 2pt 的 22pt 图标按钮，
`expui/general/moreVertical.svg` 与 `expui/general/hide.svg` 原始 16pt 资源。
底线复用 `LitheToolWindowHeaderDivider` 的主题边框颜色、1pt 高度和两侧 1pt 内缩，
以内侧 overlay 绘制，不能再叠加普通 divider，也不使用旧 `LitheToolWindowHeader` 的 30pt 度量。

标题栏源码依据同一 Community revision 的
`platform/platform-impl/src/com/intellij/toolWindow/ToolWindowHeader.kt`：New UI 高度走
`JBUI.CurrentTheme.ToolWindow.headerHeight`，工具栏保留原动作按钮度量，
`paintComponent` 根据工具窗口边界绘制底线。Lithe 在已对齐的 Git Log/Terminal 入口复用对应规则，
Debug 空状态与活动会话均使用同一标题栏规则。

### Debug 活动会话布局

同一 Community revision 的 `XDebugSessionTabNewUI.kt` 将顶层调试动作交给
`RunTab.RunTabSupplier`；`SingleContentLayout.kt` 根据 `debugger.toolbar.before.tabs`
在同一行先排工具栏、再排内容标签。Lithe 因此取消单独占一行的内容切换栏，
只显示已有 Threads & Variables / Console，不移植 Beans、Health、Mappings 等产品没有的入口。

会话及内容标签直接消费 `LitheToolWindowTabStyle`，会话关闭直接消费
`LitheToolWindowTabCloseButton`，整个 Debug 区使用独立活动跟踪器；调用栈列表仍保留自己的
焦点跟踪器，避免变量/控制台获得焦点时激活调用栈选中项。标题栏保持 41pt、13pt Bold，
会话标题/内容标签为 13pt Regular，16pt 图标使用标准 22pt 工具栏命中范围，禁用透明度
仅由共享按钮 owner 处理一次。内容标签旁不显示状态圆点和状态文字；停止位置跳转入口继续保留。

控制台保留 `OutputTextView` 的 ANSI 渲染、链接定位、滚动与复制功能，只通过既有字号参数
采用 13pt 代码字体；暂停求值、历史与程序输入继续保留，不另造调试控制台。
变量与监视项的值/类型颜色由 `LitheTheme.Debugger` 统一保存，取 Islands 明暗主题的
`Debugger.Variables.valueForeground/typeForeground`，不用强调色冒充普通变量值。
普通标签、代码字段和原始图标恢复各自正常尺寸，不把所有小图标字体一并放大。

验证需要区分空状态、运行中、暂停、失败和结束的布局；检查内容切换、窄窗口横向可达性、
会话停止、断点/求值动作、明暗与焦点切换。纯布局调整不能作为 DAP 能力新增或 Java 启动成功的证据。

本地验证：69 项 Debug 模块/工具栏/字体/渲染安全测试通过；最后的配置选择器与监视按钮调整后，
再次通过 16 项相关呈现测试。实际 backend 会话已检查深浅主题下的控制台与线程/变量标签切换，
其启动因本机 Redis 连接被拒绝而退出，不能记为服务启动成功。最终重新打开项目的原生界面检查
连续超时，因此最终构建的真实暂停、求值、窄窗口及停止按钮交互仍待验收；不据此改变 DAP 行为。

Debug 标题栏不再重复放置运行配置选择器；配置选择统一使用窗口顶部已有入口，
标题栏只保留实际会话及其切换/停止入口。删除局部选择器，不改变配置选择或启动逻辑。

### Debug 图标的 New UI 映射与 Console 呈现

截图上的差异不能只靠字号或透明度补偿。Community 同一 revision 的
`platform/icons/src/PlatformIconMappings.json` 把旧 Actions/Debugger 名称映射到
`expui/run`。Debug 主操作现在使用这些原始 16pt 明暗 SVG，仍由共享 22pt 按钮处理命中及悬停。
禁用时使用 `GrayFilter.java` 的 NTSC 灰度、立方亮度与对比度运算，参数沿 Islands 继承到
Darcula `-70,-70,100` / IntelliJ `33,-35,100`；保留原 alpha，不再叠加按钮的 0.45 透明度。
该行为通过图标和按钮的显式参数接入，不改变其他共享按钮消费者。

Console 使用 `ConsoleViewUtil.updateConsoleColorScheme` 的独立控制台字体/配色语义，
样式入口是 `LitheConsoleStyle`，现有 `OutputTextView` 默认且统一应用；面板不能另选旧样式。
`IslandSchemeDark.xml`、`Light.xml` 与 `DefaultColorSchemesManager.xml` 提供普通输出、链接、
折叠占位和 16 色 ANSI 色板。移除调试 Console 自行淡化时间戳和按级别整行重涂的行为，
保留生产者的 ANSI 真彩、常规/亮色和真实字重，不根据字符串猜测 stderr。
旧 `Severity` / `applySeverityColors` 整行染色实现已删除，不再按 INFO 字符串将正文染蓝。
Test、Debug、Run 共用 `LitheConsoleStyle` 的控制台字型和 ANSI 色板。
默认字号、行高、底色、链接及日志级别颜色均由共享入口持有，调用面板不重复声明。
带括号或时间戳前缀的级别标签统一为 INFO 绿色、WARN 黄色、ERROR/FATAL 红色，
使用现有 ANSI 色板；只覆盖级别文字，保留正文、时间、类名的生产者样式与真实字重。
当前纯文本快照没有完整保留 stdout/stderr 的通道信息，本次不能据此宣称完成通道语义对齐。

字号操作按 `ChangeEditorFontSizeAction` 每次 1pt、8pt 下限与 `EditorFontsConstants` 的默认
40pt 上限，提供当前 Console 的增大/减小/重置操作，不缩放工具栏或其他输出面板。
不擅自为未映射的 IDEA 字号动作增加全局快捷键。Console 展开与字号状态由 Debug 视图持有，
内容标签切换不会重置，实际绘制仍交给原生 NSTextView。

折叠移植 `java/execution/impl/.../StackTraceFolding.kt` 与设置的默认值：保留前 8 帧，
其余连续 Java 堆栈帧（包含 enclosed more 与 async 标记）形成外层折叠；内部行采用
`java/java-backend/resources/META-INF/JavaPlugin.xml` 的 54 个默认子串及 Java module 前缀归一化，
按 `SubstringConsoleFolding` 附着到前一行，作为低优先级嵌套区域。没有移植 IDEA 插件扩展系统
或个人自定义折叠设置。点击占位文字展开/收起，右键可全部展开/收起；复制选择及全部输出均
还原完整原文，不把占位文字写入日志，也不破坏展开后的源码链接。

原始富文本与显示投影分开保存，继续使用原增量输出更新；投影只替换可见文本发生变化的尾部。
扫描受 Debug 原有 400,000 字符上限及 100ms 发布节奏限制，并用一万帧输入验证。若扩大日志
上限或发布频率，先把折叠扫描改为按脏行索引，不能直接提高上限后依旧全量扫描。
测试覆盖嵌套、Unicode、8 帧边界、原文复制、ANSI 常规/亮色、缩放边界及半透明图标灰度。

本次 Console 回归共 50 项通过并生成单测试计时报告；一万帧折叠投影/复制在本机记录约 34ms，
不是整屏帧率证明。覆盖日志分块未完成的末行、只改变 ANSI 样式的替换、UTF-16 边界以及
无效 ANSI 索引。最终预览已打包启动，但打开 backend 后原生界面检查再次超时，
因此真实点击折叠/字体菜单和最终明暗整屏效果仍待验收，不能把上述组件测试当作完整 UI 验收。

Console 行距采用 `FontPreferences.DEFAULT_LINE_SPACING = 1.2`，而不是 NSTextView 自然行高。
`ConsoleViewUtil` 将颜色方案的 ConsoleLineSpacing 交给编辑器；`EditorView.getLineHeight`
在默认关闭 xcode/correct.rounding 两个 registry 分支时，对字体度量高度乘行距后向上取整。
本机参考 IDEA 的 console-font/editor-font 配置没有覆盖默认值；用 JBR 读取仓库 JetBrains Mono
Regular 13pt，ascent/descent 为 14/4，原高度 18pt，得到 22pt 行高。Lithe 用相同字体度量规则
设置段落最小/最大行高，折叠占位及字号改变后均更新段落样式，不只给正文添加固定行间空白。
启动或重启调试默认选择 Console；原有断点暂停切到 Threads & Variables 的行为保留。


## 主工具栏执行按钮的运行状态

Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的
`platform/execution-impl/src/com/intellij/execution/ui/RedesignedRunWidget.kt`
中 `RunWidgetButtonLook` 给运行中的执行动作和停止动作保留独立底色，
并通过 `toStrokeIcon` 把图标转为白色。Islands 深色底分别解析为
`#338555` / `#C54E58`，浅色为 `#4E9D6C` / `#E4656E`；
hover/pressed 叠层按该主题的 RunWidget token 解析，不能改用普通选中蓝色。
`JBUI.CurrentTheme.RunWidget` 提供30pt按钮和16pt图标，
`HeaderToolbarButtonLook` 的主工具栏圆角直径12（半径6），外侧留白沿用现有入口。

Lithe 在 `LitheMainToolbarButtonStyle` 增加可选执行底色，默认调用者保持原样。
运行/调试各自按原有会话状态启用绿色底，停止使用相同外框和
`expui/run/stop_stroke.svg`，移除停止按钮局部28pt外框及手形光标。
保留现有动作、提示和可见条件，没有把参考图中的其他动作加进来。
使用 `MainToolbarAppearanceTests` 验证明暗底色、按下叠层和外侧留白，
完整工作区的启动/停止与hover仍须在预览中检查。

主工具栏的Run槽位同时承担当前目标的调试暂停/继续控制。依据Community
`idea/262.9437.185`（`b75ab523e6adbe1d26112219729eacbcfd24daa0`）的
`RunToolbarXDebuggerAction.kt`、`RunToolbarDebugActionHandler.kt` 与
`RedesignedRunWidget.filterOutRunIfDebugResumeIsPresent`，选中目标正在调试时隐藏
普通Run：运行状态显示Pause，暂停状态显示Resume；旁边的重新调试和停止仍保留。
复用Debug工具栏既有的 `expui/run/pause.svg`、`resume.svg` 原始16pt明暗图标与
普通主工具栏按钮外框，不给这两个控制添加重跑按钮的绿色常驻底色。
动作仍由宿主注册表执行，控制Debug时采用Debug模块权限，并在执行请求未完成时禁用，
避免多次继续或误启动另一轮Run。调试结束或选择其他目标后恢复Run/Rerun。
当前摘要只公开启动标题，暂按选中标题匹配；将来启动契约提供配置ID后应改用ID，
不能把所有工作区里任意暂停会话都当作当前运行目标。回归检查覆盖各会话状态、目标
切换及主工具栏动作权限，实际预览还需验证按钮能继续到下一断点。
顶栏已选测试目标时，统一的 `AppModel.startDebugging` 入口必须调用已有Java测试调试
工作流，与Run入口使用同一个 `activeTestTarget`。不能一边显示测试方法名，一边启动
底层Main配置，否则不仅目标错误，按目标匹配的Pause/Resume也会被正确地隐藏。

输出区“Jump to latest”对应同一Community版本的 `ScrollToTheEndToolbarAction.java`，
动作图标 `RunConfigurations.Scroll_down` 在 `PlatformIconMappings.json` 映射为
`expui/general/scrollDown.svg`。复用现有16pt明暗资源和共享22pt工具栏按钮，
不显示文字、胶囊背景与描边；仅共享hover/按下反馈，保留可访问名称与提示。


Console日志高亮沿Community同一revision的
`platform/platform-util-io/src/com/intellij/execution/process/AnsiEscapeDecoder.java`
和 `platform/platform-api/src/com/intellij/execution/process/ColoredOutputTypeRegistryImpl.java`
处理程序输出的SGR，而不是猜测日志格式后重涂时间、级别或类名。
Debug输出清理器之前删除了所有CSI，导致Logback本身的 `%cyan`、`%highlight`、
`%boldMagenta`失效。现只保留以数字/分号组成、最多128字节的完整SGR序列，
保留跨分块解析状态；OSC、光标/屏幕命令、私有和超长CSI继续过滤。
未输出颜色的普通日志仍保持普通颜色，不伪造Spring插件的高亮规则。

展开后的Console折叠位置对照 `EditorGutterComponentImpl.drawDirectedBox` 的New UI路径，
使用 `expui/gutter/fold{,_dark}.svg` 的9×9原始资源，画在正文左侧，
不再把 `▾`作为文字插入日志。展开位置以富文本元数据保存，绘制和鼠标命中仅枚举
可见字符，不在高频指针事件中重新扫描或重建日志。原文复制和源码链接保持不变。
用户明确要求折叠占位hover手形；这里只给正文链接使用手形，左侧折叠图标保持箭头。
通过原生窗口事件测试折叠占位光标和标记点击；明暗ANSI及Logback组合、跨分块和
超长/私有CSI均有回归测试。完整应用视觉及真实SVG渲染仍需新预览验收。

收起状态同样显示折叠栏：`EditorGutterComponentImpl.drawSquareWithPlusOrMinus`
在New UI路径使用 `Gutter.Unfold`（`expui/gutter/unfold{,_dark}.svg`，9×9）。
展开使用 `Gutter.Fold`，两种状态复用同一原生位置计算与点击处理；折叠占位文字
仍可点击展开。回归测试覆盖两个状态标记的命中和展开后原文宽度不变。


## Debug输入入口与Console正文

Console不再常驻两个固定输入栏。表达式求值复用变量区顶部的现有入口，Enter及
执行图标调用同一个求值动作，并切换Console查看原有结果输出；“＋”仍然添加监视。
历史表达式复用原有会话历史，挂到求值图标的共享右键菜单，避免给输入框覆盖一套
会吞掉原生剪切/复制/粘贴的菜单。

标准输入参考Community同一revision的 `ConsoleViewImpl.insertUserText` / `doInsertUserInput`：
输入直接跟随输出，不画另一行固定表单。`OutputTextView` 可选的标准输入回调仅由
Debug接入；其他输出页面仍只读。原生文本控件只允许改动尚未发送的尾部，历史日志
不会被退格、选区删除或粘贴改写。发送保留现有AppModel标准输入通道和终端所有权。
存在活动 Debug Session 时，可用性与发送共用同一候选终端选择，只检查该会话的终端；
找不到或终端不可输入时拒绝发送。只有没有活动 Debug Session 的旧入口才保留全局回退，
不能因 A 的终端停止就把 A 的 Console 输入发给 B。双会话回归同时检查禁用、拒发与 B 的正常发送。
空行也能发送；发送失败保留草稿，成功后等待既有进程输出回显，不另外合成一份日志。

草稿由Debug既有视图局部呈现对象保存，不写入业务输出或持久化磁盘；会话ID改变时
清理，内容页签切换时保留。程序输出追加后保持草稿及相对光标，IME组合期间暂缓替换
显示投影，提交组合后应用待显示输出；切会话或关闭输入时结束旧组合，避免送给新进程。
可编辑Console的源码/折叠链接仍可直接点击，不引入AppKit可编辑文本默认的Cmd点击门槛。
控件复用Console字体、颜色、行高、背景及光标，不新增边框、按钮或固定工具条。

取舍：日志刷新或折叠重排后，原生撤销记录中的范围会过期，因此只保留两次输出刷新之间
的输入撤销；若需要持续输出时也保留多步撤销，应改用仅管理草稿的撤销栈，而不能让撤销
修改历史日志。使用 `ConsoleInlineInputTests` 验证输入边界、发送成功/失败、IME、输出追加、
会话切换、可编辑状态下的源码链接及折叠往返。完整工作区还需检查真实stdin与求值。


### Debug面板的分隔线

Debug标题、动作栏、线程选择、求值、变量/监视分组及Console诊断条统一复用
`LitheToolWindowHeaderDivider`；Console工具栏和Performance收起边缘使用同一
`LitheTheme.toolWindowBorder(for:)`，不再用通用`divider`近似工具窗口边界。
线程/变量与Console/Performance的可调整边界复用`LitheSplitPaneView`，与Git Log
使用同一分隔条、明暗颜色、调整光标和拖动结束提交规则；悬停和拖动不变亮。
边缘由单个容器绘制，展开时不叠加收起条的边线。

动作组之间的短竖线继续使用`LitheTheme.ActionToolbar.separator`；断点管理等独立
对话框仍使用现有对话框分隔样式。没有把这些不同角色的线强行替换成工具窗口边界。
验证复用`SplitHandleViewTests.sharedBorderKeepsItsColorDuringHoverAndDrag`的深浅主题
像素对比和原生鼠标事件，以及`LitheSplitPaneCollapseTests`的收起/恢复与拖动边界检查。


### Console动作栏的深色资源与禁用态

Console左侧动作栏保留Git Log共享的16pt图标、22pt按钮与4pt间距，
上下箭头必须包含Community同版本的`up_dark.svg`、`down_dark.svg`，
否则渲染器会回退到浅色图标的`#6C707E`，在深色背景上错误变暗。
完整深色资源使用原始`#CED0D6`；禁用状态复用现有`LitheIDEADisabledIcon`
灰度处理，并关闭按钮的二次透明度淡化。按钮动作、可用条件和共享hover不变。
`DebugToolbarPresentationTests.consoleActionsRenderNativeLightAndDarkAssets`
加载全部六个动作的真实明暗SVG，检查原始16pt尺寸及不透明像素颜色，避免资源遗漏。


### Performance图表的时间与悬停呈现

性能面板原来只有折线且平分剩余高度，导致曲线下没有填充、无法读取历史点，
并且少量样本被横向拉满。现在两项指标共用`DebugPerformanceChart`：
每项最高160pt，底部保留指标名称和共享边框色横线，折线下绘制同色12%面积填充。
时间轴固定显示最近60秒，最新真实采样位于右侧，新采样推进时历史向左移动；
未采样时间保持空白，不复制或插值生成历史。

两图共用悬停时间，吸附真实采样点并显示圆点、对应数值、竖向时间标记和时间。
采样推进时保持鼠标所在的相对时间位置；离开后恢复最新点。未知CPU读数显示缺失，
0%保留真实平线，单点仍绘制圆点；不会为了填充视觉而伪造波动。

行为参考JetBrains官方CPU and memory live charts文档中的悬停数值/时间说明。
公开Community中未找到该Performance绘图实现；此处复用系统Swift Charts的
`AreaMark`、`LineMark`、`PointMark`与坐标转换，没有声称照搬不可得源码。
现有OpenJDK数据采集不变。明暗主题、边框、字体使用Lithe共享入口；60秒窗口、
160pt高度和12%面积填充是本次Lithe呈现参数，不冒充Community主题常量。
验证：`DebugPerformanceChartTests`检查面积实际像素、深浅主题、真实采样吸附、
未知CPU和固定时间域右端/向左移动；完整目标JVM鼠标悬停交互仍须实机验收。


### 原生输出区域跟随工作台背景

Debug外层已透明，但Console原生滚动视图、输出容器、左侧动作栏和Performance
内部仍各自绘制固定底色，导致自定义背景在这些区域被遮挡。
`WorkbenchSurfaceBackground`现在同时向后代传递已有背景图片状态；
不持有`AppModel`的原生输出控件读取该环境值，SwiftUI叶子表面复用共享入口的
显式状态重载，避免向每个Run/Build/Tests/Database输出调用者重复添加判断。
Performance展开内容与收起条直接使用现有共享表面入口。

设置背景时关闭原生`NSScrollView.drawsBackground`，移除背景后恢复Console主题底色；
每次更新都明确设置两种状态，不能只在开启时清除，否则关闭图片后会残留透明。
更新不替换文字控件、不重置输出/折叠/输入草稿；ANSI片段背景、选区、输入框与菜单
继续保留其语义颜色，不属于结构底色。

`ConsoleInlineInputTests.wallpaperChangesUpdateEveryConsoleLayerWithoutReplacingInput`
在深浅主题重复关闭→开启→关闭，通过真实原生像素检查输出区及动作栏，
并检查输入草稿和文字控件身份。该组件验证不能替代完整工作台背景选择的实机验收。


### Console折叠图标的实际绘制边界

仅验证折叠锚点与点击，不能证明9pt SVG已经画出来。真实滚动视图的像素回归
复现了图标区域没有像素：`NSTextView.draw`遗留的正文裁剪范围遮住左侧留白。
`OutputNativeTextView.draw`在调用原生正文绘制前保存图形状态，之后恢复原始
裁剪再画官方Fold/Unfold图标；不改SVG几何、颜色或正文排版来掩盖问题。

日志投影发生变化及滚动时显式刷新可见折叠栏；只重画左侧留白，不替换文本控件，
也不扫描离屏全文。资源默认继续走`LitheIcons`，原生绘制器可接受资源加载闭包。
SwiftPM测试通过该入口加载与应用同一组真实SVG，避免缺少应用资源时“空图也通过”。
`ConsoleInlineInputTests.realScrollViewPaintsBothFoldMarkersAndTogglesThem`
在深浅主题逐次检查折叠/展开/折叠像素及原生点击；同一测试在修复裁剪前失败、
修复后通过，补足之前只验证锚点的漏检。


### Threads & Variables的共享样式

本页保留线程/调用栈、变量、表达式求值和监视四个已有入口，不复制IDEA的额外
数据能力。Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的
`platform/xdebugger-impl/ui/src/com/intellij/xdebugger/impl/frame/`
下`XFramesView`、`XVariablesView`、`XWatchesViewImpl`及
`ui/tree/XDebuggerTreeRenderer`区分普通界面文字、代码内容和分角色颜色。
`XWatchesViewImpl`为内联添加监视指定`AllIcons.Debugger.AddToWatch`，
不能继续使用旧版带圆圈通用加号。

图标依同版本`PlatformIconMappings.json`使用`expui/debugger`、`expui/nodes`
和`expui/run/evaluateExpression`的原始16pt明暗资源。变量展开改用共享
chevron SVG和Tree的图标槽、19pt层级缩进，保留加载与展开动作。
原始彩色变量/监视图标不再模板着色；禁用求值/刷新只应用一次现有IDEA灰度。
线程与作用域下拉保留共享菜单；作用域选中态使用共享checked槽，不额外绘制圆点。

变量与监视标题使用13pt Regular及Tree文字色，空提示使用共享StatusText颜色，
不局部加粗。变量名称/表达式保留13pt真实代码字型与现有值/类型专用颜色；
多行值、错误及监视内容仍可显示，不硬塞为单行24pt树行。
表达式输入复用`LitheSearchTextField`的占位、光标和IME观察规则，保留代码输入
字体、Enter求值、添加监视和已有历史菜单，不新增输入框边框。
求值行与线程行同为28pt，继承现有工具窗口布局，不将IDEA Diff的40pt工具栏
尺寸套到这里。断点管理等独立对话框本次未调整。

验证使用`DebugToolbarPresentationTests.inspectorUsesNativeNewUIAssetsInBothAppearances`
加载实际资源并检查16pt尺寸及可见像素，运行共享输入框、树行焦点和菜单覆盖回归。
组件与资源检查不等于完整暂停目标的实机验收。


按用户后续要求，线程选择标题和表达式输入前的图标移除，文字不保留空图标槽；
线程菜单项仍保留状态图标。求值历史共享右键菜单移到已有添加监视按钮，保留
输入框原生剪贴板菜单及输入行为，不为了历史入口新增按钮。


### Threads & Variables的StatusText和紧凑布局

用户确认采用左窄右宽、简化求值与合并空提示后，调用栈默认占三分之一，
仍使用共享分隔器并保留用户拖动后的宽度；该比例是Lithe布局选择，非IDEA源码常量。
线程选择、求值、变量和监视标题共享28pt行高度。求值只保留输入、Enter及添加监视，
移除重复的三角按钮；历史菜单仍位于添加监视按钮，不占用原生文本编辑菜单。
变量与监视移除计数，无监视时隐藏不可用的刷新按钮，已有监视和变量操作均保留。

同版本Community `StatusText.java`使用标签字体、`DEFAULT_ATTRIBUTES = GRAYED_ATTRIBUTES`，
`NamedColorUtil.getInactiveTextColor`解析`Component.infoForeground`，默认深浅
`#787878/#999999`；已核对Islands及父主题，复用现有`ToolWindowEmptyState`字体/颜色。
`StatusText.getTextComponentBound`默认水平居中，纵向为可用高度减内容高度后除以3。
新的共享`LitheToolWindowStatusText`复用这些度量，以固定字号、无背景、无图标的
方式绘制；窄区域裁剪，不另造小字或换行。该组件不截获输入。

调用栈空状态移出LazyVStack放到完整内容区域，显示“Frames are not available”；
原左上角提示即使换字体也无法得到上游位置，因此没有采用只换颜色的方案。
右侧没有变量、监视与异常时，只显示一条共享提示；暂停后提示选取栈帧，运行时提示
暂停程序。状态文字位于标题之后的可用区域，去掉监视的重复空提示。
`ToolWindowStatusTextTests`通过深浅主题实际文字像素检查字体行高边界、水平居中与
三分之一高度，不把声明了13pt等同于实际可见。完整目标进程暂停交互另行验收。


提交前审查修正Console上一处/下一处导航：相同URL可能在日志中出现多次，
导航位置必须同时记录原生文字范围，不能只按URL找到第一处。替换输出后重置
位置，原生动作回归验证三处相同源码链接的前进、回绕与后退。
性能采集的数据所有权与真实进程清理规则见
[本地JVM性能监控](../feature/2026-10-14-local-jvm-performance-monitoring.md)。


### 添加与编辑监视表达式的弹窗

内联 Add to Watch 只提交求值输入框中的非空表达式；空白时禁用，避免模型拒绝空值而按钮看似无响应。
Watches 标题的＋继续打开新增弹窗，已有监视的编辑菜单复用同一弹窗。
弹窗输入复用 `LitheSearchTextField` 和 `litheSearchField` 的普通字体、占位色、边框及焦点环，
取消/保存复用 `LitheSecondaryButtonStyle` / `LithePrimaryButtonStyle`；不保留原生 roundedBorder 或另画输入框。
打开后聚焦表达式，Enter 仅在非空时保存，Esc 取消；空白保护同时覆盖按钮和键盘提交。
复验新增与编辑初值、中文输入法、深浅主题、聚焦/失焦及原有去重和暂停求值流程。


Watch 编辑器的外层也必须经过 `litheDropdown` → `LitheContextMenuPresenter`，
锚定 Watches 标题的＋按钮，新增和编辑共用；不能只替换输入框后继续使用系统 `.sheet`。
共享 owner 负责8pt外框圆角、底色、1pt边框、阴影、屏幕边缘约束和无动画显示。
内容只保留12pt留白，不再绘制第二层背景或固定高度；保存/取消显式清空编辑上下文，
Esc及外部点击由共享呈现器关闭，重新编辑以上下文身份重置输入值。


Console 源码导航必须区分“尚未定位”和“已定位第一条”：首次前进从第一条开始，
首次后退从最后一条开始，之后才按当前链接范围逐个移动并回绕。
输出整体替换后，即使新旧源码链接的 URL 与范围完全相同，也要重新执行首次定位；
`ConsoleInlineInputTests` 的双向原生回归保护这一边界，不能将跳过第一条写成预期。


Console 原生视图的源码导航可用性通知在 `updateNSView` 返回后交付，按最后一次值去重，
新渲染覆盖旧的排队通知；`dismantleNSView` 使排队通知失效并清理观察器及回调。
不要在原生更新事务中同步修改 SwiftUI State，也不要让已卸载视图回写工具栏状态。
导航按钮回归覆盖无链接、有链接、清空输出、快速覆盖及卸载重建。


Debug Console 的 400,000 字符上限同时约束前台输出与后台会话快照。
截断必须落在完整 SGR（ANSI 颜色和字重指令）之外，并在保留文本前恢复截断处的有效样式；
不能直接裁掉控制序列的一半，也不能把全部历史 SGR 拼回头部而让缓存无限增长。
保留少量有界前缀空间，按现有 `ANSIOutputRenderer` 支持的粗体、前景及背景类别合并状态，
覆盖标准色、256 色和真彩；增加渲染器样式类别时同步扩展截断状态。
回归覆盖跨 chunk、恰好截在 SGR 内、后台会话切换、样式重置及 Unicode 长输出。

## 带参数通知与普通错误描述（2026-10-15）

通知的持久内容保留消息键和原始字符串参数，气泡与历史列表共用展示层，随应用语言
翻译并格式化。合并身份是消息键加参数：不同启动失败详情不能合并，重复的相同详情
才累加次数。不能在入库前把格式化后的翻译当作键。

Maven reloadError 直接展示异常描述，不经过通知展示层，所以生成异常时通过
AppLanguage.localizedString 按应用语言解析。它不适用通知保存原始键的规则。
WorkbenchNotificationTests 覆盖同一失败通知由中文切换英文、重复次数和详情隔离，
并检查 Maven 异常在两种应用语言下的描述。


### Tests 顶部与运行标签

Tests 标题栏复用同一 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade`
的 `ToolWindowHeader.kt`、`JBUI.CurrentTheme.ToolWindow` 与 Islands 主题规则：
41pt 高度、13pt Bold 标题、左 12pt / 右 8pt 留白，不显示标题图标或发现数量。
底线直接使用 `LitheToolWindowHeaderDivider`，运行控制移到下一行，避免挤占标题栏。

`TabContentLayout.java` 按选中内容与工具窗口活动状态绘制标签，
`ContentTabLabel.java` 的关闭动作移除并释放内容。Lithe Tests 当前服务只拥有一次运行，
因此仅在 `activePlan` 存在时显示真实运行名称，复用 `LitheToolWindowTabStyle`、
`LitheToolWindowTabCloseButton` 和独立的工具窗口活动跟踪器，完成后仍保留关闭按钮。
标签图标沿 `JUnitConfigurationType.getIcon` → `AllIcons.RunConfigurations.Junit` →
`PlatformIconMappings.json` 使用原始 16pt `expui/runConfigurations/junit.svg` 及深色变体。
关闭调用 `LanguageTestService.closeRun`，停止运行、失效旧回调并移除计划、输出、结果和重跑目标，
保留发现列表及编辑器测试标记。最小化仍只隐藏窗口，不处置运行。

不创建视图私有的历史标签或在点选发现条目时冒充新运行；多会话历史需要服务先拥有独立会话。
标题继续使用现有 Tests 工具窗口名称，本次不改变 Run/Tests 的窗口归属。
`ExecutionModuleTests.closingTestRunPreservesDiscoveryAndAllowsNewRun` 覆盖运行中与完成后关闭、
保留发现以及随后再次启动。实际打包预览已运行 Maven 演示并观察到 2 通过、1 故意失败、1 跳过，
核对了深色活动/非活动标签、完成后关闭标签与输出清理，以及深浅主题的标题栏和刷新/重跑/清空 SVG。
运行中关闭由确定性服务测试覆盖；多会话历史不在本次验收范围。

第二行刷新和清空分别沿 `AllIcons.Actions.Refresh` / `ClearConsoleAction` 的
`AllIcons.Actions.GC` → `PlatformIconMappings.json` 使用现有
`expui/general/refresh.svg` / `delete.svg`；重跑使用原始 `expui/run/rerun.svg`
（仓库已以 `debugger/rerun.svg` 引入），停止使用 `expui/run/stop.svg`。
四个按钮均使用其明暗 SVG、16pt 原始尺寸和 `litheToolbarIconButton` 的 22pt 命中范围，
不再使用旧 12pt 测试 gutter 图标，也不使用 SF Symbol 垃圾桶作为实际资源。

Tests 详情区去掉重复的图标、测试名、提供方和 Run/Debug 标题块，第二行右侧不再显示
Running/Passed/Failed 状态标签；测试结果统计与错误内容仍由详情/输出区展示。
运行入口统一放在第二行第一个图标按钮，初次选中作用域使用 Run；与服务最后一次运行的
提供方和精确作用域相同时使用 Rerun，切换到其他作用域恢复 Run。比较使用 `lastRun.scope`，
不能比较展示名称，否则同名测试或文件路径显示差异会误判。按钮始终通过现有
`AppModel.runTest` 启动当前选择；运行中禁用，Stop 常驻并只在运行时启用。
原有 Java 非工作区 Debug 入口移到同一行，继续使用原动作与 IDEA 明暗 SVG。

本次实际预览验证了无标题块/右侧状态的空闲和运行中布局；通过第二行按钮运行工作区，
再选择 `addsPositiveNumbers()`，按钮恢复 Run，点击后单测试通过且恢复 Rerun。
确定性服务测试同时核对未运行、同作用域、不同提供方/作用域和关闭后匹配状态。


### Tests 结果布局与右侧收缩条

Community 同一版本的 `platform/testRunner/src/com/intellij/execution/testframework/ui/TestResultsPanel.java`
将结果树放左侧，状态行放控制台上方，控制台动作放 `BorderLayout.EAST`（右侧）；
`SMTestRunnerResultsForm` 根据结果更新摘要和树。Lithe 因此将详情表单移入右侧 Details，
控制台顶部只保留单行真实结果摘要；报告尚未提供耗时字段，不推测或伪造每个测试的耗时。

测试报告可与发现的精确选择器匹配时，左侧展示本次报告的类/方法，状态图标直接使用
Community `expui/run/testPassed`、`testFailed`、`testIgnored` 明暗 SVG。
状态分组在结果变化时计算一次，单行查字典；参数化方法共享状态，任一失败/错误优先，
未知结果不冒充通过。没有精确报告或发现信息时保留原来的发现列表。
树行使用 `litheTreeRow`，区域焦点继续独立跟踪；折叠按深度跳过后代，不能隐藏其他类。

控制台直接使用 Debug 已有的 `OutputTextView`、`ConsoleFoldPresentation`、IDEA 字型/颜色，
保留源码跳转、复制和折叠。共享输出控件新增工具栏左右位置参数，默认仍在左侧，
Tests 选择右侧；不要复制一套按钮、导航定位或打印代码。清空动作在控制台工具栏保留；按用户指定，第二行也保留清空，刷新紧挨垃圾桶左侧。

右侧 Details 复用 Git Log/Debug 的 `LitheCollapsedActionStripe`、`ActionStripe` 度量和
`LitheSplitPaneView`，默认收起。展开后可调整宽度，拖动结束才持久化，隐藏不处置运行。
其中显示已有 Scope、Command、失败详情和源码定位；Performance 已接入本次测试 worker 的
独立 JVM 目标及 JFR，不能把 Debug 的活动会话或历史曲线借来当成测试性能数据。

`LanguageTestPresentationTests` 验证结果分组、方法匹配和树折叠边界；
`ConsoleInlineInputTests.wallpaperChangesUpdateEveryConsoleLayerWithoutReplacingInput`
覆盖工具栏左右布局、深浅主题、背景切换和输入控件身份。

实际打包预览已在深浅主题验证测试树/摘要和右侧控制台 SVG，测试类可收起/展开；
Details 已验证展开、宽度拖动和收起，拖动后沿用共享容器保存宽度。
摘要行使用第二行操作栏的同一 22pt 图标按钮与上下 5pt 留白形成 32pt 高度，
对应上游 `SameHeightPanel` 将状态行与工具栏对齐的布局意图，不套用 40pt 主工具栏高度。
运行示例和切换主题前后，整个预览包 1300 个文件的 SHA-256 均未变化。
31 项相关检查通过，其中本次修改的控制台左右布局/主题检查为 57ms；
其余结构/服务边界、资源不可变、笔记和功能矩阵检查通过。

Test 的 Performance 复用 `DebugConsoleWithPerformance`、`DebugPerformanceChart`、共享
分隔器和折叠条；CPU 和 Resident Memory 使用测试运行进程树的真实采样，显示口径
与采集生命周期见本地 JVM 性能 Note。Details 继续保留作用域、命令与失败定位。

Test 第二行 SVG 全部启用 `usesIDEADisabledAppearance`，复用 Community 灰度算法；
Stop 禁用时为灰色，运行中才保留原始红色，不通过单纯降低红色透明度模拟禁用。

Test 右侧由用户确认合并为一个可收缩区域，Performance/Details 顶部切换，保留作用域、
命令和失败定位。原生 JVM 图表与 JFR 工具归属见性能 Note。Performance 标题使用
Community `JBUI.Fonts.smallFont`→`UIUtil.FontSize.SMALL`（13pt默认下11pt常规），
Islands `*.foreground`→`text-default`（dark #D1D3D9/light black）；共享 ActionStripe
标题 token 同时用于折叠条、Debug Performance 及 Test 的两个标签，避免继承系统白色。
录制图标原样使用 Community `expui/profiler/rec{,_dark}.svg`，不以Run图标代替。

Test Performance 的 Show Results 改为复用 `LitheActionButtonStyle`：从 CommitAreaView
移至共享组件，Commit 操作继续消费同一个实现。依据同 revision 的 DarculaButtonUI、
DarculaButtonPainter、DarculaButtonBorder 与 ManyIslands 明暗主题：28pt 可见高度、
72pt 最小宽度、14pt 文字内边距、3pt 外部边框留白、4pt 圆角和13pt常规字。普通按钮
深色透明、浅色白底；禁用使用独立 text-disabled/control-border-disabled，不能整块降透明度。
上游普通文字按钮不另外叠加 hover/pressed 底色，保留默认箭头。录制图标仍走共享工具栏
按钮，原始 SVG 已应用 IDEA GrayFilter，禁用时不再叠加按钮透明度。

Show Results 的结果窗口同时复用 Git Patch 等表单的 `LitheCenteredPopup(dialogTitle:)`，
由共享 presenter 提供原生标题栏、父窗口居中、关闭和事件隔离；内容继续使用统一
OutputTextView。关闭动作放在对话框底部，采用现有对话框按钮与 Esc，移除独立 sheet
标题行和工作台表面，避免系统 sheet 圆角背景与产品对话框混用。

Test 结果摘要下方不再画普通分隔线：有失败/错误时红色，否则有通过项时绿色；
无结果、运行准备中或全部跳过不画。重跑沿用服务清空 results 的生命周期。
依据同 revision 的 TestStatusLine `ProgressBar.stripeWidth=3` 与
DarculaProgressBarUI 的确定进度绘制，状态条为3pt、两端半圆，颜色由共享
`LitheTheme.TestResult` 持有。Light 的 ProgressBar.failedColor/passedColor 解析为
#E4656E/#4E9D6C；Dark 主题中的 failedcolor/passedcolor 是小写键，UITheme
按大小写精确写入 UIDefaults，因此实际取 ExperimentalDark 父主题 Red6/Green6，
即 #BD5757/#57965C，不能直接用 Dark 的 accent-error-bg/accent-success-bg 替代。

状态条右端与控制台文本区对齐：扣除 OutputTextView 尾侧共享 ActionStripe.width 及其1pt分隔线，不延伸到控制台工具栏或 Performance 折叠条。

没有 Maven 结构化报告时，结果摘要按 LanguageTestService.state 保留通过、失败、取消及
超时；仅 idle 使用未运行提示，不把 Go/Python/Node/Rust/Gradle 的结束状态丢掉。
无报告的通过/失败仍使用同一状态条，取消不冒充成功。

Test 左侧结果树对照同 revision 的 TestTreeRenderer → TestsPresentationUtil：根与叶的名称
均使用 REGULAR_ATTRIBUTES，对应13pt常规字和共享 Tree.text；不因选中或失败加粗/着色
名称。展开箭头改用 Tree 主题指定的 expui/general/chevronRight/Down 原始明暗16pt SVG。
未运行项复用 PoolOfTestIcons.NOT_RAN → PlatformIconMappings 的 testNotRunYet，
执行错误用 testError，断言失败用 testFailed，保留 passed/ignored 原始图标，不用SF图标
替代测试状态或通过调色修改源SVG。列表左右留白复用 Tree.horizontalInset（12pt），
行高24pt、层级19pt、文字间距2pt，选中/失焦/hover仍由共享树行负责。

Test 结果摘要对照 TestStatusLine、TestRunnerBundle 与 SimpleColoredComponent：
使用连续的“2 tests failed, 3 passed, 1 ignored”形式及13pt Regular，中文单独翻译，
单复数按数量选择。失败文字取 Label.errorForeground（深#F57E84/浅#C54E58），
忽略文字取 Label.warningForeground（深#D59637/浅#A56906），总数取
GRAYED_ATTRIBUTES → Component.infoForeground（#73767C）；不能用通用日志等级色替代。
状态图标保留16pt，额外区分全部忽略、通过但含忽略、错误和未运行；总数与结果分段显示，
没有真实耗时数据时不伪造时间。共享 TestResult 持有字体、颜色与间距：左4pt来自wrapper2
加icon inset2；图文3pt来自iconTextGap2加文字border1；描述12pt来自前项尾3、容器gap6
及后项首3。3pt结果状态条的范围保持不变。

结果树有子项的名称区域支持双击切换折叠；单击继续选择，箭头点击继续只切换折叠。
复用 Maven 树的 simultaneous double-tap 方式，叶子双击不改折叠集合、不触发运行。

Test 发现列表与运行结果分开处理图标语义：工作区入口使用原始 testGroup，文件复用
LitheIcons.kind 文件分类与 LitheIcon；有子项的测试分组用 class，叶项用 method。
它们均保留16pt原始明暗资源与共享树行；有报告状态时仍优先用运行结果图标，
不把尚未运行的整个发现列表画成 testNotRunYet 灰点。原始资源只在构建时打包，
运行时只读，不产生缓存或改变 bundle，既有 IDEAIcons 工作树资源归属不变。

Test摘要把整体运行结论与报告计数分别保留：Maven解析器即使无报告也可返回零计数，
因此.failed/.timedOut必须优先决定错误图标和红色状态条；报告没有失败计数时，
额外保留Failed/Timed Out文字。部分测试通过不代表整体构建成功，取消不画绿色状态条。

### 主编辑器软换行按钮

软换行开关复用 `LitheIconButtonStyle` 的工具栏尺寸（22pt 点击区、16pt 原始
`expui/general/softWrap.svg` 图标，内部每侧3pt），共享悬停、按下和选中底色。
按钮位于缩略图左侧，保留8pt间隙；关闭缩略图后位于滚动条左侧。位置来自
Monaco `getLayoutInfo()` 的实际缩略图边界，不能假定缩略图固定宽度。
`editorLayout` 桥接消息仅在尾侧占用宽度变化时发布，几何状态由对应
`MonacoWorkbenchSession` 持有，不经 AppModel 或工作台重新发布。主编辑器和
独立文件窗口使用同一开关，预览与差异窗口不增加按钮。查找栏出现时继续隐藏
开关，设置持久化、禁用条件和辅助功能描述保持原语义。
真实 WebKit 回归覆盖两种宽度、缩略图开关与桥接定位值。

### Islands Dark 内容区精确底色

依据 Community `idea/262.9437.185` 的
`platform/platform-resources/src/themes/islands/ManyIslandsDark.theme.json`，
`editor-bg` 与 `tool-window-bg` 均经 `layer-0-bg` 解析到 `gray-10 = #191A1C`。
Lithe 深色主题原先使用 `(0.094, 0.098, 0.106)` 小数近似值，转成8位颜色为
`#18191B`，不能与精确主题值等同。共享调色板改用精确 `#191A1C`，覆盖编辑器、
侧栏、面板标题和原先同底色的活动标签；浅色主题和其他颜色主题保持原值。
Monaco 继续通过原有主题桥接读取相同 editor token，不引入单独的网页底色。
截图像素经过显示器配置与截图色彩配置转换，不直接当作源代码中的 sRGB 常量。
回归核对原生内容底色与 Monaco 背景，以及原有壁纸透明和主题切换语义。

### 行号与 Java 启动类标签

Community `idea/262.9437.185` 的 `themes/islands/IslandSchemeDark.xml` 定义
`LINE_NUMBERS_COLOR = #4B5059`、`LINE_NUMBER_ON_CARET_ROW_COLOR = #A1A3AB`。
macOS Lithe 深色主题通过 CodeEditorPalette 把专用颜色传给 Monaco，其他主题不改。
`EditorGutterComponentImpl.getFontForLineNumbers()` 使用编辑器 Plain 字体加
`PlatformExtensions.xml` 中默认 `editor.gutter.linenumber.font.size.delta = -1`。
macOS 网页适配层仅将行号设为继承字体的小1pt常规字，最小1pt，保留原行高、行号
命中区域、代码字号与引擎布局；不改变 Windows 的适配层。

Java 编辑器标签复用已经导入的 `expui/nodes/runnableMark.svg` 原始16pt角标，
与 Run Configuration 和 Problems 文件标题的装饰方式一致，角标本身没有额外点击动作。
`EditorDocument.hasRunnableJavaMain` 由已有 Monaco Java Run marker 响应更新，必须先通过
当前文档、路径、revision 和 requestID 校验；只在 main 标记存在时显示，不把普通类或
测试类误标成启动类，也不另发语言服务请求或新增源码启发式解析。

### macOS 行号优先的编辑器边栏

macOS 宿主启用 `WorkbenchHost.lineNumbersFirst`，关闭 Monaco 原始左侧 glyph margin，
使用公开的 linesDecorationsClassName 将运行和导航标记放在行号右侧的两个16pt区域。
主方法运行图标复用 `expui/run/run.svg` 及其 dark 变体的原始16pt描边图形，
不再把实心12pt TestState.Run 当作主方法的运行图标；测试结果状态保留原资源。
断点使用公开 lineNumberClassName 在行号区显示，点击数字区域仍走原调试请求，
暂停箭头使用右侧装饰区；运行/导航菜单、revision 校验及键盘命令保持原入口。
保留 glyph 装饰元数据以维持未启用此宿主选项的平台表现，不修改 Monaco 内部布局、
鼠标控制器或第三方源码，也不通过 CSS 互换两块引擎命中区域。
WebKit 回归核对绘制矩形、getTargetAtClientPoint 类型及行号、运行 SVG 尺寸和
深色资源、断点行号区域，并继续覆盖分屏、导航、只读和调试标记生命周期。

### 行号后的间距与折叠箭头

Community `idea/262.9437.185` 的 `JBUI.CurrentTheme.Editor.Gutter` 默认
`gapAfterLineNumbersWidth` 和 `gapAfterIconsWidth` 均为4pt；Islands Dark 及
ExperimentalDark 主题未覆盖。原先32pt的动作区扩展为：4pt行号后留白、两个16pt
动作槽、4pt动作后留白和16pt折叠命中槽。最后16pt由 Monaco 开启折叠时自动添加，宿主不重复预留。尺寸由同一个 nativeGutter 定义推导，
运行、导航/暂停箭头、折叠控件互不重叠，仍全部位于 Monaco 实际装饰区域内。

折叠控件替换字体图标为现有 `expui/gutter/fold{,_dark}.svg` 和
`unfold{,_dark}.svg`：原始9×9 viewBox、1pt描边及圆头，深色 #6F737A、浅色
#A8ADBD。16pt容器内居中绘制，不缩放笔画，不另画箭头，保留引擎展开/收起与悬停语义。
样式只作用于宿主 extraEditorClassName 标记的行号优先编辑器，不影响差异审阅布局。
运行/导航图标的 mouseup 在 document 捕获阶段按编辑器 DOM 所有权判断后停止冒泡，避免同一装饰区的引擎
折叠处理器在打开动作菜单时同时折叠声明；监听器随编辑器销毁清理。
真实 WebKit 核对4pt间距、箭头绘制和命中矩形、展开/收起 SVG、真实点击折叠、
断点点击，以及点击运行图标不会折叠声明。

### 测试类 Run All 与空导航槽

测试类未运行状态使用 Community `idea/262.9437.185` 的原始
`platform/icons/src/expui/actions/runAll{,_dark}.svg`（16pt描边双三角），与主方法
Run 的16pt、描边色和明暗变体一致，不再使用旧12pt实心 TestState.Run_run。
新资源版权和来源记入 IDEAIcons/NOTICE.txt；测试类仍使用 run-all 语义，测试
方法仍使用 run，成功/失败状态保留原图标，不改变测试动作。

单动作槽的折叠位置为4pt行号后留白 + 16pt运行槽 + 4pt间距；仅当当前模型
已有 Java 导航标记时追加16pt导航槽。通过已有导航响应和模型切换更新当前编辑器
配置，无额外语言服务请求；保留旧导航显示期间的槽位，避免每次键入导致边栏闪动。
从引擎现有配置判断是否需要更新，不在每次光标变化时重复布局。主题和字体配置更新后
重新核对导航槽，避免全局显示配置冲掉当前文件的槽位；各分屏仍各自判断。
回归覆盖 Run All 原始16pt明暗资源、无导航时运行与折叠的4pt间隔、有导航时保留
导航槽、主题配置不清除已有槽位，以及文件重命名清空导航后的回收。

### 行号栏按实际字体与位数计算

IDEA `idea/262.9437.185` 的 `EditorGutterComponentImpl` 用最大行号的普通编辑字体
（字号减1）测量宽度，并用 New UI 断点图标宽度作为下限。macOS 的行号栏不再固定
预留5位：普通模式设置最小字符数为1，宽度按行号字体的数字宽度 × 文档最大行号位数
计算，最低16pt以容纳当前断点图标。原生编辑字体为等宽字体；数字仍右对齐，文档
增长、缩短、字体变更及分屏均由对应编辑器重新计算。Git blame 自定义行号模式保留
原26字符注释空间，关闭后回到普通测量模式，Windows 保留既有5字符配置。

Monaco 0.55.1 的公开 lineNumbersMinChars 只接受整数，layoutInfo 使用代码字体
的 maxDigitWidth，无法精确表达更小字号的行号和16pt最低宽。因此仅在 macOS 网页
适配层包装固定版本 EditorOptions.layoutInfo.compute，且只作用于带行号优先标记的
普通行号编辑器。复用引擎 FontMeasurements 缓存和 BareFontInfo 测量字号减1的常规字，
向原计算函数提供行号专用 maxDigitWidth；不修改实际代码 fontInfo、正文字符测量、
caret 或第三方文件，不复制布局公式，不在 Swift 工作台发布几何。其余内容区宽度、
换行、缩略图和鼠标命中继续由同一次上游布局计算得出；差异预览及自定义注释栏旁路。

这是固定版本的窄兼容点：升级 Monaco 时必须复核 maxDigitWidth 在 layoutInfo
计算中的用途及 compute/font measurement 参数；上游提供独立行号字体/像素宽度选项后
改用正式选项并删除包装。真实 WebKit 用独立 Canvas 字体测量核对9/99/100/1000行、
缩回个位行、不同字号与实际 JetBrains Mono 字体，并检查分屏独立宽度；同时保留
行号区断点点击、运行/折叠布局和 blame 开关回归。

### Java 测试文件标签角标

Community `idea/262.9437.185` 的 `JavaFileIconPatcher.kt` 取文件对应类的图标，
`ElementPresentationUtil.getClassKindImpl/getFlags` 优先识别测试类，再识别 runnable
类，并注册 `PlatformIcons.JunitTestMark` 图层。macOS 编辑器标签保留语义类图标，
右上角叠加原始 `expui/nodes/junitTestMark{,_dark}.svg`：16pt viewBox 内的红绿
测试标记，使用原始颜色、几何及明暗变体，版权来源记入 IDEAIcons/NOTICE.txt。

`EditorDocument.hasJavaTests` 与 main 标记共用已有 JDT Run marker 响应，且仅在
文档、URL、revision 和 requestID 校验通过后更新；测试类或测试方法标记均可证明
文件含测试，不通过 *Test.java 文件名或目录猜测，不增加语言服务请求。测试角标
优先于 main 角标，结果通过/失败不改变测试文件身份。无测试时撤销测试角标，
非 Java 文件不显示遗留标记；辅助函数回归覆盖测试、main、同时存在、普通类和改扩展名。
本次仅修改编辑器标签，不额外修改项目树或其他面板。


测试文件标签内部配色同样对照 Community `idea/262.9437.185`：`TestsScope` 把测试
源码范围映射到 `FileColor.Green`，不是运行结果的成功色。`ManyIslandsDark/Light.theme.json`
分别为 #1C261C / #EDFAEF；`IslandsTabPainter.paintTab` 在选中标签里内缩3pt绘制，
非活动使用40%透明度。共享 `LitheToolWindowTabStyle` 仅在调用者传入文件范围色时
增加该层，原工具窗口标签不传色，保留现有焦点、边框与hover行为。编辑器使用导入的
Maven项目及子模块源码根角色（含自定义目录和测试辅助类），没有根信息时复用已有
JDT Run marker 的测试元数据，不根据文件名包含 Test 推断。深浅主题与活动/非活动
像素验证见 `EditorTabColorTests`，源码根边界验证见 `EditorTabLayoutTests`。

### 2026-10-17 编辑器结构线颜色与匹配边界

- 依据 Community `idea/262.9437.185` 的 `platform/platform-resources/src/themes/islands/IslandSchemeDark.xml`，Lithe 深色编辑器普通结构线使用 `INDENT_GUIDE=#323438`，配对结构线使用 `MATCHED_BRACES_INDENT_GUIDE_COLOR=#4E5157`；其他主题沿用原配色。
- 核对 `BraceHighlightingHandler.kt`、`IndentGuideRenderer.java` 与 `IndentsModelImpl.java` 后，按本次产品要求限制为光标紧邻多行配对花括号时突出对应结构线；普通块内语句及文本选择不触发。关闭 Monaco 默认“所在缩进持续高亮”，避免两套规则叠加。
- macOS frontend 使用固定 Monaco 0.55.1 `TextModel.bracketPairs.matchBracket`，匹配预算 5ms，并校验既有词法 token 排除字符串和注释；不另建括号解析器、不强制同步词法解析。绑定各编辑器的选择、模型、内容及 token 变化，关闭时释放监听；分屏互不继承光标状态。
- 普通线与括号线统一消费 palette 的 `guide` / `activeGuide`，嵌套深度不额外引入彩虹线色。原生宿主关闭水平括号辅助线；Windows 宿主行为不变。
- `MonacoWorkbenchThemeTests` 验证原生颜色，`workbench.integration.ts` 在真实 WKWebView 验证首尾括号、内部语句、嵌套块、注释与字符串、选择、配置更新和独立分屏。完整应用视觉验收仍待进行。

### 2026-10-17 软换行覆盖按钮光标

软换行按钮已改为 WebKit 文档内的标准 HTML 按钮，与 Monaco 正文使用同一套光标系统；旧的 `EditorSoftWrapToggle` 原生覆盖层及手动光标回调已删除，不再使用 `onContinuousHover` 强制设置箭头。按钮尺寸和绘制参数仍来自共享图标按钮样式，悬停使用小手，正文与空白编辑区保留 I 形光标。可见性、禁用和点击继续通过现有 configure 与同源消息处理。原因和真实 WebKit 验证见[Monaco 可行性与原生桥接 Note](../architecture/2026-09-15-macos-monaco-feasibility-probe.md)的软换行按钮决策；独立组件测试不代替完整应用悬停验收。
