# Agent 笔记：单仓库 Git 状态监听与文件系统同步

状态：提议中

## 先说结论

目标是让一个本地 Git 仓库的文件变化最终都能反映到界面上的真实状态。事件可以合并，但不能丢掉最后一次刷新；方案还在提议阶段，实现前需要先解决监听范围、丢事件、启动竞态和刷新期间重复事件这些问题。

## 问题

Changes、当前分支、Git Log、stash 和进行中的 merge/rebase 等状态来自
单个本地 Git 仓库。本地文件系统的任意一次变化只要会改变这些状态，
Lithe 最终都必须重新读取仓库状态并让界面收敛到 Git 的真实结果——但
当前实现做不到这一点。

当前 `MacDirectoryWatcher`（[`macos/Sources/Lithe/Platform/MacOS/FileWatching/MacDirectoryWatcher.swift`](../../../../macos/Sources/Lithe/Platform/MacOS/FileWatching/MacDirectoryWatcher.swift)）
只用 FSEventStream 监听用户打开的 `workspaceRoot` 一个目录，并在上报
事件前应用 `FileVisibilityRules.isHiddenPath` 过滤路径，这漏掉两类
变化：事件位于工作区内但被隐藏规则过滤（例如普通仓库的 `.git/**`）；
事件发生在工作区外（linked worktree、直接打开的 submodule，或只打开
了 repository root 的子目录）。此外当前实现不处理 FSEvents 丢事件、
监听根变化、初始快照与 watcher 启动之间的竞态，以及 Git 刷新期间再次
到达的事件。

需要建立的核心不变量：对单个本地 Git 仓库，所有由 `workspaceRoot`、
`repositoryRoot`、`gitDirectory`、`gitCommonDirectory` 及 FSEvents
恢复信号驱动的状态变化，都必须最终收敛到至少一次读取最终状态的
`refreshGit()`。短时间内的事件可以防抖合并，但最后一次变化不能被
丢弃——不能因为事件过滤、监听范围、事件丢失、刷新并发或 watcher
生命周期而永久保留旧状态。

## 提案

### 已验证的失效场景

以下结论均通过真实 Git 仓库和当前 `MacDirectoryWatcher` 的 FSEvents
实验确认（`/Volumes` 下的临时目录，避免 `/tmp` 与 `/private/tmp`
路径别名影响判断）：

- **普通仓库外部 commit**：`.git/index`、`.git/logs/HEAD`、
  `.git/refs/heads/main` 等原始事件存在，但当前 watcher 因隐藏规则
  上报为空——staged changes、当前分支引用和 Git Log 不会自动更新。
- **Linked worktree**：独立的 `gitDirectory`（收到 `index`、
  `logs/HEAD`）和共享的 `gitCommonDirectory`（收到 `refs/heads/<branch>`
  等）可能位于两个不同的外部目录，必须分别解析并监听。
- **直接打开 submodule**：submodule 的 `.git` 是地址文件，真实
  git-dir 在父仓库的 `.git/modules/**` 中；只改工作区内 `.git/**`
  的过滤方式解决不了，必须监听解析后的真实 Git 目录。
- **打开 repository root 的子目录**：`repositoryRoot` 内、
  `workspaceRoot` 外的未暂存文件变化不会写 Git 元数据，只监听
  `workspaceRoot` 和 Git 目录仍不够，必须把 `repositoryRoot` 纳入
  监听范围。

### 范围

覆盖一个 Lithe 项目对应的一个本地 Git 仓库：普通仓库、linked
worktree、直接打开的 submodule、打开含 submodule 的父仓库看到的
gitlink 状态、`workspaceRoot` 是 `repositoryRoot` 子目录、
`git init --separate-git-dir` 等真实 Git 目录位于工作区外的布局、
项目打开后才执行 `git init`、FSEvents 丢事件和监听根变化后的恢复、
应用重新获得焦点后的最终状态恢复。

