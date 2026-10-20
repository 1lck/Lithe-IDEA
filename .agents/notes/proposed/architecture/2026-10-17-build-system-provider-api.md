# Agent 笔记：构建系统 Provider 的通用 API 与声明式插件化

状态：提议中

## 先说结论

Lithe 对构建工具的支持原本分散在三处：Rust Core 里写死的运行入口探测器、一整套 Maven 专用类型和工具窗口，以及只认“语言”的声明式插件契约。新增一个构建工具或构建插件（例如 Issue #10 里 Gradle 的 Loom/NeoForge 任务）都要改 Core 代码。

统一模型的第一步已经落地：插件 API 级别 3 的 `buildSystems` 契约、Rust Core 的校验与解码、13 个 `build.*` 命令，以及进程型 Provider 的 Core 部分（与语言服务器共用启动字段和启动计划），见[构建系统插件契约](../../implemented/architecture/2026-10-17-build-system-plugin-contract.md)。macOS 宿主也已经能启动 Provider 并发送 `lithe/build/model`、`lithe/build/dependencies`。本提案只保留**还没做的部分**：Windows 宿主的通用 Build 工具窗口和 Provider、运行配置接入构建模型、现有探测器和 Maven 功能迁移到同一契约，以及以后的 `lithe/build/execute` 和 BSP（构建服务协议）档。

对日常开发的影响：在宿主接入之前，不要再给 `execution/detectors/` 增加新生态，也不要照着 Maven 再写一套工具窗口；新构建工具先写成声明和 fixture，等宿主接入后直接可用。Maven 每项现有功能的迁移归属见第 6 节的对照表。

## 问题

### 现状

| 位置 | 做了什么 | 问题 |
| --- | --- | --- |
| `rust/lithe-core/src/execution/detectors/` | npm、Cargo、Go、Gradle、Python、Make、just、Compose、Procfile 等探测器，在一次共享目录遍历中产出运行配置 | 生态知识写死在 Core 里。Gradle 只能匹配一张固定的插件 ID 表（Spring Boot、Quarkus、Micronaut、`application`），表外插件注入的任务完全看不到，这就是 Issue #10 |
| `rust/lithe-core/src/project/maven*.rs` + `MavenService` / `MavenView`（macOS）+ `windows/tauri/src/features/maven/`（Windows） | Reactor（Maven 的多模块聚合工程）扫描、Profile、生命周期、依赖树、诊断解析、Surefire 测试报告、工具窗口 | 质量很高，但类型全是 `Maven*`，其他构建工具无法复用；工具窗口的“生命周期 / 依赖 / Profile / 执行目标”结构也没有通用版本 |
| `shared/contracts/plugins/v1/` | API 1/2 只有 `languages`、`languageServers`、`executionProviders`（按语言运行/测试单个文件）；API 3 已加入 `buildSystems` | 契约和 Core 已就绪。macOS 宿主已经通过通用 Build 工具窗口使用 `build.*` 命令，声明 `buildSystems: [1]` 和 `buildProviders: [1]`；Windows 宿主还没有接入，也不声明能力 |

[公共扩展契约提案](2026-10-13-public-extension-contract-and-provider-api.md) 已把 BuildSystem/Task 列为领域扩展点，但没有展开字段和边界。

### 不处理的后果

- 每支持一个生态或一个构建插件，都要改 Core、发 Lithe 新版本，社区插件无法参与。
- 第二个需要工具窗口的构建工具（Gradle 最可能）会再复制一套 Maven 式的类型和视图，两端各一份。
- 新探测器容易在无意中执行仓库代码（例如在打开项目时跑 `gradle tasks`），违反现有“打开项目不能执行仓库程序”的规则。

## 调研：主流构建工具提供了什么

### 共同的能力维度

下表每一行是一种能力，列出各工具里的叫法，以及这个事实应该由谁拥有。“上游拥有”是指 Lithe 只读取、展示和编排，不自己推算。

| 能力 | 各工具中的对应物 | 事实归属 |
| --- | --- | --- |
| 识别与根目录 | `pom.xml`、`settings.gradle[.kts]`、`Cargo.toml` 的 `[workspace]`、`go.work`/`go.mod`、`package.json` 的 workspaces、`*.sln(x)`、`CMakeLists.txt`、`MODULE.bazel`、`build.sbt`、`Package.swift` | 清单文件（静态可判断） |
| 调用方式与工具链 | Wrapper（`mvnw`、`gradlew`）、包管理器选择（`packageManager` 字段或锁文件决定 npm/pnpm/Yarn/Bun）、版本锁定（`rust-toolchain.toml`、`.nvmrc`、`.python-version`、`global.json`、`.tool-versions`）、所需运行时（Maven/Gradle 需要 JDK） | 清单 + 宿主工具链发现 |
| 工程结构 | 两层：工程（Maven 模块、Gradle project、Cargo package、Go module、.NET project）和构建目标（Cargo target 的 bin/lib/test/bench/example、CMake target、Bazel label、SwiftPM product） | 上游 |
| 任务 | Maven 生命周期阶段与插件 goal、Gradle task、Cargo 内置命令与 `[alias]`、npm scripts、Make 目标、just 配方、.NET 目标、CMake 预设、Bazel 的 build/test/run | 上游；部分可静态读取 |
| 运行入口 | Cargo bin、Go `main` 包、Gradle `run`/`bootRun`、`spring-boot:run`、npm `dev`/`start`、.NET `OutputType=Exe`、CMake 可执行目标、Bazel `*_binary` | 上游 + Lithe 分类（应用 / 服务 / 任务） |
| 测试 | 发现（`cargo test -- --list`、`go test -list`、`dotnet test --list-tests`、`ctest --show-only=json-v1`、`pytest --collect-only`）、过滤语法（`-Dtest=A#m`、`--tests A.m`、`-run '^TestX$'`、`--filter`）、结果格式 | 上游 |
| 构建诊断 | 文本错误行（Maven、MSBuild、javac）、结构化输出（Cargo `--message-format=json`、`go build -json`、Gradle Problems API） | 上游输出，Lithe 解码 |
| 依赖 | `dependency:tree`、Gradle `dependencies`、`cargo metadata` 的 resolve 图、`go list -m -json all`、`npm ls --json`、`uv tree`、`dotnet list package --format json` | 上游 |
| 构建选项 | Maven Profile、Cargo features 与 `--release`、Go build tags、.NET Configuration/TargetFramework、CMake 预设与 build type、Bazel `--config`、离线、跳过测试 | 清单声明维度，用户选择取值 |
| 同步与重载 | 监听哪些文件、自动还是手动重载（IDEA 的“Load Maven Changes”）、守护进程（Gradle daemon、mvnd、Bazel server、sbt server） | Lithe 编排 |
| 目录布局 | 输出与生成目录（`target/`、`build/`、`node_modules/`、`.gradle/`、`bazel-*`），用于项目树排除 | 清单或上游 |
| 给语言服务器的配置 | Maven settings/Profile → JDT LS、`compile_commands.json` → clangd、BSP → Metals/sourcekit-lsp | 由语言服务器自己导入；Lithe 只传递用户选择 |

