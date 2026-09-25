# Agent 笔记：macOS Git Log 多仓库分支分组

状态：已实现

## 先说结论

macOS 版 Git Log 的引用面板（reference pane）现在支持按仓库分组：当一个工作区里
有多个 Git 仓库时，顶层每个仓库一个可折叠节点（仓库名 + 引用数），节点内部才是原本的
Local / Remote / Tags。只有一个仓库时，渲染和以前完全一样，没有仓库层。

各仓库的引用由 macOS 特性模型（feature model，负责界面状态和用户动作的那一层）在
`gitRepositoryReferences` 里逐个仓库聚合，不改 Rust Core 的引用 / 历史契约。引用面板
工具栏新增一个开关控制是否显示链接工作树（`git worktree`）仓库，默认显示。

只有“活动仓库”那一个分组可以执行分支写操作。其它仓库的分组是**只读**的：可以点选
某一行把它切成活动仓库，但右键不再弹出任何菜单，避免在 B 仓库的行上误操作 A 仓库。

同一块引用面板还给每个仓库配一个颜色：工作区里有多个仓库时，仓库节点显示一个色点、
该仓库下的每条引用行左侧有一条细色条；只有一个仓库时完全不出现颜色，和改动前一致。
这次同时把引用行右键菜单补齐到 IntelliJ IDEA 的常见项：`Copy Branch Name`，以及
“Tracking Branch”子菜单（列出远程分支来设置上游、带一个清除项）；提交右键的“重置到
此处”也补齐了 soft / mixed / hard 三档。

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
`refreshGitHistory()` 遍历 `availableRepositoryRoots`，逐个调用现有的
`service.references(at:operationID:)`，按发现顺序写入列表。这一步用独立的 `async let`
与提交图（`refreshGitRepositoryGraph`）并行发起，只在函数末尾 `await`——**不占用提交
列表的关键路径**。否则每个仓库的引用读取都会挡在“过期结果校验”和“发布提交页”之间：
提交列表要等所有仓库读完才显示，而且期间用户切分支时旧刷新会越过校验继续发布过期页。

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

### 非活动仓库组只读

历史、diff、控制台以及所有分支写操作（checkout / merge / rebase / push / update /
rename / delete）都只针对一个活动仓库，闭包直接从活动 `gitRepositoryRoot` 取参数。如果
非活动仓库的行也弹出同一套菜单，在 B 仓库的分支上点“删除分支”实际删的是 A 仓库——
这是数据安全问题。

因此：**非活动仓库的行不显示右键菜单**。`GitLogView` 把“是否只读”传给引用行，
`GitReferenceRowMenu.entries(...)` 在只读时直接返回空数组，`LitheContextMenuPresenter.show`
对空数组不弹菜单。只读判断依赖的 `isReadOnly` 纳入 `GitReferenceRowView` 的相等比较，
否则切换活动仓库后旧行不会重建、仍带着旧菜单。行本身的点击行为不变：先切仓库再选引用。

菜单“有哪些项”被抽成纯函数（`GitReferenceRowMenu.entries(kind:isCurrent:...) ->
[GitReferenceMenuEntry]`，定义在 `macos/Sources/Lithe/Views/Git/GitReferenceRows.swift`），
与标题、闭包和本地化解耦，因此“只读仓库不提供任何条目”这条规则可以在没有 SwiftUI
宿主的情况下直接单元测试。视图只负责把每个条目映射成真实的 `LitheContextMenuItem`。

### 每个仓库一个颜色，定位用“完整仓库列表”而不是“可见仓库列表”

多仓库时，仓库节点带一个 8 色色点（`GitRepositoryColor`，定义在
`macos/Sources/Lithe/Views/Git/GitRepositoryColor.swift`），该仓库下的每条引用行左侧
有一条 2.5px 色条，方便一眼看出某条引用属于哪个仓库。

颜色按仓库在 `feature.availableRepositoryRoots` 里的**位置**取
`palette[index % 8]`，按标准化路径匹配，而不是按“当前可见的仓库”重新编号。原因是
`availableRepositoryRoots` 是**工作树过滤之前**的完整顺序列表：如果按可见集合编号，
隐藏工作树时剩余仓库的颜色会整体前移、颜色跟着行漂移，用户会以为引用换了仓库。正确做法
是把完整列表传给 `GitRepositoryColor.index(for:in:)`；错误做法是用
`GitRepositoryHierarchy.visibleRepositoryRoots(...)` 的结果去定色。

颜色只在可见仓库数 `> 1` 时出现：仓库节点判断 `GitRepositoryColor.isVisible(for:)`
（即完整列表 `count > 1`），单仓库布局把 `repositoryColorIndex` 传 `nil`，因此单仓库
工作区的渲染和改动前完全一样，没有色点也没有色条。

