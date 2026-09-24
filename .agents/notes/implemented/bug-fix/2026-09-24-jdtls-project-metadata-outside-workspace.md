# Agent 笔记：JDT LS 的 Eclipse 项目文件不写进用户项目

状态：已实现

## 先说结论

打开 Maven/Gradle 项目后，Java 语言服务 JDT LS 以前会在每个模块根目录写入
`.project`、`.classpath`、`.factorypath` 和 `.settings/*.prefs`，多模块项目里一次出现几十个
未跟踪文件（#856）。现在 Rust Core 启动 JDT LS 时传入
`-Djava.import.generatesMetadataFilesAtProjectRoot=false`，这些文件改存到 Lithe 缓存目录里的
JDT 状态目录。以前版本留在项目里、且 Git 没有跟踪的旧文件，会在 JDT LS 启动前自动删除。
设置里只能隐藏 `.factorypath` 的“推荐规则”按钮是当时的应急方案，已经整条移除。

## 问题

JDT LS 自带一个文件系统插件 `org.eclipse.jdt.ls.filesystem`。它根据 JVM 系统属性
`java.import.generatesMetadataFilesAtProjectRoot` 决定这些 Eclipse 项目文件放在哪里：

- 属性不存在时，默认写到每个模块根目录。Lithe 以前没有传这个属性，所以落在这种情况。
- 属性为 `false` 时，写到 `-data` 状态目录下的
  `.metadata/.plugins/org.eclipse.core.resources/.projects/<项目名>/`。插件在列目录时
  仍然把它们当作存在于模块根目录，所以 m2e 导入、编译和跳转都不受影响。

这个开关是 JVM 启动参数，不是 LSP 配置。放进 `initializationOptions` 或
`didChangeConfiguration` 都不会生效。VS Code 的 Java 插件也是用启动参数传 `false`。

还有一个坑：只要模块根目录**已经存在**这些文件，JDT LS 就继续使用根目录那份。只加启动
参数的话，老用户项目里已有的文件永远不会消失。

## 决策

1. `rust/lithe-core/src/lsp/languages/jdt.rs` 在直接启动和 wrapper 启动两条路径都加入该属性，
   并把它列为适配器拥有的参数。目录（catalog）或用户传入的同名参数会被替换，重复适配
   结果不变。
2. `rust/lithe-core/src/lsp/languages/jdt_project_metadata.rs` 在引擎启动 JDT LS 前运行：
   - 遍历工作区，跳过隐藏目录、符号链接和 `java_workspace::IGNORED_DIRECTORIES`，
     只看含 `pom.xml`、`build.gradle`、`build.gradle.kts` 的模块目录。JDT LS 只会在这些
     目录生成文件。
   - 只删除 Git **没有跟踪**的文件。每个模块向上找最近的 `.git`（目录或文件）确定所属
     仓库，不需要起进程；同一仓库的候选文件合并成一次 `git::untracked_candidates`
     （`git ls-files`，按 16 KiB 分批，避开 Windows 命令行长度上限）。不在仓库里的模块
     直接跳过，不调用 Git；Git 查询失败时整批不删。
   - 不能只在工作区根目录查一次：嵌套仓库或子模块的文件不在外层索引里，会被误判为
     未跟踪而删掉。
   - `.settings` 里只删 `*.prefs`，其他文件保留；目录清空了才删除目录本身。
   - 删掉了任何文件，就同时删除当前工作区的 `-data` 状态目录，让这次启动重新导入。
     旧状态里记着“`.project` 在模块根目录”，继续用它会指向已删除的文件。
   - 删除是尽力而为。单个文件删除失败只意味着 JDT LS 继续用它，不阻止启动；
     只有状态目录重置失败才返回启动错误。
   - 删过文件时，会话日志记一条 `info`：“Removed Java project files that earlier versions
     left in the workspace”，detail 里列出删除的相对路径和是否重置了状态目录。Lithe 删了
     用户项目里的文件，必须能查到删了什么。
3. 两端共用引擎（`lsp/interface/engine.rs` 的 `start_server`），macOS 和 Windows 同时生效，
   平台代码不需要改。