### 各工具的机读接口

| 工具 | 工程模型 | 任务 / 入口 | 测试结果 | 构建诊断 | 长驻服务 / BSP |
| --- | --- | --- | --- | --- | --- |
| Maven 3.9（4.0 仍在 RC） | 无官方 JSON。POM 可静态解析（Lithe 已在 Rust 中实现 reactor 扫描）；`help:effective-pom` 要执行 Maven 并可能下载插件；Maven Embedder 在 JDT 的 m2e 里 | 固定生命周期阶段 + 插件 goal | Surefire/Failsafe XML（JUnit 格式） | 纯文本，需要按行匹配 | mvnd；没有成熟的 BSP 实现 |
| Gradle 9.x | Tooling API（TAPI，官方 Java 库：模型查询、进度事件、取消）；init script（初始化脚本，可注入自定义输出） | 任务由插件在运行时注入，静态不可知；`gradle tasks --all` 每次要配置整个构建 | `build/test-results/**/*.xml` + TAPI 测试事件 | Problems API（8.6 起，仍标记孵化中），可经 TAPI 取得结构化问题 | Gradle daemon；Microsoft 开源的 Build Server for Gradle（BSP），已是 vscode-gradle 的默认导入方式 |
| Cargo | `cargo metadata --format-version 1`（稳定：workspace、packages、targets 的 kind、features、依赖图） | 内置命令 + `[alias]` + 各 target | libtest JSON 仍不稳定（2026 年 Rust Project Goal 在推进）；cargo-nextest 可输出 JUnit | `--message-format=json`（稳定，含 rustc 诊断和产物路径） | 无；BSP 2.2 草案增加了 Cargo/Rust 扩展 |
| Go | `go list -json`、`go list -m -json all`、`go env -json` | `main` 包即可运行；`go generate` | `go test -json`（test2json，稳定） | `go build -json`（Go 1.24 起）、`go vet -json` | 无；gopls 自己调用 `go list` |
| npm / pnpm / Yarn / Bun | `package.json` + workspaces 静态可读；`npm ls --json`、`pnpm ls --json` | `scripts` 静态可读 | 取决于测试框架（Jest、Vitest 可输出 JUnit/JSON） | 取决于工具（tsc、eslint） | Nx/Turborepo 另有项目图与任务图（`nx show projects --json`、`turbo run --dry=json`） |
| Python（uv / Poetry / Hatch / PDM） | `pyproject.toml`（PEP 621）静态可读；`uv workspace metadata` 有 JSON，但仍是预览功能 | `[project.scripts]`、`[tool.poetry.scripts]`；任务运行器各家不同（poe、tox、nox、hatch） | pytest `--junitxml` | 无统一格式 | 无 |
| .NET（MSBuild） | `dotnet msbuild -getProperty/-getItem/-getTargetResult`（.NET 8 起输出 JSON）；`dotnet sln list` | Build/Clean/Publish/Pack/Test 目标；`OutputType=Exe` 可运行 | `dotnet test --logger trx`（TRX）或 JUnit logger | MSBuild 规范格式 `file(line,col): error CODE: …` | MSBuild 节点复用 |
| CMake | File API（`.cmake/api/v1`：目标、产物路径、编译参数）；`CMakePresets.json` | 预设（configure/build/test/workflow）+ 目标 | `ctest --output-junit` | 编译器文本；`compile_commands.json` 供 clangd 使用 | 无 |
| Bazel / Buck2 | `bazel query`/`cquery` 的 jsonproto 输出；Buck2 `targets --json`、BXL | 对 label 执行 build/test/run | `bazel-testlogs/**/test.xml`（JUnit）；BEP | BEP（Build Event Protocol，构建事件流） | Bazel server；JetBrains 维护的 Bazel BSP |
| sbt / Mill / Bloop | 原生 BSP | BSP + 各自任务 | BSP 测试报告 | BSP `build/publishDiagnostics` | 是，BSP 起源于 Scala 生态 |
| SwiftPM / Xcode | `swift package describe --type json`；`xcodebuild -list -json`、`-showBuildSettings -json` | product / target；scheme | `swift test --xunit-output`；`xcresulttool` | 编译器文本 | sourcekit-lsp 新增了 SwiftPM BSP 服务（目前需手动开启） |
| Make / just / Task | Make 没有机读模型；`just --dump --dump-format json`；`task --list-all --json` | 目标 / 配方（just 支持参数） | 无 | 无 | 无 |
| Composer / Rake / Mix / Dart / Deno / Zig | 多为静态清单（`composer.json` scripts、`deno.json` tasks、`pubspec.yaml`）加列表命令（`rake -AT`、`zig build -l`） | 同左 | Dart `--reporter json`、Flutter `--machine` | 文本 | 无 |

### 可借鉴的现成抽象

- **BSP**（Build Server Protocol，构建服务协议，IDE 与构建工具之间的 JSON-RPC 协议，类似 LSP）：两层模型 `BuildTarget`（带 `application`/`library`/`test` 等标签和 `canCompile`/`canTest`/`canRun`/`canDebug` 能力位），加上 compile/test/run 请求、任务进度通知和诊断推送。它是目前唯一跨工具的标准，但 2.2 仍是预发布版，Maven、npm、Cargo 没有成熟的服务器。
- **IntelliJ External System**（IDEA 给 Gradle、sbt 等外部构建系统用的统一框架）：“设置 → 解析出 `DataNode` 工程图（模块、内容根、依赖、任务）→ 导入”；任务由 `ExternalSystemTaskManager` 执行；`ExternalSystemProjectTracker` 负责“清单变了，提示重载”；Build 工具窗口消费统一的构建事件。Lithe 的工具窗口形态应参考它。
- **VS Code 的 `taskDefinitions` 与 `problemMatchers`**：任务类型的 JSON schema 和“用正则把输出行变成诊断”都可以纯声明贡献。这是“声明式构建插件”最接近的先例，但 VS Code 只有任务，没有工程模型。
- **Nx 推断任务**（Project Crystal）：插件按文件 glob 识别配置文件，再推断出工程和目标，与 Lithe 的“共享遍历 + 探测”同形。
- **Zed tasks**：任务模板变量加语言提供的 runnables，和现有 `executionProviders` 的模板展开相似。

### 从调研得到的四条结论

