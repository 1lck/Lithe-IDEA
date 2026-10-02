# Agent 笔记：macOS 全局默认字体随安装包分发

状态：已实现

## 先说结论

截图核对后，用户要求界面字体与 IDEA 对齐。macOS 普通界面使用已有的 Inter，
编辑器、终端及显式等宽内容继续使用 JetBrains Mono 2.304。普通界面统一从
`LitheTheme.uiFont` 和 `uiNSFont` 获取，代码与终端使用 `editorFont`；保留控件字重，
Project 树字号对齐 IDEA 的 13pt。欢迎页应用名、导航、普通项目名和常规操作按钮按 IDEA 使用 Regular，避免局部 Medium/SemiBold 覆盖默认字重。
字体文件随安装包分发，用户无需自行安装；运行时只读加载。

## 问题

此前把所有页面统一为 JetBrains Mono 后，Project 树与 Git 列表相较 IDEA
显得更宽、更实。IDEA 普通界面使用 Inter，代码编辑器才使用 JetBrains Mono。
此前仅有 Inter 3.019 Regular/SemiBold，Medium、Bold 请求会匹配到 SemiBold；用户提供 Inter 4.1 完整发行包后，用其静态字型替换旧版，无需新增运行时下载或依赖。只修改根视图的默认字体会被
这些局部设置覆盖。内嵌编辑器还有独立的网页进程，不能依赖原生注册。

## 决策

复用共享主题入口，替换显式字体调用，不改变控件字号、字重、动作和文本颜色。
语义文字样式先读取原生字号，再使用打包字体。中文等字体不包含的字形由系统
回退渲染。IDEA SVG 的几何形状和大小保持其资源定义。

`macos/Resources/Fonts` 保存用户提供的 Inter 4.1 包中的 18 个原始静态 OTF（9 个字重及斜体，文件内部版本为 4.001）、许可，以及
JetBrains Mono 2.304 的 16 个原始静态 TTF、OFL 和作者信息。Mono 文件与用户再次提供的归档逐文件核对，16 个文件均字节一致。
普通 UI 通过明确的字型名称匹配 Regular、Medium、SemiBold、Bold 等真实字重；SwiftUI 不再对已经指定字型的字体重复调用 `.weight`。
代码和终端继续读取 Mono 字型。构建脚本在签名前复制到 app 的 `Fonts`
资源目录；CoreText（macOS 的字体管理服务）按 process 范围注册，即只对当前
进程生效，不安装到用户系统。不能因机器已经装有同名字体而跳过打包资源。

Monaco 网页通过现有只读资源 adapter 加载同一字体目录。资源 adapter 要拒绝
目录逃逸和非 TTF 请求；网页加载字体后重新测量文字宽度，避免缓存回退字体的
度量。字体文件不在运行时下载、解压或修改，不改变签名或 Sparkle 增量更新
所需的发行基线。工作树通过 Git 获取源文件，资源复用脚本拒绝从另一份产物
或已签名安装包复制字体。

### 原生 Diff 的编辑器字体与中央行号

普通 Monaco 编辑器默认已经是 JetBrains Mono Regular 13pt。原生 Diff 曾固定
12.5pt、24pt 行高，并从界面状态色取语法颜色，造成截图中字号与颜色观感不同。
Diff 现在使用同一真实 Regular 字型、13pt/22pt，语法色复用现有编辑器颜色配置，
正文色复用 `CodeEditorPalette`。IDEA 依据为 `FontPreferences` 的 13pt/1.2 默认值，
以及 Islands/Darcula 编辑器配色，固定上游版本
`c7f91397daa3a961b4e78bc634fe467a0a7d9ade`。

两侧行号按各自源文件的行数放在中央，随各自代码流纵向滚动，横向滚动只移动代码。
继续复用 `DiffSplitLayout`，不改比较、搜索、折叠或导航逻辑。两侧代码改用
AppKit（macOS 原生界面库）的 `NSTextView`（原生文本控件），让文本可连续选中。
文字排版使用固定容器宽度，拖动仅改变裁剪范围；语法文字只在内容或配色变化时准备。
透明的懒加载行保留导航定位、折叠和差异块操作，行号和连接带只绘制可见区域。连接带使用实际拖动后的面板宽度定位，而不是假定左右均分。
配色由 `LitheTheme.Diff` 持有：新增绿、删除灰、修改蓝；中央背景与代码背景一致，
边界为 1pt，分隔条仍使用现有拖动组件但不额外变亮。

