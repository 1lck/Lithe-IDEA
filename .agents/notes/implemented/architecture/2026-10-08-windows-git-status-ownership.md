# Agent 笔记：Windows Git 状态按仓库统一管理

状态：已实现

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
  元数据监听覆盖全部已知仓库；重新安装或卸载时释放每个监听标识。
  顶部与文件树的全局状态刷新延续原先始终更新的行为，Commit 自动刷新设置仍控制
  面板额外的分支、stash 等读取，不再使顶部保留旧状态。
- 原始记录及相同投影复用对象，重复的相同快照不会反复重建文件列表。
  仓库查询失败保留最后一次成功记录并记录错误，不能把失败当作干净工作区。
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

## 后果

顶部、Commit 和文件树看到的分支及文件变化由同一次发布决定。
多仓库的原始记录和展示投影仍占用各自内存，但不会独立查询或成为另一个可写真源。
新增 Git 状态消费者应读仓库状态表或已有投影，不能恢复旧的两个独立 setter。

## 验证

- 状态存储回归覆盖外部 checkout 的原子发布、启动／Commit 迟到读取、多仓库路径、
  工作区重置、提交草稿保留和相同快照不通知。另有交错回归：完整读取先开始、纯状态发布先
  完成，随后释放的操作状态（冲突解除或新增冲突）仍被发布，且旧文件快照不回退。
- 宿主、滚轮动画和滚轮归属测试已列入 `ci-windows.yml` 的显式执行清单，并出现在逐项计时报告中。
- 全局宿主回归只挂载宿主、不挂载 Commit，验证外部事件合并、同步计数归零、
  无关仓库不查询、卸载清理；使用可手动推进的计时器。
- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.ps1`
- `./.agents/skills/write-stable-tests/scripts/test-stability-windows.ps1 -Scope Frontend`
- `./scripts/verify-windows-boundaries.ps1`
- `./scripts/build-windows.ps1 -Configuration Release`
- `./scripts/verify-runtime-bundle-immutability.sh`
- 真实 Windows 产品中关闭 Commit，外部 pull、checkout、暂存，再核对顶部、文件树和
  重开 Commit；测试多仓库、工作树与快速切项目。原生交互验收继续为 pending。

## 适用范围

- `windows/tauri/src/features/git/stores/git.store.ts`
- `windows/tauri/src/features/git/runtime/git-status-refresh-host.tsx`
- `windows/tauri/src/features/git/runtime/git-metadata-watch-host.tsx`
- `windows/tauri/src/features/git/hooks/use-git-data-controller.ts`
- `windows/tauri/src/features/workspace/services/workspace-git-bootstrap.ts`
- `windows/tauri/src/features/layout/components/footer/footer-git-branch-item.tsx`
