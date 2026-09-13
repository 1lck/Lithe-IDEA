# Agent 笔记：macOS Git 提交图对齐 IntelliJ 布局与长边导航

状态：已实现

关联需求：[Issue #410](https://github.com/1lck/Lithe-IDEA/issues/410)。

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
- **渲染尺寸和合并提交文字层次复刻 IDEA**：22pt 行高、16pt 列距、
  8pt 节点直径、1.5pt 线宽；两个及以上父节点的合并提交标题使用
  `VersionControl.Log.Commit.unmatchedForeground`，以父节点数量而非
  标题是否以 "Merge" 开头判断是否为合并提交。

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
- `rust/lithe-core/src/git/history.rs`
- `macos/Sources/Lithe/Core/Rust/RustGitOperations.swift`
- `macos/Tests/LitheGitModuleTests/Fixtures/GitGraphIDEA/`
- `macos/Tests/LitheTests/Fixtures/GitGraph/`
- `macos/Resources/GitGraph/`
