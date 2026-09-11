# macOS Git 提交图：IntelliJ 布局与长边导航

关联需求：[Issue #410](https://github.com/1lck/Lithe-IDEA/issues/410)。

本次只实现 macOS。算法落在现有 `LitheGitModule`，AppKit/SwiftUI 负责绘制与交互；不改 Windows、Rust Core 或共享 JSON 协议。以后迁移共享实现时，以本文件和 macOS 的算法回归用例为依据。

## 对齐基准与范围

算法基准固定为 JetBrains/intellij-community 提交
`36415d346b3d18a6ded90d05afb8e0a0bface9d6`，不以随时变化的 master 或截图的颜色作为规范：

- [GraphLayoutBuilder.kt](https://github.com/JetBrains/intellij-community/blob/36415d346b3d18a6ded90d05afb8e0a0bface9d6/platform/vcs-log/graph/src/com/intellij/vcs/log/graph/impl/permanent/GraphLayoutBuilder.kt)：从有序图头开始 DFS，给连续分支分配 layout index。
- [GraphElementComparatorByLayoutIndex.java](https://github.com/JetBrains/intellij-community/blob/36415d346b3d18a6ded90d05afb8e0a0bface9d6/platform/vcs-log/graph/src/com/intellij/vcs/log/graph/impl/print/GraphElementComparatorByLayoutIndex.java)：节点与经过本行的边的相对排序。
- [PrintElementGeneratorImpl.kt](https://github.com/JetBrains/intellij-community/blob/36415d346b3d18a6ded90d05afb8e0a0bface9d6/platform/vcs-log/graph/src/com/intellij/vcs/log/graph/impl/print/PrintElementGeneratorImpl.kt)：逐行紧凑定位、相邻行路由、长边裁减与箭头阈值。
- [DottedFilterEdgesGenerator.kt](https://github.com/JetBrains/intellij-community/blob/36415d346b3d18a6ded90d05afb8e0a0bface9d6/platform/vcs-log/graph/src/com/intellij/vcs/log/graph/collapsing/DottedFilterEdgesGenerator.kt)：双向遍历，在筛选隐藏的提交之间补可见虚线。
- [GitRefManager.kt](https://github.com/JetBrains/intellij-community/blob/36415d346b3d18a6ded90d05afb8e0a0bface9d6/plugins/git4idea/backend/src/log/GitRefManager.kt) 的 `GitBranchLayoutComparator`、[HeadCommitsComparator.java](https://github.com/JetBrains/intellij-community/blob/36415d346b3d18a6ded90d05afb8e0a0bface9d6/platform/vcs-log/impl/src/com/intellij/vcs/log/graph/HeadCommitsComparator.java) 与 [NaturalComparator.java](https://github.com/JetBrains/intellij-community/blob/36415d346b3d18a6ded90d05afb8e0a0bface9d6/platform/util/base/src/com/intellij/openapi/util/text/NaturalComparator.java)：图头的引用优先级和自然名称排序。
- [GraphCommitCellUtil.kt](https://github.com/JetBrains/intellij-community/blob/36415d346b3d18a6ded90d05afb8e0a0bface9d6/platform/vcs-log/impl/src/com/intellij/vcs/log/ui/render/GraphCommitCellUtil.kt)：按每行打印元素及相邻列中点计算文字起点。
- [产品行为说明](https://www.jetbrains.com/help/idea/log-tab.html)：Long Edges 默认关闭，箭头导航到连线另一端。

这里的“同样算法”指上述布局、图头优先级、比较、可见图与打印元素规则在相同输入上的一致性。提交行顺序仍由 Lithe 已有的 `git log --topo-order` 提供；IDEA 的日期排序、BEK 排序和颜色主题不在本次范围内。比较截图时必须统一提交集合、行顺序、引用、筛选条件和 Long Edges 设置。macOS 保留产品现有的 30 pt 行高与 13 pt 列间距，几何比例没有宣称像素级复刻 IDEA。

长边收束隐藏的是两个提交之间经过很多行的边，不删除中间行的其他提交；“折叠一整段线性提交”属于另一种功能，本次不启用。

## 原理

### 1. 完整提交图和稳定的分支顺序

输入为子提交在父提交之前的有界历史页，父数组保持 Git 的原顺序。建立 hash → 行号、父子邻接表，去重重复父边，页外父提交单独保留。

图头集合是没有子节点的提交，加上所有分支引用和 HEAD 指向的提交；只有 tag 的内部节点不单独成为图头。每个图头选择最优先的引用，按 `origin/main`、`origin/master` → 其他远程分支 → 本地 `main`、`master` → 其他本地分支 → tag → HEAD 排序；同类引用使用 IDEA 的自然名称比较，包括数字段、前导零和大小写平局处理。无引用图头最后按输入行号排序。远程名称通过引用快照识别，支持非 `origin` 远程。Lithe 目前只展示单个仓库，因此无需 IDEA 的跨仓库 root 平局规则。

按照有序图头执行非递归 DFS。首次访问节点时写入当前 layout index；沿第一个尚未访问的父节点继续，走到没有未访问父节点的节点时递增 index，再回溯处理其他父节点。这是分支的相对顺序，不是屏幕列号，也不能用屏幕列号决定颜色。

### 2. 筛选生成可见图

作者、关键词、日期和路径筛选只决定哪些节点可见。布局顺序来自完整图，不能先删掉提交再把被删父节点判为“未加载”。

保留两端都可见的直接边。沿完整图执行向下和向上的编号传播，按 IDEA 的最近可见节点规则补虚线，并对重复端点去重。虚线表示经过被隐藏的提交，实线表示直接父子边。页外父提交使用独立的未加载标记；已知但被筛掉的节点不会产生“历史未加载”的误报。

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

“跨度”使用可见图的行号之差。省略边在中间行不占列；下箭头指向父提交，上箭头指向子提交。点击已有可见目标时选择目标、滚动定位并刷新详情，不改变多选修订操作的执行规则。箭头有独立的命中区域、提示文字和可访问按钮，普通图形区域仍使用整行选择。

页外父节点不能伪装为已有行；保留明确的未加载提示和现有 Load more 入口。补页后按新图重新投影，补齐端点。不能为了跳转把一个旧提交插在日志顶部破坏拓扑顺序。

### 5. 渲染与性能

布局和筛选投影在后台执行，按历史版本、引用版本、筛选结果版本与长边显示模式触发；取消或版本过期的结果不得覆盖当前图。选择、hover、滚动不重新执行 DFS 或全图投影。

继续使用现有单个 AppKit 绘图表面，只绘制 dirty rect 对应的行。SwiftUI 的行承担原有选择、上下文菜单和多选行为。箭头命中与提示使用已经生成的打印元素，不在鼠标移动时遍历 Git 历史。列表宽度由当前可见打印元素计算。

有界历史目前最多 5,000 个提交。分页可能需要调整列位置和被补齐的边；应保留滚动锚点，不承诺在输入图改变时每个像素都不变。

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
| `macos/Sources/LitheGitModule/Services/GitGraphLayoutService.swift` | macOS 布局入口、引用解析和绘制快照 |
| `macos/Sources/Lithe/Views/Git/GitGraphGeometry.swift` | 半边坐标、文字宽度和箭头命中范围 |
| `macos/Sources/Lithe/Views/Git/GitGraphView.swift` | AppKit 绘制、SwiftUI 箭头按钮和原生列表导航 |
| `macos/Sources/Lithe/Views/Git/GitLogView.swift` | 缓存更新、长边开关、选择、详情和滚动定位 |

上游 fixture 固定保存在 `macos/Tests/LitheGitModuleTests/Fixtures/GitGraphIDEA/`。4 个布局 fixture 比较完整 layout index 向量；5 个打印 fixture 比较完整节点列、上下半边端点、箭头与实/虚线结果，只排除使用不同回调生成的颜色值。fixture 输入和输出不随 Lithe 实现生成。Apache-2.0 许可证和来源说明放在 `macos/Resources/GitGraph/`，随预览、打包和性能测量应用一起复制。

### 2026-09-11 验证记录

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