1. **能力维度一致，事实来源差异巨大。** 从“清单就是全部答案”到“必须执行构建脚本”，跨度很大，所以模型来源必须分档声明，不能假设统一。
2. **稳定的机读输出越来越多，但格式各不相同。** `cargo metadata`、`go list -json`、MSBuild `-getItem`、CMake File API、JUnit XML 都很稳定。宿主需要的是“通用解码 + 声明式映射”，而不是每个工具一份 Rust 解析器。
3. **取得模型通常意味着执行仓库代码或联网。** Gradle 脚本、Maven 插件、Wrapper 下载发行版、`go list` 下载模块和工具链。信任边界必须写进 API，不能留给每个探测器自觉。
4. **BSP 值得接，但只能作为一档。** 它免费带来 sbt、Mill、Bazel、SwiftPM 和 Gradle，却覆盖不了 Maven、npm、Cargo，而且协议本身仍在演进。

## 提案

### 1. 已落地的部分，以及与原始提案的差异

契约、Core 实现和验证方式见[构建系统插件契约](../../implemented/architecture/2026-10-17-build-system-plugin-contract.md)，这里不再重复。与原始提案相比有这些差异，后续工作以已实现的 Note 为准：

- 模型来源有 `static`、`command`、`provider`、`hostIntegration` 四档，依赖来源有 `command`、`provider`、`hostIntegration`。`buildServer`（BSP）档留到第 5 节的 P3。
- Provider 的两种写法都必须写 `executesProjectCode` 和 `mayUseNetwork`，原计划的共享写法 `{ "languageServer": "java" }` 没有这两个标志，现在缺少就是 `plugin.manifest.invalid`。Provider 的模型请求总是覆盖整个实例，依赖请求只支持工作区和工程两层。
- 解码格式是静态模型的 `toml`、命令输出的 `jsonStream`、`junitXml`、`lineMatcher` 和四个规范格式（`litheBuildModel`、`litheTestResults`、`litheDependencies`、`litheDiagnostics`），其余格式在第 7 节的审查中拿掉了。原计划的 `trx`、`tap`、`sarif`、`goTestJson` 还没有实现，有实际插件需要时作为 `buildSystems` 的新版本加入。
- 选项参数通过 `${optionArguments}` 或 `${optionArguments:<id>}` 整体放置，没有原计划的 `${option:<id>}` 拼接变量；拼接方式由选项自己的 `arguments` 模板决定。
- `runtimeDependencies` 是开放列表：`java`、`node`、`go` 由宿主管理，其他运行时由插件自己描述。可执行文件新增了 `runtime` 一类。
- Maven 用 `outermost` 嵌套加 `maven` 集成，没有为它增加专用的嵌套方式。

### 2. 宿主要做的事

两端宿主接入时，按 Core 给出的计划执行，代码里不出现任何构建系统的名字。

| 能力 | 宿主做什么 | 用到的命令 |
| --- | --- | --- |
| 发现实例 | 打开项目、启用或禁用插件时，把全部启用的清单交给 Core | `build.detect` |
| 选定可执行文件 | 按候选顺序检查文件是否存在、执行版本探测；Wrapper 一律视为执行仓库代码 | `build.invocationPlan`、`build.checkToolVersion` |
| 选项 | 按“构建系统 ID + 实例根”保存用户选择；把 `dropped` 里的选项改存生效值 | `build.resolveOptions` |
| 加载模型 | 为写文件的命令分配新的 `${outputFile}`，运行后交给 Core 解码，再删除文件 | `build.modelPlan`、`build.decodeModel` |
| 任务、测试、依赖 | 执行 Core 给出的 argv；测试结束后把输出和运行开始时间交给 Core | `build.taskPlan`、`build.testPlan`、`build.decodeTestResults`、`build.dependencyPlan`、`build.decodeDependencies` |
| 诊断 | 把构建输出交给 Core，结果进入现有诊断列表 | `build.decodeDiagnostics` |
| 重载提示 | 监听 `sync.watch` 里的文件，用指纹判断模型是否过期 | `build.syncFingerprint` |

通用 Build 工具窗口按 IDEA 的形态组织：构建系统实例 → 工程 → {任务分组、运行入口、依赖、选项}。工具栏提供重载、执行任务（带任务目录补全，相当于现在的“Execute Maven Goal”）和选项开关；输出区复用现有构建输出和诊断列表。现有 `MavenView` 是它的第一个用户，迁移期间行为不能退化。

另外两项不属于工具窗口，但要一起完成：

- **运行配置接入构建模型**：`runConfig.generate` 增加“构建模型”这个输入来源，生成、覆盖和 ID 仍走原流程，不另起一套运行配置。Cargo fixture 已经证明运行入口与现有探测器逐字一致，可以作为第一个迁移对象。
- **插件市场放开 API 3**：宿主具备 Build 工具窗口后，让宿主接受级别 3，并在宿主自己的能力表里加上 `buildSystems: [1]`，通过 `hostCapabilities` 发给 Core。macOS 已完成声明式构建这一步，Windows 待做；Provider 插件还要求独立的 `buildProviders: 1`，宿主必须完成协议协商、请求和生命周期管理后才可声明，macOS 已声明，Windows 待做。不需要再改 `plugins/marketplace.rs`：只用语言服务器的级别 3 插件，在宿主声明对应能力后就能先上架，不必等 Build 工具窗口。规则见[声明式插件按能力分版本](../../implemented/architecture/2026-10-17-plugin-capability-versions.md)。

### 3. 执行仓库代码的信任边界

- `static` 档永远不启动进程，可以在打开项目时运行。
- `command` 档只在用户显式操作（打开 Build 工具窗口、点击重载、运行任务）或工作区已被用户信任后运行，绝不在打开项目时自动运行。这延续了现有 Gradle 探测器“不在打开项目时启动 Gradle”的判断。
- 插件声明的 `executesProjectCode` 和 `mayUseNetwork` 只用于展示。只要选中的可执行文件是工程里的文件（`gradlew`、`mvnw`），宿主就按执行仓库代码处理。
- 模型缓存、守护进程状态写入 `${workspaceStateDir}` 或宿主缓存，不写插件包，不写安装目录（见仓库的运行时只读规则）。
- 守护进程登记进[统一子进程生命周期](2026-10-16-unified-child-process-lifecycle.md)的进程账本；禁用插件时停止它们，但不停止用户自己在终端启动的同一个工具。

### 4. 进程型 Provider 的宿主部分

