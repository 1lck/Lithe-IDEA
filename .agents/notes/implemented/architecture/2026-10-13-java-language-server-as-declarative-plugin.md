# Agent 笔记：Java 语言服务器是一个声明式插件

状态：已实现

## 先说结论

Java 的语言服务器 JDT LS（Eclipse 的 Java 语言服务器，提供补全、诊断和跳转）不再是 Lithe.app 里写死的一部分，而是官方插件 Java Support（`dev.lithe.plugin.java-support`）。插件包拥有 JDT LS、Lombok、调试和测试扩展，以及它运行所用的 JDK；`plugin.json` 声明这些文件在包内的位置和启动方式。这个插件随应用发行、默认启用，用户可以卸载和恢复。

宿主不再知道 JDT LS 或 JDK 放在哪里。它只做两件事：按插件的声明启动语言服务器；为声明了 `jdt` 宿主集成（由宿主实现、插件按名字启用的一段专用逻辑）的服务器启用 Java 的工程模型、`jdt://` 虚拟文档、测试和调试支持。

对日常开发的直接影响：需要某个插件专属的资源时，在该插件的清单里声明；不要在宿主的通用代码里按语言或工具的名字加分支。

## 问题

迁移之前 JDT LS 和声明式插件契约有三处不一致：

1. **资源在 app 里**。`scripts/package-app.sh` 把 JDT LS 和 JDK 拷到 `Contents/Resources/LanguageServers`，宿主扫描这个写死的目录来找 launcher、配置目录、Lombok 和扩展 jar。JDT LS 升级必须跟着 Lithe 发版，不写 Java 的用户也要带着这约 400 MB。
2. **契约表达不了它的启动方式**。API 1 只能声明“包内一个可执行文件加静态参数”，运行时只有 `go` 和 `node`。PHP 插件为此在包里放了启动脚本。
3. **宿主里有按语言 ID 的特判**。组合根里有多处 `descriptor.id == "java"`，工具发现里有专门找内置 `jdtls` 的分支。

## 决策

### 1. 三层划分

判断一项能力属于哪一层，只问一个问题：宿主实现它时，需不需要知道这是 Java。

| 层 | 含义 | 落在哪里 |
| --- | --- | --- |
| 通用启动 | 任何语言服务器都可能用到 | 契约 API 2 的 `launch`、启动模板、`initializationOptions` |
| 具名宿主集成 | 需要算法或跨模块数据，只能是宿主代码 | 清单里的 `hostIntegration`，目前只有 `jdt` |
| 插件资源 | 集成要读的文件 | `hostIntegration.resources`，由插件声明包内路径 |
| 宿主能力 | 仍由宿主内置实现提供的运行、测试、调试 | `hostIntegration.capabilities`，由插件逐项声明 |

字段语义以 `shared/contracts/plugins/v1/README.md` 为准，校验和模板展开只在 `rust/lithe-core/src/plugins/declarative.rs` 实现一次。

### 2. 契约 API 2 增加的内容

- `launch.kind: "runtime"`：用运行时启动包内入口文件，不需要启动脚本。运行时有两种来源：插件自带（`packagedRuntime`，宿主只启动包内这一个文件），或由宿主发现并按 `minimumVersion` 检查版本。
- 启动模板变量 `${pluginDir}`、`${stateDir}`、`${workspaceStateDir}`、`${arch}`，以及 `initializationOptions`。
- `settings`：用户可调的选项（整数、枚举、布尔），在启动模板里写 `${setting:<id>}` 引用。Java Support 用它暴露 JDT LS 的最大堆内存和日志级别，决策见 [声明式插件设置](../feature/2026-10-14-declarative-plugin-settings.md)。
- `hostIntegration`：`{ id, capabilities, resources }`。只有 `dev.lithe` 命名空间的插件可以声明，因为它让受信任的宿主代码去读插件的文件。
- 两个 Core 命令：`plugins.declarative.languageServerLaunchPlan` 展开启动计划，`plugins.declarative.checkRuntimeVersion` 解析并比较运行时版本。

