# Agent 笔记：工作区依赖浏览器与语言插件 Provider 边界

状态：已实现

## 先说结论

依赖侧栏只显示语言能力明确注册的依赖源，不把运行配置自动复制过来。语言插件从语言服务（LSP）或其上游项目模型取得工作区外的依赖根和虚拟文档，再交给统一的树模型。内置 Java 同样走这条入口：JDT LS 项目准备好后读取其已解析的 classpath；Docker Compose、Node 脚本和 Java 启动项仍在 Run 面板，但仅有运行配置不会进入依赖树。

路径配置和索引分别保存在工作区的 `.lithe/dependencies/config.json` 与 `.lithe/dependencies/index.json`。索引输入没有变化时直接复用；依赖管理文件变化只使受影响服务的索引失效，不会因为一次依赖编辑就递归扫描整个工作区。Maven 仍然只负责自己的构建工具窗口和 Java 项目模型，依赖侧栏不改变 Maven UI。

## 问题

运行配置表示怎么启动程序，不表示可浏览的外部依赖。一份项目可生成许多 Docker、Node 和 Java 启动项；直接拿它们做依赖树清单会出现重复的空服务。另一方面，用户仍需要手动加入特定源码或生成目录，并持久化排除某个目录及其子目录。

## 决策

- `RunService.registerDependencySource` 是统一的依赖源入口。宿主只在语言服务已激活、且其能力实现 `LanguageDependencyProviding` 时按语言 ID 注册；内置 Java 由 `LanguageIntelligenceCapability` 提供相同协议。打开侧栏不会自动激活 LSP。执行模块延迟激活时会重放已激活语言的注册，语言服务停用时撤销。运行配置不参与清单、索引键或依赖路径推导，Run 面板仍按原配置工作。
- `DependencyResolutionContext`、`DependencyNode`、`DependencyGraph` 和 `WorkspaceDependencyProvider` 位于 `LitheCoreContracts`。通用 `RunServiceDependencyProvider` 把插件路径和用户 JSON 配置分成 `Source Code`、`Build Outputs`、`Dependencies`、`Additional Search Paths` 四组；侧栏只显示非空组，不自行递归发现缓存。
- 插件的活跃 capability 可实现 `LanguageDependencyProviding`，提交已解析的 `LanguageDependencySnapshot`（源码、二进制、依赖根及虚拟 URI）。自动文件根只接受工作区外路径；工作区内的 `vendor`、`node_modules`、`bin` 不由声明或运行配置自动注入。用户在 JSON 中明确配置的工作区内路径仍然显示。快照调用只读取已有结果，不能启动构建、LSP 或包扫描。上游变化由插件通知宿主比较并刷新；内置通用 LSP 能力尚未实现依赖快照，Rust 必须由相应插件接入上游项目模型后才会自动出现。
- Java 在 JDT LS 项目准备状态变为 ready 后异步调用 `java.project.getAll`，只对当前工作区的项目调用 `java.project.getClasspaths`（runtime scope），收集工作区外路径并去重。管理文件变化通过已有文件监听转发给 JDT LS 后，合并短时间内的变化再做一次只读查询；若 JDT LS 报告配置任务正在执行，就取消该查询，等状态再次变为 ready 后读取。监听通知本身没有服务器确认回执，因此未报告配置进度的服务器只能采用合并延迟查询，不能保证在极慢的导入任务尚未报告状态时立即拿到最终模型；后续 ready 事件会再次同步。它不调用用于 Run/Debug 的 `vscode.java.resolveClasspath`，因为现有启动流程在该命令之前会构建工作区；也不扫描 Maven 本地仓库。查询失败只保留侧栏旧快照和日志，不改变 Maven 工具窗口。JDT LS 上游 `ProjectCommand.getClasspaths` 由其项目模型解析容器（包括 Maven），而 `getSettings` 的 `referencedLibraries` 只看原始 `CPE_LIBRARY`，会遗漏容器依赖。
- 依赖树的虚拟节点携带 URI，点击时以服务的语言 ID 路由到该语言的运行中 LSP。其他导航入口如果没有携带语言 ID，可依据插件声明的 `virtualDocumentSchemes` 寻找唯一归属；不唯一或服务休眠时明确失败，不把 URI 发给另一个语言服务器。
- 用户在语言行右侧的齿轮中补充源码、构建产物、依赖和额外搜索路径。每类的“浏览”先以工作区为起点，也可以通过系统文件夹面板跳到外部缓存；目录逐层列出直接子项，勾选当前目录、多个子目录或依赖归档后一次加入草稿，点“保存”才写入原有 JSON。工作区内存相对路径，工作区外存绝对路径；已添加路径不能重复勾选。逐行编辑保留在可展开区域，用于输入尚不存在的路径。这里不枚举整棵目录树，也不替代 LSP 提交的自动路径。右键路径可以排除目录；排除项按工作区相对路径保存到语言依赖源的 `excludedPaths`，匹配该目录本身及所有子路径。旧运行配置 ID 下的 JSON 路径不自动迁移，以免把脚本运行配置误认成外部依赖。
- 每个语言源的索引签名按固定 JSON 键序编码语言源 ID、Provider ID、用户配置和 Provider 负责的依赖管理文件摘要。索引另存插件提供的已解析快照：插件休眠时输入不变就复用完整的图；插件再次提供不同快照时才更新。旧版本运行配置索引不复用。新增、修改或删除管理文件会更新文件库存并让所属语言源失效，不递归扫描。
- 文件监听只转发变化路径。`pom.xml` 仍通知原有 Maven 服务，同时继续转发给 Java 语言服务，以便 JDT LS 更新项目模型和依赖快照；`.lithe/dependencies` 元数据不发送给 Java 语言服务，索引文件不会触发工作区快照或项目服务重载。其他语言插件负责根据自己的管理文件变化更新上游解析结果并通知宿主；宿主不会替插件猜测何时解析完成。
- Maven 的项目模型、构建任务、profiles 和原有工具窗口继续由 `MavenService` 与 `MavenView` 管理。Java 适配器优先使用 JDT LS 的外部 classpath；当 JDT LS 尚未给出第三方路径、且 Maven 树已经由用户或原有流程解析完成时，宿主只读投影该树中 `resolved` 的 artifact 到 Java 快照。仓库位置优先取项目现有 Maven 本地路径设置，否则取宿主既有的标准 Maven 缓存地址；只纳入实际存在的归档，不启动 Maven、不扫描仓库。Maven 项目需要重新加载时不复用旧树，其他语言不受影响。通用侧栏仍不读取 Maven 运行配置，也不修改 Maven 配置 JSON。