Provider 的 Core 部分已经落地：两种 `provider` 写法均要求 `buildProviders: 1`，Core 支持校验和计划，但这不表示宿主已经实现；未传 `hostCapabilities` 的工具调用仍可使用。`provider` 声明与语言服务器共用 `ServerProcess` 启动字段和校验，`languageServerLaunchPlan` 可以按 `buildSystemID` 选中进程，`model`、`dependencies` 支持 `source: "provider"`，`build.modelPlan`、`build.dependencyPlan` 返回 `lithe/build/*` 请求，`build.decodeModel`、`build.decodeDependencies` 解码回复。细节见[构建系统插件契约](../../implemented/architecture/2026-10-17-build-system-plugin-contract.md)第 9 节。协商（`capabilities.experimental.litheBuild`）、`lsp.buildRequest` 和 macOS 宿主的进程管理也已落地，见同一 Note 第 9、10 节；下表保留作为 Windows 接入时的对照。这里只保留还没做的部分。

Provider 就是语言服务器那一种进程，所以宿主侧也全部复用：

| 方面 | 语言服务器现在的做法 | Provider 还要做的事 |
| --- | --- | --- |
| 传输与生命周期 | JSON-RPC 2.0，`Content-Length` 分帧，`initialize` → `initialized` → `shutdown` / `exit`，`$/cancelRequest` 取消 | 完全相同，宿主复用现有 LSP 客户端和会话管理；共享写法（`buildProvider.languageServer`）直接复用正在运行的语言服务器会话 |
| 能力协商 | `initialize` 返回的 `capabilities` | 构建能力放在 `capabilities.experimental.litheBuild`（LSP 规范留给扩展的位置）：宿主发 `{"versions": [1]}`，Provider 回 `{"version": 1}`，双方忽略不认识的字段；没有回复版本时宿主不发 `lithe/build/*`。规则写在契约 README 的 Build providers 一节，Core 的 LSP 客户端已实现，两端宿主共用 |
| 发送请求 | — | 把 Core 计划里的 `provider.method` 和 `provider.params` 原样发出，回复作为 `result` 交给 Core 解码，取消沿用 `$/cancelRequest` |
| 进程管理 | 宿主负责启动、崩溃、停用插件时停止，状态写插件状态目录 | 相同，并登记进[统一子进程生命周期](2026-10-16-unified-child-process-lifecycle.md)的进程账本 |

#### `lithe/build/execute`（可选，未实现）

Provider 自己执行任务或测试，用 `lithe/build/output`、`lithe/build/testResult`（`litheTestResults` 的单条）、`lithe/build/diagnostic`（`litheDiagnostics` 的单条）通知流式汇报。Gradle Tooling API 只能这样拿到结构化进度和测试事件。没有协商出这项能力时，任务仍由 Core 展开 argv、宿主执行。加入时，Provider 一侧走协议协商（`litheBuild` 的新版本或可选方法），清单一侧只需要给 `test.results` 增加 `provider` 来源。后者是 `buildSystems` 能力的新版本，只影响用到它的插件。

#### 唯一不同：什么时候允许发构建请求

进程类型相同，但触发时机不同。语言服务器在打开文件时自动启动，因为它不执行仓库代码，所以它也从不选用工程里的可执行文件。构建请求往往会让 Provider 加载工程的构建脚本（`executesProjectCode: true`），也就是执行仓库代码。因此：

- 单独的 Provider 进程与 `command` 档同级，只在用户显式操作或工作区已信任后启动。
- 复用语言服务器进程时，进程可以照常随文件打开启动，但宿主在工作区被信任之前不发送任何 `lithe/build/*` 请求。

#### 对 `hostIntegration` 的影响

`hostIntegration: maven` 是迁移期的例外：它让 Maven 的解析代码继续留在 Core 里。有了 Provider 之后，Maven 的终点也是插件自带的进程，可以是单独的 Provider（Maven 自己的模型构建器，结果比现在的静态 POM 读取更准确），也可以复用 Java 插件的 JDT LS 进程，因为它已经导入了 Maven 工程。等两端都切换过去，就从契约里删除 `hostIntegration`，Core 里的 `project::maven` 也随之删除。

#### 与 BSP 的关系

BSP 本身也是 JSON-RPC 上的进程外构建协议，生命周期与 LSP 几乎相同。以后要接现成的 BSP 服务器时，用同一个传输层和进程管理，由 Core 把 BSP 的 `BuildTarget` 等回复映射成统一模型。先做 `lithe/build/*` 方法，因为载荷已经存在，Gradle 和 Maven 用它就够了。

#### 以后可能的整理

如果除了语言和构建之外还有第三类功能也要用这种进程（例如调试适配器），再新增一个独立的能力（例如 `servers` 列表），由语言、构建系统等按 ID 引用。已有插件继续声明 `serverProcess` 1，不受影响。在那之前不改现有 `languageServers` 的形状。

### 5. 分阶段落地

1. **P0 契约骨架（Core 已完成）**：API 3 的 `buildSystems`、13 个 `build.*` 命令、Cargo/Go/Gradle/Maven 四个 fixture 和 `build-plans.json` 标准答案。
2. **P1 通用工具窗口与运行配置**：两端实现第 2 节的宿主能力和 Build 工具窗口；`runConfig.generate` 接入构建模型，先迁移 Cargo；把 npm、just、Make、Composer 等现有探测器改写成内置声明；定下 `buildSystems.test` 与 `executionProviders.test` 在同一工程里谁优先。
3. **P2 进程型 Provider 与 Gradle**：`provider` 声明、启动计划和回复解码的 Core 部分已完成（`gradle-provider`、`mix-provider` fixture 和标准答案）。macOS 宿主部分（协商、发送 `lithe/build/*`、进程生命周期）已完成，剩下 Windows 宿主。Gradle 先用插件包内的 init script 输出 `litheBuildModel`（fixture 已验证这条路）关闭 Issue #10，再评估改用 Tooling API 的 Provider 以获得结构化进度和测试事件；Go、Cargo 的依赖树走模型命令档。
4. **P3 BSP**：有实际需求（Scala、Bazel、SwiftPM）时，在同一传输层上加入 `bsp/2` 协议。
5. **P4 Maven 收编**：官方插件 `dev.lithe.maven` 先以 `hostIntegration: maven` 进入同一领域模型，由通用工具窗口渲染，Windows 随后用同一组 fixture 切换。最后改为插件自带的 Provider，从 Core 删除 `maven` 集成。逐项对照见下一节。

### 6. Maven 插件化对照表

迁移后，Maven 由官方插件 `dev.lithe.maven` 提供。它的清单声明一个 `id` 为 `maven` 的构建系统，模型来源是 `hostIntegration: maven`。下表的“归属”只有四种：

- **声明**：写在 `dev.lithe.maven` 清单里的纯数据。
- **集成**：`maven` 宿主集成，也就是 Core 里现有的 Rust 实现。迁移期间保留不重写，终点是移进 Maven 插件的 Provider 进程（第 4 节）。
- **通用宿主**：所有构建系统共用的宿主能力，代码里不出现 Maven 字样。
- **Java 插件**：留在 Java/JDT 集成里，通过声明和 Maven 的选项、任务关联。

