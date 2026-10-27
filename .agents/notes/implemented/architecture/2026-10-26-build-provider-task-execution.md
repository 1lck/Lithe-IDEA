# Agent 笔记：Build Provider 原生任务执行

状态：已实现

## 先说结论

构建插件现在可以在自己的工作区 Provider（提供构建能力的后端进程）里执行任务、发现和运行测试，而不是把每个操作都展开为宿主命令。原生 Build 窗口复用现有工作区会话、输出、诊断、取消和进程清理，测试报告复用现有解析器，不要求插件增加网页或调用私有函数。这是 [#1495](https://github.com/1lck/Lithe-IDEA/issues/1495) 阶段 C 的构建、测试与应用启动准备基础能力；Maven/Java 业务迁移、多服务编排，及 Java/JDT 调试准备不在本决策已实现的范围内。插件自有原生程序的调试准备已经接到既有调试适配器注册表。

## 问题

现有 `buildProviders: 1` 只承载模型和依赖。普通任务由 Core 展开参数、宿主启动 CLI（命令行工具），因此后端即使拥有工程快照，也不能从原生入口掌握构建执行。直接调用插件私有函数会让宿主猜测参数、结果和错误码；另建一种工作区后端则重复 Provider 已有的进程、权限、取消和生命周期。

## 决策

### 类型化执行进入现有 Provider

`buildProviders: 2` 增加任务的 `source: "provider"`，`litheBuild` 在进程初始化时协商版本 2。两者分别负责安装准入与进程实际协议，不可互相替代。只协商版本 1 的后端明确拒绝执行，不退回 CLI 或私有函数。

Core 继续校验工程/目标/模型任务选择、路径与生效选项，返回 Provider 计划。后端收到任务声明 ID、选择、选项、参数与可选工具路径后，自行解释并执行领域业务。显式无效的工具或运行时选择沿用现有解析器的终止失败，不许可后端换一套自动发现。普通声明式命令任务继续走原来的公共命令能力，这不是 Maven/Java 旧业务 fallback。

这里只支持有界任务和测试；`application/service` 不借执行 RPC（请求/回复调用）伪装接入。测试发现使用独立的方法，不把发现误当成运行。正式形状、限制和共享用例在 `shared/contracts/plugins/v1/`，不在本笔记重复字段全集。

### 测试执行使用独立的版本准入

`buildProviders: 3` 和进程选择 `litheBuild` 版本 3 后，原生测试入口才能发送 `lithe/build/test`。版本 3 继续支持构建执行；选择版本 1/2 的进程明确拒绝测试，不转成构建任务或命令。测试声明仍持有作用范围、支持的筛选类型和报告位置，参数模板必须为空，也不能指定宿主领域集成的报告解析。

套件、用例和附加参数分别交给插件，由插件使用已有上游测试引擎执行。宿主不猜测 Java/Gradle 的选择器语法、不发现第二份测试模型。报告继续复用仓库现有的 JUnit XML 与标准测试结果解析、时间与路径检查；例如后端调用上游测试引擎生成 JUnit 报告，原生结果列表只读解析后的通用结果。不要把用例名拼进宿主命令后，再假定插件运行了完全相同的筛选条件。

测试与任务共用执行结果、进度及唯一操作身份，但各自有明确方法。工作区全部测试仍要求需要模型的构建系统已加载最新模型，以覆盖所有子工程报告。后端回复之后，运行身份与配置检查继续覆盖诊断和报告解析；改选项或关闭工作区不能发布迟到报告。

### 测试发现复用上游事实与已有树

插件显式声明 `test.discovery`，同时支持套件和用例筛选，原生窗口才提供发现入口。用户展开“已发现的测试”或点击发现时，宿主通过协议 3 的 `lithe/build/discoverTests` 请求整个实例的清单；不会在打开工程时扫描源码或后台执行工具。列表里的每个条目都必须能通过同一测试计划精确运行，Core（共享校验层）拒绝错误范围、路径、筛选类型和超限清单，不用部分成功假装已经列全测试。

插件复用其已选择的上游测试引擎回答套件、用例、工程及目标；宿主只显示现有共享树的节点。不增加另一套 Java 注解扫描、框架探测、工程图或 Test Explorer。条目身份包括工程和目标，所以两个模块中的同名测试不会互相覆盖。

发现和执行共用唯一原生操作槽及工作区进程，避免又建一个后台任务运行时。加载状态、成功空列表和失败是不同结果；失败可由用户重试。发现缓存仅在同一插件包、生效选项、启动设置及配置代次下可用，任何工作区源码修改都会清除清单，并取消正在进行的发现。旧工具栏选择运行前必须用 ID 重新查验当前清单，不能只保存旧请求然后直接执行。停用、更新、工作区重开和退出继续通过既有会话释放资源；报告和清单不写进插件包。

### 每个操作只有一个持有方

原生入口 → `BuildSystemService` → `MacBuildProviderSessions` → `LanguageServerRuntimeSession` → Core `lsp.buildRequest` → 同一 Provider 进程。模型、依赖、任务/测试执行及插件自己的函数可复用这个进程，但领域调用和私有函数继续有各自契约。

Core 用 JSON-RPC 请求 ID 作为后端看到的 `operationID`，进度按仍在等待的同一执行请求转换成宿主操作 ID。取消、超时、退出或回复后删除等待项；晚到回复与进度不能复活操作，宿主 ID 复用也不串用旧消息。超时最长一小时，取消走原来的 `$/cancelRequest`，卡住的写入继续使用既有逃生与后代进程清理路径。

结果区分工具的非零退出码、无效协议结果和后端拒绝。最终输出用于现有诊断解码；已流式显示的输出不重复追加。进度和结果都有限制，不能把无限后台服务放进单次任务。

### 工作区与配置失效

每个进程继续按插件、清单/包、构建系统及工作区隔离。`BuildSystemService` 在任务上绑定运行 ID、工作区代次、生效选项指纹、启动设置及被监听构建文件的配置代次。停用/移除插件、工作区关闭/替换、取消，以及同一构建系统选项或被监听配置文件变化，都停止或使对应操作失效；后端迟到输出不能进入替换运行或新工作区。

同一路径重开仍是新的服务代次。插件更新先停止旧 Provider 再替换包；配置变化后的下一次调用按现有规则重新建立会话。Windows 当前尚未接入 Build Provider 宿主，继续不声明此能力，不以 Core 支持版本 2 代替 Windows 实机实现。

### 资源与数据边界

本次没有新增下载入口、生成目录、缓存路径或用户数据迁移。执行复用既有 `workspaceStateDir` 和进程生命周期；插件包与发行目录只读，运行状态、日志、锁和输出仍由现有平台存储 adapter 提供位置。可变工作区状态不跨工作树共享，不影响代码签名或 Sparkle 增量更新的基线。

契约/协议变更合并前，用 `lithe-plugin-docs` 的 SDK 端到端工具验证当前源码；合并后按[契约发布规则](2026-10-23-plugin-contract-publishing.md)同步副本。已有 SDK 模型/依赖示例须继续协商版本 1 并正常工作；SDK 的新执行处理器与 Maven 插件接入属于后续独立交付，本次不宣称它们已迁移。

### 正确做法与反例

正确做法：插件将构建任务声明为 Provider 来源，用户在原生窗口点击任务，宿主发送类型化执行请求；取消后，由同一个会话停止请求，旧输出不能写回新运行。

不要这样做：宿主通过 `functions.invoke("maven.build")` 猜测 Maven 私有函数；Provider 超时后再启动旧 `MavenService`；为获取工作区进程而创建空网页。它们分别绕过领域契约、保留旧业务回退和错误绑定页面生命周期。

### 应用准备与应用进程分别管理

`buildProviders: 4` 与进程协商版本 4 增加应用启动准备。Provider 先使用自己的上游工程状态完成同步、构建并给出启动计划；Core 只检查目标身份、作用范围、参数大小、可执行工具引用与工作目录。比如后端从自己的工程引擎取得 classpath，返回分开的参数；宿主不要解析 POM 或源码再算另一份 classpath，也不要把启动命令拼成 shell 字符串。

本批只开放模型目标上的应用入口。运行入口不再生成一个空命令配置：Build 树按目标标签列出入口，点击时重新查询当前模型 ID。准备过程仍在 Build Output 显示进度，成功后交给现有 RunService，并切到 Run 窗口。RunService 继续持有进程、工具解析器、输出和 Java 长参数临时文件的租约；应用退出、停止或启动失败时释放租约。Provider 回复只是准备完成，不代表应用已经结束。

准备中的源码、模型、配置、插件或工作区变化使旧结果失效，解码完成后也要再次检查。应用启动后不因普通源码编辑就终止；停用所属插件或关闭工作区才按对应操作 ID 停止，旧操作 ID 不能停止新进程。运行目录只能是工作区内、属于当前实例的已有目录；符号链接解析后的目录也必须满足这一限制。没有新增运行资源目录、下载或跨工作树缓存，既有平台进程与临时参数 adapter 继续负责可写位置，安装包保持只读。

首次从 Build 树运行仍在 Build 窗口管理准备；从 Run 重启时，Run 的停止动作取消对应准备 ID，成功启动后改由进程 ID 管理。应用输出不再要求旧式检测器先生成 Run 配置，也不会因缺少 generated.json 被配置引导页遮住。多服务编排与 Java/JDT 调试准备仍未接入，不能把此增量表述为阶段 C 或 Java/Maven 迁移全部完成。

### 保存选择器，重启时重新准备

用户可以把当前 Provider 入口显式保存到已有 `.lithe/run/local.json`，不另建最近运行数据库或镜像设置。Core 只生成文档变更，平台适配器检查原文件快照后原子写入，并补齐本地文件的忽略规则；写入后重新读取，失败明确报告。相同插件/实例/目标/声明重复保存会更新原条目并保留 ID，不产生重复配置，也不改动其他条目和 JDK 默认值。

保存的是“由哪个插件的哪个实例准备哪个模型目标”，加上原始参数数组，不是后端上一次返回的 classpath、命令或环境。比如保存 `Main` 后重启，宿主重新查找当前已启用的插件和模型 ID，再发送 `prepareRun`；不能直接执行上次的 `java -cp ...`。首次保存不需要生成器建立一份空模型，读取时仅对明确保存的 Provider 入口允许空生成层；其他未识别工程保留原缺失语义。

原生点击和重启先等待工作区文档保存，保存失败或工作区代次改变便停止，不发送准备请求。准备失败、用户停止、插件停用和工作区切换各自终结对应身份；旧准备完成不能启动进程，旧终止事件不能结束替换准备。应用仍使用单个主运行槽，不宣称已经提供通用 Services 或多应用并行编排。

### SDK 使用同一组类型化入口

配套 Node/Java SDK 源码在独立的 `lithe-plugin-docs` 仓库实现任务、测试、发现与运行准备处理器，不复制进主仓库。SDK 选择宿主明确提供的最高共同协议版本；版本 1 不能调用执行、版本 2 不能调用测试、版本 3 不能调用运行准备，即使后端注册了对应处理器也一样。清单能力准入与进程协商是两层独立检查，SDK 不用私有函数代替领域方法。

执行、测试和运行准备的上下文保留 Core 分配的线缆操作身份，进度只带这份身份。处理器改动自己的参数对象不能换掉进度归属；取消和结束后不再报告。Node 的类型声明与 Java 的具名入口共同表达这条边界，Core 继续负责选择器、工作区路径与领域输出校验，SDK 不再维护一份工程引擎。

两套无页面示例使用虚构引擎展示协议，端到端回归通过真实 Core 检查构建退出码、精确筛选、运行前构建与准备计划、并行工作区隔离、取消后的工具清理，以及包含 SDK/JAR 的完整包字节不变。SDK 处理器属于开发中的源码，不代表已发布 SDK 或现有 Maven/Java 插件完成迁移；发布契约副本仍必须等主仓库合并后运行同步工具。

### 调试启动保留已选适配器的身份

现有调试适配器注册表（DebugAdapter Registry）已经定义插件 ID 与适配器 ID 组成的身份，但 macOS 会话过去只按源文件选择语言默认适配器。工程目标可能没有打开的源文件，同一语言也可能有多个调试器，所以明确选中的适配器现在通过 `DebugLaunchConfiguration.adapterProviderID` 交给原有会话管理器。原有插件文件启动入口也携带这份身份，重试与配置变换继续保留它。

开发者要从已安装、已启用的注册中取得 `插件 ID/适配器 ID`，并在启动前完成现有 Core 参数及权限校验。正确例子是把已校验的 LLDB 启动参数交给 `dev.example.native/lldb`；不要只传一个 `.c` 文件，再期待宿主碰巧选中同一个调试器。明确身份已经消失、被停用或不支持该请求时，启动在创建进程前失败。不能因此改用同语言的另一插件，也不能把身份当成可调用私有函数、任意进程或端口的权限。

宿主保留所有适配器的完整身份，包括只能附加到进程的适配器；它们不会挤占文件启动的默认项。源码断点传给匹配语言的已注册适配器（未限制语言的原生适配器接收全部源码），并在之后启动时重放；函数、异常与数据断点按当前会话的适配器身份更新。新增会话启动失败只关闭自己的资源，原会话和选择继续保留。这里不增加资源目录、下载或缓存；插件进程仍由既有平台 adapter 放在原有可写状态位置，安装包保持只读。

`buildProviders: 5` 增加独立的原生程序调试准备请求。运行声明只引用同插件适配器；后端先构建，再返回程序路径、参数、工作目录和环境，不得夹带适配器身份、进程、端口或任意调试协议参数。Core 检查程序属于当前工程实例且为已有文件；平台交接前再次检查可执行权限和符号链接，随后复用注册表的目标绑定生成参数。`debugAdapters: 2` 只增加参数与环境的类型化目标绑定，原有 DAP 引擎、适配器资源与权限规则继续生效。

Build 树和已保存的 Provider Run 配置都有 Debug 入口，启动前先保存文档。异步准备、Core 解码和宿主交接共享已有运行准备的配置、源码与模型失效判断；调试停止只取消对应准备，准备成功后由 Debug 会话负责资源。正确例子是插件自己的构建引擎生成当前程序，再交给自己声明的 LLDB 入口；不要把 `prepareRun` 返回的命令改名成调试计划，更不能从 Provider 返回另一个插件的私有函数或开放端口。两个 SDK 同步增加类型化入口并保留版本准入；正式契约副本仍在合并后同步。

这个纵向增量只覆盖插件自有原生可执行程序。Java/JDT、跨插件准备与长期服务仍未迁移，不能据此声称整个阶段 C 或 Java Support 拆分已完成。

## 考虑过的备选方案

- **扩展独立页面 backend。** 它是全应用范围的私有服务；改为工作区服务需要重复已有 Provider 的作用域和清理。执行首先复用现有工作区机制。
- **只加入任意方法调用。** 代码较少，但 Core 无法判断允许的方法、结果及进度归属，容易成为通用 JSON-RPC 隧道；仅开放明确的构建执行方法。
- **继续要求所有任务返回 argv。** 对简单工具仍然合适，但拥有工程状态的后端不能控制执行与结果；作为并列来源保留，后端任务没有失败回退。
- **让测试复用任务方法并让宿主推导筛选命令。** 无法证明旧后端支持测试，也容易扩大筛选范围；单独协商测试方法，保留选择器为类型化数据。报告解析复用现有实现，不增加另一套测试报告系统。
- **只在宿主源码里找测试，或返回不可运行的标签。** 宿主会拥有第二份框架事实，测试清单和实际运行容易不一致。插件返回上游选择器，Core 只复用现有测试计划校验；当前不支持精确筛选的工具暂不声明发现能力。
- **一次补齐全部 Run/Test/Debug。** 各领域有不同目标和状态要求；先交付可独立验证的执行路径，后续基于真实需求补类型化能力，复用 #1210 的调试契约。
- **让 Provider 准备后伪造一个带语言后缀的文件来选调试器。** 会把工程目标误当成文件，遇到同语言多个适配器或插件停用时选错。直接传递现有注册身份，不增加另一套调试器路由与进程机制。

## 后果

收益是无页面的原生入口可以调用工作区后端执行，复用现有进程和 UI，并通过同一套协议证明进度、失败和取消。代价是多一个明确的能力/协议版本；后端作者需要实现执行处理器，宿主不能自行把未知任务变成命令。Maven/Java 仍有旧生产调用，只有对应纵向迁移完成并删除旧实现，#1495 才能最终关闭。

## 验证

共享 fixture 覆盖版本准入、类型化请求/回复、路径与大小限制，以及本地 Run 选择器。Core 回归使用独立计时进程验证旧协议拒绝新方法、进度映射、取消、注入时间的超时和晚到结果；保存回归验证不生成空模型、重复保存保留 ID、其他命名空间的元数据和工具链不丢失、缺省参数归一化、非法进程字段明确拒绝。

macOS 使用固定的 Swift 6.3.3 工具链和原生计时 harness。相关服务回归控制准备开始、解码暂停、停止或工作区切换的顺序；原生存储用真实 Core 和隔离临时目录验证保存后读回。Run 的对外操作身份从准备到应用退出保持不变，底层准备/进程各自按身份取消；Agent 启动返回同一主运行记录，授权仍沿用既有入口。插件停用、进程替换和工作区切换不能留下旧输出、订阅或可操作的旧主运行记录。

Agent 入口回归从真实本地 Run 配置读取选择器，用可控 Provider 准备与进程替身依次验证启动、准备中停止、重启、输出和退出状态。准备到进程的交接不得更换公开操作 ID；重启产生新 ID，旧 ID 的停止请求必须报告失效，不能取消新准备。替身不启动系统工具，这项证据不代替真实插件后端的端到端验收。

可复验的检查入口：

```bash
./scripts/verify-agent-notes.sh
./scripts/verify-shared-contracts.sh
./scripts/verify-runtime-bundle-immutability.sh
./scripts/verify-service-boundaries.sh
./scripts/verify-windows-boundaries.sh
./scripts/verify-rust-core-comments.sh
./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --jobs 6 --filter 'BuildSystemServiceTests|ExecutionModuleTests|MacBuildProviderSessionsTests|RustBuildSystemOperationsTests|BuildToolProviderResolutionTests|PluginWebBridgeTests|BuildSystemToolWindowTests|RunConfigurationIntegrationTests|RunWorkflowCoordinatorTests|IdeCapabilitiesTests'
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'BuildSystemServiceTests|RustBuildSystemOperationsTests|MacBuildProviderSessionsTests|LitheDebugModuleTests|PluginDebugAdapterTests|PluginLiveActivationTests|RunConfigurationIntegrationTests|RunWorkflowCoordinatorTests'
cargo test --manifest-path rust/Cargo.toml -p lithe-core --lib build_systems
cargo test --manifest-path rust/Cargo.toml -p lithe-core --lib run_configuration
cargo test --manifest-path rust/Cargo.toml -p lithe-core --lib provider_debug
cargo test --manifest-path rust/Cargo.toml -p lithe-core --lib lsp
```

当前本地逐项计时证据为 `saved-provider-complete-macos.json`、`saved-provider-core.json`、`provider-sdk-unit.json` 与 `provider-sdk-native.json`，对应 HTML/JUnit 保存在 `.artifacts/test-stability/`。SDK 兼容场景另外使用契约锁定的 Core，原生工作流场景使用显式工作区源码快照，不能把日志里的基线 SHA 当作完整已提交实现。Java 产物检查 Java 8 字节码；本地运行时和 Windows 实机证据分别记录，不能用编译替代运行。

调试身份交接的本地回归记录在 `provider-debug-routing-final.json` 及对应 HTML/JUnit：182 个测试通过，包含真实 Rust Core 桥接后 DAP 参数不混入宿主身份、无源文件目标、明确身份失效、请求类型不匹配、多适配器断点、失败后恢复原会话及同步回调替换会话后的精确清理。测试使用受控会话，不代表真实插件适配器、Provider 调试准备或 Windows 已验收。

原生调试准备的本地增量报告是 `provider-debug-preparation-macos.json`（375 项）、`provider-debug-preparation-core.json`（1,304 项）、`provider-debug-sdk-unit.json`（114 项）和 `provider-debug-sdk-native.json`（6 项），均有对应 HTML/JUnit。报告覆盖当前 Swift/Node/JDK 运行时的受控宿主与真实 SDK 进程；原生调试准备取消后构建子进程结束、另一工作区仍可用，完整插件包保持只读。平台交接回归另验程序不可执行、程序/实例别名变化以及插件撤回和替换；没有启动真实 LLDB、JDT 或 Windows 产品，所以功能矩阵继续保持 `pending`。

在 `lithe-plugin-docs` 运行以下入口可以复验 SDK 部分：

```bash
node --test sdk/node/test/*.test.mjs scripts/*.test.mjs
npm ci --prefix sdk/node --ignore-scripts
npm run --prefix sdk/node test:types
mvn -B -ntp -f sdk/java/pom.xml verify
node scripts/sdk-e2e.mjs
node scripts/sdk-e2e.mjs --source /path/to/Lithe-IDEA --working-tree --build-workflows
```

工作区快照工具只复制 `rust/` 和 `shared/` 的暂存、未暂存与未跟踪源码，源目录和 Git index 保持只读，忽略的构建缓存不复制。SDK 验证使用独立构建目录，不与主工作树共享可变 Cargo 状态；这些临时验证输入不是产品运行资源或可跨工作树复用缓存。

这些证据不替代真实插件工程、发行包和 Windows 实机验收，功能矩阵保持 `pending`。没有新增下载物或产品资源目录；本地用户配置不属于可跨工作树共享的构建缓存。新增目录或依赖时仍须遵循资源复用和安装包只读规则。

## 适用范围

- `rust/lithe-core/src/build/`、`rust/lithe-core/src/lsp/interface/`、`rust/lithe-core/src/plugins/`
- `rust/lithe-core/src/execution/configuration.rs`
- `macos/Sources/LitheCoreContracts/Execution/BuildSystemContracts.swift`
- `macos/Sources/LitheExecutionModule/Services/BuildSystemService.swift`
- `macos/Sources/LitheExecutionModule/Services/RunService.swift`
- `macos/Sources/Lithe/Platform/MacOS/MacServiceContainer.swift`
- `macos/Sources/LitheExecutionModule/Application/BuildSystemsFeatureModel.swift`
- `macos/Sources/Lithe/Views/Run/BuildSystemToolWindowView.swift`
- `macos/Sources/LitheLanguageIntelligenceModule/Runtime/LanguageServerSession.swift`
- `macos/Sources/Lithe/Platform/MacOS/Build/MacBuildProviderSessions.swift`
- `macos/Sources/Lithe/Core/Rust/RustBuildSystemOperations.swift`
- `shared/contracts/plugins/v1/`
- `shared/platform-feature-matrix/features/build-system-plugins.json`
- `shared/contracts/run-configuration-v2.schema.json`
- `shared/fixtures/run-configuration/build-provider.json`
- `macos/Sources/Lithe/Platform/MacOS/RunConfiguration/MacRunConfigurationStore.swift`
- `macos/Sources/Lithe/Application/Features/IdeCapabilitiesFeatureModel.swift`
- `macos/Sources/LitheCoreContracts/Debug/DebugAdapterContracts.swift`
- `macos/Sources/LitheDebugModule/Runtime/DebugAdapterSessionManager.swift`
- `macos/Sources/LitheDebugModule/Application/GenericDebugFeatureModel.swift`
- `macos/Sources/Lithe/Platform/MacOS/Plugins/MacLivePluginRegistry.swift`
- `macos/Sources/Lithe/Platform/MacOS/Debug/MacBuildDebugLaunchResolver.swift`
- `shared/fixtures/debug/adapter-selection-v1.json`
