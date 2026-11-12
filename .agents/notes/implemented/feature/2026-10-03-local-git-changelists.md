# Agent 笔记：本地 Git 变更列表与提交范围保护

状态：已实现

> Viva 迁移状态（2026-11-11）：Viva 的 Commit 面板已接入本地 ChangeList，含列表栏（当前列表下拉、新建、重命名、删除、更新父仓库引用）、按列表分组的变更区、右键“移动到更改列表”和弹窗。归属、重命名跟随和提交范围由 Core 的 `git.changelists` reducer 计算，提交请求带 Core `pathScope`；宿主只做保存，并以 `statusGen` 丢弃过期投影。
> 保存按仓库绝对根分文件，放在应用数据目录（`git-changelists-<根哈希>.json`），不写入发行包。每次写入前都重读并比较，与其他窗口冲突时最多重试三次，不覆盖更新的值；读不出或版本、根不符时整套列表停用，禁止全部暂存、提交和 AI 生成，原文件保持不动。
> 新建列表不带走已有文件，删除需确认且文件回到默认列表，父仓库引用默认开启。重试提交沿用上次计划的范围，不再传 `pathScope`。
> 尚未迁移：多选和目录批量移动、Windows 设置页的显示开关，以及差异读取或 AI 生成期间切换列表时丢弃旧结果。旧客户端的说明见下文，不代表 Viva 的行为。

## 先说结论

本地变更列表（ChangeList）把同一工作区的文件改动分组，例如把仅供本机使用的配置放在单独列表。
macOS 与 Windows 都提供原生列表界面，提交范围的检查由同一套 Rust Core 负责。
列表不会改变文件内容或 Git 暂存区：批量暂存只作用于当前列表，其它列表已有暂存文件时，提交会报错并要求用户明确处理。

## 问题

只把文件按标题分组，不能防止顶部“全部暂存”或提交工作区所有索引内容时带入本地配置。
只检查界面最后一次刷新也不够，外部 Git 可以在刷新后暂存文件、重命名文件或改变父仓库引用。
把“移动列表”实现成自动取消暂存会破坏用户的部分暂存结果，因此不能这样做。

## 决策