除特别标注外，各项都在 P4 迁移。

Core 侧已经具备的部分：fixture `maven-build.plugin.json`（插件 ID 为 `dev.lithe.fixture.maven-build`）声明了 Wrapper、`MAVEN_HOME` 和 `PATH` 三类候选，Profile、`settings.xml`、本地仓库、离线和跳过测试五个选项，`clean`、`compile`、`package`、`install` 和自由输入的 goal，统一后的单测模板，以及诊断正则；`maven` 集成负责 reactor 模型、依赖树和 Surefire 结果。表里“迁移做法”剩下的主要是宿主工作、正式的 `dev.lithe.maven` 清单，以及删除旧命令。

#### 工程模型

| 现有功能 | 现在在哪 | 归属 | 迁移做法 |
| --- | --- | --- | --- |
| 识别 Reactor 根、多个独立 Reactor | Core `maven.scan`、`detect_all(root, maven_root)` | 声明 + 集成 | `detection.markers` 写 `pom.xml`。哪个 POM 是根、哪些是子模块要解析 `<modules>`，继续由集成判断 |
| 模块树、坐标、packaging | Core `maven.scan`；macOS `MavenProject`；Windows `maven.types` | 集成 | 集成把模块映射成统一模型里的“工程”，坐标和 packaging 作为工程属性 |
| 源码根（main/test/generated × 源码/资源） | Core `MavenSourceRoot`；macOS 模块树；Windows `maven-source-root-rows` | 集成 + 通用宿主 | 统一模型增加可选的 `contentRoots`（内容根，参考 IDEA 的概念），Maven 是第一个提供者，Cargo、Gradle 以后也能填 |
| 框架服务入口（Spring Boot、Quarkus、Micronaut） | Core `detectors/maven.rs` 的 `SERVICE_PLUGINS` | 声明 | 集成在模型里给出每个模块用到的构建插件坐标；“坐标 → 启动 goal（`spring-boot:run`、`quarkus:dev`、`mn:run`）、执行分类为服务”的对照表搬进清单，社区插件可以补充其他框架 |

#### 调用与配置

| 现有功能 | 现在在哪 | 归属 | 迁移做法 |
| --- | --- | --- | --- |
| 固定的全局参数 `-B -ntp` | Core `launch_plan` | 声明 | `invocation.globalArguments` |
| Maven 可执行文件发现与覆盖 | macOS `MacRuntimeDiscovery`（Homebrew 路径、`maven-core-*` 探测、mvnd 排在普通 Maven 之后）；Windows `run.rs`（`mvnw.cmd`、`MAVEN_HOME`、`M2_HOME`、`MVND_HOME`） | 声明 + 通用宿主 | `invocation` 声明 Wrapper 名和它必需的 `.mvn/wrapper/maven-wrapper.properties`、启动器名、环境变量、常见安装位置、低优先级的 mvnd，以及版本探测参数和 `Apache Maven\s+(…)` 正则。候选顺序由 `build.invocationPlan` 统一计算，两端只检查文件是否存在、执行探测。Homebrew 等常见安装位置和 mvnd 还没有对应的候选种类，迁移前要决定是新增候选种类还是让宿主的运行时设置补充。可以提前到 P1 验证 |
| Maven 使用的 JDK | `java_home_path`；macOS `ProjectRuntimeService.mavenProcessEnvironment`、`DebugLaunchConfigurationResolver` 的 `.maven(homeOverride:)` | 声明 + 通用宿主 | `invocation.runtimeDependencies` 声明 `java`，宿主按通用规则选 JDK 并设置 `JAVA_HOME`。用户覆盖存为构建系统的“调用覆盖”，所有构建系统共用这一项 |
| Profile 列表、默认激活、自定义 Profile、恢复默认 | Core 扫描出 `profiles`；macOS `addCustomProfile`、`restoreDefaultProfiles`；Windows `maven.store` | 声明 + 集成 + 通用宿主 | 清单声明多选选项 `profiles`：取值来自模型，允许用户补充，用 `,` 拼接后映射成 `-P`。选择界面和“恢复默认”由通用宿主提供 |
| 跳过测试、`settings.xml`、本地仓库 | `MavenLaunchContextRequest` 的 `skip_tests`、`settings_path`、`local_repository_path` | 声明 + 通用宿主 | 布尔选项 → `-DskipTests`；文件选项 → `-s`；目录选项 → `-Dmaven.repo.local=`。路径只能由用户填写 |
| 配置保存：团队共享的 `.lithe/maven/config.json` 加按 Reactor 分开的本机文件 | macOS `MacMavenConfigurationStore`；Windows `maven_load_configuration`、`maven_write_configuration` | 通用宿主 | 通用存储按“构建系统 ID + 实例根”分键。首次读取时从旧位置迁移，旧文件不删除，迁移规则用 fixture 锁住 |
| 生效配置预览（空字段实际解析成什么） | Windows `maven_resolve_effective_configuration`；macOS 目前没有 | 通用宿主 | 基于 `build.invocationPlan` 和 `build.resolveOptions`，两端的任何构建系统都能显示“自动检测到的值” |
| `pom.xml` 变更提示与重载 | macOS `markPomChanged`、`isReloadRequired`、`reloadProject` | 声明 + 通用宿主 | `sync.watch` 列出 `pom.xml`；通用宿主监听文件，用 `build.syncFingerprint` 判断是否过期。通用部分在 P1 完成 |

#### 任务与运行

| 现有功能 | 现在在哪 | 归属 | 迁移做法 |
| --- | --- | --- | --- |
| 生命周期 clean … deploy | macOS `MavenLifecyclePhase`；Windows `maven.types`；Core `maven.launchPlan` 的 goals | 声明 | `tasks.catalog` 固定列出 9 个阶段，分组为 `lifecycle`，作用范围为工作区和工程 |
| 执行任意 goal（Execute Maven Goal） | macOS `runCustomGoal`；Windows `maven-tool-window-actions` | 通用宿主 + 声明 | 通用“执行任务”输入框，清单声明允许自由输入，补全来自任务目录。输入框在 P1 完成 |
| 按模块执行（`-pl <模块> -am`） | Core `maven.launchPlan` | 声明 | 已用 `nestedProjectSelected` 条件参数写进 fixture，`build_systems` 测试证明结果与内置 `maven_arguments` 逐字一致；宿主切到 `build.taskPlan` 即可 |
| 模块右键菜单（Run、Test、Package、Execute Goal、Reload）与启动模块（含调试） | macOS `MavenModuleOperations`、`AppModel+MavenOperations`；Windows `maven-module-operations`、`maven-node-context-menu` | 通用宿主 + 声明 | 工程节点菜单由“作用范围包含工程”的任务和运行入口生成；哪些任务放进菜单由任务声明决定 |
| 运行配置的 `extensions.maven`（module、mainClass、profiles、jvmArguments、programArguments、reactorPath）和 `project-maven` 工具链 | Core `execution/configuration.rs` | 集成 | `extensions.maven` 成为 `maven` 构建系统专属的扩展命名空间，字段和运行配置 ID 都不变。其他构建系统使用 `extensions.<buildSystemID>`。`project-maven` 改由 `build.invocationPlan` 解析，工具链 ID 不变 |
| 输出、停止、50 万字符输出上限、依赖树 60 秒超时 | macOS `MavenService` | 通用宿主 | 进程进入[统一子进程生命周期](2026-10-16-unified-child-process-lifecycle.md)的进程账本；上限用通用值，超时按声明的档位。P1 完成 |

