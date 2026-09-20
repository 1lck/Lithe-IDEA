# Agent 笔记：工作区依赖浏览器与语言服务器 Provider 边界

状态：已实现

## 先说结论

依赖侧栏只展示语言服务器或语言 Provider 注入的项目模型，不再读取
`RunService.configurations`，也不根据启动目录猜源码根。一个语言只显示一个入口；
该语言有多少个启动服务，不会改变依赖侧栏的结构。

Lithe 负责语言会话生命周期、取消、过期结果保护、确定性排序和 UI。源码根、构建
输出和第三方依赖属于语言引擎；没有注册依赖贡献器的语言显示为空，不回退到文件
扫描或运行服务。

## 问题

运行配置描述“怎样启动一个进程”，不等于编译器或语言服务器看到的项目模型。
同一个 Node.js 源码可以有 API、Worker 等多个启动入口；Java 的 Maven/Gradle 模块
也可能有多个 Main 类。用运行服务生成依赖树会重复展示同一份源码，并遗漏生成源码、
自定义输出目录、模块路径和语言服务器已经解析的 classpath。

依赖关系也不是标准 LSP 方法。不同语言需要使用各自公开的扩展命令或 Provider API，
因此 UI 不能直接发送 Java 命令，更不能为每种语言写路径规则。

## 决策

- `LanguageDependencyFeatureModel` 位于 `LitheLanguageIntelligenceModule`。它从工作区
  文件清单中选择已注册的语言依赖贡献器，并把每个语言投影成一个
  `LanguageDependencyDescriptor`。
- `LanguageDependencyProviding` 是语言依赖贡献入口。实现通过对应的
  `LanguageToolingSessionManager` 会话读取项目事实；不得读取 `RunService`、启动配置或
  机器级依赖缓存，也不得递归扫描工作区来重建上游项目模型。
- 侧栏展开语言时才解析依赖。工作区切换、文件变化和手动刷新都会更新 generation；
  较早请求返回后必须以 `CancellationError` 丢弃，不能污染新工作区。
- Java 贡献器复用 JDTLS 的 `java.project.getAll` 和 `java.project.getSettings`。后者读取
  `org.eclipse.jdt.ls.core.sourcePaths`、`outputPath` 和 `referencedLibraries`，分别形成
  `Source Code`、`Build Outputs` 和 `Dependencies`。多模块结果按规范化路径去重并排序。
- 依赖侧栏不再创建 `.lithe/dependencies/config.json` 或 `index.json`。JDTLS 持有自己的
  项目模型和缓存；Lithe 不保存第二份可能过期的依赖真相。
- 路径默认不直接显示。用户点击路径节点后，侧栏临时显示可横向滚动的完整路径条带，
  三秒后自动收起；这只是展示行为，不改变依赖模型。
- 新语言要显示依赖，必须在语言智能模块中注册自己的贡献器，并复用该语言服务器公开
  的项目模型能力。SwiftUI 侧栏不得按 Java、Node.js、Rust 等语言名称分支。

正确做法示例：Java Provider 向现有 JDTLS 会话请求项目 source paths 和 libraries，
再返回语言无关的 `DependencyGraph`。

不要这样做：从三个 Node.js `RunConfiguration` 生成三个依赖入口，或者看到
`package.json` 后自行遍历 `node_modules`。

## 考虑过的备选方案

- **从运行服务列表生成依赖树**：已否决。启动入口和源码所有权不是同一个概念，容易
  重复展示同源服务，也会形成与语言服务器冲突的项目模型。
- **按 Provider 和运行配置源码根聚合**：已实现过但被替换。它能减少重复行，仍然依赖
  运行服务推导源码根，无法覆盖没有运行配置的模块和上游生成路径。
- **保留 `.lithe/dependencies` 让用户手工补路径**：已否决。手工覆盖会让 Lithe 成为第二
  份依赖真相；上游模型变化后，缓存和排除项可能继续遮蔽真实结果。
- **侧栏直接扫描 Maven 本地仓库或 `node_modules`**：已否决。扫描无法可靠判断依赖属于
  哪个项目模型，也带来不可预测的性能和机器环境差异。
- **为所有 LSP 提供通用目录猜测回退**：已否决。LSP 标准没有依赖协议；没有贡献器时
  明确显示为空，比展示似是而非的树更可诊断。

## 后果

依赖侧栏和 Run 模块不再互相激活或共享状态。多个同语言服务天然聚合为一个语言入口，
Java 多模块项目使用 JDTLS 已导入的真实源码根、输出目录和依赖库。工作区不再产生
依赖浏览器专用 JSON 文件，文件监听也不需要为这些文件设置例外。

代价是当前只有 Java/JDTLS 注册了依赖贡献器；Node.js、Go、Rust、Python 等语言在各自
Provider 接入成熟的上游项目模型前不会显示依赖。语言服务器启动或项目导入失败时，
侧栏会展示该会话的真实错误，而不是退回到不完整的猜测结果。

## 验证

- `swift build --target LitheLanguageIntelligenceModule`
- `swift build --target LitheExecutionModule`
- `swift build --target Lithe`
- `swift test --filter dependencyBrowser`
- `./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh`
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter dependencyBrowser`
- `./scripts/verify-agent-notes.sh`
- `./scripts/verify-service-boundaries.sh`

## 适用范围

- `macos/Sources/LitheCoreContracts/Dependencies/DependencyContracts.swift`
- `macos/Sources/LitheLanguageIntelligenceModule/Dependencies/LanguageDependencyFeatureModel.swift`
- `macos/Sources/LitheLanguageIntelligenceModule/Services/LanguageToolingSessionManager.swift`
- `macos/Sources/LitheLanguageIntelligenceModule/Module/LanguageIntelligenceFeatureGraph.swift`
- `macos/Sources/Lithe/Models/AppModel/AppModel+Dependencies.swift`
- `macos/Sources/Lithe/Views/Workspace/DependencySidebarView.swift`
