# Agent 笔记：Git 仓库发现与切换边界

状态：已实现

## 先说结论

工作区的 Git 列表不应自动纳入 `.build/checkouts` 等缓存中的依赖仓库。
自动发现默认跳过隐藏目录和内置构建目录，但保留工作树容器及用户显式打开的目录。
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
- Git 忽略规则决定文件是否由父仓库跟踪，不决定是否纳入另一个独立仓库。文件树的用户
  可见性覆盖也不隐式改变 Git 管理范围。本次只统一内置排除规则，不增加持久化设置。
- macOS 在活动仓库真正变化时，先取消旧历史请求并用旧根目录关闭游标，再清理旧引用、
  提交、文件详情、比较和过滤结果。目标仓库历史读取失败时，不能继续展示原仓库可操作的提交。
- 跨仓库选分支使用一次 `selectRepository(root, reference:)`。普通仓库切换回到目标的
  `HEAD`；分支点击直接查询目标引用，省去一次中间历史读取。过期请求继续由已有代际校验拦截。

正确做法：父项目扫描不进入 `.build`，显式打开依赖仓库仍可正常使用 Git。
不要这样做：只在引用面板隐藏依赖仓库，让状态聚合仍然读取它们；也不要在新仓库里查询旧分支。

## 考虑过的备选方案

- 继续全量扫描、仅隐藏 UI 行：后台仍读取依赖状态，提交范围和扫描成本没有修复。
- 无例外地跳过所有隐藏目录：会丢失 `.worktrees` 中用户主动创建的工作树。
- 完全按 `.gitignore` 排除仓库：用户常用它忽略工作树容器或独立源码 checkout，不能等同于
  仓库管理设置。这里复用已有扫描和 Git 所属根查询，没有重新实现 Git 忽略语义。
- 切换后遇到无效分支再回退：错误请求和控制台噪音已经发生，且旧提交状态仍可能留在界面。

## 后果

两端默认仓库列表不再包含隐藏缓存及常见构建产物，扫描也能在这些目录入口停止。
自定义隐藏容器中的源码仓库需要显式打开；如要支持更广的自动纳入策略，应增加明确设置，
不能重新放开所有构建缓存。此次不新增下载、缓存、持久化目录或运行时资源写入。

## 验证

- `rust/lithe-core/src/tests/git_repository_discovery.rs` 使用真实 Git 和有界 Core 调用，
  覆盖共享可见性 fixture、隐藏根目录、所属父仓库、真实链接工作树、扫描深度和符号链接。
- `macos/Tests/LitheGitModuleTests/GitModuleTests.swift` 覆盖普通切仓库、直接选目标分支、
  旧游标归属及新历史读取失败后的旧状态清理。
- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`
- `./scripts/verify-runtime-bundle-immutability.sh`
- `./scripts/verify-shared-contracts.sh`
- `./scripts/verify-agent-notes.sh`

## 适用范围

- `rust/lithe-core/src/git/mod.rs`
- `rust/lithe-core/src/project/files.rs`
- `macos/Sources/LitheGitModule/Application/GitFeatureModel.swift`
- `macos/Sources/Lithe/Views/Git/GitLogView.swift`
- `windows/tauri/src/features/git/api/git-repo-api.ts`
- `shared/contracts/rust-core-api.md`
- `shared/fixtures/workspace/repository-visibility-v1.json`