`GitReferenceRowView`（`GitLogView.swift`）因此新增 `repositoryColorIndex: Int?` 入参，
并且**必须纳入它的自定义 `==`**：只有把色号纳入相等比较，隐藏 / 显示工作树导
致某行的仓库色号变化时，那一行才会重建。存的是 `Int?` 色号而不是解析后的 `Color`，
是因为 `Color` 在这个部署目标（macOS 13）上不是稳定可比较的值，色号是纯数据、比较可靠。

### 引用行菜单补齐 Copy Branch Name 与 Tracking Branch

`GitReferenceRowMenu.entries(...)` 新增两个动作：本地分支和远程分支都加 `copyBranchName`
（标签不加），本地分支加 `trackingBranch`。视图侧：`copyBranchName` 直接把
`reference.shortName` 写进 `NSPasteboard`；`trackingBranch` 展开成一个子菜单，数据来自
活动仓库的远程引用（`feature.gitReferences.filter { $0.kind == .remote }`），已配置上游时
先显示当前上游和一个“Stop Tracking Branch”清除项，没有远程分支时显示禁用的占位项。

写操作复用 Rust Core 已经支持的 `setUpstream` / `unsetUpstream`（见
`rust/lithe-core/src/git/mod.rs`，Windows 端 `git-branches-api.ts` 已在用），macOS 侧只补
接线：`GitOperations` 协议 + `RustGitOperations` 实现（`setUpstream(branch:to:)` 把上游
引用和分支名传给 Core），`GitService`、`GitFeatureModel.setUpstream` /
`unsetUpstream` 依次透传。**没有改动 Rust Core**，也没有新增 Core 命令。

### 提交右键的重置支持 soft / mixed / hard

`GitFeatureModel.resetCurrentBranch(to:)` 以前写死 `--mixed`，现在加
`mode: GitResetMode = .mixed` 参数（`GitResetMode` 定义在 `GitModels.swift`，`argument`
返回 `--soft` / `--mixed` / `--hard`）。默认值保持 `.mixed`，老调用点行为不变。

提交右键原来是一个“Reset Current Branch to Here…”项，现在改成同名的**子菜单**，
列出 soft / mixed / hard 三项，对应 Windows 的 `resetToCommit(repoPath, revision, mode)`。
三档都走既有的确认对话框；hard 的确认按钮标记为 `destructive`（`GitCommitOperationKind`
新增 `isDestructive`），并把确认文案改成“丢弃工作区更改”，确保硬重置需要用户明确确认。
`GitGraphRowActions.onReset` 的签名相应变成 `(GitCommit, GitResetMode) -> Void`。

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
- **让非活动仓库的行执行写操作时先切仓库再执行**：被否。写操作要读分支、改动工作树，
  “先隐式切仓库”会让一次点击产生用户没预期的活动仓库变更，失败时更难回滚；只读更简单也更安全。
- **给写操作闭包传入目标 `repositoryRoot`**：被否。写操作链路上游（对话框、待处理请求）都以活动
  仓库为上下文，逐个改签名会把仓库身份扩散到调用链各处；在菜单层直接不提供更集中。
- **按“当前可见仓库列表”的序号给仓库上色**：被否。隐藏工作树会让剩余仓库的色号整体前移，
  同一行的颜色会漂移；必须用 `availableRepositoryRoots`（过滤前完整列表）定位。
- **在 Core 新增一个 macOS 专用的设置上游命令**：被否。Core 的 `setUpstream` / `unsetUpstream`
  已经存在且被 Windows 使用，macOS 只需接线。
- **在引用行里保存解析后的 `Color` 而不是色号**：被否。部署目标是 macOS 13，`SwiftUI.Color`
  在那里不是可靠可比较的值，放进 `GitReferenceRowView.==` 会导致刷新判断不稳定；存 `Int?`
  色号更可靠，也顺带让单仓库的“无颜色”状态可表达。

## 后果

- 多仓库工作区一次看到所有仓库的分支，并知道每条属于哪个仓库；工作树作为独立仓库照常出现。
- 单仓库工作区不出现仓库层，行为与改动前一致；活动仓库（含单仓库）保留完整右键菜单。
- 每轮历史刷新会为每个仓库多一次只读引用读取，仓库越多总耗时越长；换来的是完整的仓库视图。
  这些读取与提交图并行且不挡提交页，所以提交列表不会等全部仓库读完。
- 非活动仓库的引用行没有右键菜单，只能点选切换活动仓库；要对该仓库做写操作，先切过去。
- 只在可见仓库数 `> 1` 时走分组渲染；开关关闭时被隐藏的是工作树仓库，活动仓库始终保留。
- 引用面板的 Local / Remote / Tags 展开状态在所有仓库间共享（与 Windows 一致），同名分组
  （如 `feature`）的折叠状态在不同仓库间也是共享的——这是对 Windows 行为的对齐，非缺陷。
- 多仓库时每条引用行多一条 2.5px 色条、每个仓库节点多一个色点；单仓库工作区没有这些视觉元素。
  颜色取自固定 8 色，超过 8 个仓库时按位置回绕，因此两个相距 8 个位置的仓库会同色。