4. 删除 macOS 设置“隐藏路径”里的“添加/移除推荐规则”按钮及其整条链路：
   `LSPGeneratedArtifactVisibility`、`LSPGeneratedArtifactGitExclude`、
   `SerialMainActorActionQueue`、`GitOperations.mutateLiteralLocalExcludePatterns`，以及只为它
   存在的 Core `git.write` 操作 `excludePatterns` / `unexcludePatterns`。Windows 从未实现该按钮。
   用户已经加入“隐藏路径”或 `.git/info/exclude` 的规则保持原样，需要时可自行删除。

正确做法：新的 JDT LS 启动参数放在 `jdt.rs` 的启动适配里，并加进
`is_jdt_owned_jvm_argument`。

不要这样做：为了“让 Lithe 生成的文件看不见”去扩充隐藏规则或写 Git 排除列表。文件仍在
磁盘上，换个工具或换台机器还会看到，本地排除列表也不会同步给团队。

## 考虑过的备选方案

- **扩充推荐隐藏规则**，把 `.classpath`、`.project`、`.settings` 也加进去：否决。只是藏起来；
  而且提交这些文件给 Eclipse 用户的团队，会被一并隐藏掉有意提交的文件。
- **把整个 `-data` 放进项目内的 `.lithe/`**（issue 的原始建议）：否决。JDT LS 只支持“模块根
  目录”和“`-data` 元数据区”两个位置。放进项目意味着索引、构建状态和日志（大项目几百 MB）
  都进仓库目录，还得另加忽略规则。
- **在工作区 key 里加布局版本号，强制所有人换新状态目录**：否决。会改变共享 fixture
  `shared/fixtures/lsp/jdt-workspace-key-v1.json` 的算法，并让所有用户重新导入一次；
  实际只有删过旧文件的工作区需要重置。
- **弹窗让用户确认后再删**：用户选择静默清理。安全边界改由“只删 Git 未跟踪文件，
  非 Git 项目不删”保证。

## 后果

- 收益：打开项目不再往用户目录写 Eclipse 文件；老项目升级后第一次打开即变干净，
  无需手动操作，两端一致。
- 代价：删过旧文件的工作区会完整重新导入一次 Java 项目。每次启动 Java 服务都会遍历一次
  工作区目录；仍留有这些文件的仓库（例如团队提交了 `.classpath`）每次启动多一次
  `git ls-files`，非 Git 项目不产生 Git 调用。
- 例外：Git 跟踪的这些文件、非 Git 项目里的旧文件会保留，JDT LS 继续使用它们。
  被 `.gitignore` 忽略的文件也属于未跟踪，会被删除。
- 被遗弃的旧状态目录不需要额外代码，两端的 `java.jdtCacheRetention` 会在 30 天后清掉。

## 验证

- `./scripts/verify-rust-core-comments.sh`
- `./scripts/verify-rust-core.sh`
- `./scripts/verify-shared-contracts.sh`
- `./scripts/verify-agent-notes.sh`
- `./scripts/test-macos.sh`

`jdt_project_metadata` 的测试覆盖：多层模块的未跟踪文件被删除且状态目录被重置；Git 跟踪的
文件和 `.settings` 里的非 prefs 文件保留；嵌套仓库里被内层仓库跟踪的文件保留；非 Git 工作区
不删除、不重置；无构建描述符的目录和 `node_modules`、`target` 下的副本不受影响。
`git::tests::pathspec_batches_stay_within_the_budget_and_keep_every_path` 覆盖分批。
`engine::tests::java_start_logs_legacy_project_files_it_removed` 覆盖从启动到日志的完整链路。`jdt.rs` 的启动参数测试覆盖两条启动路径都
带 `false`，并替换外部传入的 `true`。

## 适用范围

- `rust/lithe-core/src/lsp/languages/jdt.rs`
- `rust/lithe-core/src/lsp/languages/jdt_project_metadata.rs`
- `rust/lithe-core/src/lsp/interface/engine.rs`
- `rust/lithe-core/src/git/mod.rs`
- `shared/contracts/rust-core-api.md`
- `macos/Sources/Lithe/Views/App/SettingsView.swift`
