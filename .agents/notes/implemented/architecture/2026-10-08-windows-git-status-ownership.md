# Agent 笔记：Windows Git 状态按仓库统一管理

状态：已实现

> Viva 迁移状态：下文描述旧 Windows 客户端的仓库状态表与监听。Viva 当前只展示当前项目的 Git 状态，并在打开项目和部分 Git 操作后读取；尚无等价的多仓库状态表与全局 Git 元数据监听，同一项目内读取乱序风险跟踪 [#1809](https://github.com/1lck/Lithe-IDEA/issues/1809)，不能把旧客户端的刷新保证当作已迁移。旧实现和测试入口见[迁移前笔记](https://github.com/1lck/Lithe-IDEA/blob/5a54c41aa37a4e6e6b68918a4b05765b9dd07a36/.agents/notes/implemented/architecture/2026-10-08-windows-git-status-ownership.md)。

## 先说结论

Windows 的顶部、Commit 面板和 Project 文件树使用同一个工作区内的仓库状态表。
外部 pull、checkout 或暂存后，全局监听刷新这张表；关闭 Commit 面板不会停止状态更新。
各界面仍可以使用适合自己的文件路径，但不能独立保存或发布另一份分支和同步计数。

## 问题

之前顶部优先读取 Commit 面板留下的 `gitStatus`，全局监听却只更新
`workspaceGitStatus`。例如旧分支落后三次提交，外部拉取并切到已同步的新分支后，
工作区已经读到零，顶部仍显示旧的 incoming 箭头。

简单把顶部改读工作区状态也不充分：Commit 支持多个仓库和用户选择的活动仓库，
Project 文件树则需要主目录所属仓库的原始相对路径。互相覆盖会丢失文件归属。

## 决策

- `git.store.ts` 的 `repositoryStatuses` 是仓库状态的唯一真源。键为查询仓库路径，
  值保留 Core 返回的分支、领先／落后数和原始文件记录。
- 启动读取、Commit 读取和全局刷新都通过同一个发布入口及请求版本规则更新状态。
  请求版本用于判断结果的新旧：较新的结果已经发布后，旧读取不能恢复旧分支、计数或暂存状态。
  切仓库、清空工作区和重置时推进版本，防止旧会话迟到结果写入。
- 操作状态（merge、rebase、冲突）只由 Commit 的完整读取提供，使用独立的已发布水位线，
  只在操作状态真正发布时推进。全局宿主的纯状态发布只推进文件状态水位线，因此不会淘汰
  更早开始、尚未返回的完整读取所带的操作状态；而比已发布操作状态更旧的结果仍被拒绝。
  两条水位线共用同一个版本计数器，切仓库和重置时同时推进。
- 顶部直接读取所选仓库的原始记录。保留 `gitStatus` 和 `workspaceGitStatus` 作为
  兼容界面投影（从状态表一次性生成的展示结果），移除独立写入它们的动作。
  单仓库时两个投影可直接使用同一个对象；多仓库 Commit 聚合文件并保留
  `repositoryPath` 和仓库相对路径，Project 投影保留主目录原始路径。
- `GitStatusRefreshHost` 随主布局运行，监听全部已发现仓库的变更并合并读取。
  元数据监听由应用级控制器按存活工作区运行实例维护，覆盖主根、附加根及已知仓库；
  切换活动项目不释放。移除根、关闭实例或窗口才撤销对应注册。窗口身份由原生注入，
  每个仓库拥有独立注册 ID，规范路径共享底层监听，防止同窗多仓库相互覆盖。
  重新安装使用新 ID，迟到完成仍须回收；安装失败等待后续成员变化或焦点恢复重试。
  打开仓库子目录时同时监听其祖先规则目录；仓库链接变化重建观察并刷新策略。
  顶部与文件树的全局状态刷新延续原先始终更新的行为，Commit 自动刷新设置仍控制
  面板额外的分支、stash 等读取，不再使顶部保留旧状态。
- 原始记录及相同投影复用对象，重复的相同快照不会反复重建文件列表。
  仓库查询按根独立收集结果，由共享 `git.workspaceStatusMerge` 计划新快照、保留旧快照或未知状态；
  失败根不能视为干净，也不能确认暂存操作。移除的根不得从旧状态复活，提示显示结果可能过期。
  宿主仍按工作区版本水位线原子发布，过期结果不能覆盖后来的状态或失败标记。
- 不新增持久化目录、下载资源或运行时写入路径；状态及监听标识只属于工作区生命周期，
  不影响发行包、代码签名或增量更新。

正确做法：外部 checkout 触发全局刷新，一次发布后顶部和 Commit 都看到新分支。
不要这样做：顶部比较两个缓存的更新时间，或在分支菜单里手动同步两个独立状态。

参考 IntelliJ Community 本地修订 `fb72b4df43aba102479eb0502d20b03586b9c5b8`：
`GitRepositoryUpdater.kt` 更新项目仓库服务，`GitWidgetApiImpl.kt` 订阅仓库和同步状态事件。
macOS 顶部通过 `AppModel.currentBranch`，Commit 通过 `GitFeatureModel.currentBranch`
读取同一个模型；工作区观察回调执行 `refreshGitFromMetadataChange()`。
macOS 顶部尚未显示同步箭头，此处只参考其状态归属。

## 考虑过的备选方案

- 顶部永远读旧工作区快照：只能修复单仓库场景，活动仓库切换及多仓库文件列表仍不一致。
- 根据时间戳选一份缓存：仍有两份真源，无法证明旧异步请求不会覆盖较新结果。
- 关闭面板时清空缓存：会丢失可复用的文件状态，重新打开前仍无法共享状态。
- 给每个 UI 分别增加监听：重复维护刷新规则，资源生命周期继续依赖可见面板。
- 文件状态与操作状态共用一条版本水位线：纯状态刷新先发布后，较早开始的完整读取所带的
  操作状态会被一并丢弃，冲突横幅停在旧值，继续按钮保持禁用。

### Git 事件分类的跨平台归属

Git 指针、规则文件、共享引用、当前 worktree 的 index、其他 worktree 的私有
状态，以及 objects、LFS 和临时提交目录，由 Core 的纯函数统一分类。子模块的 Git
状态位于 `modules`，其 HEAD 或 index 会影响父仓库 gitlink，因此该目录的事件
在尚无明确子模块根身份时保守地刷新，不能整体过滤。Windows
原生监听器直接调用该函数；macOS 本地与远程监听器按事件批次分页调用同一契约，
不逐条跨桥。仅有当前 worktree index 写入的批次刷新工作区 Git 状态，不额外重拉历史与
worktree 列表；macOS 的既有状态读取仍会附带 stash 等查询。合并过程中出现其他相关事件时提升为完整元数据刷新。原生丢失事件和根目录变化仍由宿主优先处理；分类失败时保守地重扫并
重新检查监听根。被排除的嵌套工作树及工作区可见性仍由工作区层管理。远程源文件
与 Git 元数据混在一个批次时，必须同时保留工作区路径与元数据刷新标志。
这项决策不创建缓存或写入发行包；共享 fixture 和两端宿主测试覆盖分类边界，
真实产品、远程工作区及高频事件的端到端验收仍需单独执行。

## 后果

顶部、Commit 和文件树看到的分支及文件变化由同一次发布决定。
多仓库的原始记录和展示投影仍占用各自内存，但不会独立查询或成为另一个可写真源。
新增 Git 状态消费者应读仓库状态表或已有投影，不能恢复旧的两个独立 setter。

## 验证

以下是旧客户端的历史验证，Viva 接入监听与多仓库后需要重新验证乱序、关闭面板和外部 Git 操作。

- 状态存储回归覆盖外部 checkout 的原子发布、启动／Commit 迟到读取、多仓库路径、
  工作区重置、提交草稿保留和相同快照不通知。另有交错回归：完整读取先开始、纯状态发布先
  完成，随后释放的操作状态（冲突解除或新增冲突）仍被发布，且旧文件快照不回退。
- 宿主、滚轮动画和滚轮归属测试已列入 `ci-windows.yml` 的显式执行清单，并出现在逐项计时报告中。
- 全局宿主回归只挂载宿主、不挂载 Commit，验证外部事件合并、同步计数归零、
  无关仓库不查询、卸载清理；使用可手动推进的计时器。
- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.ps1`
- `./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope Frontend`
- 旧版 Windows 边界及发行构建脚本已随旧客户端移除，历史命令见上方迁移前笔记。
- `./scripts/desktop/verify/verify-runtime-bundle-immutability.sh`
- 真实 Windows 产品中关闭 Commit，外部 pull、checkout、暂存，再核对顶部、文件树和
  重开 Commit；测试多仓库、工作树与快速切项目。原生交互验收继续为 pending。

## 适用范围

- Lithe-core-rust 锁定修订：[rust/lithe-core/src/git/metadata_watch.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/git/metadata_watch.rs)
- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/fixtures/git/metadata-classification-v1.json`
- `desktop/internal/workbench/git.go`
- `desktop/internal/workbench/commit.go`
- `desktop/internal/workbench/filetree_watch.go`
- `shared/platform-feature-matrix/features/git-status-commit.json`
