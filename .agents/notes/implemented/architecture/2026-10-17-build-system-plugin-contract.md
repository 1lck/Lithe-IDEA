# Agent 笔记：构建系统插件契约与 Core 统一构建模型

状态：已实现

> 2026-11-14 更新：下文第 8 节的 `hostIntegration: maven` 已不存在。Core #23 删除了 Maven 集成，`hostIntegration` 只剩保留字段，写任何值都以 `plugin.integration.unsupported` 拒绝；Core #28 起清单 schema 也删掉了 `model`、`test.results`、`dependencies` 里的 `source: "hostIntegration"`，这样写按未知来源以 `plugin.manifest.invalid` 拒绝。Maven 改由 [lithe-plugin-maven](https://github.com/Lithe-IDEA/lithe-plugin-maven) 用声明和 Provider 提供。下文保留当时的决策与理由。

## 先说结论

Lithe 现在用一套统一的构建模型描述所有项目级构建工具（Build Tool，例如 Maven、Gradle、Cargo、Go）。插件在 `plugin.json` 的 `buildSystems`（插件 API 级别 3）里用纯 JSON 声明：怎样认出工程、用哪个可执行文件、有哪些选项、任务、运行入口和测试，以及怎样读工具的输出。思路与 LSP 插件化相同：插件只提供数据，通用逻辑只在 Rust Core 实现一次。

Rust Core 负责校验声明、识别工程、展开每一条命令行，并把输出解码成统一的形状，通过 `build.*` JSON 命令交给宿主。宿主只负责找可执行文件、启动进程、监听文件和保存用户选择，代码里不按构建系统的名字写分支。因此社区插件不改宿主代码就能加入一个新构建工具。

映射（`map`）只从解码后的文档里挑值。挑值以外的逻辑由插件自己处理：读 JSON、YAML 清单，从工具读任务，计算父子关系，这些都交给插件自带的脚本输出规范格式（第 6 节）。声明和规范格式都表达不了的工具（Gradle Tooling API 等），由插件自带的 Provider 进程回答。Provider 就是语言服务器那种进程：共用启动字段、校验和启动计划，只多回答 `lithe/build/model`、`lithe/build/dependencies`，回复仍由 Core 解码（第 9 节）。

目前落地的是 Core、共享契约和桌面端宿主（代码见 `desktop/internal/core/build.go`）。桌面端为每个启用的构建系统各开一个工具窗口，向 Core 声明 `buildSystems: [1]` 和 `buildProviders: [1]`，并在用户点击加载模型或依赖时启动 Provider、发送 `lithe/build/*`；Windows 宿主还没有接入。API 3 的清单按能力分版本，声明式构建系统使用 `buildSystems`，两种写法的 Provider 都额外使用 `buildProviders: 1`；插件市场只在宿主声明支持对应能力时才列出 API 3 的版本，见[插件契约从统一基线 0 开始](2026-11-11-plugin-contract-single-baseline.md)。宿主接入和 Maven 迁移的计划见[构建系统 Provider 提案](../../proposed/architecture/2026-10-17-build-system-provider-api.md)。

### 当前实现范围与删除条件

这里的统一模型、Provider 和通用工具窗口已经落地；下文记录的 `MavenService`、Run/Debug/Agent 旧消费者及 Maven 导入兼容路径仍是当前实现，不能把它们解释为 Maven 领域迁移已完成或必须长期保留。#1495 的迁移清单 按入口列出替换与删除条件：最新宿主/匹配插件接管所有消费者并完成数据迁移后，删除旧服务、旧配置读取和 fallback。Build Provider v1 的模型/依赖能力与宿主执行声明式 CLI 任务，也不等同于插件后端已拥有构建执行。

### Provider 任务与测试执行补充（2026-10-26）

当前增加 `buildProviders: 2/3/4` 与 `litheBuild` 协议 2/3/4：原生 Build 任务、测试发现/执行和应用启动准备通过类型化请求进入同一个工作区 Provider，不要求网页，不使用插件私有函数。测试报告复用原有解析器，应用准备交给既有 Run 进程所有者。本文关于版本 1 仅有模型/依赖的说明仍适用于版本 1；具体版本准入、进度、取消与删除条件见[Build Provider 原生任务执行](2026-10-26-build-provider-task-execution.md)。这不代表命令模型运行配置、服务编排或 Java/Maven 业务迁移已经完成。

### 多个构建根各自保存选项（2026-10-28）