API 1 的行为完全不变：已发布的 PHP、Go 包声明 API 1，其参数里的 `${...}` 仍按字面量传递。

### 3. `jdt` 集成复用现有的 Rust 适配层

Rust Core 里的 JDT 适配（JVM 参数、Equinox 配置区的可写副本、按工作区指纹划分的 `-data` 目录、Maven 设置同步、`jdt://`）已经成熟，Windows 也在用，所以没有重写。变化只在它的输入来源：

- 以前：`MacJDTLSLaunchResourceResolver` 扫描 app 内写死的目录。
- 现在：`MacPluginLanguageServerLaunchResolver` 按插件声明定位文件并确认它们在包内，`jdt` 集成把这些路径交给同一个适配层。

JDK 也一样：`ProjectRuntimeService` 不再问“app 内置的 JDK 在哪”，而是由 `jdt` 集成从插件的 `packagedRuntime` 声明读出位置后告诉它。

#### 宿主集成在 macOS 上的落点

`jdt` 相关的宿主代码不能散落在通用的 LSP 管线和组合根里，否则每加一个集成都要改一遍通用代码。划分如下：

- 通用契约 `LanguageServerHostIntegrationContracts.swift`：`LanguageServerHostIntegrationLaunch` 是集成为一次启动提供的内容（运行时可执行文件 + Rust Core 的启动参数）。运行时工厂和会话只把它原样带到 Rust Core，不解释。
- 通用注册表 `Plugins/HostIntegrations/MacLanguageServerHostIntegrations.swift`：协议 `MacLanguageServerHostIntegration`（启动、工作区指纹、重置与清理工作区状态、插件加载完成的通知），按清单里的 `hostIntegration.id` 查表分发。
- `jdt` 的全部实现在 `Plugins/HostIntegrations/Jdt/`：`MacJdtHostIntegration`（协议实现）、`MacJdtLaunchResources`（声明的文件到 JDT 启动资源）、`MacJdtWorkspaceState`（工作区索引）。
- 组合根 `MacServiceContainer` 只有一处注册这个集成，其余代码按 ID 路由，不再判断语言或集成名。

新增一个集成时，只需要新增一个实现协议的类型并在注册处加一行；Rust Core 的契约校验仍然决定哪些 ID 可以被声明。

### 4. 运行、测试、调试由插件声明后交还宿主

插件一旦声明某个语言，宿主就认为这个语言的进程类能力归插件所有：能力目录（`PluginLanguageProviderCatalogSource`）去掉运行、测试、调试标记，语言包注册表（`LanguagePackRegistry`）不再创建内置的测试提供方，运行和测试服务要求必须有插件的执行模块。这条规则是为 PHP、Go 这类整套由插件提供的语言定的，目的是插件缺失或停用时宿主不偷偷退回内置工具。

Java Support 只提供语言服务器，运行、测试、调试仍是宿主内置实现（JDWP 调试、JUnit/TestNG 测试运行器、Java main 启动），它们依赖的正是 `jdt` 集成加载的 Java Debug Server 和 Java Test 扩展包。迁移初版没有表达这一点，结果 Java 被当成“插件拥有但插件没提供”：

- 工具栏调试和“开始调试”提示 `Debug support is not available for <文件>`，不能打断点。
- 测试面板不再列出 Java 测试。
- “当前文件”和 Java main 运行配置提示 `Java does not provide project execution`。Spring Boot 等 Maven 框架配置走 `maven` 提供方，不受影响，所以只验证它会漏掉这个问题。

真实调试集成测试当时全部通过，因为它们直接组装调试会话，不经过应用里的能力目录。

现在由清单声明：

```json
"hostIntegration": { "id": "jdt", "capabilities": ["debug", "run", "testing"], "resources": { … } }
```

