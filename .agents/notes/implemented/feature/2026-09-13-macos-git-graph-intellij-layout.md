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

### 当前分支底色与紧凑引用标签

以 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的
`CurrentBranchHighlighter`、`GitRefManager.groupForTable`、`SimpleRefGroup`、
`LabelPainter`、`LabelIcon/TagPainter` 和 Islands 主题为准。深蓝底色表示当前
分支可到达的提交，包含所有合并父节点，不按图谱列、连续行块或提交标题猜测。
深/浅背景为 `#1D2336` / `#EDF3FF`；选中行优先，hover 在当前底色上叠加。
单独过滤 HEAD 或当前分支时不再重复强调；没有当前本地分支时不着色。

祖先集合在数据刷新任务中生成，绘制和拖动不读取 Git。当前只遍历已加载图谱，
因此缺失的历史不能推断为当前分支成员；完整仓库索引成熟后可扩展同一数据入口。
不能在原生 draw 或逐行 body 中运行 `git branch --contains`。

提交标签默认显示，采用 IDEA 默认的紧凑模式、右对齐及不显示 tag 名称规则。
同一提交上的本地分支和其上游合成 `origin & main`，没有显式上游时允许同名
远程分支合并；当前分支优先，其余名称复用已导入的自然排序规则。HEAD 以黄色
图标加入分组，分离头指针保留 HEAD 文字。每种引用类型最多两个叠加图标；
本地绿、远程紫、HEAD 黄、tag 灰，均使用 Islands 明暗专用颜色。

名字超过 22 个字符且空间不足时，先将首段路径缩成 `..`，再按字体宽度省略；
22 是上游保留长度下限，不是始终截到 22。原始引用名不改写，悬停显示组内全部
完整名称。整张原生提交表只注册一个可见范围的 AppKit tooltip 区域，显示时再
按行和标签范围命中，避免给每条提交创建 SwiftUI tooltip/几何覆盖层。
`GitGraphReferenceGroup` 是显示值，不改变 Git 引用和图谱排序的业务模型。

`GitGraphLayoutTests.currentBranchMembership` 覆盖交错分支、合并父节点及缺失历史；
`GitGraphInteractionTests.referenceGroups/referenceHoverAndCurrentBranchColor` 验证
名称、堆叠类型、省略后原名和深浅主题选中覆盖。

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

### 后台刷新不能把深处历史缩回首批

文件状态变化不代表提交历史变化，普通状态刷新只在仓库、分支或所选引用上下文
改变时重开历史。工作区监听仍会检查历史，因此外部提交和其他工作树移动共享
引用不会因为当前工作区状态没变而被漏掉；但后台重读的窗口大小必须保留已加载
条数，并一次发布结果，不能先显示首批再靠底部自动加载补回来。否则文档高度
反复缩短和增大，会让底部滚动条上下跳动。
若新提交把原窗口尾部挤出，按共同提交的实际位移补读相应条数，再一起发布，
避免尾部选择丢失；没有共同提交的历史改写不盲目扫描整个仓库。

重读期间保留仓库图和后续页占位高度，暂停自动翻页；结果未变时不使已有提交、
引用和仓库图的呈现版本失效。当前仓库的分支树复用同一次引用读取，其他仓库
独立读取并继续做代次校验，避免同一仓库并行执行两份完全相同的引用查询。
后台刷新打断边缘请求且返回相同行时，也会释放原边缘去重状态，让新游标继续翻页；
失败状态仍暂停自动重试，不因加载状态变化形成失败循环。

原生视口更新前记录顶部可见提交 hash 及行内像素偏移。新提交插在上方时，按
这个锚点恢复，而不是滚回旧像素坐标或当前选择行；只有选择改变、切换上下文和
显式图导航才允许主动定位。若原提交已经被改写掉，则夹取旧偏移到真实文档范围。
正确例子是浏览第 170 行时保存文件，仍看到同一提交和行内偏移；不要在保存后
替换为 100 行、清除后续页占位，再触发自动读取。

代价是后台刷新会重新读取已经展示的有界窗口，而不是每次只读首批；它仍受
Core 历史上限约束，不会为了固定滚动条长度预取整个仓库。进程超时仍照常报告，
去掉重复查询不等同于隐藏或证明修复所有原生进程清理失败。

