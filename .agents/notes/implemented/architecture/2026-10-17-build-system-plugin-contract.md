# Agent 笔记：构建系统插件契约与 Core 统一构建模型

状态：已实现

## 先说结论

Lithe 现在用一套统一的构建模型描述所有项目级构建工具（Build Tool，例如 Maven、Gradle、Cargo、Go）。插件在 `plugin.json` 的 `buildSystems`（插件 API 级别 3）里用纯 JSON 声明：怎样认出工程、用哪个可执行文件、有哪些选项、任务、运行入口和测试，以及怎样读工具的输出。思路与 LSP 插件化相同：插件只提供数据，通用逻辑只在 Rust Core 实现一次。

Rust Core 负责校验声明、识别工程、展开每一条命令行，并把输出解码成统一的形状，通过 13 个 `build.*` JSON 命令交给宿主。宿主只负责找可执行文件、启动进程、监听文件和保存用户选择，代码里不按构建系统的名字写分支。因此社区插件不改宿主代码就能加入一个新构建工具。

映射（`map`）只从解码后的文档里挑值。挑值以外的逻辑由插件自己处理：读 JSON、YAML 清单，从工具读任务，计算父子关系，这些都交给插件自带的脚本输出规范格式（第 6 节）。声明和规范格式都表达不了的工具（Gradle Tooling API 等），由插件自带的 Provider 进程回答。Provider 就是语言服务器那种进程：共用启动字段、校验和启动计划，只多回答 `lithe/build/model`、`lithe/build/dependencies`，回复仍由 Core 解码（第 9 节）。

目前落地的是 Core、共享契约和 macOS 宿主（第 10 节）。macOS 为每个启用的构建系统各开一个工具窗口，向 Core 声明 `buildSystems: [1]` 和 `buildProviders: [1]`，并在用户点击加载模型或依赖时启动 Provider、发送 `lithe/build/*`；Windows 宿主还没有接入。API 3 的清单按能力分版本，声明式构建系统使用 `buildSystems`，两种写法的 Provider 都额外使用 `buildProviders: 1`；插件市场只在宿主声明支持对应能力时才列出 API 3 的版本，见[声明式插件按能力分版本](2026-10-17-plugin-capability-versions.md)。宿主接入和 Maven 迁移的计划见[构建系统 Provider 提案](../../proposed/architecture/2026-10-17-build-system-provider-api.md)。

## 问题

在这次改动之前，构建工具的知识分散在三处：

- `execution/detectors/` 里写死的运行入口探测器。
- 一整套 `Maven*` 专用类型和工具窗口。
- 只认“语言”的声明式插件契约（API 1/2）。

结果是：每支持一个生态或一个构建插件（例如 Issue #10 里 Gradle 的 Loom/NeoForge 任务），都要改 Core、发 Lithe 新版本，社区插件无法参与。

提案中的调研（Maven、Gradle、Cargo、Go、npm 系、Python 系、.NET、CMake、Bazel、sbt、SwiftPM、Make/just 等）给出了两条结论，它们决定了这次的实现方式：

1. 各工具的**能力维度**一致：识别工程、调用方式、工程结构、任务、运行、测试、诊断、依赖、构建选项、同步。差别只在于事实从哪里来。
2. 稳定的机读输出越来越多（`cargo metadata`、`go list -json`、JUnit XML 等），但格式各不相同。所以宿主需要的是“通用解码 + 声明式映射”，而不是每个工具一份 Rust 解析器。

## 决策

### 1. 一个模型，按能力拆块

每个构建系统由能力块组成，只有 `detection`（识别）和 `invocation`（调用方式）必填。其余能力块是 `runtimeDependencies`、`options`、`model`、`tasks`、`run`、`test`、`diagnostics`、`dependencies`、`sync`、`layout`。

没有声明的能力不报错，也不会出现在界面上。例如 Cargo fixture 没有声明依赖树，Build 工具窗口就不显示依赖区。

字段全集只写在 `shared/contracts/plugins/v1/README.md` 的 “API level 3: build systems” 一节和 `plugin-manifest.schema.json` 里，本 Note 不重复。四个 fixture（`cargo-build`、`go-build`、`gradle-build`、`maven-build`）是完整示例，`gradle-provider`、`mix-provider` 分别示范 Provider 的两种写法。

### 2. Core 与宿主的分工

| 角色 | 负责 | 不负责 |
| --- | --- | --- |
| 插件 | 识别规则、可执行文件候选、选项、任务目录、运行和测试模板、解码方式、监听文件 | 在宿主进程里执行任何代码；机器路径；凭据 |
| Rust Core | 校验声明；识别实例；读取静态模型；展开模板得到 argv 计划；解码模型、测试、诊断和依赖输出；计算指纹 | 启动进程；写文件；保存用户选择 |
| 宿主 | 选定可执行文件并探测版本；启动进程并负责取消、期限和输出上限；分配输出文件；监听文件；保存选项；信任确认 | 生态知识；拼 argv；按构建系统名写分支 |

宿主通过 13 个命令使用 Core，请求和结果形状见 `shared/contracts/rust-core-api.md` 的 “Build systems” 一节：

| 用途 | 命令 |
| --- | --- |
| 识别 | `build.detect`：一次传入全部已启用插件，返回实例；`static` 和 `hostIntegration` 来源的模型直接附带，`provider` 来源不附带 |
| 调用 | `build.invocationPlan`（可执行文件候选和版本探测）、`build.checkToolVersion` |
| 选项 | `build.resolveOptions`：合并保存值和默认值，返回生效值和配置指纹 |
| 计划 | `build.modelPlan`、`build.taskPlan`、`build.testPlan`、`build.dependencyPlan` |
| 解码 | `build.decodeModel`、`build.decodeTestResults`、`build.decodeDiagnostics`、`build.decodeDependencies` |
| 同步 | `build.syncFingerprint`：监听文件的摘要，用来判断模型是否过期 |

几条横跨所有命令的规则：

- 每次调用都重新校验清单。清单有问题时返回 `{ status: "rejected" }`；只有请求本身格式错误才是 `invalid_request`。
- Core 不启动进程、不写文件。只有 `build.detect`、各 `decode*` 和 `build.syncFingerprint` 会在工作区内有界地读取文件，以及读取宿主分配的 `outputFile`。
- 代码在 `rust/lithe-core/src/build/`，在 `lib.rs` 里用私有的 `mod build;` 引入，没有新增 crate 根的 `pub` 项。模板解析与 `plugins::declarative` 共用 `parse_template_with`，不另写一份。

### 3. 对社区插件开放什么，封闭什么

这一节回答“社区插件作者怎么注入自己的构建工具”。原则是：**工具本身是开放的，Core 怎样解释声明是封闭的。**

插件可以自由描述（不需要改 Core）：

- **任何构建工具**：ID、标记文件、任务、选项、运行入口、测试过滤器、诊断正则、依赖命令都是数据。
- **可执行文件**：按偏好顺序列出候选，有四种：
  - `projectFile`：工程里的 Wrapper（例如 `gradlew`），可以要求某些文件存在。它一律被视为执行仓库代码。
  - `environment`：某个环境变量下的相对路径，例如 `MAVEN_HOME` 下的 `bin/mvn`。变量必须列在 `environmentInputs` 里，宿主只传这些变量。
  - `command`：在 `PATH` 上查找的裸命令名。
  - `runtime`：直接使用一个声明的运行时，例如 Go fixture 直接用 `go`。
- **运行时**：`java`、`node`、`go` 由宿主管理，只写 ID 和最低版本，按用户的运行时设置发现。Core 提供 Java 的 `-version`、Node 的 `--version`、Go 的 `version` 探测参数，宿主合并标准输出与错误输出再交回 Core 校验；Java 8 不支持 `--version`，且版本信息通常写到错误输出，不能据此误判为不可用。其他任何 ID 都由插件自己写可执行文件候选和版本探测，所以运行时列表是开放的。
- **自带逻辑**：插件附带的脚本（例如 Gradle 的 init script，即初始化脚本）可以直接输出规范格式，不必写选择器映射。规范格式有 `litheBuildModel`、`litheTestResults`、`litheDependencies`、`litheDiagnostics`。规范文档里的未知字段会被忽略，所以新脚本配旧宿主也能用。插件自带的常驻 Provider 进程也用这几种格式回复（第 9 节）。

固定词汇（要扩展就给对应能力加一个新版本，见[声明式插件按能力分版本](2026-10-17-plugin-capability-versions.md)）：

- 权限只新增一个 `process.build`；激活事件是 `onBuildSystem:<id>`。
- 模板变量和参数条件。
- 解码格式：静态模型读 `toml`；模型和依赖命令的输出用 `jsonStream`；测试报告用 `junitXml`，诊断用 `lineMatcher`；再加上上面四个规范格式。
- 映射规则和选择器（第 6 节）。
- `hostIntegration`（具名的宿主内置实现）：只有官方 `dev.lithe.*` 插件能声明，目前只有 `maven`。第三方声明会得到 `plugin.integration.unsupported`。

