# Agent 笔记：本地 Git 变更列表与提交范围保护

状态：已实现

## 先说结论

本地变更列表（ChangeList）把同一工作区的文件改动分组，例如把仅供本机使用的配置放在单独列表。
macOS 与 Windows 都提供原生列表界面，提交范围的检查由同一套 Rust Core 负责。
列表不会改变文件内容或 Git 暂存区：批量暂存只作用于当前列表，其它列表已有暂存文件时，提交会报错并要求用户明确处理。

## 问题

只把文件按标题分组，不能防止顶部“全部暂存”或提交工作区所有索引内容时带入本地配置。
只检查界面最后一次刷新也不够，外部 Git 可以在刷新后暂存文件、重命名文件或改变父仓库引用。
把“移动列表”实现成自动取消暂存会破坏用户的部分暂存结果，因此不能这样做。

## 决策

- 列表名称、当前选择和文件归属属于本地界面状态；Windows 沿用 Zustand 状态库与 WebView 存储适配器，macOS 通过 Git 模块的存储接口注入偏好存储适配器。两端仅将用户分组投影成允许或排除路径，Core 独占提交是否安全的判断。按工作区路径隔离列表；文件归属同时包含所属仓库根和仓库相对路径，工作树和同名文件不串组。
- 默认列表接收未分配的新路径。用户选择的当前列表限定本次批量暂存和提交范围；新建列表不会自动搬入已有文件。支持创建、重命名、删除确认，以及右键将多选文件移动到其它列表，Windows 的目录菜单同时支持移动目录内文件。macOS 按仓库、列表分组展示文件，原未跟踪文件保留各行的新增状态。
- 勾选仍是真实 Git index（暂存区）状态。单文件和分组勾选可以操作对应文件；仓库级和顶部批量按钮只影响当前列表。提交说明生成和文件数量只使用当前列表的已暂存文件。
- 文件变干净后保留路径归属，避免配置再次修改就回到默认列表。Git 报告重命名时，沿用原路径的归属并记住新路径；手动移动重命名同时记录两端。源路径归属优先于目标路径的历史记录；复制是新路径，移动副本不会改动源文件的归属。不会通过扫描磁盘或相似文件内容推断重命名，未被状态观察到的历史重命名不保证恢复归属。
- Core 的可选 `pathScope` 是本次提交的允许或排除路径快照。默认列表排除其它列表的路径，自定义列表只允许分配给自身的路径；路径是字面值，不是 Git 通配符。
- Core 重新读取每个仓库的真实暂存路径，且关闭重命名合并以同时检查删除和新增路径。任何范围外的暂存文件或自动父引用更新都会阻止整个准备阶段。已有的 HEAD、索引内容检查和写锁继续防止准备后状态变化。
- 提交开始后固定列表快照，确认变化时需要再次确认；重试沿用原范围，不能借重试放宽范围。批次尚未完成时停用列表管理，避免界面暗示另一个范围。用户可以关闭父引用联动来单独提交自定义列表中的子仓库改动。
- 元数据格式或版本损坏、读取或保存失败时阻止后续暂存和提交，保留原存储数据，不静默恢复为空列表，也不退回只能临时保存的内存存储。

正确示例：把 `application.yaml` 放到“本地配置”，保持默认列表为当前列表，全部暂存只勾选业务代码；若配置已经被外部工具暂存，Lithe 提示先取消其勾选。
不要仅过滤可见文件后执行普通全索引提交，也不要用 `git commit --only` 代替索引提交：它可能取工作树内容，带入用户尚未暂存的编辑。

## 考虑过的备选方案

- 平台独立计算提交计划：不采用。原生端保留符合各自框架的列表选择和持久化，两个适配器使用同一份范围夹具；提交准备、父引用、确认、续接和重试规则只在共享 Core 实现。
- `assume-unchanged` 或 `skip-worktree`：不采用。这些 Git 标记改变工作树检查行为，不能表达本地任务分组，也不应作为防止误提交的保证。
- 为每个列表维护独立索引或临时改写真实索引：不采用。会增加部分暂存、钩子、冲突和失败恢复的风险。当前保留真实索引，仅拒绝范围不符的提交。
- 仅靠前端禁用按钮：不采用。共享 Core 也检查刚读取的状态、父引用与续接状态，快捷键和过期界面都不能绕过。

