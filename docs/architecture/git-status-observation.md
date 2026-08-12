# 单仓库 Git 状态监听与文件系统同步

本文记录 [Issue #22](https://github.com/1lck/Lithe-IDEA/issues/22) 暴露的 Git 状态同步问题、已验证的失效场景、架构方案、实现边界和验收要求。

**状态**：设计方案，尚未实现。

**目标读者**：实现 Rust Core Git 契约、macOS FSEvents adapter、`WorkspaceFeatureModel` 和 `GitFeatureModel` 的开发者。

---

## 1. 问题定义

Lithe 的 Changes、当前分支、Git Log、stash 和进行中的 merge/rebase 等状态来自单个本地 Git 仓库。只要本地文件系统中的一次变化会改变这些状态，Lithe 就必须最终重新读取仓库状态并使界面与 Git 的真实结果一致。

当前实现只监听用户打开的工作区目录，并在上报事件前应用项目文件隐藏规则。这会漏掉两类变化：

1. 事件位于工作区内，但路径被隐藏规则过滤，例如普通仓库的 `.git/**`；
2. 事件发生在工作区外，例如 linked worktree、直接打开的 submodule，或者用户只打开了 repository root 的一个子目录。

此外，当前实现没有处理 FSEvents 丢事件、监听根变化、初始快照与 watcher 启动之间的竞态，以及 Git 刷新期间再次到达的事件。

本设计要建立以下核心不变量：

> 对单个本地 Git 仓库，所有由 `workspaceRoot`、`repositoryRoot`、`gitDirectory`、`gitCommonDirectory` 及 FSEvents 恢复信号驱动的状态变化，都必须最终收敛到至少一次读取最终状态的 `refreshGit()`。

这里的“最终收敛”意味着不能因为事件过滤、监听范围、事件丢失、刷新并发或 watcher 生命周期而永久保留旧状态。短时间内的事件可以防抖合并，但最后一次变化不能被丢弃。

---

## 2. 当前实现

### 2.1 工作区 watcher

`MacDirectoryWatcher` 使用启用了 file events 和 watch root 的 FSEventStream 监听一个工作区根目录。回调先通过 `FileVisibilityRules.isHiddenPath` 过滤路径，再把剩余路径上报给 `WorkspaceFeatureModel`。

`FileVisibilityRules.builtInHiddenDirectories` 包含 `.git`，因此普通仓库中的 Git 元数据事件在进入应用层前已经被丢弃。相同过滤还会影响 `build`、`dist` 等隐藏目录；如果这些目录包含被 Git 跟踪的文件，其内容变化仍可能改变 Changes，但当前 watcher 不会上报。

### 2.2 工作区刷新与 Git 刷新耦合

`WorkspaceFeatureModel` 收到可见文件路径后进行防抖，处理编辑器外部变化、项目树、项目服务和本地历史，最后调用 Git 刷新。没有可见文件路径时，这条链路不会启动。

因此，metadata-only Git 操作虽然改变了 Git 状态，但不会触发 `refreshGit()`：

- `git add`、unstage、reset；
- commit、amend；
- branch、tag、refs 和 packed refs 变化；
- fetch、push 后的本地 refs 变化；
- stash；
- merge、rebase、cherry-pick、revert 的状态标记；
- worktree 或 submodule 的 HEAD/index 变化。

某些操作同时修改普通文件，例如 checkout 或 stash apply，当前实现可能因为普通文件事件而碰巧刷新。但这不是可靠契约，最终 Git 元数据事件仍可能被过滤或位于监听范围外。

### 2.3 Git 状态范围大于工作区监听范围

Rust Core 的 Git status 流程会从用户打开的目录执行 `git rev-parse --show-toplevel`，随后在完整 `repositoryRoot` 上执行 porcelain status。因此 Changes 展示的是整个 repository root，而 watcher 只覆盖 `workspaceRoot`。

当用户打开仓库子目录时，repository root 其他位置的文件变化会影响 Changes，却不在当前 watcher 范围内。

### 2.4 FSEvents 恢复信号被忽略

当前 FSEvents 回调忽略 `eventFlags`，没有处理：

- `MustScanSubDirs`；
- `UserDropped`；
- `KernelDropped`；
- `EventIdsWrapped`；
- `RootChanged`。

`MustScanSubDirs` 表示客户端不能再依赖收到的单个路径，必须递归重新扫描监听层级。`RootChanged` 表示监听根或其父路径被移动、删除或替换，需要重新解析路径并重建 watcher。

### 2.5 初始化和刷新竞态

当前工作区流程先读取快照和 Git 状态，再启动 watcher。FSEventStream 使用 `SinceNow`，不会补发 watcher 启动前发生的事件。外部变化如果发生在初始状态读取之后、watcher 启动之前，就会永久漏掉，直到其他事件或手动刷新触发下一次读取。

`GitFeatureModel.refreshGit()` 还会在已有刷新进行时直接返回。若最终事件在一次较早的刷新期间到达，第二次请求可能被丢弃，使界面停留在中间状态。

---

## 3. 已验证的失效场景

以下结论均通过真实 Git 仓库和当前 `MacDirectoryWatcher` 的 FSEvents 实验确认。实验使用 `/Volumes` 下的临时目录，避免 `/tmp` 与 `/private/tmp` 路径别名影响判断；所有临时目录和监听程序均已清理。

### 3.1 普通仓库的外部 commit

外部 commit 产生了以下原始 FSEvents：

```text
.git/index
.git/logs/HEAD
.git/logs/refs/heads/main
.git/refs/heads/main
```

当前 `MacDirectoryWatcher` 上报为空，因为 `.git` 被隐藏规则过滤。

结果：commit 前的 staged changes 可能继续显示，当前分支引用和 Git Log 也不会自动更新。

### 3.2 Linked worktree

linked worktree 的 `.git` 是地址文件：

```text
linked-worktree/.git
  → main-repo/.git/worktrees/linked-worktree
```

一次外部 commit 后：

- worktree 根目录原始 FSEvents：空；
- 当前 `MacDirectoryWatcher`：空；
- worktree `gitDirectory`：收到 `index`、`logs/HEAD`；
- `gitCommonDirectory`：收到 `refs/heads/<branch>`、`logs/refs/heads/<branch>`。

这证明 linked worktree 的独立 HEAD/index 与共享 refs 可能位于两个不同的外部目录，必须分别解析并监听。

### 3.3 直接打开 submodule

submodule 的 `.git` 同样是地址文件：

```text
parent-repo/modules/child/.git
  → parent-repo/.git/modules/modules/child
```

外部 commit 前 submodule 状态为：

```text
M  tracked.txt
```

提交后变为 clean，但：

- submodule 工作区原始 FSEvents：空；
- submodule 当前 `MacDirectoryWatcher`：空；
- 真实 git-dir 收到 `index`、`logs/HEAD`、`refs/heads/main`。

因此直接把 submodule 作为 Lithe 项目打开时，单纯修改工作区内 `.git/**` 的过滤方式不能解决问题，必须监听解析后的真实 Git 目录。

### 3.4 打开包含 submodule 的父仓库

同一次 submodule commit 在父仓库根目录产生了：

```text
.git/modules/modules/child/index
.git/modules/modules/child/logs/HEAD
.git/modules/modules/child/logs/refs/heads/main
.git/modules/modules/child/refs/heads/main
```

父仓库原始 FSEvents 能收到这些路径，但当前 `MacDirectoryWatcher` 因 `.git` 隐藏规则而上报为空。

父仓库模式只需要同步父仓库看到的 submodule gitlink 状态；它不把 Changes 扩展成多个独立仓库的聚合视图。

### 3.5 打开 repository root 的子目录

仓库结构：

```text
repo/
├── .git/
├── outside.txt
└── apps/opened/     ← Lithe workspaceRoot
```

从外部修改 `repo/outside.txt` 后：

```text
git status:  M outside.txt
workspaceRoot 原始 FSEvents: 空
当前 MacDirectoryWatcher: 空
repositoryRoot 原始 FSEvents: outside.txt
```

随后执行 `git add outside.txt`：

```text
git status: M  outside.txt
gitDirectory 原始 FSEvents: index, index.lock
当前 MacDirectoryWatcher: 仍为空
```

这证明只监听 `workspaceRoot` 和 Git 目录仍不足够：未暂存的 repository root 外部文件变化不会写 Git 元数据。必须把 `repositoryRoot` 纳入监听范围。

---

## 4. 范围

### 4.1 本设计包含

本设计覆盖一个 Lithe 项目对应的一个本地 Git 仓库：

- 普通仓库；
- linked worktree；
- 直接打开的 submodule；
- 打开包含 submodule 的父仓库所看到的 gitlink 状态；
- `workspaceRoot` 是 `repositoryRoot` 子目录；
- `git init --separate-git-dir` 等真实 Git 目录位于工作区外的布局；
- 项目打开后才执行 `git init`；
- 本地普通文件、index、HEAD、refs、stash 和 Git operation state 变化；
- FSEvents 丢事件和监听根变化后的恢复；
- 应用从后台重新获得焦点后的最终状态恢复。

### 4.2 本设计不包含

以下内容不属于本设计：

- 多个独立 Git 仓库的 Changes 聚合和跨仓库操作；
- 父仓库 Changes 中展开 submodule 内部文件；
- 远端仓库发生变化但本地没有 fetch；
- 自动 fetch、网络轮询或远端通知；
- `~/.gitconfig`、全局 excludes 等任意工作区外 Git 配置的实时监听；
- 外部进程使用不同 `GIT_DIR`、`GIT_WORK_TREE` 或 `GIT_INDEX_FILE` 环境后形成的另一套 Git 视图；
- bare repository 的工作区 Changes；
- Windows 文件监听实现；
- 多仓库数据模型改造。

如果另一台机器向远端 push，而本地 refs 和文件系统没有变化，FSEvents 不可能感知；必须先发生本地 fetch 或引入独立的网络同步能力。

---

## 5. Git 目录拓扑

应用层持有用户打开的 `workspaceRoot`。Rust Core 负责解析 Git 自身的三个规范化绝对路径。

| 路径 | 含义 | 主要变化 |
| --- | --- | --- |
| `workspaceRoot` | 用户在 Lithe 中打开的目录 | 项目树、编辑器文件和可能影响 Git status 的普通文件 |
| `repositoryRoot` | `git rev-parse --show-toplevel` | 完整 worktree；可能包含 workspace 外但会出现在 Changes 中的文件 |
| `gitDirectory` | 当前 worktree/submodule 的 Git 目录 | HEAD、index、rebase/merge 等当前 worktree 状态 |
| `gitCommonDirectory` | 多 worktree 共享的 Git 目录 | refs、packed refs、对象和共享日志 |

### 5.1 普通仓库

```text
workspaceRoot == repositoryRoot
gitDirectory == gitCommonDirectory == repositoryRoot/.git
```

### 5.2 Linked worktree

```text
workspaceRoot == repositoryRoot
gitDirectory != gitCommonDirectory
gitDirectory 和 gitCommonDirectory 可能都位于 workspaceRoot 外
```

### 5.3 直接打开 submodule

```text
workspaceRoot == repositoryRoot
gitDirectory == gitCommonDirectory
gitDirectory 位于父仓库的 .git/modules/** 中
```

### 5.4 打开 repository root 子目录

```text
workspaceRoot != repositoryRoot
workspaceRoot 位于 repositoryRoot 内
gitDirectory 通常是 repositoryRoot/.git
```

### 5.5 Separate git-dir

```text
workspaceRoot == repositoryRoot
gitDirectory == gitCommonDirectory
gitDirectory 位于 repositoryRoot 外
```

实现不得通过拼接 `repositoryRoot/.git` 推断 Git 目录。worktree、submodule 和 separate git-dir 都会使该假设失效。

---

## 6. Rust Core 契约

### 6.1 GitWatchContext

Rust Core 应提供只负责路径解析的机器可读结果：

```text
GitWatchContext
├── repositoryRoot
├── gitDirectory
└── gitCommonDirectory
```

建议字段语义：

- 使用绝对路径；
- 对存在的路径进行规范化；
- 无 Git 仓库时返回空 context，而不是把工作区当作仓库；
- 不把 `.git` 是文件还是目录的判断交给 Swift；
- 不依赖 Git 的自然语言输出；
- 支持 worktree、submodule 和 separate git-dir。

路径应通过 Git 的机器可读命令解析，例如：

```text
git rev-parse --show-toplevel
git rev-parse --absolute-git-dir
git rev-parse --path-format=absolute --git-common-dir
```

Swift/macOS adapter 不应直接解析 `.git` 地址文件，也不应自行构造 Git 命令。这符合现有边界：Git 路径语义属于 Rust Core，FSEvents 属于 macOS adapter。

### 6.2 Context 生命周期

Git watch context 不是只读一次的永久值。以下情况必须重新解析：

- 首次打开工作区；
- 工作区中 `.git` 被创建、删除或替换；
- FSEvents 报告 `RootChanged`；
- worktree repair；
- submodule init、deinit、update 或 absorbgitdirs；
- 应用重新获得焦点；
- Git 刷新发现 repository root 与当前 context 不一致。

解析失败时保留工作区 watcher，并把 Git 状态显示为无仓库；后续 `.git` 变化或前台激活必须允许重试。

---

## 7. macOS 多根目录监听

### 7.1 逻辑监听根

macOS adapter 接收以下逻辑根：

```text
workspaceRoot
repositoryRoot
GitDirectory
gitCommonDirectory
```

所有路径先规范化并去重。物理 FSEventStream 可以一次监听多个根，也可以在某个祖先根已经覆盖子目录时省略重复的物理根；即使物理监听路径被合并，仍必须保留每个逻辑根的角色，用于事件分类。

示例：普通仓库中 `repositoryRoot` 已包含 `repositoryRoot/.git`，物理上监听 repository root 即可，但 `.git/**` 事件必须在应用隐藏规则之前识别为 Git 事件。

### 7.2 路径角色

事件按逻辑范围处理：

| 事件位置 | 工作区处理 | Git 处理 |
| --- | --- | --- |
| `workspaceRoot` 内可见普通路径 | 进入现有编辑器、项目树、历史和项目服务流程 | 请求 Git 刷新 |
| `workspaceRoot` 内隐藏普通路径 | 不进入项目树和编辑器流程 | 仍请求 Git 刷新，因为隐藏路径可能被 Git 跟踪 |
| `repositoryRoot` 内、`workspaceRoot` 外 | 不进入工作区流程 | 请求 Git 刷新 |
| `gitDirectory` 内 | 不进入工作区流程 | 请求 Git 刷新 |
| `gitCommonDirectory` 内 | 不进入工作区流程 | 请求 Git 刷新 |
| Git context 指针或监听根变化 | 不直接作为普通文件处理 | 重新解析 context、重建 watcher 并刷新 |

Git 相关分类必须发生在 `FileVisibilityRules` 过滤之前。`.git` 对项目树保持隐藏，不等于 `.git` 对 Git 状态监听不可见。

### 7.3 Git 目录过滤策略

第一版以正确性优先：`gitDirectory` 或 `gitCommonDirectory` 下的任意事件都标记 Git 状态可能变化，再通过防抖合并刷新。

不建议第一版只允许 `index`、`HEAD` 和 `refs/**`，因为还存在：

- `packed-refs`；
- reflog；
- stash refs；
- split index 的 `sharedindex.*`；
- merge/rebase/sequencer 状态；
- Git 后续版本的 ref 存储变化，例如 reftable；
- submodule 的 `.git/modules/**`。

objects 和 lock 文件会增加事件数量，但不会破坏正确性；防抖应把一次 Git 操作产生的 burst 合并为一次最终刷新。只有在真实性能数据证明必要后，才能收紧过滤，并且收紧后仍须保留所有会影响 Git 状态的最终事件。

---

## 8. 结构化事件

目录 watcher 不应再只返回 `[String]`。建议定义平台无关的批次：

```text
DirectoryChangeBatch
├── workspacePaths
├── gitStateMayHaveChanged
├── requiresFullRescan
└── watchRootsChanged
```

字段语义：

- `workspacePaths`：可进入编辑器、项目树、本地历史和项目服务流程的普通路径；
- `gitStateMayHaveChanged`：至少需要一次 Git 最终状态刷新；
- `requiresFullRescan`：不能信任单个路径列表，必须重建工作区快照并刷新 Git；
- `watchRootsChanged`：当前监听根可能失效，必须重新解析 Git context 并重建 watcher。

macOS 类型、CoreServices 标志和具体 watcher 不得泄漏到 Application、Services 或 Views。

---

## 9. 事件路由与刷新协调

### 9.1 普通工作区事件

`workspacePaths` 继续使用现有流程：

```text
外部普通文件变化
→ 编辑器外部修改检测
→ 必要时刷新项目树
→ 必要时重载 Java/Maven 项目服务
→ 本地历史
→ Git 状态刷新
```

本设计不能改变普通文件自动重载、未保存冲突处理或项目树刷新行为。

### 9.2 Git-only 事件

只有 `gitStateMayHaveChanged` 时：

```text
Git 元数据或 repositoryRoot 外部文件变化
→ Git 独立防抖
→ refreshGit()
```

禁止进入：

- 项目树重建；
- 编辑器外部文件冲突检测；
- 本地历史；
- Java/Maven 服务重载；
- 普通文件扫描。

### 9.3 防抖与最终刷新

Git 刷新需要独立于工作区刷新的协调状态，至少包括：

```text
pendingGitRefresh
gitRefreshTask
gitRefreshGeneration 或等价状态
isGitRefreshRunning
```

期望语义：

1. burst 中的多次事件合并；
2. 防抖时间建议与现有工作区刷新接近，约 300–350ms；
3. 刷新运行期间到达的新事件只标记 pending，不启动并发读取；
4. 当前刷新结束后，如果 pending 再次为 true，必须继续刷新；
5. 直到一次刷新期间没有新事件，任务才结束。

不能依赖 `isRefreshingGit` 直接返回来处理事件并发，因为直接返回会丢失最终状态请求。

### 9.4 Git operation freeze

Lithe 内部 Git 写操作继续使用现有 freeze depth：

- freeze 期间不读取 index/worktree 中间状态；
- 普通文件路径继续累计；
- Git 事件只标记 pending；
- 最外层 freeze 结束后合并为一次最终 Git 刷新；
- 与 GitFeatureModel 已有的显式刷新去重，但不得因此丢掉最终刷新。

外部终端或其他应用执行 Git 操作时不会进入 Lithe freeze，依靠事件防抖等待操作 burst 稳定。若长操作中途产生超过防抖间隔的停顿，可以读到中间状态；后续事件仍必须触发最终刷新。

---

## 10. FSEvents 恢复

### 10.1 MustScanSubDirs

收到 `MustScanSubDirs` 时，单个事件路径不再可信。应用必须：

1. 标记 `requiresFullRescan`；
2. 重建工作区快照；
3. 强制刷新 Git；
4. 不把当前批次路径当成完整变化集合。

`UserDropped` 和 `KernelDropped` 用于诊断事件在用户态还是内核态丢失；正确性处理统一由 `MustScanSubDirs` 驱动。

### 10.2 EventIdsWrapped

虽然当前 stream 使用 `SinceNow`，收到 `EventIdsWrapped` 仍应按无法信任历史事件处理，执行完整扫描和 Git 刷新。

### 10.3 RootChanged

收到 `RootChanged` 时：

1. 标记 `watchRootsChanged`；
2. 重新解析 `GitWatchContext`；
3. 停止旧 stream；
4. 使用新的规范化根集合建立 stream；
5. 执行工作区和 Git 最终刷新。

不得只对旧路径调用 `refreshGit()`，因为旧 watcher 可能已经监听不存在的位置。

### 10.4 应用重新获得焦点

应用前台激活是最终兜底，不是实时监听的替代品。每个已打开项目应：

1. 重新解析 Git context；
2. context 变化时重建 watcher；
3. 请求一次 Git 刷新。

该路径覆盖应用挂起期间的变化、外接卷短暂断连、未观察到的 Git 目录迁移和其他不可恢复的事件窗口。

---

## 11. 初始化顺序

FSEventStream 使用 `SinceNow` 时，必须遵循“先订阅，再读取最终状态”。建议工作区启动顺序：

```text
确认 workspaceRoot
→ 启动 workspace-only watcher
→ Rust Core 解析 GitWatchContext
→ 扩展并重建为完整监听根集合
→ 读取工作区快照
→ refreshGit()
```

如果实现结构不适合在快照前启动完整 watcher，最低要求是：

```text
解析 context
→ 启动 watcher
→ 无条件执行一次最终 refreshGit()
```

首次没有 Git 仓库时仍保留 workspace watcher，以便观察 `.git` 创建。`.git` 创建事件不得因隐藏规则而消失；它需要触发 context 重新解析和 watcher 重建。

---

## 12. 单仓库边界

本设计中的“单仓库”指一个 `GitFeatureModel` 对应一个 `GitWatchContext`。

### 12.1 Submodule

- 直接打开 submodule：submodule 自身是当前单仓库，解析其真实 git-dir；
- 打开父仓库：父仓库仍是当前单仓库，只同步父仓库看到的 gitlink 状态；
- 不在父仓库 Changes 中聚合 submodule 内部的 staged/unstaged 文件。

### 12.2 嵌套独立仓库

repository root 下存在其他独立 `.git` 目录时，本设计不发现或聚合这些仓库。多仓库支持需要把单个 `gitRepositoryRoot` 和单个 Changes 状态改造成仓库集合，是独立架构工作。

监听父 repository root 可能接收到嵌套仓库事件；这些事件最多触发当前仓库一次无害刷新，不得据此创建第二套 Git 状态。

---

## 13. 预期代码边界

实现时预计涉及以下职责，不要求文件名完全固定，但不得破坏现有分层：

### Rust Core

- 新增 Git watch context 请求、响应和路径解析；
- 使用机器可读 Git 命令；
- 为普通仓库、worktree、submodule 和 separate git-dir 增加真实仓库测试；
- 更新共享 JSON 契约和 Swift bridge payload。

### Core Ports / Application

- 定义平台无关的结构化目录事件；
- 让 watcher factory 接收逻辑监听根或 watch configuration；
- 在 `WorkspaceFeatureModel` 中路由普通工作区事件、Git-only 事件和恢复事件；
- 与 Git operation freeze 协调；
- 保证刷新期间到达的事件不会丢失。

### macOS Adapter

- 使用 FSEvents 监听去重后的多根目录；
- 在隐藏过滤前识别 Git 和 repository root 事件；
- 解释 FSEvents flags；
- 上报结构化事件，不在 adapter 内直接刷新 UI 或执行 Git。

### App lifecycle

- 应用重新获得焦点时重新解析 context 并请求 Git 刷新；
- 多个已打开项目分别刷新自己的单仓库状态。

### Views

Views 不参与路径解析、文件监听、防抖或恢复。Changes、状态栏和 Git Log 继续只消费 `AppModel`/`GitFeatureModel` 暴露的状态。

---

## 14. 验收矩阵

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

---

## 15. 测试与验证

### 15.1 Rust Core 测试

至少覆盖：

- 普通仓库三个路径；
- linked worktree 中不同的 git-dir/common-dir；
- submodule 地址文件；
- separate git-dir；
- 从 repository 子目录解析根；
- 非 Git 目录返回空 context；
- 路径为绝对、规范化结果。

测试必须创建真实临时 Git 仓库并执行真实 Git 命令，不以手写 `.git` 目录结构代替 Git 行为。

### 15.2 Swift 单元测试

至少覆盖：

- 多根目录规范化和去重；
- workspace、repository、git-dir、common-dir 的事件分类；
- 隐藏路径只触发 Git 刷新；
- Git-only 事件不进入项目树、编辑器和项目服务；
- burst 防抖只产生一次刷新；
- 刷新期间再次到达事件后会补刷新；
- freeze 嵌套和最外层 flush；
- full rescan 与 watch roots changed 路由；
- context 变化后替换 watcher。

### 15.3 macOS 真实场景验证

真实 FSEvents 验证必须至少重跑本文件第 3 节的四组实验，并在运行中的 Lithe 中观察：

- Changes 分组；
- 当前分支；
- Git Log；
- merge/rebase operation state；
- 项目树没有因 Git-only 事件闪烁；
- Java/Maven 服务没有因 Git-only 事件重启；
- 编辑器没有收到 `.git` 路径的外部冲突提示。

### 15.4 仓库验证命令

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

如果修改 Rust Core，再运行对应 Cargo 测试，并确保格式检查通过。

---

## 16. 完成标准

本设计只有同时满足以下条件才算完成：

1. 普通仓库、linked worktree、submodule、repository 子目录和 separate git-dir 都通过验收；
2. Git-only 事件不会触发项目树、编辑器、本地历史或 Java/Maven 刷新；
3. 普通文件外部变化行为没有回归；
4. FSEvents 丢事件和 RootChanged 有明确恢复路径；
5. 初始化期间没有“刷新完成后、watcher 启动前”的永久漏事件窗口；
6. Git 刷新期间的新事件不会被丢弃；
7. 应用重新获得焦点时可以重新解析路径并恢复最终状态；
8. 未引入多仓库聚合、远端轮询或全局 Git 配置监听；
9. 自动测试、真实 macOS 场景和仓库边界验证全部通过。
