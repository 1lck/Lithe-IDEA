# Agent 笔记：Windows 文件树右键 Git 菜单（Show Diff / Add / Commit File）

状态：已实现

日期：2026-09-30

关联：[Issue #975](https://github.com/1lck/Lithe-IDEA/issues/975)

## 先说结论

Issue #975 的作者希望像 IntelliJ IDEA 一样在右键菜单里直接做 Git 比对和添加提交。调研发现 Windows 端的 Diff 视图、暂存与提交的底层链路（`git-diff-api` / `git-status-api` → `tauri-core` → `lithe-core` 的 `git.write`）全部现成，缺的只是文件树右键入口，因此本次只做"接线"：在文件树右键增加 `Git` 子菜单（Show Diff / Add / Commit File…），目录右键增加 Show Diff（路由到源代码管理变更面板），不新增任何 Tauri command、不改动 `platform.rs`。issue 中提到的"文件关键词搜索"诉求由既有的 Ctrl+Shift+F 项目搜索满足，属于入口未被发现，不在本次实现范围。

## 问题

在 #975 之前，Windows 端提交或比对单个文件的唯一路径是：打开源代码管理面板 → 在变更列表里找到该文件 → 点它或勾选它。当工作区同时修改了多个文件时，"只提交/只看这一个文件"的操作路径太长；文件树右键只有仓库根目录有 Git 子菜单（Log/Fetch/Pull/Push/New Branch），单文件没有任何 Git 动作。issue 作者因为找不到比对入口，甚至误以为产品缺少该能力。

## 决策

文件树右键的 Git 动作全部复用既有 API 层函数，菜单纯逻辑抽成独立 lib 以便单测；按文件的实际 Git 状态决定菜单项可见性（干净文件不显示 Git 子菜单）。

### 正确做法

- 菜单构建的纯逻辑放在 `windows/tauri/src/features/file-explorer/lib/file-context-menu-git-file-items.ts`：`getExplorerGitFileMenuCapabilities()` 决定可见性（无变更条目 → 全部隐藏；已暂存 → 隐藏 Add，因为重复暂存是空操作），`buildGitFileContextMenuItems()` 输出 `Git` 子菜单。单测同目录 `.test.ts`。
- 右键打开时异步解析 Git 上下文：`resolveRepositoryForFile()` 定位所属仓库（支持嵌套仓库），`getGitStatus()` 取该文件状态条目，解析完成后菜单增量出现（`use-file-explorer-context-menu.tsx` 内的 effect）。
- Show Diff 复用 `use-git-diff-data.ts` 的虚拟 buffer 约定：`diff://unstaged|staged/<repo 相对路径>`，打开前先试工作区差异、为空再退回暂存区差异，未跟踪文件走 `getWorkingTreePathDiff()`。
- Commit File… = 先 `stageFile()` 暂存该文件，再 `selectRepository()` + `toggleSourceControlSidebar()` 聚焦源代码管理面板——暂存区即只含该文件，复用现有提交流程，不新做提交对话框。
- 目录右键 Show Diff = `resolveRepositoryPath()` 定位所属仓库后路由到源代码管理变更面板，不新做逐目录 Diff 视图。

### 不要这样做

- 不要为这些动作新增 Tauri command 或改 `platform.rs` 中央分发器——现有 `git_diff_file` / `git_add` 通道已覆盖，新增会违反"不为每个 Core 操作新增 command"的边界规则。
- 不要绕过 `@/features/git/api/*` 直接在菜单里 `tauriInvoke`——通信必须收敛在 API 层。
- 不要对干净文件显示禁用态的 Git 菜单项——产品原则是显式失败而非摆设入口（`find-in-folder` 空桩就是反例，本次未处理，另行跟进）。

## 考虑过的备选方案

### 备选方案一：同步从 `workspaceGitStatus` 读状态

最有吸引力的理由是零 IPC、菜单即时出现。没有采用：它只覆盖工作区根仓库，多仓库/嵌套仓库下的文件会查不到状态导致菜单静默消失，且快照可能过期。

### 备选方案二：复用 `useGitDiffActions` 的 `viewFileDiff`

最有吸引力的理由是行为与 Git 面板完全一致。没有采用：该 hook 需要 `gitFileByPath`、`workingTreeDiffEntriesByScope` 等只在 Git 视图内存在的输入，把它拖进文件树会制造跨模块的重量级依赖；轻量打开路径采用与 AI 工具调用展示（`tool-call-display.tsx`）相同的 `getFileDiff` + `openBuffer` 模式。

### 备选方案三：新做单文件提交对话框

最有吸引力的理由是完全复刻 IDEA 的 `Commit File...` 弹窗。没有采用：提交面板（暂存列表 + AI 提交信息 + 多仓库提交计划）已是成熟流程，右键只负责"把该文件送进暂存区并聚焦面板"，避免出现第二套提交 UI。

## 后果

- 收益：单文件比对/暂存/提交从"打开面板找文件"变为一次右键；多仓库工作区同样可用。
- 代价：右键后 Git 子菜单有约一次 IPC 往返的延迟才出现（菜单先开、Git 项增量挂载）。
- 需要重新评估的触发条件：若后续要求右键目录直接展示该目录范围的 Diff 视图，或要求撤销/历史/blame 入口，应重新评估是否升级为完整的目录 Diff 管线而不是路由到面板。
- macOS 端同一能力仍为 partial（文件树仅有条件性 Show Git Diff，无 Add/Commit），对齐时以本笔记的复用清单为参照。

## 验证

- `cd windows/tauri && bun test src/features/file-explorer/lib/file-context-menu-git-file-items.test.ts`
- `cd windows/tauri && bun run typecheck`
- `./scripts/verify-windows-boundaries.ps1`
- `node scripts/generate-platform-feature-matrix.mjs && ./scripts/verify-platform-feature-matrix.sh`
- 实机：对修改/未跟踪/已暂存/干净四类文件右键，核对菜单可见性与三个动作的结果（矩阵 `git-explorer-context-actions` 条目的 verification 字段）。

## 适用范围

- `windows/tauri/src/features/file-explorer/hooks/use-file-explorer-context-menu.tsx`
- `windows/tauri/src/features/file-explorer/lib/file-context-menu-git-file-items.ts`
