# Agent 笔记：macOS Git Log 多仓库分支分组

状态：已实现

## 先说结论

macOS 版 Git Log 的引用面板（reference pane）现在支持按仓库分组：当一个工作区里
有多个 Git 仓库时，顶层每个仓库一个可折叠节点（仓库名 + 引用数），节点内部才是原本的
Local / Remote / Tags。只有一个仓库时，渲染和以前完全一样，没有仓库层。

各仓库的引用由 macOS 特性模型（feature model，负责界面状态和用户动作的那一层）在
`gitRepositoryReferences` 里逐个仓库聚合，不改 Rust Core 的引用 / 历史契约。引用面板
工具栏新增一个开关控制是否显示链接工作树（`git worktree`）仓库，默认显示。

## 问题

工作区下可以有多个并列仓库，其中主仓库还常带一批链接工作树（位于主仓库目录内的
`.worktrees/<name>`）。以前的 macOS Git Log 只显示单个活动仓库的分支：

- `GitFeatureModel.gitReferences` 只有活动仓库的引用，`refreshGitHistory()` 只对
  `service.references(at:)` 读一次活动仓库；
- 引用面板只按 Local / Remote / Tags 分层，没有仓库维度。

多仓库工作区里就会“只看到部分分支、不知道哪条属于哪个仓库”。Windows 端已经做了同样的
分组（见 `2026-09-24-windows-git-log-multi-repository-groups.md`），本笔记记录 macOS 的对齐实现。

## 决策

### 按仓库聚合放在 macOS 特性模型，不下沉到 Core

Core 的 `git.references` / `git.historyPage` 保持单仓库入参（`root`）。多仓库聚合由
macOS 自己完成：`GitFeatureModel` 新增

```swift
@Published package private(set) var gitRepositoryReferences: [GitRepositoryReferences]
```

`GitRepositoryReferences` 是一个纯值类型，保存一个仓库的 `repositoryRoot` 和它的
`references` / `recentReferences`（定义在 `macos/Sources/LitheGitModule/Models/GitModels.swift`）。
`refreshGitHistory()` 在成功拿到活动仓库引用之后，遍历 `availableRepositoryRoots` 逐个调用
现有的 `service.references(at:operationID:)`，按发现顺序写入列表。

这样做的理由是：分组是**呈现层**能力，历史分页、游标、diff、控制台都属于活动仓库。把
“列出所有仓库的引用”做成 Core 新命令，会把仓库身份这一呈现概念塞进稳定契约。macOS 保持
`gitReferences` / `recentGitReferences` / `gitCommits` 仍然只代表活动仓库，所有既有消费者
（图形、过滤、比较、Source Control）不用改。

`GitReference` 不加字段：每条引用天然归属于它被读取时的那个仓库，仓库身份由它所在的
`GitRepositoryReferences` 承载，不需要在引用自身上重复。

读取顺序是**串行**的，且沿用 `gitHistoryGeneration`（历史刷新用的代际令牌）做过期保护：
工作区切换后旧结果不会覆盖新工作区。与 Windows 不同，macOS 的
`GitService.references(at:)` 走 Core 的只读 `git.references`，不持有重写租约，所以这里不存在
Windows 那种“并发解析同一公共目录会互相报 another Git write operation”的问题，串行只是
为了让结果顺序确定、实现简单。

### 链接工作树的判定用真实路径边界

`GitRepositoryHierarchy.isLinkedWorktreeRepository(_:among:)`（同样在 `GitModels.swift`）：某个
仓库根如果在本列表里存在另一个**严格祖先**根，就算链接工作树。比较用
`URL.standardizedFileURL.pathComponents` 做逐段前缀比较，因此
`/workspace/op-platform-extra` 不会被判为在 `/workspace/op-platform` 之下——朴素字符串前缀
判断会犯这个错。

`GitRepositoryHierarchy.visibleRepositoryRoots(_:activeRoot:showWorktreeRepositories:)` 决定
真正参与分组的仓库：只有一个仓库时原样返回；关闭开关时丢掉被判定为工作树的仓库，但**始终
保留活动仓库**，避免“切到工作树后它自己从列表里消失”。

### 开关默认显示，且持久化

`GitLogView` 用 `@AppStorage("lithe.gitLog.showWorktreeRepositories")`，初值 `true`。macOS 现有
的 Git Log 开关（如“显示提交装饰”“显示长图形边”）都是会话内 `@State`，而本开关要求跨会话
记忆，因此采用同仓库其它视图（如 `RunView`）已在用的 `@AppStorage` 持久化方式，不引入新的
设置模型。

