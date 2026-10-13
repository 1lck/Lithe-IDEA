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

只有顶部的分支弹窗在右边缘提供拖动调整宽度的入口。共享呈现器只为传入
宽度绑定的自定义弹窗安装已有 `SplitHandleInteractionView` 原生分隔条命中组件，
普通菜单不安装；其他调用点不传宽度绑定。右侧 10pt 命中区使用水平调整光标。
命中区与 `NSHostingView` 放在同一个原生容器中，由这个容器统一拥有宽度。
不能只设置 AppKit `NSPanel` 的 resizable 标志，因为无边框窗口不会因此提供
可用的边缘拖动入口；还必须避免宿主的理想宽度把窗口改回默认值。

弹窗是独立窗口，不能嵌入工作台内部的 `LitheSplitPaneView` 分隔布局。
复用原生命中组件的屏幕坐标和 `LitheDragUpdateScheduler` 事件合并，
拖动只调整原生窗口框架，不向工作台逐帧发布宽度。
默认及最小宽度沿用 375pt，最大宽度受窗口右侧的屏幕可用区域限制。初始高度由内容决定；
右侧两个角增加宽高联动拖动，最小高度取 Community `GitBranchesPopupBase` 的 312pt，
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

右侧两个角复用 `ProjectReplaceCornerHandleView` 的稳定屏幕坐标和清理逻辑。
依据同一 Community revision 的 `platform/platform-impl/src/com/intellij/ui/WindowMouseListenerSupport.kt`
与 `WindowResizeListener.java`，右上角使用 `NE_RESIZE_CURSOR`（东北—西南），
右下角使用 `SE_RESIZE_CURSOR`（西北—东南）；macOS 15 起只在分支弹窗覆盖为
原生 `NSCursor.frameResize`，较旧系统复用现有斜向光标，其他控件的光标不变。
分支角落跟踪使用 `activeAlways`，不依赖非激活弹窗先获得键盘焦点；
弹窗启用鼠标移动事件，在事件分发后按原生命中区设置调整光标，防止子视图
覆盖它。回归通过真实窗口发送鼠标移动事件，要求第一次点击之前光标就正确。
10pt 角落命中区盖在右边缘上，仅分支弹窗显式启用；两轴用同一次合并更新改变
原生窗口，左侧固定，右上角拖动固定底边，右下角拖动固定顶边。
松开后同步被拖动的原生锚点：向下打开时更新右上角移动后的顶边，
向上打开时更新右下角移动后的底边，内容刷新不能把它拉回拖动前的位置。
连续拖动以 `display: false` 修改原生窗口，把重绘交给 AppKit 下次绘制周期；
不能每个鼠标事件都同步刷新窗口。初次打开、普通菜单和持久化流程不受影响。
松开才更新宽高绑定并通过 `WorkbenchLayoutStore` 保存到当前项目的布局。
新增可选字段兼容旧布局，不改变侧栏和 Maven 面板尺寸的保存方式。
其他项目使用自己的宽高；屏幕变窄时只限制显示尺寸，不在打开弹窗时覆盖保存值。
`ContextMenuCoverageTests` 经真实窗口发送按下、拖动、松开事件，检查原生命中、
两个角的原生光标、相反边固定、尺寸限制、松开回调及刷新保宽，
用连续 20 次原生拖动事件确认只合并交付一次且拖动中不保存，
并确认普通弹窗没有拖动命中区。该计时不代表复杂工作区的帧流畅度验收。
该检查必须启用原生约束引擎并强制布局；先前同步宿主未启用它，曾误报通过。
补上约束后已复现 375pt 回退，修复后检查实际窗口尺寸保持用户值；
`WorkbenchMavenLayoutTests` 检查旧数据兼容和项目隔离。2026-10-07 完整应用预览中，
实际拖动后的窗口宽度与请求值一致（仅有原生像素取整），用户确认拖动已经生效；
诊断日志随后移除。新增右下角检查经真实窗口发送双轴鼠标事件，验证命中、
松开提交、宽高上下限、宿主尺寸和关闭恢复；项目持久化和隔离由布局测试覆盖。
新增角落与上游列尚需完整应用的实机视觉验收，完整 Git 工作流仍按功能矩阵待验收。

### 全局通知与右侧底部动作

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
共享蓝色焦点边框。原生面板通过 `searchOnTyping` 保持初始焦点在菜单；
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

## 验证

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