## 其他 LSP 如何接入

1. 在自己的 `LanguageSupportDeclaration.dependencies` 中声明实际管理文件名（例如 Rust 的 `Cargo.toml`、`Cargo.lock`），并让语言服务 capability 实现 `LanguageDependencyProviding`。不要为了出现侧栏行去创建运行配置，也不要把 Node、Docker 的启动项批量注册。内置语言可以像 Java 一样在自己的能力上实现协议；插件则由已有的 `registerLanguageDependencySourceIfAvailable` 在激活时统一注册。
2. 从该语言的上游项目模型或 LSP 已经解析出的结果生成 `LanguageDependencySnapshot`。将外部源码放在 `sourceRoots`、外部构建目录放在 `binaryRoots`、包目录或归档放在 `dependencyRoots`、非文件 URI 放在 `virtualDocuments`；使用当前工作区作为查询键。`dependencySnapshot` 必须同步返回缓存，侧栏展开不得启动语言服务、调用包管理器、扫描 home 或递归目录。没有已解析结果时返回 `nil`，让已有持久化索引先显示上次有效数据。
3. 当上游模型在管理文件变化后重新解析、或语言服务报告项目配置就绪时，更新缓存并调用 `setDependencySnapshotChangeHandler` 传入的回调。宿主负责比较快照、按语言源失效索引并持久化；插件不直接写 `.lithe/dependencies/index.json`。工作区切换、插件卸载和会话终止时撤销回调及旧工作区快照，不能把上一个项目的路径注入新项目。
   Java 的 Maven 补充是宿主中仅针对 Java 的兼容桥，不能当作新语言插件的通用依赖发现接口；新插件应直接提交自己的已解析结果。
