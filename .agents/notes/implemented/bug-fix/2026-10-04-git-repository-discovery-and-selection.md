# Agent 笔记：Git 仓库发现与切换边界

状态：已实现

## 先说结论

工作区的 Git 列表不应自动纳入 `.build/checkouts` 等缓存中的依赖仓库。
自动发现跳过隐藏、构建、被 Git 忽略及手动排除的目录；显式打开的根独立管理。
切换仓库时，历史请求、分支选择和提交选择必须一起切换，不能把旧仓库的引用传给新仓库。

## 问题

Issue #1064 中，文件树已经隐藏 `.build`，Git 却列出了 SwiftTerm、Sparkle 等依赖。
先前为避免漏掉嵌套仓库，自动发现仅跳过 `.git`，因此两份构建缓存会产生两组同名仓库。
父仓库的 `.gitignore` 仍然有效；这些条目来自对依赖仓库的独立发现和状态读取。

macOS 点击另一仓库的分支时，先刷新目标仓库，再设置目标引用。如果旧引用只在原仓库
存在，第一次历史读取就会报 `unknown revision`；旧分页游标还可能在替换根目录之后才关闭。

## 决策

- Rust Core 在进入子目录前排除以点开头的目录，并复用文件树已有的内置隐藏目录清单，
  避免 `.build`、`node_modules`、`target` 等规则在两端各维护一份。
- `.worktree` 和 `.worktrees` 是显式保留的工作树容器；继续识别目录或文件形式的 `.git`，
  并在容器内部照常跳过构建目录。这里只决定扫描范围，不根据目录名判断是否真是链接工作树。
- 过滤仅作用于递归子目录。直接打开 `.build/checkouts/SwiftTerm` 时仍然管理这个仓库；
  打开其源码子目录时也保留 Git 报告的所属仓库。普通 `vendor` 下的源码仓库仍可发现。
- 2026-11-02 起，进入子目录前通过原生 Git 批量查询忽略规则，并应用请求携带的手动排除。
  这是子仓库的自动纳入边界，不是已有仓库的文件过滤器；父仓库已跟踪修改和普通未跟踪文件
  仍由 Git 状态决定。分析开关、包含例外和树可见性设置不登记 Git 根。
- 显式工作区根分别传入自己的手动标记和根集合，父扫描不进入另行打开的嵌套根。
  工作树容器只豁免隐藏名称规则，不能豁免 Git 或手动排除。索引登记的 gitlink（父仓库
  保存的子模块提交引用）保留依赖发现；普通嵌套 `.git` 不享有这个例外。
- 忽略语法交给 Git 的批量 `check-ignore`，沿用 `ls-files` 对已跟踪后代的保护。
  Git 2.31 没有按模式筛选 gitlink 的查询开关，因此通过原有本机／远程进程所有者流式
  读取 NUL 分隔的索引记录，只保留子模块路径，不捕获整个大索引。取消、错误与进程树
  清理仍由同一所有者负责，标准错误保持有界捕获；临时记录只活到本次查询结束。
  查询失败传播原始错误分类，不能当作无忽略规则或空根列表。两端保留最后成功快照。
- macOS 手动标记保存后触发 Git 重发现；Windows 的发现缓存包含各根的排除快照。
  元数据、忽略文件、标记、根集合和焦点补偿触发更新；快照身份及请求代次共同拒绝旧结果。
  自动根被移除时回到有效活动根，清理旧引用与历史请求，不增加持久化 VCS 映射系统。
- macOS 在活动仓库真正变化时，先取消旧历史请求并用旧根目录关闭游标，再清理旧引用、
  提交、文件详情、比较和过滤结果。目标仓库历史读取失败时，不能继续展示原仓库可操作的提交。
- 跨仓库选分支使用一次 `selectRepository(root, reference:)`。普通仓库切换回到目标的
  `HEAD`；分支点击直接查询目标引用，省去一次中间历史读取。过期请求继续由已有代际校验拦截。

正确做法：父项目扫描不进入 `.build`，显式打开依赖仓库仍可正常使用 Git。
不要这样做：只在引用面板隐藏依赖仓库，让状态聚合仍然读取它们；也不要在新仓库里查询旧分支。

