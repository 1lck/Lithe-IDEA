# Agent 笔记：Windows Git Log 多仓库分支分组

状态：已实现

## 先说结论

在 Windows 版里，当一个工作区包含多个 Git 仓库时，Git Log 的引用树按仓库分组：
顶层每个仓库一个可折叠节点（仓库名 + 引用数），节点内部才是 Local / Remote / Tags。
分支数据由前端遍历工作区已发现的仓库分别读取再聚合，Rust Core 的引用与历史命令
仍是单仓库接口，`GitReference` 只在浏览器侧多带一个可选的 `repositoryPath`。
点击其它仓库的分支会把活动仓库切换过去，再加载该分支的历史。

聚合读取必须**串行**：解析仓库路径会执行一条持有"仓库级写租约"的 Git 命令，而该
租约按 Git 公共目录（common dir）加锁。一个仓库的多个链接工作树共享同一个公共目录，
并发解析会互相报 "another Git write operation is running"，导致工作树取不到引用而显示 0 条。

## 问题

工作区（例如 `D:/workspace/work-code/op`）下可以有多个并列仓库，其中 `op-platform`
还带一批链接工作树（`git worktree`，位于 `op-platform/.worktrees/<name>`）。以前的
Windows Git Log 只显示单个活动仓库的分支：

- `git-log-tool-window.tsx` 用 `activeRepoPath ?? rootFolderPath` 作为唯一 `repoPath`，
  `useGitLogController` 只取一个仓库的引用；
- 引用树 (`git-reference-tree.tsx`) 只按 Local / Remote / Tags 分层，没有仓库维度。

结果就是多仓库工作区里"只渲染了部分分支、没有按仓库分组"。

## 决策

### 仓库维度的分组放在前端，不下沉到 Core

Core 的 `git.references` / `git.historyPage` 保持单仓库入参（`root`）。多仓库聚合由
Windows 前端完成：新 hook `windows/tauri/src/features/git/hooks/use-git-workspace-references.ts`
遍历 `availableRepoPaths`，逐个调用现有 `getGitReferences`，给每条引用打上
`repositoryPath`（规范化的仓库根），并按仓库缓存与取消。

理由是：分组是**呈现层**能力，历史分页、游标、diff、控制台都属于活动仓库；把
"列出所有仓库的引用"做成 Core 新命令会把仓库身份这一呈现概念塞进稳定契约。
`GitReference` 的 `repositoryPath` 因此是前端类型里的可选字段，不进 JSON C ABI。

引用树在 `repositoryPaths.length > 1` 时渲染仓库层，折叠状态复用 preferences 里的
`collapsedReferenceGroups`（id 形如 `repo:<规范化路径>`），组内节点 id 带仓库前缀，
避免不同仓库的同名分支共享折叠状态。单仓库时渲染路径与以前完全一致。

### 各仓库的引用串行读取

工作区里的链接工作树共享主仓库的 Git 公共目录。解析仓库路径（前端
`resolveRepositoryPath` → 原生 `git_discover_repo` → Core `git.command` 执行
`rev-parse --show-toplevel`）会持有按公共目录加锁的写租约；若并发解析同一公共目录
下的多个工作树，除第一个外都会失败。因此 hook 按 `availableRepoPaths` **顺序**加载，
首轮和变更刷新都串行。工作树本身是合法仓库（Core 的发现明确返回 `.git` 文件形式的工作树），
修复方向是让读取不互相冲突，而不是把工作树从仓库列表里剔除。

### 点击其它仓库的分支要切换活动仓库

引用树只负责选中，不负责加载历史。选中一条属于非活动仓库的引用时，
`GitLogToolWindow` 先把活动仓库切到该仓库（`selectRepository`），再用一个
pending 引用 ref，在 `repoPath` 变化后的 effect 里调用 `selectReference`。
这样历史的单仓库语义不变，也避免引入"一个窗口同时展示多个仓库历史"的新状态机。

## 考虑过的备选方案

- **在 Core 增加"聚合所有仓库引用"的新命令**：被否。它把呈现层的仓库身份引入稳定
  契约，还要为两个平台同时定义 fixture；每个仓库的引用读取已有命令可复用。
- **在 Core 的 `GitReferenceResponse` 上直接加 `repositoryPath`**：被否。活动仓库由
  应用层决定，Core 不该知道"工作区里有哪几个仓库"。
- **并发读取各仓库引用**：被否，见上文租约冲突。前端最初的 `Promise.all` 会让
  同主仓库的工作树互相失败。
- **让 Core 的仓库发现跳过 `.git` 文件（工作树）**：被否。Core 现有集成测试
  `workspace_repositories_discovers_multiple_child_repositories` 明确要求发现工作树标记，
  契约文档也写明 `.git` 目录和 `.git` 文件都算仓库标记；剔除工作树会破坏该既定行为。

## 后果

- 多仓库工作区现在能一次看到所有仓库的分支，并知道每条分支属于哪个仓库；工作树
  作为独立仓库照常出现，且能看到与主仓库共享的分支。
- 单仓库用户不受影响：引用树不出现仓库层，行为与此前一致。
- 各仓库引用顺序读取，仓库越多总耗时越长；换来的是同一公共目录下不互相抢租约。
- 只在 `repositoryPaths.length > 1` 时走仓库分组与多仓库读取。
- macOS 端尚未做对应的引用树分组，行为与 Windows 暂不一致。

## 验证

- Windows 前端：`tsc --noEmit`；`bun test src/features/git`，含新增的
  `git-reference-tree.test.tsx`（单仓库保持扁平、多仓库按仓库分组）与
  `use-git-workspace-references.test.tsx`。
- Rust 未改动（Core 的仓库发现和引用契约保持原样），`cargo test --manifest-path
  rust/lithe-core/Cargo.toml` 无需针对本改动重跑。
- 手工：在工作区 `D:/workspace/work-code/op` 打开 Git Log，确认仓库分组、工作树
  不再显示 0 条、点击跨仓库分支切换加载，以及单仓库项目无回归。

## 适用范围

适用于 Windows（`windows/tauri/src/features/git/`）的 Git Log 引用树。不改变
`git.references`、`git.historyPage`、`workspace.repositories` 的 JSON 契约；不覆盖
macOS 的引用树分组，也不覆盖左侧 Source Control 的分支切换下拉（仍是单仓库、
仅本地分支）。
