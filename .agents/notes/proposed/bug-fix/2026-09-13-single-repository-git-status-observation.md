# Agent 笔记：单仓库 Git 状态监听与文件系统同步

状态：提议中

## 先说结论

目标是让一个本地 Git 仓库的文件变化最终都能反映到界面上的真实状态。Viva 桌面端已经监听 Git 元数据目录，由 Core 判断变化含义，并合并防抖、在丢事件时整体重扫；仍缺的是把仓库根纳入监听、应用切回前台时的最终恢复、Lithe 内部 Git 写操作的合并刷新，以及无仓库到有仓库的切换。

## 问题

Changes、当前分支、Git Log、stash 和进行中的 merge/rebase 等状态来自单个本地 Git 仓库。本地文件系统的任意一次变化只要会改变这些状态，Lithe 最终都必须重新读取仓库状态并让界面收敛到 Git 的真实结果。

当前桌面端的实现（`desktop/internal/workbench/git_observation.go`）：

- 打开项目时，通过 Core 的 `git.watchContext` 解析 `gitDirectory`、`gitCommonDirectory` 和分支引用目录 `refs/heads`，只监听这几个目录（`app.WatchDirectory`）。
- 收到的只是目录里的文件名。Core 的 `git.classifyMetadataChanges` 判断它们是上下文变化、忽略规则、元数据写入，还是仅 index 写入；只有元数据或忽略规则会刷新状态，非 index 写入还会刷新历史和内联 blame，因此 Git-only 事件不会重建项目树或重载编辑器。
- 防抖约 150 毫秒（`gitObserveDebounce`）；刷新运行时到达的事件只标记等待中，不并发读取，结束后继续刷新直到没有新事件。
- 原生监听报告丢事件（Resync）或目录被替换时，整体重扫并重新监听；上下文变化时停止旧观察并重新解析。
- 工作区文件的显示由项目树的目录监听负责（`filetree_watch.go`），与 Git 元数据观察是两条路径。

仍存在的缺口：

- 元数据监听不包含 `repositoryRoot`。打开的目录是仓库根的子目录，或者 `workspaceRoot` 之外的仓库根部分发生未暂存改动时，只有 Git 元数据目录的写入能间接触发刷新，不能保证收敛。
- 无仓库时（`git init` 之前）不安装任何元数据监听，项目打开后创建仓库需要靠别的路径发现。
- 应用切到后台期间的变化，返回前台时没有统一的最终恢复（重新解析上下文、请求一次 Git 刷新）。
- 当前没有 Lithe 内部 Git 写操作的合并机制；暂存、提交、切换分支时，中间状态可能被显示。

需要建立的核心不变量：对单个本地 Git 仓库，所有由 `workspaceRoot`、`repositoryRoot`、`gitDirectory`、`gitCommonDirectory` 及原生事件恢复信号驱动的状态变化，都必须最终收敛到至少一次读取最终状态的 Git 刷新。短时间内的事件可以防抖合并，但最后一次变化不能被丢弃——不能因为事件过滤、监听范围、事件丢失、刷新并发或 watcher 生命周期而永久保留旧状态。

## 提案

### 需要覆盖的布局

以下布局都会让“只监听工作区目录”的做法失效，实现必须各自覆盖：

- **普通仓库外部 commit**：`.git/index`、`.git/logs/HEAD`、`.git/refs/heads/main` 等会变化，但它们在工作区内的 `.git` 目录里，如果被普通文件的隐藏规则过滤掉，状态就不会更新。Git 相关的分类必须发生在可见性过滤之前。
- **Linked worktree**：独立的 `gitDirectory`（收到 `index`、`logs/HEAD`）和共享的 `gitCommonDirectory`（收到 `refs/heads/<branch>` 等）可能位于两个不同的外部目录，必须分别解析并监听。
- **直接打开 submodule**：submodule 的 `.git` 是地址文件，真实 git-dir 在父仓库的 `.git/modules/**` 中；必须监听解析后的真实 Git 目录。
- **打开 repository root 的子目录**：`repositoryRoot` 内、`workspaceRoot` 外的未暂存文件变化不会写 Git 元数据，因此必须把 `repositoryRoot` 纳入监听范围。
- **separate git-dir**：真实 Git 目录在 `repositoryRoot` 外，不能假设 `repositoryRoot/.git` 存在。

### 范围

