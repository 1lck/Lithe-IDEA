# Agent 笔记：工作区多仓库提交计划与重试

状态：已实现

## 先说结论

Changes 中的勾选继续代表 Git 的暂存状态；用户一次提交，系统按文件所属仓库分别执行。
真正的子模块关系以 Git 索引中的引用条目（gitlink，记录子仓库提交号）为准，提交子仓库时默认联动更新已打开工作区内的父引用。
确认前重新检查计划；执行失败保留已完成步骤，重试只做剩余提交或推送。
macOS 和 Windows 都直接消费 Rust Core 的提交计划、依赖排序、失败传播、重试及 Git 检查写入；平台只负责界面和原生接线。

## 问题

只有目录包含关系，不能证明两个仓库互相依赖。真正的子模块中，父仓库管理的是提交号，子仓库才管理 `hello.ts` 的内容。
只读取有暂存文件的仓库会遗漏干净的父仓库；确认后直接重算并执行会悄悄改变用户同意的范围；推送失败后再次提交则会重复创建提交。

## 决策

- 已发现的独立嵌套仓库不会作为父仓库的未跟踪目录参与勾选，避免“全部暂存”意外创建子模块引用。比较前必须统一规范化 Git 返回的路径和平台传入的仓库绑定，兼容 macOS 目录别名及 Windows 短路径/扩展路径。
- Windows 的文件及仓库分组勾选也写入真实暂存区，取消原有仅限单仓库的提交入口。部分暂存文件的提交预览和 AI 说明只读取索引；工作树差异仍可从差异菜单查看。
- 保留暂存区作为选择的唯一来源，外部 `git add` 也会反映到勾选状态。没有另建一份仅属于 UI 的提交选择。
- macOS 的待确认暂存状态不能假设变更标识唯一。例如 `git rm --cached example.txt` 保留磁盘文件后，Git 同时返回暂存删除和未跟踪文件，两条记录拥有同一标识。保留真实记录，按标识分组核对；所有记录都符合请求的暂存状态后才清除界面的待确认值，避免打开项目闪退或旧快照提前确认操作。如果文件恢复干净并从完整快照消失，也要清除待确认值，否则后续操作会一直被阻止。不要用要求键唯一的字典构造器，也不要只保留第一条或最后一条记录，这会让结果依赖返回顺序。
- Core 读取 Git 的 porcelain v2 状态，把子模块提交号变化和未提交文件分开。只有文件脏、引用未变的父条目展示提示，不参与批量勾选。
- Core 读取所有已发现仓库的真实引用，再计算子到父的执行顺序。默认自动带上必要的父引用；确认窗口显示仓库、文件、顺序和引用更新，并允许关闭本次自动联动。
- Core 的提交前置状态包括 HEAD、当前分支、索引对象号和暂存路径。确认时重新传入最新仓库列表，任何状态变化都更新计划并再次确认；实际写入前仍在已有仓库写入锁内核对。
- 读取提交状态和写入子引用前确认 Git 的真实根目录。子仓库元数据消失时拒绝执行，避免 Git 向上搜索后错用父仓库。
- 更新父引用使用 Git 的精确索引更新命令，只写已经确认的子提交号。父仓库其它未暂存文件保持原样。
- Core 每次最多执行一次提交或推送，返回由 Core 管理的进度。平台只负责确认界面、原生认证与取消、项目生命周期、展示结果和继续调用；不得自己安排仓库、推导失败范围或重算重试。
- Windows 按工作区保留 Core 返回的结果，任务生命周期由工作台持有，切换侧栏不停止批次；离开项目时取消当前原生请求并停止派发后续步骤，迟到结果只能更新原工作区的恢复记录。
- 每个仓库提交或推送有独立的执行上下文。停止当前操作后继续独立仓库，依赖失败子仓库的父仓库等待重试。
- 只选择父引用时，已发现且有本地分支的子仓库会显示为“仅推送”，不会重复提交。父仓库推送还通过 Git 自带的子模块发布检查，拒绝引用尚未发布的子提交；分离 HEAD 无法确定推送分支时保留失败供用户处理。
- 结果按仓库保留。已提交但未推送的仓库重试时只推送；已成功的独立仓库不会再提交。重试也先展示当前计划，项目切换后旧异步结果不能写回界面或启动后续仓库操作。

正确示例：只勾选 `A/libs/B/hello.ts`，计划显示先提交 B，再只更新 A 中的 `libs/B` 引用；如果选择推送，B 推送成功后才执行 A。
不要在 A 中 `git add --all` 来更新 B 的引用，这会把 A 的其它未选择文件一并提交。

## 考虑过的备选方案

