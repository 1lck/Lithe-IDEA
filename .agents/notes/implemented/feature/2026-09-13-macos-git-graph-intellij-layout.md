# Agent 笔记：Git 提交图对齐 IntelliJ 布局与长边导航

状态：已实现

> 2026-11-08 Viva 迁移：本文的图算法决策仍然有效，图投影已由 Rust Core 的 `git.graphProjection` 提供，Viva 调用它并绘制历史列表。原 macOS 界面的像素、交互和测试记录属于迁移前的 Swift 客户端，已从本文删除；Viva 的完整交互和像素级一致性尚未重新验收。

关联需求：[Issue #410](https://github.com/1lck/Lithe-IDEA/issues/410)。

## 先说结论

Git 提交图以固定版本的 IntelliJ 实现作为算法基准，先对完整仓库建图，再根据当前页面投影结果。颜色、顺序和长边处理都必须保持稳定，这样用户看到的历史图才能和参考实现一致，并且可以回归验证。

## 问题

早期实现使用固定槽位布局，且只在当前分支页面上建图、按提交 hash 对固定颜色表取模。复杂合并历史下，多条无关分支会碰巧同色；颜色和顺序随分页、筛选跳变；长边处理也与 JetBrains IDEA Log 不一致。

需要固定对齐一个不随时间变化的参考实现，而不是随时可能变化的 IDEA master 分支或截图颜色，否则“是否与 IDEA 一致”无法被验证或回归。

## 决策

算法基准固定为 JetBrains/intellij-community 提交 `36415d346b3d18a6ded90d05afb8e0a0bface9d6`（`GraphLayoutBuilder`、`GraphElementComparatorByLayoutIndex`、`PrintElementGeneratorImpl`、`DottedFilterEdgesGenerator`、`GraphColorManagerImpl` 等）。算法落在 Rust Core 的 `git.graphProjection`（Core 仓库的 `rust/crates/git/src/graph.rs`）。桌面端的 `git.historyPage` 显式请求 `order: "date"`，未提供该参数时默认仍为 `--topo-order`。

关键规则：

- **先建仓库范围的永久图，再投影可见页。** 仓库图决定永久 layout index、颜色和基础顺序；可见页只决定显示哪些提交、哪些父提交尚未加载。上下文就绪后只更新仓库图并触发已有投影，不替换可见页或选择。
- **按 committer date 排序。** 对应 IDEA 的 Normal 模式，使用 committer date，不使用界面展示的 author date。rebase 或 cherry-pick 后两者不同，用 author date 会与参考行为不一致。
- **图头集合和优先级固定。** 没有子节点的提交加上所有分支引用和 HEAD 指向的提交（tag 的内部节点不算）；每个图头按 `origin/main`、`origin/master` → 其他远程分支 → 本地 `main`、`master` → 其他本地分支 → tag → HEAD 排序，同类引用用 IDEA 的自然名称比较。按有序图头做非递归 DFS 分配 layout index，这是分支相对顺序，不是屏幕列号，也不用来决定颜色。
- **颜色由图头引用名或 layout index 生成，不对 hash 取模。** 主片段用该图头最优先引用名的 Java `String.hashCode`，其他 DFS 片段用 layout index 作为颜色 ID，经 IDEA 的整数 RGB 映射得到 hue，再应用当前主题的 saturation 与 brightness 覆盖值；边用两端 layout index 较大者所属片段的颜色；主题切换清除颜色缓存。
- **筛选只改变可见性，不改变顺序。** 作者、关键词、日期、路径筛选后，布局顺序仍来自完整图；隐藏祖先产生的虚线经共享的隐藏边界 DAG 计算，避免逐节点复制累计父哈希集合。
- **长边省略阈值固定复刻 IDEA。** 默认紧凑模式对跨度不小于 30 行的边省略中间行，只在端点不超过 1 行的范围内保留；显示长边模式的阈值是 1,000 行，端点范围 250 行；跨度不小于 30 行时端点附近仍有方向箭头。“长边收束”只隐藏中间行的边本身，不删除中间行的其他提交，也不做 IDEA 的“折叠一整段线性提交”功能。
- **合并提交的判断看父节点数量。** 两个及以上父节点的提交才算合并提交，不根据标题是否以 “Merge” 开头判断。
- **当前分支底色只按已加载图计算。** 深蓝底色表示当前分支可到达的提交，包含所有合并父节点，不按图谱列、连续行块或提交标题猜测。祖先集合在数据刷新任务中生成，绘制和滚动不读取 Git。当前只遍历已加载图谱，因此缺失的历史不能推断为当前分支成员。
- **边界仍由 Core 产生。** 宿主不在绘制时运行 `git branch --contains` 之类的命令。

正确做法：图的颜色、顺序和边都来自 Core 的投影结果，宿主只做显示和命中。
不要这样做：在宿主里对 hash 取模定色，或在每次绘制时重新推导图的拓扑。

## 考虑过的备选方案

- **按提交 hash 对固定颜色表取模**：实现最简单，不需要维护图头优先级或 layout index。但相邻的无关分支会碰巧同色，复杂合并历史下问题会被放大，因此改为按图头引用名的 hashCode 与 layout index 生成颜色。
- **只在当前页面上建图，不建仓库级永久图**：减少一次请求，实现更直接。但缺少仓库级的主线优先级，分页或切换筛选时顺序和颜色会跳变，因此改为先建完整仓库图，再投影当前页与筛选结果。
- **启用 IDEA 的 BEK 模式或“折叠一整段线性提交”功能**：这两个是 IDEA Log 的可选模式。本次范围只需要 Normal committer-date 模式和长边省略，扩大范围会显著增加验收面，因此明确不启用。
- **用界面展示的 author date 排序**：可以复用已显示的字段，但与 IDEA 的 Normal 模式不一致，因此新增可选的 `order` 参数显式请求 committer date 排序。

## 后果

- Git 提交图的颜色、顺序和长边行为与固定版本的 IDEA Log 一致，可以用同一份上游夹具和独立的 Java oracle 验证，不依赖会变化的截图或 master 分支。
- 仓库上下文和单个历史游标分别有 5,000 条硬上限；超出范围的极旧分支会退回到只用当前页建独立图，不承诺仓库级颜色与顺序一致性。
- 代价：渲染必须等仓库图的 DFS 完成才能确定最终颜色和顺序，实现比“只处理当前页”复杂，并且需要仓库上下文的取消和代次校验；`git.historyPage` 多了一个需要向后兼容维护的可选参数。
- 如果以后要改变图算法，必须以本文引用的固定 IntelliJ 提交和共享夹具为依据，不能重新从零选择对齐目标。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/core ./internal/workbench`：当前桌面代码的常规测试；它不证明图的逐像素对齐或所有交互已完成。
- Core 仓库的 [`rust/fixtures/git/graph-idea/`](https://github.com/Lithe-IDEA/Lithe-core-rust/tree/main/rust/fixtures/git/graph-idea/)：4 个布局夹具比较完整的 layout index 向量，5 个打印夹具比较节点列、半边端点、箭头与实线、虚线，只排除颜色值。
- [`rust/fixtures/git/graph-projection-v1.json`](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/fixtures/git/graph-projection-v1.json)：投影规则的共享夹具。
- Viva 图投影的长边交互与真实窗口截图仍需针对当前客户端验收。

## 适用范围

- `desktop/internal/core/gitlog.go`
- `desktop/internal/workbench/gitgraph.go`
- `desktop/internal/workbench/gitlog.go`
- `desktop/internal/workbench/gitlog_view.go`
- Core 仓库的图投影实现（[`rust/crates/git/src/graph.rs`](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/crates/git/src/graph.rs)），以 [Lithe-core-rust](https://github.com/Lithe-IDEA/Lithe-core-rust) 当前固定的修订为准。

## 后续：布局下沉到 Rust Core（#1662 GIT-18/19）

本文描述的 DFS、head 排序、定色、过滤后的虚线拓扑和 missing parents 算法已搬进 Core 的 `rust/crates/git/src/graph.rs`，由 `git.graphProjection` 统一提供，规则以 Core 仓库的 `rust/fixtures/git/graph-projection-v1.json` 为准。宿主只保留绘制和颜色 ID 到主题色的映射。
