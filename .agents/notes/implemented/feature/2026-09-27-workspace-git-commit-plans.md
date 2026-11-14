# Agent 笔记：工作区多仓库提交计划与重试

状态：已实现

## 先说结论

Changes 中的勾选仍代表 Git 的暂存状态；用户一次提交时，提交计划按文件所属仓库分别执行，并按子模块的引用关系排序。计划的生成、确认后的复核、失败传播和重试全部由 Rust Core 完成，桌面端只负责界面与原生交互。当前 Viva 的提交界面只操作当前仓库，多仓库确认与重试流程尚未接入，本文记录接入时必须遵守的规则。

## 问题

只看目录包含关系不能证明两个仓库有依赖：真正的子模块中，父仓库只记录子仓库的提交号。只读取有暂存文件的仓库会漏掉干净的父仓库；确认后直接重算并执行，会悄悄扩大用户同意的范围；推送失败后再次提交，又会重复创建提交。

## 决策

- **暂存区是唯一的选择来源。** 外部 `git add` 的结果会直接反映到勾选上，不另建只属于界面的提交选择。
- **子模块关系以 gitlink 为准。** 子仓库的变更先提交，父仓库只更新该子模块的引用，不能用 `git add --all` 把父仓库的其它未选文件带入提交。
- **确认前重新检查计划。** 确认窗口显示仓库、文件、执行顺序和引用更新，并允许关闭本次自动联动；任何状态变化（HEAD、分支、索引对象或暂存路径）都要更新计划并重新确认。写入前仍在仓库写锁内再核对一次。
- **每次只执行一个提交或推送。** 失败的仓库保留已完成的步骤；依赖它的父仓库等待重试。重试只做剩余的提交或推送，已经提交的仓库只推送，已成功的独立仓库不会再次提交。
- **读取失败不算没有依赖。** 任何仓库读取失败都必须中止建立计划，不能把读取失败当成没有依赖。
- **子仓库元数据消失时拒绝执行。** 操作前确认 Git 的真实根目录，避免 Git 向上搜索后误用父仓库。
- **结果只保留在当前项目会话中。** 退出项目或清除结果后，不提供恢复记录。

## 考虑过的备选方案

- **独立于暂存区的提交勾选。** 未采用。会改变已有勾选的含义，外部暂存和部分暂存都需要第二套同步规则。
- **确认后静默执行重算的计划。** 未采用。用户可能在确认窗口打开期间暂存了更多文件，执行范围必须重新确认。
- **在界面层各写一份依赖与重试规则。** 未采用。规则会在不同端之间漂移，应只保留 Core 的一份实现。

## 后果

- Git 没有跨仓库事务，已成功的提交不会因后续失败而回滚。
- 提交钩子失败可能留下已更新的父引用暂存项，重试前必须重新读取状态。
- 自动联动只覆盖工作区已发现的仓库，不推断未打开的外部父仓库。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/core -run 'TestWorkspaceCommitScopeProtectsStagedChanges' -count=1`：验证提交范围保护与暂存状态。
- `scripts/desktop/desktop-go.sh test ./internal/core -run 'TestWorkspaceRepositoryDiscoveryUsesCoreRules' -count=1`：验证仓库发现规则。
- 多仓库确认与重试接入后，需用真实仓库、子模块和推送失败场景做端到端验收。
- Core 侧的计划、依赖排序与重试测试位于 [Lithe-core-rust `rust/crates/git/src/workspace_commit`](https://github.com/Lithe-IDEA/Lithe-core-rust/tree/main/rust/crates/git/src/workspace_commit)。

## 适用范围

- `desktop/internal/workbench/commit.go`
- `desktop/internal/workbench/commit_view.go`
- `desktop/internal/core/changelists.go`
- `desktop/internal/core/changelists_test.go`
- `desktop/internal/core/repository_discovery_test.go`
- `shared/platform-feature-matrix/features/git-submodule-commit-plan.json`