封闭这几项的原因是：两端宿主必须对同一份声明做出逐字相同的解释。如果允许插件自定义变量或解码器，未知的部分在某个宿主上会被静默忽略，同一个插件在两端会生成不同的命令行。

### 4. 模板和选项的规则

- 参数是模板字符串，或 `{ "value": …, "when": 条件 }`。条件有 `projectSelected`、`nestedProjectSelected`、`targetSelected`、`suiteSelected`、`caseSelected` 及对应的 `no…` 反义条件。
- 可能缺席的对象必须用条件保护。例如任务允许在工作区和目标两种作用范围运行时，`${target.name}` 必须写在 `targetSelected` 条件下，否则校验返回 `plugin.template.invalid`。
- **每个选项的参数在一条命令行里只出现一次。** 引用要么放在 `globalArguments`，要么放在命令自己的列表里；同一个列表内也只能引用一次，除非两处引用处在互斥条件下（一处 `targetSelected`，一处 `noTargetSelected`）。重复参数在不同工具里的含义不同，有的覆盖、有的累加、有的报错，Core 不去猜。
- 多选选项的保存值里有部分取值已经失效（例如某个 Maven Profile 被删掉了）时，Core 保留仍然有效的取值，并把选项 ID 列进 `dropped`，宿主据此改存生效值。全部取值失效时回落到默认值。
- 选项的生效值决定配置指纹 `optionFingerprint`，宿主用它判断旧结果是否过期。检测与模型生成的运行入口必须使用同一份模型选项集合过滤保存值，避免已删除的 Cargo feature 留在运行参数里、同次检测却产生不同指纹。文件和目录类选项的取值只能来自用户，插件只声明“这是一个文件选项”。
- 安装审查的命令身份必须包含会影响参数展开的选项字段：类型、默认值、分隔符和取值约束等。只比较参数模板会漏掉“默认初始化脚本换了”的更新；展示名称和选项标题不参与身份，以免单纯改文案也要求重新确认。

### 5. 识别与冲突

- `markers` 是文件名，含有其中之一的目录就是候选根。
- `nesting` 决定嵌套的候选怎样处理：`outermost` 把更深的候选并进外层实例（Gradle 构建、Maven reactor，即多模块聚合工程）；默认的 `separate` 让每个候选各自成为实例（Cargo 包）。
- 两个插件声明同一个构建系统 ID 时，`priority`（0～100，默认 50）高的胜出，相同时取插件 ID 较小的；落选者列在 `shadowed`。
- 一个清单无效不影响其他插件，它按传入顺序列在 `rejected` 里。
- 识别复用运行配置探测的同一次目录遍历（`crate::execution::scan`），因此会跳过同样的输出目录，例如 `target/`。
- Maven 曾计划用一种“由集成决定根”的专用嵌套方式，实现时删掉了。现在 Maven 用 `outermost`，reactor 里哪些目录是模块仍由集成解析 `<modules>`。

### 6. 模型来源与解码

- `static`：识别时直接读取 `toml` 清单，不启动进程，打开项目即可运行。Cargo fixture 读 `Cargo.toml`。清单是 JSON 或 YAML 的工具（`deno.json`、`package.json`）用插件脚本，走 `command` 来源。
- `command`：宿主运行模型命令，Core 解码输出。声明里的 `executesProjectCode`、`mayUseNetwork` 只用于展示；凡是选中 `projectFile` 候选，宿主一律按执行仓库代码处理，不采信插件的声明。Go fixture 用 `go list -json`（`jsonStream` 解码；`jsonStream` 也接受单个 JSON 文档），Gradle fixture 用 init script 输出 `litheBuildModel`。
- `provider`：插件自带的 Provider 进程回答，见第 9 节。
- `hostIntegration`：见第 8 节。

映射（`map`）只挑值：用选择器从解码后的文档取出工程（连同工程的目标和内容根）和选项取值。目标规则的 `fallback` 按标签分组：只有同标签的显式规则已经产出目标时才跳过回退，所以显式 `[[bin]]` 会抑制 `src/main.rs` 的隐式 application target，而显式 `[[test]]`/`[[example]]` 不会把它一起抑制；工程和内容根的回退仍是整组判断。选择器是 JSON Pointer 加少量扩展：`@key`、从文档根开始的 `$/…`、`*`、`where` 过滤、`fallback`、`whenFile`、字面值 `{ "value": … }` 和 `lastSegment` 变换。目标标签是字面列表；工程的父工程是包含它的最深一层工程，不能映射；依赖映射只产出平铺列表，依赖树来自 `litheDependencies`。选择器不提供控制流。

映射表达不了的部分由插件自己处理：插件脚本（或者工具加初始化脚本）输出 `litheBuildModel`、`litheDependencies`，或者由 Provider 回答。API 3 发布前按真实插件裁剪过一次（2026-10-18），去掉了没有 fixture 使用的部分：工程里的任务规则、`map` 顶层的目标和任务、`parent`、映射出来的标签、`parentDirectory` 变换、依赖的 `children`、静态模型的 `json` 和 `yaml`、命令输出的 `json`、`toml` 和 `yaml`，以及 `layout.generated`。原因是每条映射规则都是 Lithe 自己定义的语义，发布后两端宿主要长期逐字相同地支持；脚本里的逻辑则归插件所有，插件可以自己演进。以后真有插件需要、又不适合放在插件里的规则，作为 `buildSystems` 的新版本加回来，并补 fixture。

模型里的工程、目标、任务和内容根在规范化后必须位于实例根内，绝对路径也遵守同一边界；其他路径一律丢弃。比如实例根是 `services/api` 时，`services/api/src` 合法，`services/web` 和 `services/api-extra` 即使位于同一工作区也要拒绝。选择器的非法内容根不算命中，不能阻止后面的合法 fallback。规范格式里内容根的 `project` 只指明归属，`path` 同样相对实例根；曾经按工程目录再拼一次，子工程会得到 `app/app/src/main/java`。读取静态模型、报告和同步监视文件前，还要校验符号链接最终指向工作区内：允许 `workspace/alias → workspace/data`，拒绝 `workspace/model.json → /outside/model.json`；否则模型和指纹会泄露外部文件内容。解码诊断和测试结果时同样校验：这两个路径会出现在 Build Output 里并可点击打开，所以工作区内的符号链接保留它被报告时的相对路径，最终指向工作区外的路径直接丢弃；导航这一层再校验一次，防止路径在解码之后被替换。宿主显式传入的 `outputFile` 保留读取工作区外临时输出的能力。输出不符合解码格式时返回 `plugin.build.invalidOutput`，不静默返回空列表。

### 7. 测试

- `test.scopes` 说明测试能在哪一层运行。`targetTags` 进一步限定目标：例如 Cargo 只在带 `test` 标签的目标上运行 `cargo test --test`，在其他目标上请求测试会得到 `plugin.build.invalidSelection`。`targetTags` 需要声明目标作用范围。
- `filters` 声明能选中的 `suite`、`case`；`${test.case:regex}` 给需要正则的工具（例如 `go test -run`）提供转义后的名字。声明了筛选不代表每种组合都能表达：Maven 的 `-Dtest=Suite#case`、Gradle 的 `--tests Suite.case` 都只能在 suite 内选 case。`build.testPlan` 要求请求的 suite/case 确实经由条件成立的模板进入命令行，否则返回 `plugin.build.invalidSelection`，而不是静默扩大成全量测试；Cargo、Go 的独立 case 不受影响。这条规则按模板求值判断，不需要插件额外声明依赖关系。
- `results` 是 `junitXml` 或 `litheTestResults` 的报告 glob，相对工程目录。工作区范围的运行没有选中工程，宿主随请求传入当前模型的 `projects`，Core 在实例根和每个工程目录下各匹配一次（与 `build.syncFingerprint` 相同的输入方式）；否则子工程失败的报告会被漏掉，解码成零用例、`success: true`。`notBeforeMillis` 让 Core 忽略本次运行之前留下的旧报告。同一个用例执行多次时，合并为最严重的状态。

### 8. Maven 过渡：`hostIntegration: maven`

`hostIntegration` 是迁移期的例外，不是扩展点。Lithe 的原则是插件逻辑跑在插件自己的进程里、不内置进核心；`maven` 集成让 Maven 的解析代码暂时留在 Core，终点是移进 Maven 插件自带的 Provider 进程，届时从契约里删除 `hostIntegration`。

Maven 已有成熟的 Rust 实现，有三件事声明表达不了，所以迁移期保留为集成：

- reactor 模型，复用 `project::maven` 的扫描；
- 依赖树 goal 及其文本格式；
- Surefire/Failsafe 结果。

其余部分（可执行文件、选项、生命周期任务、诊断正则）已写成 Maven fixture 里的声明。

集成生成的命令行与声明的命令遵守同一顺序：全局参数，然后是全局参数没有放置的选项参数，最后是集成自己的参数。`build_systems` 测试证明 `build.taskPlan` 的结果与内置 `maven_arguments` 逐字一致。`project::maven` 保持原有入口；共享扫描器在读取根 POM 和模块 POM 前校验实际路径仍位于工作区或 reactor 内，避免适配器沿链接读取外部文件。