覆盖一个 Lithe 项目对应的一个本地 Git 仓库：普通仓库、linked worktree、直接打开的 submodule、打开含 submodule 的父仓库看到的 gitlink 状态、`workspaceRoot` 是 `repositoryRoot` 子目录、`git init --separate-git-dir` 等真实 Git 目录位于工作区外的布局、项目打开后才执行 `git init`、原生事件丢失和监听根变化后的恢复、应用重新获得焦点后的最终状态恢复。

不覆盖：多个独立 Git 仓库的聚合和跨仓库操作、父仓库 Changes 中展开 submodule 内部文件、远端变化但本地未 fetch、自动 fetch 或网络轮询、`~/.gitconfig` 等工作区外配置的实时监听、外部进程使用不同 `GIT_DIR` 形成的另一套 Git 视图、bare repository、多仓库数据模型改造。

### Git 目录拓扑

桌面端持有 `workspaceRoot`；Core 负责解析 Git 自身的三个规范化绝对路径：

| 路径 | 含义 |
| --- | --- |
| `workspaceRoot` | 用户在 Lithe 中打开的目录 |
| `repositoryRoot` | `git rev-parse --show-toplevel` |
| `gitDirectory` | 当前 worktree/submodule 的 Git 目录 |
| `gitCommonDirectory` | 多 worktree 共享的 Git 目录 |

普通仓库中四者要么相等要么是 `repositoryRoot/.git`；linked worktree 的 `gitDirectory != gitCommonDirectory` 且可能都在 `workspaceRoot` 外；直接打开 submodule 时 `gitDirectory` 位于父仓库 `.git/modules/**` 中；打开 repository root 子目录时 `workspaceRoot != repositoryRoot`；separate git-dir 布局下 `gitDirectory` 在 `repositoryRoot` 外。实现不得通过拼接 `repositoryRoot/.git` 推断 Git 目录。

### Core 契约（已实现）