#### 测试与诊断

| 现有功能 | 现在在哪 | 归属 | 迁移做法 |
| --- | --- | --- | --- |
| 运行单个测试类或方法 | macOS `StandardLanguageTestProvider`：`-Dtest=<类>#<方法> test`；Windows `maven.store`：`test -Dtest=<类>#<方法> -Dsurefire.failIfNoSpecifiedTests=false` | 声明 | 写成 `test` 的过滤模板。**两端现在的参数和顺序都不一致**：Windows 多出的参数让没有匹配测试的上游模块不报错。fixture 已统一成一个模板（保留 Windows 的 `-Dsurefire.failIfNoSpecifiedTests=false`），两端切到 `build.testPlan` 后不一致自然消失 |
| Surefire/Failsafe 结果 | Core `maven.testResults`：解析文本汇总，再读 XML 报告补全每个方法的结果 | 集成 + 声明 | 目前由 `maven` 集成负责（文本汇总加 XML 报告）。目标是改走通用 `junitXml` 解码器、只依赖 XML，届时把 fixture 的 `results` 换成报告 glob |
| 测试结果类型 | macOS `LanguageTestResults = MavenTestResults` | 通用宿主 | 改成通用测试结果类型，Maven 只是其中一个产出者。P1 完成 |
| 构建诊断（`[ERROR] 路径:[行,列] 消息`） | Core `maven.diagnostics` 的正则 | 声明 | 正则已写进 fixture，用 `lineMatcher` 解码；两端改调 `build.decodeDiagnostics` 后删除 `maven.diagnostics` |

#### 依赖

| 现有功能 | 现在在哪 | 归属 | 迁移做法 |
| --- | --- | --- | --- |
| 依赖树计划（固定 `maven-dependency-plugin:3.8.1:tree`，写输出文件） | Core `maven.dependencyPlan` | 集成 | 保留在集成里，经 `build.dependencyPlan` 调用 |
| 依赖树解析（resolved、omittedDuplicate、omittedConflict、selectedVersion） | Core `maven.dependencies` | 集成 + 通用模型 | 这些字段成为通用依赖节点的可选字段，其他构建系统也能用来表达冲突 |
| 依赖输出文件分配与清理 | macOS `MacMavenDependencyOutputStore`；Windows `maven_create_dependency_output`、`maven_remove_dependency_output` | 通用宿主 | 通用宿主在 `${workspaceStateDir}` 下分配 `${outputFile}`，所有构建系统共用 |
| 依赖区（加载、取消、失败状态） | macOS `MavenView`；Windows `maven-pane` | 通用宿主 | Build 工具窗口的通用依赖区 |

#### Java 联动

| 现有功能 | 现在在哪 | 归属 | 迁移做法 |
| --- | --- | --- | --- |
| 把 Profile、settings 同步给 JDT LS | Core `lsp.updateMavenConfiguration`、`lsp.retryMavenProfiles`、`JdtMavenConfiguration` | Java 插件 | Java 插件清单声明它要读取 `maven` 构建系统的哪些选项。选项变化时，通用宿主把生效选项快照转给语言服务器会话；写进 JDT 设置的逻辑仍在 Core 的 `jdt` 集成里 |
| 直接启动前执行资源处理 goal | [Java 构建与启动边界](../../implemented/architecture/2026-09-18-java-project-build-and-launch-boundary.md) | Java 插件 | 留在 Java 集成，但改为通过 `build.taskPlan` 请求 `maven` 构建系统执行，不再自己拼 Maven argv |
| `pom.xml` 上的解析问题 | macOS `MavenResolutionProblems`；Windows `use-maven-resolution-problems` | 通用宿主 | Build 工具窗口显示“构建清单文件上的语言服务器诊断”。文件名来自 `detection.markers`，代码里不写 `pom.xml` |
| 依赖浏览器的 Maven 回退 | [工作区依赖浏览器](../../implemented/architecture/2026-09-18-workspace-dependency-browser.md) | Java 插件 | 投影的输入改成通用依赖节点 |
| 混合协议 `RustJavaMavenOperations` | macOS | 拆分 | Maven 部分并入通用的构建操作协议；代码视觉、类名、Spring/MyBatis 索引等留在 Java |

#### 界面入口

| 现有功能 | 现在在哪 | 归属 | 迁移做法 |
| --- | --- | --- | --- |
| Maven 工具窗口 | macOS `BuildSystemToolWindowView`；Windows `maven-pane`、`maven-run-pane` | 通用宿主 | macOS 已改为每个构建系统各有一个窗口，由同一视图按声明渲染；内置 `MavenView` 已删除，Windows 迁移待完成 |
| `toggle-maven` 命令与快捷键 | macOS `LitheCommandCatalog` | 通用宿主 | 2026-10-18 用户决定删除旧命令，不保留别名；每个构建系统按声明推导自己的切换命令，见已实现 Note 第 11 节 |

Maven 在 P4 内部的迁移顺序：

1. Core 加入 `build/integrations/maven.rs`。`build.*` 与 `maven.*` 并行，用 fixture 证明两者结果一致。
2. macOS 切到通用 Build 工具窗口，逐项核对生命周期、Profile、依赖树、执行 goal 和模块右键菜单。
3. Windows 用同一组 fixture 切换。
4. 删除已被声明取代的 Core 命令（先删 `maven.diagnostics`）；其余 `maven.*` 降为集成内部函数，从 `rust-core-api.md` 中移除。

### 7. 发布前按真实插件审查 API 3 的字段（已完成）

API 3 还没有发布。`buildSystems` 的版本 1 一旦发布就要长期支持；而按能力分版本之后，以后再加字段只影响用到它的插件（作为 `buildSystems` 版本 2）。所以发布前先拿掉了没有真实插件需要的部分。

