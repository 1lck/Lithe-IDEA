# Agent 笔记：双端统一的 Git 提交图布局与分支颜色

状态：已实现

关联：Windows 侧对齐 macOS 的 IDEA 风格图着色，见
[`2026-09-13-macos-git-graph-intellij-layout.md`](2026-09-13-macos-git-graph-intellij-layout.md)。

## 先说结论

macOS 和 Windows 的 Git 提交图现在使用同一套 IntelliJ 风格的永久图规则：先按引用优先级确定图头，再为每个图头分配稳定的图片段和颜色，最后根据提交顺序投影到屏幕泳道。这样本地分支新增提交时，不会因为沿用父分支的第一条泳道而和父分支混成同一种颜色；两个端的分支优先级、颜色身份和合并拓扑也保持一致。

Windows 使用 SVG 行渲染，图头排序、永久布局、紧凑长边及绘制尺寸与 macOS 的 IntelliJ 基准一致。颜色使用完整有符号身份生成明暗主题 RGB，节点为实心、连线为直线，尺寸按字号和显示器缩放调整。今后修改提交图时，必须同时以 macOS 的实现和 IntelliJ 固定基准为准，不要重新引入泳道着色或六色取模。

Windows 的日志筛选也基于完整已加载历史生成可见图。隐藏中间提交后，用虚线连接仍可见的祖先，而不是直接删除已绘制的行；清空筛选恢复原图。

Windows 历史请求与 macOS 一样使用日期顺序，并在可见分页之外加载有界仓库上下文，保留跨分支的永久颜色身份。长边可以展开或收起，箭头只导航到已加载且可见的父／子提交，选择、Diff 预览和滚动继续使用现有入口。

## 问题

Windows 原先只在当前提交页上维护泳道槽位。第一父提交会直接继承当前泳道颜色，因此本地分支的提交和父分支的提交在分叉关系中可能继续使用同一个颜色。泳道编号还会随着合并顺序和页面数据变化，导致同一分支在不同历史窗口中的颜色或位置不稳定。

macOS 已经按 IntelliJ 的永久图规则处理了这个问题，但 Windows 仍是独立的槽位算法，导致同一仓库在两个端展示不同。

## 决策

- **统一图头排序**：按 `origin/main`/`origin/master`、其他远程分支、本地 `main`/`master`、其他本地分支、tag、HEAD 的优先级排序；同类引用使用 IntelliJ 自然名称排序。`refs/heads/`、`refs/remotes/` 和 `refs/tags/` 在解析时先还原为展示名。
- **统一永久布局**：仓库上下文完整覆盖当前分支页时，先在上下文上按有序图头做非递归 DFS，生成与屏幕列无关的 layout index，再投影当前分支。上下文不完整或有重复哈希时回退到当前快照；已被更高优先级父分支占用的父提交保留父分支片段，新增本地图头从新的片段开始。
- **统一颜色身份**：图头主片段使用主引用名的完整 Java `String.hashCode`；其他 DFS 片段使用 layout index。边使用两端 layout index 较大者所属片段的颜色，避免本地提交沿用父分支颜色。`colorIndex` 字段保存有符号颜色 ID，不是调色板槽位；不得取模或取绝对值后传给绘制层。
- **统一紧凑投影**：Windows 使用与 macOS compact 模式相同的 30 行长边阈值和 1 行端点保留规则。屏幕泳道只负责排版，不能再决定颜色身份。
- **保持平台边界**：Rust Git 历史接口、JSON 契约和 macOS 的 native graph renderer 不变；Windows 只在自身布局投影层复用相同算法语义，并继续使用现有 SVG 组件绘制。

### 筛选后的祖先连接

筛选先保留完整已加载历史的永久布局，再计算哪些提交可见。Windows
`git-graph-filter-projection.ts` 移植 macOS `GitGraphProjection.dottedEdges`
的双向最近可见节点遍历规则，算法来源仍是上文关联 Note 固定的 Community
`36415d346b3d18a6ded90d05afb8e0a0bface9d6` 的 `DottedFilterEdgesGenerator`。
本次另核对本地 Community `fb72b4df43aba102479eb0502d20b03586b9c5b8`
的同名文件；不会按相邻显示行猜测父子关系，也不会在每次搜索时重新分配分支颜色。