### 9. 进程型 Provider：与语言服务器同一种进程

Lithe 的插件逻辑跑在插件自己的进程里。声明和规范格式解决不了的构建工具（Gradle Tooling API；Mix 的工程只能在 BEAM 里读到），由插件自带的 Provider 进程回答，而不是在 Core 里加专用代码。Provider 不是新的进程类型，它就是语言服务器那种 LSP 基础协议进程，只多回答两个方法。

- **共用启动字段和校验。** `languageServers[]` 和 `buildSystems[].provider` 的启动字段（`launch`、`arguments`、`validationArguments`、`runtimeDependencies`、`initializationOptions`）是同一个 Rust 类型 `ServerProcess`（`plugins/declarative.rs`，两处都用 `#[serde(flatten)]` 引入）和同一个 schema 定义 `$defs/serverProcess`。包内路径、运行时、启动模板和设置引用的校验只写一次，错误信息按角色称为 language server 或 build provider。
- **两种写法，按 `languageServer` 键区分。** 共享写法 `{languageServer: <languageID>, executesProjectCode, mayUseNetwork}` 指向同一插件里有语言服务器的语言，宿主把构建请求发给那个会话。自有进程写法是启动字段加两个标志，需要 `languageServer.launch` 权限：用户同意的是“插件启动自己的常驻进程”，与进程回答哪些方法无关。两种写法混写会因未知字段被拒绝。
- **来源。** `model.source` 和 `dependencies.source` 可以写 `provider`；依赖的作用范围只能是 `workspace` 和 `project`。声明了 Provider 却没有来源使用它，或者来源写了 `provider` 却没有声明，都是 `plugin.manifest.invalid`。
- **启动计划不新增命令。** `plugins.declarative.languageServerLaunchPlan` 必须且只能给出 `languageID` 或 `buildSystemID` 之一，都没有或都有是 `invalid_request`。按构建系统选中时，结果多一个 `buildProvider: {buildSystemID, executesProjectCode, mayUseNetwork, languageServer?}`。共享写法直接返回那个语言服务器的计划，并用 `languageServer` 告诉宿主复用已有会话，不要再启动第二个进程。
- **计划与解码。** `provider` 来源的 `build.modelPlan`、`build.dependencyPlan` 不返回 argv，而是 `provider: {method, params}`；`method` 是 `lithe/build/model` 或 `lithe/build/dependencies`，`params` 是 `{buildSystemID, root, options（生效值）, optionArguments, environment}`，依赖请求再加 `project: {name, path} | null`。模型请求总是覆盖整个实例。宿主把回复原样作为 `result` 交给 `build.decodeModel`、`build.decodeDependencies`，Core 用规范格式的解码器校验，超过输出上限是 `plugin.build.invalidOutput`。所以 ID、路径校验和运行入口推导仍然只在 Core 里做。
- **识别不启动进程。** `build.detect` 对 `provider` 来源只报告 `modelSource: "provider"`，不附带模型。
- **安装审查。** 自有进程列为 `packagedBuildProvider`、`systemBuildProvider` 或 `runtimeBuildProvider`，带 `buildSystemID` 和两个标志，它需要的运行时另列 `runtime` 条目；共享写法写进该构建系统 `buildSystem` 条目的 `provider` 字段，因为它改变了语言服务器被要求做的事。任何一项变化都要用户重新确认。

- **协商与请求在 Core 的 LSP 客户端里。** `initialize` 在 `capabilities.experimental.litheBuild` 下发 `{"versions": [1]}`（`lsp/interface/build_provider.rs`），Provider 回答 `{"version": 1}` 后会话才记录 `litheBuild` 能力。宿主用 `lsp.buildRequest {sessionId, method, params, timeoutMilliseconds}` 发请求，Core 只接受协商出的版本里的两个方法；没有协商成功的会话直接返回失败，所以共享写法里不认识这套协议的语言服务器不会收到 `lithe/build/*`。结果和其他 LSP 操作一样经 `requestCompleted` 回到宿主。

同一个会话还可以协商 `litheFunctions`，提供插件私有的函数；它与 `litheBuild` 互不依赖，也不能代替类型化的领域方法，见[插件函数契约与能力方向](2026-10-20-plugin-function-contract.md)。

还没有实现：`lithe/build/execute`（Provider 自己执行任务并流式汇报进度和测试事件），见提案第 4 节。测试结果目前仍来自声明的报告解码器或 `hostIntegration`，没有 `provider` 来源。

### 10. macOS 宿主适配层

macOS 宿主接受级别 3，并在 `PluginManifest.hostCapabilities` 里声明 `buildSystems: [1]`，插件市场因此在 macOS 列出构建插件。工作区识别出某个构建系统的实例时，右侧出现这个构建系统自己的工具窗口（第 11 节），任务和测试的输出、诊断和测试结果显示在共用的 Build Output 里。

代码按“谁负责什么”分四层，任何一层都不认识具体的构建系统：

| 层 | 位置 | 负责 |
| --- | --- | --- |
| Core 调用 | `macos/Sources/Lithe/Core/Rust/RustBuildSystemOperations.swift` | 把 13 个 `build.*` 命令包成 `BuildSystemPlanning`；契约类型在 `LitheCoreContracts/Execution/BuildSystemContracts.swift` |
| 平台适配器（Platform Adapter，封装 macOS 系统调用的类） | `macos/Sources/Lithe/Platform/MacOS/Build/` | `MacBuildToolResolver` 按 Core 的候选顺序找可执行文件、探测版本、给宿主管理的运行时设置环境；`MacBuildCommandRunner` 在独立进程组里启动命令，登记进程账本，负责取消、期限和输出上限；`MacBuildOptionsStore` 保存选项；`MacBuildSystemStateLocator` 在插件状态目录下分配 `${workspaceStateDir}` 和 `${outputFile}` |
| Provider 进程 | `macos/Sources/Lithe/Platform/MacOS/Build/MacBuildProviderSessions.swift` | 实现 `BuildProviderRequesting`：按需启动 Provider、复用或替换已退出的进程、按目标停止；启动计划由 `MacPluginLanguageServerLaunchResolver.resolveBuildProvider` 解析，进程会话复用 `LanguageServerRuntimeSession` |
| 编排 | `macos/Sources/LitheExecutionModule/Services/BuildSystemService.swift` | 识别、加载模型、任务、测试、依赖、选项和过期提示，只负责按顺序调用上面两层 |
| 界面 | `macos/Sources/Lithe/Views/Workbench/BuildSystemToolWindowRegistration.swift`、`macos/Sources/Lithe/Views/Run/BuildSystemToolWindowView.swift`、`BuildOutputView.swift` | 按声明注册的工具窗口、窗口内容和输出区 |

几条宿主规则和它们的原因：

