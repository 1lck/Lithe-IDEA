# Agent 笔记：Maven/Java 领域插件迁移与删除条件

状态：提议中

## 先说结论

Java Support 已拥有语言服务器资源，Maven 也已有插件后端，但宿主和 Rust Core 仍执行一部分 Maven/Java 专属业务。本提案按 [Issue #1495](https://github.com/1lck/Lithe-IDEA/issues/1495) 固定当前入口、调用关系、数据和删除条件：后续迁移必须让同一用户流程全部使用插件结果，再删除被替代的生产路径。只支持迁移后的最新宿主与匹配插件，保留用户数据迁移，不保留旧业务回退。

阶段 A 的交付是下述静态清单与边界决策；后续能力契约、代码删除和真实工作流验收尚未完成。本笔记留在 `proposed/`，不能据此宣称 Maven 或 Java 已完成领域后端迁移。

## 问题

### 固定基线与证据边界

核对日期为 2026-10-26（Asia/Shanghai）。主仓库使用提交前重新核对的最新 [`preview@1a7a95c8ce9d254bb6b8811af73e93d86a7badc1`][baseline]，而非 Issue 初次审计的 `e854cfd98`；下文源码链接均固定到该提交。实现前应在各自最新 `preview` 再检查增量，尤其是调试与配置相关工作。本次已复核从 `26c42fe65` 到此提交的增量：#1510 新增调试适配器声明契约，其他下列生产调用链未被这项变更替换。

Maven 插件单独使用 [`Lithe-IDEA/lithe-plugin-maven@bfa56dc80914df22ab60967ec859f8932870b494`][maven-plugin]（清单版本 `0.1.1`）核对。它证明源码具备哪些能力，不证明用户安装了该包，也不证明主仓库与该包已通过联合运行验收。

本次依据生产构造、调用、清单和 Git 删除历史；没有启动应用、执行 Maven/Java 项目或进行 Windows 实机验收。源码存在、历史 Issue 已关闭、功能矩阵已有记录，均不能代替当前工作流的运行证据。[PR #1483](https://github.com/1lck/Lithe-IDEA/pull/1483) 是独立分发相关的 Draft 工作，不在本基线内，也不是领域迁移完成的证据。

### 三类判定

| 分类 | 本基线事实 | 允许采取的动作 |
| --- | --- | --- |
| 已确认失去产品入口，并已删除 | [`f5458a243` / #1498][removed] 已删除 `CodeEditorView`、`HighlightedRangeCache`、`EditorSyntaxHighlightState`、`LanguageServerSetupView`、`AgentHistoryPopover`、`MavenModuleOperations`、`MonacoDiffEditor`、旧 `DiffPairing`、`LitheUnavailableView`、`ExternalAuthorizationCallbackRouting`。当前生产源文件中已无这些声明。 | 阶段 B 已有独立交付，不在本次重复删除；沿用该变更迁移过的有效场景。 |
| 仍被生产调用，但最终应由插件执行 | 下表 M1–M8、J1–J9 的领域部分；组合根仍创建 `MavenService`，Java 清单仍启用 `hostIntegration: jdt`。 | 先补能力与完整消费者迁移，达到对应删除条件后，在同一纵向交付中删除旧路径。 |
| 删除依据不足，或同时承载公共能力 | `RunService`、`StandardLanguageTestProvider`、LSP engine、通用 DAP/套接字、配置文件读写 adapter、共享解码器、`SyntaxHighlighter`、原生 Diff 高亮、`macos/Experiments/Monaco/`。 | 不整类、整目录删除。按实际语言/工具分支证明所有消费者替换；证明不了就保留公共部分并记录阻塞点。 |

第三类并非“确认废弃”：搜索替换预览调用 `SyntaxHighlighter`，原生 Diff 和调试展示调用 `DiffSyntaxHighlighter`；当前 `LocalHistoryDiffPairing` 是本地历史功能的实现，不能因名字相近而当成已删除的旧 `DiffPairing`。`JavaRunService` 只是 `LitheExecutionModule.RunService` 的类型别名，不能把它算成第二套独立运行引擎。

## 提案

### 一、最终所有者与最新版本策略

插件后端是独立进程中处理领域请求的部分；Provider 是向宿主提供某种能力的插件接口。两者都不意味着新增一套通用进程或 UI 框架。

| 所有者 | 应持有的内容 | 代码迁移动作 |
| --- | --- | --- |
| Maven 插件后端 | Maven 工程模型、Profiles、settings/仓库语义、目标参数、执行与报告；复用 Maven 自己的模型和解析结果。 | 接管 M1–M8 的 Maven 决策，向所有消费者提供同一生效快照。 |
| Java 插件后端 | JDT 启动和专属适配、入口、运行准备、测试/调试、Spring/MyBatis；复用成熟 Java 引擎。 | 接管 J1–J9 的 Java 决策，撤销宿主 `jdt` 专属入口及对应 Core 分支。 |
| 宿主与平台 adapter | 原生窗口、编辑器、通用 Build/Run/Test/Debug 展示；能力路由、权限、进程、终端、凭据、平台文件读写、取消及资源释放。 | 按类型化结果执行用户动作，不推导主类、Maven 参数、Java 类路径或框架事实。 |
| 通用 Rust Core | 通用契约校验、路径安全、确定性规范化、LSP（语言服务器协议）、DAP（调试适配器协议）与通用操作状态。 | 拆掉 Maven/Java 专属决策；保留仍有公共消费者的校验、传输和状态能力。 |
| Maven、JDT 及扩展 | 各自负责的项目模型、源码根、依赖、符号、编译、测试、调试事实。 | 以引擎输出为事实源；不从几条命令另建一份长期同步的工程引擎。 |

只交付最新宿主与对应插件的组合。阶段 C 确定协议和能力版本后，不匹配的组合明确拒绝并提示更新；不增加老版本宿主业务 shim（兼容转接层）、双写、旧模型兜底或静默降级。

一次性配置/数据迁移与旧业务兼容不同：迁移须能重试、校验并保留失败源数据，成功后删除旧读取入口。通用包管理的原子安装失败恢复仍有必要，但不能借“恢复”重新启用不匹配插件或旧宿主 Maven/JDT 实现。

### 二、当前能力与真实缺口

| 可复用的现有机制 | 本基线能力 | 迁移尚缺什么 |
| --- | --- | --- |
| [通用构建服务][build-service]与[工作区 Provider 会话][build-sessions] | 工程识别、模型/依赖请求、声明式 CLI（命令行）任务、诊断/报告展示、选项、取消和失效；按插件、构建系统、工作区管理进程。 | 原生领域调用及执行/运行/测试等能力如何复用该会话，需要阶段 C 定义。不能重建另一套进程管理器。 |
| [Build Provider v1][build-protocol] | `lithe/build/model`、`lithe/build/dependencies` 两个方法。已有模型和依赖后端，不等于执行已在后端。 | Maven 普通任务当前由宿主执行插件声明的 CLI 计划；需要补齐后端执行、进度、结果与报告能力，才能迁走执行决策。 |
| [`backend: 1`][page-backend]及[macOS 会话][page-sessions] | 每插件一个进程，供插件自己的网页函数/设置动作调用；要求网页窗口，不绑定工作区，拒绝 `workspaceStateDir`。 | 无页面时可用、工作区隔离的原生领域入口。不能用空网页绕过限制，也不能把任意私有函数开放为宿主业务 API。 |
| 现有函数协商与 `BuildSystemService.invokePluginFunction` | 已有协商、调用和构建 Provider 目标定位；不能把它描述为“完全没有函数调用”。 | 调用存在不等于已有公开、类型化的 Run/Test/Debug/Maven 业务契约；权限、版本、参数与生命周期仍须定义。 |
| 通用 Debug 服务及 [#1210 提案][debug-note] | 已有 #1508 基础调试重构、#1509 macOS 多会话；#1510 已将 API 4/`debugAdapters` 声明及校验纳入[正式契约][debug-contract]。 | DebugAdapter Registry（适配器注册表）与宿主运行时接入仍待完成；新 Core 启动计划和包资源检查尚无生产调用方。复用已发布声明，不能把声明校验通过写成插件调试已可用。 |
| 插件契约与两个后端 SDK（开发工具包） | 主仓库拥有契约和 Core，`lithe-plugin-docs` 拥有契约副本与 Node/Java SDK。 | 新契约随 Core/fixtures 评审，合并后同步副本；协议实现合并前用两个 SDK 的真实后端跑端到端验证。 |

新能力必须明确插件 ID/版本、工作区身份与重开代次、配置/工程快照身份、`operationID`、进度、取消、超时和晚到结果。停用、更新、崩溃、切换/关闭工作区及退出，必须撤销能力并结束对应进程/订阅。以上是职责要求，不是已经发布的新字段或方法名；正式协议只在 `shared/contracts/plugins/v1/` 随实现定义。

### 三、Maven 当前入口、调用链与替换能力

以下 M/J 编号用于把调用链与下一节的数据、删除及验收逐项对应。“目标能力”是职责名称，不是新 API。清单以 macOS 当前用户入口为准；Windows 现有共享消费者另列。

| 编号 / 用户入口 | 当前调用链与所有者 | 目标插件能力 / 公共部分 |
| --- | --- | --- |
| M1：Build 工具窗口，识别、模块/Profiles、依赖加载及 Reload | `BuildSystemToolWindowView` → `BuildSystemsFeatureModel` → [`BuildSystemService`][build-service] → Core `build.*` → [Maven Provider][maven-backend]。后端用 Maven 扩展一次取得模型与依赖，宿主持有通用展示。 | Maven 后端拥有工程/依赖快照及强制刷新；宿主保留通用树和加载状态。复用现有扩展，不再独立解析一份完整 POM 模型。 |
| M2：构建生命周期、自定义目标、Skip Tests、输出/诊断/测试报告 | 通用窗口 → `BuildSystemService` → 插件声明的任务 CLI → 宿主进程 → 通用解码。另有 [`MavenService.run/runCustomGoal`][maven-service] → `maven.launchPlan` → 专用进程的旧路径。 | Maven 后端负责参数/任务选择、执行与 Maven 报告；宿主复用进程权限、输出与通用报告展示。不能只把新窗口接通后留下旧执行入口。 |
| M3：Agent Maven 查看/执行与环境配置 | [`IdeCapabilitiesFeatureModel.execute`][agent] 激活 execution 模块后直接访问 `MavenFeatureModel`；Maven 选项与 `environment.configure` 又写 runtime/旧 Maven 配置。 | Agent 通过宿主的类型化路由调用与 UI 相同的 Maven 能力及配置源，保留授权、操作 ID、输出游标和通用错误。 |
| M4：打开/重开工程、运行入口生成 | [`ProjectDevelopmentFeatureModel.loadProject`][execution-models] 判断 `pom.xml` → `MavenFeatureModel/MavenService.loadProject` → `maven.scan`；将旧 `MavenProject` 传给 `RunFeatureModel/RunService`。组合根仍构造旧服务。 | Maven 后端提供工程/模块信息；Java 后端提供 Java 入口；通用 Run 消费结果。移除宿主 POM 特判与旧模型注入。 |
| M5：项目 JDK/Maven 设置、Profiles/settings/仓库修改 | [`AppModel+FeatureState`][runtime-settings] 从 Run toolchain 与旧 Maven 字段准备表单，保存时更新旧服务与 Run 项目配置；Build 选项另经 `MacBuildOptionsStore` 持久化。 | Maven 后端解释 Maven 配置来源和优先级，Java 后端解释项目 JDK；平台执行受保护读写，UI 显示实际值、来源和显式覆盖。与 #818/#1493 共用一次迁移。 |
| M6：Java 导入、Profiles 热更新、Reload | [`AppModel+BuildSystems`][build-import] 等待插件导入输入，有值时使用插件 `mavenContext`，否则读取旧 `mavenFeatureIfActive.launchContext`；准备协调器 → `LanguageToolingSessionManager` → JDT。 | Maven 发布生效配置/工程快照；Java 消费并更新 JDT。按工作区代次与配置身份失效，删除旧上下文 fallback。Gradle 导入也须继续可用。 |
| M7：Dependencies 侧栏、依赖源码/类文件导航、框架元数据 | [`DependencySidebarView`][dependencies] → Run feature 的通用依赖服务；Java 依赖来自语言会话。组合根为 Run 配置依赖提供者，插件依赖结果缺失时仍读旧 Maven artifact paths。 | Maven 提供解析后的依赖，Java 提供语义/虚拟源码导航；宿主保留树、编辑器、下载权限与通用展示。禁止拿旧 Maven 依赖填补插件失败。 |
| M8：Maven 模块/框架运行、测试准备及停止 | [`RunService`][run-service] 持有旧 Maven 工程/context，生成服务与计划；[`StandardLanguageTestProvider`][test-provider] 的 Java/Maven 分支选择 Maven 参数，旧 Maven 路径负责报告；Java Main 和有入口源码的 Spring Boot 已走 JDT 准备。 | Maven 后端拥有构建/测试目标与 Maven 报告，Java 后端拥有 Java 目标和运行前准备。通用 Run/Test 仍管理会话、停止、输出和结果树。不能把所有 Java 运行重新退回 Maven reactor 执行。 |

### 四、Java 当前入口、调用链与替换能力

| 编号 / 用户入口 | 当前调用链与所有者 | 目标插件能力 / 公共部分 |
| --- | --- | --- |
| J1：安装/启停 Java Support、语言服务启动与索引维护 | [Java 清单][java-manifest]声明资源及 `hostIntegration: jdt` → [`MacJdtHostIntegration`][jdt-host] → `MacJdtLaunchResources/MacJdtWorkspaceState` → Core `jdt*`；Java 准备协调器与会话管理器仍在宿主。 | Java 后端拥有资源解释、JDT 启动/专属状态和维护。宿主管理包信任、平台存储、通用语言会话/启停。独立下载只改变分发，不自动完成这项。 |
| J2：Java 编辑、补全/诊断/重构、语义导航与 `jdt://` 依赖文档 | Monaco/`JavaFeatureModel`/`AppModel+JavaNavigation` → [`LanguageToolingSessionManager`][language-sessions] → Core LSP engine 的 JDT/Java 分支及上游命令；另有 `java.codeVision/structure/sourceDefinition` 等领域投影。 | Java 后端适配 JDT 语义、虚拟文档与 Java 专属投影。通用文档同步、LSP 传输和编辑器展示保留；不迁移通用 Monaco 组件。 |
| J3：工程激活、Maven/Gradle 导入、Java 就绪与重建索引 | `JavaLanguageServerPreparationCoordinator`、`AppModel+BuildSystems` → 会话管理器 → Core `java.workspacePolicy`、JDT workspace/configuration/progress/build；Maven 上下文见 M6。 | Java 后端维护 Java 工程事实与就绪状态，消费构建插件快照；宿主只展示通用准备状态及执行取消。保留首次导入、外部改动与同路径重开的失效保护。 |
| J4：工具栏/代码边栏 Run、主类选择与运行配置编辑 | [`AppModel+JavaEntrypoints`][java-entries] → 会话 `javaEntrypoints/javaMainMethods` → JDT；Run 生成/编辑 → `MacRunConfigurationStore` → Core `runConfig.*` 与 `java.runMarkers`。 | Java 后端发现入口、解释 Java 配置及运行目标；通用配置 ID、合并、编辑器和受保护文件写入按实际公共消费者保留。不能按命令前缀整体删除 `runConfig.*`。 |
| J5：运行前保存、编译、类路径/JDK 解析、长类路径与服务更新 | `RunService` → 会话 `prepareJavaRunLaunchTarget/buildJavaServiceUpdate` → Java Debug Server/JDT 构建与 classpath；平台启动 JVM。失败构建的继续/取消、Spring Boot DevTools 更新和 Hot Code Replace 属于现有能力。 | Java 后端负责完整“保存 → 同步/构建 → 解析 → 启动准备/更新”顺序；宿主执行通用保存、权限、进程与 UI。运行和调试使用同一项目 JDK，显式无效选择不得切到语言服务器 JVM。 |
| J6：测试窗口/边栏，发现、单方法/类/模块执行与结果 | `StandardLanguageTestProvider`、Test workflow → 会话 `discoverJavaTestItems`/`javaTestItems` → Java Test 扩展；Java/Maven 测试选择和启动参数还在宿主/Core。 | Java 后端适配 JUnit/TestNG 发现与选择；Maven 负责其执行/报告部分。保留通用测试树、运行状态和定位；不能用源码文件名或正则重建测试语义。 |
| J7：工具栏/测试 Debug、多会话、断点、停止/重启 | `DebugLaunchConfigurationResolver` 的 Java/Maven 分支、`JavaTestDebugLaunchService` → 会话解析目标/`startJavaDebugServer`；`MacJavaDebugAdapterTransport` 查 JDT 调试端口，Core `debug/java_test.rs` 生成测试调试配置。 | Java 后端贡献调试适配器及目标、Java Test 启动/结果适配；复用 #1210 注册表。宿主保留通用 DAP、套接字、断点/线程/变量、会话标签和生命周期。 |
| J8：Spring 配置补全/诊断、Bean/注入导航、Endpoints；MyBatis Java/XML 跳转 | [`SpringFeatureModel`][spring]、[`MybatisFeatureModel`][mybatis] → `RustJavaMavenOperations` → Core `spring.index/mybatis.index`；FeatureModel 中仍有专属补全、文件识别和导航逻辑。 | Java 生态后端持有框架语义及索引；不要求本阶段另拆两个插件。正式选型先核对许可和上游扩展完整能力，不能假定当前 JDT 已提供全部 Spring/MyBatis 功能。 |
| J9：新建 Java 工程及项目运行时选择 | Java Support 清单已有项目生成器图标/模板；宿主通用生成器展示并创建项目。`ProjectRuntimeService` 负责平台工具发现，Java JDK/Maven 选择与配置存在领域语义。 | Java/Maven 专属生成字段、校验和工具要求由插件声明/后端拥有；通用模板写入、目录选择及工具发现 adapter 保留。保护项目 JDK 与语言服务器 JDK 的不同用途。 |

### 五、数据/资源、删除条件与逐项验收

可写位置均由平台存储 adapter 解析。下表列的是迁移对象与生命周期，不表示本次新建目录；没有新增下载、生成资源或可复用缓存。

| 数据/资源编号 | 当前来源与生命周期 | 迁移规则 |
| --- | --- | --- |
| R1：Maven 用户选项 | `.lithe/maven/config.json` 的便携配置；[`MacMavenConfigurationStore`][maven-store] 在 Application Support 的 `Lithe/Maven/<digest>.json` 存本机路径，身份含工作区与 reactor；`MacBuildOptionsStore` 另用 `BuildSystems.Options.*` 及显式空多选标记保存 Build 选项。 | #818/#1493 共同确定逐字段来源/优先级与冲突策略，迁走读取者后删除旧存储代码。保留自定义 Profiles、Skip Tests、显式空值、本机路径和用户选择；不能直接删文件或把所有源静默合并。 |
| R2：运行配置与工程工具链 | `.lithe/run/configurations.json`、`local.json`、`generated.json`；[`MacRunConfigurationStore`][run-store] 负责文件/迁移 adapter。项目 JDK/Maven defaults 在 `local.json`，另有旧偏好迁移。 | 稳定配置 ID、用户参数/环境/工具链和本机/共享范围保留；仅可重建的生成结果可失效。区分通用文件格式与 Java/Maven 字段，完整读回成功后才移除旧读取。 |
| R3：工具的真实配置与仓库 | 项目 `pom.xml`、`.mvn/`、Wrapper、用户/全局 `settings.xml`、Maven 本地仓库；上游工具拥有实际配置和依赖。 | 默认发现和显示生效值/来源，编辑草稿后由用户确认；受保护写回明确来源并读回，冲突/只读/解析失败保留源和草稿；敏感值不回显。插件状态不得复制成第二份生效 settings。 |
| R4：构建/依赖/测试产物 | Provider 的 `workspaceStateDir` 与 `maven-snapshot.json`；通用输出 staging；旧 `MacMavenDependencyOutputStore` 在临时目录 `Lithe/maven-dependency-trees/<pid>/` 写操作输出；工程的构建目录与测试报告。 | 每工作区/插件/操作隔离，配置或模型失效时拒绝旧结果；临时物由操作清理，缓存可重建；用户项目产物由工具规则管理，迁移不能清空用户仓库或所有构建目录。 |
| R5：Java 插件固定资源 | JavaSupport 包内 JDT/JDK/Lombok/Debug/Test、生成器模板/图标；来源及校验在 `third_party/jdtls/manifest.json`、`third_party/jdk/manifest.json`。 | 构建阶段固定来源、平台/架构/许可并签名；已安装 app/插件版本只读。迁移打包入口时同步资源清单与工作树复用校验；不复制可编辑源码或运行时改包。 |
| R6：JDT 专属可写状态 | 平台缓存的 `jdtls/` 工作区索引、`jdtls-configuration/` Equinox 可写配置，以及 profile/settings 副本、日志、锁和使用标记。 | Java 后端管理内容，宿主提供位置与权限；状态按版本/工作区隔离、可重建，不跨工作树共享。退出/停用先结束进程，再删除可丢弃状态，不能把索引迁到插件安装目录。 |
| R7：操作/调试/框架状态 | 宿主内存中的会话、取消任务、Java 调试端口和测试结果 listener（监听器）、框架索引、导航标记与未保存文档投影。 | 同一操作/工作区代次拥有资源；后端崩溃、取消、停用、切换工作区、退出时有界释放；晚到结果不能发布。框架投影跟随文档版本，不产生宿主/插件双索引事实源。 |

删除须同时满足：新能力具备生产入口；该行全部消费者已切换；数据迁移完成且失败不丢源；当前 Windows 消费者已处理；对应用户流程有运行证据。搜索零引用是最后一道检查，不是全部证明。

| 关联清单 | 数据 | 满足上述条件后删除的领域路径 | 必须留下的验收证据 |
| --- | --- | --- | --- |
| M1 | R1/R3/R4 | Core `build/integrations/maven.rs` 中被插件模型替代的 Maven 解释；旧 `project/maven.rs` 扫描部分；保留通用模型校验。 | 单/多模块、多个 reactor、父 POM/Profiles、自定义 Profiles、Reload/离线/取消；模型和依赖来自同次生效配置。 |
| M2 | R1/R3/R4 | `MavenService` 的目标/参数/执行/报告路径及 Core Maven launch/diagnostic/report 专属实现；通用 Build 服务和通用报告解码不可整删。 | lifecycle、自定义目标、模块目标、Skip Tests、失败诊断/定位、测试报告、停止及迟到输出；UI/Agent 结果一致。 |
| M3 | R1/R2/R4 | Agent 的 `MavenFeatureModel` 访问与直接配置写入分支。 | Agent 查看、修改配置、执行、取输出和取消；权限拒绝与未就绪正确，生效值与 UI 一致。 |
| M4 | R1/R2/R4 | `ProjectDevelopmentFeatureModel` 的 POM 特判与旧 Maven load，Run 的旧 MavenProject 注入、Core Maven 检测分支。 | 打开、同路径重开、混合工程、多个构建根；旧加载器不再构造，非 Maven 运行入口保持。 |
| M5 | R1/R2/R3 | 旧 `MacMavenConfigurationStore`、`MavenConfigurationWriter`、runtime 表单的旧镜像写入与冲突 fallback；通用文件/偏好 adapter 保留。 | 来源发现 → 回显 → 编辑确认/取消 → 冲突保护 → 保存读回 → 重开；显式空值、坏配置、秘密与迁移重试覆盖。 |
| M6 | R1/R3/R6 | `javaLanguageImportConfiguration` 的旧 Maven fallback、会话中的旧 Maven provider 路径、Core `jdt_maven_settings` 等被替代业务。 | 改 Profiles/settings/仓库 → 同一快照到 JDT → 符号可见；移除 Maven 插件清除旧输入；纯 Java/Gradle 不受损。 |
| M7 | R3/R4/R6 | 组合根旧 artifact-path fallback、`MavenService` 依赖解析/临时输出专属存储与被替代 Core dependency-tree 分支。 | 依赖树刷新、源码/JAR/虚拟文档跳转、取消/失败、无源码依赖；切换工作区无串用，插件失败不会读取旧依赖。 |
| M8 | R1/R2/R4/R7 | `RunService` 的 Maven 业务分支、`StandardLanguageTestProvider` 的 Maven 参数/选择、旧 Maven 测试报告入口。 | 模块/框架 Run/Test、重启/停止、单方法选择、JUnit/TestNG 结果；配置覆盖与工程默认值一致，其他语言测试保持。 |
| J1 | R5/R6/R7 | `HostIntegrations/Jdt/` 专属实现、清单 `hostIntegration: jdt` 及 Core JDT 启动/状态特例。 | 无页面启动、重建索引、插件安装/停用/更新/卸载；不重复会话，状态可写且包哈希不变。 |
| J2 | R5/R6/R7 | `JavaFeatureModel`/AppModel 中专属语义、Core `java*`/`jdt*` 对应投影与 engine 专属分支。 | 补全、诊断、定义/实现/引用、重构、Code Vision、结构与依赖虚拟文档；未保存文档和取消/晚到结果正确。 |
| J3 | R1/R3/R6/R7 | Java 准备协调器、会话管理器中 Java 专属协作和 Core workspace/profile/build 策略。 | 普通 Java、Maven、Gradle；导入/保存/热更新、超时/重试、取消、同路径重开；就绪显示对应当前快照。 |
| J4 | R2/R7 | AppModel Java 入口协调、Java 配置生成/解析和 run marker 分支；`runConfig.*` 逐命令拆，保留公共 CRUD/合并/校验。 | 工具栏与边栏相同主类、生成/编辑/重开不丢 ID/参数、过期入口失效、无入口/多入口与非 Java 配置保持。 |
| J5 | R2/R5/R6/R7 | 宿主 Java launch lease/准备/服务更新和 Core Java launch/classpath/server-port 领域部分。 | 保存后构建并运行最新代码；构建失败继续/取消、长 classpath、显式坏 JDK、Spring DevTools/HCR；一次尝试不重复构建。 |
| J6 | R2/R4/R5/R7 | 会话中的 Java Test 适配、语言测试提供者的 Java 分支、Core Java 测试语义；通用 Test 生命周期保留。 | JUnit/TestNG 发现、单方法/类/模块执行、结果定位、取消与工作区替换；无误用源码命名规则。 |
| J7 | R2/R5/R6/R7 | `DebugLaunchConfigurationResolver` Java/Maven 部分、`JavaTestDebugLaunchService` 专属配置、JDT 端口发现及 `debug/java_test.rs`。 | Main/测试/Attach 调试，断点/步进/变量、多会话/子会话、停止/重启；JDK 与 Run 一致，端口/listener/进程全部释放。 |
| J8 | R3/R4/R7 | `SpringFeatureModel/MybatisFeatureModel` 领域索引/补全/导航，`spring.index/mybatis.index` 实现与桥接。 | 配置补全/诊断、Bean/注入/Endpoints 搜索、Java/XML 双向跳转；未保存编辑、元数据变化、工作区切换正确。 |
| J9 | R2/R3/R5 | 宿主/Core 中仅为 Java/Maven 服务的生成字段/运行时选择特判；通用生成器与工具探测保留。 | 已有模板创建后可导入/运行；显式/默认/无效项目 JDK、插件 JDK 更新/卸载；普通语言生成器不回归。 |

`MavenService`、`MavenFeatureModel` 及 `RustJavaMavenOperations` 的 Maven 部分，须在 M1–M8 全部替换后整体移除，不能把只剩 Agent 或设置调用的服务标成“完成”。Java/Core 文件按 J1–J9 实际职责分批删，不能把 `lsp/languages/`、`RunService` 或通用调试框架整目录迁走。

### 六、共享 Core 命令与当前 Windows 消费者

这里核对的是当前消费者，非旧版本兼容承诺。共享命令删除/改义时，同一变更切换这些消费者及 adapter；Windows 独有且 macOS 从未采用的历史功能不在清理范围。表中未检出直接调用的命令也不能立即删，仍需核对统一 dispatcher、操作枚举、fixtures 和桥接。

| 命令/操作族 | 当前 macOS 位置 | 当前 Windows 生产消费者 | 处理条件 |
| --- | --- | --- | --- |
| `maven.scan/launchPlan/dependencyPlan/dependencies/diagnostics/testResults` | `RustJavaMavenOperations`、旧 Maven/Run/Test 路径 | [`features/maven/api/maven-core-api.ts`][win-maven]，Maven store、运行与测试流程 | 随 M1/M2/M4/M7/M8 切到 Maven 插件；同步去掉旧命令/专属 fixture 与契约说明。 |
| `runConfig.inspect/updateOptions/generate/resolve/createLaunchPlan/saveEditorChanges`；macOS 另有 `selectJava/createUser` | `MacRunConfigurationStore`、Run 配置与 Debug 解析 | [`features/run/api/run-core-api.ts`][win-run]及 Run store | 拆 Java/Maven 语义，公共文档与其他语言功能按消费者保留；“Windows 没直接调用某方法”不能作为删除依据。 |
| `java.runMarkers/sourceDefinition` | Java markers 与源导航桥接 | `features/run/services/java-run-markers.ts`、`features/editor/lsp/lombok-accessor-navigation.ts` | 随 J2/J4 切到 Java 后端；保留通用 gutter/导航。 |
| `java.workspacePolicy/jdtWorkspaceFingerprint/jdtCacheRetention` | Java 激活与 `MacJdtWorkspaceState` | `platform/java-workspace-policy.ts`、`src-tauri/src/lsp/jdt_workspace.rs`；Java 启动还有 `lsp_resolve_java_launch` 平台命令 | Java 后端接管策略/指纹内容，平台 adapter 保留文件与进程；处理两端的旧 JDT 资源路径。 |
| `javaEntrypoints/javaMainMethods/javaTestItems` LSP 操作；`java.navigationMarkers/resolveNavigation` | `LanguageToolingSessionManager`、LSP engine | [`platform/lsp-core-adapter.ts`][win-lsp]；Run、run-actions 和 Maven Java test discovery | 随 J2/J4/J6 切换语义调用；通用 `lsp.request` 和进程会话不整删。 |
| Java 构建、classpath、调试目标操作 | 会话的 Java 准备、Debug resolver、Java Test 调试 | `platform/lsp-core-adapter.ts` 使用 `vscode.java.buildWorkspace/resolveClasspath/startDebugSession`，Run/debugger 使用其结果 | J5/J7 同步调整两端；不要因为上游方法名不以 `java.` 开头而漏掉领域调用。 |
| `spring.index/mybatis.index` | Spring/MyBatis FeatureModel 与 Rust bridge | `features/spring/api/spring-index-api.ts`、`features/mybatis/api/mybatis-index-api.ts` | J8 切换当前消费者后删除 Core 实现；两端框架能力分别验收。 |
| `java.codeVision/className/serverPort/structure` 等剩余 Java 命令 | `RustCoreBridge` / `RustJavaMavenOperations` | 本次 Windows 静态检索未找到以上四个命令的直接字面量调用 | 列入 J2/J5 删除审计，检查间接路由/测试引用；不据此声称无消费者。 |
| `debug.javaTestLaunch`；`debug.steppingFilters` 中的 Java 默认值 | `RustDebugProtocolCore`、Debug resolver | 本次未检出这两个命令的 Windows 直接字面量调用；Windows debugger 仍有平台会话/调试端口 API | 随 J7 迁移 Java 专属默认值/启动配置；保留通用调试协议、端口与会话管理，删除前复核间接调用。 |
| 通用 `build.*` / `lsp.*` / `debug.*` | 两类服务与通用调试 | 依据各端当前接入情况；本基线 Windows 构建窗口并未等同于 macOS Provider 接入 | 保留通用能力，移除其中 Maven/Java 专属策略；任何新第二平台行为先补 shared fixture。 |

`shared/contracts/application-boundary.md`、`rust-core-api.md` 中的当前 Java/Maven Core 归属描述仍反映旧实现；随对应命令/路径真正迁移而更新，不能在阶段 A 把现存契约直接改成未来事实。

### 七、上游复用与未决选型

| 已固定输入 | 当前可复用能力 | 后续必须核对的边界 |
| --- | --- | --- |
| [JDT LS `1.61.0`、Lombok `1.18.46`][jdt-lock] | Java 工程导入、语义、补全/导航及已有配置入口。 | 在 Java 插件后端复用完整 JDT 工程状态，保留 Maven/Gradle 协同；不由宿主或另一个 Core parser 重建 classpath/源码根。 |
| 同一清单的 Java Debug 扩展 `0.59.0` / server `0.53.2` | 入口、构建、运行 classpath、调试会话与服务更新所用命令。 | 迁移完整准备顺序与失败语义，复用现有通用 DAP；启动语言服务器的 Java 与项目 Java 区分。 |
| Java Test 扩展 `0.46.0` / plugin `0.43.1` | JUnit/TestNG 语义发现与测试运行所需资源。 | 核实测试启动/结果协议、选择和资源清理；不能只迁“发现”而留下宿主测试选择器。 |
| [固定 Maven 插件后端与 extension][maven-plugin] | Maven 自身的模型/依赖；后端按工作区和根管理快照/指纹、刷新与 Maven 子进程。 | 继续扩展当前后端与 Maven 扩展，补执行/配置能力；不另建 POM 继承、模块/依赖解析引擎。 |
| [JDK 锁定清单][jdk-lock] | macOS 两架构的 `21.0.12.1+1`，JDT 最低 Java 21。Windows arm64 清单实际为 `21.0.12+8`。 | 每平台按具体条目核对架构与哈希，不把顶层版本当成所有平台均相同；阶段 A 不升级工具链。 |
| Spring/MyBatis 现存能力 | 本基线由 Lithe 的领域索引实现，J8 有明确产品消费者。 | 在 J8 实现前单独核对可分发的成熟上游/公开扩展及许可；若仍需保留自有实现，放入对应后端并记录缺口证据，不能虚构当前 JDT 已覆盖。 |

正确做法：用户改 Profiles 后，Maven 后端发布一个配置/工程快照，Java 后端通过宿主路由消费它；运行和 Agent 使用同一身份，旧结果被拒绝。

不要这样做：Build 窗口用新 Provider，Agent 继续读 `MavenService`；Java 插件直接打开 Maven 插件的 `maven-snapshot.json`；插件失败时宿主重新扫描 POM。这样分别留下两套生产路径、跨插件私有缓存依赖和旧业务回退。

### 八、可独立验收的后续交付与删除配对

顺序表示依赖，不是未经评审的协议设计。阶段 C 的基础设施本身没有替代业务时，可先交付契约/会话验证；不得因此提前宣称 D/E 完成。此后每个纵向 PR 必须包含其替换的旧路径删除，而非先长期增加第二套实现。

| 交付单元 | 对应 Issue 阶段 / 依赖 | 新路径与同项删除 | 退出证据 |
| --- | --- | --- | --- |
| A：清单与边界 | 本笔记及旧 Note 修订 | 无功能替换，不删仍在用的生产代码；B 已由 #1498 交付。 | 固定基线、M/J/R 清单、Windows 消费者、上游/配置/删除条件与静态校验完整。 |
| C1：工作区领域会话与调用 | C；复用 Provider/函数会话；与 #1210 协调 | 原生无页面调用、工作区身份、取消/失效/退出；避免新增重复运行时。协议进入主仓库，SDK 同步验证。 | 无页面、并行工作区、崩溃/超时/停用/退出有界完成；尚不删除业务。 |
| C2：最小领域能力 | C；在 C1 与 #1210 公共注册能力上补缺口 | 复用 API 4 调试声明并补实际注册/启动；评审类型化执行、运行准备、测试及跨插件快照的剩余缺口，不用任意私有函数替代公共契约。 | shared fixtures 与 Node/Java SDK 端到端通过，版本不匹配明确拒绝；具体能力随下一批纵向消费者一起启用。 |
| D1：Maven 模型/配置/导入/依赖 | D；C；复用 #818/#1493 | M1/M4/M5/M6/M7 一组消费者统一快照，完成 R1/R2 配置迁移；删除该组旧模型/配置/导入 fallback/依赖路径。若旧服务仍因 M2/M3/M8 存活，列明剩余方法，不另增旧 API。 | 打开 → 实际配置 → 修改/重开 → 导入 → 依赖导航完整运行，失败源数据保留；Windows 对应消费者同步切换。 |
| D2：Maven 执行与全部入口收口 | D；D1/C2 | M2/M3/M8 的 Maven 部分，连同 Run/Test 消费者切换；删除 `MavenService/MavenFeatureModel` 及剩余 Maven Core 业务、旧存储入口。 | UI/Agent 构建与运行/测试都使用同快照，取消/报告正确；没有旧 Maven 构造和读取。 |
| E1：JDT 生命周期与项目协同 | E；C/D1 | J1/J2/J3，插件后端接管 JDT 启动、语义、导入/维护；同项删 `HostIntegrations/Jdt` 及对应 engine/会话分支。 | 普通 Java/Maven/Gradle 编辑与同步完整，资源哈希不变；Java 未安装/停用明确撤销能力。 |
| E2：Java Run/Test/Debug 与框架 | E；E1/C2/#1210 | 按 J4/J5、J6/J7、J8/J9 分纵向 PR，各自切完 UI/Agent/配置/Windows 消费者并删对应领域分支。 | 每行工作流验收，加多会话、坏 JDK、构建失败和服务更新；宿主只剩通用流程。 |
| F：迁移收尾 | F；D/E 实际完成 | 删除孤立命令/fixture/旧测试/打包脚本，复核数据库连接/历史/凭据迁移后再删过渡代码；公共图标契约保留。 | 最新组合的全清单验收、数据迁移与包只读证据； owning Notes/契约/矩阵/资源复用说明与实现相符。 |

D1/D2 或 E1/E2 若出现无法独立完成的消费者依赖，应缩成更小的完整用户流程，或合并紧耦合交付；不能在两批之间制造依赖已删除服务、无法编译或配置丢失的中间状态。没有可审阅的真实运行证据时，相应能力保持 `verificationStatus: pending`。

本阶段不调整功能矩阵的实现/验证状态，不迁移数据库数据，不增加插件资源目录。后续新增下载/生成/缓存入口时，须同项更新 `scripts/resources/worktree-resources.json`、复用脚本校验路由及测试和 `docs/ci-builds.md`；运行时状态继续隔离，不能因插件化加入跨工作树共享可变缓存。

## 考虑过的备选方案

- **只移资源或只换 Build 窗口。** 能降低发行体积或改善 UI，但 M3–M8、J1–J8 的现有生产调用仍在，无法达到 #1495 的职责迁移目标。
- **长期保留旧服务并双写、失败回退。** 迁移看似容易，但配置/工程事实继续有两份，失败被掩盖；本提案采用最新组合，保留数据迁移和明确失败，删除旧业务。
- **让 Java 直接读取 Maven 私有缓存。** 可以省一个调用，但缓存版本、工作区和失效策略变成隐式契约；采用宿主路由的类型化快照。
- **重写完整 Maven/Java 工程引擎。** 容易控制接口，却需重复解决上游已处理的工程正确性；采用现有 Maven 扩展/JDT 及公开能力，先核实缺口再自建必要适配。
- **复用 `backend: 1` 并伪造空页面，或新增另一套插件运行时。** 前者继承全应用、非工作区范围，后者重复进程/权限/清理状态；优先在既有 Provider/会话机制上补通用领域入口。
- **一次移动整个 Rust/Run/Debug 目录。** 删除量大却会带走公共消费者；按 M/J 行完成端到端替换，再删除领域分支。

## 验收标准

阶段 A 完成只代表：有固定最新实施基线、三类判定、M1–M8/J1–J9 的当前入口与所有者、R1–R7 数据/资源、待删实现/验收、当前 Windows 消费者、上游复用及按删除条件拆分的交付；旧 Note 对长期 JDT 宿主特例/旧业务回退的表述已限定为历史或中间状态。它不满足 #1495 的整体关闭条件。

D/E/F 完成须逐行附上真实新路径、删除证据、工具/插件/平台版本与运行结果；覆盖 UI、Agent、设置、Run/Test/Debug、语言服务，配置迁移成功且失败源数据保留。任何一行仍调用旧领域服务、私有缓存或 fallback，都不能判定整个迁移完成。

## 风险

- 新协议/注册表与 #1210、配置 #818/#1493 并行变化；实施前必须重新核对基线，复用已合并成果。
- Maven 配置已有多处来源，直接“搬文件”可能改变优先级或丢失显式空值；迁移映射和冲突保护是删除条件。
- JDT 的工程状态、构建及 Java Test/Debug 有连续正确性要求；单个方法 mock 成功不能证明新流程等价。
- 框架完整上游替代尚未选定；不得为了迁移速度删除用户已有功能，或引入不允许分发的实现。
- Windows 的静态消费者清单不能代替实机验收；共享命令改动必须跟消费者一起交付，并分别报告两端结果。
- 迁移资源路径可能触发索引重建；包必须只读，不能用清理/改写发行目录规避升级基线问题。

## 验证

本阶段只做文档与静态源码/Git 核对。交付前运行以下现有检查；执行结果随交付记录，不把静态通过写成运行时通过：

```bash
./scripts/agent-notes/verify-agent-notes.sh
./scripts/macos/verify/verify-runtime-bundle-immutability.sh
git diff --check
```

后续实现按受影响边界运行共享契约、服务边界、Rust Core、macOS/Windows 与测试稳定性检查；修改插件协议时合并前执行 `lithe-plugin-docs` 的 Node/Java SDK 端到端验证，合并后按[契约发布规则][contract-note]同步逐字节副本。平台改动提交前通过实际 PR 基线的矩阵变更门禁。

真实工作流验收必须比较 app/Windows 安装资源与已安装插件版本的文件清单或哈希，证明典型启动/构建/运行/测试/调试后不变。只读静态脚本通过不代替此证据。本次没有启动应用；以后每次验证结束关闭本次启动的所有 Lithe/子进程、listener、订阅和临时资源，确认无残留后交付。

## 适用范围

- `macos/Sources/Lithe/Application/`、`macos/Sources/Lithe/Models/AppModel/`、`macos/Sources/Lithe/Services/`
- `macos/Sources/Lithe/Platform/MacOS/`、`macos/Sources/LitheExecutionModule/`、`macos/Sources/LitheLanguageIntelligenceModule/`
- `rust/lithe-core/src/build/`、`rust/lithe-core/src/project/`、`rust/lithe-core/src/execution/`、`rust/lithe-core/src/lsp/`、`rust/lithe-core/src/debug/`
- `Plugins/mac/Official/JavaSupport/`、`third_party/jdtls/manifest.json`、`third_party/jdk/manifest.json`
- `shared/contracts/`、`shared/fixtures/`、`shared/platform-feature-matrix/features/`
- `windows/tauri/src/features/`、`windows/tauri/src/platform/`、`windows/tauri/src-tauri/src/`
- 外部 Maven 后端：[`Lithe-IDEA/lithe-plugin-maven`][maven-plugin]
- 关联决策：[Java 声明式资源插件][java-note]、[通用 LSP Runtime][lsp-note]、[Build System 当前契约][build-note]、[Java 独立分发提案][distribution-note]、[真实配置读写][settings-note]、[#1210 调试提案][debug-note]

[baseline]: https://github.com/1lck/Lithe-IDEA/commit/1a7a95c8ce9d254bb6b8811af73e93d86a7badc1
[removed]: https://github.com/1lck/Lithe-IDEA/commit/f5458a2431343ec63fc07ea0c51765f6b1a5fdbd
[maven-plugin]: https://github.com/Lithe-IDEA/lithe-plugin-maven/tree/bfa56dc80914df22ab60967ec859f8932870b494
[maven-backend]: https://github.com/Lithe-IDEA/lithe-plugin-maven/blob/bfa56dc80914df22ab60967ec859f8932870b494/backend/src/main/java/io/github/litheidea/maven/backend/MavenBackend.java
[build-service]: https://github.com/1lck/Lithe-IDEA/blob/1a7a95c8ce9d254bb6b8811af73e93d86a7badc1/macos/Sources/LitheExecutionModule/Services/BuildSystemService.swift
[build-sessions]: https://github.com/1lck/Lithe-IDEA/blob/1a7a95c8ce9d254bb6b8811af73e93d86a7badc1/macos/Sources/Lithe/Platform/MacOS/Build/MacBuildProviderSessions.swift
[build-protocol]: https://github.com/1lck/Lithe-IDEA/blob/1a7a95c8ce9d254bb6b8811af73e93d86a7badc1/rust/lithe-core/src/lsp/interface/build_provider.rs
[page-backend]: https://github.com/1lck/Lithe-IDEA/blob/1a7a95c8ce9d254bb6b8811af73e93d86a7badc1/rust/lithe-core/src/plugins/backend.rs
[page-sessions]: https://github.com/1lck/Lithe-IDEA/blob/1a7a95c8ce9d254bb6b8811af73e93d86a7badc1/macos/Sources/Lithe/Platform/MacOS/Plugins/MacPluginBackendSessions.swift
[maven-service]: https://github.com/1lck/Lithe-IDEA/blob/1a7a95c8ce9d254bb6b8811af73e93d86a7badc1/macos/Sources/LitheExecutionModule/Services/MavenService.swift
[agent]: https://github.com/1lck/Lithe-IDEA/blob/1a7a95c8ce9d254bb6b8811af73e93d86a7badc1/macos/Sources/Lithe/Application/Features/IdeCapabilitiesFeatureModel.swift
[execution-models]: https://github.com/1lck/Lithe-IDEA/blob/1a7a95c8ce9d254bb6b8811af73e93d86a7badc1/macos/Sources/LitheExecutionModule/Application/ExecutionFeatureModels.swift
[runtime-settings]: https://github.com/1lck/Lithe-IDEA/blob/1a7a95c8ce9d254bb6b8811af73e93d86a7badc1/macos/Sources/Lithe/Models/AppModel/AppModel+FeatureState.swift
[build-import]: https://github.com/1lck/Lithe-IDEA/blob/1a7a95c8ce9d254bb6b8811af73e93d86a7badc1/macos/Sources/Lithe/Models/AppModel/AppModel+BuildSystems.swift
[dependencies]: https://github.com/1lck/Lithe-IDEA/blob/1a7a95c8ce9d254bb6b8811af73e93d86a7badc1/macos/Sources/Lithe/Views/Workspace/DependencySidebarView.swift
[run-service]: https://github.com/1lck/Lithe-IDEA/blob/1a7a95c8ce9d254bb6b8811af73e93d86a7badc1/macos/Sources/LitheExecutionModule/Services/RunService.swift
[test-provider]: https://github.com/1lck/Lithe-IDEA/blob/1a7a95c8ce9d254bb6b8811af73e93d86a7badc1/macos/Sources/LitheExecutionModule/Services/StandardLanguageTestProvider.swift
[java-manifest]: https://github.com/1lck/Lithe-IDEA/blob/1a7a95c8ce9d254bb6b8811af73e93d86a7badc1/Plugins/mac/Official/JavaSupport/plugin.json
[jdt-host]: https://github.com/1lck/Lithe-IDEA/blob/1a7a95c8ce9d254bb6b8811af73e93d86a7badc1/macos/Sources/Lithe/Platform/MacOS/Plugins/HostIntegrations/Jdt/MacJdtHostIntegration.swift
[language-sessions]: https://github.com/1lck/Lithe-IDEA/blob/1a7a95c8ce9d254bb6b8811af73e93d86a7badc1/macos/Sources/LitheLanguageIntelligenceModule/Services/LanguageToolingSessionManager.swift
[java-entries]: https://github.com/1lck/Lithe-IDEA/blob/1a7a95c8ce9d254bb6b8811af73e93d86a7badc1/macos/Sources/Lithe/Models/AppModel/AppModel+JavaEntrypoints.swift
[spring]: https://github.com/1lck/Lithe-IDEA/blob/1a7a95c8ce9d254bb6b8811af73e93d86a7badc1/macos/Sources/Lithe/Application/Features/SpringFeatureModel.swift
[mybatis]: https://github.com/1lck/Lithe-IDEA/blob/1a7a95c8ce9d254bb6b8811af73e93d86a7badc1/macos/Sources/Lithe/Application/Features/MybatisFeatureModel.swift
[maven-store]: https://github.com/1lck/Lithe-IDEA/blob/1a7a95c8ce9d254bb6b8811af73e93d86a7badc1/macos/Sources/Lithe/Platform/MacOS/Persistence/MacMavenConfigurationStore.swift
[run-store]: https://github.com/1lck/Lithe-IDEA/blob/1a7a95c8ce9d254bb6b8811af73e93d86a7badc1/macos/Sources/Lithe/Platform/MacOS/RunConfiguration/MacRunConfigurationStore.swift
[win-maven]: https://github.com/1lck/Lithe-IDEA/blob/1a7a95c8ce9d254bb6b8811af73e93d86a7badc1/windows/tauri/src/features/maven/api/maven-core-api.ts
[win-run]: https://github.com/1lck/Lithe-IDEA/blob/1a7a95c8ce9d254bb6b8811af73e93d86a7badc1/windows/tauri/src/features/run/api/run-core-api.ts
[win-lsp]: https://github.com/1lck/Lithe-IDEA/blob/1a7a95c8ce9d254bb6b8811af73e93d86a7badc1/windows/tauri/src/platform/lsp-core-adapter.ts
[jdt-lock]: https://github.com/1lck/Lithe-IDEA/blob/1a7a95c8ce9d254bb6b8811af73e93d86a7badc1/third_party/jdtls/manifest.json
[jdk-lock]: https://github.com/1lck/Lithe-IDEA/blob/1a7a95c8ce9d254bb6b8811af73e93d86a7badc1/third_party/jdk/manifest.json
[java-note]: ../../implemented/architecture/2026-10-13-java-language-server-as-declarative-plugin.md
[build-note]: ../../implemented/architecture/2026-10-17-build-system-plugin-contract.md
[distribution-note]: 2026-10-24-java-support-independent-distribution.md
[debug-note]: 2026-10-25-unified-debug-engine-and-adapter-registry.md
[settings-note]: ../../implemented/architecture/2026-10-25-settings-native-configuration-editing.md
[contract-note]: ../../implemented/architecture/2026-10-23-plugin-contract-publishing.md
[lsp-note]: ../../implemented/architecture/2026-09-13-language-tooling-and-lsp-runtime-ownership.md
[debug-contract]: https://github.com/1lck/Lithe-IDEA/blob/1a7a95c8ce9d254bb6b8811af73e93d86a7badc1/shared/contracts/plugins/v1/README.md#api-level-4-debug-adapters