例如 `A → B → C` 中隐藏 B，显示的是 `A ⇢ C` 的虚线；A、C 的提交对象及
原始父哈希仍保留 Git 返回值。直接父子关系继续使用实线；两条路径到达同一
可见祖先时去重，直接关系优先。无关分支不会因为显示行相邻而连接。

未加载父提交通过 macOS `GitGraphMissingParents` 相同的隐藏边界分组规则
传播，多个合并路径共用边界组，避免给每条隐藏提交复制全部祖先哈希集合。
传播遇到可见祖先就停止，由该祖先持有后续连接；分页加载父提交后重新投影，
不再标记该父提交缺失。隐藏的已加载根提交不属于缺失历史。

筛选结果和未筛选图统一通过 `printElements`（逐行绘制的上下半边）保留边的
身份、虚线样式与颜色。相邻两行在共同边界中点衔接，经过其他可见提交的
虚线不能被画成实线；清空筛选恢复完整图，继续使用同一绘制入口。

### 未筛选图的跨行与合流绘制

Windows 不再根据泳道颜色数组推断进入提交的连线。移植 macOS 和 IDEA
`PrintElementGeneratorImpl` 的上下半边规则后，每条边独立保存当前列、相邻
行的列和颜色；两半在共同边界中点衔接。经过中间行的边发生列号变化时必须
绘制斜向连接，多个分支汇入同一提交时必须保留各自颜色到圆点中心，不能在
行边界提前使用节点颜色。

长边和缺失历史同样沿用上游的打印元素终止规则：紧凑长边保留两端一行，
缺失父提交的终止元素放在下一行，不在最后一个可见节点下伪造一段线。
打印元素保留终止及方向标记属性，供绘制模型使用。SVG 按 macOS 的坐标规则
绘制实心点、直线、筛选虚线及紧凑长边方向箭头。
上述图形和打印元素继续作为长边展开及端点导航的同一入口；不改变筛选字段。

SVG 的宽度同时计入斜向边的边界中点，避免相邻行列数增多时连线覆盖提交
标题。`incomingLaneColors` 仅保留为结构诊断摘要，渲染器不得再读取它推断
边的几何或颜色。这样普通浏览与筛选浏览共用同一模型，修复不会在两条
绘制路径中各维护一份。

### 日期顺序与仓库上下文

Windows `getGitHistoryPage` 在首批、分页、回退及仓库上下文请求中都传
`order: "date"`，与 macOS `RustGitOperations.historyPage` 一致。Core 继续
使用既有 `git log --date-order`，游标始终绑定仓库、引用和顺序，不能只修改
首批请求，也不能在 UI 按展示的作者时间重新排序提交。

`use-git-log-controller.ts` 独立加载最多 5,000 条全部引用的上下文，不与
50 条可见页共用游标。可见页不等待上下文完成；分页不取消上下文读取，也
不重复加载它。切仓库、刷新或重选引用时取消旧上下文操作，并用独立代次
拒绝迟到结果；所有上下文游标，包括卸载后迟到的游标，读取后立即关闭。
失败时保留可浏览的当前页，按 API 既有诊断规则记录异常并回退到页内布局。

只有上下文哈希唯一且包含当前页全部提交时，才复用它的永久布局和基础
顺序。显示的提交对象仍使用当前页数据；隐藏分页外的节点不会凭上下文
变成已加载的父节点。例如跨分支上下文包含 main 图头时，选择 feature
仍继承 main 的优先级；如果旧页超出上下文窗口，必须显示旧页而不是丢掉
它。这里不是无限完整仓库图，不得去掉上限或在绘制期间读取 Git。

引用分类使用 `git.references` 返回的真实远端短名集合，同时保留 `origin/`
及完整 `refs/remotes/` 的兼容识别。不能把 `upstream/work` 当成本地分支，
也不能仅凭名称含 `/` 就把 `feature/orders` 当成远程引用。

### 长边开关与箭头导航

`GIT_GRAPH_DISPLAY_OPTIONS` 对照 macOS 的紧凑与展开模式：紧凑模式使用
30 行阈值和一行端部；展开模式使用 1,000 行阈值和 250 行端部，超过 30 行
的普通连线仍绘制方向箭头。展开是长连线的展示方式，不折叠提交或合并片段。
Windows 工具栏开关使用现有 Button 与图标系统，默认紧凑，保存到现有视图
偏好；选择、筛选和分页游标不因开关变化重置。

