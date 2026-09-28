# Agent 笔记：双端统一的 Git 提交图布局与分支颜色

状态：已实现

关联：Windows 侧对齐 macOS 的 IDEA 风格图着色，见
[`2026-09-13-macos-git-graph-intellij-layout.md`](2026-09-13-macos-git-graph-intellij-layout.md)。

## 先说结论

macOS 和 Windows 的 Git 提交图现在使用同一套 IntelliJ 风格的永久图规则：先按引用优先级确定图头，再为每个图头分配稳定的图片段和颜色，最后根据提交顺序投影到屏幕泳道。这样本地分支新增提交时，不会因为沿用父分支的第一条泳道而和父分支混成同一种颜色；两个端的分支优先级、颜色身份和合并拓扑也保持一致。

Windows 仍保留现有六色调色板和 SVG 行渲染，只把 macOS 已落地的图头排序、永久布局和紧凑长边规则移植到 `git-graph-layout.ts`。今后修改提交图算法时，必须同时以 macOS 的实现和 IntelliJ 固定基准为准，不要重新引入按泳道创建颜色的算法。

## 问题

Windows 原先只在当前提交页上维护泳道槽位。第一父提交会直接继承当前泳道颜色，因此本地分支的提交和父分支的提交在分叉关系中可能继续使用同一个颜色。泳道编号还会随着合并顺序和页面数据变化，导致同一分支在不同历史窗口中的颜色或位置不稳定。

macOS 已经按 IntelliJ 的永久图规则处理了这个问题，但 Windows 仍是独立的槽位算法，导致同一仓库在两个端展示不同。

## 决策

- **统一图头排序**：按 `origin/main`/`origin/master`、其他远程分支、本地 `main`/`master`、其他本地分支、tag、HEAD 的优先级排序；同类引用使用 IntelliJ 自然名称排序。`refs/heads/`、`refs/remotes/` 和 `refs/tags/` 在解析时先还原为展示名。
- **统一永久布局**：先在完整的当前提交快照上按有序图头做非递归 DFS，生成与屏幕列无关的 layout index。已被更高优先级父分支占用的父提交保留父分支片段，新增本地图头从新的片段开始。
- **统一颜色身份**：图头主片段使用主引用名的 Java `String.hashCode` 映射到 Windows 现有六色调色板；其他 DFS 片段使用 layout index。边使用两端 layout index 较大者所属片段的颜色，避免本地提交沿用父分支颜色。
- **统一紧凑投影**：Windows 使用与 macOS compact 模式相同的 30 行长边阈值和 1 行端点保留规则。屏幕泳道只负责排版，不能再决定颜色身份。
- **保持平台边界**：Rust Git 历史接口、JSON 契约和 macOS 的 native graph renderer 不变；Windows 只在自身布局投影层复用相同算法语义，并继续使用现有 SVG 组件绘制。

## 考虑过的备选方案

- **只修复 Windows 的第一父颜色继承**：改动小，但无法解决合并顺序、分页和两个端布局规则不一致的问题，因此没有采用。
- **继续按泳道序号轮换颜色**：实现简单，但泳道是屏幕布局结果，不是分支身份，历史窗口变化后颜色仍会跳变，因此没有采用。
- **按提交 hash 取模**：可以让颜色看起来稳定，但相邻的无关提交可能碰巧同色，也无法体现父分支和本地分支的关系，因此没有采用。
- **将算法下沉到 Rust Core**：当前 macOS 还需要 native graph 的打印元素与可见投影，而 Windows 使用不同的渲染模型；本次只统一算法语义，避免把平台绘制模型错误地塞入跨平台 Core。

## 后果

- Windows 本地分支在父分支之上新增提交时，提交节点和连接线可以与父分支清楚区分，解决 Issue #902 的主要体验问题。
- 两端的图头优先级、自然名称排序、永久片段颜色和紧凑长边处理一致；同一历史在两个端不会再因为使用不同的槽位算法而出现明显分叉差异。
- Windows 仍使用六色调色板，不同片段在颜色数量有限时可能撞色；这属于既有视觉约束，不代表片段身份被重新合并。
- Windows 当前日志页没有 macOS 的完整仓库上下文投影能力，因此颜色稳定性范围是当前加载的提交快照；以后增加跨页/筛选永久图时，必须复用这里的永久布局入口，不能恢复槽位着色。

## 验证

- 既有 macOS 对照基准：`./scripts/verify-git-graph.sh`
- Windows 前端：`tsc --noEmit`；`bun test src/features/git`
- 代码边界和运行时资源：`./scripts/verify-service-boundaries.sh`、`./scripts/verify-runtime-bundle-immutability.sh`

## 适用范围

- `windows/tauri/src/features/git/utils/git-graph-layout.ts`
- `windows/tauri/src/features/git/utils/git-graph-colors.ts`
- `windows/tauri/src/features/git/components/log/git-graph-row.tsx`
- `macos/Sources/LitheGitModule/Services/GitGraphHeadOrdering.swift`
- `macos/Sources/LitheGitModule/Services/GitGraphProjection.swift`
- `macos/Tests/LitheGitModuleTests/Fixtures/GitGraphIDEA/`
