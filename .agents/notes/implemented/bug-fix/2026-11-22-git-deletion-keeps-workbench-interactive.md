# Agent 笔记：Git 删除期间保持工作台可操作

状态：已实现

## 先说结论

用户确认删除分支或移除工作树后，确认弹窗立即关闭，Git 写入在后台继续。相关删除入口在任务结束前保持禁用，编辑、导航和其他工具窗口可以继续使用。

## 问题

Git 命令已经在后台执行，但运行中的确认弹窗继续截获工作台输入。远程分支删除会等待网络，工作树移除也可能耗时。两种情况都会让用户在等待期间无法直接操作工作台。

## 决策

- 提交确认时捕获仓库、目标和所选操作，关闭弹窗，然后使用项目所属的后台任务执行。分支删除在当前项目仍有效时发布结果和刷新列表。
- 对未合并分支或有本地改动的工作树，仍以 Git 返回的结构化拒绝为依据，进入明确的强制确认。分支删除完成后如果用户打开了另一项分支操作或切换了分支弹窗所属仓库，结果通过通知反馈，已有弹窗保留。
- 执行结束前继续禁用同一类删除入口。确认弹窗关闭和后台任务结束各自有独立的状态，普通关闭动作不用于提交删除。

例如，确认删除远程分支后可以立即点「项目」，删除完成后再读取更新的引用。要让工作台保持可用，等待期间应释放整个模态弹窗，只禁用它的按钮仍会挡住下面的工作台。

## 考虑过的备选方案

- 在确认弹窗内加进度条和取消按钮。该做法仍会捕获工作台输入，因而保留了原问题。
- 取消确认后直接强制删除。Git 首次拒绝时需要让用户审阅本地改动和目标，原有的额外确认步骤仍有必要。

## 后果

用户可在 Git 等待期间切换面板，删除的结果仍由原来的结果视图和通知反馈。操作遇到 Git 的保护条件时，继续删除需要一次单独的确认动作。

## 验证

- `TestGitDeletionKeepsWorkbenchInteractive` 在后台操作停在可控等待点时向「项目」按钮发送真实点击，断言第一次点击即触发切换。继续执行后检查远程引用或工作树记录已删除。
- `TestGitDeletionFailureLeavesNewBranchDialogOpen` 在远程删除等待时打开新建分支弹窗，验证后来返回的失败只发通知并保留草稿。
- `TestLogForceDeleteRequiresSecondConfirmation` 和 `TestWorktreesRemovalOfAChangedCheckoutAsksToForce` 验证两个强制确认流程。无头截图入口为 `TestVisualGitDeletionInProgress`。

## 适用范围

- `desktop/internal/workbench/branch_delete.go`
- `desktop/internal/workbench/gitlog_view.go`
- `desktop/internal/workbench/gitworktree.go`
