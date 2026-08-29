# Git Log 筛选器有界下拉技术方案

对应需求：[`2026-08-29-git-log-filter-popover-requirements.md`](./2026-08-29-git-log-filter-popover-requirements.md)
对应 Issue：[#302](https://github.com/1lck/Lithe-IDEA/issues/302)

## 现状分析

筛选栏实现位于 `macos/Sources/Lithe/Views/Git/GitLogView.swift`（`gitLogFilterBar`）：

- Branch、User 两个筛选器原为 SwiftUI `Menu`（`.menuStyle(.borderlessButton)`），
  底层是 NSMenu。NSMenu 在条目多时会纵向铺满屏幕且无最大高度约束，这就是 issue 截图中
  巨型弹层的来源（并非真的 WebView；macOS 全工程的 WKWebView 仅用于 Markdown 预览与
  LinuxDo 社区，与 Git Log 无关）。
- Path 筛选器已经用 `.popover(isPresented:arrowEdge:)` + 有界内容实现了锚定弹层，
  证明该模式在本视图中可用。
- `BranchSwitcherPopover` 已经实现了有界弹层：搜索框 + 分组列表 + 滚动 +
  `lithePopupChrome`，其布局、行样式可直接借鉴。

数据侧无需改动：`model.gitReferences`（`GitReference`，含 `kind`/`shortName`/
`upstreamShortName`/`isCurrent`）与 `model.gitCommits` 派生的作者列表已存在，筛选动作
`model.selectGitReference(_:)` 已有。本次是纯 macOS 视图层改动，不触碰 Rust Core、
共享契约和 Windows。

## 方案概述

新增文件 `macos/Sources/Lithe/Views/Git/GitLogFilterPopover.swift`，包含两个弹层视图、
共享子组件与纯逻辑构建器。形态对齐 IDEA 的 Git Log 筛选菜单：

```text
gitLogFilterBar
 ├─ Branch 标签 ──.popover──▶ GitLogBranchFilterPopover（两级结构）
 │     ├─ 一级列：All Branches 重置项 + ⭐当前分支 + ⭐upstream + 分组行（Local / origin/… / Tags）
 │     ├─ 二级列（flyout）：点分组行后右侧展开该组全部引用，有界高度、内部滚动
 │     └─ 搜索框：输入后切换为扁平过滤模式（复用 branchSections）
 └─ User   标签 ──.popover──▶ GitLogFilterPopover（扁平结构：置顶项 + 可搜索列表）
```

Date、Path 筛选器保持不变。

## 组件结构

纯展示组件，不持有 `AppModel`，所有数据与回调由 `GitLogView` 注入，符合 Views 层边界
（不触碰 Rust C ABI、不依赖 Services）。

| 类型 | 职责 |
| --- | --- |
| `GitLogBranchFilterPopover` | Branch 两级弹层：一级列（重置 + 收藏 + 分组行）+ 二级 flyout；`searchQuery` 非空时切换为扁平过滤 |
| `GitLogFilterPopover<Row>` | 通用扁平弹层（User 筛选使用）：搜索 + 分组列表 + 空状态 |
| `GitLogFilterSearchBar` | 共享搜索行，`onAppear` 自动聚焦，回车选中首个匹配项 |
| `GitLogFilterRowView<Row>` | 共享行渲染：图标（收藏行用强调色）、标题、次要信息、选中态 checkmark + 背景高亮 |
| `GitLogFilterListView<Row>` | 共享分组列表主体：分组头、行、置顶区后的分隔线、空状态 |

纯逻辑（确定性、无副作用，全部可单测）：

| 类型 / 函数 | 职责 |
| --- | --- |
| `GitLogFilterList.branchMenu(references:)` | 浏览模式：当前分支与 upstream 的收藏行；非空分组按 Local → 远程按名排序（`origin/…`）→ Tags 排列；flyout 子项保留完整短名、当前分支置前 |
| `GitLogFilterList.branchSections(references:query:)` | 搜索模式扁平分组：置顶重置项 + 本地命名空间 / Remote / Tags 分组 |
| `GitLogFilterList.authorSections(authors:query:)` | 置顶 All Users / Me + 按名字与邮箱稳定排序的作者列表 |

数据行类型：`GitLogBranchFilterItem`（引用行 / 重置项 / 收藏行）、
`GitLogAuthorFilterItem`（作者行，`selection` 映射回 `GitLogAuthorSelection`）、
`GitLogBranchGroup`（一级分组行）、`GitLogBranchMenu`（浏览模式整体）。

### 区域约束

- 扁平弹层：固定宽 340pt，`maxHeight: 460`，内容超出内部滚动。
- 两级弹层：一级列 224pt + 分隔线 + 二级列 335pt（合计约 560pt），`maxHeight: 460`，
  两列各自 `ScrollView`。
- 紧凑密度对齐 IDEA 菜单：候选行与分组行高 28pt、搜索行 34pt、分组头 24pt、
  分隔线垂直留白 2pt、列内边距 6pt。
- 锚定沿用 Path 筛选的 `.popover(isPresented:arrowEdge: .bottom)` 模式，由系统保证
  贴着触发标签。
- 空查询时 `localizedCaseInsensitiveContains("")` 恒为 false，全部匹配逻辑显式以
  `query.isEmpty` 短路，避免空查询清空列表。

### 行为细节

- 点击候选行：应用筛选并关闭弹层；点击分组行：切换二级 flyout（再点收起）。
- 点弹层外部或 Esc：关闭且不改变筛选（SwiftUI popover 默认行为）。
- 清除按钮（×）与筛选标签文案渲染逻辑不变。

## 不做的事

- 不改 `AppModel`、Services、Core、Rust：数据与动作全部复用现有接口。
- 不改 Date 筛选器与 Windows 端（Windows 若要对齐，属 Tauri 前端独立任务）。
- 不做键盘上下键导航与分组行 hover 展开（后续增强，本次以搜索 + 点击覆盖主路径）。

## 测试计划

按 `write-stable-tests` 规范（确定性、无真实睡眠）在 `macos/Tests/LitheTests/` 的
`GitLogFilterListTests` 中覆盖：

1. `branchMenu`：收藏行取当前分支 + upstream 且标记 starred；分组顺序 Local →
   远程按名 → Tags；flyout 子项完整短名、当前分支置前、本地保留 upstream detail。
2. `branchMenu` 空组省略：无当前分支时收藏区为空；无本地/远程/标签时对应分组不出现。
3. `branchSections`（搜索模式）：分组顺序、组内排序、置顶项查询匹配、空查询返回全量。
4. `authorSections`：置顶区恒定、名字与邮箱匹配、稳定排序、`selection` 映射。

## 验证

| 项 | 命令 |
| --- | --- |
| 测试稳定性门禁 | `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh` |
| 聚焦测试 + 计时报告 | `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'GitLogFilterListTests'` |
| macOS 全量测试 | `./scripts/test-macos.sh` |
| 边界检查 | `./scripts/verify-service-boundaries.sh` |

手工验收：在含 100+ 分支的仓库打开 Branch 筛选，确认两级结构（收藏 + 分组 flyout）、
有界、锚定、可搜索、可滚动，组合筛选与清除行为与改动前一致。

## 工作量评估

- 组件与纯逻辑（含两级结构）：约 0.5–1 天。
- 单测 + 验证脚本 + 手工回归：约 0.5 天。

合计约 1–1.5 个工作日，仍属中小改动：单一视图族内新增文件 + 一处替换，无契约、
无跨端、无数据层变更。