整行修改色与词内修改色不能都取滚动条标记色。IDEA 的 `TextDiffTypeFactory`
在有词内差异时，将差异色与 60% 编辑器背景混合用于整行，词内使用原差异色。
因此蓝色差异背景不是文本选中；真实选中使用编辑器的选择色。原生光标所在行的
行号取 `LINE_NUMBER_ON_CARET_ROW_COLOR`，深色 `A1A3AB`，浅色 `767A8A`；
其他选中行不会一起变亮。光标、选区和行号状态只属于当前文本控件。
差异导航只定位已有差异，不能在正文左边额外绘制蓝色“当前差异”竖线。
Diff 的复制菜单复用 `LitheContextMenuPresenter` 和 IDEA 16pt 复制 SVG，
不启用原生文本控件默认的系统菜单；复制时排除补丁头和折叠提示行。

已有 `MonacoDiffEditor` 使用 Monaco（打包的网页编辑器）的标准双栏模型，
其行号位于每个编辑器左侧，并会插入对齐空白，不能直接表达本页面已经采用的
中央双行号和独立紧凑代码流。此次复用原生文本选择与排版，不增加自制选择引擎，
也不改变 Monaco、Git 或后端的比较结果。初次准备文字仍与可见文件大小成正比；
拖动不重新生成文字。若未来统一到 Monaco，应先验证中央行号、单侧增删、折叠、
源行号映射和现有差异块动作，而不是只替换截图中的颜色。

### 历史提交 Diff 工具栏、单栏与滚动标记

历史提交页的文件标签、提交说明、Parent/Commit 标签及补丁区块头曾占用多行。
现在保留工具栏和版本信息两行：版本行显示父提交/当前提交的短哈希，左侧附文件
路径并从中间省略，标题跟随各自面板宽度和收起状态。单栏模式把版本信息上下排列，将已有修改前/修改后的文本依次
显示；双栏维持两个紧凑代码流。`@@` 是补丁元数据，只在历史提交页隐藏；工作区
Diff 的区块动作、搜索、折叠与只读/暂存语义保留。高亮词语和关闭操作进入已有
共享 `LitheMenu` 设置入口。用户明确要求补上工具栏中漏掉的已有能力后，
增加打开工作区文件到编辑器、上一/下一提交文件及文件总数、折叠未修改区域入口；
分别复用 AppModel 的打开/提交 Diff 动作和 DiffCollapse，文件列表必须属于当前提交，
不跨提交使用已缓存列表。单文件与首尾文件禁用对应箭头；删除文件禁用打开入口。
折叠开关对双栏/单栏均生效，区域仍可单独展开，切换文件清除区域展开状态。

依据同一 Community 版本的 `DiffHeaderToolbarPanel`、`DiffUtil.getContentTitleBorderInsets`、
`DiffToolChooser`、`SegmentedButtonComponent` 与 `FilePathDiffTitleCustomizer`。
上一处/下一处、只读锁、双栏/单栏使用原始明暗 SVG；普通工具按钮复用
`litheToolbarIconButton`、共享 hover/提示和界面字体。Islands 主题不是 DiffUtil 的
默认平面外观：`DiffToolbarIslandPanelUI` 在编辑器背景上画独立圆角工具栏，40pt
内容高度、上 2pt / 左右 6pt 外侧留白、6pt 圆角；背景/边框来自
`Editor.SearchField.background/borderColor`。移除原先贯穿整页的工具栏底边，
不能拿普通 toolHeader 背景代替这层表面。

版本标题遵循 `ManyIslands{Dark,Light}.theme.json` 对 `Diff.ContentTitle.insets`
的四边 6pt 覆盖值，不使用 `DiffUtil` 的 2/4/0/4 默认值；16pt 标题内容加内边距和
1pt 底边，共 29pt。单栏标题在同一边框内用 6pt 间距堆叠。底边来自编辑器
`TEARLINE_COLOR`：深色继承 Darcula 的 #555555，浅色继承 Light 的 #D4D4D4，
与中央竖线是不同的 token。路径继承普通 13pt Regular 标签字体及
`UIUtil.getContextHelpForeground` → `Label.infoForeground`（#73767C），和提交文字
之间保留 8pt；不能用较小字体或通用 secondaryText 代替。