审查方法：列出 schema 里 `buildSystems` 的字段路径和枚举值，对照六个 fixture（Cargo、Go、Gradle、Maven 和两个 Provider）实际用到的部分。第一版盘点把 fixture 已经用到的 `where`（Go）、`fallback`、`whenFile`、`optionValues`（Cargo）、`transform`（Go 的 `lastSegment`）、字面值 `value` 和依赖 `map`（Go）误列为未使用，复查后改正。

2026-10-18 的决定：

| 结论 | 内容 | 理由 |
| --- | --- | --- |
| 保留 | Provider 的 `packaged`、`systemCommand` 启动方式，`node` 运行时，`packagedRuntime`、`validationArguments`、`runtimeDependencies` | 与语言服务器共用 `serverProcess`，语言服务器的 fixture 已经验证过；拿掉反而要在共用代码里加例外 |
| 保留 | `detection.nesting: "separate"`、`model.output: "stdout"` | 这两个是默认值，fixture 依赖默认值，所以没有写出来 |
| 保留 | 选项的 `singleSelect`、`choices`、`default` | Cargo 的 `--profile`、CMake 的构建类型都是单选，下一个真实插件大概率会用到 |
| 保留 | 参数的 `{value, when}` 条件写法（`globalArguments`、`model.arguments`、`run[].arguments`） | 条件求值是模板的公共机制，只在某几个列表里禁止，规则反而不规整 |
| 保留，但第一个使用它的插件要补 fixture | 规范格式 `litheTestResults`、`litheDiagnostics`；诊断严重级别 `warning`、`information`、`hint` | 这是插件自带脚本的出口：没有 JUnit 报告、也没有固定输出格式的工具只能靠它。目前只有单元测试 |
| 保留 | `invocation.runtimeDependencies[]` 里 `java`、`node`、`go` 以外的自定义运行时 | 没有 fixture 使用，但它是[构建系统插件契约](../../implemented/architecture/2026-10-17-build-system-plugin-contract.md)为 .NET、Erlang、Dart 这类工具保留的开放运行时清单；拿掉后这些工具只能假设自己在 `PATH` 上，宿主也无法提示版本不够 |
| 保留 | fixture 用到的映射规则：`where`、`fallback`、`whenFile`、`each`、选择器的各种写法、`lastSegment`、字面值、`optionValues`；工程级的目标和内容根；依赖的平铺 `map` | 真实插件在用 |
| 保留 | 内容根的全部类型 | 类型与 `litheBuildModel` 共用一个枚举，只在映射里收窄会让两种来源的词汇不一致 |
| 已拿掉 | 工程里的任务规则（`tasks`、`template`、执行方式）、`map` 顶层的 `targets` 和 `tasks`、工程的 `parent`、映射出来的标签、`parentDirectory` 变换、依赖的 `children` | 没有 fixture 使用。规则越多，`map` 越像一门要长期维护的小语言；从工具读任务、算父子关系、产出依赖树，都交给插件脚本输出 `litheBuildModel`、`litheDependencies` |
| 已拿掉 | 静态模型的 `json`、`yaml`；模型命令的 `json`、`toml`、`yaml`；依赖命令的 `json`、`toml`、`yaml` | 静态清单只有 `Cargo.toml` 这一种真实用法；命令输出的单个 JSON 文档由 `jsonStream` 读成单元素数组 |
| 已拿掉 | `layout.generated` | 宿主还没有展示生成目录的地方，Maven 的生成源码目录目前由 `hostIntegration` 处理 |

拿掉的部分已从 schema、README、Rust 实现和单元测试中删除；`invalid-manifests.json` 里有九条用例证明这些写法现在会被拒绝。代价是 Deno、npm 这类清单是 JSON 的工具不能再纯静态声明，要附带脚本走 `command` 来源，任务要等用户请求后才出现。以后真有插件需要，作为 `buildSystems` 版本 2 加回来，并附带 fixture。

### 正确做法

- 宿主实现“对这个模块执行 package”：调用 `build.taskPlan`，把返回的 argv、环境变量和工作目录交给现有执行链路，输出交给 `build.decodeDiagnostics`。宿主代码里没有 `-pl`，也没有 Maven 字样。
- 宿主实现“清单变了，提示重载”：监听 `build.detect` 返回的实例对应的 `sync.watch` 文件，变化后调用 `build.syncFingerprint`，指纹和上次加载时不同才提示。
- 新构建工具的声明怎么写，见[构建系统插件契约](../../implemented/architecture/2026-10-17-build-system-plugin-contract.md)的“正确做法”。

### 不要这样做

- 在 `execution/detectors/` 新增一个生态的 `.rs` 文件，或在 Core、宿主里按 `buildSystemID == "gradle"` 写分支。这与已撤销的 `descriptor.id == "java"` 是同一类特判。
- 在打开项目时执行 `gradle tasks`、`mvn help:effective-pom` 或任何 Wrapper：既慢，又会执行仓库代码。
- 让 Lithe 的构建模型成为语言服务器的第二个事实来源。JDT LS 自己导入 Maven/Gradle，rust-analyzer 自己运行 `cargo metadata`，Lithe 只把用户选择（Profile、features）传给它们。
- 把 Maven 的类型直接改名成通用类型。`MavenLifecyclePhase`、`MavenSourceRootKind` 是 Maven 的事实，应由 `maven` 集成映射成通用模型，而不是让其他工具假装有生命周期。

## 考虑过的备选方案

### 全部走 BSP

最有吸引力的地方：协议现成，一个客户端覆盖 sbt、Mill、Bazel、SwiftPM、Gradle，任务进度和诊断都是结构化的。暂不作为唯一方案，因为 Maven、npm、Cargo、Go、.NET 没有成熟的 BSP 服务器，Lithe 等于要自己写这些服务器；BSP 服务器都是长驻进程，资源开销大；而且 2.2 版本还在预发布阶段。保留为 P3 的一档。

### 每个构建工具保留自己的工具窗口

最有吸引力的地方：延续 `MavenView` 的做法，每个工具的界面可以完全贴合它的概念。不采用，因为第二个需要工具窗口的构建工具（Gradle 最可能）就会再复制一套类型和视图，两端各一份；社区插件也无法得到界面。通用窗口只按能力块渲染，工具特有的概念（Maven 生命周期）通过任务分组表达。

### 照搬 VS Code 的 tasks 与 problemMatchers

最有吸引力的地方：成熟、纯声明、生态熟悉。不够用，因为它只有任务，没有工程和目标两层结构，撑不起类似 Maven 的工具窗口、依赖树和按模块运行测试。它的行匹配器设计已经作为 `lineMatcher` 借鉴进契约。

## 验收标准

Core 契约部分的验收已在已实现的 Note 里完成。剩下的工作按下列标准验收：

