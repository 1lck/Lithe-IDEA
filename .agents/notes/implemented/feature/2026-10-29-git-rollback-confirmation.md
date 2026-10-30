# Agent 笔记：Git 批量回滚的确认范围

状态：已实现

## 先说结论

macOS 提交面板复用原来的弯箭头按钮，先打开可重新勾选文件的“回滚更改”窗口，最后确认才改文件。
提交面板的勾选仍表示真实 Git 暂存区；回滚窗口里的勾选只是这次操作的草稿，关闭窗口不写入。
回滚包含已暂存和未暂存内容；新增文件默认只取消暂存，只有明确勾选删除本地副本才删除磁盘文件。

## 问题

旧按钮使用行高亮作为范围，而不是提交复选框中的文件集合，导致勾选多个文件后不能直接批量回滚。
旧的普通丢弃操作只把暂存区内容恢复到磁盘，已经暂存的更改不会恢复到上次提交。
直接把确认文案改成“回滚”会让用户误以为已经恢复全部内容，因此范围和实际 Git 操作必须一起修改。

## 决策

- 参考 IntelliJ Community revision `0698a5fe297dfa08069f015cc423a6a85ed7fc60` 的
  `platform/vcs-impl/src/com/intellij/openapi/vcs/changes/ui/RollbackChangesDialog.kt`。
  上游使用带复选框的文件浏览器，纳入集合与高亮分开；空集合不能确认，新增文件本地删除选项默认关闭。
  本次只参考公开交互和源码，不复制上游窗口实现。
- 顶部按钮限定当前 ChangeList（用户组织文件的本地变更列表）：有已暂存文件时默认纳入这些文件，
  否则使用行多选，再否则纳入当前列表全部文件。右键从其作用范围初始化。窗口中可以增减纳入文件。
- 窗口复用 `LitheCenteredPopup` 的有标题原生确认窗口、`LitheTreeList`、`LitheTreeCheckbox`
  和共享动作按钮。文件按仓库分组，分组框是三态，展开、高亮和纳入分别处理；不另建菜单、列表或按钮样式。
- `GitRollbackSelection` 保存候选文件与纳入标识；`GitFeatureModel` 拥有请求、取消、忙状态和确认动作。
  点击确认先捕获草稿，再关闭窗口，异步执行使用捕获值，不读取已经清空的窗口绑定。
- 确认时检查工作区、请求身份及最新已知文件状态，拒绝被替换或失效的草稿。
  执行期间阻止同模型及 Worktree 提交模型的暂存/提交交错；取消、重置或仓库切换后不派发后续写入。
- 后台全量 Git 读取不占有索引或工作区写权限，因此不能单凭 `isRefreshingGit` 禁用回滚。
  已暂存文件仍能打开确认窗口；确认时继续检查最新已知状态，执行写入使较早状态读取失效，
  防止读请求迟到后把已回滚的行加回来。暂存待确认、提交及其他写操作的互斥条件保持不变。
- 复用共享 Core 的既有 Git 操作：普通文件直接通过 `discardAll` 一次恢复上次提交的暂存区和磁盘内容，
  不再先做一次多余的取消暂存；只有新增文件先取消暂存，再按删除选项保留或调用 `discard` 删除。
  `git add -N` 的意向新增也先清除索引记录。
  重命名携带新旧两个路径；复制记录只操作目标路径，不能取消暂存或恢复源文件的独立更改。
  首个失败停止，保留已有诊断，并重新读取状态；不把部分成功伪装成跨文件事务。
- Git 同时报告“暂存删除”和“保留的未跟踪磁盘副本”时，窗口只保留同标识的已跟踪记录，
  防止把应恢复的删除当作新增文件。已经展开的未跟踪目录使用子项而不是同时保留整目录删除项，
  避免取消某个子项后仍被父项删除。
- Worktrees 更改页复用相同流程，但使用固定在对应工作树根的提交模型，不改变主工作区的暂存区。
  Windows 沿用原有行选择及确认设置控制的回滚入口，本次没有同步这一确认文件树，不宣称界面一致。
- 回滚命令已由后台工作线程执行；可见延迟还来自完成后等待项目服务、无关仓库和重复状态扫描。
  因此先重读本批目标的仓库并发布真实行状态，恢复回滚按钮可用，再调度工作区后续刷新；不先乐观移除行。
  旧的全工作区读取和较早的同根状态请求不能覆盖这次确认结果，工作区重置也必须隔离在途请求。
  Core 的 `discardAll` 状态查询仅扫描所选路径，按命令行预算分批，并把特殊字符当字面文件名；
  不能对每个文件重复枚举整个仓库的未跟踪目录。

正确示例：提交面板勾选 A、B，打开回滚窗口后取消 B，确认只恢复 A 的暂存与磁盘内容。
不要在回滚窗口内调用暂存服务来实现勾选，也不要把当前高亮文件作为最终范围覆盖用户的确认草稿。

## 考虑过的备选方案