[Core 仓库的 `rust/crates/git`](https://github.com/Lithe-IDEA/Lithe-core-rust/tree/main/rust/crates/git) 提供路径解析和元数据分类：

- `git.watchContext` 返回 `repositoryRoot`、`gitDirectory`、`gitCommonDirectory`，使用绝对路径，存在的路径做规范化，无仓库时返回空上下文。路径通过机器可读命令解析（`git rev-parse --show-toplevel`、`--absolute-git-dir`、`--path-format=absolute --git-common-dir`），不依赖 Git 的自然语言输出，也不由平台代码判断 `.git` 是文件还是目录。
- `git.classifyMetadataChanges` 对一批有序的监听路径分类，结果中每项带 `kind`（上下文、忽略规则、元数据、被忽略、其他）和 `indexOnly`。

桌面端只依据分类决定刷新范围，不自己解析 `.git` 文件。分类规则在 Core 中，收紧分类时仍须保留所有会影响 Git 状态的最终事件：`packed-refs`、reflog、stash refs、split index 的 `sharedindex.*`、merge/rebase/sequencer 状态、未来的 reftable 存储，正确性优先于事件数量。

Context 不是只读一次的永久值，以下情况必须重新解析：首次打开工作区、`.git` 被创建、删除或替换、原生监听报告根变化、worktree repair、submodule init/deinit/update/absorbgitdirs、应用重新获得焦点、Git 刷新发现 repository root 与当前 context 不一致。解析失败时保留工作区监听并把 Git 状态显示为无仓库，允许后续重试。

### 多根监听

监听根包括 `workspaceRoot`、`repositoryRoot`、`gitDirectory`、`gitCommonDirectory`，规范化并去重后可以合并为更少的原生监听。每个逻辑根的角色要保留，用于事件分类：

| 事件位置 | 工作区处理 | Git 处理 |
| --- | --- | --- |
| `workspaceRoot` 内可见路径 | 进入项目树和编辑器流程 | 请求 Git 刷新 |
| `workspaceRoot` 内隐藏路径 | 不进入项目树和编辑器流程 | 仍请求 Git 刷新 |
| `repositoryRoot` 内、`workspaceRoot` 外 | 不进入工作区流程 | 请求 Git 刷新 |
| `gitDirectory` / `gitCommonDirectory` 内 | 不进入工作区流程 | 请求 Git 刷新 |
| Git context 或监听根变化 | 不作为普通文件处理 | 重新解析 context、重建监听并刷新 |

Git 相关分类必须发生在可见性过滤之前：`.git` 对项目树保持隐藏，不等于对 Git 状态监听不可见。当前实现只监听元数据目录；`repositoryRoot` 的纳入是本提案的待办。

### 刷新协调

Git-only 事件独立防抖后只触发 Git 刷新，不触发项目树重建、编辑器外部冲突检测、本地历史或语言服务重载。刷新协调的规则：burst 内多次事件合并，刷新运行期间到达的新事件只标记等待中、不并发读取，当前刷新结束后等待中的事件仍为真则继续刷新，直到一轮刷新期间没有新事件才结束。不能依赖“正在刷新就直接返回”，那样会丢失最终状态请求。当前实现（`scheduleGitObservation` 中的 `running` 标记与 `paths`/`full` 等待集合）已经满足这条规则。

Lithe 内部 Git 写操作（暂存、提交、切换分支等）的合并刷新是本提案的待办：写操作期间，Git 事件只标记等待中，不读取 index 或 worktree 的中间状态；写操作结束后合并为一次最终刷新，且不得因已有的显式刷新去重而丢掉最终刷新。

### 原生事件恢复与初始化顺序

丢事件（Resync）时整体重扫并重新监听，已经实现，不信任不完整的路径列表。监听根变化（上下文变化）时停止旧观察、按新的规范化根集合重建，并执行 Git 最终刷新，不得只对旧路径刷新。

初始化顺序保证不留下漏事件窗口：先安装元数据监听，再读取最终状态。当前实现在解析上下文后先装监听、再标记整体刷新，符合这一顺序。

应用重新获得焦点是最终兜底而非实时监听的替代品：重新解析上下文、上下文变化时重建监听、请求一次 Git 刷新，用于覆盖挂起期间的变化、外接卷短暂断连和其他不可恢复窗口。这一兜底是本提案的待办。

首次没有 Git 仓库时，当前实现不安装元数据监听。本提案要求保留能观察 `.git` 创建的监听，使项目打开后执行 `git init` 能从无 Git 切换为仓库状态，而不必重开项目。具体由工作区监听覆盖还是由单独的监听覆盖，实现时确定。

### 单仓库边界

一个 Git 观察对应一个 `watchContext`。直接打开 submodule 时 submodule 自身是当前单仓库；打开父仓库时父仓库仍是当前单仓库，只同步其看到的 gitlink 状态，不在父仓库 Changes 中聚合 submodule 内部文件。repository root 下的其他独立 `.git` 目录不被发现或聚合，最多触发当前仓库一次无害刷新，不得据此创建第二套 Git 状态；多仓库支持是独立架构工作，超出本设计范围。

### 代码位置

- Core：`git.watchContext` 与 `git.classifyMetadataChanges` 的桌面端客户端在 `desktop/internal/core/git_metadata.go`。
- 桌面端观察与刷新协调：`desktop/internal/workbench/git_observation.go`，Git 状态读取（`loadGit`）和界面更新在 `desktop/internal/workbench/git.go`。
- 项目树的目录监听（工作区可见路径）：`desktop/internal/workbench/filetree_watch.go`，macOS 和 Windows 使用递归监听，其他平台按目录注册并设有数量上限。
- 监听接口由 Viva 提供（`app.WatchDirectory`），桌面端只消费目录事件，不直接调用平台 API。

## 考虑过的备选方案

- **只放宽可见性过滤，让 `.git` 事件通过现有工作区监听。** 改动最小，能修好普通仓库场景。但 linked worktree、submodule 和 separate git-dir 的真实 Git 目录经常位于工作区之外，工作区监听天然覆盖不到，因此不采用。
- **第一版只放行 `index`/`HEAD`/`refs/**` 事件以减少事件量。** 能降低事件处理开销，但会漏掉 `packed-refs`、reflog、stash refs、split index、merge/rebase 状态和未来的 reftable 存储，正确性优先于性能。只有真实性能数据证明必要时才收紧，并保留上面列出的会影响 Git 状态的事件。
- **只依赖应用重新获得焦点时轮询 Git 状态，不做实时监听。** 实现简单，并能兜底挂起期间的变化。但用户在应用保持前台时执行外部 Git 操作，就看不到实时更新，因此焦点恢复只作为兜底，不能替代实时监听。
- **顺带做多仓库 Changes 聚合。** 能一并解决 repository root 下存在独立嵌套仓库的场景，但会把单个 Git 状态改造成仓库集合，是与本设计正交的独立架构工作，因此明确排除，只保证嵌套仓库事件最多触发一次无害刷新。

## 验收标准

| 场景 | 操作 | 预期结果 | 不应发生 |
| --- | --- | --- | --- |
| 普通仓库 | 外部修改普通文件 | Changes 自动出现 unstaged change | 丢失事件 |
| 普通仓库 | `git add` / unstage / reset | staged/unstaged 分组自动更新 | 项目树重建 |
| 普通仓库 | commit / amend | Changes 清空或更新，分支和 Git Log 更新 | 手动刷新 |
| 普通仓库 | fetch / push | 本地 refs 相关 UI 更新 | 工作区重扫 |
| 隐藏但被跟踪的目录 | 修改 tracked 文件 | Changes 自动更新 | 文件出现在项目树中 |
| Linked worktree | add / commit / refs 更新 | 当前 worktree Changes、分支和 Log 更新 | 依赖焦点切换 |
| 直接打开 submodule | add / commit | submodule 自身 Changes 更新 | 依赖父仓库监听 |
| 父仓库含 submodule | submodule HEAD 前进 | 父仓库 gitlink 状态刷新 | 聚合 submodule 内部 Changes |
| 打开 repository 子目录 | 修改子目录外 tracked 文件 | Changes 自动更新 | 把该文件加入项目树 |
| Separate git-dir | index / refs 更新 | Changes 和分支更新 | 假设 `repositoryRoot/.git` 存在 |
| 项目打开后 `git init` | 创建仓库 | 从无 Git 自动切换为仓库状态 | 重开项目 |
| 原生事件丢失 | Resync | 整体重扫并恢复最终状态 | 信任不完整路径列表 |
| 监听根迁移 | 上下文变化 | 重新解析 context、重建监听、刷新 | 继续监听旧路径 |
| 刷新期间再次变化 | 连续两次外部操作 | 最终状态与第二次操作一致 | 第二次请求被丢弃 |
| Lithe 内部 Git 操作 | stage / commit / checkout | 写操作结束后一次最终刷新 | 展示持久中间状态 |
| 应用后台期间变化 | 返回前台 | context 和 Git 状态恢复 | 永久陈旧 |

自动测试至少覆盖：Core 对普通仓库、linked worktree、submodule、separate git-dir 和 repository 子目录的路径解析（在 Core 仓库中使用真实临时 Git 仓库和真实 Git 命令）；桌面端 `desktop/internal/workbench/git_observation_test.go` 覆盖事件分类、Git-only 事件不进入工作区流程、burst 防抖、刷新期间补刷新、Resync 与上下文变化的路由；repositoryRoot 纳入监听、焦点恢复和 Lithe 内部写操作合并三项待办完成后，补充对应测试。

真实场景（上表）需要在 macOS 和 Windows 的真实仓库上手动验证，并记录结果。

## 风险

- 元数据目录不做事件过滤时，objects 和 lock 文件会放大事件数量；如果真实使用中防抖仍不足以合并 burst，需要重新评估收紧策略，但收紧后仍须保留所有会影响 Git 状态的最终事件。
- 原生事件标志中的丢事件和根变化如果遗漏，会重新引入“永久陈旧”的失效；丢事件标志只用于诊断时，正确性依赖整体重扫，如果诊断显示丢事件却没有触发整体重扫，需要重新审视这个假设。
- 监听目录去重如果出错，可能让某个逻辑根的事件被错误分类（例如元数据目录事件被当作普通工作区路径处理），需要对去重后的场景做分类测试，而不能只测试未合并的情况。
- 范围明确排除的多仓库聚合、远端轮询和全局 Git 配置监听，如果后续被并入这次改动，会显著扩大验收面；这些需求出现时应作为独立提案处理，不要就地扩展本 Note。

## 验证

```bash
scripts/desktop/desktop-go.sh test ./internal/workbench/ ./internal/core/
./scripts/desktop/verify/verify-runtime-bundle-immutability.sh
./scripts/agent-notes/verify-agent-notes.sh
```

`desktop-go.sh test` 运行桌面端 Go 测试，涵盖 Git 观察与 Core 客户端的解码；Core 的路径解析和分类测试在 Core 仓库中运行。

## 适用范围

- `desktop/internal/workbench/git_observation.go`
- `desktop/internal/workbench/filetree_watch.go`
- `desktop/internal/core/git_metadata.go`
- `https://github.com/Lithe-IDEA/Lithe-core-rust/tree/main/rust/crates/git`