- 含义：这个语言的这几项能力由宿主自己的实现提供，集成负责提供它们需要的文件。没有列出、也没有 `executionProviders` 提供的能力，对这个语言就是不可用。
- Rust Core 校验三件事：能力必须是该集成实现的；能力依赖的资源必须已声明（`debug` 需要 `extensionBundleDirectories`，`testing` 还需要 `testRunner`）；同一能力不能既由集成又由插件的执行提供方提供。
- Swift 侧 `LanguageSupportDeclaration.hostCapabilities` 承载声明。能力目录据此加回标记；`MacServiceContainer` 按能力分别计算“必须由插件模块提供”的语言集合，交给语言包注册表、运行服务和测试服务；`RunWorkflowCoordinator` 对声明了 `run` 的语言不再要求激活执行模块。这些代码都只读声明，不判断语言名或集成名。
- 声明跟随安装状态，与语言归属一致：插件已安装但语言服务器被停用时，标记仍在，需要 JDT LS 的操作在执行时报告语言服务不可用。

这不是把 Java 的运行、测试、调试做成了扩展点，只是让“它们仍由宿主提供”成为插件的显式声明。扩展点仍需单独提案。

Java 的入口点、测试、调试、Maven 上下文等工作流仍是宿主里的 Java 功能代码（`LanguageToolingSessionManager` 的 `java*` 方法、`RustCoreBridge` 里与 Rust 命令一一对应的 JDT 请求类型），它们不是启动管线的一部分，要等运行/测试/调试成为扩展点时再处理。

### 4. 插件包的布局和组装

```text
dev.lithe.plugin.java-support/
├── plugin.json
├── language-server/            # JDT LS：plugins、features、lombok、java-debug、java-test
│   └── configuration/<arch>/   # 每个架构的 Equinox config.ini，只读
└── runtime/<arch>/             # JDK，每个架构一份
```

组装逻辑放在插件自己的目录：`Plugins/mac/Official/JavaSupport/assemble-package.sh`，由 `scripts/build-official-plugins.sh` 调用。`plugin.json` 精确写出入口 jar 的文件名，升级 JDT LS 后文件名对不上会在组装时失败，而不是等到用户打开 Java 文件。

`LitheOfficialPluginVerifier` 的规则随之调整：Mach-O 原生代码只允许出现在清单 `packagedRuntime` 声明的顶层目录内；包内任何位置都不允许符号链接。

### 5. 随应用发行、默认启用、可卸载

- **随应用发行**：Java 是主场景，首次启动必须离线可用，所以包在 `Lithe.app/Contents/Resources/OfficialPlugins/` 下，信任方式是 `sameTeamAsHost`（由应用自身的代码签名封住）。
- **默认启用**：随应用发行的包替代的是内置功能，它的模块默认开启；下载安装的插件，模块清单默认值仍是关闭，但用户在确认窗口里确认的首次安装（插件市场、社区源、磁盘包）会把它的模块记为启用，重启后直接生效，与 IntelliJ IDEA 安装即启用一致；更新和重装不改用户已有的启用选择。否则构建插件装好后 Build 工具窗口不出现，用户会以为界面没有注入。
- **卸载**：app bundle 运行时只读，包本身删不掉。卸载记录在用户目录的 `<app-support>/Lithe/Plugins/.removed-bundled-plugins.json`，宿主重启后不再注册这个插件，并在那次启动时删除它的语言服务器状态（卸载后到重启前，语言服务器仍在运行并写入该目录，所以不在点击时删除；重启前恢复则不会丢失索引）。插件管理里仍然列出它并提供“恢复”。
- **卸载时 JDT 状态的清理**：JDT LS 的工作区索引（`<cache>/Lithe/language-servers/jdtls/`）和 Equinox 配置区（`jdtls-configuration/`）在宿主缓存里，不在插件自己的 `PluginState/<plugin-id>/` 下，插件包管理器删不到。所以由 `jdt` 集成自己清理：启动时 `pluginsDidLoad` 拿到扫描结果，如果没有任何“未卸载”的已安装插件声明 `jdt` 集成，就在后台删除这两个目录（不碰同目录下其他语言服务器的缓存）。扫描本身失败（拿不到已安装列表）、或插件已安装但启动时被拒绝，都不算卸载，状态保留。这样宿主既不用写死 Java Support 的插件 ID，也不需要把缓存搬进插件状态目录。
- **卸载后的表现**：插件仍然“拥有”Java 语言，宿主不会退回任何内置路径。打开 Java 文件时提示需要安装或恢复 Java Support；语法高亮、Maven 面板和其他语言不受影响。