双栏/单栏选择复用现有行 hover。按 `SegmentedButtonComponent/Toolbar`，父容器
只画一个外框，然后覆盖被选中的子项边框；未选项不再单独画框。每项 48×26pt，
来源是 16pt 图标 + ActionButtonWithText 两边 4pt margin + DSL 两边 12pt gap；
外围保留 Darcula 的 2pt focus width 和 1pt line width，外框圆角半径为 Button.arc/2
（4pt）。描边画在边界内，颜色使用 Button/SegmentedButton 主题 token，不通过
文字颜色透明度猜测。不能套用设置页的蓝色文字分段选择样式，也不改变选项动作。

两侧滚动条通过 `LitheScrollBarStyle` 使用编辑器用途的共享绘制和 `LitheTheme.Diff`
标记色；具体全局入口与普通滚动区的区别见
[macOS 共享滚动条](2026-10-02-macos-shared-scrollbar.md)。相对位置依据各自完整代码流高度，至少 2pt，点击把变更置于视口约三分之一
处；单侧增删的空范围仍有对应最小高度标记。AppKit 对 layer-backed NSScroller 有自身轨道
绘制，故原生跟踪与既有滑块绘制放在有明确裁剪的视图内，避免系统浅色轨道和越界
绘制盖住代码。原生双栏消费者不再另外显示旧概览条；工作区新增/删除的旧单栏仍用
原概览入口。未改 Windows、Monaco 或后端比较结果。

### 差异块按左右源范围配对

Community 同一 revision 的 `SimpleDiffChange.getDiffType` →
`DiffUtil.getLineDiffType` 依据整段左右源范围判断修改、插入或删除。
Lithe 的 Core 返回逐行配对；前端将相邻差异行组成一段，直到上下文行或折叠行结束。
例如修改旧第 78 行并追加新第 79 行，两边属于一个蓝色替换块，不能把额外的行
当成独立绿色块再生成另一条插入连接带。纯单侧变化仍为绿色/灰色。

正文、中央行号、连接带、滚动映射和标记使用同一段范围。保留 Core 行内容与原
行号，不创建空占位行；单栏仍按旧/新源顺序展示。词内高亮按该范围自己的增删改
类型着色，不因为整块为蓝色就将只新增的字符也画成蓝色。连接带复用
`DiffDrawUtil.drawCurveTrapezium` 的 0.3/0.7 控制点和 1pt 最小厚度；空范围对应
的横线使用差异背景色，不能取较亮的滚动标记色。

词内高亮同样先取得整段两侧文本，再将范围投影回每个原始行；不能继续拿
Core 的逐行配对来决定词内增删颜色，否则多行调用重排会被拆成绿/灰/蓝色碎片。
两侧行数相同时，在保持整块类型的前提下按对应行细化公共前缀/后缀范围，避免
两行独立参数修改把中间未变的调用和缩进也涂深；行数不同时继续投影完整片段，
保留重排场景。每个对应行（或行数不同的片段）最多一个内部范围；它修正了比较范围，
并未移植 IDEA `ByWordRt` 的完整单词匹配与片段优化算法。若需要区分同一段内
同一行内多个离散单词修改，应由现有比较提供方输出内部片段，不能在滚动绘制中再比较。

正文与行号区的相邻矩形背景关闭抗锯齿，仅恢复后绘制文字；连接曲线保留抗锯齿。
不能靠每行加高 1pt 遮缝，否则会覆盖上下文边界。原生像素检查覆盖深浅主题及
0、0.25、0.5、0.75pt 偏移；旧实现的小数偏移会在相邻行间露出底色。
中央连接带端点也必须使用行号矩形的设备像素覆盖范围：`NSRect.fill` 向外对齐像素，
曲线直接使用小数坐标会留下半透明边缘，形成中央竖缝或上下端的细边。
通过当前 CGContext 的设备坐标转换对齐两侧端点，保留中间曲线抗锯齿，不增加拖动边框；
深浅主题、1×/2× 和四种小数偏移的像素检查要求平直差异块从左行号到右行号连续一致。

### 连接带坐标与行号区域