### 引用面板：多于一个仓库才出现仓库层

`GitLogView.rebuildReferenceRows()` 额外算出 `repositoryReferenceRows`（每个仓库的各 kind
扁平行），面板在可见仓库数 `> 1` 时渲染仓库节点，否则走与以前完全一致的
Local / Remote / Tags 单仓库布局。选中某个非活动仓库的行时，先 `selectRepository(root)`
切换活动仓库，再 `selectGitReference(reference)` 加载该分支历史，历史仍是单仓库语义。
只有活动仓库会高亮选中行。

## 考虑过的备选方案

- **在 Core 增加“聚合所有仓库引用”的新命令**：被否。把呈现层的仓库身份引入稳定契约，还要
  为两个平台同时定义 fixture；每个仓库的引用读取已有命令可复用。
- **给 `GitReference` 增加 `repositoryPath` 字段**（Windows 的做法）：macOS 不需要。macOS 的
  引用按 `GitRepositoryReferences` 分组持有，字段会污染一个纯 Core 值类型且没有额外收益。
- **并发读取各仓库引用**：可选但没必要。macOS 读取无需租约，但串行让顺序确定、便于复用
  单一代际令牌做取消；仓库数量通常很小。
- **用字符串前缀判断工作树祖先**：被否。会把 `op-platform-extra` 误判为 `op-platform` 的子目录。
- **把开关放进 `AppSettings` 设置模型**：被否。现有 Git Log 开关都不在 `AppSettings` 里，为一个
  布尔量扩大设置模型和其 `restoreDefaults()` 维护面不划算。

## 后果

- 多仓库工作区一次看到所有仓库的分支，并知道每条属于哪个仓库；工作树作为独立仓库照常出现。
- 单仓库工作区不出现仓库层，行为与改动前一致。
- 每轮历史刷新会为每个仓库多一次只读引用读取，仓库越多总耗时越长；换来的是完整的仓库视图。
- 只在可见仓库数 `> 1` 时走分组渲染；开关关闭时被隐藏的是工作树仓库，活动仓库始终保留。
- 引用面板的 Local / Remote / Tags 展开状态在所有仓库间共享（与 Windows 一致），同名分组
  （如 `feature`）的折叠状态在不同仓库间也是共享的——这是对 Windows 行为的对齐，非缺陷。

## 验证

- `node scripts/verify-agent-notes.mjs`：本笔记格式与路径校验通过。
- `macos/Tests/LitheGitModuleTests/GitModuleTests.swift` 新增测试：
  - `linkedWorktreeDetectionUsesPathComponentBoundaries`（含 `op-platform` vs `op-platform-extra`
    边界）；
  - `visibleRepositoryRootsHideWorktreesButAlwaysKeepActive`；
  - `gitRepositoryReferencesAggregateAcrossWorkspaceRepositories`（多仓库聚合与顺序）；
  - `gitRepositoryReferencesHoldOneEntryForSingleRepositoryWorkspace`（单仓库一条）。
- git 控件本地化词条（含新增的两个开关文案）纳入
  `macos/Tests/LitheTests/AppLocalizationTests.swift` 的英 / 中对照校验。
- 完整 macOS 编译与测试需要在 macOS 上运行：`./scripts/test-macos.sh`。
- `./scripts/verify-service-boundaries.sh`。
- **限制**：本次改动没有 macOS 工具链可用，Swift 代码和 UI 均未在本机编译或手工验证；
  上述 Swift 测试由 macOS CI 执行。UI（仓库分组、工作树开关、跨仓库选中）未手工验证。

## 适用范围

- `macos/Sources/LitheGitModule/Models/GitModels.swift`
- `macos/Sources/LitheGitModule/Application/GitFeatureModel.swift`
- `macos/Sources/Lithe/Views/Git/GitLogView.swift`
- `macos/Resources/en.lproj/Localizable.strings`
- `macos/Resources/zh-Hans.lproj/Localizable.strings`
- `macos/Tests/LitheGitModuleTests/GitModuleTests.swift`
- `macos/Tests/LitheTests/AppLocalizationTests.swift`

不改变 `git.references`、`git.historyPage`、`workspace.repositories` 的 JSON 契约；不改提交图，
也不改顶部 `BranchSwitcherPopover`（仍为单仓库）。