- **没有模型时不能收集子工程报告。** 测试报告 glob 是相对工程目录的；没有模型就不知道子工程目录，子工程的失败报告会被漏掉，解码成零用例和 `success: true`。所以声明了模型、又声明了测试报告解码的工作区级“全部测试”要求模型已加载且没有过期标记，服务层在生成计划后拒绝并提示先加载或重新加载；判断不能依赖请求里的 `projects` 是否为空，因为界面会把旧模型的工程列表原样传进来。没有声明模型的插件，或者计划不需要解码报告时，工作区测试照常允许。
- **什么时候启动进程。** 打开工作区时只跑 `build.detect`，`static` 和 `hostIntegration` 来源的模型随识别一起读出，不启动进程。macOS 目前没有工作区信任机制，所以 `command` 来源的模型和工程里的 Wrapper 只在用户点击“加载模型”或运行任务后启动。项目内的可执行文件（`projectFile` 候选）不做版本探测，因为探测本身就是在执行仓库代码。
- **取消后谁能写回。** 模型和依赖加载的任务槽保存独立操作 ID。完成时同时检查工作区代次、当前槽的 ID 和取消状态，只有仍持有槽的任务才能清槽、更新模型或依赖及活动状态；不能只看工作区代次，否则重复加载时旧任务的取消回调会清掉新任务。任务和测试的运行也携带运行 ID 与工作区代次：诊断和测试结果的解码在独立任务里完成，写回前必须再检查身份和取消状态，否则停止、启动新运行或切换工作区后，旧解码会覆盖新状态。流式输出同样带归属：每段输出在追加前检查启动它的运行或加载任务是否仍是当前任务，因为命令取消后管道还可能排空出尾部文本。模型命令依赖当前选项和构建文件，加载开始时要记录选项指纹和文件变化代次；结果返回时若任一已经变化，模型仍可发布但必须标记为需要重新加载，不能清除过期标记。文件代次对宿主上报的每个工作区变化都递增，因为首次加载时模型还没有列出子工程的监听文件，按旧监听列表会漏掉这些变化。依赖加载也要记录选项指纹和文件变化代次；返回时任一已变化就显示“需要重新加载”，不能把旧 profile 或旧 POM 的依赖树当成新配置的结果。停止、重置和停用插件后重新加载也遵守同一规则；每个旧任务仍负责清理自己的临时输出文件。
- **什么时候重新识别。** 只有 `sync.watch` 里的文件变化才会重新识别，连续保存在 500 毫秒内合并成一次。已加载的 `command` 模型不会被自动重跑：指纹变了只标记“需要重新加载”，等用户决定。
- **检测和加载怎么合并。** 检测在启动时取一份条目快照，完成时代次和加载 UUID 只能证明工作区没换、任务没被替换，不能证明期间没有新的模型或依赖结果发布。每个条目分别记录模型修订号和依赖修订号：模型加载成功、失败或取消时递增模型修订号，依赖加载结束时递增依赖修订号。检测提交时比较启动快照里的修订号：模型修订号变了，就保留当前的模型、选项、同步和依赖状态；只有依赖修订号变了，就只保留依赖树，模型仍采用这次检测新读到的结果。两个修订号都没变时必须整体采用检测结果，否则正常的静态模型刷新会被旧模型覆盖。实例 ID 只由构建系统 ID 和根目录组成，两个插件声明同一 ID 时会重复；模型和依赖缓存必须同时校验 `pluginID`，插件接管后从 `notLoaded` 开始，不能沿用上一个插件的缓存。
- **输出怎么交给 Core。** 模型和依赖命令的 stdout 单独捕获后交给 Core 解码（计划写 `outputFile` 时读文件），stderr 照常进入 Build Output，所以工具打印的警告不会破坏要解码的文档。任务和测试的完整输出交给诊断解码。
- **选项存在哪里。** 按“工作区 + 构建系统 ID”保存，与 `build.detect` 的 `options` 形状一致。Core 在 `dropped` 里报出的选项改存它的生效值，用户的其他选择因此保留；检测和模型加载后也要处理一次，不能等用户再改选项。任务、测试、模型和依赖计划按当前模型重新解析选项，只把 Core 仍接受的生效值交给 Core，否则模型删掉的 Cargo feature 会继续出现在命令行里。选项按工作区 + 构建系统共享，但模型取值属于单个实例：清理存储前要让所有实例各解析一次，只有没有任何实例接受的值才删除，单个实例仍接受的值保留，由各实例计划自己过滤。选项行对 `allowCustom` 的单选和多选提供自定义值输入：单选替换当前值，多选追加或从菜单里移除已选的自定义值；值仍交给 Core 校验并保存。用户显式清空的多选值 `[]` 和空文本 `""` 都是有效选择，不能当作“没有值”删除，否则非空默认值会在下一次检测后回来。Core 描述选项时必须把用户选中的空值原样返回，不能因为有默认值就返回 `null` 或默认值；界面提交空文本时也提交空字符串，恢复默认由重置按钮负责。为区别“当前实例明确清空”与“共享数组里的值只属于兄弟实例”，宿主额外按工作区、构建系统 ID 和实例相对根保存空多选标记。标记只把仍声明为多选的选项覆盖为 `[]`；共享数组仍保存其他实例的选择，清理它时也只用共享值解析，不能让空标记删掉兄弟值。检测后的选项、同步指纹、所有计划和语言服务器导入都应用同一空覆盖；重开工作区保留，当前实例重新非空编辑清自己的标记，共享编辑或重置清该选项的全部实例标记。这个标记由现有平台偏好存储持有，与用户构建设置同寿命，不新增缓存目录、不写安装包，不影响签名或 Sparkle delta，也不能跨 worktree 复制为构建资源；其他非空选项仍维持共享存储。
- **诊断和测试路径怎么打开。** Core 解码时已经丢弃最终指向工作区外的路径；Build Output 在导航前仍用 `BuildOutputSourcePath` 重新解析真实路径，因为解码和点击之间工作区内容可能变化。工作区内的符号链接保留被报告时的相对路径，越出工作区的链接不打开。输出正文里的链接（包括绝对路径）也走同一入口，只能打开工作区内的文件；正文里的相对路径按所有实际写入该输出的命令所在实例根解析，而不是工作区根，否则嵌套实例的 `src/main/java/...` 会被解析到另一个工程；同名相对路径在多个根下都存在时视为歧义，不生成链接，宁可没有链接也不打开另一个工程的文件。
- **自定义运行时可以放在项目里。** 运行时候选支持 `projectFile`，例如项目虚拟环境里的 Python；它按项目代码处理，不做版本探测（探测就是执行仓库代码），只检查文件可执行和 `requires` 文件存在。只支持 `command` 或 `environment` 时，Core 允许的候选会在 macOS 上不可用。
- **可写文件放在哪里。** 输出文件和状态目录都在插件状态目录下，读完就删；不写 app bundle、不写插件包，符合运行时只读规则。
- **插件变化。** 启用、停用或卸载插件后，`pluginsChanged()` 先停止该插件已经启动的命令和 Provider 进程，再重新识别，它的实例随即从工具窗口消失。可用插件列表在启动时确定，新安装的插件和其他声明式插件一样，重启后才出现。
- **Provider 进程彼此隔离。** 进程按“插件 ID + 构建系统 ID + 工作区”一一对应（`BuildProviderTarget`），两个插件永远不共用一个进程。每个进程只通过自己的 stdio 与宿主说 JSON-RPC 2.0，宿主不在进程之间转发消息，所以一个插件够不到另一个插件的 Provider。可写状态放在该插件的构建系统状态目录（`<插件状态目录>/build-systems/<buildSystemID>`），设置也只读该插件自己的；插件包和 app bundle 只读。能跨进程共享的只有宿主统一读取的只读信息，例如工作区路径和 Core 解析好的计划。共享写法（`buildProvider.languageServer`）只允许复用**同一个插件**的语言服务器会话：`LanguageToolingSessionManager.requestBuildProvider` 在发送前核对该语言运行时的来源插件 ID，不同插件时拒绝。这是进程和通信层面的隔离，不是操作系统沙盒，Provider 仍以用户权限运行。
- **Provider 什么时候启动、什么时候停止。** 和 `command` 模型一样，只在用户点击“加载模型”“重新加载”或加载依赖时启动；`executesProjectCode`、`mayUseNetwork` 随请求带到宿主，安装时已由用户确认。进程常驻到它的目标被丢弃：切换或关闭工作区、项目窗口关闭或执行模块停用（`ExecutionFeatureGraph.stop()` → `BuildSystemService.stop()`；`reset` 也走 `stop`）、停用插件（`pluginsChanged()`）。服务的 `stop` 是统一回收入口，必须连同已就绪和初始化中的 Provider 一起停止；不能只在 `reset` 回收，否则直接关闭项目窗口会留下进程与会话轮询。安装、同版本重装、回滚或卸载会替换或移走插件包，`MacPluginManager` 在动包之前调用 `beforePackageReplacement`，组合根在这里按插件 ID 直接停止该插件全部 Provider（`MacBuildProviderSessions.stopProviders(ofPlugin:)`）；不靠 `BuildSystemService` 的插件列表比较，因为那份列表是启动时的快照，看不到包已被替换。启动参数会展开插件设置（例如 `-Xmx${setting:providerHeapMB}m`），所以每个进程记下启动时的设置值，下一次请求发现当前设置不同就停掉旧进程按新值重启；“Restart Language Servers”不负责独立的 Provider。进程退出或崩溃后，下一次请求重新启动；同一目标的并发请求等待同一次启动。共享写法的语言模块还没激活时，宿主提示用户先打开该语言的文件，而不是另起一个进程。
- **Provider 入口在安装时校验。** `MacPluginPackageStore.validateLaunchResources` 除了语言服务器，还对每个声明了 `provider` 的构建系统（`DeclarativeBuildSystem.declaresProvider`）用 Core 展开一次启动计划（状态目录用不会创建的临时路径，设置用默认值），要求 `requiredPackagePaths` 都在包内且不经过符号链接，包内可执行文件和打包运行时是普通可执行文件；不满足时安装失败（`buildProviderLaunchMissing`），而不是等到第一次“加载模型”才报错。共享写法跟着对应语言服务器校验。启动时 `MacPluginLanguageServerLaunchResolver.resolveBuildProvider` 仍做同样的检查，防止安装后包被改动。
- **可执行文件怎么找。** 包内文件直接启动；`command` 和 `runtime` 启动方式合成一份 `BuildInvocation`，交给构建命令同一个 `MacBuildToolResolver`，所以 Provider 看到的运行时、`PATH` 和最低版本检查与构建命令一致。

正确做法：Gradle 插件想在工程节点上多一个菜单项，就在清单里声明一个作用范围包含 `project` 的任务。宿主按作用范围生成菜单，不需要改 Swift 代码。

不要这样做：在 `BuildSystemService` 或视图里写 `if entry.instance.buildSystemID == "maven"`；在宿主里给 argv 补参数、自己解析工具输出；从 `Bundle.main.resourceURL` 推导输出文件的位置。

### 11. 展示字段：每个构建系统一个窗口，照抄 Maven 窗口

