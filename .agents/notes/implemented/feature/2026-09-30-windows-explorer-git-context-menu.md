# Agent 笔记：Windows 文件树右键 Git 菜单

状态：已实现

关联 Issue #975。

## 先说结论

Issue #975 要右键直接比对和提交单个文件。Windows 端 Diff、暂存、提交的底层链路都已存在，本次只加文件树右键入口（文件：Git 子菜单 Show Diff / Add / Stage and Open Commit…；目录：Show Diff），不新增 Tauri command。issue 的搜索诉求由既有 Ctrl+Shift+F 满足，未扩展。

## 问题

此前比对或提交单个文件只能打开源代码管理面板、在变更列表里找；文件树右键没有任何单文件 Git 动作。

## 决策

- 菜单纯逻辑放 `windows/tauri/src/features/file-explorer/lib/file-context-menu-git-file-items.ts`（能力判定 + 构建 + 虚拟路径契约），单测同目录。
- 右键时异步解析所属仓库与状态（`resolveRepositoryForFile` + `getGitStatus`），支持嵌套仓库；干净文件不显示 Git 菜单，只有已全部暂存且无剩余工作区修改时隐藏 Add；MM/AM 部分暂存仍显示 Add。显式暂存整文件会包含剩余编辑，原有复选框保留部分暂存的语义不变。
- Show Diff 以 `createSingleFileWorkingTreeDiff` 载荷打开 `diff://working-tree/all-files`，`workingTreeTargets` 显式携带所属仓库，首次打开与后续刷新都比较 HEAD 到完整工作区内容，并保留 hasStagedChanges 以限制不安全的块丢弃；后续刷新/切换按 target.repoPath 重读，不再拿工作区根猜仓库（多仓库安全，PR #989 review 意见③）。Stage and Open Commit…（暂存并打开提交）先暂存该文件再打开源代码管理提交面板，复用现有提交流程；面板提交的是当前暂存区全部内容而非仅该文件，动作按此语义命名（PR #989 review 意见①）。
- 只准调 `@/features/git/api/*`；禁止为这些动作新增 Tauri command 或绕过 API 层直接 invoke。

## 考虑过的备选方案

- 同步读 `workspaceGitStatus`：只覆盖工作区根仓库，嵌套仓库下菜单会静默消失，弃用。
- 复用 `useGitDiffActions.viewFileDiff`：需要 Git 视图内部的大量输入，拖进文件树过重，弃用。
- 新做单文件提交对话框：与既有提交面板重复，弃用。

## 后果

- 收益：单文件比对/暂存一次右键完成，并可直达提交流程，多仓库可用。
- macOS 端已按 reviewer 邀请对齐（Git 子菜单装 Add 与 Stage and Open Commit…，Show Diff 复用既有独立菜单项不重复；可见性判定在 `GitFileContextMenuPlan`，多参考了既有 `canToggleStaging` 门禁）。
- 代价：Git 子菜单在菜单弹出后约一次 IPC 往返才出现（Windows）。

## 验证

- `cd windows/tauri && bun test src/features/file-explorer/lib/file-context-menu-git-file-items.test.ts`
- `cd windows/tauri && bun run typecheck`；`./scripts/verify-windows-boundaries.ps1`
- `node scripts/generate-platform-feature-matrix.mjs && ./scripts/verify-platform-feature-matrix.sh`
- 实机点检项见矩阵 `git-explorer-context-actions` 条目的 verification 字段。

## 适用范围

- `windows/tauri/src/features/file-explorer/hooks/use-file-explorer-context-menu.tsx`
- `windows/tauri/src/features/file-explorer/lib/file-context-menu-git-file-items.ts`
