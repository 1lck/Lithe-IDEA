# Agent 笔记：macOS Git 提交图对齐 IntelliJ 布局与长边导航

状态：已实现

关联需求：[Issue #410](https://github.com/1lck/Lithe-IDEA/issues/410)。

## 先说结论

macOS Git 提交图以固定版本的 IntelliJ 实现作为算法基准，先对完整仓库建图，再根据当前页面投影结果。颜色、顺序和长边处理都必须保持稳定，这样用户看到的历史图才能和参考实现一致，并且可以回归验证。

## 问题

macOS Git 提交图最初使用固定槽位布局，且只在当前分支页面上建图、
按提交 hash 对固定颜色表取模。复杂合并历史下，这产生了多条无关分支
碰巧同色、颜色和顺序随分页/筛选跳变、长边处理不一致等问题，与用户
熟悉的 JetBrains IDEA Log 行为不一致。截图反馈证实了这些差异会在真实
仓库历史上叠加放大。

需要固定对齐一个不随时间变化的参考实现，而不是随时可能变化的 IDEA
master 分支或截图颜色，否则"是否与 IDEA 一致"无法被验证或回归。

## 决策

算法基准固定为 JetBrains/intellij-community 提交
`36415d346b3d18a6ded90d05afb8e0a0bface9d6`（`GraphLayoutBuilder`、
`GraphElementComparatorByLayoutIndex`、`PrintElementGeneratorImpl`、
`DottedFilterEdgesGenerator`、`GraphColorManagerImpl` 等）。算法落在
`LitheGitModule`，AppKit/SwiftUI 负责绘制与交互；Rust `git.historyPage`
（[`rust/lithe-core/src/git/history.rs`](../../../../rust/lithe-core/src/git/history.rs)）
新增向后兼容的可选 `order` 参数，由 macOS
（[`RustGitOperations.swift`](../../../../macos/Sources/Lithe/Core/Rust/RustGitOperations.swift)）
显式请求 `order: "date"`；Windows 代码与未提供该参数时的默认行为
（`--topo-order`）不变。

关键规则：

- **先建仓库范围的永久图，再投影可见页**。macOS 并行取得最多 5,000
  条所有引用历史和当前分支的一页历史，两者都显式传 `order: "date"`
  （对应 IDEA 的 Normal 模式，按 committer date 排序，不使用 UI 展示
  的 author date）。仓库图决定永久 layout index、颜色和基础顺序；
  可见页只决定显示哪些提交、哪些父提交尚未加载。当前页和引用快照
  就绪即可显示日志、结束首屏加载，不等待仓库上下文；上下文就绪后
  只更新仓库图并触发已有投影，不替换可见页或选择。
- **图头集合和优先级固定**：没有子节点的提交加上所有分支引用和
  HEAD 指向的提交（tag 的内部节点不算）；每个图头按
  `origin/main`/`origin/master` → 其他远程分支 → 本地
  `main`/`master` → 其他本地分支 → tag → HEAD 排序，同类引用用 IDEA
  的自然名称比较。按有序图头做非递归 DFS 分配 layout index，这是
  分支相对顺序，不是屏幕列号，也不用来决定颜色。
- **颜色由图头引用名/layout index 生成，不对 hash 取模**：主片段用
  该图头最优先引用名的 Java `String.hashCode`，其他 DFS 片段用
  layout index 作为颜色 ID，经 IDEA 的整数 RGB 映射得到 hue 再应用
  当前主题的 saturation/brightness 覆盖值；边用两端 layout index
  较大者所属片段的颜色；主题切换清除颜色缓存。
- **筛选只改变可见性，不改变顺序**：作者/关键词/日期/路径筛选后，
  布局顺序仍来自完整图；隐藏祖先产生的虚线经共享隐藏边界 DAG 计算，
  避免逐节点复制累计父哈希集合。
- **长边省略阈值固定复刻 IDEA**：默认紧凑模式对跨度 ≥ 30 行的边
  省略中间行，只在端点 ≤ 1 行范围内保留；显示长边模式的阈值是
  1,000 行，端点范围 250 行；跨度 ≥ 30 行时端点附近仍有方向箭头。
  "长边收束"只隐藏中间行的边本身，不删除中间行的其他提交，也不做
  IDEA 的"折叠一整段线性提交"功能。
- **渲染尺寸和合并提交文字层次复刻 IDEA**：New UI 普通密度使用
  `JBUI.CurrentTheme.VersionControl.Log` 的至少 26pt 行高，并取字体 ascent、descent、leading 的整数度量加 7pt 内边距的较大值；`PaintParameters`
  的 22pt 是缩放基准，16pt 列距、8pt 节点直径、1.5pt 线宽及 2pt
  图文间距均乘以 `26 / 22`，绘制与箭头命中共用同一份几何数据。
  提交文字使用 13pt，引用文字按 `LabelPainter` 使用 12pt 且不绘制旧版
  灰色圆角标签；焦点/失焦选中色复用共享树行主题，选中覆盖 hover。
  深色 hover 按 `VcsLogGraphTable.getHoveredBackgroundColor` 与
  `ColorUtil.mix` 将白色和当前背景以 18/255、237/255 混合，不能把
  `#FFFFFFED` 直接当作高不透明度覆盖层。两个及以上父节点的合并提交在未选中时，标题、作者和日期统一使用
  `VersionControl.Log.Commit.unmatchedForeground`（深色 `#6F737A`，浅色 `#818594`）；
  选中后恢复主文字色，对齐 `MergeCommitsHighlighter`。以父节点数量而非
  标题是否以 "Merge" 开头判断是否为合并提交。

Git 工具窗的活动态必须双向跟随工具窗、提交列表、关键词、分支和路径筛选
的当前焦点；全部失焦时清除活动态，不能只在获得焦点时置为 true。视图挂载
只恢复显示，不请求 first responder（接收键盘输入的控件），避免打断编辑器
输入；只有显式用户操作才能请求焦点。验证时用键盘从这些控件切回编辑器，
并检查隐藏后重新显示 Git 不会抢走编辑器焦点。

标题起点沿用 `GraphCommitCellUtil` 的缩放列距与图文间距，并计入
`SimpleColoredComponent` 的 2pt 左内边距。为对齐用户给出的六列参考截图，
Lithe 为标题预留至少六列；更密集的行可以继续扩宽。这是 Lithe 的显示选择：
上游按推荐图宽取最多六列，并不强制所有仓库至少六列。仅扩大文字预留区，
不改变节点、边、图谱路由或箭头命中位置。

图谱绘制继续按行高缩放，但最终尺寸按 UI 基准提交
`c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的 `SimpleGraphCellPainter.MyPainter`
和 `PaintUtil.alignToInt` 对齐屏幕物理像素（`FLOOR` / `ODD`，向下取奇数像素）。
此前直接绘制浮点缩放值，导致 Retina 2×、26pt 行高时圆点约 9.45pt、线宽约
1.77pt；对齐后为 8.5pt 圆点和 1.5pt 连线/箭头描边。尺寸从当前绘制上下文的
缩放系数计算，不能将 Retina 数值写死，否则 1× 屏幕或切换屏幕时会失配。

`GitGraphGeometry.PaintMetrics` 同时提供绘制和箭头命中坐标。列距、圆心、
圆点半径及终止箭头留白均使用对齐后的值；箭头两侧仍遵循 0.3 × 行高的长度
与 `sqrt(0.7)` / `sqrt(0.3)` 的旋转公式。逻辑图宽、标题预留和图谱拓扑保持不变。
对齐可能让斜向箭头尖端跨过逻辑行边界半个点，因此命中检查覆盖相邻行及尖端
附近一个物理像素；屏幕 backing scale 变化只重绘，不重新建图。

Git Log 时间列保留 Inter 13 regular，启用字体的等宽数字特性，避免 `11`、`55`
等数字组合改变文本总宽度。按应用语言而非系统语言选择格式：英文为
`yyyy/MM/dd hh:mm AM/PM`，中文为 `yyyy/MM/dd HH:mm`。英文 AM/PM 使用固定
宽度区域，数字块和后缀分别对齐；列表的 SwiftUI/AppKit 两条路径及提交详情
复用 `GitLogDatePresentation`，既有 `GitLogQuery.parseCommitDate` 负责解析，
不改变提交时间、时区含义、历史排序和筛选。原生日期显示按原始日期缓存，
更新行或切换语言时失效，滚动绘制不重复解析可见行。
AppKit 重绘区域先与视图 bounds 相交再换算行号，避免 SwiftUI 原生截图传入
无限重绘区域时发生浮点转整数越界；位图检查覆盖此路径。

提交标题、作者和日期使用 Inter 13 Normal；引用标签使用 12pt。文字绘制复用
CoreText 的单行布局和省略号处理，采用 `SimpleColoredComponent.getTextBaseLine`
的整数基线公式，并计入 JetBrains Runtime 的 leading。绘制和截断共用同一字型，
每个单元格裁剪后绘制，避免长标题覆盖其他列；按 SimpleColoredComponent 默认关闭分数度量的规则，
仅在 Git Log 的绘制上下文关闭子像素字形定位，不对字形施加缩放或描边来模拟粗细。
JVM 与 CoreText 的栅格化器不同，因此遵循相同度量规则不代表像素级完全相同。


右侧文件树复用 `LitheTheme.Tree` 的 24pt 行高、19pt 层级缩进、16pt 图标、
常规文字与选中/悬停色。对齐 `ChangesBrowserFileNode` / `ChangesBrowserNodeRenderer`：
文件类型图标由已有 `LitheIcons` 目录取得，文件名用 `IslandSchemeDark` /
`expUI_lightScheme` 的 FileStatus 色显示修改、新增、删除或重命名；不再显示
状态字母、逐行横线和工具栏内重复总计数。保留原生横向滚动、裁剪文字展开、
内容宽度缓存以及点击文件打开 diff，拖动只改变可视区，不重建每行图标。

提交详情按 `CommitDetailsPanel` 的 14pt 外边距与 10pt 内部间距排版：
标题使用默认编辑器字体的 bold，作者/邮箱/时间使用 13pt 普通界面字体，
在同一段文字中换行；引用复用图谱标签绘制，不用原始 decoration 字符串。
详情可滚动，避免长标题被两行限制裁掉。文件树与详情之间只保留共享 1pt
分隔线，悬停和拖动不高亮。

左侧分支栏的 180pt 限制不来自 `BranchesInGitLogUiFactoryProvider` 的
`OnePixelSplitter`；上游把独立工具栏放在可调整树区之外，并按子组件尺寸限制。
Lithe 删除这处专用限制，使用工作区已有 30pt 面板下限；36pt 竖栏不计入树区，
且继续保留分隔条的命中区、裁剪、拖动结束更新宽度及收缩前视图身份。
这遵循本项目共享窄面板规则，不宣称 IDEA 在所有环境中的最小树宽均为 30pt。

### 连续拖动时保持原生可见区域与数据计算独立

Git Log 的生产路径使用已有 `GitGraphScrollView` 的原生滚动容器和绘制表面。
分隔条改变可见区域的高度，提交数据和图谱快照继续保留；绘制仅处理脏矩形中的
行，不为每条提交重新布置 SwiftUI 控件。这个边界参照 UI 基准提交的
[VcsLogGraphTable](https://github.com/JetBrains/intellij-community/blob/c7f91397daa3a961b4e78bc634fe467a0a7d9ade/platform/vcs-log/impl/src/com/intellij/vcs/log/ui/table/VcsLogGraphTable.java)
与工具窗口外层实际使用的
[ThreeComponentsSplitter](https://github.com/JetBrains/intellij-community/blob/c7f91397daa3a961b4e78bc634fe467a0a7d9ade/platform/platform-api/src/com/intellij/openapi/ui/ThreeComponentsSplitter.kt)：
鼠标坐标转到固定容器、限制尺寸，再对现有组件设置边界；仅边界变化时才
让子组件重新布局。面板尺寸调整与日志数据更新分开。
底部工具窗口标题栏的入口则是
[ToolWindowContentUi.initMouseListeners](https://github.com/JetBrains/intellij-community/blob/c7f91397daa3a961b4e78bc634fe467a0a7d9ade/platform/platform-impl/src/com/intellij/openapi/wm/impl/content/ToolWindowContentUi.java)：
按下时保存屏幕坐标及初始高度，拖动时用屏幕 Y 位移修改同一个 splitter 的
末尾面板高度。它和分隔条的坐标入口不同，但共用现有面板边界布局。

Lithe 的共享分隔容器在宽高确定时直接向子面板传入最终矩形，避免堆栈布局
在每次拖动中询问最小、理想及最大尺寸。布局仍由 SwiftUI 管理，不移走焦点、
滚动代理和环境值；这只是采用上游的确定边界布局原则，不能将两种 UI 框架的
实现或耗时视为相同。主队列异步合并只合并交付前到达的事件，不保证每个显示
刷新周期只交付一次，也不能代替布局成本验证。

原生视口的 `layout` 负责同步文档宽度和高度，因此恢复尺寸不依赖一次新的数据
刷新。多选、Shift/Command 点击、上下键、焦点选中色、右键操作、箭头跳转、
引用图标、分页与辅助功能继续使用已有动作。重复跳转到已选提交使用导航请求
标识，不能只比较所选 hash。辅助功能访问时才生成可操作的行和箭头节点，
不能在每次拖动时创建整棵行视图。

Git Log 分支内容和右侧文件树在尺寸读取器外构建；仅改变高度时不重建文件树。
上方 Diff 的全文宽度测量、折叠规划及双栏布局同样在尺寸读取器外生成，再传给
共享 `DiffSplitPaneView`。Diff 两侧使用 `LazyVStack` 按可见区域创建行，避免
普通 `VStack` 在拖动时布置整份文件。行内容在共享双栏视图自己的高度读取器
外构建；即使远距离滚动已创建中间行，后续高度变化也不重新生成全部行。
窗口尺寸仅影响最终可见宽高；数据、折叠或差异选择
变化时仍会重新计算。三个 Diff 调用入口都遵守这个规则，不能只优化 Git Log
截图对应的一条路径。

SwiftUI 第一次远距离滚动时仍可能测量中间行，测试已观察到这个行为；本次
约束是初始可见区域和随后的拖动不能反复构建整份 Diff。若以后远距离跳转的
成本成为问题，再评估原生视口绘制，不扩大本次拖动修复的范围。

局部绘制对照计时只用于定位成本，不作为固定帧率承诺，也不以机器相关的耗时
阈值让单元测试失败。最终流畅度仍需在目标工作区连续拖动确认。

## 考虑过的备选方案

- **按提交 hash 对固定颜色表取模（初版实现）**：实现最简单，不需要
  维护图头优先级或 layout index。但相邻的无关分支会碰巧同色，复杂
  合并历史下这个问题会被放大，因此改为按图头引用名 hashCode/layout
  index 生成颜色。
- **只在当前分支页面上建图，不建仓库级永久图（初版实现）**：减少
  一次并行请求，实现更直接。但缺少仓库级主线优先级，分页或切换
  筛选条件时顺序和颜色会跳变，因此改为先建完整仓库图再投影当前页/
  筛选结果。
- **启用 IDEA 的 BEK 模式或"折叠一整段线性提交"功能**：这两个都是
  IDEA Log 的可选模式，实现它们能进一步对齐 IDEA 的全部能力。但本次
  范围只需要 Normal committer-date 模式和长边省略，扩大范围会显著
  增加验收面，因此明确不启用，长边收束也不等同于折叠线性提交。
- **用界面展示的 author date 排序，避免额外请求 committer date**：
  可以复用已经显示的时间字段，不需要 Rust 侧新增参数。但 IDEA 的
  Normal 模式实际按 committer date 排序，用 author date 会在
  rebase/cherry-pick 后与参考行为不一致，因此新增可选 `order` 参数
  显式请求 committer date 排序。

## 后果

- macOS Git 提交图的颜色、顺序和长边行为与固定版本的 IDEA Log 一致，
  可以用同一份上游 fixture 和独立 Java oracle 验证，而不依赖会变化
  的截图或 master 分支。
- 仓库上下文和单个历史 cursor 分别有 5,000 条硬上限；超出范围的极
  旧分支会退回到只用当前页建独立图，不承诺仓库级颜色/顺序一致性。
- 缺页传播使用共享隐藏边界 DAG 后，5,000 个不同缺页端点的合并链从
  平方级复制降到线性量级，但辅助图仍随输入节点和边增长，不保证
  所有输入都线性耗时。
- 代价：渲染必须等仓库图 DFS 完成才能确定最终颜色和顺序，实现上
  比"只处理当前页"更复杂，且引入了仓库上下文的取消/generation
  校验逻辑；`git.historyPage` 多了一个需要向后兼容维护的可选参数。
- 需要重新评估的触发条件：如果以后要把图算法迁移为 macOS/Windows
  共享实现，必须以本 Note 引用的固定 IntelliJ commit 和 macOS 的
  算法回归 fixture 为依据，不能重新从零选择对齐目标。

## 验证

`GitGraphInteractionTests.continuousViewportResize` 连续调整原生视口 80 次，
检查文档和子视图身份、文档宽度、滚动位置、多选、修饰键、上下键及重复跳转。
`dragGitLogWithDiff` 用真实共享分隔条事件调整上方 1,200 行 Diff 和下方
300 条提交的布局，检查收缩和恢复以及原生文档身份。
`splitDiffCreatesViewportRows` 检查 1,200 行 Diff 只创建视口附近的行，并能滚动到
末行，随后改变高度时也不重新生成全部行；`viewportResizeComparison` 输出同机旧 SwiftUI 列表和原生列表各 30 次调整与
绘制的耗时，不设置机器相关时间门槛。


`GitGraphInteractionTests.titleGutter` 检查六列标题预留与复杂图谱扩宽；
`mergeColumnsRenderTogether` 实际渲染 SwiftUI/AppKit 两条路径，检查合并行
标题、作者、日期在选中与未选中时的颜色；`GitCommitFileTreeLayoutTests` 检查
明暗主题下修改文件名的实际像素色、无逐行分隔线，以及可视宽度变化后的滚动范围。


- `./scripts/build-macos.sh`
- `./scripts/verify-git-graph.sh`
- `./scripts/verify-service-boundaries.sh`
- `git diff --check`

上游对照 fixture 固定保存在
[`macos/Tests/LitheGitModuleTests/Fixtures/GitGraphIDEA/`](../../../../macos/Tests/LitheGitModuleTests/Fixtures/GitGraphIDEA/)
（4 个布局 fixture 比较完整 layout index 向量，5 个打印 fixture 比较
节点列、半边端点、箭头与实/虚线，只排除颜色值）；真实历史回归数据
冻结在
[`macos/Tests/LitheTests/Fixtures/GitGraph/`](../../../../macos/Tests/LitheTests/Fixtures/GitGraph/)
（只保留拓扑、公开引用和显示所需标题，不含作者个人信息）。对照输出
由独立 Java oracle 直接调用 IntelliJ IDEA 原始类生成，不使用 Lithe
生成期望值；生成方法见同目录 README。普通测试只读取冻结文件，不
依赖安装 IDEA、Java、网络或本地 Git 仓库状态。Apache-2.0 许可证和
来源说明放在
[`macos/Resources/GitGraph/`](../../../../macos/Resources/GitGraph/)，
随预览、打包和性能测量应用一起复制。

## 适用范围

- `macos/Sources/LitheGitModule/Services/GitGraphHeadOrdering.swift`
- `macos/Sources/LitheGitModule/Services/GitGraphProjection.swift`
- `macos/Sources/LitheGitModule/Services/GitGraphMissingParents.swift`
- `macos/Sources/LitheGitModule/Services/GitGraphLayoutService.swift`
- `macos/Sources/Lithe/Views/Git/GitGraphColor.swift`
- `macos/Sources/Lithe/Views/Git/GitGraphGeometry.swift`
- `macos/Sources/Lithe/Views/Git/GitGraphView.swift`
- `macos/Sources/Lithe/Views/Git/GitLogView.swift`
- `macos/Sources/Lithe/Views/Git/GitCommitFileTreeView.swift`
- `macos/Tests/LitheTests/GitCommitFileTreeLayoutTests.swift`
- `rust/lithe-core/src/git/history.rs`
- `macos/Sources/Lithe/Core/Rust/RustGitOperations.swift`
- `macos/Tests/LitheGitModuleTests/Fixtures/GitGraphIDEA/`
- `macos/Tests/LitheTests/Fixtures/GitGraph/`
- `macos/Resources/GitGraph/`
