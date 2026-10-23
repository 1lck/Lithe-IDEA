# Agent 笔记：统一 VCS 模型与 Provider 接入

状态：提议中

## 先说结论

Lithe 现在只认识 Git：Rust Core、macOS 和 Windows 的变更列表、提交面板、项目树文件颜色、编辑器行标记（gutter）都直接使用 Git 类型。[Issue #827](https://github.com/1lck/Lithe-IDEA/issues/827) 要求支持 SVN，以后还可能有 Mercurial、Perforce 等其他 VCS（Version Control System，版本控制系统）。

提案照搬[构建系统插件契约](../../implemented/architecture/2026-10-17-build-system-plugin-contract.md)已经验证过的做法：Rust Core 定义一份与具体 VCS 无关的统一模型和 `vcs.*` 命令，每种 VCS 是一个 Provider（回答“这个目录现在是什么状态、怎样提交、怎样回滚”的实现）。SVN 作为第一个插件 Provider，后端用官方 Node SDK 编写，以插件进程的形式接入，后续其他 VCS 走同一条路。2026-10-23 决定 SVN 插件不放进主仓库，而是像 Cargo 插件一样做成独立仓库的社区插件（[lithe-plugin-svn](https://github.com/Lithe-IDEA/lithe-plugin-svn)）；主仓库只保留与具体 VCS 无关的 Core、契约、SDK 和宿主。

2026-10-22 评审决定：**Git 暂不接入统一层**。现有 Git 代码约 8 万行（Rust、Swift、TypeScript 合计，不含测试），两端还有重复的确定性逻辑，直接“包一层”会把这些债一起带进统一层。所以第一期统一层只服务插件 Provider，Git 保持现有 `git.*` 和 Git 模块不变；Git 的精简、迁移和改成内置官方插件另起提案（第 10 节）。

对日常开发的影响：新的 Git 功能照常写在 Git 模块里；但凡是“任何 VCS 都会有”的界面（文件状态颜色、gutter、提交、回滚、文件历史、Annotate），不要再新增对 Git 类型的直接依赖，以免 Git 迁移时多一处要拆。

## 问题

### 现状

| 位置 | 现在做什么 | 问题 |
| --- | --- | --- |
| `rust/lithe-core/src/git/`、`rust/lithe-git-host/` | 约 1.85 万行 Git 参数策略、解析、执行事件和原生进程适配，暴露 47 个 `git.*` 命令 | 质量高，但所有结果类型都是 Git 专属，第二种 VCS 无法复用 |
| `macos/Sources/LitheGitModule/` | `GitOperations` 端口、`GitFeatureModel`、Changelist、Shelve | Changelist 和 Shelve 在 IDEA 里属于平台层，与具体 VCS 无关；在 Lithe 里绑在 Git 模块上 |
| `macos/Sources/Lithe/Views/`（项目树、编辑器、Diff） | 直接引用 `GitChange`、`GitChangeKind`、`GitSnapshot` | 文件颜色和 gutter 这类通用展示被 Git 类型锁死 |
| `windows/tauri/src/features/git/` | 约 6 万行 React/TS，状态表、提交面板、Log | 同样只认 Git |
| `shared/contracts/plugins/v1/` | 语言、语言服务器、构建系统等能力 | 没有 VCS 扩展点，社区插件无法提供 VCS |

### 不处理的后果

- 直接照着 Git 再写一套 SVN 模块，会复制提交面板、变更列表、文件颜色、gutter 和 Changelist，两端各一份。这正是构建系统统一之前 Maven 专用类型带来的问题。
- 每增加一种 VCS 都要改宿主代码、发 Lithe 新版本，社区无法参与。
- SVN 有 Git 没有的硬性要求：改名必须走 `svn move` 才能保留历史，提交直接上传服务器，修订号是递增整数。通用层如果不提前留位置，后面只能在宿主里按名字写特例。

## 提案

### 1. 三层分工：谁回答什么问题

| 层 | 位置（计划） | 负责 | 不负责 |
| --- | --- | --- | --- |
| Rust Core 的 `vcs` 模块 | `rust/lithe-core/src/vcs/`（新） | 统一模型、`vcs.*` 命令、根目录识别、请求计划、插件回复的解码和校验 | 启动进程、弹窗、存储 |
| 宿主 | macOS 新的 VCS 工作区模块；Windows 的 VCS 状态 store | 根映射与用户覆盖、文件监听触发刷新、凭据交互、Provider 进程生命周期、项目控制台 | 解析任何 VCS 的输出 |
| Provider | 插件进程（第一期只有 SVN）；Git 暂不接入 | 回答状态、基线内容、历史、Annotate、提交、回滚、更新等事实 | 界面和跨根聚合 |

插件 Provider 的回复先由 Core 校验（路径必须在根内、排序稳定、数量和大小有上限），再转换成统一形状。所以宿主拿到的结果不区分来自哪个 Provider，以后 Git 接入时也只需要产出同一形状。

### 2. 统一模型只收所有 VCS 都成立的概念

参照 IntelliJ Community 固定版本 [`c7f91397daa3`](https://github.com/JetBrains/intellij-community/commit/c7f91397daa3a961b4e78bc634fe467a0a7d9ade) 的 `platform/vcs-api`：`AbstractVcs`（一种 VCS 的入口）、`ChangeProvider`（状态）、`DiffProvider`（基线内容）、`CheckinEnvironment`（提交）、`RollbackEnvironment`（回滚）、`UpdateEnvironment`（更新）、`VcsHistoryProvider`（历史）、`AnnotationProvider`（Annotate）、`VcsRootChecker`（根识别）。IDEA 的 Git、SVN、Mercurial 插件都实现这同一组接口，说明这组概念确实跨 VCS 成立。

| 概念 | 含义 | Git 对应 | SVN 对应 |
| --- | --- | --- | --- |
| 根（root） | 一个受版本控制的目录 | 工作树根（`.git` 目录或文件） | 工作副本根（1.7 起只有根目录有 `.svn`） |
| 文件状态 | 修改、新增、删除、改名、未纳入版本控制、忽略、冲突等 | `git status` | `svn status --xml` |
| 修订（revision） | 不透明的 ID，加上用于显示的文本 | 40 位提交哈希 | 整数 `r1234` |
| 基线内容 | 文件在当前基线版本的内容，供 Diff 和 gutter 使用 | `HEAD` 或索引里的内容 | `svn cat -r BASE` |
| 提交 | 把选中的改动记录为新修订 | 本地提交，之后需要 Push | 直接上传到服务器 |
| 更新 | 把远端新修订合入本地 | Pull | `svn update` |
| 回滚 | 丢弃选中文件的本地改动 | restore / checkout | `svn revert` |

宿主永远不解析修订 ID 的内容，也不比较两个修订的先后；需要比较时问 Provider。

### 3. 界面看能力，不看 VCS 的名字

每个 Provider 声明自己支持哪些能力，界面只按能力出现入口。必备能力是状态、基线内容、提交和回滚；协议版本 1 的可选能力是历史、文件历史、Annotate、更新、推送、暂存区（staging）、文件操作跟踪、冲突处理和清理。分支、锁、属性、忽略规则等到有第二个 Provider 需要时，再按能力版本加入。

集中式与分布式 VCS 的差别也表达成能力：

- 有没有“推送”能力，决定提交按钮显示 “Commit” 还是 “Commit and Push”。
- 有没有“暂存区”能力，决定变更列表是否显示 staged/unstaged 两个维度。Git 的暂存状态是附加维度，不放进通用文件状态。

正确做法：提交面板读取当前根的能力，SVN 根没有推送能力，因此只显示 “Commit”，并提示提交会直接上传。

不要这样做：在提交面板里写 `if root.vcs == "svn"`。下一个集中式 VCS 出现时，这个分支又要再改一次。

### 4. 文件操作跟踪

SVN 的改名、移动和删除必须通过 `svn move` / `svn delete` 执行，否则历史会断开；新建文件也需要 `svn add` 才会被提交。IDEA 在 `platform/vcs-impl` 的 `VcsVFSListener` 里统一处理这件事，SVN 插件只提供 `SvnFileSystemListener`。

Lithe 的做法相同：Provider 声明“文件操作跟踪”能力后，宿主在项目树里新建、改名、移动或删除文件时，按用户设置（询问、总是、从不）把操作交给 Provider。Git 不声明这个能力，所以 Git 项目的行为完全不变。

### 5. Git 专属功能留在 Git 模块

Git Log 图、Rebase、Worktree、Stash、Push 和 Fetch 对话框、历史改写这些只属于 Git 的功能继续由 Git 模块拥有，作为 Git 能力挂到界面上。IDEA 也是这样做的：这些功能只在 `git4idea` 插件里，不在 `vcs-api`。同理，SVN 的锁、属性、Cleanup、Switch、Relocate 由 SVN 插件通过声明式 UI 或插件网页提供。

不要为了“统一”把 Rebase、Worktree 这类功能抽象进 `vcs.*`。那会让通用层被 Git 的概念撑大，而其他 VCS 永远实现不了。

### 6. 插件 Provider：与构建 Provider 同一种进程

插件 VCS Provider 不是新的进程类型，它就是语言服务器那种 LSP 基础协议进程，与[构建系统插件契约](../../implemented/architecture/2026-10-17-build-system-plugin-contract.md)第 9 节的构建 Provider 一样：

- 清单在插件 API 级别 3 新增 `vcsProviders` 能力（`requires: { vcsProviders: 1 }`），只写启动前必须知道的事：VCS ID、显示名、根识别标记（例如名为 `.svn` 的目录），以及复用 `serverProcess` 的启动字段。
- 打开项目时由 Core 按静态标记识别根，不启动进程。识别到这种 VCS 的根之后，宿主才启动 Provider，因为文件状态颜色在打开项目时就需要。安装审查时要向用户说明这一点。
- 进程启动后，宿主在 `initialize` 里通过 `capabilities.experimental.litheVcs` 协商版本，Provider 在回复里给出自己的能力集。能力集描述的是运行中的进程，所以不写进清单，这遵守[声明式插件按能力分版本](../../implemented/architecture/2026-10-17-plugin-capability-versions.md)第 4 节的规则。
- 请求方法统一以 `lithe/vcs/` 开头。宿主不按 Provider ID 写分支；进程按“插件 ID + VCS ID + 工作区”隔离，生命周期规则与构建 Provider 相同。

字段和方法见 [VCS Provider 契约](../../../../shared/contracts/vcs-provider-v1.md)，示例数据见 [`shared/fixtures/vcs/model-v1.json`](../../../../shared/fixtures/vcs/model-v1.json)。Core 已按契约实现（见第 9 节的进度），但还没有宿主声明 `vcsProviders`，所以插件市场不会列出这类插件；宿主接入前契约仍可以修改，改动要同时更新 fixtures 和 Core 测试。

### 7. SVN 作为社区插件

SVN 插件在独立仓库维护和发布（见第 9 节 P2），调用用户系统里的 `svn` 命令行，解析它稳定的 `--xml` 输出。IDEA 的 svn4idea 也是这样做的（`plugins/svn4idea/src/org/jetbrains/idea/svn/status/CmdStatusClient.kt` 使用 `svn status --xml`）。这和 Lithe 使用系统 Git 的方式一致，不需要打包 JVM 或跨平台编译 libsvn。

后端进程用官方 Node SDK（[lithe-plugin-docs](https://github.com/Lithe-IDEA/lithe-plugin-docs) 的 `sdk/node`）编写，以 `runtime` 方式启动（`tool: node`）。SDK 已经负责线协议、协商、取消、子进程清理和错误映射，Cargo 社区插件也走这条路；同一份后端在 macOS 和 Windows 上都能运行，插件包里没有原生二进制，不涉及按架构编译和 Gatekeeper。代价是用户除了 `svn` 还需要 Node 20.3 以上，安装审查和缺少运行时的提示要说清楚。SDK 新增 `litheVcs` 支持，和 `litheBuild` 并列；2026-10-23 起 SDK 不在主仓库，这部分改动在 lithe-plugin-docs 提交（见[插件契约、SDK 与开发者资料的发布](../../implemented/architecture/2026-10-23-plugin-contract-publishing.md)）。

凭据规则沿用[Git 执行与项目控制台](../../implemented/architecture/2026-09-12-git-execution-and-project-console.md)：命令始终带 `--non-interactive`，SVN 自己的认证缓存优先回答。第一版只依赖这份缓存，认证失败时返回 `vcs.authentication.failed`，宿主提示原因；交互式认证（宿主弹窗收集用户名和密码，经 `--password-from-stdin` 传给 `svn`）在宿主阶段实现。密码不出现在命令参数、控制台和日志里，Lithe 也不保存密码。

### 8. 宿主接手与 VCS 无关的状态

- **根映射**：一个工作区可以同时有 Git 和 SVN 根。文件归属最深的那个根；同一目录同时出现两种标记时，要求用户在设置里选择，不能猜。IDEA 用 `VcsDirectoryMapping` 保存这种映射。Git 暂不接入统一层，但 Core 识别根时仍认得 `.git` 标记，这样嵌套和歧义的判断对 Git 也成立，Git 根继续交给 Git 模块。
- **Changelist 和 Shelve**：长期应从 `LitheGitModule` 上移到宿主的 VCS 层（IDEA 的 `ChangeListManagerImpl` 在 `platform/vcs-impl`，不属于任何一种 VCS）。这一步和 Git 迁移一起做；第一期 SVN 根的变更不分组，也不支持 Shelve。
- **监听刷新**：[单仓库 Git 状态监听提案](../bug-fix/2026-09-13-single-repository-git-status-observation.md)里要求的监听范围，扩展成“每个 Provider 声明的元数据目录”，例如 SVN 的 `.svn/wc.db`。
- **项目控制台**：现有 Git 执行事件多带一个 VCS ID 字段。插件 Provider 用 `lithe/vcs/execution` 通知上报实际执行的命令和输出，Core 把它转成会话日志事件交给宿主。展示、折叠和脱敏规则不变。

### 9. 分阶段落地

2026-10-22 起按“先底层、再 SVN、Git 最后”的顺序：

| 阶段 | 内容 | 完成标志 |
| --- | --- | --- |
| P0 | 本提案、契约草案和 fixtures | 评审通过 |
| P1 | Core：插件清单 `vcsProviders` 能力、根识别、请求计划与插件回复解码、`litheVcs` 协商和 `lsp.vcsRequest`；Node SDK 支持 `litheVcs` | fixtures 和用 SDK 写的假 Provider 经真实 Core 会话跑通 |
| P2 | SVN 社区插件（独立仓库，Node SDK 后端） | 插件仓库里录制的 `svn --xml` 样例解析测试，以及用固定版本 Core 在本地 `file://` 仓库上跑的端到端测试 |
| P3 | macOS 宿主：Provider 会话（复用构建 Provider 的会话代码）、项目树颜色和 gutter 合并展示插件根、通用“版本控制”工具窗口（变更、提交、回滚、更新）、文件操作跟踪、交互式认证 | 见验收标准 |
| P4 | Windows 按同一契约和 fixtures 接入 | Windows 通过同一组 fixtures |
| 之后 | Git 精简并接入统一层，见第 10 节 | 另起提案 |

P1 已完成（2026-10-22）：

- 插件清单：API 级别 3 的 `vcsProviders`、`process.vcs` 权限和 `onVcsRoot:<id>` 激活事件；`git` 是保留 ID。安装审查列出 Provider 进程，SVN 这类工具路径另放在 `vcsTool` 字段，不覆盖运行时的 `tool`。
- 根识别 `vcs.detectRoots`：只读目录项，不读文件、不启动进程；工作区自己没有标记时向上查祖先目录，所以“工作区开在 SVN 工作副本的子目录里”也能识别。新增 `vcs.ownerOf`，让各宿主用同一条“最深根”规则给文件找归属，不必各写一份。
- 会话：`litheVcs` 只提供给插件启动的会话；`lsp.vcsRequest` 按操作名生成 `lithe/vcs/*` 请求，未协商的能力在写出前就拒绝；Provider 只能使用契约列出的错误码，其余一律变成 `vcs.provider.failed`。`lithe/vcs/authenticate` 在宿主实现交互式认证前按未知请求回绝。
- Node SDK：`backend.vcs(id, handlers, traits)` 按声明的处理函数协商能力，VCS 处理函数里的 `context.run` 会自动发出 `lithe/vcs/execution` 执行报告（只带命令行、退出码、耗时和截断后的 stderr，不带 stdout）。示例 `sdk/node/examples/sample-vcs` 是一个把修订存在 JSON 文件里的玩具 VCS，端到端场景经真实 Core 会话跑通它的协商和全部 11 种操作。SDK、示例和端到端场景随 SDK 迁到 lithe-plugin-docs，在那里用 `scripts/sdk-e2e.mjs --ref <本分支>` 运行；主仓库只保留契约、fixtures 和 Core 测试。

P2 已完成（2026-10-23），同日改为社区插件：

- 插件在独立仓库 [lithe-plugin-svn](https://github.com/Lithe-IDEA/lithe-plugin-svn)，ID 是 `io.github.lithe-idea.svn-support`，`vendor.signatureRequirement` 为 `none`。仓库结构照搬 [Cargo 插件](../../implemented/feature/2026-10-22-cargo-build-plugin.md)：`sdk.lock.json` 按上游提交和逐文件 SHA-256 固定 Node SDK，打包前校验；安装包发在插件仓库的 GitHub Releases，Lithe Store 索引记录下载地址和 SHA-256。
- 插件仓库自己的 CI 按 `sdk.lock.json` 的同一个宿主提交检出 Core，经公开 JSON 接口在 `svnadmin create` 建立的 `file://` 仓库上跑状态、提交、更新、冲突、回滚、移动、历史和 Annotate。svn 怎样映射到每个操作、svn 错误码怎样映射到契约错误码，都写在插件仓库的 README 里，主仓库的契约只留一个指向。
- 主仓库不再有 SVN 专属的代码和测试，CI 也不用装 svn。它保留通用的部分：契约、fixtures 和 Core 测试，以及宿主测试用的 `shared/contracts/plugins/v1/fixtures/vcs-provider.plugin.json`（只有清单，没有实现）。样例 Provider `sample-vcs` 和它的端到端场景随 SDK 在 lithe-plugin-docs。

正确做法：主仓库改 VCS 契约或 Core 时，用 fixtures 和 Core 测试验证，合并前在 lithe-plugin-docs 用 `scripts/sdk-e2e.mjs --ref <分支>` 跑样例 Provider；SVN 插件升级 `sdk.lock.json` 后在自己的 CI 里验证。
不要这样做：在主仓库测试里引用隔壁的 SVN 插件 checkout，或者为 SVN 在宿主代码里加按名字判断的分支。

宿主需要知道的 SVN 行为（插件 README 有完整说明）：

- `head` 是根目录自己的工作修订（`svn info` 的结果）。提交后根目录停在旧修订，要 `update` 才前进，这是 SVN 的混合修订语义，宿主不要拿它判断“提交没成功”。
- svn 每个写命令结束前会等约 1 秒，保证之后的修改时间戳不同，宿主不要指望写操作更快完成。
- 第一版 `status` 每次查整个根，契约 v1 也没有按路径查询的参数。增量查询要等量出大工作副本的实际耗时后再加，要加就按能力版本加参数。

P3 第一部分已完成（2026-10-23），在 macOS 上：

- 宿主在 `PluginManifest.hostCapabilities` 声明 `vcsProviders: [1]`，声明了 VCS Provider 的插件从这时起能安装。宿主读清单时给这类插件生成一个 `<插件 ID>.vcs-providers` 模块，只承载插件的启用状态，默认关闭，做法和构建系统插件的 `.build-systems` 模块一样。安装审查给三种 Provider 程序（插件内、系统已装、运行时启动）显示启动命令、`vcsTool` 里的客户端命令，以及 `mayUseNetwork` 声明的“可能连接仓库服务器”，让用户批准前知道插件会运行哪个 `svn`。客户端命令和 Provider 自己的运行时一样经构建工具发现查找，找不到时报契约的 `vcs.tool.unavailable`，工具窗口据此先显示安装提示。
- Provider 会话按窗口创建：启动时已安装的插件声明了 `vcsProviders`，`MacServiceContainer` 才建 `VcsProvidersFeatureModel`。启动后再安装的插件要重启才生效，工具窗口这时只显示“重启 Lithe 后使用”。这样做是因为服务在窗口组合时一次建好，运行中插桩会话要改动整个组合根，收益只是省一次重启。
- 每个 Provider 贡献一个左侧工具窗口，宿主只认贡献上的 `vcsProviderPluginID`、`vcsProviderID` 两个可见性键，代码里没有任何 VCS 或插件的名字（与构建系统窗口同一套注册方式）。Provider 不声明图标，派生的窗口和命令统一用宿主的版本控制图标（`git` 宿主图标，即 `vcs@20x20.svg`），不用通用工具窗口图标。第一次读状态时 Provider 进程才启动，可能要几秒，变更列表这时显示“正在读取更改…”，不留空白。变更行在辅助功能里是一个合并元素，默认动作是选中，另有“显示差异/打开文件”和“包含在提交中”两个命名动作，否则辅助功能只能切换复选框。窗口按冲突、变更、未版本化文件分组：默认只勾选“变更”组，未版本化文件要用户勾选才提交，冲突文件不能勾选，要先“标记为已解决”；移动的文件提交时连同原路径一起提交，否则 SVN 会只提交一半。按钮是否出现看 Provider 协商的能力，不看 VCS 名字。
- 与基线比较做成窗口级的弹出面板（`VcsProvidersFeatureModel.presentedDiff`，由 `RootView` 显示），不挂在工具窗口里，因为项目树右键的“显示差异”在工具窗口隐藏时也要能用。比较复用本地历史的 `LocalHistoryDiffBuilder` 和 Git 的 `DiffPaneView`；超过 2 万行时退成左右两栏纯文本，避免逐行比较卡住界面。有没有基线由 `VcsRootState.comparesWithBase` 一处判断，工具窗口双击、辅助功能动作和项目树右键共用：新增、未版本化、忽略的文件没有基线，双击直接打开；复制的文件和复制来源比较。
- 项目树颜色：插件根的状态通过一个只观察 `VcsProvidersFeatureModel` 的包装视图传给项目树，项目树本身仍是 `.equatable()`，刷新状态不重绘整棵树。同一文件 Git 和插件都有状态时用 Git 的，因为第一期 Git 不在统一层，嵌套时以 Git 的显示为准，不让两套颜色互相覆盖。
- 文件操作跟踪：工作区模块只多一个注入的 `moveTrackedItem` 回调，不认识任何 VCS。项目树里的重命名和移动先交给拥有该文件的 Provider（`svn move`）；Provider 不跟踪这个文件或拒绝时，退回原来的磁盘移动。源路径和目标路径都要用 Core 的 `vcs.ownerOf` 判断归属，两端都属于同一个插件根才交给 Provider：嵌套的 Git 仓库、还没选 VCS 的歧义目录都不属于外层工作副本。只按“最深的插件根”判断会把移进嵌套 Git 仓库的文件也交给 `svn move`。等待 Core 判断归属期间如果开始了别的操作，移动直接退回磁盘移动，和操作开始前就在运行时一样，不报“等正在运行的操作结束”。
- 刷新：工作区监听和项目树一样隐藏 VCS 元数据目录。内置隐藏列表里有 `.git` 和 `.svn`，与 IDEA 默认的忽略列表一致；不隐藏的话，`.svn/pristine` 里每个文件的基线副本会进入项目树、搜索、本地历史和索引。所以每个插件根单独监听自己的标记目录，例如 `.svn`，或工作区开在工作副本子目录里时的 `../.svn`。只监听 `metadataPaths` 所在的标记目录，不监听整个外层工作副本。工作文件的变化仍走工作区事件，两路事件走同一条过滤和合并逻辑，合并后再刷新受影响的根。元数据目录里只有 Provider 声明的 `metadataPaths`（SVN 是 `.svn/wc.db`）会触发刷新。宿主自己的请求执行期间和结束后的短暂时间内忽略元数据变化，否则每次提交、甚至每次读状态都会再刷新一遍；代价是命令行在这段时间里的改动，要等下一次刷新才显示。元数据监听丢了事件，或标记目录消失时，按标记变化处理，重新识别根。标记目录隐藏后，工作区事件里看不到新出现的 `.svn`。所以新建的条目和它所在的目录如果不是已知的根，就在后台线程查一次有没有标记，有才重新识别，例如在工作区里 checkout 了新工作副本，或 update 拉下了 external。
- 生命周期：关闭工作区、切换工作区，以及原生项目窗口关闭（`shutdownProjectSession`，这时工作区可能被设置窗口保留而不关闭）都会在第一次挂起前清空 `VcsProvidersFeatureModel`：取消识别和刷新任务，停止该工作区启动中和运行中的 Provider 进程，停掉元数据监听。窗口关闭走 `shutdown()`，之后这个窗口的模型不再加载任何工作区：关闭时还在进行的工作区扫描随后调用 `loadVcsProviders` 也不会把 Provider 重新拉起来；关闭的会话模型不会被复用，所以不需要恢复入口。
- 歧义目录的选择按工作区存在应用偏好里（`Vcs.RootMappings.<工作区摘要>`），不写工作区，也不写 app bundle。识别时目录不再歧义，就丢掉旧选择。

P3 剩下的部分：编辑器 gutter 与 Annotate、交互式认证（`lithe/vcs/authenticate` 仍按未知请求回绝）、把 `lithe/vcs/execution` 执行报告接到项目控制台，以及在 Lithe Store 上架 SVN 插件。上架要等带 `vcsProviders` 能力的 Lithe 版本发布后再做，否则旧版本用户会在市场里看到装不上的插件；P1 合入后，插件仓库的 `sdk.lock.json` 也要改指向 `preview` 上的提交。

### 10. Git 什么时候、怎样接入

Git 接入不在本提案的范围内，这里只记下评审时已经确认的方向，供以后的提案使用：

- **先精简再接入。** 提交图投影在 Core 里已有一份（`git/graph.rs` 的 `project_graph`），但生产代码没有调用，macOS 和 Windows 又各写了一份布局；执行日志、Changelist、状态模型等确定性逻辑也是两端各一份。接入时按切片迁移，每一片两端同时切换，并在同一个 PR 里删掉旧路径。
- **Git 改成随应用内置的官方插件**，和 SVN 走同一个注册入口；通用界面不再直接依赖 `LitheGitModule`。是否搬到独立进程是传输方式问题，可以单独决定。
- **平台层功能先做在统一层**：三方合并工具、行级历史、Changelist、Shelf 在 IDEA 里都属于平台而不属于 git4idea，补齐时直接给所有 VCS 用。

## 考虑过的备选方案

### 每种 VCS 一套独立模块

最快能交付 SVN：照着 Git 模块再写一个 SVN 模块就行。但提交面板、变更列表、文件颜色、gutter、Changelist 都要复制，两端各一份，以后每加一种 VCS 再复制一遍。构建系统统一之前，Maven 专用类型已经证明这条路走不远，因此不采用。

### 把 Git 的全部能力都映射进统一层

界面只需要面对一套 API，看起来最“统一”。但 Rebase、Worktree、暂存区这些概念在 SVN 里不存在，要么让通用层变成 Git 的翻版，要么为了照顾最弱的 VCS 削掉 Git 的能力。IDEA 也没有这样做，因此只统一跨 VCS 成立的概念。

### 第一期就把 Git 包成内置 Provider

最初的方案是在 Core 里给现有 `git::*` 加一层转换，让 Git 和插件同时产出统一形状。评审时发现这样会把两端重复的逻辑和 Git 专属的结果类型原样带进统一层，以后再精简反而更难，因此改为第一期不接 Git，先用 SVN 把底层跑通（第 10 节）。

### Git 也改成插件进程

这样内置和插件完全对称。但 Git 是 Lithe 的核心体验，状态读取在热路径上，认证、取消和执行事件链路也刚稳定；第一期不动 Git。以后 Git 改成内置官方插件时，进程内还是进程外只是传输方式，可以单独决定。

### SVN 后端用 Rust 写成原生可执行文件

不需要用户安装 Node，启动也更快。但插件包要为每个平台和架构各编译一份、单独签名，macOS 上下载来的原生可执行文件还要处理 Gatekeeper 隔离；而 Node SDK 已经实现协议、取消和子进程清理，社区构建插件也在用。SVN 后端的工作主要是调用 `svn` 和解析 XML，不是性能热点，因此选 Node SDK。

### SVN 内置到宿主

首发更快，也不需要先做插件能力。但插件 VCS 这条链路要等到第三种 VCS 出现才会被真实验证，而且宿主里会出现 SVN 专属代码。用 SVN 作为第一个插件 Provider，可以在真实需求下验证整条插件链路，因此做成插件。

### SVN 作为官方插件留在主仓库

P2 的第一版就是这样：插件放在 `Plugins/mac/Official/SvnSupport/`，用 Lithe 的发布者私钥签名，进官方插件目录。好处是主仓库改 Core 时，SVN 端到端测试会一起跑。但插件每次修改都要走主仓库的 PR、CI 和官方签名发布，和 Lithe 的发版节奏绑在一起，主仓库 CI 还得装 svn；Go、PHP、Cargo 插件已经因为同样的原因搬到了独立仓库。改为社区插件后，插件可以独立发布，信任来自 Lithe Store 的审核、SHA-256 和安装确认框；契约回归由主仓库的样例 Provider 覆盖，SVN 自己的回归由插件仓库 CI 用固定版本 Core 覆盖。因此不采用。

### 用 SVNKit 或 libsvn 嵌入 SVN

不依赖用户安装 `svn` 命令行。但 SVNKit 需要 JVM，libsvn 需要为每个平台编译和签名 C 库，SVN 服务器端协议的兼容也要自己跟进。IDEA 的 svn4idea 本身已经改为调用 `svn` 命令行并解析 `--xml` 输出，因此不采用。

### 像 `buildSystems` 一样用纯声明式命令和映射实现 SVN

不需要常驻进程，读操作（`svn status --xml`、`svn log --xml`）确实可以用“命令 + 解码映射”表达。但提交、更新、冲突和认证需要多步交互和状态，声明式写不出来。纯声明式可以留给以后的只读 VCS，不作为主路径。

## 验收标准

- P1：清单校验接受和拒绝的情况都有 fixture；根识别覆盖嵌套、歧义和 Git worktree 文件标记；插件回复的校验用例全部通过；用 Node SDK 写的假 Provider 经真实 Core 会话完成协商和每种请求，未协商成功的进程收不到 `lithe/vcs/*` 请求。
- P2（在插件仓库 CI 中运行）：SVN 插件对录制的 `svn status/info/log/blame --xml` 样例解析正确；在本地 `svnadmin create` 建立的 `file://` 仓库上完成状态、提交、更新、回滚、add/move/delete、Annotate、文件历史和冲突显示。
- P3：macOS 上安装 SVN 插件后完成安装审查、根识别、文件颜色、gutter、提交、回滚、更新和进程清理；停用或卸载插件后进程退出，它的根从界面消失；Git 项目的行为没有变化；密码不出现在进程参数、控制台和日志中。
- 每个阶段都运行对应的 Core、契约、Note 和平台验证脚本；Windows 的结论只来自 Windows 上的实际运行。

## 风险

- **统一层只被一种 VCS 验证过。** 第一期只有 SVN 用统一层，模型里可能藏着 SVN 的偏见。缓解办法：模型只收第 2 节表里 Git 和 SVN 都成立的概念，Git 专属的暂存维度已经作为可选能力进入 fixtures；Git 接入时如果发现缺口，按能力版本加字段。
- **Git 仍在快速变化。** Issue 评论里提到 Git 还没稳定。第一期不碰 Git，`git.*` 不冻结。
- **状态读取是热路径。** SVN 在大工作副本上 `svn status` 较慢。第一版每次查整个根，宿主先合并刷新事件、限制刷新频率；实测太慢时再按能力版本加按路径的增量查询。
- **混合根和嵌套根。** Git 仓库里嵌套 SVN 工作副本时，文件必须只归属一个根，否则会重复显示或重复提交。识别规则和用户映射都要有 fixture 覆盖。
- **插件进程常驻的成本。** 只在识别到对应根时启动，关闭工作区即回收，规则与构建 Provider 相同。
- **回退方式。** 每个阶段都只新增路径，停用 SVN 插件即回到现状。

## 适用范围

- `rust/lithe-core/src/vcs/`
- `rust/lithe-core/src/plugins/`
- `rust/lithe-core/src/lsp/interface/`
- [SVN 插件仓库](https://github.com/Lithe-IDEA/lithe-plugin-svn)
- `rust/lithe-core/src/git/`
- `rust/lithe-git-host/`
- `macos/Sources/LitheGitModule/`
- `macos/Sources/Lithe/Views/Git/`
- `macos/Sources/Lithe/Views/Workspace/`
- `macos/Sources/Lithe/Views/Vcs/`
- `macos/Sources/Lithe/Platform/MacOS/Vcs/`
- `macos/Sources/Lithe/Application/Features/VcsProvidersFeatureModel.swift`
- `macos/Sources/Lithe/Views/Editor/`
- `windows/tauri/src/features/git/`
- `shared/contracts/plugins/v1/`
- `shared/contracts/vcs-provider-v1.md`
- `shared/fixtures/vcs/`