不覆盖：多个独立 Git 仓库的聚合和跨仓库操作、父仓库 Changes 中展开
submodule 内部文件、远端变化但本地未 fetch、自动 fetch 或网络轮询、
`~/.gitconfig` 等工作区外配置的实时监听、外部进程使用不同 `GIT_DIR`
形成的另一套 Git 视图、bare repository、Windows 文件监听、多仓库
数据模型改造。

### Git 目录拓扑

应用层持有 `workspaceRoot`；Rust Core 负责解析 Git 自身的三个规范化
绝对路径：

| 路径 | 含义 |
| --- | --- |
| `workspaceRoot` | 用户在 Lithe 中打开的目录 |
| `repositoryRoot` | `git rev-parse --show-toplevel` |
| `gitDirectory` | 当前 worktree/submodule 的 Git 目录 |
| `gitCommonDirectory` | 多 worktree 共享的 Git 目录 |

普通仓库中四者要么相等要么是 `repositoryRoot/.git`；linked worktree
的 `gitDirectory != gitCommonDirectory` 且可能都在 `workspaceRoot`
外；直接打开 submodule 时 `gitDirectory` 位于父仓库
`.git/modules/**` 中；打开 repository root 子目录时
`workspaceRoot != repositoryRoot`；separate git-dir 布局下
`gitDirectory` 在 `repositoryRoot` 外。实现不得通过拼接
`repositoryRoot/.git` 推断 Git 目录，四种非普通布局都会使该假设
失效。

### Rust Core 契约

Rust Core（[`rust/lithe-core/src/git/`](../../../../rust/lithe-core/src/git/)）
新增只负责路径解析的 `GitWatchContext`（`repositoryRoot` /
`gitDirectory` / `gitCommonDirectory`），使用绝对路径、对存在的路径
规范化、无仓库时返回空 context、不把 `.git` 是文件还是目录的判断
交给 Swift、不依赖 Git 自然语言输出，路径通过机器可读命令解析
（`git rev-parse --show-toplevel` / `--absolute-git-dir` /
`--path-format=absolute --git-common-dir`）。Swift/macOS adapter 不
直接解析 `.git` 地址文件，也不自行构造 Git 命令。

Context 不是只读一次的永久值，以下情况必须重新解析：首次打开工作区、
`.git` 被创建/删除/替换、FSEvents 报告 `RootChanged`、worktree
repair、submodule init/deinit/update/absorbgitdirs、应用重新获得
焦点、Git 刷新发现 repository root 与当前 context 不一致。解析失败
时保留工作区 watcher 并把 Git 状态显示为无仓库，允许后续重试。

### macOS 多根目录监听

macOS adapter 接收 `workspaceRoot`、`repositoryRoot`、
`gitDirectory`、`gitCommonDirectory` 四个逻辑根，规范化并去重后
可以合并为更少的物理 FSEventStream，但必须保留每个逻辑根的角色用于
事件分类。事件按逻辑范围路由：

| 事件位置 | 工作区处理 | Git 处理 |
| --- | --- | --- |
| `workspaceRoot` 内可见路径 | 进入现有编辑器/项目树/历史/项目服务流程 | 请求 Git 刷新 |
| `workspaceRoot` 内隐藏路径 | 不进入项目树/编辑器流程 | 仍请求 Git 刷新 |
| `repositoryRoot` 内、`workspaceRoot` 外 | 不进入工作区流程 | 请求 Git 刷新 |
| `gitDirectory` / `gitCommonDirectory` 内 | 不进入工作区流程 | 请求 Git 刷新 |
| Git context 或监听根变化 | 不作为普通文件处理 | 重新解析 context、重建 watcher 并刷新 |

Git 相关分类必须发生在 `FileVisibilityRules`（[`macos/Sources/LitheCoreContracts/Workspace/FileVisibilityRules.swift`](../../../../macos/Sources/LitheCoreContracts/Workspace/FileVisibilityRules.swift)）
过滤之前——`.git` 对项目树保持隐藏，不等于对 Git 状态监听不可见。
第一版对 `gitDirectory`/`gitCommonDirectory` 下的任意事件都标记 Git
状态可能变化，不只放行 `index`/`HEAD`/`refs/**`，因为还有
`packed-refs`、reflog、stash refs、split index 的 `sharedindex.*`、
merge/rebase/sequencer 状态、未来的 reftable 等，正确性优先于事件
数量。