同一工作区可能同时包含两个独立工程。它们即使使用同一个构建插件，也可能选择
不同的 Profiles、配置文件或仓库目录，因此不能把不同实例的路径和开关压成一个共享值。
插件用 `buildSystems: 3` 为需要隔离的选项声明实例作用域，宿主以检测到的相对根目录
保存和读取；Core 在生成静态运行入口前就收到同一份实例值。模型、依赖、任务、同步指纹
与语言导入继续消费这份输入，宿主不从工具名字推测作用域。

例如 A 的配置文件是 `a.xml`、B 是 `b.xml`，编辑或重置 A 只改变 A。显式空数组、
空文本和 `false` 仍是用户值；实例作用域不再使用共享多选的空选择标记。未声明作用域
的现有插件保留工作区选项和既有多选行为。不要把实例值覆盖到共享选项，也不要以工作区
值作为实例的隐藏回退。已有选项改变作用域时，宿主先为各根复制旧值、保留已有实例覆盖和显式空标记，
读回目标成功后才删除共享源并重新检测。失败阻止发布默认配置，保留源以便重试；暂未检测到
但已有标记的根也保存其原值。本能力本身
不宣称旧 Maven 配置和其所有消费者已经迁移。

新增状态只在平台偏好存储中按工作区、构建系统和根目录隔离，不写入发行包或插件包，
不跨工作树复用。`PluginBuildOptionPersistenceTests` 使用真实 Core、生产存储和服务，
验证兄弟编辑、空值、重置、重开、任务参数与语言导入；Core fixture 验证静态运行入口
也使用对应根的参数，并拒绝不支持实例作用域的宿主。

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

`build.detect` 对普通文件根或不存在的根保留空实例结果，这属于检测入口的既有兼容边界。共用工作区扫描器后仍在此入口区分根的类型；真实目录的读取、权限或扫描失败继续返回拒绝，不能把所有 I/O 错误当作“未检测到项目”。不要为了修复某个平台的非目录错误而放宽共用扫描器，也不要让宿主按操作系统错误码猜测空结果。回归见 `detection_returns_empty_for_non_directory_and_missing_workspace_roots`。

字段全集只写在 `Lithe-core-rust/shared/plugins/contract/v1/README.md` 的 “API level 3: build systems” 一节和 `plugin-manifest.schema.json` 里，本 Note 不重复。四个 fixture 各示范一种模型来源，按能力命名而不是按真实插件命名：`build-static-file`（读项目文件，内容用 Cargo）、`build-command-stdout`（解码命令输出，内容用 Go）、`build-command-output-file`（解码命令写出的文件，内容用 Gradle）、`build-host-integration`（交给宿主集成，内容用 Maven）。`build-provider`、`build-provider-language-server` 分别示范 Provider 的两种写法。

### 2. Core 与宿主的分工

| 角色 | 负责 | 不负责 |
| --- | --- | --- |
| 插件 | 识别规则、可执行文件候选、选项、任务目录、运行和测试模板、解码方式、监听文件 | 在宿主进程里执行任何代码；机器路径；凭据 |
| Rust Core | 校验声明；识别实例；读取静态模型；展开模板得到 argv 计划；解码模型、测试、诊断和依赖输出；计算指纹 | 启动进程；写文件；保存用户选择 |
| 宿主 | 选定可执行文件并探测版本；启动进程并负责取消、期限和输出上限；分配输出文件；监听文件；保存选项；信任确认 | 生态知识；拼 argv；按构建系统名写分支 |

宿主通过 13 个命令使用 Core，请求和结果形状见 `Lithe-core-rust/rust/contracts/rust-core-api.md` 的 “Build systems” 一节：

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
- 代码在 `rust/crates/build/src/`，在 `lib.rs` 里用私有的 `mod build;` 引入，没有新增 crate 根的 `pub` 项。模板解析与 `plugins::declarative` 共用 `parse_template_with`，不另写一份。

### 3. 对社区插件开放什么，封闭什么

这一节回答“社区插件作者怎么注入自己的构建工具”。原则是：**工具本身是开放的，Core 怎样解释声明是封闭的。**

插件可以自由描述（不需要改 Core）：

- **任何构建工具**：ID、标记文件、任务、选项、运行入口、测试过滤器、诊断正则、依赖命令都是数据。
- **可执行文件**：按偏好顺序列出候选，有四种基础来源：
  - `projectFile`：工程里的 Wrapper（例如 `gradlew`），可以要求某些文件存在。它一律被视为执行仓库代码。
  - `environment`：某个环境变量下的相对路径，例如 `MAVEN_HOME` 下的 `bin/mvn`。变量必须列在 `environmentInputs` 里，宿主只传这些变量。
  - `command`：在 `PATH` 上查找的裸命令名。
  - `runtime`：直接使用一个声明的运行时，例如 Go fixture 直接用 `go`。