每个打印元素保存已加载可见端点的 `targetHash`；未加载父提交保持空目标。
行组件的透明原生按钮按 `arrowHitRect` 命中，保留父／子提交说明、Enter／
空格激活与无障碍标签。按钮点击和双击不传播到源行，避免误选源提交或
打开它的 Diff；目标选择仍调用表格原有 `onSelect`，沿用预览和多选边界。

屏幕外端点通过现有虚拟列表定位；焦点请求在目标行的 DOM 挂载时消费，
不靠单次动画帧猜测挂载时机，也不通过轮询等候。引用或上下文重绘可以
保留同一提交的请求；仓库、搜索或长边模式替换后丢弃旧请求，卸载清理
所有权。普通上下键、首尾、右键和双击 Diff 保持原路径。
普通上下键和首尾导航保持列表视口焦点，使键盘右键菜单在虚拟行替换后仍有
稳定所有者；只有明确的图箭头导航在目标挂载后转移到目标行焦点。

### 分页保留滚动与文件选择

沿用 macOS `GitGraphScrollView.updateNSView` 的边界：追加历史页、更新引用或
收到仓库上下文只更新数据，不再次定位已选提交。Windows 表格按提交 hash
记录已经消费的选择；定位分支头使用独立导航代次，即使分支头已经选中，也
能主动定位一次。箭头和键盘仍通过现有入口定位、选择并聚焦目标。

Commit Files 的读取身份由仓库和实际比较内容组成：单提交使用 hash，连续
范围使用两端引用，离散多选使用有序 hash 集合。分页产生新数组或刷新提交
元数据时不清空文件树，不重复请求，也不丢失文件选择和折叠状态。读取身份
变化才启动新请求；旧仓库或旧选择的迟到结果仍通过代次丢弃。显式选择的
首次文件预览继续消费当前选择，不能打开旧仓库的文件。

例如选中第一个提交后浏览第 50 条并触发分页，应保留当前滚动位置及右侧
已选文件。不能在图谱行数组每次变化时调用滚动定位，也不能用选择数组的
对象身份决定文件是否重新读取；这两个做法会让正常分页跳回顶部并闪烁文件树。

### 明暗主题与物理像素尺寸

颜色入口 `git-graph-colors.ts` 移植 Community `DefaultColorGenerator`，保留
Java 32 位溢出及单精度浮点舍入，避免负数 ID 或明暗主题下 RGB 偏移。ID 0
沿用主题正文色；其他 ID 按上游色相、0.6 饱和度及浅色 0.7/深色 0.6 亮度
生成颜色。主题切换使用产品 ThemeRegistry 的根 `data-theme-type` 标记，
同时兼容已有 `.dark` 容器；CSS 更新颜色，不重新计算布局。