- 引用行菜单新增 Copy Branch Name（本地 / 远程）和 Tracking Branch 子菜单；提交右键的重置
  从单项变成 soft / mixed / hard 子菜单。这些项都复用现有写操作，不增加新的 Core 命令。

## 验证

- `node scripts/verify-agent-notes.mjs`：本笔记格式与路径校验统一走这个入口。
- `macos/Tests/LitheGitModuleTests/GitModuleTests.swift` 新增测试：
  - `linkedWorktreeDetectionUsesPathComponentBoundaries`（含 `op-platform` vs `op-platform-extra`
    边界）；
  - `visibleRepositoryRootsHideWorktreesButAlwaysKeepActive`；
  - `gitRepositoryReferencesAggregateAcrossWorkspaceRepositories`（多仓库聚合与顺序）；
  - `gitRepositoryReferencesHoldOneEntryForSingleRepositoryWorkspace`（单仓库一条）；
  - `visibleHistoryPublishesBeforeRepositoryReferencesLoad`（某个仓库引用读取被卡住时，
    提交列表仍先发布）；
  - `supersededRepositoryReferencesLoadDoesNotPublishAStalePage`（仓库引用读取期间切分支，
    旧刷新返回后不能覆盖新页）。
- `macos/Tests/LitheTests/GitReferenceRowsBuilderTests.swift` 的 `Git reference row menu` 套件
  校验菜单策略：只读行返回空条目，活动行的本地 / 远程 / 标签菜单项与启用状态符合预期，
  分支操作进行中时写操作项被禁用，并新增 Copy Branch Name（本地 / 远程有、标签无）与
  Tracking Branch（仅本地有）两条策略断言。
- `macos/Tests/LitheTests/GitRepositoryColorTests.swift` 校验配色：8 色互不相同且不透明，
  N 个仓库拿到互不相同的色号，隐藏中间仓库时后续仓库色号不变（证明按完整仓库列表定色），
  超过 8 个仓库回绕，单仓库不启用颜色，未知仓库回退到 0 号色。
- `macos/Tests/LitheTests/ContextMenuCoverageTests.swift` 更新提交右键断言：重置现在是子菜单，
  可执行 mixed / hard 两项并回调到 `onReset(commit, mode)`。
- `macos/Tests/LitheTests/AppLocalizationTests.swift` 的英 / 中对照校验扩展到新增的
  Copy Branch Name、Tracking Branch、Stop Tracking Branch、No Remote Branches 与
  soft / mixed / hard 三档重置的标题和确认文案。
- 上游写操作复用 Core 已有的 `setUpstream` / `unsetUpstream`（`rust/lithe-core` 内已有测试
  `git_write` 覆盖），macOS 侧只做接线，不新增 Rust 改动。
- git 控件本地化词条（含新增的两个开关文案）纳入
  `macos/Tests/LitheTests/AppLocalizationTests.swift` 的英 / 中对照校验。
- 完整 macOS 编译与测试需要在 macOS 上运行：`./scripts/test-macos.sh`。
- `./scripts/verify-service-boundaries.sh`。
- **限制**：本次改动没有 macOS 工具链可用，Swift 代码和 UI 均未在本机编译或手工验证；
  上述 Swift 测试由 macOS CI 执行。UI（仓库分组、工作树开关、跨仓库选中、仓库配色、新增
  菜单项）未手工验证。

## 适用范围

- `macos/Sources/LitheGitModule/Models/GitModels.swift`
- `macos/Sources/LitheGitModule/Application/GitFeatureModel.swift`
- `macos/Sources/LitheGitModule/Services/GitService.swift`
- `macos/Sources/Lithe/Core/Rust/RustGitOperations.swift`
- `macos/Sources/Lithe/Views/Git/GitLogView.swift`
- `macos/Sources/Lithe/Views/Git/GitReferenceRows.swift`
- `macos/Sources/Lithe/Views/Git/GitGraphView.swift`
- `macos/Sources/Lithe/Views/Git/GitRepositoryColor.swift`
- `macos/Resources/en.lproj/Localizable.strings`
- `macos/Resources/zh-Hans.lproj/Localizable.strings`
- `macos/Tests/LitheGitModuleTests/GitModuleTests.swift`
- `macos/Tests/LitheTests/GitReferenceRowsBuilderTests.swift`
- `macos/Tests/LitheTests/GitRepositoryColorTests.swift`
- `macos/Tests/LitheTests/ContextMenuCoverageTests.swift`
- `macos/Tests/LitheTests/AppLocalizationTests.swift`

上游写操作复用 `rust/lithe-core/src/git/mod.rs` 已有的 `setUpstream` / `unsetUpstream`，
本笔记不改变这些命令的入参或契约。

不改变 `git.references`、`git.historyPage`、`workspace.repositories` 的 JSON 契约；不改提交图，
也不改顶部 `BranchSwitcherPopover`（仍为单仓库）。