### 结构化事件与刷新协调

目录 watcher 不再只返回 `[String]`，改为平台无关的
`DirectoryChangeBatch`：`workspacePaths`（可进入现有流程的普通路径）、
`gitStateMayHaveChanged`（至少需要一次 Git 最终刷新）、
`requiresFullRescan`（不能信任路径列表，必须重建快照并刷新）、
`watchRootsChanged`（当前监听根可能失效，必须重新解析 context 并
重建 watcher）。macOS 类型、CoreServices 标志和具体 watcher 不得
泄漏到 Application、Services 或 Views。

Git-only 事件独立防抖后调用 `refreshGit()`，禁止触发项目树重建、
编辑器外部冲突检测、本地历史或 Java/Maven 服务重载。Git 刷新需要
独立协调状态（`pendingGitRefresh` / `gitRefreshTask` /
`gitRefreshGeneration` / `isGitRefreshRunning`）：burst 内多次事件
合并、防抖约 300–350ms、刷新运行期间到达的新事件只标记 pending 不
启动并发读取、当前刷新结束后 pending 仍为真则继续刷新，直到一轮
刷新期间没有新事件才结束。不能依赖 `isRefreshingGit` 直接返回处理
并发，那样会丢失最终状态请求。

Lithe 内部 Git 写操作继续用现有 freeze depth：freeze 期间不读取
index/worktree 中间状态，Git 事件只标记 pending，最外层 freeze
结束后合并为一次最终刷新，且不得因与 `GitFeatureModel`
（[`macos/Sources/LitheGitModule/Application/GitFeatureModel.swift`](../../../../macos/Sources/LitheGitModule/Application/GitFeatureModel.swift)）
已有显式刷新去重而丢掉最终刷新。

### FSEvents 恢复与初始化顺序

`MustScanSubDirs` 时标记 `requiresFullRescan`、重建工作区快照、强制
刷新 Git，不信任当前批次路径；`EventIdsWrapped` 按无法信任历史事件
处理，执行完整扫描和 Git 刷新；`RootChanged` 时标记
`watchRootsChanged`、重新解析 `GitWatchContext`、停止旧 stream、
用新的规范化根集合建立 stream、执行工作区和 Git 最终刷新，不得只对
旧路径调用 `refreshGit()`。应用重新获得焦点是最终兜底而非实时监听
替代品：重新解析 context、context 变化时重建 watcher、请求一次 Git
刷新，用于覆盖挂起期间的变化、外接卷短暂断连和其他不可恢复窗口。

FSEventStream 使用 `SinceNow`，必须先订阅再读取最终状态：确认
`workspaceRoot` → 启动 workspace-only watcher → Rust Core 解析
`GitWatchContext` → 扩展为完整监听根集合 → 读取工作区快照 →
`refreshGit()`。首次没有 Git 仓库时仍保留 workspace watcher 以观察
`.git` 创建，该事件不得因隐藏规则消失。

### 单仓库边界

一个 `GitFeatureModel` 对应一个 `GitWatchContext`。直接打开
submodule 时 submodule 自身是当前单仓库；打开父仓库时父仓库仍是
当前单仓库，只同步其看到的 gitlink 状态，不在父仓库 Changes 中聚合
submodule 内部文件。repository root 下的其他独立 `.git` 目录不被
发现或聚合，最多触发当前仓库一次无害刷新，不得据此创建第二套 Git
状态；多仓库支持是独立架构工作，超出本设计范围。

### 预期代码边界