2026-10-18 用户决定，内置 Maven 窗口不再由宿主写死，改为随插件出现：每个启用的构建系统各有一个工具窗口。外壳（停靠、标题、活动栏、顺序、显隐、布局、生命周期）沿用现有工具窗口贡献的注入方式，只是从写死的 `execution.maven` 改为按插件声明注册。窗口内容照抄现有 `MavenView` 的结构，包括工具栏开关、Profiles 勾选树、分组任务和依赖，不重新设计。Gradle 用同一个 SwiftUI 原生视图，任务分组模仿 IDEA 的 `Tasks › build`。插件界面优先原生实现；不禁止需要时采用网页，但网页只是独立可选能力，不是 Maven、Gradle 的界面方案或交付前提，见[插件自带网页界面](2026-10-18-plugin-web-content-in-host-windows.md)。

照抄的视图不能认 Maven 这个名字，所以清单加了三个只管展示的字段，Core 校验它们，但它们不进入任何计划：

- `buildSystems[].icon`：窗口和活动栏图标，沿用 UI 图标的校验。
- `options[].presentation`：`toolbar` 把带 `icon` 的布尔选项放上工具栏（离线、跳过测试），`tree` 把多选选项放到树顶部作为勾选节点（Maven Profiles）。
- 任务的 `category`：1～4 级标题。模板上的值是模型任务的默认值，`litheBuildModel` 里的模型任务可以自带（字符串数组）；超过四级或出现空标题时回退到模板的值，任务不会因此丢失。

为什么不复用 `group`：`group` 是固定的七类语义枚举，运行配置和默认动作依赖它，表达不了 `Plugins › compiler` 或 Gradle 的任意任务组。`category` 只描述放在哪里，两者分开以后，改展示不会改变语义。

正确做法：Maven 插件给 `profiles` 写 `presentation: "tree"`，给 `offline` 写 `toolbar` 和图标；扩展输出的插件目标带 `category: ["Plugins", "compiler"]`。

不要这样做：在视图里写 `if buildSystemID == "maven" { showProfiles() }`，或者用 `properties.group` 这类约定键私下决定分组。

宿主怎样落地（2026-10-18）：

- **窗口从声明推导，不由插件写 ID。** `DeclarativeBuildSystem.contributions(pluginID:order:)` 为每个构建系统生成一个右侧工具窗口和一条命令面板命令，ID 是 `<pluginID>.build-systems:<buildSystemID>`。插件声明的 UI ID 不允许含 `:`，所以不会和插件自己的窗口冲突；标题是 `displayName`，图标是 `icon`。贡献的 `visibility` 带上插件 ID 和构建系统 ID，`buildSystemRegistration` 只读这两个键，不认识任何具体名字。
- **出现与消失。** 2026-10-19 用户决定，窗口和命令不再依赖识别结果：只要插件已启用并且打开了工作区，活动栏按钮和命令面板项就显示；工作区没有该构建系统的实例时，窗口内显示“此工作区未检测到 %@ 工程”。原因是只装插件不见图标时，用户无法判断插件是否生效。停用或卸载插件后贡献随插件移除，窗口随之消失。窗口的切换动作在有工作区时就可用，这样保存过的布局能在识别完成前恢复；布局沿用工具窗口的通用持久化。恢复和打开都先激活贡献所属的插件模块，再激活负责识别的 execution 模块，不能只激活后者而跳过插件生命周期。激活期间命令面板项显示 pending 并禁用，活动栏按钮仍允许取消。命令面板标题是“切换 %@”，只本地化动词，构建系统名称原样显示。
- **共享 Build 窗口删除，不保留为兜底。** 每个构建系统都有窗口以后，共享窗口只会把同一棵树再列一遍；没有声明展示字段的构建系统也能在自己的窗口里按 `group` 分组显示，不需要兜底。识别问题（`issues`）以横幅显示在每个构建系统窗口顶部。Build Output 仍然共用。
- **窗口内容。** 工具栏依次是运行/停止所选任务、需要参数的任务（`requiresUserArguments`）、刷新、`toolbar` 选项开关、全部折叠和其余选项的下拉面板。同一构建系统有多个实例时，原生根目录选择器决定工具栏、树和下拉面板正在编辑哪个实例；候选和生效值必须来自所选实例，不能取首实例代表全部，否则嵌套 Cargo 工程的独有 feature 无法选择。修改一个实例的多选值时，`setInstanceOption` 保留其他实例独有的已选值，再交给共享存储和 Core 校验；显式清空额外保存当前实例的空标记，否则只剩兄弟值时 Core 会认为全部无效并回落非空默认值。恢复默认删除完整的共享覆盖和该选项所有实例的空标记。树的顶部是 `tree` 选项的勾选节点（`allowCustom` 时可以添加值，用户改过时可以恢复默认），然后是实例：实例根上只有一个根工程时直接显示这个工程，否则显示实例节点并在下面列出根工程。每个节点下依次是按 `category` 分级的任务（没有 `category` 时按 `group` 归类）、运行测试、目标、依赖和子工程。实例根上的任务、测试和依赖在声明允许时优先使用 `workspace` 作用范围，这样根构建覆盖所有工程；只接受 `project` 的任务仍携带根工程，只接受 `target` 的参数任务保留目标与标签约束。工具栏和节点菜单共用同一套作用范围选择，不能先把根工程丢掉再交给 Core。依赖在第一次展开时加载。
- **视图状态不能跨模型沿用。** 模型、实例列表或工作区变化后清除所选任务、未提交的参数弹窗和选项输入弹窗，避免运行旧模型中的请求。实例选择消失后回到首个有效实例，自定义输入还要校验打开时的实例身份，防止旧弹窗改到新实例。任务分组节点按每级标题的 UTF-8 长度编码身份；标题即使含有分隔符，也不能和另一条分组路径共用折叠状态。
- **已删除。** `MavenView`、`MavenBuildOutputView`、`MavenDependencyLocalization`、`BuildSystemsView`，`execution.maven`、`execution.maven.output`、`execution.build` 贡献，`toggle-maven` 命令和对应的 `ToolWindow` 常量。旧布局里的这些 ID 和其他未知贡献一样被忽略；`ToolWindow.restoredID` 改为显式映射旧名字，不再依赖 `allCases` 的顺序。

还留着的 Maven 宿主代码：`MavenService`（以及 `MavenFeatureModel`）仍负责未声明插件导入配置时的兼容设置、模块运行/调试的启动上下文，以及 `lithe_maven_*` Agent 工具。Agent 执行的 Maven 目标不再有专门的输出窗口，Agent 通过 `lithe_operation_output` 读取输出。`MavenResolutionProblems`（JDT 报告的 `pom.xml` 问题）仍供编辑器诊断使用，但不再显示在构建窗口里。通用构建窗口读取的依赖也尚未成为 Java 依赖侧栏的补充来源。

macOS 已接入插件选项到 JDT 的通用桥（第 12 节）：检测、选项修改和模型加载完成后，Core 归一化每个实例的生效选项为 `mavenContext` / `javaGradle`，Swift 只负责等待、转发和过期保护，并通过唯一的发布回调更新同一工作区的 Java 会话。停用插件的清除资格归属实际带过 Maven 输入的活动会话，不用工作区内“曾发布过”的全局标记。运行/调试与 Agent 工具仍使用原来的 Maven 业务，因此还不能删除 `MavenService`。

### 12. 语言服务器导入：`languageImport`

JDT LS 自己导入 Maven 和 Gradle 工程。导入用的 Profile、settings 和缓存必须和用户给构建工具选的一致，否则编辑器解析出来的依赖和构建不同。以前这些值来自内置 Maven 窗口（`MavenService`），而社区插件没有 `hostIntegration`，Core 不能按插件名字认出 Maven。

所以 2026-10-18 给 `buildSystems` v1 加了可选的 `languageImport`：`kind` 写插件对应的导入（`maven` 或 `gradle`），`options` 把导入设置映射到插件自己的选项 ID。`maven` 有 `profiles`（多选）、`settingsFile`（文件）和 `localRepository`（目录）；`gradle` 有 `offline`（布尔）和 `gradleUserHome`（目录）。校验要求映射的选项存在且类型匹配。`build.languageImport` 按用户存储的值解析选项，返回 `lsp.startServer` 已经接受的 `mavenContext` 或 `javaGradle`。宿主只做转发，不认插件。

Gradle 的 `offline` 和 `userHome` 是用户自己选的值，不是猜测，所以和 #1302 “不猜构建脚本里的设置”不冲突：没有目录值时不发送 `userHome`，`offline` 按 Core 返回的生效布尔值传递。这两个值只在会话启动时生效；Maven 仍可通过 `lsp.updateMavenConfiguration` 热更新。

macOS 接入规则（2026-10-18）：