4. 测试应覆盖：只有激活的语言能力才注册；管理文件变化仅刷新所属语言；重复与工作区内路径被过滤，显式 JSON 路径仍可见；会话停止与工作区切换不泄漏快照；索引输入不变时复用。不能假设所有 LSP 都有标准的“列依赖”方法，先核对对应服务器真实支持的只读项目模型接口。

## 考虑过的备选方案

- **侧栏直接扫描 Maven 本地仓库**：无法证明 JAR 属于当前语言源，也会把机器环境和 Java 绑定在一起，因此否决。
- **把依赖树放进 Maven 工具窗口**：会破坏 Maven 原有导航，并阻止非 Java 服务使用依赖树，因此否决。
- **每种语言复制一套侧栏和索引状态**：会让排除、缓存和监听行为出现差异，因此采用语言无关合同和 Provider。
- **每次点击或打开工作区递归扫描**：大型仓库会产生不可预测的延迟，因此只使用插件已有快照、工作区文件清单和持久化索引。
- **把所有语言的包缓存地址写进宿主**：缓存地址可能由工具链或项目配置改变。宿主不能依据语言名称或机器环境猜测；插件应消费上游已解析的路径，再按统一合同提交。
- **把全部运行配置当成依赖源**：Docker Compose 和 Node 脚本会产生大量无关或重复的空行，且路径来自启动入口而不是已解析的依赖，因此改为语言插件显式注册。
- **Java 只读 `referencedLibraries`**：JDT LS 原始 classpath 中的 Maven 容器不属于直接声明的 `CPE_LIBRARY`，因此无法覆盖本次截图中的第三方 JAR；采用上游已解析的 `getClasspaths`。

## 后果

依赖浏览器不依赖 Java/Maven，也不被 Docker/Node 运行项填满。配置与索引分离后，用户路径不会和构建工具配置互相覆盖，索引也能独立失效。

代价是仅有 LSP 启动配置和静态语言声明不再产生依赖树行。插件必须实现可选快照能力并显式注册；即使用户编辑 JSON，尚未注册的语言也不会凭旧运行配置自动出现。失效只刷新索引；上游重新解析依赖并发布新快照由对应语言插件负责。

## 验证

- `swift build --target LitheExecutionModule`
- `swift build --target Lithe`
- `swift test --filter DependencyProviderTests`
- `swift test --filter languagePluginContributesResolvedRootsAndVirtualDocuments`
- `swift test --filter javaDependencySnapshotReadsResolvedJdtClasspathsWithoutBuilding`
- `swift test --filter 'dependencyBrowserRequiresExplicitLanguageRegistration|runConfigurationsDoNotInjectDependencySources|genericProviderUsesRunServiceIdentityAndPaths|dependencyPathConfigurationDecodesPartialJson'`
- `swift test --filter DependencyPathSelectionTests`
- `./scripts/verify-agent-notes.sh`
- `./scripts/verify-service-boundaries.sh`
- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`

## 适用范围

- `macos/Sources/LitheLanguageIntelligenceModule/Services/LanguageToolingSessionManager.swift`
- `macos/Sources/LitheLanguageIntelligenceModule/Module/LanguageIntelligenceModule.swift`
- `macos/Sources/LitheExecutionModule/Dependencies/RunServiceDependencyProvider.swift`
- `macos/Sources/LitheExecutionModule/Services/RunService.swift`
- `macos/Sources/LitheExecutionModule/Application/ExecutionFeatureModels.swift`
- `macos/Sources/Lithe/Views/Workspace/DependencySidebarView.swift`
- `macos/Sources/Lithe/Views/Workspace/ProjectSidebarView.swift`
- `macos/Sources/Lithe/Platform/MacOS/Persistence/MacWorkspaceDependencyStore.swift`
- `macos/Sources/LitheModuleAPI/Plugins/PluginTypes.swift`
- `macos/Sources/LitheCoreContracts/Dependencies/DependencyContracts.swift`