版本标题必须占真实布局高度。原先使用 `safeAreaInset`，SwiftUI 对原生滚动区
施加 29pt 内容 inset，却没有对连接带做同样的坐标转换；滚动偏移检查通过，
连接带仍比代码行低 29pt。现在标题与正文使用普通垂直布局，代码、行号和连接带
共用正文坐标，原生检查直接将代码行边缘转换到连接带视图比较，覆盖初始和滚动状态。
不能用额外减去 29 的常量修补：标题变化或没有标题的调用者会再错位。
连接带同时受原生绘制 bounds 和正文容器裁剪，离屏部分不能覆盖标题或工具栏。
`DiffDividerDrawUtil.DividerPolygon` 先把非空范围的排他末端减 1，再交给
`drawCurveTrapezium` 加回 1；Lithe 直接使用排他末端，不能额外加 1，否则中央
底边会比两侧多一条像素。空边仍按上游绘制最小厚度，中央宽度为零时不绘制连接带。

Community 的 `DiffSplitter` 从 registry 读取 24pt 中央宽度，旧 34pt 并无对应来源。
`EditorGutterLayout` New UI 和 `EditorGutterComponentImpl` 根据真实源行号测量 number area，
至少 16pt；两个 gutter 取较大的源行号宽度。本页保留现有数字/折叠用途的 32pt chrome
（空注释 4、数字前 4、数字后 4、9pt 折叠 anchor 加 2、末侧 painter 8 加 1pt 线），
不预留没有的动作 icon area。宽度在规划变化时算一次，拖动不扫描所有行。
左 gutter 镜像后数字靠连接带，右 gutter 数字在距边缘 8pt 的区域右对齐，
不能让两个 gutter 都以总宽度减 8 对齐，后者会把右数字移入折叠空白区。
行号区分隔线在靠代码侧向内 3pt；差异行背景覆盖分隔线，最靠代码的 3pt
使用正文差异底色，其余行号区使用 gutter 差异色。不能在 SwiftUI 外层再叠加一条
永远可见的边框，否则差异块与连接带之间会留下 IDEA 没有的竖线。

### 项目标识的字母

项目颜色标识的字母属于已有 `ProjectAvatarBadge`，不是普通界面标题。
Community `AvatarUtils.getNewUiFont` 使用 JetBrains Mono DemiBold，字号按
`13 × size / 20` 取整数。复用已打包的 SemiBold 字型及现有字体入口，20pt 标识用
13pt；顶部、项目菜单与欢迎页同一处修正。保留项目颜色、标识大小及名称规则，
不复制 JetBrains 产品标志，也不改变其他界面文字的字重。

## 考虑过的备选方案

- 只给根视图加字体：改动少，但不能覆盖显式 SwiftUI 字体及原生文字控件。
- 依赖用户安装字体：包更小，但版本随机器变化，也无法保证网页进程可用。
- 只保留 Regular/Bold：文件少，但 Medium、SemiBold 和轻字重会依赖合成，
  难以保留界面原有文字层次。

## 后果

普通界面使用比例字体，代码和终端使用等宽字体，字体来源均可核对。
Git Log 日期列按实际 UI 字体测量，避免换字体后宽度仍沿用编辑器字体。
操作系统管理的窗口装饰与系统对话框字体仍由 macOS 决定。Windows 本次不变。

## 验证

`BundledUIFontTests` 以临时 bundle 验证 34 个字型的注册来源、Inter/Mono 版本、重复注册、
原生 UI/代码字体分工和 Regular/Medium/SemiBold/Bold/Black 的真实字型匹配、SwiftUI/AppKit 实际字宽，以及注册前后的文件清单和 SHA-256。
同一测试覆盖网页资源 adapter 的字体请求和目录逃逸拒绝。
项目徽标的白色字母像素与实际 JetBrains Mono SemiBold 13pt 文字对照，验证共享
徽标不是 Inter Bold 或合成字重；明暗主题的原生项目菜单捕获也加载实际打包字体。

```bash
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter BundledUIFontTests
node scripts/test-reuse-worktree-resources.mjs
./scripts/verify-runtime-bundle-immutability.sh
./scripts/verify-agent-notes.sh
```

完整安装包由 `scripts/verify-macos-package.sh` 检查全部字型及许可信息。
本次字体注册/字重与明暗弹窗圆角渲染测试通过；按用户要求不启动预览，当前运行界面的视觉验收尚未完成。Windows 原生界面不在本次验证范围内。