- 增加一个“批量回滚”按钮：不采用。现有回滚入口就应该正确处理勾选集合，重复按钮会增加歧义。
- 把提交勾选改成纯界面选择：不采用。会破坏既有真实暂存区语义、外部 Git 同步及部分暂存。
- 保留只列路径的普通确认框：不采用。用户无法在最终确认前排除文件，也不符合上游纳入集合交互。
- 直接对所有目标调用 `discardAll`：不采用。新增路径可能不存在于上次提交，且不能表达默认保留新增文件。
- 新增一套平台 Git 命令执行器：不采用。已有共享 Core 操作和原生执行生命周期足够，保持原有认证、
  命令记录、取消和有界进程控制。
- 只增加后台线程而保留原等待顺序：不采用。Git 已不在主线程执行，文件状态仍会被无关刷新阻塞；
  应调整状态确认与文件监听解冻的先后关系，而不是增加无主后台任务。
- 全量状态读取期间一直禁用回滚：不采用。多根扫描、Stash 或历史读取会让已勾选文件长时间不能操作；
  沿用写入互斥和过期读取保护即可，不把纯查询当作写操作。

## 后果

用户可以一次恢复多个已暂存或部分暂存文件，并在最后一步重新审核范围。
默认不删除新增文件，避免因为它没有历史版本而永久丢失内容；选择删除后仍是不可撤销操作。
多个 Git 写入不是原子事务：中途失败或取消可能已经完成前面的文件，甚至已经取消当前文件暂存。
确认检查的是模型最新已知状态，不提供跨外部 Git 客户端的文件内容锁；不要宣称可阻止外部同时改写。
草稿只在当前窗口和工作区会话中存在，不新增下载、缓存、安装目录写入或跨工作树共享资源。

## 验证

- `macos/Tests/LitheGitModuleTests/GitRollbackSelectionTests.swift`：默认纳入、独立勾选、空集合、同标识删除及目录子项排除。
- `macos/Tests/LitheGitModuleTests/GitModuleTests.swift`：窗口关闭与异步确认顺序、首错停止、忙时互斥、取消、重置及旧请求隔离；
  本地状态先于解冻发布、同级仓库无额外扫描、竞争写入按实际完成顺序确认、Worktree 展开及历史窗口保持；
  有界阻塞同级仓库读取时仍能确认回滚，释放旧读取后已消失的行不会恢复。
- `macos/Tests/LitheTests/LitheCoreLogicTests.swift`：嵌套操作最外层解冻后调度已有刷新，操作不等待项目服务，重置取消后续任务；
  阻塞项目重载时普通文件事件与写入后恢复仍独立刷新 Git，取消的读取不吞掉新请求，旧工作区读取不能释放新读取。
- `rust/lithe-core/src/tests/git_untracked_directories.rs`：回滚状态查询限制所选路径、长参数分批、特殊文件名字面匹配、
  重命名源记录正确解析，以及暂存删除与未跟踪副本同路径时优先恢复历史版本。
- `macos/Tests/LitheTests/GitStatusObservationTests.swift`：真实 Git 经 Core 验证批量恢复暂存区和磁盘、未选文件不变、
  新增及意向新增文件保留/删除、复制来源不变、重命名/删除/保留副本以及 linked Worktree 隔离；
  同一个已挂载 Commit 面板通过真实监听接收外部新增、修改、删除，后台只读未结束时原生回滚按钮可点击，
  打开确认后取消不改变真实索引。
- `macos/Tests/LitheTests/GitRollbackDialogTests.swift`：中英文与深浅主题原生布局、关闭/确认回调、独立重新勾选和空集合禁止确认。
  普通 SwiftPM 宿主不携带产品图标和语言包；截图验收用带当前资源的临时签名宿主运行相同用例，
  检查真实中文按钮及复选框资源，不向已安装程序包写入测试资源。
- `macos/Tests/LitheTests/GitWorktreeAppearanceTests.swift`：没有高亮行时点击工具栏实际打开带标题的审核窗口，
  通过关闭按钮的 Escape 快捷键及原生关闭控件取消，均不派发命令且允许重开；另检查宽窄布局控件可达。
  独立窗口测试通过无障碍接口直接按关闭按钮；隔离宿主的真实子面板不稳定提供 SwiftUI 无障碍节点，
  因而集成用例验证原生响应链，不把它视为完整产品的辅助功能验收。
- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh` 与该 Skill 的 macOS 逐项计时入口。
- `./scripts/macos/test/test-macos.sh`、`./scripts/architecture/verify-service-boundaries.sh`、
  `./scripts/macos/verify/verify-runtime-bundle-immutability.sh`、`./scripts/agent-notes/verify-agent-notes.sh`、
  `./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`，以及共享 i18n 检查。
- 原生组件和真实 Git 测试不能替代完整工作台人工验收；平台矩阵保留 pending。

## 适用范围

- `macos/Sources/LitheGitModule/Models/GitRollbackSelection.swift`
- `macos/Sources/LitheGitModule/Application/GitFeatureModel.swift`
- `macos/Sources/Lithe/Views/Git/GitRollbackDialog.swift`
- `macos/Sources/Lithe/Views/Git/ChangesSidebarView.swift`
- `macos/Sources/Lithe/Views/Git/GitWorktreeChangesView.swift`