Rust Core 新增 Git watch context 请求/响应和路径解析，为普通仓库、
worktree、submodule 和 separate git-dir 增加真实仓库测试，更新共享
JSON 契约和 Swift bridge payload。Core Ports / Application 定义
平台无关的结构化目录事件，让 watcher factory 接收逻辑监听根，在
`WorkspaceFeatureModel`
（[`macos/Sources/LitheWorkspaceModule/Application/WorkspaceFeatureModel.swift`](../../../../macos/Sources/LitheWorkspaceModule/Application/WorkspaceFeatureModel.swift)）
中路由普通/Git-only/恢复事件并与 Git operation freeze 协调。macOS
Adapter 用 FSEvents 监听去重后的多根目录，在隐藏过滤前识别 Git 和
repository root 事件，解释 FSEvents flags，只上报结构化事件不直接
刷新 UI 或执行 Git。Views 不参与路径解析、监听、防抖或恢复，继续只
消费 `AppModel`/`GitFeatureModel` 暴露的状态。

## 考虑过的备选方案

- **只放宽 `FileVisibilityRules`，让 `.git/**` 事件通过现有单目录
  watcher，不建立 `GitWatchContext` 或多根监听**：改动最小，能立刻
  修好普通仓库场景。但已验证的实验证明 linked worktree、submodule
  和 separate git-dir 的真实 Git 目录经常位于 `workspaceRoot` 之外，
  单目录 watcher 天然覆盖不到，因此不采用。
- **第一版只放行 `index`/`HEAD`/`refs/**` 事件以减少事件量**：能
  降低事件处理开销，实现也更简单。但会漏掉 `packed-refs`、reflog、
  stash refs、split index 的 `sharedindex.*`、merge/rebase/sequencer
  状态和未来的 reftable 存储，正确性优先于性能，因此第一版不收紧，
  只有真实性能数据证明必要后才重新评估。
- **只依赖应用重新获得焦点时轮询 Git 状态，不做实时 FSEvents 分类**：
  实现远比多根 watcher 简单，且天然能兜底挂起期间的变化。但用户在
  应用保持前台时执行外部 Git 操作或修改文件时看不到实时更新，验收
  矩阵要求的"自动更新"场景无法满足，因此焦点恢复只作为兜底路径，
  不能替代实时监听。
- **顺带做多仓库 Changes 聚合**：能一并解决 repository root 下存在
  独立嵌套仓库的场景。但会把单个 `gitRepositoryRoot`/单个 Changes
  状态改造成仓库集合，是与本设计正交的独立架构工作，容易让这次改动
  范围失控，因此明确排除在外，只保证嵌套仓库事件最多触发一次无害
  刷新。

## 验收标准

| 场景 | 操作 | 预期结果 | 不应发生 |
| --- | --- | --- | --- |
| 普通仓库 | 外部修改普通文件 | Changes 自动出现 unstaged change | 丢失事件 |
| 普通仓库 | `git add` / unstage / reset | staged/unstaged 分组自动更新 | 项目树重建 |
| 普通仓库 | commit / amend | Changes 清空或更新，分支和 Git Log 更新 | 手动刷新 |
| 普通仓库 | fetch / push | 本地 refs 相关 UI 更新 | 工作区重扫 |
| 隐藏但被跟踪的目录 | 修改 tracked 文件 | Changes 自动更新 | 文件出现在项目树中 |
| Linked worktree | add / commit / refs 更新 | 当前 worktree Changes、分支和 Log 更新 | 依赖焦点切换 |
| 直接打开 submodule | add / commit | submodule 自身 Changes 更新 | 依赖父仓库 watcher |
| 父仓库含 submodule | submodule HEAD 前进 | 父仓库 gitlink 状态刷新 | 聚合 submodule 内部 Changes |
| 打开 repository 子目录 | 修改子目录外 tracked 文件 | Changes 自动更新 | 把该文件加入项目树 |
| Separate git-dir | index / refs 更新 | Changes 和分支更新 | 假设 `repositoryRoot/.git` 存在 |
| 项目打开后 `git init` | 创建仓库 | 从 No Git 自动切换为仓库状态 | 重开项目 |
| FSEvents 丢事件 | `MustScanSubDirs` | 完整扫描并恢复最终状态 | 信任不完整路径列表 |
| 监听根迁移 | `RootChanged` | 重新解析 context、重建 watcher、刷新 | 继续监听旧路径 |
| 刷新期间再次变化 | 连续两次外部操作 | 最终状态与第二次操作一致 | 第二次请求被丢弃 |
| Lithe 内部 Git 操作 | stage / commit / checkout | freeze 后一次最终刷新 | 展示持久中间状态 |
| 应用后台期间变化 | 返回前台 | context 和 Git 状态恢复 | 永久陈旧 |