- **运行时**：`java`、`node`、`go` 由宿主管理，只写 ID 和最低版本，按用户的运行时设置发现。Core 提供 Java 的 `-version`、Node 的 `--version`、Go 的 `version` 探测参数，宿主合并标准输出与错误输出再交回 Core 校验；Java 8 不支持 `--version`，且版本信息通常写到错误输出，不能据此误判为不可用。其他任何 ID 都由插件自己写可执行文件候选和版本探测，所以运行时列表是开放的。
- **自带逻辑**：插件附带的脚本（例如 Gradle 的 init script，即初始化脚本）可以直接输出规范格式，不必写选择器映射。规范格式有 `litheBuildModel`、`litheTestResults`、`litheDependencies`、`litheDiagnostics`。规范文档里的未知字段会被忽略，所以新脚本配旧宿主也能用。插件自带的常驻 Provider 进程也用这几种格式回复（第 9 节）。

固定词汇（要扩展就给对应能力加一个新版本，见[插件契约从统一基线 0 开始](2026-11-11-plugin-contract-single-baseline.md)）：

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

### 12. 语言服务器导入：`languageImport`

JDT LS 自己导入 Maven 和 Gradle 工程。导入用的 Profile、settings 和缓存必须和用户给构建工具选的一致，否则编辑器解析出来的依赖和构建不同。以前这些值来自内置 Maven 窗口（`MavenService`），而社区插件没有 `hostIntegration`，Core 不能按插件名字认出 Maven。

所以 2026-10-18 给 `buildSystems` v1 加了可选的 `languageImport`：`kind` 写插件对应的导入（`maven` 或 `gradle`），`options` 把导入设置映射到插件自己的选项 ID。`maven` 有 `profiles`（多选）、`settingsFile`（文件）和 `localRepository`（目录）；`gradle` 有 `offline`（布尔）和 `gradleUserHome`（目录）。校验要求映射的选项存在且类型匹配。`build.languageImport` 按用户存储的值解析选项，返回 `lsp.startServer` 已经接受的 `mavenContext` 或 `javaGradle`。宿主只做转发，不认插件。

Gradle 的 `offline` 和 `userHome` 是用户自己选的值，不是猜测，所以和 #1302 “不猜构建脚本里的设置”不冲突：没有目录值时不发送 `userHome`，`offline` 按 Core 返回的生效布尔值传递。这两个值只在会话启动时生效；Maven 仍可通过 `lsp.updateMavenConfiguration` 热更新。

### 13. 还没有开放给用户的部分

- Windows 宿主还不发送 `hostCapabilities`，不会列出级别 3 的版本，也没有 Build 工具窗口。
- Windows 宿主还不会启动 Provider，也不声明 `buildProviders`。任一 `buildSystems[].provider` 都要求 `buildProviders: 1`，包括共享语言服务器；不要为了让插件可安装而从 `requires` 省去它，那会因能力未列全被拒绝。
- Provider 进程没有操作系统级沙盒（例如 `sandbox-exec` 或 App Sandbox 子进程），隔离只到进程和通信通道这一层；需要时作为后续工作单独设计。
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

### Provider 自己判断缓存是否过期，或者新增一个失效方法

最有吸引力的地方：宿主不用区分加载原因。只靠 Provider 自己比较 POM、settings 和选项指纹，不采用，因为指纹不覆盖本地仓库被手工清理、远端快照版本更新这类情况，用户点 Reload 恰恰是在说“别信缓存”，这个意图只有宿主知道。新增 `lithe/build/invalidate` 之类的方法也不采用：老 Provider 不认识新方法，需要升协议版本；在已有请求里加可选的 `refresh` 不需要。工具路径同理：让每个 Provider 各自实现 Wrapper、环境变量、`PATH` 和用户覆盖的查找，会和宿主运行任务时选中的工具不一致。

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
- Maven 仍保留一块 Core 专用的集成代码，要等进程型 Provider 落地、两端宿主迁移完成后才能删除。
- 标准答案固定了配置指纹。改动选项的序列化方式会让所有涉及指纹的标准答案一起变化，需要逐条确认。
- `ServerProcess` 由语言服务器和 Provider 共用：改动其中任何字段或校验，两者会一起变化，需要同时检查两边的 fixture。
- 每个 Provider 都是独立的常驻进程，多个构建系统插件同时加载时会多占内存；这是隔离的代价，进程只在用户加载后启动、随工作区关闭。

## 验证