- 一个只声明 `buildSystems`、不声明语言和 UI 的插件能在两端安装、启用和禁用；宿主的 `hostCapabilities` 含 `buildSystems` 后，插件市场列出它的 API 3 版本。
- 发布 API 3 之前，第 7 节的字段审查已完成（2026-10-18），拿掉的部分已从 schema、README 和 Core 中删除；发布前如果又加了 `buildSystems` 字段，按同样方法再审一遍。
- Cargo 改由构建模型生成运行配置后，生成结果（含 ID）与现有探测器的标准答案一致；用户已写的覆盖配置不会脱钩。
- 安装一个第三方 Gradle 构建插件后，它注入的每个运行任务各自生成一条运行配置，名字包含 project 路径和任务名，满足 Issue #10 的验收条件，Core 和宿主都不改代码。
- 在未信任的工作区打开项目时，没有任何 `command` 档进程被启动；Wrapper 只在用户操作后运行。
- 只有 `buildSystems: [1]` 的宿主可安装模板构建插件，但市场、清单校验和安装审查必须拒绝自有与共享 Provider；宿主真正实现 Provider 后才加入 `buildProviders: [1]`。已有 `declarative_plugins` 和 `marketplace_plugins` 回归覆盖这一边界，后续宿主实现要保留这些断言。
- `gradle-provider` 这类自有 Provider 只在用户操作或工作区信任后启动，并登记进进程账本；`mix-provider` 这类共享写法不启动第二个进程，在工作区信任前不发送 `lithe/build/*`。
- 任务通过现有执行链路运行，具备取消、期限和输出上限；禁用插件会停止它登记的守护进程，用户在终端启动的同一工具不受影响。
- `junitXml` 和 `lineMatcher` 解码出的诊断与测试结果能跳转到编辑器位置。
- 迁移过程中 Maven 工具窗口的生命周期、Profile、依赖树和执行目标行为不变；`build.*` 与 `maven.*` 并行期间，两者对同一组 Maven fixture 的结果一致。
- 两端宿主代码里没有按构建系统 ID 写的分支；运行 `./scripts/verify-shared-contracts.sh`、`./scripts/verify-runtime-bundle-immutability.sh` 通过。

## 风险

- **选择器表达力不足，逐渐长成编程语言。** 规则：选择器只做取值、过滤和简单映射；表达不了的情况升级到 `command` 档，让插件附带的脚本输出规范格式，而不是给选择器加控制流。
- **上游格式不稳定。** libtest JSON 未稳定，`uv workspace metadata` 是预览功能，Gradle Problems API 仍在孵化，BSP 2.2 是预发布版，Maven 4 将带来 POM 4.1.0。Core 已经支持“工具最低版本”探测，并在解码失败时返回 `plugin.build.invalidOutput`；宿主必须把这两种失败显示给用户，不能静默显示空列表。
- **模型命令慢。** Gradle 配置一次可能要几十秒。必须缓存模型，用监听文件的指纹判断是否过期，并沿用 `operationID` 丢弃过期结果。
- **与语言服务器重复导入。** JDT LS 与 Build Server for Gradle、Metals 与 sbt 都可能各自启动一份构建进程。接入 BSP 前要确认语言服务器是否已经连接同一个构建服务器，避免两个客户端争用。
- **ID 稳定性。** 运行配置 ID 是用户覆盖配置的连接键。迁移任何探测器都必须用 fixture 锁住 ID，否则用户的覆盖配置会悄悄失效。
- **回退方式。** 每个阶段都保留原有实现直到 fixture 证明结果一致；内置声明和旧探测器在同一版本里只启用一个。

## 适用范围

- `shared/contracts/plugins/v1/`
- `rust/lithe-core/src/plugins/declarative.rs`
- `rust/lithe-core/src/execution/detectors/`
- `rust/lithe-core/src/execution/types.rs`
- `rust/lithe-core/src/project/maven.rs`
- `rust/lithe-core/src/execution/configuration.rs`
- `rust/lithe-core/src/lsp/interface/engine.rs`
- `rust/lithe-core/src/runtime/dispatcher.rs`
- `shared/contracts/rust-core-api.md`
- `macos/Sources/Lithe/Platform/MacOS/Runtime/MacRuntimeDiscovery.swift`
- `macos/Sources/Lithe/Platform/MacOS/Persistence/MacMavenConfigurationStore.swift`
- `macos/Sources/LitheExecutionModule/Services/MavenService.swift`
- `macos/Sources/LitheExecutionModule/Services/StandardLanguageTestProvider.swift`
- `macos/Sources/LitheCoreContracts/Execution/MavenContracts.swift`
- `macos/Sources/Lithe/Views/Run/BuildSystemToolWindowView.swift`
- `windows/tauri/src/features/maven/`
- `windows/tauri/src/features/run/`
- `windows/tauri/src-tauri/src/maven.rs`
- `windows/tauri/src-tauri/src/run.rs`

## 调研来源

- [Build Server Protocol 规范](https://build-server-protocol.github.io/docs/specification.html)与[版本记录](https://github.com/build-server-protocol/build-server-protocol/releases)
- [Microsoft：Build Server for Gradle](https://devblogs.microsoft.com/java/new-build-server-for-gradle/)、[vscode-gradle 架构说明](https://github.com/microsoft/vscode-gradle/blob/develop/ARCHITECTURE.md)
- [Gradle 9.3 发行说明（Problems API）](https://docs.gradle.org/9.3.0/release-notes.html)
- [Maven 4.0.0-rc-6 发行说明](https://maven.apache.org/docs/4.0.0-rc-6/release-notes.html)
- [Rust 2026 Project Goal：libtest JSON](https://rust-lang.github.io/rust-project-goals/2026/libtest-json.html)、[cargo metadata](https://doc.rust-lang.org/cargo/commands/cargo-metadata.html)
- [Go 提案：`go build -json`](https://github.com/golang/go/issues/62067)
- [uv 工作区元数据](https://docs.astral.sh/uv/reference/internals/metadata/)
- [SourceKit-LSP 与 BSP](https://forums.swift.org/t/extending-functionality-of-build-server-protocol-with-sourcekit-lsp/74400)
- 相关 Note：[构建系统插件契约](../../implemented/architecture/2026-10-17-build-system-plugin-contract.md)、[声明式语言插件](../../implemented/architecture/2026-10-12-declarative-language-plugins.md)、[Java 语言服务器是声明式插件](../../implemented/architecture/2026-10-13-java-language-server-as-declarative-plugin.md)、[Java 构建与启动边界](../../implemented/architecture/2026-09-18-java-project-build-and-launch-boundary.md)、[运行配置发现质量](../../implemented/feature/2026-09-20-run-configuration-discovery-quality.md)、[工作区依赖浏览器](../../implemented/architecture/2026-09-18-workspace-dependency-browser.md)
