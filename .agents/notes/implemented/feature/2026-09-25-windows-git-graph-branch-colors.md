# Agent 笔记：Windows Git 提交图按分支名固定颜色

状态：已实现

关联：Windows 侧对齐 macOS 的 IDEA 风格图着色，见
[`2026-09-13-macos-git-graph-intellij-layout.md`](2026-09-13-macos-git-graph-intellij-layout.md)。

## 先说结论

Windows Git 提交图不再按"第几条泳道"轮换颜色，而是用泳道所代表分支的引用名
（Java `String.hashCode`）决定颜色。分支换到别的泳道、历史分页或拓扑变化时，
同一条分支保持同一种颜色；没有引用名的泳道用一个确定性的兜底序号。

## 问题

`windows/tauri/src/features/git/utils/git-graph-layout.ts` 原先把颜色按泳道槽位分配：
每新占一个槽位就 `colorIndex++`。泳道编号会随合并顺序、分页和可见提交集合变化，
于是同一条分支的颜色会跳变，用户看到的图与 macOS/IDEA 不一致。

## 决策

- 颜色身份来自引用名，不来自泳道序号。每条提交解析其装饰（`parseGitDecorations`），
  按 IDEA 的优先级选出"主引用"：`origin/main`/`origin/master` → 其他远程分支 →
  本地 `main`/`master` → 其他本地分支 → tag → HEAD。
- 用主引用名的 Java `String.hashCode`（按 UTF-16 code unit 计算，`git-graph-colors.ts`
  的 `javaStringHashCode`）对现有 6 色调色板取模，得到 `colorIndex`
  （`graphColorIndexForName`）。复用 `git-graph-row.tsx` 原有的调色板与线宽，
  不引入新颜色或色相算法。
- 颜色在**泳道建立时**确定：非首个父提交占新槽位时用该提交的主引用名上色；
  首个父提交延续当前泳道颜色（与 macOS 的图头片段沿用同一颜色一致）。
- 没有引用名的提交（合并的第二父、快照外的父提交等）用自增兜底序号
  （`fallbackColorIndex`），只保证同输入同输出，不承诺跨拓扑稳定。
- 调色板、`graphColor` 与哈希函数集中到
  `windows/tauri/src/features/git/utils/git-graph-colors.ts`，供布局与行渲染共用。

## 考虑过的备选方案

- **沿用 macOS 的整数 RGB → hue 方案（`GitGraphColor.swift`）**：能产生更多互不
  相同的颜色，但会改变 Windows 现有的 6 色调色板与视觉语言，还需要跨平台同步
  主题覆盖值。本次只要求颜色稳定，因此保留既有调色板，只改颜色身份来源。
- **按提交 hash 取模**：实现最简单，但会让相邻的无关分支碰巧同色，历史一变化
  颜色仍会跳。因此改为按引用名。
- **未引用泳道也按某个假名哈希**：不如自增序号直观，也无法保证首帧稳定，
  故采用确定性兜底序号。

## 后果

- 同一条命名分支在分页、筛选、拓扑变化后颜色不变；颜色只取决于引用名。
- 6 色调色板下不同分支仍可能撞色（这是既有视觉约束，非回归）。
- `GitGraphEdge.colorIndex` / `GitGraphRow.incomingLaneColors` 的语义从"泳道序号"
  变为"调色板槽位"，取值 0–5 或兜底序号；未引用的兜底序号与命名分支的槽位
  可能重叠。
- 单仓库、单分支等简单历史行为不变（颜色仍是调色板第 0 色时可能的等价结果）。

## 验证

- Windows 前端：`tsc --noEmit`；`bun test src/features/git`，其中
  `git-graph-layout.test.ts` 覆盖"同一分支名在不同拓扑落到不同泳道时颜色一致"、
  "未引用泳道确定性"、"Java `String.hashCode` 取值"与"主引用优先级选择"。

## 适用范围

- `windows/tauri/src/features/git/utils/git-graph-colors.ts`
- `windows/tauri/src/features/git/utils/git-graph-layout.ts`
- `windows/tauri/src/features/git/components/log/git-graph-row.tsx`

不改变 Rust Core、JSON 契约或 macOS 实现；Windows 的布局仍是泳道槽位算法，
不是 macOS 的仓库级永久图。