此次标题/工具栏修正的主 `LitheTests` 目标报告 1,379 项 / 178 个 suite 成功，
51.296 秒（1,368 项实际执行通过，11 项按条件跳过）；最后把颜色检查取样点从
真实箭头所在位置移到工具栏空白处后，聚焦 8 项实际执行通过，1.240 秒，实际
字体/SVG helper 的 9 项 / 两个 suite 通过，1.201 秒。原生标题检查以深浅主题的
实际像素验证工具栏外侧留白、独立背景、29pt 标题行、1pt 底边、路径提示色和
分段控件单外框，点击后核对双栏/堆叠版本的位置。普通 SwiftPM 不含应用 SVG，
资源专用检查由该 helper 单独执行。标题检查耗时 112ms；1,200 行 / 60 帧组件
调整和截图检查文字重建为零，p95 9.94ms，这不能证明完整应用的实际滚动帧延迟。
任务拥有的窗口和进程均退出；没有启动完整预览应用。HTML 报告在
`.artifacts/diff-header-validation/full/index.html`、`focused/index.html` 和
`native/index.html`，完整工作区视觉验收继续 pending。

## 适用范围

- `macos/Sources/Lithe/Theme/LitheTheme.swift`
- `macos/Sources/Lithe/Platform/MacOS/UI/MacBundledFontRegistry.swift`
- `macos/Sources/Lithe/Platform/MacOS/MonacoWorkbenchEditor.swift`
- `macos/EditorFrontend`
- `macos/Resources/Fonts`
- `scripts/worktree-resources.json`


## 编辑器标签与 Repository Diff

Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的
`VcsLogEditorDiffPreview.getEditorTabName` 与 `VcsLogBundle.properties` 使用
`Repository Diff: {0}`，参数为当前文件名；空预览为 `Repository Diff`，文件历史则
是 `History: {0}`。`DiffEditorTabTitleProvider` 将标题缩至 30 字符。图标来自
`DiffVirtualFileBase` 的 Diff 文件类型，复用已有 `expui/vcs/diff.svg` 明暗资源。

Git Log 历史 Diff 进入已有 `EditorTabItem`/`EditorTabOrderFeatureModel` 的混合顺序，
使用一个可更新文件名的 repositoryDiff 槽。Git feature 继续持有比较上下文和数据；
标签模型仅持有呈现选中状态和返回标签，不复制比较数据。切入 Diff 时停用
原编辑文档/媒体/终端，防止隐藏文档接收保存命令；关闭活动 Diff 恢复前一个
仍存在的标签，关闭后台 Diff 不改当前选择。切换普通文件、媒体、编辑器终端时
隐藏但保留 Diff；重新点标签恢复。关闭 Diff 清理原 Git 上下文，关闭命令按当前
活动内容执行；项目关闭/切换时移除槽；Git Log 改选提交但尚未选文件时保留空预览标题。
加载前即显示可关闭标签，请求身份阻止关闭/替换后的旧激活回调重新打开预览。

`IslandsTabPainter` 对编辑器与工具窗口复用相同 selected active/inactive token；
ManyIslands 明暗主题的 EditorTabs 也指向 `tab-selected-*`。因此编辑器复用
`LitheToolWindowTabStyle` 与 `LitheToolWindowTabCloseButton`，不复制另一套颜色。
普通模式 28pt 圆角块，水平/垂直外侧各 4pt，去掉旧 2pt 蓝色底线；编辑器文字
13pt regular，文件和 Diff 图标 16pt。工具窗口容器保留各自布局。

活动状态与“选中哪个标签”分开；共享 tracker 既观察所在区域鼠标事件，也观察
原生 first responder 变化，使用其 visibleRect 与 bounds 的交集（不能使用超出裁剪区的全文 bounds；
非裁剪 NSView 的 visibleRect 也可能大于自身 bounds）
判断所在区域，支持键盘/程序切换焦点。窗口失活通过 controlActiveState
使用已有非活动样式。观察器随原生视图卸载移除；不启动轮询和定时器。
验证涵盖混合排序、普通文件往返不丢 Diff、关闭恢复文档，以及原生焦点往返和卸载。
完整工作区逐项视觉验收保持 pending；Windows 标签实现未修改。