- 双端的普通批量暂存与提交范围说明放在 ChangeList 选择器的悬停提示中，不常驻占用文件列表高度；Windows 配置不可用等实际错误仍以 `alert` 显示。缩减说明只改变呈现，不改变暂存与提交范围校验。
- 列表名称、当前选择和文件归属属于本地界面状态；Windows 沿用 Zustand 状态库与 WebView 存储适配器，macOS 通过 Git 模块的存储接口注入偏好存储适配器。两端把持久化快照及变更身份交给 Core 的纯 reducer；列表操作、校验、文件归属、重命名和提交范围由 Core 统一计算，平台只负责存储和批量投影渲染。按工作区路径隔离列表；文件归属同时包含所属仓库根和仓库相对路径，工作树和同名文件不串组。
- macOS Worktrees 的更改页复用同一列表管理及范围检查，但模型固定在选中工作树的唯一根目录，不发现同级或嵌套仓库。主工作区根也出现在 Worktrees 时，两处共享该存储键的列表值和故障状态；linked 工作树使用独立键。主提交与工作树提交互斥，提交在途不允许另一处修改同根列表或启动批量暂存；详情标签切换保留各自草稿，工作区重置使旧模型失效。
- Windows 每个工作区使用独立的持久化键；每次动作在同源 Web Lock 内重新读取、调用 Core 并只写目标工作区，锁等待有上限，锁不可用或 Core 失败时关闭操作；禁止用窗口内存中的整个工作区表覆盖共享存储。Web Lock 的同源语义见 [W3C Web Locks](https://w3c.github.io/web-locks/)。macOS 在 Core 计算后及暂存、提交前核对持久化快照，其他窗口变化时停止操作而不覆盖新值。旧版整表按工作区读取，第一次保存写入新键，旧键保留为迁移备份；新键损坏不能回退到旧快照。存储事件和窗口重新获得焦点时刷新当前工作区，刷新监听由视图创建并在卸载时移除。
- 默认列表接收未分配的新路径。用户选择的当前列表限定本次批量暂存和提交范围；新建列表不会自动搬入已有文件。支持创建、重命名、删除确认，以及右键将多选文件移动到其它列表，Windows 的目录菜单同时支持移动目录内文件。macOS 按仓库、列表分组展示文件，原未跟踪文件保留各行的新增状态。
- 勾选仍是真实 Git index（暂存区）状态。单文件和分组勾选可以操作对应文件；仓库级和顶部批量按钮只影响当前列表。提交说明生成和文件数量只使用当前列表的已暂存文件。macOS 在读取差异前保存分组选择版本和当前暂存路径集合，读取完成和 AI 返回时都重新核对；切换分组（包括切走再切回）或修改文件归属后丢弃旧结果。
- 文件变干净后保留路径归属，避免配置再次修改就回到默认列表。Git 报告重命名时，沿用原路径的归属并记住新路径；手动移动重命名同时记录两端。源路径归属（包括目录继承和隐式默认）优先于目标路径的历史记录；复制是新路径，移动副本不会改动源文件的归属。不会通过扫描磁盘或相似文件内容推断重命名，未被状态观察到的历史重命名不保证恢复归属。
- Core 的可选 `pathScope` 保留旧版允许或排除路径，并附上按仓库 ID 分组的完整归属规则；提交时对真实暂存路径重新解析精确路径、最近目录和显式默认覆盖，保护快照之后新增并暂存的文件。路径是字面值，不是 Git 通配符。
- Core 重新读取每个仓库的真实暂存路径，且关闭重命名合并以同时检查删除和新增路径。任何范围外的暂存文件或自动父引用更新都会阻止整个准备阶段。已有的 HEAD、索引内容检查和写锁继续防止准备后状态变化。
- 提交开始后固定列表快照，确认变化时需要再次确认；重试沿用原范围，不能借重试放宽范围。批次尚未完成时停用列表管理，避免界面暗示另一个范围。用户可以关闭父引用联动来单独提交自定义列表中的子仓库改动。
- 元数据格式或版本损坏、读取或保存失败时阻止后续暂存、提交和 AI 说明生成，保留原存储数据，不静默恢复为空列表，也不退回只能临时保存的内存存储。

正确示例：把 `application.yaml` 放到“本地配置”，保持默认列表为当前列表，全部暂存只勾选业务代码；若配置已经被外部工具暂存，Lithe 提示先取消其勾选。
不要仅过滤可见文件后执行普通全索引提交，也不要用 `git commit --only` 代替索引提交：它可能取工作树内容，带入用户尚未暂存的编辑。

## 考虑过的备选方案

- 平台独立计算提交计划：不采用。原生端保留符合各自框架的列表选择和持久化，两个适配器使用同一份范围夹具；提交准备、父引用、确认、续接和重试规则只在共享 Core 实现。
- `assume-unchanged` 或 `skip-worktree`：不采用。这些 Git 标记改变工作树检查行为，不能表达本地任务分组，也不应作为防止误提交的保证。
- 为每个列表维护独立索引或临时改写真实索引：不采用。会增加部分暂存、钩子、冲突和失败恢复的风险。当前保留真实索引，仅拒绝范围不符的提交。
- 仅监听跨窗口存储事件后继续覆盖整张表：不采用。事件送达前两个窗口都可能持有旧快照；独立工作区必须使用独立写入键。
- 仅靠前端禁用按钮：不采用。共享 Core 也检查刚读取的状态、父引用与续接状态，快捷键和过期界面都不能绕过。

## 后果

列表按完整文件路径工作，不支持将同一文件的不同修改块分配到不同列表。
当前列表提交前，用户需要取消其它列表的暂存勾选；Lithe 不自动整理索引。列表删除后，原文件以显式默认归属覆盖上层目录，确认提示明确告知其可能被默认列表的批量暂存包含。
Windows 元数据存于现有 WebView 用户数据中以 `git-local-changelists-workspace-v1:` 开头的工作区键，旧的 `git-local-changelists-v1` 整表只作为迁移读取来源；macOS 通过 `MacGitChangelistStorage` 保存到用户偏好的 `lithe.git.local-changelists.v1:` 工作区键，由 Git 模块通过接口读写；生命周期跨重启，仅保存在本机，不写入仓库、app bundle 或安装目录，不影响签名和 Sparkle delta。
本次不新增下载、解压、构建缓存或可复用资源目录；这些可变用户偏好不能作为 worktree 构建资源复制或共享。
Windows 提供两个独立的 Git 设置：`showGitChangelists` 和 `showGitParentReferences`，默认都开启，只出现在 Windows，macOS 没有对应设置。关闭 `showGitChangelists` 会隐藏 ChangeList 选择器、新建/重命名/删除按钮和变更树里的列表分组节点，并把所有变更视为默认列表：当前列表、“其它列表已暂存”的提交保护和 `pathScope` 都按空分配计算，因此不再缩小提交范围。已保存的分配不会被删除，重新开启后继续生效；关闭期间存储不可用的提示也不再阻止提交。关闭 `showGitParentReferences` 只隐藏栏里的“更新父仓库引用”勾选，提交时按默认值开启处理，不会因为看不到选项而让引用更新悄悄关闭。提交确认面板里的父仓库引用开关不受这两个设置影响。
未传 `pathScope` 的旧客户端保留原提交行为。两端目标系统上的原生界面、构建及安装包验收仍待运行验证；代码存在不等于功能矩阵的 verified。

## 验证

- ~~`macos/Tests/LitheGitModuleTests/GitLocalChangelistsTests.swift`~~（已随 #1794 移除）：共享范围夹具、持久化序列化、重命名保留、仓库隔离与元数据校验。
- ~~`macos/Tests/LitheGitModuleTests/GitModuleTests.swift`~~（已随 #1794 移除）：原生列表管理、当前列表批量暂存、提交范围传递、确认与重试固定范围、存储故障阻止提交。
- ~~`macos/Tests/LitheTests/MacGitChangelistStorageTests.swift`~~（已随 #1794 移除）：偏好持久化、工作区隔离、损坏数据保留和写入失败。
- ~~`macos/Tests/LitheTests/CommitWorkflowChangelistTests.swift`~~（已随 #1794 移除）：用有界测试闸门控制差异读取和 AI 返回，在选择变化后阻止旧说明回填或弹出替换确认。
- ~~`macos/Tests/LitheTests/GitChangeSectionsCacheTests.swift`~~（已随 #1794 移除）：移动文件后缓存重新分组并保留所有列表可见。
- 旧客户端的 [macOS 测试入口](https://github.com/1lck/Lithe-IDEA/blob/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/scripts/macos/test/test-macos.sh) 和稳定性计时结果不能代替 Viva 验收。

- ~~`windows/tauri/src/features/git/stores/git-changelists.store.test.ts`~~（已随 #1794 移除）：两个已初始化实例交错保存后第三个实例重载、旧格式迁移、加载前禁用保护、干净路径保留、工作区/仓库/工作树隔离、重命名、损坏与保存失败、共享范围夹具。
- ~~`windows/tauri/src/features/git/components/status/git-workspace-status-panel.test.tsx`~~（已随 #1794 移除）：批量暂存保护与单分组勾选。
- ~~`windows/tauri/src/features/git/components/git-commit-panel.test.tsx`~~（已随 #1794 移除）：按钮、快捷键与范围传递。
- `rust/lithe-core/src/git/workspace_commit/tests.rs`：列表限制、父引用、确认变化、重试和续接校验。
- `rust/lithe-core/src/tests/git_workspace_commit.rs`：真实 Git 拦截范围外暂存、不改变索引和工作树、保留部分暂存、刷新前重命名。
- `shared/fixtures/git/changelists-reducer-v1.json`：Core 和两端适配器验证同一归属及范围结果；旧 `local-changelist-scope-v1.json` 保留旧客户端契约。
- `scripts/desktop/desktop-go.sh test -race ./internal/core -run 'Test(ChangeListsUseSharedMembershipAndScope|WorkspaceCommitScopeProtectsStagedChanges)' -count=3 -timeout=90s`：macOS 使用共享 fixture 和临时 Git 仓库验证 Core 范围、未出现在快照中的已分配文件、准备后暂存变化与 HEAD/索引不变；不是 Viva 界面或 Windows 验收。
- `scripts/desktop/desktop-go.sh test ./internal/workbench -run TestChangeLists -count=1`：Viva 界面用真实 Git 验证只提交当前列表、其他列表已暂存时拦截并提示、重名被拒后弹窗保持、删除归还默认列表、列表文件损坏时停用且不覆盖；不是 Windows 实机验收。
- 异步投影、跨窗口锁、过期状态和关闭后结果丢弃有受控回归；真实 Git 测试覆盖投影后新暂存的目录文件及显式默认覆盖。
- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh --platform all`。
- 旧版 [Windows 边界检查](https://github.com/1lck/Lithe-IDEA/blob/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/scripts/windows/verify/verify-windows-boundaries.sh)和 [共享契约检查](https://github.com/1lck/Lithe-IDEA/blob/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/scripts/architecture/verify-shared-contracts.sh)尚无完整 Viva 等价门禁；当前仍需运行 `./scripts/desktop/verify/verify-runtime-bundle-immutability.sh`、`./scripts/agent-notes/verify-agent-notes.sh` 和 `./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`。

## 适用范围

- `desktop/internal/workbench/commit.go`
- `desktop/internal/workbench/changelists.go`
- `desktop/internal/workbench/changelists_view.go`
- `desktop/internal/core/gitcommit.go`
- `desktop/internal/core/changelists.go`
- `shared/platform-feature-matrix/features/git-local-changelists.json`
- Lithe-core-rust 锁定修订：[rust/lithe-core/src/git/workspace_commit/path_scope.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/git/workspace_commit/path_scope.rs)
- Lithe-core-rust 锁定修订：[rust/lithe-core/src/git/commit_state.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/git/commit_state.rs)
- `shared/contracts/rust-core-api.md`
- [旧客户端的列表实现与原适用范围（历史版本）](https://github.com/1lck/Lithe-IDEA/blob/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/.agents/notes/implemented/feature/2026-10-03-local-git-changelists.md)