- `BuildSystemService` 在无进程检测后，用当前模型接受的有效选项调用 `build.languageImport`。只按返回的 `kind` 转发，不按插件或构建系统 ID 判断。Maven 安装路径来自 `MacBuildToolResolver.languageImportExecutable` 的被动发现，不执行版本探测、Wrapper 或运行时探测；找不到工具仍可使用 JDT 的默认安装设置。
- 一个 JDT 会话可同时带一个 Maven 和一个 Gradle 输入。检测到多个相同种类的实例时，先选工作区根，再选最浅的根，最后按路径和稳定 ID 排序；不合并不同 reactor 的 Profiles 或机器路径。没有对应插件输入时保留原 Maven 设置兼容路径；`MavenService` 仍是 Run/Debug/Agent 业务的现有提供者。
- 打开项目、编辑器同步、Run/Debug、测试发现、Java 入口点与维护操作在启动前都受同一份准备结果约束。维护入口先结束模块激活和插件注册，再等待导入；首次启动在 Java 运行时准备完成后还要重新等待当前结果，因为此前已经准备好的配置可能在挂起期间失效。最后一次等待结束后直接调用同步启动，不能在二者之间再插入异步工作。入口携带包含重开代次的 `WorkspaceIdentity`，每个异步边界后重查并检查取消；同步启动入口在配置尚未准备好时拒绝启动，不能借旧 Maven 上下文绕过等待。
- 检测、选项或插件变化使导入结果失效并重新计算。命令模型加载后可能收窄可选值，因此发布模型和生效选项后也要重新归一化；受监听文件变化影响时，立即清除旧输入并取消旧检测，再沿用 500 毫秒合并等待重算，等待期间不能读取保存前的配置。直接发起的检测会取消尚未到期的合并任务，避免迟到的重复检测再次清空刚准备好的配置。完成时同时校验工作区代次、检测 UUID 和取消状态，再通知同一工作区的 Java 会话；Maven 优先原地更新，Gradle 等下次会话启动。若运行中的会话拒绝 Maven 更新（例如它启动时没有 Maven 输入），调用现有 `reloadJavaWorkspace` 恢复，不能只留下警告。Java 准备协调器串行持有这项恢复：新发布先取消并等待旧恢复结束清理，再应用最新配置；旧恢复取消了自己创建的会话时，新发布继续承担重启，不能把此时的 `noSession` 当成无需处理。工作区替换、关闭、停用 Java 或会话关闭会取消恢复；包含同路径重开的代次检查阻止旧任务启动新会话。等待者有 30 秒期限，各自取消只释放自己的 continuation；停止或重置取消所有等待者，旧检测不能清除新检测或更新新工作区。
- 停用或移除 Maven 构建插件后，没有插件或兼容输入的活动会话也必须清除旧 Profiles、settings、仓库和工具路径。会话管理器记录启动时实际传入的 Maven 上下文，仅向带过 Maven 输入的同一会话发送空配置；纯 Gradle 会话首次启动仍传 `nil`，不能为了将来清除而给所有 Java 会话注入空 Maven 输入。停止或清除会话时同时释放记录，重开后的会话不能继承旧配置的清除资格。
- 这条通路不创建文件或缓存。JDT 的状态和 settings 副本仍由现有平台可写缓存和 Core 管理，不写 app bundle 或插件包；不会改变签名或 Sparkle delta 的发行基线。

回归覆盖：`languageImportMapsPluginOptionIDsWithoutBuildSystemNameAssumptions` 验证 Core 的两类结果解码；`languageImportPublishesTheSameEffectiveOptionsAsBuildPlansAndClearsDisabledPlugins` 验证发布值与构建计划一致、选项重发、插件停用的空快照及重置后的旧工作区拒绝；`languageImportUsesEffectiveOptionsAndRefreshesAfterSelection`、`languageImportWaiterCancellationDoesNotCancelSharedDetection`、`stoppingServiceFinishesARegisteredLanguageImportWaiter`、`replacedWorkspaceDoesNotPublishItsPendingLanguageImport` 验证选项、注册后的共享等待取消、停止与工作区替换；`watchedFilesInvalidateLanguageImportBeforeDebouncedDetection` 用注入的有界事件控制合并等待，确认旧配置立即失效，等待者只收到重新计算的值；`commandModelRecomputesLanguageImportWithItsAcceptedOptions` 验证模型收窄选项后会更新导入输入；`pluginImportReachesJavaStartupAndMavenHotUpdateWithoutLegacyFallback` 和 `pendingPluginImportCannotStartJavaWithLegacyContext` 验证启动及热更新；`removingPluginMavenImportClearsOnlySessionsThatHadMavenInputs` 验证清除旧输入、纯 Gradle 启动以及停止后清除记录；`JavaLanguageServerRuntimeTests` 的 `startupRechecksImportInvalidatedDuringRuntimePreparation` 用有界事件暂停运行时准备并使导入失效，确认启动会等到最新输入；`startupImportWaitRejectsCancellationAndReopenedWorkspace` 验证最终等待的取消和同路径重开；`pluginMavenImportRestartsASessionStartedWithoutMavenInputs` 验证拒绝热更新时恢复重启且后续变更仍原地更新；`newerPluginImportJoinsCancelledRecoveryBeforeRestarting` 验证新选项等待旧恢复清理并最终启动最新配置；`pluginImportRecoveryDoesNotStartAfterCancellationOrWorkspaceReopen` 验证恢复准备期间的取消和代次。`languageImportDiscoversWrapperWithoutExecutingItOrRuntimeProbes` 验证被动发现不执行工具。真实 JDT 导入验收仍待完成，矩阵保持 `pending`。

正确做法：Maven 插件写 `"languageImport": { "kind": "maven", "options": { "profiles": "profiles", "settingsFile": "settingsFile", "localRepository": "localRepository" } }`，宿主在选项变化后调用 `build.languageImport` 并把 `mavenContext` 交给 `lsp.updateMavenConfiguration`。

不要这样做：宿主按 `buildSystemID == "maven"` 或插件 ID 拼 Maven 上下文，或者从选项的 `arguments` 反推 `-P`、`-s`。

### 13. 还没有开放给用户的部分

- Windows 宿主还不发送 `hostCapabilities`，不会列出级别 3 的版本，也没有 Build 工具窗口。
- Windows 宿主还不会启动 Provider，也不声明 `buildProviders`。任一 `buildSystems[].provider` 都要求 `buildProviders: 1`，包括共享语言服务器；不要为了让插件可安装而从 `requires` 省去它，那会因能力未列全被拒绝。
- Provider 进程没有操作系统级沙盒（例如 `sandbox-exec` 或 App Sandbox 子进程），隔离只到进程和通信通道这一层；需要时作为后续工作单独设计。
- 构建模型里的运行入口（`run`）还没有接入 macOS 的运行配置。
- `runConfig.generate` 还没有接入构建模型。Cargo fixture 只证明了它产出的运行入口与内置探测器逐字一致，包括 `cargo.binary:<路径>` 这类 ID，迁移时用户的覆盖配置不会脱钩。

### 正确做法

- 社区作者支持 Deno：`detection.markers` 写 `deno.json`；插件附带一个读 `deno.json` 的脚本（例如 `model.ts`），`model` 用 `command` 来源，参数写 `run --allow-read ${pluginDir}/model.ts`，脚本把 `tasks` 写成 `litheBuildModel` 里的任务；再给 `build-plans.json` 补一条标准答案。Core 和宿主都不改。
- 某个 Gradle 插件注入了新的运行任务：插件更新 init script，让它把任务写进 `litheBuildModel`，并标上 `execution: "service"`。用户刷新模型后就能看到，Lithe 不需要发版。
- 构建工具需要一个宿主不管理的运行时（例如 `dotnet`）：在 `runtimeDependencies` 里写这个 ID、它的可执行文件候选和版本探测。
- Gradle 插件想用 Tooling API：`provider` 用 `runtime` 启动包内的 jar，`model` 和 `dependencies` 写 `source: "provider"`，jar 回复 `litheBuildModel`、`litheDependencies`。语言服务器已经导入了工程时（例如 ElixirLS），用共享写法，不要再启动一个进程各自导入一遍。

### 不要这样做

- 在 `build/` 或宿主里写 `if build_system_id == "gradle"`。这与已撤销的 `descriptor.id == "java"` 是同一类特判。
- 给模板引擎加变量、给解码器加格式、给映射加规则，却不给对应能力加新版本、不补 fixture。
- 为了让某个插件少写一段脚本，就给 `map` 加一条规则。映射只挑值，需要计算的部分放在插件脚本里。
- 为了图方便给社区插件开放 `hostIntegration`，或者再加一个新的集成。新的构建系统应该用声明或规范格式。
- 在宿主里自己拼 argv 或解析输出。即使只差一个参数，也要改声明或 Core，否则两端会各写一份。
- 为 Provider 另写一份启动字段和校验，或者新增 `build.providerLaunchPlan`。宿主也不要直接使用 Provider 的回复，必须先交给 Core 解码。

## 考虑过的备选方案

### 每个构建工具一个宿主集成，继续在 Core 写解析器

最有吸引力的地方：和现在的 Maven 一样，质量可控，改动路径熟悉。不采用为默认方案，因为生态知识仍然锁在 Lithe 的版本里，社区插件无法参与，Issue #10 的问题会在每个生态重演。只保留给 Maven 这种已有成熟实现、且声明表达不了的情况。