绘制入口 `git-graph-geometry.ts` 对照 macOS `GitGraphGeometry` 和 Community
`c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的 `PaintParameters`、
`SimpleGraphCellPainter` 及 `PaintUtil`。默认行高 26px，按用户字体的上升、
下降和行间距加 7px 扩高；图形按上游 22px 基准成比例缩放。线宽、圆点直径
和列距采用向下取整及奇数物理像素规则，包括 Windows 的分数缩放。标题使用
下述可见图建议宽度，复杂行单独扩宽。去掉逐行分隔线及水平额外内边距，
避免行盒与图形坐标偏移。

### 图形与提交文字按行混排

Windows 不再把六列当作标题的最小固定留白。对照 Community
`fb72b4df43aba102479eb0502d20b03586b9c5b8` 的 `PrintElementGeneratorImpl.calculateRecommendedWidth`
和 `GraphCommitCellUtil.getGraphWidth`，先按可见图边数计算加权均值加标准差，
最多采样前 20,000 行，头部权重大于尾部，末端权重比例为 0.1。
这份建议宽度作为统一基线，基线最多六列；具体每行取节点、连线当前位置、
相邻行连线中点三者的最右占用，超过基线时只扩宽该行。

例如绝大部分提交是一条直线，但中间一次合并同时占用八列，简单行的文字
仍从较小基线开始，合并附近的文字跟随当前行右移，之后恢复。
不能把整个历史的最大列数传给所有行，也不能在行绘制时按截图猜一个更小
固定值；这两种做法都无法随筛选和长边模式反映当前可见图。

建议宽度在 `layoutGitGraph` 内使用边区间的差分计数（只记录区间开始和结束）
计算，避免逐行扫描全部活跃连线；渲染接收计算结果，不查询 Git，也不注册
逐行测量。标题偏移按 IDEA 分别取整图宽及图文间隙，再加入已有 2px 文字
内边距，引用标签的可用宽度使用同一行偏移。
macOS 原有六列标题留白保持，这次用户要求仅调整 Windows；双方的永久布局、
颜色身份和打印元素不因此分叉。

只有表格视口的 `use-git-graph-paint.ts` 监听字体加载与 DPI；行组件接收不可变
绘制参数，不注册逐行监听。字体变化重新测量虚拟列表行高，DPI 变化只更新
绘制参数；普通窗口调整不重建历史图。沿用用户设置的 Windows UI 字体和字号，
不为 Git Log 强制替换字体。例如 13px 默认字号仍使用 26px 行高，24px 字号
至少使用 31px 行高；不能只放大 SVG 而继续以旧行高虚拟滚动。

### 提交行高亮与引用分组

Windows 提交行对照 macOS `GitGraphView`、`GitGraphColor` 和 Community
`CurrentBranchHighlighter` / `MergeCommitsHighlighter`：浏览全部引用或其他
分支时，沿当前检出分支的所有父提交识别历史范围；只查看当前分支或 HEAD
时不重复高亮。合并提交的说明、作者、日期在未选中时使用弱化文字，选中
后恢复正常文字；选择背景优先于当前分支背景，并区分列表内焦点、文件树
焦点和窗口失焦。窗口活动标记只写入列表 DOM，不重建图或修改选择。

引用展示对照 macOS `GitGraphReferenceGroup` 与 Community `GitRefManager`、
`LabelPainter`、`LabelIcon`、`TagPainter`。在说明右侧显示一个紧凑组，优先
按真实 upstream 元数据合并本地／远程名称，同名回退保持 macOS 规则；附着
HEAD 使用叠加图标，游离 HEAD 明确显示。每种引用最多绘制两个图标，完整
名称保留在悬停和无障碍提示中。宽度不足时按上游规则缩略，至少保留 22 个
字符后由列裁剪；只有标签的组保留图标与完整提示，不凭空显示一个分支名。

分组与当前分支范围按数据变化准备；只有表格视口测量字体和剩余列宽，单个
ResizeObserver（浏览器按帧合并的尺寸观察器）服务已挂载行，列拖动期间不
逐行读取尺寸，结束后按持久化列宽刷新文字度量。字体完成与卸载有明确
所有者，避免每行注册监听。正确做法是把 `main` 与它跟踪的 `upstream/release`
显示为 `upstream & main`，但提示仍包含两个原始引用；不要只按名称含斜杠
猜远程身份，也不要让显示分组修改 Git 引用或触发 Commit Files 重读。

## 考虑过的备选方案

- **只修复 Windows 的第一父颜色继承**：改动小，但无法解决合并顺序、分页和两个端布局规则不一致的问题，因此没有采用。
- **继续按泳道序号轮换颜色**：实现简单，但泳道是屏幕布局结果，不是分支身份，历史窗口变化后颜色仍会跳变，因此没有采用。
- **按提交 hash 取模**：可以让颜色看起来稳定，但相邻的无关提交可能碰巧同色，也无法体现父分支和本地分支的关系，因此没有采用。
- **将算法下沉到 Rust Core**：当前 macOS 还需要 native graph 的打印元素与可见投影，而 Windows 使用不同的渲染模型；本次只统一算法语义，避免把平台绘制模型错误地塞入跨平台 Core。
- **删除不匹配行后沿用原图**：跨行连线仍指向旧显示位置，隐藏祖先也无法标记为虚线，因此不采用。只对匹配提交重新建图同样会丢掉隐藏祖先及永久颜色身份。
- **只为筛选图维护上下半边**：普通浏览仍会在换列时断开，在合流时提前换色；两套绘制路径容易漂移。因此未筛选图也消费同一打印元素，删除旧泳道推断绘制。
- **保留六色槽并只替换六个 RGB**：完整颜色身份仍被合并，无法通过真实 IDEA 颜色对照，因此不采用。
- **按每一行监听缩放或重新建图**：增加大量监听和高频布局工作；由表格视口集中测量，纯坐标层负责绘制。
- **在 UI 对分页提交按日期重新排序**：无法保证父子顺序，也会破坏游标，改用 Core 现有日期顺序。
- **让上下文和可见页共用取消代次或游标**：分页会取消背景读取，迟到游标易泄漏，因此两个请求由各自所有者管理。
- **单帧后直接聚焦箭头目标**：真实虚拟列表可能在该帧之后才挂载端点；改为由目标 DOM 提交消费焦点请求。
- **只删除所有自动定位或在父级缓存选择数组**：前者会破坏分支头定位，后者不能防止相同 hash 的元数据刷新重读文件；改为分别维护明确导航请求和实际文件比较身份。
- **在每一行监听宽度或把引用重新画成独立彩色胶囊**：前者扩大高频尺寸监听和准备成本，后者不符合 macOS 的紧凑引用组；改为共享视口度量与原始 TagPainter 图标几何。

## 后果

- Windows 本地分支在父分支之上新增提交时，提交节点和连接线可以与父分支清楚区分，解决 Issue #902 的主要体验问题。
- 两端的图头优先级、自然名称排序、永久片段颜色和紧凑长边处理一致；同一历史在两个端不会再因为使用不同的槽位算法而出现明显分叉差异。
- 两端明暗主题的颜色生成规则一致，完整身份不再因六色取模丢失；上游色相算法本身仍可能让不同身份生成相同 RGB。
- 图形尺寸和跨行端点随真实显示器缩放对齐；字体加载与跨屏 DPI 变化需在目标 WebView2 中验收。SVG 与 AppKit 的抗锯齿由各自渲染器负责，不能仅凭单元测试声称像素截图完全相同。
- Windows 与 macOS 共用有界仓库上下文规则；完整覆盖时分支页复用仓库颜色和基础顺序，窗口外仍回退到当前快照。额外上下文请求有读取成本，但不会阻塞首批可见行。
- 筛选图和未筛选图共用当前快照的永久布局；搜索变化会重新生成可见图，最多处理当前 5,000 条已加载提交。未加载历史的真实关系不能凭筛选结果推断。

## 验证

- `git-graph-reference-group.test.ts` 直接采用 macOS `GitGraphInteractionTests.referenceGroups` 的独立期望，覆盖 upstream 跟踪、游离 HEAD、只有标签、自然排序和长名缩略；`git-graph-highlights.test.ts` 覆盖合并双亲、上下文、缺失身份、重复及循环边界。
- `git-commit-table.presentation.test.tsx` 渲染实际表格，验证明暗背景和三个合并文字列、标签完整提示、点击选择与焦点、单一视口观察器、宽窄缩略和卸载清理；结合浏览器中的实际 ThemeRegistry、键盘及 Commit Files 焦点验证选择颜色和主题动态切换。分页回归和长边导航仍通过原入口。

- 既有 macOS 对照基准：`./scripts/verify-git-graph.sh`
- Windows 前端：`tsc --noEmit`；`bun test src/features/git`
- Windows 筛选回归计时：`./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope Frontend -FrontendTestPath src/features/git/utils/git-graph-layout.test.ts,src/features/git/components/log/git-graph-row.test.ts,src/features/git/components/log/git-commit-table.filter.test.tsx`。覆盖隐藏链、合并与直接边优先、缺失父节点传播和分页、5,000 条隐藏边界，以及真实提交表筛选/清空后的 SVG 虚线。
- 未筛选图读取 `macos/Tests/LitheTests/Fixtures/GitGraph/issue410-history.tsv` 与真实 IDEA 生成的 `issue410-idea.txt`，比较 200 条提交的节点列、上下半边位置、终止及方向标记和完整有符号颜色 ID，不从 Windows 算法生成预期。SVG 回归验证换列边界实际坐标和合流两条入边的独立颜色。
- 外观对照读取真实上游 `idea-theme-colors.txt`，覆盖明暗主题、负数及溢出颜色；几何回归覆盖 1x/1.25x/1.5x/2x/3x 的上下半边端点、奇数物理像素、终止留白和方向箭头。`use-git-graph-paint.test.tsx` 验证 DPI/字号变化后的实际 SVG、普通调整不重复监听、卸载清理及历史布局不重建。
- 外观回归计时使用同一 Windows Frontend harness，加入 `src/features/git/utils/git-graph-colors.test.ts`、`src/features/git/utils/git-graph-geometry.test.ts` 和 `src/features/git/hooks/use-git-graph-paint.test.tsx`。浏览器验证使用真实行组件和测量 hook，检查明暗主题、五种 DPI 和用户字号；平台调用在独立页面中替代，不视为原生产品验收。
- 仓库上下文读取现有 `issue410-context-idea.txt` 和 `issue410-date-idea.txt`，比较真实 IDEA 的 200 条拓扑页与 300 条日期页，不用 Windows 输出生成预期。API 测试复用 `shared/fixtures/git/history-page-date-request-v1.json`，确认首批与后续页都传相同顺序。
- 上述两份 IDEA 输出的 `Width` 也参与建议宽度回归；几何与真实行组件检查单线、建议基线六列上限、斜边中点、超过六列的密集行与后续简单行、筛选重算和标签呈现。浏览器用真实表格与虚拟滚动核对文字按行避让图形；目标 WebView2 设备验收仍单独记录。
- `use-git-log-controller.integration.test.tsx` 通过可控异步事件验证首批不等待上下文、切仓库和刷新取消、分页独立、卸载与迟到游标清理以及失败回退；`git-commit-table.navigation.test.tsx` 验证真实行与工具栏、屏幕外双向导航、延迟挂载、选择/焦点及普通 Diff。浏览器再用真实虚拟列表和原生 Enter／空格检查同一序列，不把 viewport mock 当作原生内核证明。
- 原生验收：在包含交错分支和合并的 Windows Git Log 中，分别使用文本、作者、分支名称筛选，确认跨过隐藏提交的连接为虚线，直接父子为实线，无关分支不误连，清空筛选恢复原图和选择行为。
- 分页回归：`git-commit-table.navigation.test.tsx` 验证手动滚动后追加页面不定位旧选择，分支头请求仍能定位已选提交一次；`git-commit-inspector.test.tsx` 验证加载中和已加载选择的重绘、单提交/连续范围/离散多选、文件节点与选择保留、显式预览及切仓库的迟到结果。浏览器使用实际表格、IntersectionObserver、虚拟列表和 Inspector，连续由 50 条加载到 150 条，检查滚动偏移与文件读取次数；平台返回值在隔离页面替代，WebView2 实机验收仍 pending。
- 代码边界和运行时资源：`./scripts/verify-service-boundaries.sh`、`./scripts/verify-runtime-bundle-immutability.sh`

## 适用范围

- `windows/tauri/src/features/git/utils/git-graph-layout.ts`
- `windows/tauri/src/features/git/utils/git-graph-colors.ts`
- `windows/tauri/src/features/git/utils/git-graph-geometry.ts`
- `windows/tauri/src/features/git/hooks/use-git-graph-paint.ts`
- `windows/tauri/src/features/git/hooks/use-git-log-controller.ts`
- `windows/tauri/src/features/git/api/git-commits-api.ts`
- `windows/tauri/src/features/git/stores/git-log-preferences.store.ts`
- `windows/tauri/src/features/git/utils/git-graph-filter-projection.ts`
- `windows/tauri/src/features/git/components/log/git-commit-table.tsx`
- `windows/tauri/src/features/git/components/log/git-commit-inspector.tsx`
- `windows/tauri/src/features/git/components/log/git-log-tool-window.tsx`
- `windows/tauri/src/features/git/components/log/git-graph-reference-label.tsx`
- `windows/tauri/src/features/git/utils/git-graph-reference-group.ts`
- `windows/tauri/src/features/git/utils/git-graph-highlights.ts`
- `windows/tauri/src/features/git/hooks/use-git-graph-reference-metrics.ts`
- `windows/tauri/src/features/git/components/log/git-graph-row.tsx`
- `windows/tauri/src/features/git/components/log/git-graph.css`
- `macos/Sources/LitheGitModule/Services/GitGraphHeadOrdering.swift`
- `macos/Sources/LitheGitModule/Services/GitGraphProjection.swift`
- `macos/Tests/LitheGitModuleTests/Fixtures/GitGraphIDEA/`