- 在 Core 仓库运行 `cargo test -p lithe-core build_systems`：四个 fixture、标准答案、Provider 协议与安装审查条目。
- 在 Core 仓库运行 `cargo test -p lithe-core declarative_plugins`：非法清单和启动计划。
- `./scripts/desktop/desktop-go.sh test ./internal/core -run 'Build'`：桌面端对 `build.*` 的调用与解码。
- `./scripts/desktop/desktop-go.sh test ./internal/buildprovider ./internal/workbench -run 'Build'`：Provider 会话与构建窗口。
- 在 Core 仓库根运行 `node shared/plugins/scripts/verify-docs.mjs`：契约文档链接与 schema `$id`。
- `./scripts/agent-notes/verify-agent-notes.sh`。

## 适用范围

- `desktop/internal/core/build.go`
- `desktop/internal/buildprovider/`
- `desktop/internal/pluginhost/pluginhost.go`
- `shared/platform-feature-matrix/features/build-system-plugins.json`

- Lithe-core-rust 锁定修订：[rust/lithe-core/src/build/](https://github.com/Lithe-IDEA/Lithe-core-rust/tree/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/build)
- Lithe-core-rust 锁定修订：[rust/lithe-core/src/plugins/declarative.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/plugins/declarative.rs)
- Lithe-core-rust 锁定修订：[rust/lithe-core/src/plugins/marketplace.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/plugins/marketplace.rs)
- Lithe-core-rust 锁定修订：[rust/lithe-core/src/runtime/dispatcher.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/runtime/dispatcher.rs)
- Lithe-core-rust 锁定修订：[rust/lithe-core/src/tests/build_systems.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/tests/build_systems.rs)
- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/shared/plugins/contract/v1/`
- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/rust/contracts/rust-core-api.md`

### 统一的候选解析扩展

### 构建与运行复用本机工具链选择（2026-10-28）

`executableResolution: 2` 的工具链候选引用已有 Run 注册表。Core 只传递工具链 ID 与
规范化实例根，平台从同一份 local.json 读取项目和子项目选择，不在 Build 中再建 Maven
路径偏好。显式选择不可用或前置 Runtime 失败时停止请求，不能把无 tool 的请求交给
Provider 自行找另一套 Maven。被动导入经只读发现入口，不运行 Wrapper 或版本探测。

Maven 构建所用 JDK 与后端进程自身的 JDK 是两项独立选择。宿主把解析得到的少量运行时
环境与 Maven 路径一起传给 Core；Core 合并插件选项环境后使用既有 Provider 参数。
模型、依赖、任务、测试和原生配置使用同一输入。不把整个宿主环境经 RPC 转发，否则会
携带无关凭据。工具链解析到工作区内的程序或文件别名时，仍按项目代码限制显式读取。

### 共享 Build 偏好与本机覆盖

旧 Maven 的共享 Profiles 和跳过测试不能迁入本机 UserDefaults 后丢掉团队范围。
通用 Build 偏好使用 `.lithe/build/options.json`：工作区选项、所有实例的默认值和
逐根覆盖都有明确位置，值仍由 Core 和插件声明校验。它是 Lithe 的调用偏好，不能
冒充 Maven 原生 settings。非敏感原生文件仍按来源读取与确认编辑。

本机选项只保存相对共享值的差异，重置本机覆盖重新继承共享值。检测与重开不写共享
文件，也不把共享默认值复制到本机偏好。本机偏好只有缺失键才表示未配置；键存在但
不是预期的 Data 时同样报损坏，保留原值，不能当作空选项发布默认配置。读取损坏、不可访问或不支持的文件时停止
发布默认构建/语言导入配置，保留原始内容并报告错误；写入检查原字节并读回核对。
旧运行偏好中的 Maven 文件/仓库覆盖属于本机作用域，迁入 `.InstanceDefaults`，
供之后出现的实例继承，不写入团队文档。已有团队和逐根选择优先于迁移值，
逐根编辑及重置仍由同一选项合并链处理。两个实例从默认值继承后，编辑 A 不改变 B；Core 的静态运行入口也消费同样的合并值。
共享文件变化会撤销原生配置草稿和模型快照，不能继续使用之前的配置指纹。

未选中的用户自定义值单独保留为候选，仅在插件允许自定义值时显示，不作为已选值或
上游模型事实。这样旧 Profiles 迁移不会只保住当前选择，也不会因候选变化触发构建。

`build.detect` 同时返回 Core 按作用域和实例根合并的已保存选项与被拒绝的键，平台直接
使用这份选择，不在前端再实现一遍继承链。例如 A 根显式保存空 Profiles，不能在 UI
发现列表为空时自行补回团队默认值。检测只读，不把归一化结果写回共享文档。