### 为每类工具写死一套命令词汇

例如约定每个构建系统都有 `build`、`test`、`run` 三个命令，由 Core 按工具名拼参数。最有吸引力的地方：插件更短。不采用，因为 Maven 的生命周期、Gradle 的动态任务、just 的配方根本不是同一种东西，写死只会把差异藏进 Core 的分支里。现在任务目录完全由插件声明，Core 只负责展开。

### 用 JMESPath 之类的完整查询语言做选择器

最有吸引力的地方：表达力强，社区熟悉。不采用，因为它很快会变成一门编程语言，两端宿主还要依赖同一个第三方实现的同一版本。现在的选择器是 JSON Pointer 加有限扩展，表达不了的情况交给插件脚本输出规范格式。

### 保留没有插件使用的字段，只是不校验

最有吸引力的地方：字段本来就是可选的，不用删代码，以后想用的插件直接能用。不采用，因为字段只要还在 schema 里、宿主还要解释它，就同样是要长期支持的承诺；去掉校验只会让写错的声明静默失效，同一份声明在两端还可能得到不同结果，路径越界检查也跟着丢掉。

### 保留全部映射规则和解码格式

最有吸引力的地方：Deno、npm 这类清单是 JSON 的工具可以纯静态声明，打开项目就能看到任务，不必启动进程。不采用，因为这些规则没有真实插件验证过，语义一旦发布就锁定在 `buildSystems` 版本 1 里。同样的需求用插件脚本输出 `litheBuildModel` 就能满足，代价是要等用户请求时才运行。真有插件需要时，作为 `buildSystems` 版本 2 加回来，并附带 fixture。

### 为 Provider 定义一种新的进程类型

例如新增 `buildProviders` 列表、单独的启动字段和 `build.providerLaunchPlan` 命令。最有吸引力的地方：字段可以按构建工具的需要裁剪，命名也更直白。不采用，因为 Provider 与语言服务器的启动方式、LSP 生命周期、宿主进程管理和用户需要同意的事完全相同；分成两份后，启动校验、安装审查和两端的 LSP 客户端会逐渐漂移。现在两者共用 `ServerProcess` 和同一条启动计划路径，以后真有第三类进程（例如调试适配器）时，再在新的 API 级别里把进程声明提升为独立列表。

### 换一种比 JSON-RPC 更轻的协议，或让多个 Provider 共用一个代理进程

最有吸引力的地方：二进制协议序列化更快；一个代理进程承载多个插件可以少开进程。不采用。模型和依赖请求由用户触发，一次加载只有几次往返，耗时由 Gradle、Mix 这些构建工具本身决定，JSON 编解码可以忽略；共享写法又必须和语言服务器说同一种 LSP 协议，另起一种协议就要两套客户端。共用代理进程则会让一个插件的崩溃、阻塞或恶意请求影响另一个插件，也需要在代理里重新实现权限隔离。以后 `lithe/build/execute` 的流式通知如果出现吞吐问题，先在协议内合并通知，大结果再考虑交给文件。

### 让 Provider 直接返回宿主使用的模型

最有吸引力的地方：少一次 Core 调用。不采用，因为那样 ID 生成、路径越界检查和运行入口推导就要在两端宿主各写一份，Provider 回复里的错误也会直接进入界面。现在 Provider 只回复规范格式，宿主把它交给 `build.decodeModel`、`build.decodeDependencies`，与命令输出走同一套校验。

### 只允许宿主管理的运行时

最有吸引力的地方：运行时发现全部由宿主掌控。不采用，因为这会把 .NET、Erlang、Dart 这类工具挡在外面。现在 `java`、`node`、`go` 由宿主管理，其余运行时由插件自己描述可执行文件和版本探测。

## 后果

收益：

- 新增一个构建工具只需要一份声明和 fixture，不需要改 Core 或宿主。
- 需要常驻进程的工具也不增加新的进程类型：Provider 复用语言服务器的启动字段、校验、权限和安装审查。
- 两端宿主拿到的命令行和解码结果逐字相同，由同一组标准答案保证。
- 信任边界写进了契约：`static` 档永远不启动进程；Wrapper 一律视为执行仓库代码；环境变量只传声明过的名字。

代价：

- 契约面很大：schema 和 README 增加了上千行，评审和后续修改都要同步 schema、README、fixture 和标准答案。
- 声明的表达力有上限，而且这次有意收窄了：映射只挑值。复杂工具（Gradle、Bazel）必须附带脚本输出规范格式，插件作者要维护这部分脚本。清单是 JSON 或 YAML 的工具（Deno、npm）也要附带脚本；macOS 只在用户请求时运行模型命令，所以这类工具的任务要点击“加载模型”后才出现，不能像 `toml` 静态模型那样打开项目就显示。
- Maven 仍保留一块 Core 专用的集成代码，要等进程型 Provider 落地、两端宿主迁移完成后才能删除。
- 标准答案固定了配置指纹。改动选项的序列化方式会让所有涉及指纹的标准答案一起变化，需要逐条确认。
- `ServerProcess` 由语言服务器和 Provider 共用：改动其中任何字段或校验，两者会一起变化，需要同时检查两边的 fixture。
- Windows 宿主还没有接入；macOS 上运行入口还不可用。
- 每个 Provider 都是独立的常驻进程，多个构建系统插件同时加载时会多占内存；这是隔离的代价，进程只在用户加载后启动、随工作区关闭。

## 验证