`GitModuleTests.backgroundRefreshRetainsDeepHistoryAndSelectionWhileExternalCommitsStillAppear`
覆盖状态改变、未变元数据、外部新提交、继续翻页和选择保持；
`GitGraphInteractionTests.backgroundHistoryRefreshAnchorsVisibleCommitInsteadOfSelectedCommit`
走真实原生更新路径，检查加载状态不改变滚动范围、新提交的像素锚定，以及显式
导航仍优先。多仓库引用回归同时验证当前仓库只查询一次。

### 连续拖动的布局边界

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

### 连续滚动自动补充历史

Git Log 在视口接近底部时自动读取下一批较早提交，不再把“加载更多提交”
作为正常浏览的必经动作。读取仍使用既有有界游标（后端返回、下次原样传回的
分页标记），不会一次读取全部历史。原生滚动容器处理边缘判断，同一批最后一条
提交只触发一次请求；每个像素的滚动位置不进入整个工作台的状态。

正确做法是：用户看到第 50 条附近时请求下一页，追加后保持当前视口和选择；
不要在追加后重新定位所选的第 1 条，也不要在绘制回调中反复读取同一游标。
没有新增提交或没有后续游标时停止自动加载，并释放未继续使用的游标。
失败时只显示显式重试，不自动循环；Core 的失败游标已经失效，重试重新读取
历史，而不是继续使用旧游标。重新读取按已加载的条数打开窗口（与后台刷新相同的
保留窗口路径），不能缩回首页，也不能移动当前选择；否则在深处点击重试会丢掉
用户已经滚过的列表。Windows 已有视口边缘自动加载，本次保留其入口。

工作树详情的“提交历史”也遵守这一规则。原生行容器在距底部十行内自动补充，
同一页只发起一个请求；追加和窗口改宽都保留像素偏移。文档高度必须跟随行数
变化，不能只在宽度变化时重新设置，否则新提交虽已收到却无法滚动到。
首屏仍复用当前仓库已有的最多 80 条提交，其他工作树先读 30 条；移除无视
视口的后台 80 条预热，避免迟到预热把已追加的长列表覆盖成短列表。第一次
续载用包含首屏的有界请求打开游标，后续每次只读 50 条，仍受 Core 5,000 条
上限约束。失败保留已有行，暂停自动请求，显式重试重新打开游标。
状态扫描和历史追加分别合并当前结果，不能把新收到的变更或提交覆盖成旧快照。
搜索只筛选已加载历史，有搜索条件时不自动遍历整个仓库；切换工作树、关闭页面、
移除工作树或重置仓库时取消在途续载并关闭游标，迟到结果只清理自身资源。
Windows 的 Worktree 弹窗目前没有此提交历史详情，不以这次 macOS 修复宣称两端
详情功能已经对齐。

工作树详情的“更改”不是只读状态表。它复用提交页的选择规则、共享复选框和
原生可见区域绘制，提供单选、Command/Shift 多选、全选、暂存、取消暂存、
Diff、打开文件、定位与复制路径。空格切换当前项暂存，Return 打开 Diff；
点击复选框不能顺带打开文件，扩展选区也不能打断当前 Diff。
批量操作优先作用于选区；右键未选中的文件只操作该文件。

所有写操作由 `GitFeatureModel` 调用已有 Git service，沿用提交页的暂存、
取消暂存和回滚语义，不另外拼命令，也不隐式切换活动仓库。执行前核对
工作树仍在列表、路径可用且快照已加载，再将捕获的文件与最新状态逐项匹配。
例如，正确做法是向选中的 linked worktree 的根目录执行暂存；不要把同名文件
映射到主工作区，也不要让旧确认框操作刷新后已经改变的文件。回滚必须先显示
选中工作树及文件，并明确提示未跟踪文件会被删除；只回滚工作区变更，保持
提交页已有的暂存区语义，不把“取消暂存”误当作删除文件。

变更批次在途期间禁止重复提交，首个失败停止后续文件，保留错误供用户处理。
取消或重置后的迟到结果不向新上下文发通知。操作后只重新扫描该工作树状态，
合并到当前详情，保留已有历史与游标；扫描失败保留旧行并显示错误。
已打开的该工作树 Diff 跟随新状态刷新，文件变干净后关闭。其他工作树或仓库
的新选择不能被旧扫描覆盖。Windows 当前只有管理弹窗，没有这组更改详情，
本次没有新增 Windows 对等入口。

