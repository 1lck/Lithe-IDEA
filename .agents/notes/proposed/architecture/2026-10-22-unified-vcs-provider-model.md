# Agent 笔记：统一 VCS 模型与 Provider 接入

状态：提议中

## 先说结论

Lithe 现在只认识 Git：Rust Core、macOS 和 Windows 的变更列表、提交面板、项目树文件颜色、编辑器行标记（gutter）都直接使用 Git 类型。[Issue #827](https://github.com/1lck/Lithe-IDEA/issues/827) 要求支持 SVN，以后还可能有 Mercurial、Perforce 等其他 VCS（Version Control System，版本控制系统）。

提案照搬[构建系统插件契约](../../implemented/architecture/2026-10-17-build-system-plugin-contract.md)已经验证过的做法：Rust Core 定义一份与具体 VCS 无关的统一模型和 `vcs.*` 命令，每种 VCS 是一个 Provider（回答“这个目录现在是什么状态、怎样提交、怎样回滚”的实现）。Git 是内置 Provider，只在 Core 里加一层转换，现有 `git.*` 代码和契约不动；SVN 作为官方插件，以插件进程的形式接入，后续其他 VCS 走同一条路。

对日常开发的影响：在统一层落地之前，新的 Git 功能照常写在 Git 模块里；但凡是“任何 VCS 都会有”的界面（文件状态颜色、gutter、提交、回滚、文件历史、Annotate），不要再新增对 Git 类型的直接依赖，等统一层就绪后改读 `vcs.*`。

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
| Rust Core 的 `vcs` 模块 | `rust/lithe-core/src/vcs/`（新） | 统一模型、`vcs.*` 命令、Provider 注册表（Registry，按 VCS ID 登记和查找实现的目录）、根目录识别、插件回复的解码和校验 | 启动进程、弹窗、存储 |
| 宿主 | macOS 新的 VCS 工作区模块；Windows 的 VCS 状态 store | 根映射与用户覆盖、文件监听触发刷新、Changelist、Shelve、凭据交互、Provider 进程生命周期、项目控制台 | 解析任何 VCS 的输出 |
| Provider | Git：Core 内置；其他 VCS：插件进程 | 回答状态、基线内容、历史、Annotate、提交、回滚、更新等事实 | 界面和跨根聚合 |

内置 Git Provider 在 Core 内部直接调用现有 `git::*` 函数，再把结果转换成统一形状。`git.*` 命令保持原样，现有 Git 界面和老调用方不受影响。插件 Provider 的回复先由 Core 校验（路径必须在根内、排序稳定、数量和大小有上限），再转换成和 Git 完全相同的形状。所以宿主拿到的 `vcs.status` 结果不区分来自哪个 Provider。

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

每个 Provider 声明自己支持哪些能力，界面只按能力出现入口。必备能力是状态、基线内容、提交和回滚；其余都可选：历史、文件历史、Annotate、更新、推送、暂存区（staging）、分支、冲突处理、文件操作跟踪、锁、属性、清理等。

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

字段和方法的草案见 [VCS Provider 契约草案](../../../../shared/contracts/vcs-provider-v1.md)，示例数据见 [`shared/fixtures/vcs/model-v1.json`](../../../../shared/fixtures/vcs/model-v1.json)。草案在 P1 落地前都可以修改，任何 Core 命令、清单校验和宿主能力表都还不接受这些名字。

### 7. SVN 作为官方插件

SVN 插件调用用户系统里的 `svn` 命令行，解析它稳定的 `--xml` 输出。IDEA 的 svn4idea 也是这样做的（`plugins/svn4idea/src/org/jetbrains/idea/svn/status/CmdStatusClient.kt` 使用 `svn status --xml`）。这和 Lithe 使用系统 Git 的方式一致，不需要打包 JVM 或跨平台编译 libsvn。

凭据规则沿用[Git 执行与项目控制台](../../implemented/architecture/2026-09-12-git-execution-and-project-console.md)：SVN 自己的认证缓存优先回答；需要交互时，Provider 通过协议向宿主发出认证挑战，宿主复用现有认证界面。命令始终带 `--non-interactive`，密码通过 `--password-from-stdin` 传入，不出现在命令参数、控制台和日志里，Lithe 也不保存密码。

### 8. 宿主接手与 VCS 无关的状态

- **根映射**：一个工作区可以同时有 Git 和 SVN 根。文件归属最深的那个根；同一目录同时出现两种标记时，要求用户在设置里选择，不能猜。IDEA 用 `VcsDirectoryMapping` 保存这种映射。
- **Changelist 和 Shelve**：从 `LitheGitModule` 上移到宿主的 VCS 层，存储键从“Git 仓库路径”改为“VCS 根 ID”，迁移时继续读取旧格式。IDEA 的 `ChangeListManagerImpl` 同样在 `platform/vcs-impl`，不属于任何一种 VCS。
- **监听刷新**：[单仓库 Git 状态监听提案](../bug-fix/2026-09-13-single-repository-git-status-observation.md)里要求的监听范围，扩展成“每个 Provider 声明的元数据目录”，例如 SVN 的 `.svn/wc.db`。
- **项目控制台**：现有 Git 执行事件多带一个 VCS ID 字段，插件 Provider 用通知上报实际执行的命令和输出。展示、折叠和脱敏规则不变。

### 9. 分阶段落地

| 阶段 | 内容 | 完成标志 |
| --- | --- | --- |
| P0 | 本提案、契约草案和 fixtures | 评审通过 |
| P1 | Core `vcs` 模块：类型、注册表、根识别；内置 Git Provider 的读路径（状态、基线内容、历史、文件历史、Annotate） | 同一批测试仓库上 `vcs.*` 与 `git.*` 的结果等价 |
| P2 | macOS 只读的通用界面改读 `vcs.*`：项目树颜色、gutter、状态栏 | Git 项目的行为和外观没有变化 |
| P3 | 插件 `vcsProviders` 能力、`litheVcs` 协商、宿主 Provider 会话（复用构建 Provider 的会话代码）；Changelist/Shelve 上移；通用提交面板 | 测试用的假 Provider 插件跑通完整流程 |
| P4 | SVN 官方插件 MVP | 见验收标准 |
| P5 | Windows 按同一契约和 fixtures 接入 | Windows 通过同一组 fixtures |

## 考虑过的备选方案

### 每种 VCS 一套独立模块

最快能交付 SVN：照着 Git 模块再写一个 SVN 模块就行。但提交面板、变更列表、文件颜色、gutter、Changelist 都要复制，两端各一份，以后每加一种 VCS 再复制一遍。构建系统统一之前，Maven 专用类型已经证明这条路走不远，因此不采用。

### 把 Git 的全部能力都映射进统一层

界面只需要面对一套 API，看起来最“统一”。但 Rebase、Worktree、暂存区这些概念在 SVN 里不存在，要么让通用层变成 Git 的翻版，要么为了照顾最弱的 VCS 削掉 Git 的能力。IDEA 也没有这样做，因此只统一跨 VCS 成立的概念。

### Git 也改成插件进程

这样内置和插件完全对称。但 Git 是 Lithe 的核心体验，状态读取在热路径上，认证、取消和执行事件链路也刚稳定；搬到进程外对用户没有收益，迁移风险却很大。内置 Provider 和插件 Provider 共用 Core 里同一套转换和校验，结果形状已经对称，因此不搬。

### SVN 内置到宿主

首发更快，也不需要先做插件能力。但插件 VCS 这条链路要等到第三种 VCS 出现才会被真实验证，而且宿主里会出现 SVN 专属代码。用 SVN 作为第一个插件 Provider，可以在真实需求下验证整条插件链路，因此选择官方插件。

### 用 SVNKit 或 libsvn 嵌入 SVN

不依赖用户安装 `svn` 命令行。但 SVNKit 需要 JVM，libsvn 需要为每个平台编译和签名 C 库，SVN 服务器端协议的兼容也要自己跟进。IDEA 的 svn4idea 本身已经改为调用 `svn` 命令行并解析 `--xml` 输出，因此不采用。

### 像 `buildSystems` 一样用纯声明式命令和映射实现 SVN

不需要常驻进程，读操作（`svn status --xml`、`svn log --xml`）确实可以用“命令 + 解码映射”表达。但提交、更新、冲突和认证需要多步交互和状态，声明式写不出来。纯声明式可以留给以后的只读 VCS，不作为主路径。

## 验收标准

- P1：在同一批 Git 测试仓库上，`vcs.status`、基线内容、历史、文件历史和 Annotate 与对应 `git.*` 结果等价；大仓库上 `vcs.status` 比 `git.status` 只多出转换开销，不额外启动进程。
- P2：macOS 项目树颜色、gutter 和状态栏改读统一模型后，Git 项目的现有测试和截图检查全部通过，行为没有变化。
- P3：一个只用于测试的假 VCS Provider 插件完成安装审查、协商、状态、提交、回滚和进程清理；停用或卸载插件后进程退出，它的根从界面消失；未协商成功的进程收不到 `lithe/vcs/*` 请求。
- P4：SVN 官方插件在本地 `svnadmin create` 建立的 `file://` 仓库上完成状态、提交、更新、回滚、add/move/delete 跟踪、Annotate、文件历史和冲突显示；密码不出现在进程参数、控制台和日志中。
- 每个阶段都运行对应的 Core、契约、Note 和平台验证脚本；Windows 的结论只来自 Windows 上的实际运行。

## 风险

- **Git 仍在快速变化。** Issue 评论里提到 Git 还没稳定。缓解办法：统一层只包装稳定的概念，`git.*` 不冻结，Git 专属功能继续在 Git 模块里演进。
- **状态读取是热路径。** 内置 Git Provider 在 Core 内直接转换，不额外起进程。SVN 在大工作副本上 `svn status` 较慢，由 Provider 按变化路径做增量查询，宿主合并刷新事件。
- **Changelist 和 Shelve 的存储迁移。** 改变存储键可能丢失用户已有分组。迁移时保留读取旧格式，并用旧数据做回归测试。
- **混合根和嵌套根。** Git 仓库里嵌套 SVN 工作副本时，文件必须只归属一个根，否则会重复显示或重复提交。识别规则和用户映射都要有 fixture 覆盖。
- **插件进程常驻的成本。** 只在识别到对应根时启动，关闭工作区即回收，规则与构建 Provider 相同。
- **回退方式。** 每个阶段都只新增路径。P2 切换后保留旧读取路径一个版本，出问题可以切回。

## 适用范围

- `rust/lithe-core/src/git/`
- `rust/lithe-git-host/`
- `macos/Sources/LitheGitModule/`
- `macos/Sources/Lithe/Views/Git/`
- `macos/Sources/Lithe/Views/Workspace/`
- `macos/Sources/Lithe/Views/Editor/`
- `windows/tauri/src/features/git/`
- `shared/contracts/plugins/v1/`
- `shared/contracts/vcs-provider-v1.md`
- `shared/fixtures/vcs/`