## 考虑过的备选方案

- 继续全量扫描、仅隐藏 UI 行：后台仍读取依赖状态，提交范围和扫描成本没有修复。
- 无例外地跳过所有隐藏目录：会丢失 `.worktrees` 中用户主动创建的工作树。
- 让被忽略的普通 checkout 永远自动纳入：旧策略保留了工作树容器，却让被排除的依赖仓库
  继续出现在提交面板。现在只保留显式打开和真实子模块依赖的例外；用户仍能主动管理该仓库。
- 直接用分析策略过滤 Git 状态：会隐藏已跟踪改动，而且分析开关和包含例外会暗中改变提交
  范围。只共享已保存的手动目录标记，Git 发现独立查询原生忽略，不读取全局分析策略。
- 切换后遇到无效分支再回退：错误请求和控制台噪音已经发生，且旧提交状态仍可能留在界面。

上游依据固定为 JetBrains/intellij-community 的
[`536da82a2cbce90820cbb0c158d91e78cda75d82`](https://github.com/JetBrains/intellij-community/commit/536da82a2cbce90820cbb0c158d91e78cda75d82)：
`VcsRootScanner` 通过项目内容根策略跳过排除目录，`VcsRootErrorsHandler` 自动注册时分别过滤
忽略和排除路径，`VcsRootDetectorTest` 的排除目录用例独立于 Git 忽略文件。
上游已注册映射及独立内容根有例外；本次只对齐自动发现边界，不声称实现完整映射管理。

## 后果

两端默认仓库列表不再包含隐藏缓存及常见构建产物，扫描也能在这些目录入口停止。
自定义隐藏容器中的源码仓库需要显式打开；如要支持更广的自动纳入策略，应增加明确设置，
不能重新放开所有构建缓存。此次不新增下载、缓存、持久化目录或运行时资源写入。

## 验证

- `rust/lithe-core/src/tests/git_repository_discovery.rs` 使用真实 Git 和有界 Core 调用，
  覆盖共享可见性 fixture、隐藏根目录、所属父仓库、真实链接工作树、扫描深度和符号链接。
- `macos/Tests/LitheGitModuleTests/GitModuleTests.swift` 覆盖普通切仓库、直接选目标分支、
  旧游标归属及新历史读取失败后的旧状态清理。
- 2026-11-02 本地验证通过 Core 1,588 项、Swift 相关组合 284 项、Windows 前端 84 项，
  另有 Git 进程生命周期 9 项和 Swift 桥接 9 项。前端回归包含失效缓存、迟到结果、
  防抖期间切换仓库、发现失败后的初始加载结束和最后成功快照保留。
- 隔离 macOS QA 项目已验收提交、分支和日志：Git 忽略及已保存手动标记移除普通
  子仓库根，父仓库已跟踪修改保留，显式打开被忽略子仓库仍可管理。手动标记通过隔离
  偏好域预置，未完成菜单操作的自动化验收。QA 实例已关闭，原有应用实例保持；
  bundle 的 1,434 项文件／链接及 Git 索引未变化。
- 本地 Swift 使用 6.4.2／Xcode 27.2，固定 6.3.3／Xcode 26.6 及 Windows 原生验收
  尚未完成；macOS 上 Windows Rust 检查仍只有基线已有的平台 API 编译错误。
- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`
- `./scripts/macos/verify/verify-runtime-bundle-immutability.sh`
- `./scripts/architecture/verify-shared-contracts.sh`
- `./scripts/agent-notes/verify-agent-notes.sh`

## 适用范围

- `rust/lithe-core/src/git/repository_discovery.rs`
- `rust/lithe-core/src/project/files.rs`
- `macos/Sources/LitheGitModule/Application/GitFeatureModel.swift`
- `macos/Sources/Lithe/Views/Git/GitLogView.swift`
- `windows/tauri/src/features/git/api/git-repo-api.ts`
- `shared/contracts/rust-core-api.md`
- `shared/fixtures/workspace/repository-visibility-v1.json`
