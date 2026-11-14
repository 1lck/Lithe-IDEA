# Agent 笔记：Git Log 多仓库分支分组

状态：已实现

## 先说结论

当一个工作区里有多个 Git 仓库时，Git Log 的引用面板应按仓库分组，并且只有活动仓库可以执行分支写操作。当前 Viva 桌面端已经接入 Core 的仓库发现和仓库颜色分配（`desktop/internal/core/repository_colors.go`），但 Git Log 界面还没有调用这些分组能力；本文记录分组落地时必须保持的边界。

## 问题

工作区下可以并列多个仓库，主仓库还常带链接工作树（`git worktree`）。如果 Git Log 只显示活动仓库的分支，用户看不到其它仓库的引用，也分不清每条分支属于哪个仓库。反过来，如果把所有仓库的行都做成可写，点在 B 仓库分支上的“删除分支”可能实际作用于 A 仓库，这是数据安全问题。

## 决策

- **聚合放在呈现层，不下沉 Core。** Core 的 `git.references` 与 `git.historyPage` 保持单仓库入参（`root`）。多仓库分组由桌面端逐个仓库调用现有引用读取后汇总；“列出所有仓库引用”不做成 Core 新命令，避免把仓库身份这一呈现概念写进稳定契约。
- **只有活动仓库可写。** 历史、差异、控制台和全部分支写操作（检出、合并、变基、推送、重命名、删除）都只作用于活动仓库。非活动仓库的行可以点选以切换活动仓库，但不提供右键菜单。
- **历史归属活动仓库。** 切换仓库时先关闭旧历史游标、取消旧请求并清理旧的分支与提交选择，再加载目标仓库的引用。不能先切换仓库再沿用旧选择。
- **链接工作树的判定按路径分量比较。** 判断某仓库是否为另一仓库的链接工作树时，逐段比较路径分量（`/workspace/op-platform-extra` 不属于 `/workspace/op-platform`），不能用字符串前缀判断。
- **颜色按完整仓库列表定位。** 仓库颜色槽位由 Core 基于工作树过滤前的完整有序仓库列表计算，过滤后的列表不能重新编号；单仓库时不显示颜色。

## 考虑过的备选方案

- **在 Core 新增“聚合所有仓库引用”命令。** 未采用。它会把呈现层的仓库身份写入稳定契约，并要求两个平台共同维护新的 fixture。
- **允许非活动仓库的行直接执行写操作，并先隐式切换仓库。** 未采用。一次点击会产生用户没预期的活动仓库变化，失败后也难以回滚。
- **按当前可见仓库的序号分配颜色。** 未采用。隐藏工作树后颜色会整体前移，同一仓库的颜色会漂移。

## 后果

- 多仓库工作区可以一次看到所有仓库的分支；单仓库工作区保持原有布局。
- 每次刷新历史会为每个仓库多一次只读引用读取，仓库越多耗时越长。
- 非活动仓库没有右键菜单，要对该仓库做写操作必须先切换过去。
- 当前 Git Log 尚未显示分组，本笔记的边界在分组接入时才会生效。

## 验证

- `scripts/desktop/desktop-go.sh test -race ./internal/core -run 'Test(WorkspaceRepositoryDiscoveryUsesCoreRules|RepositoryColorAssignmentsUseCoreFixtures)' -count=3 -timeout=90s`：验证仓库发现顺序、嵌套仓库、隐藏目录，以及颜色分页与错误拒绝。
- 分组接入后需在真实多仓库工作区中验收：切换活动仓库、非活动仓库无右键菜单、隐藏工作树后颜色不变。

## 适用范围

- `desktop/internal/workbench/gitlog.go`
- `desktop/internal/workbench/gitlog_view.go`
- `desktop/internal/core/gitlog.go`
- `desktop/internal/core/workspace.go`
- `desktop/internal/core/repository_colors.go`
- `shared/platform-feature-matrix/features/git-multi-repository-references.json`