同样的交互规则写入 `develop-lithe` Skill。反汇编列表也按滚动方向自动补充
指令，上方插入时保留旧首行的像素位置；当前指令的定位只改变纵向偏移，
短指令靠左，长指令保留横向滚动。内存查看器是离散地址页，不套用连续列表规则。

反汇编的映像边界不能只等空页：本机 LLDB 21 在 Mach-O（macOS 可执行映像）
头部地址继续向前读取时，会返回 `Unexpected error while disassembling instructions.`。
上游 `llvmorg-21.1.0` 的 `lldb/tools/lldb-dap/Handler/DisassembleRequestHandler.cpp`
也用同一错误表示起始地址或指令列表不可用，不能根据英文文案判断错误类型。
宿主对被拒绝的反汇编页按 64、32、16、8、4、2、1 条有界缩小请求；
单条相邻指令仍失败时，再读取已知边缘的一条指令。只有边缘仍可读才认为该方向
到头，保留列表且允许向另一个方向滚动。超时、取消、传输停止和无效回复不走
缩页；边缘验证失败仍显示可重试错误，旧暂停代次的验证结果直接丢弃。

不要把所有分页失败都吞成“到头”，也不要按 ARM 固定宽度自己减地址：
正确做法是继续把原始引用和 `instructionOffset` 交给适配器。上游补齐的空白
无效指令不作为行或下次翻页锚点；有字节但没有助记符的内容仍按上游原样显示，
不在宿主猜测可执行区段。错误条占满可用宽度并靠左，不因错误文字长度而居中。

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

### 大量引用的首屏准备与面板重开

Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的
`VcsLogRefresherImpl` 先读取近期提交块，`GraphTableModel` 按行读取图与引用，
`MiniDetailsGetter` 从缓存取得详情或返回占位数据，再后台补齐。
Lithe 已使用有界分页、后台图投影和原生可见区域绘制；大量分支仍可能被
显示前的标签准备阻塞，因此不能把“后台执行”当作已消除首屏等待。

引用分组对真实 upstream（本地分支实际跟踪的远程分支）优先匹配，找不到
才沿用自然排序后的同名远程回退。每份显示结果只建立一次本地引用索引，
每组远程标签按完整名称和分支名建索引；不要在每个本地标签内反复扫描全部
远程标签和拆分名称。完整标签、提示文本、自然排序及图标上限均保留。

项目的 `AppModel` 持有最近一份 `GitLogPresentationCache`，只缓存呈现数据，
不持有模型、窗口、任务或业务动作；不写磁盘、发行 bundle 或共享构建资源。
同一项目隐藏再打开 Git Log 时按现有版本令牌复用。匹配缓存必须在视图初始化
时填入本地状态，让第一次布局直接获得提交和分支树；不能等出现后的任务再
回填，否则即使没有重新建图，也会先挂载空面板再做一次完整布局。
提交、仓库上下文、引用、
筛选和显示选项变化都拒绝旧结果。无筛选时忽略空筛选任务的版本变化，避免
重新打开触发一次无意义重算。异步结果仍在取消与身份检查后发布及入缓存。
每个项目仅保留最近一份，项目释放时一并释放；首次打开仍需准备实际图数据。
同一缓存同时保留最近一份分支树行数据，身份包含引用、各仓库引用、仓库根、
工作树显示开关和折叠集合；提交图更新不驱逐未改变的树。单仓库不构建多仓库
分组副本，多仓库的活动根直接复用已构建的三类行，避免同一输入重复建树。
原生提交行的绘制和无障碍文本共用已有日期解析缓存；引用刷新和语言变化仍
沿用原有缓存失效规则，不裁掉离屏提交的无障碍导航。
右侧提交详情也使用懒布局，只创建可见的分支标签；不能因选中提交有数千个
引用，就一次实例化全部离屏标签并阻塞中间提交列表的首屏显示。

正确做法是“数据版本相同，重开面板复用已准备结果”；不要用静态全局缓存
保留所有项目，也不要在版本不同的情况下拿旧图代替新分支结果。
本次没有重写原生表格，也没有扩大历史读取量或改变后端分页：已采样的热点是
`GitGraphReferenceGroup` 中本地/远程标签的嵌套查找，优先消除这项开销。

