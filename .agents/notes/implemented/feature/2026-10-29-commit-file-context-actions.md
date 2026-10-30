# Agent 笔记：提交文件菜单与插件 VCS 文件操作

状态：已实现

## 先说结论

macOS Commit 和 Worktrees 的文件右键菜单补齐提交文件、回滚、普通差异、新标签差异、删除与添加到 VCS。
右键目标取被点击行及其所在多选集合，不把行高亮等同于提交复选框。
插件提供的版本控制系统（VCS，例如 SVN）必须处理自己的添加和已跟踪文件删除；删除先显示明确范围的确认窗口，取消不改文件。
Git 删除后先确认并发布对应仓库状态；已暂存的新文件还需要清除其残留索引记录，不能只移走磁盘文件。

## 问题

菜单缺少常用操作时，用户必须逐个打开文件或切到外部工具。
把“添加到 VCS”当作 Git 暂存的别名会漏掉 SVN 等系统；把跟踪删除退回普通磁盘删除会绕过插件的版本记录。
删除目录还可能跨越嵌套仓库、删除编辑器中尚未同步的内容，或在工作区切换后继续执行旧请求。

## 决策

### 上游依据与已有能力

参考 IDEA Community revision `0698a5fe297dfa08069f015cc423a6a85ed7fc60`：

- `platform/vcs-impl/src/com/intellij/openapi/vcs/changes/actions/ScheduleForAdditionAction.kt`
  只处理未版本化文件，按所属 VCS 调用添加接口，不固定成 Git 命令。
- 同目录 `ScheduleForRemovalAction.java` 把受版本控制的删除交给对应系统；
  `RollbackDialogAction.java` 将所选更改送入回滚确认流程。
- 同目录的兼容入口 `AbstractCommitChangesAction.kt` 限制所选变更列表并转发提交动作，
  不是另建无确认的即时提交器。

Lithe 复用既有 `VcsOperation.add/delete`、Provider 能力协商及根归属判断，不新建 SVN 命令执行器，
也不改变插件契约。普通和新标签差异的生命周期见
[编辑器标签分屏](../architecture/2026-10-12-editor-tab-split-docking.md)，
Git 提交准备见[工作区提交计划](2026-09-27-workspace-git-commit-plans.md)，
批量回滚见[回滚确认范围](2026-10-29-git-rollback-confirmation.md)。

### 目标、能力与所有权

- 右键选中集合中的行时作用于该集合；右键集合之外的行时只作用于被点击文件。
  Git 的添加只暂存未跟踪目标。插件的添加只允许全部目标为未版本化状态，并要求 `fileOperations` 能力。
- 插件已跟踪文件删除使用同一能力下的 `.delete`；未版本化文件使用 macOS 废纸篓。
  Provider 拒绝或失败时不退回磁盘删除，缺少能力时菜单禁用。
- 发出请求前检查根、状态快照、路径和忙状态；异步根归属检查返回后再次检查工作区代次与根集合。
  目录内部存在其他已识别或归属歧义的根时拒绝递归操作；根发现被截断时不假定未返回的区域安全。
- Git 删除在执行前重新发现实际仓库，阻止确认期间才出现的嵌套仓库或 linked worktree 被整目录移走。
  这是已发现范围的保护，不是与外部客户端之间的原子文件系统锁。

### 删除确认与编辑器保护

`CommitFileDeletionFeatureModel` 保存不可变的确认目标和单次请求身份；视图只负责展示路径、取消和确认。
确认同步消费同意并声明忙状态，再允许原生窗口关闭；取消、被替换或已使用的请求不能重放。

目录目标先去重、合并子项，拒绝根目录本身和根外路径。叶子符号链接可移走，父目录解析后必须仍在确认根内。
先排空目标编辑器的待处理输入，再检查未保存修改、工作区生命周期、最新资格和取消状态。
存在脏文档或脏后代时拒绝删除，不代替用户保存或丢弃。
每次原生废纸篓操作前重新检查，首错停止；成功后只关闭相应的干净文档并刷新。
已跟踪的插件删除只派发一次确认批次，成功导致状态项消失不能反过来阻止清理干净文档。

Git 的废纸篓操作不会改索引（Git 保存待提交内容的位置）。删除已暂存的新文件后，Git 仍会报告
“暂存新增、磁盘已删除”，所以 Commit 会继续显示绿色行。删除动作完成后，仅对本次确认中的新增目标
重新读取状态；只有 Git 确认它仍是新增且磁盘已删除，才取消暂存。复制只清除目标，不影响源文件的独立编辑。
即使废纸篓批次中途失败，也对已经消失的新增目标做这一处理；保留未删除目标、普通跟踪文件的删除记录和无关索引内容。
状态读取失败时保留现有行并报告需刷新确认，不能直接从界面隐藏文件来伪装成功。