- `cargo test --manifest-path rust/Cargo.toml -p lithe-core --lib build_systems`：四个 fixture 通过校验；`build-plans.json` 的全部标准答案；在临时工作区里验证 Cargo 运行入口与内置探测器逐字一致、嵌套、优先级与拒绝、Maven reactor 识别、Gradle 规范格式输出文件、JUnit 报告、同步指纹、Maven 任务参数与内置实现一致，以及互斥条件下允许重复引用选项。
- `cargo test --manifest-path rust/Cargo.toml -p lithe-core --lib build_systems` 还覆盖 Provider：`build-plans.json` 里 `gradle-provider`、`mix-provider` 的请求计划和 `result` 解码；`provider_processes_are_install_review_programs`（自有进程和共享写法在安装审查中的条目）；`launch_plans_name_exactly_one_process`；`provider_models_are_not_read_during_detection`。
- `cargo test --manifest-path rust/Cargo.toml -p lithe-core --lib declarative_plugins`：`invalid-manifests.json` 里的非法清单，包括社区插件声明 `hostIntegration`、未声明权限、路径越界、未保护的模板变量和选项重复放置，以及 Provider 的十种错误写法（没有来源使用、混写、缺少标志、缺少权限、入口越界、不支持的运行时、未声明的设置等），和裁剪后不再接受的九种写法（静态 `yaml`、命令 `json`、任务规则、顶层目标、`parent`、映射标签、`parentDirectory`、依赖 `children`、`layout.generated`）；`command-plans.json` 里按 `buildSystemID` 选中的启动计划。
- `declarative_plugins::build_providers_require_their_own_host_capability` 与 `marketplace_plugins::build_provider_versions_require_host_support_before_download` 验证 Provider 能力与声明式构建分开，安装审查的共享 fixture 同时覆盖自有进程和共享写法。
- `cargo test -p lithe-core --lib lsp`：`lsp/interface/build_provider.rs` 验证只有宿主提供过的版本算协商成功、版本 1 只接受两个方法；`engine.rs` 的测试验证协商后的会话写出 `lithe/build/*` 并返回结果，未协商或方法不在版本里时直接失败、不写入进程。
- `./scripts/test-macos.sh --filter 'BuildSystemServiceTests'` 的 Provider 用例：`providerModelSendsThePlannedRequestAndDecodesItsReply`、`providerDependenciesDecodeTheProvidersReply` 验证请求原样发给按插件、构建系统和工作区确定的目标，回复作为 `providerResult` 交给 Core 解码且不启动命令；`workspaceSwitchAndDisabledPluginStopTheirProviders` 验证停用插件和切换工作区停止进程、插件列表不变时保留；`providerModelFailsWithoutAProviderHost`、`failedProviderRequestReportsItsMessage` 验证失败路径。`PluginMarketplaceServiceTests.buildProvidersAreAcceptedByTheMacOSHost` 验证 `gradle-provider`、`mix-provider` 能通过 macOS 的安装审查。`MacBuildProviderSessionsTests` 用真实的 `MacBuildProviderSessions` 和脚本化 Core 验证：重复请求复用进程，按插件停止后下一次请求重新启动；设置变化后按新参数重启；包内入口不可执行时不启动进程。`PluginPackageStoreTests.unusablePackagedBuildProviderIsRefused`、`buildProviderRuntimeEntryMustBeInThePackage` 验证安装时校验 Provider 的包内入口：缺失、不可执行、经过符号链接都被拒绝，运行时入口缺失也被拒绝。
- `./scripts/verify-shared-contracts.sh`：schema 与 fixture 一致；`build-plans.json` 的用例名唯一、操作合法、拒绝码都有文档、不含机器路径；`command-plans.json` 的每个用例只给出 `languageID`、`buildSystemID` 之一。
- `./scripts/verify-rust-core-comments.sh`：`build/` 模块的注释规范。
- `./scripts/test-macos.sh --filter 'BuildSystemToolWindowTests'`：选项根选择保留各实例的候选和生效值，原生菜单动作覆盖自定义单选替换、多选追加及取消已选自定义值；原生 `NSTextField` 提交验证 text/file/directory 清空后提交 `""` 而非重置。设置 `LITHE_BUILD_CAPTURE_DIR` 后可导出选项行的明暗截图。`BuildSystemServiceTests.instanceOptionEditsPreserveSiblingOnlySelections` 验证编辑一个实例不会丢掉另一个实例独有的选择；`languageImportPublishesTheSameEffectiveOptionsAsBuildPlansAndClearsDisabledPlugins` 验证插件配置与构建计划使用同一份生效值、修改后重新发布、停用及重置清理；`RustBuildSystemOperationsTests.languageImportMapsPluginOptionIDsWithoutBuildSystemNameAssumptions` 验证真实 Core 的导入映射和 Maven 可选执行字段解码。本地 Maven、Gradle fixture 副本经真实 Core 校验后读出 `icon`、`presentation`、选项图标和 `category`；模型任务自带的 `category`；每个构建系统推导出的窗口和命令（ID、标题、停靠、命令与窗口分开的动作），以及注册表校验通过。补充回归覆盖窗口所属模块激活、命令 pending 状态、独立窗口停靠与显隐恢复、旧 Maven 贡献及命令移除、参数任务根工程与目标作用范围。临时插件包中的窗口与选项明暗 SVG 加载后，目录清单和每个文件的字节必须完全不变。
- 窗口测试通过 `write-stable-tests` 的 macOS 计时入口执行，并设置 `LITHE_TEST_WINDOW_MODE=isolated`；逐测试时长记录在 `.artifacts/test-stability/` 的 HTML 与 JUnit 中。2026-10-18 固定 Swift 6.3.3 的整合回归 261 项、21 个 suite 全部通过，测试执行 19.016 秒，报告为 `.artifacts/test-stability/plugin-integration-final.{json,html,junit.xml,log}`；其中导入配置的注册后取消、停止和文件失效用例各 1 毫秒，命令模型重新计算用例 2 毫秒，真实 Core 导入桥 34 毫秒。隔离测试不替代明暗主题、真实焦点、真实 Maven/Gradle 工作流和 Windows 验收；这些未执行项保持功能矩阵 pending。
- `./scripts/test-macos.sh --filter 'PluginBuildOptionPersistenceTests|BuildSystemServiceTests'`：用真实 Core、`BuildSystemService` 和 `MacBuildOptionsStore` 验证带非空默认值的两个实例，清空 A 后保留 B 的选择，A 的 UI、同步指纹、最终任务 argv 和语言服务器导入都保留显式空；兄弟编辑、重新检测和重建服务/存储后不会恢复默认，非空编辑和重置按约定清理标记。另验证空标记与旧偏好格式兼容，并按工作区和构建系统隔离。服务单元测试的假解析器也必须区分全部无效与真实 `[]`，不能总返回 `source=user` 掩盖回落。
- `./scripts/test-macos.sh --filter 'RustBuildSystemOperationsTests|BuildSystemServiceTests'`：Swift 一侧对真实 Rust Core 调用 `build.*`（cargo、go、maven fixture 的识别、选项 `dropped`、调用计划、版本探测、任务和测试 argv、命令模型解码、诊断与同步指纹）；`BuildSystemService` 用假的 Core、运行器和存储验证识别问题列表、stdout 捕获与输出文件清理、失败退出码、输出顺序与诊断、停止、选项改存生效值、指纹变化后的重新加载提示，以及停用插件后停止命令并移除实例。
- `build_runtime_versions` 与 `MacBuildToolResolverTests` 验证 Java 8 探测参数、错误输出捕获和最低版本校验；`BuildSystemServiceTests` 使用可控制取消与退出顺序的运行器，覆盖模型/依赖的重复加载、停止、重置和停用插件，以及旧取消先完成、旧成功最后完成两种顺序。
- `build_systems` 额外覆盖嵌套实例根的目标、任务与内容根边界，以及非法选择器内容根后的 fallback；同时覆盖默认参数变化后的安装重新确认、动态 feature 删除后的检测与运行指纹一致，以及静态模型、Maven POM、JUnit 报告、诊断和测试结果与同步文件的符号链接边界；`reported_output_paths_reject_escaping_symlinks` 同时验证工作区内部链接仍被保留；`BuildOutputSourcePathTests` 验证 Build Output 导航前的真实路径校验，包括诊断列表与输出正文里的绝对路径和符号链接。`taskPlansOnlyReceiveOptionValuesTheModelStillAccepts` 与 `modelLoadStoresTheEffectiveOptionValues` 验证选项在检测和模型加载后被换成生效值，并进入下一个任务计划；`decodedDiagnosticsDoNotCrossIntoAReplacementRun` 和 `decodedTestResultsDoNotCrossIntoAnotherWorkspace` 验证迟到的解码结果不会写进替换运行或新工作区；`lateCommandOutputDoesNotCrossIntoAReplacementRun`、`lateCommandOutputDoesNotCrossIntoAnotherWorkspace` 和 `lateModelCommandOutputDoesNotCrossIntoAnotherWorkspace` 验证取消后仍在排空的命令行输出不会进入新运行或新工作区；`multiInstanceOptionValuesSurviveForInstancesThatStillAcceptThem` 验证同一构建系统的多个实例各自保留仍有效的选项。`explicitlyClearedMultiSelectKeepsItsEmptyValue` 验证用户清空多选后默认值不会回来；`cargo_implicit_main_survives_test_and_example_targets` 验证显式 test/example 目标不会抑制隐式主程序、显式 bin 仍会抑制；`outputLinksResolveRelativeToTheInstanceRoot` 和 `outputRootsCoverEveryCommandThatWroteOutput` 验证输出正文按写入它的实例根解析；`OutputTextViewLinkTests` 验证同名相对路径不会打开另一个工程；`fileChangeDuringDependencyLoadMarksTheResultStale` 验证依赖加载期间构建文件变化会拒绝旧结果；`optionChangeDuringModelLoadMarksTheModelStale` 验证加载期间改选项会把结果标记为过期；`pluginTakeoverDropsThePreviousPluginsModel` 验证插件接管同一实例 ID 后不沿用旧插件的模型和依赖；`fileChangeDuringModelLoadMarksTheModelStale` 验证加载期间构建文件变化会保留过期标记；`workspaceTestsWithoutAModelAreRefused`、`staleModelCannotCollectWorkspaceReports`（带旧模型的非空工程列表）和 `modelLessPluginCanRunWorkspaceTests` 验证只有需要子工程报告的工作区测试才要求模型，且模型过期时同样拒绝；`subprojectFileChangeDuringFirstModelLoadMarksTheModelStale` 验证首次加载期间子工程文件变化会保留过期标记；`optionChangeDuringDependencyLoadMarksTheResultStale` 验证依赖加载期间改选项会拒绝旧结果；`explicitlyClearedTextOptionKeepsItsEmptyValue` 与 `resolve_options_describe_explicit_empty_text_values` 验证空文本选项的往返；`projectLocalRuntimeCandidateResolvesWithoutProbing` 验证项目内运行时不会被探测。；`detectionDoesNotOverwriteAModelLoadedWhileItRan`、`detectionKeepsANewModelAndADependencyLoadedWhileItRan` 和 `redetectionPublishesANewStaticModel` 验证检测与模型/依赖加载并行时既不会用旧快照覆盖已发布结果，也不会丢弃正常重新检测得到的新模型。

## 适用范围

- `rust/lithe-core/src/build/`
- `rust/lithe-core/src/plugins/declarative.rs`
- `rust/lithe-core/src/plugins/marketplace.rs`
- `macos/Sources/LitheCoreContracts/Execution/BuildSystemContracts.swift`
- `macos/Sources/Lithe/Core/Rust/RustBuildSystemOperations.swift`
- `macos/Sources/Lithe/Platform/MacOS/Build/`
- `macos/Sources/LitheExecutionModule/Services/BuildSystemService.swift`
- `macos/Sources/LitheExecutionModule/Application/BuildOutputSourcePath.swift`
- `macos/Sources/Lithe/Views/Workbench/BuildSystemToolWindowRegistration.swift`
- `macos/Sources/Lithe/Views/Run/BuildSystemToolWindowView.swift`
- `macos/Sources/Lithe/Views/Run/BuildOutputView.swift`
- `rust/lithe-core/src/runtime/dispatcher.rs`
- `rust/lithe-core/src/tests/build_systems.rs`
- `shared/contracts/plugins/v1/`
- `shared/contracts/rust-core-api.md`
- `scripts/verify-shared-contracts.sh`