回归由 `GitGraphInteractionTests.manyReferenceGroups` 覆盖同提交 3,001 个标签、
真实 upstream 优先、缺失 upstream 的自然排序回退、重复输入和完整提示；
`presentationCache` 覆盖所有缓存身份字段及最近一份的替换；
`referenceRowsCache` 覆盖树输入失效及图/树缓存互不驱逐，`nativeDateCache`
验证明暗无关的日期文本在语言切换和重复读取时一致。耗时仅记录诊断，
不作为依赖机器速度的断言；整机首屏与拖动仍需用同一数据重新打开验证。
本机同一 3,002 引用演示项目已完成面板重开、宽高拖动与详情末项滚动；
修复后的连续八次开关采样未再出现分支树构建、图投影或引用分组调用栈。
这是该演示场景的诊断证据，不能据此保证所有项目的单帧延迟或用户手感。

### 工具窗口隐藏与重开的控件生命周期

Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的
`ToolWindowImpl.kt` 通过惰性内容管理器创建内容，`ToolWindowManagerImpl.kt`
隐藏工具窗口时卸下外围容器；`VcsLogUiImpl.java` 和 `MainFrame.java`
仍持有原图表，显示状态变化通过 `VcsLogManager.kt` 激活已有刷新器。
因此只缓存图数据不足以实现相同的重开边界。

Lithe 在工作台视图中持有 `WorkbenchToolContentStore`，本次用于 Git Log 和
终端。第一次打开才创建原生宿主（承载 SwiftUI 内容的 `NSHostingView`），
宿主始终挂在工作台的固定原生表面，停靠槽仅报告位置与尺寸；隐藏时只设为不可见，
重新打开或移动停靠位置时更新同一宿主的边界，工作台释放时一起释放。
直接从 SwiftUI 停靠槽拆下再接回宿主的原生回归仍会重建内部提交控件，因此
不采用这条看似更短的实现。传入当前环境以保留语言、主题、设置和工作区依赖，已有功能模型
继续拥有数据刷新和终端会话。尚未打开的工具窗口不提前创建。隐藏时清除面板内的原生键盘焦点，固定表面的
无障碍子项只包含可见面板，避免不可见按钮继续被读取或操作。

独立宿主显式传入 `workbenchHasBackgroundImage`，该值也进入内容身份，背景从无图切换到有图再移除时，
终端标题栏和正文必须跟随恢复，不能仅将外层面板设透明。宿主从隐藏变为可见时通过 `onActivate`
在本轮布局结束后请求一次当前工具终端会话的输入焦点；连续 frame/环境更新不触发激活。
隐藏或解绑会取消尚未交付的激活请求，避免迟到回调抢回编辑器焦点。Git Log 不安装焦点回调。
保留树在隐藏期间仍会响应会话选择，不能只取消 `onActivate`：当工具会话从 B 回退到 A 时，
`TerminalSurfaceView` 会重新挂载。它的出现任务和原生异步焦点回调都必须在交付时检查原生视图
仍挂在窗口中且自身和祖先均未隐藏；异步入口还须确认原生视图仍属于原宿主。
重开沿用显式激活回调，不靠重复挂载恢复焦点。
`hiddenToolSessionRemountCannotTakeFocusFromEditorTerminal` 使用两个工具会话 A/B 和编辑器会话 C，
验证隐藏后选择 C 即使重挂 A 也不请求会话焦点、不改变 first responder，重开后才激活 A。

保留内容的圆角由独立、不能接收鼠标或无障碍焦点的轻量宿主绘制，叠在内容宿主之上。
停靠槽从原工作台的 `workbenchFrame` 命名坐标空间取得矩形，圆角继续复用共享形状与渐变算法，
显式接收该矩形、当前项目辉光和主题。位置、尺寸、项目色或背景图改变时只更新圆角层；
不要把这些几何输入加入 Git Log/终端内容身份，否则连续拖动会再次更新重内容根视图。
仅传辉光仍不足以修复独立宿主中的坐标原点；重新绘制纯标题栏色会在侧栏顶部留下色块。
`WorkbenchSurfaceBackgroundTests.retainedPaneCornersMatchWorkbenchGradient` 在真实窗口里对照
原工作台树和保留宿主的四角像素，覆盖两种工具、明暗主题、移动及尺寸变化、项目色变化、关闭渐变和背景图恢复。
像素对照证明共享绘制一致，不替代目标设备上的界面人工验收。