对应仓库的确认状态先更新 Commit、Worktrees 和已打开 Diff，再允许文件监听继续更新项目树与项目服务。
不能把其他仓库扫描、历史或 Stash 刷新放在文件状态发布之前。具体异步顺序见
[Git 执行与项目控制台](../architecture/2026-09-12-git-execution-and-project-console.md)。

正确示例：在 SVN 未版本化列表多选 A、B 后添加，宿主向 SVN Provider 发送一次排序去重的 `.add`。
不要这样做：把 A、B 传给 Git 暂存，或在 SVN 删除失败后用 `removeItem` 强行删掉文件。

## 考虑过的备选方案

- 删除后直接隐藏所选行：不采用。已跟踪文件的删除仍是需要提交的真实变更，隐藏会让视图与 Git 不一致。
- 删除整个批次后统一清空索引：不采用。会破坏普通文件的部分暂存以及未删除或无关文件的待提交内容。

- 只补菜单文案：无法实现所承诺动作，尤其插件仍没有添加入口，不采用。
- 统一用磁盘删除：破坏已跟踪文件的 VCS 语义，不采用；普通磁盘删除仅用于 Git 或未版本化文件的废纸篓流程。
- 弹窗关闭后再从当前高亮读取删除目标：范围可随用户操作变化，也无法撤销已取消的请求，不采用。
- 自动保存全部脏文件再删除：会未经用户同意写入草稿，不采用；同步输入后仍有修改就要求用户先处理。
- 为插件比较另开覆盖层：绕过普通标签、取消和分屏清理，不采用。

## 后果

用户得到完整可执行的菜单，插件仍是自己版本控制语义的唯一执行者。
代价是含嵌套或歧义工作副本的目录需要拆开选择，脏编辑器必须先由用户处理。
多文件删除没有跨文件事务；进行中的一次原生废纸篓调用不能被中途撤销，但取消后不再派发后续删除。
Provider 自身负责服务器与工作副本的原子性，宿主不保证其批次一定全成或全败。
这些动作只使用平台文件接口、现有插件协议和会话状态，不新增 bundle 写入、下载或共享缓存。

## 验证

- `macos/Tests/LitheTests/VcsProviderHostTests.swift`：真实菜单回调、精确排序批次、能力缺失、嵌套和歧义根、
  异步所有权过期、操作互斥与重置后的迟到结果；同文件的 `VcsProviderAppModelTests` 覆盖新标签请求生命周期。
- `macos/Tests/LitheTests/CommitFileDeletionTests.swift`：取消、替换、同意重放、同步输入后脏/过期/取消/失败，
  Provider 批次、首错停止和干净文档清理；原生窗口 Escape/关闭及实际按钮分别验证取消和确认。
- `macos/Tests/LitheTests/GitStatusObservationTests.swift`：真实 Git 仓库中的提交准备、废纸篓动作前新嵌套仓库保护；
  删除后清理缺失新增项、部分失败时保留未删除项、保留普通跟踪删除与无关部分暂存，以及复制来源保护。
- `macos/Tests/LitheGitModuleTests/GitModuleTests.swift`：本次操作的根先发布状态、不等待工作区解冻、
  不扫描同级仓库；竞争写入、旧快照、跨根批次部分请求替代、父/子模型独立展开及迟到结果、读取失败和重置隔离。
- 使用 `write-stable-tests` 的 macOS 计时入口生成逐项 HTML/JUnit；中英文明暗截图用携带当前语言、字体和图标的临时宿主。
- `./scripts/architecture/verify-service-boundaries.sh`、`./scripts/architecture/verify-shared-contracts.sh`、
  `./scripts/macos/verify/verify-runtime-bundle-immutability.sh`、`./scripts/agent-notes/verify-agent-notes.sh`、
  `./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh` 和共享 i18n 检查。
- fake Provider 与原生组件不替代真实 SVN 插件整机验收；Windows 未实现这些新增 macOS 入口，矩阵验证保持 pending。

## 适用范围

- `macos/Sources/Lithe/Application/Features/CommitFileDeletionFeatureModel.swift`
- `macos/Sources/Lithe/Application/Features/VcsProvidersFeatureModel.swift`
- `macos/Sources/Lithe/Models/AppModel/AppModel+GitOperations.swift`
- `macos/Sources/Lithe/Models/AppModel/AppModel+VcsProviders.swift`
- `macos/Sources/Lithe/Views/Git/CommitFileDeletionPresentation.swift`
- `macos/Sources/Lithe/Views/Git/ChangesSidebarView.swift`
- `macos/Sources/Lithe/Views/Git/GitWorktreeChangesView.swift`
- `macos/Sources/Lithe/Views/Vcs/VcsProviderToolWindowView.swift`
