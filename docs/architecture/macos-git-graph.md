# macOS Git 提交图：IntelliJ 布局与长边导航

关联需求：[Issue #410](https://github.com/1lck/Lithe-IDEA/issues/410)。

本次改变 macOS 产品行为。算法落在现有 `LitheGitModule`，AppKit/SwiftUI 负责绘制与交互。Rust `git.historyPage` 增加向后兼容的可选排序参数，由 macOS 显式请求日期排序；Windows 代码与原有调用默认行为不变。以后迁移共享图实现时，以本文件和 macOS 的算法回归用例为依据。

## 对齐基准与范围

算法基准固定为 JetBrains/intellij-community 提交
`36415d346b3d18a6ded90d05afb8e0a0bface9d6`，不以随时变化的 master 或截图的颜色作为规范：

- [GraphLayoutBuilder.kt](https://github.com/JetBrains/intellij-community/blob/36415d346b3d18a6ded90d05afb8e0a0bface9d6/platform/vcs-log/graph/src/com/intellij/vcs/log/graph/impl/permanent/GraphLayoutBuilder.kt)：从有序图头开始 DFS，给连续分支分配 layout index。
- [GraphElementComparatorByLayoutIndex.java](https://github.com/JetBrains/intellij-community/blob/36415d346b3d18a6ded90d05afb8e0a0bface9d6/platform/vcs-log/graph/src/com/intellij/vcs/log/graph/impl/print/GraphElementComparatorByLayoutIndex.java)：节点与经过本行的边的相对排序。
- [PrintElementGeneratorImpl.kt](https://github.com/JetBrains/intellij-community/blob/36415d346b3d18a6ded90d05afb8e0a0bface9d6/platform/vcs-log/graph/src/com/intellij/vcs/log/graph/impl/print/PrintElementGeneratorImpl.kt)：逐行紧凑定位、相邻行路由、长边裁减与箭头阈值。
- [DottedFilterEdgesGenerator.kt](https://github.com/JetBrains/intellij-community/blob/36415d346b3d18a6ded90d05afb8e0a0bface9d6/platform/vcs-log/graph/src/com/intellij/vcs/log/graph/collapsing/DottedFilterEdgesGenerator.kt)：双向遍历，在筛选隐藏的提交之间补可见虚线。
- [GitRefManager.kt](https://github.com/JetBrains/intellij-community/blob/36415d346b3d18a6ded90d05afb8e0a0bface9d6/plugins/git4idea/backend/src/log/GitRefManager.kt) 的 `GitBranchLayoutComparator`、[HeadCommitsComparator.java](https://github.com/JetBrains/intellij-community/blob/36415d346b3d18a6ded90d05afb8e0a0bface9d6/platform/vcs-log/impl/src/com/intellij/vcs/log/graph/HeadCommitsComparator.java) 与 [NaturalComparator.java](https://github.com/JetBrains/intellij-community/blob/36415d346b3d18a6ded90d05afb8e0a0bface9d6/platform/util/base/src/com/intellij/openapi/util/text/NaturalComparator.java)：图头的引用优先级和自然名称排序。
- [GraphColorManagerImpl.kt](https://github.com/JetBrains/intellij-community/blob/36415d346b3d18a6ded90d05afb8e0a0bface9d6/platform/vcs-log/impl/src/com/intellij/vcs/log/graph/GraphColorManagerImpl.kt)、[GraphColorGetterByHead.kt](https://github.com/JetBrains/intellij-community/blob/36415d346b3d18a6ded90d05afb8e0a0bface9d6/platform/vcs-log/graph/src/com/intellij/vcs/log/graph/impl/print/GraphColorGetterByHead.kt) 和 [DefaultColorGenerator.kt](https://github.com/JetBrains/intellij-community/blob/36415d346b3d18a6ded90d05afb8e0a0bface9d6/platform/vcs-log/impl/src/com/intellij/vcs/log/graph/DefaultColorGenerator.kt)：图头/分支片段的颜色 ID 和 HSB 配色。
- [GitLogProvider.kt](https://github.com/JetBrains/intellij-community/blob/36415d346b3d18a6ded90d05afb8e0a0bface9d6/plugins/git4idea/backend/src/log/GitLogProvider.kt)：仓库完整历史读取使用 `--date-order`。
- [MergeCommitsHighlighter.java](https://github.com/JetBrains/intellij-community/blob/36415d346b3d18a6ded90d05afb8e0a0bface9d6/platform/vcs-log/impl/src/com/intellij/vcs/log/ui/highlighters/MergeCommitsHighlighter.java)：合并提交采用主题弱化前景色，选中时恢复普通前景色。
- [PaintParameters.java](https://github.com/JetBrains/intellij-community/blob/36415d346b3d18a6ded90d05afb8e0a0bface9d6/platform/vcs-log/impl/src/com/intellij/vcs/log/paint/PaintParameters.java)：行高、列距、节点直径和线宽。
- [GraphCommitCellUtil.kt](https://github.com/JetBrains/intellij-community/blob/36415d346b3d18a6ded90d05afb8e0a0bface9d6/platform/vcs-log/impl/src/com/intellij/vcs/log/ui/render/GraphCommitCellUtil.kt)：按每行打印元素及相邻列中点计算文字起点。
- [产品行为说明](https://www.jetbrains.com/help/idea/log-tab.html)：Long Edges 默认关闭，箭头导航到连线另一端。

这里的“同样算法”指上述布局、图头优先级、比较、可见图、打印元素与默认配色规则在相同输入上的一致性。先在仓库所有引用的有界历史上建立永久图，再投影所选分支及其已加载页面；提交显示顺序沿用这个仓库图的顺序，不能为每个分支单独重排并重新分配 layout index。底层使用 `git log --date-order`，对应 IDEA 当前“按提交日期”的 Normal 模式，排序依据是 committer date，不能使用界面展示的 author date 做简单排序。BEK 是另外的模式，本次不启用。比较时须统一提交集合、引用、筛选条件和 Long Edges 设置。

长边收束隐藏的是两个提交之间经过很多行的边，不删除中间行的其他提交；“折叠一整段线性提交”属于另一种功能，本次不启用。

## 原理

### 1. 完整提交图和稳定的分支顺序

输入分为仓库图与可见历史页。macOS 通过 Rust `historyPage` 接口并行取得最多 5,000 条所有引用历史和当前分支的一页历史，两者均显式传 `order: "date"`，后续页沿用该参数。排序必须从 Git 遍历开始保持一致，不能只在 UI 内排序当前页。Core 将 cursor 与 root、reference、order 绑定，错误的续页排序不会消费游标。未提供参数的客户端及旧 `history` 接口继续使用 `--topo-order`。仓库图决定永久 layout index、颜色和基础顺序；可见页决定显示哪些提交、哪些父提交尚未加载。两者均保持子在父之前，父数组保持 Git 原顺序。建立 hash → 行号、父子邻接表，去重重复父边，页外父提交单独保留。

当前页和引用快照就绪后立即显示日志、结束首屏加载状态，并允许继续分页；不等待 5,000 条仓库上下文返回。上下文就绪后仅更新仓库图，触发现有后台投影，不替换可见页或选择。上下文未完成时使用当前页的独立图，完成后可能调整顺序、列位和颜色。

仓库上下文请求参与既有 operation ID 取消和 generation 检查，返回的上下文 cursor 立即关闭，包括取消后迟到的响应，避免额外 Git 进程常驻。刷新开始时清除旧上下文；失败、重复 hash 或未覆盖当前页全部提交时，以当前页的独立图回退，不能混合不兼容的 layout index 或丢失行。分页复用同一仓库图；仓库刷新和分支范围切换重新获取。当前引用快照没有引用目标哈希，不能仅按引用名称缓存仓库历史，否则同名分支前进后可能复用过期图。

图头集合是没有子节点的提交，加上所有分支引用和 HEAD 指向的提交；只有 tag 的内部节点不单独成为图头。每个图头选择最优先的引用，按 `origin/main`、`origin/master` → 其他远程分支 → 本地 `main`、`master` → 其他本地分支 → tag → HEAD 排序；同类引用使用 IDEA 的自然名称比较，包括数字段、前导零和大小写平局处理。无引用图头最后按输入行号排序。远程名称通过引用快照识别，支持非 `origin` 远程。Lithe 目前只展示单个仓库，因此无需 IDEA 的跨仓库 root 平局规则。

按照有序图头执行非递归 DFS。首次访问节点时写入当前 layout index；沿第一个尚未访问的父节点继续，走到没有未访问父节点的节点时递增 index，再回溯处理其他父节点。这是分支的相对顺序，不是屏幕列号，也不能用屏幕列号决定颜色。

主片段采用该图头最优先引用名称的 Java `String.hashCode`（UTF-16、有符号 32 位溢出）；其他 DFS 片段以 layout index 为颜色 ID，无引用主片段使用主题前景色。边采用两端 layout index 较大者所属片段的颜色。ID 经 IDEA 的整数 RGB 映射得到 hue，再应用 IDEA expUI / Islands 主题覆盖值：saturation=0.6，浅色 brightness=0.7，深色 brightness=0.6。`DefaultColorGenerator` 的 0.4/0.65 只是未配置主题时的后备值，不能用它代表当前 IDEA 外观。主题切换时清除原生图的颜色缓存。禁止把提交 hash 对少量固定颜色取模，这会让互不相关的相邻分支碰巧同色。

### 2. 筛选生成可见图

作者、关键词、日期和路径筛选只决定哪些节点可见。布局顺序来自完整图，不能先删掉提交再把被删父节点判为“未加载”。

保留两端都可见的直接边。沿完整图执行向下和向上的编号传播，按 IDEA 的最近可见节点规则补虚线，并对重复端点去重。虚线表示经过被隐藏的提交，实线表示直接父子边。页外父提交使用独立的未加载标记；可见节点经过隐藏祖先抵达页外父节点时保留虚线延续与未加载提示。多个隐藏路径到同一父节点时去重，同一端点已有直接边则保留实线。已加载的根节点及与可见图无关的隐藏分支不会产生缺页误报；补页后重新投影，已补齐的未加载标记随之消失。

缺页传播使用共享的隐藏边界 DAG：反向遍历已加载节点，每个组只保存本节点直接缺失的父哈希与父组 ID，不复制所有祖先的累计哈希集合。无直接缺页的单父路径复用父组，相同组也复用 ID；可见祖先不向子节点传播其边界，由它自己的出边表达延续。随后按可见提交遍历关联组，使用访问戳去重，临时哈希集合只保存该提交的输出，避免每个隐藏节点都保留一份累计结果。辅助图存储随输入节点和边增长；遍历成本还取决于各可见提交可达的组数，输出边本身可能很多，不能承诺所有输入都线性耗时。建组、遍历和输出均检查取消，过期投影由布局入口丢弃。

### 3. 逐行紧凑布局

每行收集本行节点、仍需显示的跨行边和箭头端点。使用 IDEA 的 comparator 排序，再以 `0..<count` 紧凑编号，不保留空槽。

普通边与节点比较时，先比较边两端 layout index 的最大值与节点的 layout index；相同时以边上端行号打破平局。两条边按上端位置、共同上端和下端位置归约到边与节点比较。这样分支的相对次序保持一致，同时结束或被省略的边及时释放宽度。

每个打印元素明确包含本行中心列、相邻行中心列、上/下方向、实/虚线、箭头和导航目标。相邻两行在公共边界采用两列的中点，因此列号变化也能连续连接。禁止压紧旧槽位后继续把贯穿边画成固定 x 的竖线。

文字起点按本行节点、边中心列和跨行斜线的边界中点共同决定，不用全图最大列数给每一行留白。推荐宽度沿用 IDEA 的前 20,000 行采样、权重从 1 降到 0.1 的加权均值加标准差；每行至少保留该推荐值与 6 列的较小值。实现通过边的区间差分计算每行计数，避免逐行扫描所有长边。

### 4. 详略关系与箭头

与固定版本 IDEA 使用同一组行数阈值：

| 模式 | 省略阈值 | 每个端点保留范围 | 额外箭头 |
| --- | --- | --- | --- |
| 默认紧凑 | 边跨度 ≥ 30 行 | 距端点 ≤ 1 行 | 省略边的两端 |
| 显示长边 | 边跨度 ≥ 1,000 行 | 距端点 ≤ 250 行 | 跨度 ≥ 30 行时，端点附近仍有方向箭头 |

“跨度”使用可见图的行号之差。省略边在中间行不占列；下箭头指向父提交，上箭头指向子提交。点击已有可见目标时选择目标、滚动定位并刷新详情，不改变多选修订操作的执行规则。箭头有独立的命中区域、提示文字和可访问按钮；命中区域水平对准实际绘制的箭头尖端，支持展开模式跨多列的斜边。主日志的 SwiftUI 行按钮保留提示、指针和可访问操作，鼠标左键由现有的单个 AppKit 绘图表面跨行命中；恰好落在行边界的尖端同时检查相邻行，避免 SwiftUI 行内按钮的边界漏点。绘图表面只接管箭头的普通左键事件，其余图形区域、悬停、右键和 Control 点击仍走行的原有事件路径。原生列表复用同一套坐标和目标解析。

页外父节点不能伪装为已有行；保留明确的未加载提示和现有 Load more 入口。补页后按新图重新投影，补齐端点。不能为了跳转把一个旧提交插在日志顶部破坏拓扑顺序。

### 5. 渲染与性能

几何使用 IDEA 原生比例：22 pt 行高、16 pt 列距、8 pt 节点直径、1.5 pt 线宽、2 pt 图文间隔。箭头按行高同比缩放；上下命中区域各占半行，不相互覆盖。普通合并节点使用实心圆，不再额外放大并添加白色内圈。

普通提交使用主要文字色；有两个及以上父节点的合并提交标题使用 IDEA `VersionControl.Log.Commit.unmatchedForeground`（浅色 `#818594`、深色 `#6F737A`），选中行恢复普通前景色。以父节点数量判断合并，而不是依赖标题是否以 Merge 开头。

布局和筛选投影在后台执行，按历史版本、仓库图版本、引用版本、筛选结果版本与长边显示模式触发；取消或版本过期的结果不得覆盖当前图。选择、hover、滚动不重新执行 DFS 或全图投影。

继续使用现有单个 AppKit 绘图表面，只绘制 dirty rect 对应的行。SwiftUI 的行承担原有选择、上下文菜单和多选行为。箭头命中与提示使用已经生成的打印元素，不在鼠标移动时遍历 Git 历史。列表宽度由当前可见打印元素计算。键盘上下移动、Shift 范围选择及箭头导航均使用图中实际显示顺序。

仓库上下文和单个历史 cursor 目前分别最多 5,000 个提交；因此极旧分支可能超出仓库上下文覆盖范围，此时按上述规则回退。分页可能需要调整列位置和被补齐的边；应保留滚动锚点，不承诺在输入图改变时每个像素都不变。

## 实施与验收

1. 替换 macOS 的固定槽位布局，加入完整图 DFS、IDEA comparator、筛选虚线和打印元素。
2. 让图绘制器消费双端列坐标，加入长边显示开关、双向箭头及可访问跳转。
3. 将投影缓存移出 `body`，将筛选版本纳入更新键，保护选择与分页行为。
4. 回归覆盖：上游布局用例、密集合并、空列回收、29/30/31 行阈值、999/1000 行阈值、双向跳转、筛选掉中间节点、页外父提交、补页、空图、重复父边和 5,000 行历史。
5. 执行测试稳定性门禁和计时测试、Git 图验证、macOS 产品构建、服务边界与 `git diff --check`。检查浅色/深色下箭头、虚线和点击目标，结束后清理测试进程。

### 实现位置

| 文件 | 职责 |
| --- | --- |
| `macos/Sources/LitheGitModule/Services/GitGraphHeadOrdering.swift` | 引用优先级、自然名称比较和图头集合 |
| `macos/Sources/LitheGitModule/Services/GitGraphProjection.swift` | 永久图 DFS、筛选虚线、逐行打印元素和推荐宽度 |
| `macos/Sources/LitheGitModule/Services/GitGraphMissingParents.swift` | 共享隐藏边界、缺页端点投影和取消检查 |
| `macos/Sources/LitheGitModule/Services/GitGraphLayoutService.swift` | macOS 布局入口、引用解析和绘制快照 |
| `macos/Sources/Lithe/Views/Git/GitGraphColor.swift` | IDEA 主题颜色生成与合并文字层次 |
| `rust/lithe-core/src/git/history.rs` | 可选日期遍历与游标排序约束 |
| `macos/Sources/Lithe/Core/Rust/RustGitOperations.swift` | macOS 日志显式请求日期顺序 |
| `macos/Sources/Lithe/Views/Git/GitGraphGeometry.swift` | 半边坐标、文字宽度和箭头命中范围 |
| `macos/Sources/Lithe/Views/Git/GitGraphView.swift` | AppKit 绘制与跨行箭头命中、SwiftUI 可访问按钮和原生列表导航 |
| `macos/Sources/Lithe/Views/Git/GitLogView.swift` | 缓存更新、长边开关、选择、详情和滚动定位 |

上游 fixture 固定保存在 `macos/Tests/LitheGitModuleTests/Fixtures/GitGraphIDEA/`。4 个布局 fixture 比较完整 layout index 向量；5 个打印 fixture 比较完整节点列、上下半边端点、箭头与实/虚线结果，只排除使用不同回调生成的颜色值。fixture 输入和输出不随 Lithe 实现生成。Apache-2.0 许可证和来源说明放在 `macos/Resources/GitGraph/`，随预览、打包和性能测量应用一起复制。

### 2026-09-11 初版验证记录

- `./scripts/build-macos.sh`：macOS 产品构建通过，包含 Rust Core 实际链接。
- `./scripts/verify-git-graph.sh`：线性历史、合并、页外父提交、引用标签、半边连续性，以及实际 Git 仓库 fixture 验证通过。
- `./scripts/verify-service-boundaries.sh`、`./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh` 和 `git diff --check`：通过。
- 更广的 Git 与上下文菜单回归使用以下计时命令，底层执行 `scripts/test-macos.sh --no-parallel`：

  ```sh
  ./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh \
    --report .artifacts/test-stability/git-issue410-regression.json \
    -- --filter 'Git|ContextMenu'
  ```

  27 个 suite 中 190 项通过、1 项既有 Rust 集成用例按条件跳过；没有失败、超时或遗留测试进程。报告：`.artifacts/test-stability/git-issue410-regression.html`，JUnit：`.artifacts/test-stability/git-issue410-regression.junit.xml`。
- 本次相关测试耗时：5,000 行布局回归 482 ms；原生图绘制采样测试 2,904 ms（多次绘制的整个测试耗时，非单帧耗时，低于 15 秒测试预算）；SwiftUI 正式列表的双向箭头事件 41 ms；原生选择与滚动定位 2 ms。
- 原生渲染器的紧凑/展开、浅色/深色四张图已生成并检查；普通测试不写图，设置 `LITHE_GIT_GRAPH_CAPTURE_DIR` 才保存截图。正式 SwiftUI 列表通过窗口鼠标事件触发箭头并验证两个目标，测试结束关闭窗口。没有将离屏窗口中未生成的辅助功能树当作 VoiceOver 验证结果。

验证环境只有 Apple Swift 6.3.3，未安装仓库规定的 Swift 6.2，因此本记录不代表 Swift 6.2 工具链验证。上述跳过项为 `worktreeCreationSendsCompleteReferenceThroughRustCore`，普通 Swift 测试未启用其所需的 Rust 集成库；本次 Git 图算法测试全部执行。

### 截图反馈后的修正

初版只在当前分支页面上建图，虽通过小型上游 fixture，却缺少仓库级主线优先级；同时保留了 30/13 的行列比例、提交 hash 取模的 7 色表和放大的合并圆环。复杂合并历史下，这些差异叠加为多条同色折线、横向迁移和过大的箭头。

修正后以仓库永久图为基础，再应用当前页/分支范围；所有显示与选择使用投影顺序。绘制尺寸和颜色改为上述 IDEA 规则。最后一行的多个未加载父节点不再在本节点上堆叠箭头，保持缺页提示及 Load more。

真实回归数据冻结在 `macos/Tests/LitheTests/Fixtures/GitGraph/`：截图时分支的 200 条提交，以及同一仓库 1,000 条所有引用上下文。只保留拓扑、公开引用和显示所需标题，不含作者个人信息。测试既比较独立页面，也比较先建仓库图后的投影，覆盖全部节点列、layout index、半边两端、长边箭头、推荐宽度和颜色 ID。RGB 样本单独覆盖正负值和 32 位溢出。

对照输出由 IntelliJ IDEA `IU-262.10315.125` 内的原始 `GraphLayoutBuilder`、`GraphElementComparatorByLayoutIndex`、`PrintElementGeneratorImpl` 及 `DefaultColorGenerator` 直接运行得到，未使用 Lithe 生成期望值。生成方法见同目录 README；它是额外的独立运行验证，之前固定到源码提交的 9 组 fixture 仍全部保留。普通测试只读取冻结文件，不依赖安装 IDEA、Java、网络或本地 Git 仓库状态。

本轮验证：

- `./scripts/build-macos.sh`、`./scripts/verify-git-graph.sh`、`./scripts/verify-service-boundaries.sh`、测试稳定性静态检查和 `git diff --check` 通过。
- `LITHE_GIT_GRAPH_CAPTURE_DIR="$PWD/.artifacts/issue410/final" ./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh --report .artifacts/test-stability/git-issue410-readability.json -- --filter 'Git|ContextMenu'`：27 个 suite，197 项通过、1 项既有 Rust 集成项按条件跳过。HTML 与 JUnit 报告分别为 `.artifacts/test-stability/git-issue410-readability.html` 和 `.artifacts/test-stability/git-issue410-readability.junit.xml`。
- 最慢的相关测试为原生绘制多次采样 2,735 ms；包含仓库图的 5,000 行布局 513 ms；真实历史的浅/深色正式 SwiftUI 渲染 424 ms；两种上下文的 IDEA 完整对照 27 ms；SwiftUI 双向箭头事件 42 ms；仓库图游标清理、取消后防止过期结果回填分别 1 ms。全部低于测试预算。
- 正式 SwiftUI 合并段回放图保存在 `.artifacts/issue410/final/reported-history-light.png` 与 `reported-history-dark.png`；两种外观均已检查。测试窗口均已关闭。验证环境仍为 Swift 6.3.3，未完成 Swift 6.2 验证。

### IDEA 参考截图的日期顺序与主题对照

此前的截图回放仍使用拓扑分组顺序及通用颜色后备值，缺少合并提交文字层次。实际检查 IDEA 当前日志菜单后，确认参考模式为“按提交日期”。现在首次加载、分页与仓库图统一请求日期顺序，同时应用主题配色和合并文字色。

新增 `issue410-date-history.tsv` 冻结 `631ede91` 的 300 个日期顺序提交；`issue410-date-context.tsv` 冻结当时所有引用可达的 1,711 个提交，覆盖当前产品 5,000 条上限内的完整仓库。必须保持完整上下文：把它随意裁成 1,000 条，虽然局部线形可能相同，却会改变 DFS 片段编号及颜色。原有拓扑顺序 fixture 保留作兼容回归。

参考截图对应 `2bedf381` 到 `887f49ea` 的 11 行，包含 `de4208d5` 的 `update`。测试使用正式 SwiftUI 列表及 AppKit 绘图器渲染这同一段历史，检查浅色和深色外观，不使用示意图替代。设置 `LITHE_GIT_GRAPH_CAPTURE_DIR` 后导出 `idea-reference-light.png` 和 `idea-reference-dark.png`，并保留最初反馈中的密集合并段。

独立 Java oracle 仍调用 IDEA 原始实现。页外父提交须使用不同负数 ID，不能用 `PermanentLinearGraphBuilder.build()` 的统一占位值，否则两个未加载父节点会在端点映射中互相覆盖。主题 RGB fixture 则显式设置 IDEA 主题的两个 UIManager 参数后调用原始颜色生成器，覆盖浅/深色、正/负 ID 与溢出。

Core 的本地 Git 集成回归构造固定作者/提交者日期的交错双分支，并将根提交的时钟设在后代之后，验证日期排序仍保持拓扑、作者日期不参与遍历、分页无重复、排序不匹配后可继续原游标、旧调用保留拓扑分组，以及 offset 兼容路径。

本轮计时验证记录：

- `LITHE_GIT_GRAPH_CAPTURE_DIR="$PWD/.artifacts/issue410/date-order" ./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh --report .artifacts/test-stability/git-issue410-date-regression.json -- --filter 'Git|ContextMenu'`：27 个 suite，197 项通过，1 项既有 Rust 集成用例按条件跳过。HTML / JUnit 为 `.artifacts/test-stability/git-issue410-date-regression.html` 与同名前缀 `.junit.xml`。
- `node .agents/skills/write-stable-tests/scripts/run-rust-tests-with-timing.mjs --manifest rust/Cargo.toml --package lithe-core --report .artifacts/test-stability/git-issue410-date-rust.json --keep-going`：448 项全部通过。HTML / JUnit 为 `.artifacts/test-stability/git-issue410-date-rust.html` 与同名前缀 `.junit.xml`。
- 新增日期分页测试 160 ms；三个真实历史 IDEA 对照 59 ms；主题 RGB 对照 1 ms；两种排序、两种外观的正式视图回放 1,180 ms（包含窗口和位图创建）；SwiftUI 箭头点击 47 ms。相关的 5,000 行布局 543 ms，原生多次绘制采样 3,186 ms，均低于 15 秒测试预算。
- Rust 普通并行门禁曾在既有 `native_rebase_large_escaped_manifest_remains_readable_through_abort` 处失败，单项重试也出现过失败；该用例在逐项计时及 `RUST_TEST_THREADS=1` 的完整重跑中通过。本次未修改这个无关用例或放宽其 5 秒请求期限，不能把这次串行通过解释为并行稳定性已经修复。
- `./scripts/verify-core.sh`、`./scripts/verify-git-graph.sh`、服务边界、共享契约、Rust 注释及测试稳定性门禁通过。环境仍只有 Swift 6.3.3，未完成 Swift 6.2 验证。
- `RUST_TEST_THREADS=1 ./scripts/verify-rust-core.sh`：435 个 Core 单元/集成用例、8 个 push 用例及 5 个 watch-context 用例通过，Swift 桥接、真实静态库链接与导出符号检查通过。
- `./scripts/build-macos.sh` 与 `git diff --check` 通过；回放窗口已关闭，生成的 Git 验证仓库已删除，结束时没有遗留 Lithe 应用或测试进程。

### PR #616 review 回归

- 筛选后仍保留隐藏祖先通向页外父节点的虚线和未加载状态；覆盖补页、真实根节点、无关隐藏分支、多个可见子节点、合并路径去重及可见祖先边界。
- 箭头命中对准绘制尖端，原生列表处理行交界处的尖端。展开模式的五父合并 fixture 通过原生命中和正式 SwiftUI 鼠标事件验证跨多列的上下箭头；测试取绘制坐标，不取命中区域自身的中心。
- 当前页和引用就绪即可显示、分页；仓库上下文独立补全。受控 worker 验证首屏无需等待上下文、旧请求迟到不覆盖新分支及取消后游标清理。
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh --report .artifacts/test-stability/pr616-review-regression.json -- --filter 'Git|ContextMenu'`：203 项通过，1 项既有 Rust 集成项按条件跳过，HTML/JUnit 使用同名前缀。新增用例最慢为 SwiftUI 斜箭头点击 23 ms；5,000 行布局 502 ms，原生绘制采样 2,815 ms，均在原有预算内。
- `./scripts/build-macos.sh`、`./scripts/verify-git-graph.sh`、服务边界、测试稳定性静态门禁和 `git diff --check` 通过。IDEA 原始 fixture 与真实历史独立 oracle 对照全部通过。本地工具链为 Swift 6.3.3；当前修正的 Swift 6.2 结果须以新一轮 CI 为准。

### PR #616 第二轮 review 修复

- 主日志复用 AppKit 绘图表面的跨行箭头命中，修复展开模式向下尖端恰好落在下一行时选错行的问题。正式 SwiftUI 窗口鼠标事件同时覆盖精确尖端、内移 0.5 pt、上下两个方向；每次只导航到目标，不触发普通行选择。另验证节点区域及正文点击仍选择对应行。
- 缺页传播改为共享隐藏边界 DAG，消除逐节点复制累计父哈希集合的平方存储。5,000 个不同缺页端点的合并链从修复前约 1.94 秒降到本轮两次测量的 31–71 ms；这是该固定输入的本机测量，不代表所有图的复杂度。2,500 个可见分支共用 2,500 个隐藏节点的场景为 44 ms；输出阶段取消后不再发出后续端点。
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh --report .artifacts/test-stability/pr616-fix2-regression.json -- --filter 'Git|ContextMenu'`：207 项通过，1 项既有 Rust 集成项按条件跳过。HTML/JUnit 使用同名前缀；最慢的新增测试为两个 5,000 节点输入合计 49 ms，精确尖端及内侧点击合计 40 ms，普通行点击 15 ms，取消输出 1 ms。计时面板无失败、超时或超预算，10 项既有绘制采样和文件观察测试有性能预警；未放宽预算。
- macOS 产品构建（实际链接 Rust Core）、Git 图验证、服务边界、测试稳定性静态检查和 `git diff --check` 均通过。再次检查共享路径、缺页去重、可见祖先边界、取消结果与主界面事件路由，未发现额外可复现问题。IDEA fixture、真实历史 oracle 和主题 RGB 对照全部通过。本地仍为 Swift 6.3.3，Swift 6.2 以本轮提交的 CI 为准。