### 正确做法

- 语言服务器依赖特定运行时：把运行时放进插件包并声明 `packagedRuntime`。只有“用户机器上任意够新的版本都行”时才用宿主发现加 `minimumVersion`。
- 某个服务器需要宿主代码配合：做成具名宿主集成，集成要读的文件由插件在 `resources` 里声明。
- 插件只提供语言服务器、运行/测试/调试仍用宿主内置实现：在 `hostIntegration.capabilities` 里逐项声明。迁移一个语言到插件后，必须在打包出的应用里实际点一次工具栏运行、调试和测试面板；只跑集成测试发现不了能力目录里丢掉的标记。
- 插件专属的构建步骤：放在插件目录的 `assemble-package.sh` 里。

### 不要这样做

- 不要在通用的工具发现、注册表或目录里为某个插件的资源加按名字匹配的分支。迁移中途曾在 `MacRuntimeToolDiscovery` 里为 `java` 加过指向内置 JDK 的分支，已撤销：它和 `descriptor.id == "java"` 是同一类特判，只是换了位置。
- 不要让宿主在插件缺失时退回内置路径。那样卸载就不是真的卸载，行为也会随安装状态悄悄变化。
- 不要为了恢复某个语言的调试或测试，把能力目录的合并规则改成“插件没声明就保留宿主原有能力”，也不要在目录或注册表里按 `java` 放行。前者让 PHP、Go 的插件停用后宿主重新运行内置工具，后者是按名字的特判。
- 不要往插件包里写任何东西。可写状态用 `${stateDir}`、`${workspaceStateDir}`，或像 JDT 那样由集成放进宿主缓存。

## 考虑过的备选方案

### 只把文件搬进插件包，宿主继续扫描目录

改动最小。但宿主仍要知道 JDT LS 的目录结构，换一个位置扫描而已，特判一处也删不掉。

### 把 JVM 参数和 Equinox 配置也搬进 `plugin.json`

更接近“启动完全由数据描述”。但这要改 Rust 引擎的 Java 启动路径，那是 Windows 共用的代码，风险和收益不成比例。现在这些仍由 `jdt` 集成给出；用户额外声明的 JVM 参数现有逻辑会保留。

### JDK 留在 app 里，由宿主作为 `java` 运行时提供

插件包能保持纯 jar，不碰原生代码的校验。但 app 内置的 JDK 只有语言服务器在用，它本来就是 Java 插件的资源；留在宿主里就需要宿主知道它的位置，卸载 Java 也省不下空间。

### 引入进程外插件协议，让插件自带逻辑

能把 Java 的全部逻辑搬出宿主，也是 Maven 这类带业务逻辑的模块最终需要的形态。但它要先设计取消、超时、崩溃隔离和权限，而 JDT LS 的启动和资源归属用声明就能解决。两者不冲突，协议可以之后单独提案。

## 后果

收益：

- 宿主里不再有 JDT LS 和 JDK 的路径，`MacJDTLSLaunchResourceResolver` 和内置 JDK 的定位代码已删除；Java 相关的钩子按 `jdt` 集成声明生效。
- JDT LS 和 JDK 可以随插件独立升级；以后改为从市场下载时，卸载能真正释放约 400 MB。
- API 2 的运行时启动、模板和状态目录对所有语言插件可用。

代价和已知的行为变化：

- **老用户升级后会重建一次 Java 索引**。工作区缓存指纹里包含语言服务器的安装路径，路径变了。
- **不能再把 Java 语言服务器指向用户自己安装的 `jdtls`**。运行时和服务器都固定为插件包内的文件。
- **卸载目前不释放磁盘空间**，因为包在只读的 app bundle 里。
- 插件包与架构有关，体积约 400 MB，需要按架构组装。
- Rust 引擎里仍按提供方 ID `java` 启用 JDT 适配；Java 的运行、测试和调试仍是宿主内置实现，尚未成为扩展点，由插件通过 `hostIntegration.capabilities` 声明后启用。
- Windows 仍把 JDT LS 和 JDK 放在安装目录里，没有接入这份契约。