## 后果

列表按完整文件路径工作，不支持将同一文件的不同修改块分配到不同列表。
当前列表提交前，用户需要取消其它列表的暂存勾选；Lithe 不自动整理索引。列表删除后，原文件归入默认列表，确认提示明确告知其可能被默认列表的批量暂存包含。
Windows 元数据存于现有 WebView 用户数据中的 `git-local-changelists-v1` 键；macOS 通过 `MacGitChangelistStorage` 保存到用户偏好的 `lithe.git.local-changelists.v1:` 工作区键，由 Git 模块通过接口读写；生命周期跨重启，仅保存在本机，不写入仓库、app bundle 或安装目录，不影响签名和 Sparkle delta。
本次不新增下载、解压、构建缓存或可复用资源目录；这些可变用户偏好不能作为 worktree 构建资源复制或共享。
未传 `pathScope` 的旧客户端保留原提交行为。两端目标系统上的原生界面、构建及安装包验收仍待运行验证；代码存在不等于功能矩阵的 verified。

## 验证

- `macos/Tests/LitheGitModuleTests/GitLocalChangelistsTests.swift`：共享范围夹具、持久化序列化、重命名保留、仓库隔离与元数据校验。
- `macos/Tests/LitheGitModuleTests/GitModuleTests.swift`：原生列表管理、当前列表批量暂存、提交范围传递、确认与重试固定范围、存储故障阻止提交。
- `macos/Tests/LitheTests/MacGitChangelistStorageTests.swift`：偏好持久化、工作区隔离、损坏数据保留和写入失败。
- `macos/Tests/LitheTests/GitChangeSectionsCacheTests.swift`：移动文件后缓存重新分组并保留所有列表可见。
- `./scripts/test-macos.sh` 与 macOS 稳定性计时入口需在固定的 Swift 6.3.3 工具链运行。

- `windows/tauri/src/features/git/stores/git-changelists.store.test.ts`：持久化、干净路径保留、工作区/仓库/工作树隔离、重命名、损坏与保存失败、共享范围夹具。
- `windows/tauri/src/features/git/components/status/git-workspace-status-panel.test.tsx`：批量暂存保护与单分组勾选。
- `windows/tauri/src/features/git/components/git-commit-panel.test.tsx`：按钮、快捷键与范围传递。
- `rust/lithe-core/src/git/workspace_commit/tests.rs`：列表限制、父引用、确认变化、重试和续接校验。
- `rust/lithe-core/src/tests/git_workspace_commit.rs`：真实 Git 拦截范围外暂存、不改变索引和工作树、保留部分暂存、刷新前重命名。
- `shared/fixtures/git/local-changelist-scope-v1.json`：前端范围生成与共享 Core 使用相同样例。
- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh --platform all`。
- `./scripts/verify-windows-boundaries.sh`、`./scripts/verify-shared-contracts.sh`、`./scripts/verify-runtime-bundle-immutability.sh`、`./scripts/verify-agent-notes.sh`、`./scripts/verify-platform-feature-matrix.sh`。

## 适用范围

- `macos/Sources/LitheGitModule/Models/GitLocalChangelists.swift`
- `macos/Sources/LitheGitModule/Application/GitFeatureModel+Changelists.swift`
- `macos/Sources/LitheGitModule/Application/GitFeatureModel+WorkspaceCommit.swift`
- `macos/Sources/Lithe/Platform/MacOS/Storage/MacGitChangelistStorage.swift`
- `macos/Sources/Lithe/Views/Git/GitChangelistBar.swift`

- `windows/tauri/src/features/git/stores/git-changelists.store.ts`
- `windows/tauri/src/features/git/utils/git-changelists.ts`
- `windows/tauri/src/features/git/components/git-changelist-bar.tsx`
- `windows/tauri/src/features/git/components/status/git-status-panel.tsx`
- `windows/tauri/src/features/git/components/git-commit-panel.tsx`
- `rust/lithe-core/src/git/workspace_commit/path_scope.rs`
- `rust/lithe-core/src/git/commit_state.rs`
- `shared/contracts/rust-core-api.md`
