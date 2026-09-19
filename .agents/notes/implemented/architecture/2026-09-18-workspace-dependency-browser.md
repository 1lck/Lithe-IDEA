# Agent 笔记：工作区依赖浏览器与运行服务 Provider 边界

状态：已实现

## 先说结论

依赖侧栏的根节点来自当前工作区的运行服务配置，而不是 Java、Maven 或某个全局缓存目录。每个运行服务由语言/构建 Provider 提供身份和路径补充，侧栏只展示统一的依赖树模型；因此 Go、Node、Rust、Python 和未知的进程服务可以使用同一套界面。

路径配置和索引分别保存在工作区的 `.lithe/dependencies/config.json` 与 `.lithe/dependencies/index.json`。索引输入没有变化时直接复用；依赖管理文件变化只使受影响服务的索引失效，不会因为一次依赖编辑就递归扫描整个工作区。Maven 仍然只负责自己的构建工具窗口和 Java 项目模型，依赖侧栏不改变 Maven UI。

## 问题

不同语言从运行服务得到的源代码、构建产物和第三方依赖位置不同。把这些规则写进项目侧栏会让 UI 依赖 Java，也无法让插件声明自己的依赖管理文件。另一方面，用户需要看到运行时没有自动发现的源码目录或生成目录，并能持久化排除某个目录及其子目录。

## 决策

- `RunService.configurations` 是依赖侧栏的服务清单。`Current File` 和 disabled 配置不显示；服务名称、Provider 名称和图标都来自运行配置。
- `DependencyResolutionContext`、`DependencyNode`、`DependencyGraph` 和 `WorkspaceDependencyProvider` 位于 `LitheCoreContracts`。Provider 只消费运行服务已经确认的路径和用户 JSON 配置，不访问 home 目录，也不自行递归发现缓存。
- 当前通用 Provider 是 `RunServiceDependencyProvider`。它把服务配置中的 `modulePath`、工作目录、源文件入口和显式 JSON 路径分成 `Source Code`、`Build Outputs`、`Dependencies` 和 `Additional Search Paths` 四组。未来语言插件应在自己的 Provider 元数据中声明同样的输入文件和路径补充规则，不要把语言分支加到侧栏。
- 用户在服务行右侧的齿轮中配置源代码、构建产物、依赖和额外搜索路径；右键路径可以排除目录。排除项按工作区相对路径保存到对应服务的 `excludedPaths`，匹配该目录本身及所有子路径。
- 每个服务的索引签名包含服务 ID、Provider ID、运行时路径、用户配置和 Provider 负责的依赖管理文件摘要。签名一致时复用 `index.json`；配置或管理文件变化只删除对应服务索引。
- 文件监听只转发变化路径。`.lithe/dependencies` 元数据不发送给 Java 语言服务；索引文件不会触发工作区快照或项目服务重载，配置文件变化才重新读取运行服务配置。
- Maven 的项目模型、构建任务、profiles 和原有工具窗口继续由 `MavenService` 与 `MavenView` 管理。通用侧栏只通过只读回调消费 Maven 已经解析出的 artifact 路径；它不会启动 Maven 或扫描本地仓库，也不修改 Maven 配置 JSON。

## 考虑过的备选方案

- **侧栏直接扫描 Maven 本地仓库**：无法证明 JAR 属于当前运行服务，也会把机器环境和 Java 绑定在一起，因此否决。
- **把依赖树放进 Maven 工具窗口**：会破坏 Maven 原有导航，并阻止非 Java 服务使用依赖树，因此否决。
- **每种语言复制一套侧栏和索引状态**：会让排除、缓存和监听行为出现差异，因此采用语言无关合同和 Provider。
- **每次点击或打开工作区递归扫描**：大型仓库会产生不可预测的延迟，因此只使用已有运行服务路径、工作区文件快照和持久化索引。

## 后果

依赖浏览器可以在没有 Java 或 Maven 项目模型的工作区中显示运行服务；新增语言通常只需提供运行配置和 Provider 元数据。配置与索引分离后，用户路径不会和构建工具配置互相覆盖，索引也能独立失效。

代价是当前 Provider 对未知生态只能显示运行服务明确提供的路径；它不会猜测全局依赖缓存位置。未来接入语言插件时，需要把依赖管理文件声明加入插件元数据，并由对应 Provider 提供 classpath 或源码包，而不是在 `RunService` 或 View 中增加语言名称判断。

## 验证

- `swift build --target LitheExecutionModule`
- `swift build --target Lithe`
- `swift test --filter DependencyProviderTests`
- `swift test --filter 'dependencyBrowserUsesNonJavaRunServiceConfiguration|genericProviderUsesRunServiceIdentityAndPaths|dependencyPathConfigurationDecodesPartialJson'`
- `./scripts/verify-agent-notes.sh`
- `./scripts/verify-service-boundaries.sh`
- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`

## 适用范围

- `macos/Sources/LitheCoreContracts/Dependencies/DependencyContracts.swift`
- `macos/Sources/LitheExecutionModule/Dependencies/RunServiceDependencyProvider.swift`
- `macos/Sources/LitheExecutionModule/Services/RunService.swift`
- `macos/Sources/LitheExecutionModule/Application/ExecutionFeatureModels.swift`
- `macos/Sources/Lithe/Views/Workspace/DependencySidebarView.swift`
- `macos/Sources/Lithe/Views/Workspace/ProjectSidebarView.swift`
- `macos/Sources/Lithe/Platform/MacOS/Persistence/MacWorkspaceDependencyStore.swift`