工具窗口拖放的落点高亮和位置提示必须在固定内容表面之上。工作台通过
`workbenchToolContentLayers` 在相同工作区边界内依次叠放保留表面和落点预览，预览保持鼠标穿透，
原落点计算和停靠提交不变。不要将预览留在内部停靠布局中：不透明终端或 Git Log 会遮住它，
即使松开仍能移动也不代表用户能看到目标位置。
`ToolWindowDockingTests.dropPreviewStaysAboveRetainedPane` 在真实窗口中对照原 SwiftUI 面板与
不透明保留面板的高亮、文字区域像素，覆盖明暗主题、两种工具和底部左右目标；同时检查工作区
偏移、预览清理、鼠标穿透和宿主身份。组件渲染回归不替代整机拖放的人工验收。

固定表面的命中不能覆盖外层分隔条伸入面板的区域，也不能在命中过程中重新查询窗口根视图。
命中测试（`hitTest`）用于确定鼠标下的控件；祖先正在遍历 SwiftUI 时，后代再次调用祖先的
`hitTest` 会同步重入尚未结束的遍历。旧实现虽然用布尔值阻止 `Surface` 自身无限递归，
仍会重入祖先。[Issue #1542](https://github.com/1lck/Lithe-IDEA/issues/1542) 的
0.6.5 Intel 发布二进制 UUID 与报告一致，崩溃位置对应这次根视图回查内部的 Swift 独占访问冲突。
独占访问要求同一存储的修改不能相互重叠，同一线程重入也可能违反；不能因此推断是后台索引竞争。
报告没有给出冲突存储的名称，不声称已确定 SwiftUI 内部的具体变量。

正确做法是由每个工作台的 `WorkbenchToolContentStore` 持有一个弱引用登记表
`SplitHandleHitTestRegistry`，只把原布局树中的分隔条加入表中。固定表面先正常查询自己的
保留内容，再从登记表判断是否应交给外层分隔条；判断只读取原生控件当前的 `bounds`、
`visibleRect`（祖先裁剪后仍可见的范围）及坐标转换，不调用任何祖先的 `hitTest`。
重叠分隔条沿原生兄弟视图层级择前，不按登记顺序选择。不缓存另一套布局矩形，也不在每次
鼠标移动时扫描整个窗口树，因此重内容的规模不会增加查找的候选数量。

登记表不传给独立的保留宿主，Git Log 内部的分隔条仍由自身正常遍历接收事件，不抢走外层边缘。
禁用、收起和卸载时取消登记；收起面板中的嵌套分隔条也清除登记作用域。查询还排除隐藏、
透明、已裁剪或不在同一窗口中的控件。原生控件移动窗口时更新登记，弱引用避免工作台持有已卸载
控件。代价是新增绕过 SwiftUI 遍历的转发路径必须显式维护可交互状态；不能假定任意 SwiftUI
隐藏修饰符都能从 AppKit 控件推断出来。

不要改成“根视图回查但多加一层防递归”，这仍然重入祖先；也不要简单删除外层分隔条转发，
那会把 10pt 命中范围缩成没有被保留面板遮住的部分。临时隐藏宿主或缩小内容同样不采用，
避免破坏焦点、跟踪和原有布局。

`retainedHostsPreserveOuterDividerHitArea` 覆盖横纵方向及工作区偏移，实际通过窗口发送中央和
两侧偏移 4pt 的按下、拖动和松开事件，检查每次尺寸只提交一次、面板中央命中及两个宿主身份；
根视图命中深度必须为 1，连续 100 次面板查询也只进入根视图 100 次。原实现会稳定得到深度 2
和 200 次根查询，新实现消除该重入。直接调用 handle 方法绕过窗口分发，不能证明这条边界。
`GitLogReferenceResizeTests` 另覆盖禁用、收起、恢复、嵌套及卸载；
`SplitHandleHitTestTests` 覆盖实时几何、裁剪、原生层级、窗口隔离及弱引用生命周期；
`DiffScrollSynchronizationTests` 在普通和保留侧栏下经真实窗口事件验证两端收起后仍可拉回。
较新系统可复现旧实现重入，但未复现原报告的 abort；这些回归不替代 macOS 13 Intel 原机验收。

`TerminalPlacementFeatureModelTests.retainedTerminalRestoresFocusAndWallpaperWithoutRecreatingItsSurface`
使用真实 `TerminalView`/`TerminalSurfaceView` 和无进程测试 transport，在明暗主题检查标题栏/正文像素、
相同原生输入控件的 first responder、隐藏/重开、连续尺寸更新及隐藏后的取消；不以空白占位内容替代终端界面。


正确做法是“隐藏槽 → 固定表面中的宿主不可见 → 重开时恢复边界和可见性”；不要把构造一个新的 SwiftUI
值或恢复图数组描述成复用原生控件。代价是打开过的两个面板会占用内存直到
工作台关闭。本次没有把其他工具窗口迁入此生命周期，也没有移植 Swing 组件；
初次数据加载与后台刷新机制不声称和 IDEA 完全相同。

`GitLogReferenceResizeTests` 通过生产宿主路径加载 1,000 个分支，在同一工作台隐藏停靠区再重开，断言实际提交文档与滚动容器的对象身份保持一致，
隐藏期间仍挂在原窗口，恢复后已有提交和分支，并单独验证工作台持有者释放后的清理。该断言验证不重建，不代表固定帧延迟或所有工作区的流畅度保证。

## 验证

- `DebugDisassemblyLayoutTests` 验证明暗主题、左右对齐、横向溢出与步进位置，
  `GitGraphInteractionTests` 验证原生视口自动加载、同页去重和追加后的偏移。
- `DebugModuleTests` 与 `GitModuleTests` 验证无进展、失败、重试及失效请求边界。
- `GitWorktreeAppearanceTests.historyScrollAutomaticallyAppendsWithoutMovingViewport`
  使用真实原生视口覆盖深浅主题、接近底部续载、同页去重、追加偏移、同宽行数变化、
  改宽、短列表、搜索上下文切换及失败/到尾停止；`GitModuleTests` 另验证工作树游标
  的每页上限、显式重试、重复提交、无进展、取消/切换和状态扫描并发。
- `GitWorktreeAppearanceTests` 另验证更改页的原生选择、复选框、快捷键、右键
  批量目标、禁用状态、共享工具栏和深浅窄宽布局，以及路径整行自适应与行内展开；
  `GitModuleTests` 覆盖根目录隔离、部分暂存、过期目标拒绝、首错停止、扫描失败
  保留、Diff 刷新/关闭、历史保留和取消/重置后迟到错误不发布。
- `DebugModuleTests` 另覆盖上下两个方向的缩页、单条邻居失败后的边缘验证、
  无效补位指令、真实错误保留和验证期间失效；本机 `lldb-dap` 21 的独立 C
  程序实验复现映像首地址的负偏移失败及零偏移成功，不代替完整工作台验收。

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


- `./scripts/macos/build/build-macos.sh`
- `./scripts/git-graph/verify-git-graph.sh`
- `./scripts/architecture/verify-service-boundaries.sh`
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
- `macos/Sources/Lithe/Views/Git/GitWorktreesView.swift`
- `macos/Sources/Lithe/Views/Git/GitWorktreeRowsView.swift`
- `macos/Sources/Lithe/Views/Workbench/WorkbenchToolWindowDock.swift`
- `macos/Sources/Lithe/Views/Workbench/SplitHandleView.swift`
- `macos/Sources/Lithe/Views/Components/LitheSplitPaneView.swift`
- `macos/Tests/LitheTests/GitLogReferenceResizeTests.swift`
- `macos/Tests/LitheTests/SplitHandleHitTestTests.swift`
- `macos/Tests/LitheTests/DiffScrollSynchronizationTests.swift`
- `macos/Tests/LitheTests/GitWorktreeAppearanceTests.swift`
- `macos/Sources/Lithe/Views/Git/GitCommitFileTreeView.swift`
- `macos/Tests/LitheTests/GitCommitFileTreeLayoutTests.swift`
- `rust/lithe-core/src/git/history.rs`
- `macos/Sources/Lithe/Core/Rust/RustGitOperations.swift`
- `macos/Tests/LitheGitModuleTests/Fixtures/GitGraphIDEA/`
- `macos/Tests/LitheTests/Fixtures/GitGraph/`
- `macos/Resources/GitGraph/`