尚未完成、需要单独提案的部分：把 `jdt://` 虚拟文档等协议扩展改成清单里的声明式特性；Debug、Run/Test 扩展点；Java Support 改为从市场下载；Windows 接入。

## 验证

- `cargo test --manifest-path rust/lithe-core/Cargo.toml --lib plugins`：API 2 的合法与非法清单、启动计划标准答案、运行时版本判定，以及仓库里的官方 `plugin.json`。
- `./scripts/verify-official-plugins.sh`：组装三个官方包并校验入口、自带运行时、符号链接和原生代码的位置。
- `./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'Plugin|LanguageExtensionProcessLifecycleTests|LanguageServerToolServiceTests|JavaLanguageServerRuntimeTests|MacJdtWorkspaceStateTests|MacJdtHostIntegrationStateTests|LanguageToolEnvironmentTests'`：按声明定位资源、路径固定在包内、版本过滤、默认启用、移除与恢复；卸载后 JDT 的索引和 Equinox 配置区被删除（扫描失败或插件被拒绝时保留）；运行时启动的服务器 `PATH` 上先找到宿主选中的运行时。
- `LITHE_RUN_JAVA_DEBUG_INTEGRATION=1 ./scripts/test-macos.sh --filter RealJavaDebugIntegrationTests`：从组装好的插件包启动真实的 JDT LS 并完成 Spring Boot 断点调试。迁移初版时它因 `java.project.getClasspaths` 在服务端抛空指针而失败（迁移前的代码同样失败），该问题已随入口发现的修复一并解决，见 [Java 入口由 JDT 判定](2026-09-21-java-entrypoints-owned-by-jdt.md)。这组测试直接组装调试会话，不验证应用里的能力目录。
- `./scripts/test-macos.sh --filter '(LanguageProviderCatalogSourceTests|RunWorkflowCoordinatorTests|RunConfigurationIntegrationTests)'`：用仓库里的官方 Java 清单验证能力目录保留运行、测试、调试；未声明的插件得不到任何宿主能力；注册表只为声明的能力创建内置工具；声明了 `run` 的语言不要求执行模块。
- `./scripts/verify-macos-package.sh`：打出的应用里 Java Support 的文件齐全，且不存在 `Contents/Resources/LanguageServers`。
- `./scripts/verify-runtime-bundle-immutability.sh`：启动与插件工作流不改写安装目录。

## 适用范围

- `shared/contracts/plugins/v1/`
- `rust/lithe-core/src/plugins/declarative.rs`
- `Plugins/mac/Official/JavaSupport/`
- `scripts/build-official-plugins.sh`
- `scripts/package-app.sh`
- `macos/Sources/Lithe/Platform/MacOS/Plugins/MacPluginLanguageServerLaunchResolver.swift`
- `macos/Sources/Lithe/Platform/MacOS/Plugins/HostIntegrations/`
- `macos/Sources/Lithe/Core/Language/PluginLanguageProviderCatalogSource.swift`
- `macos/Sources/Lithe/Services/Language/LanguagePackRegistry.swift`
- `macos/Sources/Lithe/Application/Features/RunWorkflowCoordinator.swift`
- `macos/Sources/LitheModuleAPI/Plugins/PluginTypes.swift`
- `macos/Sources/LitheCoreContracts/Language/LanguageServerHostIntegrationContracts.swift`
- `macos/Sources/Lithe/Platform/MacOS/Plugins/MacPluginPackageStore.swift`
- `macos/Sources/Lithe/Platform/MacOS/MacServiceContainer.swift`
- `macos/Sources/Lithe/Services/Java/ProjectRuntimeService.swift`
- `macos/Sources/LitheLanguageIntelligenceModule/Services/LanguageServerToolService.swift`
- `macos/Tests/LitheOfficialPluginVerifier/OfficialPluginVerifier.swift`