- 独立于暂存区的提交勾选：没有采用。会改变已有勾选含义，且外部暂存、部分暂存都需要第二套同步规则。
- 停止一个操作就结束整个批次：没有采用。无依赖仓库可以继续完成；只有依赖的父引用必须阻塞。
- 确认后静默执行重算的计划：没有采用。用户可能在对话框打开期间暂存更多文件，执行范围必须重新确认。
- 把 Git 命令输出解析放在 Swift：改为共享 Core 的类型化状态，保持 Git 自身为索引和引用的事实来源。
- 只共享 Git 原语，把提交计划留在 Swift：没有采用。Windows 会被迫重复实现依赖和重试规则；现在两个端都直接消费 Core 生成的计划和下一步结果。
- 在 Core 中维护常驻批次注册表：没有采用。当前只需要项目会话内恢复，使用无后台资源的 JSON 续接状态即可；每一步仍以真实 Git 状态校验防止重复提交。

## 后果

Git 的多个仓库没有跨仓库原子事务，已成功的提交不会因后续失败而回滚。Lithe 的写入锁只能约束自己的命令，外部 Git 客户端不参与该锁。
提交钩子失败可能留下已经更新的父引用暂存项；重试必须重新读取状态。取消后的只读核对有独立的 5 秒上限，返回已完成提交的信息，不能用通用取消错误覆盖它。结果仅保留在当前项目会话中，退出项目或显式清除结果后不提供恢复记录。
自动联动仅覆盖工作区已发现的仓库，不推断未打开的外部父仓库。读取某个仓库失败时停止建立计划，不能把读取失败当成没有依赖。
不改变 Git Log 的已有分组和活动仓库规则。

## 验证

- `windows/tauri/src/features/git/services/git-workspace-commit-workflow.test.ts` 消费同一份共享夹具，验证计划转发、再次确认、重试、取消与迟到响应；`git-workspace-status-panel.test.tsx` 验证分组勾选写入所属仓库、忽略不可暂存的脏子模块引用。Tauri dispatcher 测试保护原生认证超时与部分结果透传。

- `macos/Tests/LitheGitModuleTests/GitModuleTests.swift` 消费共享夹具和预设 Core 响应，验证确认与再次确认、联动选项与重试转发、步骤驱动、复选框资格和项目切换隔离；不在测试替身中重新实现业务算法。
- 同文件暂存删除和未跟踪记录的回归用例覆盖两种返回顺序、首次与重复状态刷新，以及暂存和取消暂存都要等待全部记录确认；`macos/Tests/LitheTests/GitStatusObservationTests.swift` 通过真实 Git → Rust Core → Swift 状态刷新验证打开仓库时不闪退，实际执行暂存或取消暂存后，干净状态正确结束待确认操作。旧快照用例继续保护单记录场景。
- `rust/lithe-core/src/git/workspace_commit/tests.rs` 覆盖干净祖先联动、关闭联动、独立嵌套仓库、过期计划、失败依赖阻塞、仅重推和外部推进后再次推送。
- `rust/lithe-core/src/tests/git_workspace_commit.rs` 使用真实 Git 验证过期索引拒绝、子模块状态、只更新引用且不带入父文件、首次提交前取消暂存保留后续编辑，暂存后在工作树删除的文件仍可见、子仓库元数据被删除后拒绝回退父仓库，以及共享夹具序列化。真实 Git 还验证共享计划执行、推送失败后的重试、过期步骤重放拒绝、取消与成功提交返回竞争。
- 使用 `write-stable-tests` 的 Rust 逐例计时入口生成 HTML/JUnit；macOS 使用该 Skill 的 macOS 计时入口。
- 运行共享契约、服务边界、功能矩阵、发行包只读边界和 Agent Notes 检查。
- 当前实现环境是 Linux；本地执行共享 Core 和 Windows 前端测试，原生构建及测试交给对应 CI，macOS/Windows 界面实测仍需平台验收，不将逻辑测试通过记作界面已验证。

## 适用范围

- `macos/Sources/LitheGitModule/Application/GitFeatureModel+WorkspaceCommit.swift`
- `macos/Sources/LitheGitModule/Application/GitFeatureModel.swift`
- `macos/Sources/LitheGitModule/Models/GitModels.swift`
- `macos/Sources/LitheGitModule/Services/GitService.swift`
- `macos/Sources/Lithe/Views/Git/CommitAreaView.swift`
- `macos/Sources/Lithe/Views/Git/ChangesSidebarView.swift`
- `rust/lithe-core/src/git/commit_state.rs`
- `rust/lithe-core/src/git/workspace_commit.rs`
- `macos/Sources/LitheGitModule/Models/GitWorkspaceCommitModels.swift`
- `shared/contracts/rust-core-api.md`

- `windows/tauri/src/features/git/services/git-workspace-commit-workflow.ts`
- `windows/tauri/src/features/git/components/git-workspace-commit-review.tsx`
- `windows/tauri/src/features/git/components/status/git-status-panel.tsx`
- `windows/tauri/src-tauri/src/platform.rs`
