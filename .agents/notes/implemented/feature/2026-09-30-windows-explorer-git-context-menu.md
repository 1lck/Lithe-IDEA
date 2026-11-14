# Agent 笔记：文件树右键的 Git 菜单

状态：已实现

关联 Issue #975。

## 先说结论

文件树右键菜单为单个文件提供 Git 子菜单（Show Diff、Add、Stage and Open Commit…），目录只提供 Show Diff。菜单的显示由文件的真实 Git 状态决定：干净的文件不显示 Git 菜单，已完全暂存且没有剩余工作区修改的文件不显示 Add。所有动作只经过已有的 Git 操作入口，不为菜单新增单独的命令。

## 问题

要比对或提交单个文件，只能打开源代码管理面板再在变更列表中查找。文件树右键没有任何单文件 Git 动作，而嵌套仓库中的文件也需要能找到它所属的仓库。

## 决策

- **菜单可见性由文件所属仓库的真实状态决定。** 右键时解析文件所属仓库（支持嵌套仓库）并读取状态，再决定显示哪些项。
- **部分暂存的文件仍显示 Add。** 整文件暂存会包含剩余的工作区修改，所以“Add”的语义是暂存整个文件，而非仅暂存已勾选的块。
- **Show Diff 比对该文件的完整工作区内容。** 差异目标显式携带所属仓库，后续刷新按该仓库重读，不能用工作区根目录猜测仓库。
- **Stage and Open Commit… 先暂存该文件，再打开提交面板。** 面板提交的是当前暂存区的全部内容，而不是仅该文件，因此动作名称按这一语义命名。
- **不新增 Git 命令。** 菜单只调用既有 Git 操作入口。

## 考虑过的备选方案

- **只读取工作区根仓库的状态。** 未采用。嵌套仓库下菜单会静默消失。
- **复用 Git 视图内部的差异动作。** 未采用。需要 Git 视图内部的大量输入，拖进文件树过重。
- **新做单文件提交对话框。** 未采用。与既有提交面板重复。

## 后果

- 单文件的比对与暂存可以在文件树中一次完成，并能直接进入提交流程，嵌套仓库也能正常使用。
- 代价是右键后需要一次状态读取，菜单的 Git 子项会比其它菜单项晚出现。

## 验证

- `scripts/desktop/desktop-go.sh test ./internal/workbench/ -count=1`：覆盖文件树菜单与 Git 动作的构建。
- 在真实仓库中验收：干净文件无 Git 菜单；部分暂存文件仍有 Add；嵌套仓库中的文件比对到正确仓库。

## 适用范围

- `desktop/internal/workbench/filetree_git_menu.go`
- `desktop/internal/workbench/filetree_menu.go`
- `desktop/internal/workbench/gitexplorer_actions.go`
- `shared/platform-feature-matrix/features/git-explorer-context-actions.json`