自动测试至少覆盖：Rust Core 对普通仓库/linked worktree/submodule/
separate git-dir/repository 子目录的路径解析，且必须创建真实临时
Git 仓库并执行真实 Git 命令；Swift 单元测试覆盖多根目录去重、事件
分类、隐藏路径只触发 Git 刷新、Git-only 事件不进入工作区流程、
burst 防抖、刷新期间补刷新、freeze 嵌套、full rescan/watch-roots
路由；macOS 真实场景验证需重跑本 Note 中列出的四组 FSEvents 实验。

提交前运行：

```bash
swift test --disable-sandbox
./scripts/verify-core.sh
./scripts/verify-git-graph.sh
./scripts/verify-service-boundaries.sh
./scripts/verify-shared-contracts.sh
./scripts/verify-windows-boundaries.sh
./scripts/verify-rust-core.sh
```

若修改 Rust Core，另需运行对应 Cargo 测试并确保格式检查通过。

完成标准：普通仓库/linked worktree/submodule/repository 子目录/
separate git-dir 均通过验收；Git-only 事件不触发项目树/编辑器/本地
历史/Java-Maven 刷新；普通文件外部变化行为无回归；FSEvents 丢事件和
`RootChanged` 有明确恢复路径；初始化期间不存在"刷新完成后、watcher
启动前"的永久漏事件窗口；Git 刷新期间的新事件不被丢弃；应用重新
获得焦点时可恢复最终状态；未引入多仓库聚合、远端轮询或全局 Git
配置监听。

## 风险

- 第一版对整个 `gitDirectory`/`gitCommonDirectory` 不做事件过滤，
  objects 和 lock 文件会放大事件数量；如果真实使用中防抖仍不足以
  合并 burst，需要重新评估收紧策略，但收紧后仍须保留所有会影响 Git
  状态的最终事件。
- FSEvents flags（`MustScanSubDirs`/`UserDropped`/`KernelDropped`/
  `EventIdsWrapped`/`RootChanged`）处理遗漏任何一种都会重新引入
  "永久陈旧"的失效模式；`UserDropped`/`KernelDropped` 目前只用于
  诊断，正确性完全依赖 `MustScanSubDirs` 覆盖，如果诊断显示丢事件
  但未触发 `MustScanSubDirs`，需要重新审视这个假设。
- 多根 watcher 合并物理监听路径的去重逻辑如果出错，可能让某个逻辑
  根的事件被错误分类（例如 `gitDirectory` 事件被当作普通工作区
  路径处理），需要专门的分类单元测试覆盖去重后的场景，而不能只测试
  未合并的情况。
- 范围明确排除的多仓库聚合、远端轮询、Windows 监听实现，如果后续
  被并入这次改动，会显著扩大本设计的验收面；这些需求出现时应作为
  独立提案处理，不要就地扩展本 Note。

## 适用范围

- `rust/lithe-core/src/git/`
- `macos/Sources/Lithe/Platform/MacOS/FileWatching/MacDirectoryWatcher.swift`
- `macos/Sources/LitheWorkspaceModule/Application/WorkspaceFeatureModel.swift`
- `macos/Sources/LitheGitModule/Application/GitFeatureModel.swift`
- `macos/Sources/LitheCoreContracts/Workspace/FileVisibilityRules.swift`
- `shared/contracts/`
