# Agent 笔记：Java 拆分用到的通用 API 与宿主语言闸门

状态：提议中

## 先说结论

用户要求 Rust Core 和 macOS 宿主的生产代码里不再出现 Java、JDT、JVM、Maven、Gradle、Spring、MyBatis 的专属逻辑，这些逻辑全部搬进 Java、Maven、Gradle 三个插件（[Issue #1495](https://github.com/1lck/Lithe-IDEA/issues/1495)）。本篇固定三件事：搬家要用哪些通用接口、拆成哪些 PR、用什么脚本防止旧写法回来。

通用接口**不新增任何 API 编号**：计划 [API-01–44](../../../../docs/development/macos-plugin-api-plan.md) 已经覆盖全部需要，拆分只是把其中标着“未做”或“部分完成”的条目提前做完。插件之间的通信走 Core 中转的插件函数调用（插件 1 → Core → 插件 2），这是 API-35 的第一阶段，状态记为“第一阶段进行中”，它不是安装依赖。

日常开发的直接影响：宿主和 Core 的新代码里不得出现上述词汇。验收脚本 `verify-no-host-language-specifics.mjs` 用“棘轮”（只允许计数下降、不允许上升）限制存量，合入本 PR 之后，任何新增命中都会让检查失败。

## 问题

### 为什么新写一篇 Note

[Maven/Java 领域插件迁移](2026-10-26-maven-java-domain-plugin-migration.md)是阶段 A 的静态清单：宿主里有哪些 Maven/Java 入口、谁在调用、删除条件是什么。它有 268 行，保留作为清单和证据。它的 §八 把后续工作拆成 C1、C2、D1、D2、E1、E2、F 七个交付单元，但后来的调查改变了两件事：

1. 新增的通用接口要对齐用户的 API-01–44 计划，不再另起名字，所以“C2：最小领域能力”需要换成按 API 条目划分的几个基础设施 PR。
2. 删除工作要同时顾及 Windows。Windows 还在直接调用这些命令，不能一删了之，需要先有一个过渡的 legacy crate（见下文）。

继续往旧 Note 里塞这两件事，会让“清单”和“决策”混在一起。所以旧 Note 只保留清单，§八 改为指向本篇；本篇承接交付拆分、API 映射、Windows 过渡和闸门。

### 现状

拆分前，宿主在这些地方认识 Java：

- Core 里有 `jdt*.rs`、`project/maven*.rs`、`java_*` 运行和测试模块，以及语言服务器 engine 里的十多处 JDT 分支。
- macOS 有 `HostIntegrations/*`、`JavaPluginTransition`、`MavenContracts`、Java 运行标记和测试结果服务器。
- 插件清单契约里有按语言写死的字段，例如 `hostIntegration: jdt`、`languageImport {kind}`。
- 共享前端内置了 TextMate 语法和主题，其中带 Java。
- Windows 的 TypeScript 和 Rust 直接调用 `maven.*`、`java.*`、`spring.index`、`mybatis.index` 等命令。

判断标准只有一条：换一种语言插件（例如 Python 加 debugpy，或 Scala 加 Metals），宿主一行都不用改。

## 提案

### 一、通用能力对应计划条目，不新增编号

“取代什么”列出的是同项删除的旧路径，由对应的纵向 PR 在能力就绪后删除。基础设施 PR（C-*）只交付通用能力，不删旧路径。

| 计划条目 | 本轮提前做完的部分 | 取代的旧路径（由谁删除） |
| --- | --- | --- |
| API-12 | `jdt://` 做成通用的只读内容提供者：插件按 URI scheme 注册，宿主打开该 scheme 时调后端函数取内容；插件内部可用 API-25 的请求去向语言服务器取反编译结果。清单里不加 `virtualDocuments` | Core 和 Swift 里写死的 `jdt://` 读取路径：`lsp/languages/jdt.rs`、`lsp/interface/engine.rs`、`debug/engine.rs`、`LanguageToolingContracts.swift`（E1） |
| API-19 | Maven 设置（settings 文件、本地仓库、Profiles）在 Maven 插件里读取、回显、写回，遵循[真实配置读写](../../implemented/architecture/2026-10-25-settings-native-configuration-editing.md) | `jdt_maven_settings.rs`（D1）；设置页改由 Maven 插件的真实配置取代 |
| API-20 | 沿用已有的 `stateDirectory`、`workspaceStateDirectory`、`logDirectory`，只新增 `temporaryDirectory` | `MacJdtWorkspaceState` 和 `java_workspace.rs`（E1） |
| API-22 | `languageServer/setStatus` 报告语言服务器准备状态；输出链接匹配器（清单声明正则，点击时调后端函数解析位置） | `jdt_progress.rs`（E1）、`LitheConsoleStyle` 里的 Java 栈帧折叠（E2a） |
| API-23 | `run/start`、`run/stop`、工具 ID 引用（工具定义 ID，例如 `java`）、`requiresTools`。Run 会话比受管进程多一层宿主展示，评审时需写明 | `SELECTED_RUNTIME_TOOLS`、`LAUNCH_RUNTIME_TOOLS`、`runConfig.selectJava`、`java_launch.rs`（E2a） |
| API-25 | 插件后端的启动解析器（`launch.kind:"backend"`），以及后端向自己声明的语言服务器发送 request、notify 和设置状态；`languageServers 3` 只加会话字段。`editor/registerProviders` 只补上游确实缺失的能力（Spring、MyBatis） | engine 里的 JDT 分支、`HostIntegrations/*`、`languages/{java,spring,mybatis}.rs`（E1、E2c） |
| API-26 | 诊断采用推送式 collection：插件只能写自己的 collection，带文档版本。不放进拉取式的 `registerProviders` | 无单独的旧路径；E2c 的 Java 诊断改用该通道 |
| API-27 | 编辑器动作扩展图标、`alternatives`、`reveal`；CodeLens；运行和测试标记。前端 `lithe-java-run-*` 类名改成 `lithe-editor-action-*` | `java_run_markers.rs`、`java_entrypoints.rs`（E2a）；前端 `plugin-editor-actions.ts` 的类名由 C-EDIT 改名 |
| API-29 | **不改协议。** 测试发现和运行已在 #1517 合入（`lithe/build/discoverTests`、`build.runTests`、`litheTestDiscovery`/`litheTestResults`），由 Maven 和 Gradle 插件提供 | `java_tests.rs`、`MacJavaTestResultServer`（E2b） |
| API-30 | `debug/start`；`debugAdapters 3` 的 `features`、`defaults` | `debug/java_test.rs`、`debug.javaTestLaunch` 命令（E2a、E2b） |
| API-33 | `projectGenerators 2` 增加 `type:"tool"`，由后端动态注册 | `JavaPluginTransition`、`AppModel+JavaPlugin`、目录里的 Java 条目（E2d，不做替代，用户到商店搜索） |
| API-35 | 第一阶段：Core 中转插件函数调用，见下一节 | `languageImport {kind}`、`build/language_import.rs`、`MavenContracts`、`RunService.buildLanguageImportProvider`、`lsp.retryMavenProfiles`（D1） |
| API-37 | 界面语言走 API-37 的环境信息，不在 workspace context 里加 `locale` | 无（避免多加一个字段） |

### 二、API-35 第一阶段：Core 中转的插件函数调用

背景：[插件函数契约](../../implemented/architecture/2026-10-20-plugin-function-contract.md)规定函数是插件私有的，后端不能请求宿主去调用别的函数（拒绝码 `plugin.function.recursiveCall`），也不能调用别的插件的函数（`plugin.function.wrongPlugin`）。Maven 的导入配置要给 Java 的 jdtls 用，必须有一条合规的跨插件通道。

做法：在 Core 里加一个中转，链路是插件 1 → Core → 插件 2。

| 规则 | 内容 |
| --- | --- |
| 接收方显式导出 | 插件在清单里列出允许其他插件调用的函数 ID。没列出的函数仍然私有，`wrongPlugin` 行为不变 |
| 调用方声明函数 ID | 写函数 ID（相当于接口名），不写对方的插件 ID。安装和启用确认时，界面显示会匹配到哪些插件 |
| 发现 | 一个宿主方法列出当前工作区中已启用、并导出了某个函数 ID 的插件，按插件 ID 排序。调用方因此不必写死 Maven 或 Gradle |
| 调用 | `litheFunctions` 协议当前版本是 1、2、3，新增版本 4，并加一个宿主请求（例如 `lithe/host/functions/invoke`，参数为 `pluginID`、`functionID`、`params`）。旧的后端 `lithe/function/invoke` 仍然返回 `recursiveCall` |
| Core 检查 | 双方都已声明且都已启用；被调方后端没运行时由 Swift 按 I/O 启动，启动有时间上限；Core 记录调用链，被调方已经在链上（A→B→A）就拒绝；调用深度、并发数、参数和结果字节数、超时都有上限；取消沿调用链向下传 |
| 信任不传递 | 被调方用自己的权限执行，调用方不获得任何权限。被调方只能读到调用方的插件 ID。远程工作区按 API-40 明确拒绝，不静默在本机执行 |
| 错误码 | 每个新的拒绝原因占用一个新码，不复用 `wrongPlugin`、`recursiveCall`，并避开 C-LS（-32022、-32023、-32024、-32026）和 C-RUN（-32025）。现有最大值是 -32021，具体数值由 C-IMPORT 的契约 PR 在 -32027 之后分配 |
| 不开放 | `lithe/build/*` 仍然对后端关闭，后端请求它一律返回 `recursiveCall` |

这一步**不是安装依赖**：它不参与安装闭包，不求解版本，装 Maven 不会强制装 Java，禁用 Java 只是让调用找不到提供方。因此 [插件依赖与导出](2026-10-25-plugin-dependencies-and-exports.md)里“第一版先不加入弱依赖、可选依赖和并存多版本”的规则不受影响。该 Note 的其余规则这一步照做：

- “导出是明确选择的契约”：只有清单列出的函数能被调用。
- “信任不沿依赖关系传递”：调用方不继承被调方的权限，反之亦然。
- “不能删除旧 `wrongPlugin` 或 `recursiveCall` 检查”：两个检查原样保留。
- “是否增加动态操作须由真实插件证明”：Java 的导入配置要在启动语言服务器时现算，是真实的动态计算，不能写成静态声明。这是第一个真实使用者。
- 不兼容的变更要换新的函数 ID（对应该 Note 的“导出契约版本”）。

该 Note 还要求每个导出写明可接受的调用上下文和所需授权，这一项留给 C-IMPORT 在契约里定稿。依赖与导出那篇 Note 继续留在 `proposed/`，由 C-IMPORT 的 PR 落地时更新，本 PR 不移动它。

SDK：三份官方后端 SDK（Node、Java、Rust）各自增加发现、调用和导出的类型化包装，由 `lithe-plugin-docs` 的 SDK 批次交付。

### 三、Java 拆分怎样使用这个中转

#### 导入配置

用户的判断是：纯 Java 工程没有“导入工程”这一步，jdtls 直接按源码目录工作；只有 Maven 和 Gradle 工程才有导入。所以导入配置的所有逻辑属于 Maven 和 Gradle 插件，Java 插件里不能有任何 Maven 或 Gradle 逻辑。

正确做法：

1. Java 插件定义一个接口函数 ID，例如 `languageImport.settings`。
2. Maven 和 Gradle 插件各自导出它，在自己的后端里计算 settings 文件、本地仓库、Profiles，以及写在自己状态目录里的派生 settings.xml；Gradle 计算 offline 和 gradleUserHome。
3. Java 插件在 `launch.kind:"backend"` 的启动解析器里，先发现并调用各提供方（带有界超时），再合并结果，只保留 jdtls 自己的键前缀 `java.configuration.maven.`、`java.import.maven.`、`java.import.gradle.`，通过 API-25 交给 jdtls（`initializationOptions`，或 `languageServer/notify` 发送 `workspace/didChangeConfiguration`）。
4. 超时或失败时，jdtls 用默认配置启动，状态栏显示是哪个插件没有提供配置，不阻塞打开窗口。
5. 用户修改 Maven 设置后，Maven 调用 Java 导出的变更通知函数，并在参数里直接带上新值。

不要这样做：

- Java 插件解析 `settings.xml` 或 POM，或者“看到 `pom.xml` 就读 Maven 配置”。
- 在 Java 导出的变更通知里回头调用 Maven 取值。Maven → Java → Maven 是环路，会被 Core 拒绝。
- Core 里写“Maven 设置变了就推给 jdtls”。宿主只做中转，不认识 Maven 和 Java 这两个名字。

#### 测试运行

测试结果要显示在宿主原生的测试面板里。发现和运行本来就在 API-29 里，由 Maven 和 Gradle 插件提供；Java 插件的测试标记走 API-27。标记被点击后怎样请求构建插件运行某个测试，具体落点等 C-EDIT 交回 API-27 之后再定。**不**把 `build.*` 开放给后端，**不**新增 `testControllers`。

### 四、版本与权限

| 能力 | 版本 | 说明 |
| --- | --- | --- |
| `serverProcess` | 3 | `launch.kind:"backend"`（C-LS） |
| `serverProcess` | 4 | `runSelectedRuntime.tool` 改为工具 ID（C-RUN，契约部分排在 C-LS 之后） |
| `languageServers` | 3 | 只放会话字段 |
| `debugAdapters` | 3 | `features`、`defaults` |
| `projectGenerators` | 2 | `type:"tool"` |
| `litheFunctions` | 4 | 宿主请求 `lithe/host/functions/*`（C-IMPORT） |
| 清单里的导出和调用字段 | 新能力键 | C-IMPORT 按 `capabilities.rs` 的命名习惯，从 1 起 |
| `pluginAPIVersion` | 仍是 4 | 新能力一律用 `requires.<key>` 的新版本门控；协议 3 内只增不改，新方法靠 `getCapabilities` 发现 |

每个新的宿主服务配新权限；新的错误码一码一义（见上）。

### 五、PR 拆分

主仓库：

| PR | 内容 | 依赖 |
| --- | --- | --- |
| A0 | 本 Note、计划更新、闸门脚本（棘轮模式） | 无 |
| C-LS | `languageServers 3`、`serverProcess 3`、`languageServer/*` 宿主方法、错误码 -32022/23/24/26 | A0 |
| C-RUN | `debugAdapters 3`、`serverProcess 4`、`run/*`、`debug/start`、输出链接匹配器、错误码 -32025 | A0，契约晚于 C-LS |
| C-EDIT | 编辑器动作选项、`registerProviders`、前端类名改名 | A0 |
| C-IMPORT | Core 中转的插件函数调用（API-35 第一阶段） | A0 |
| C-PROJ | `projectGenerators 2` | A0 |
| W1 | Windows legacy crate 第一阶段；Core 删除只有 Windows 在用的 Java 部分 | 无 |
| W2 | legacy crate 增加会话命令，经通用的 `lsp.request` 等命令 | W1，J1 |
| E1 | Mac 的 JDT 启动切到 Java 插件，删除 `HostIntegrations/*`、`jdt*.rs`、engine 的 JDT 分支等 | C-LS，J1，W2，W1 |
| D1 | Maven 和 Gradle 切到中转导出，Mac 设置页由 Maven 插件提供，删除 `languageImport {kind}` 等 | C-IMPORT，M1，G1，E1 |
| E2a | 运行标记、Run、Debug 切到插件，含运行配置迁移 R1 | C-RUN，C-EDIT，J2，E1 |
| E2b | 测试切换，JVM 性能面板改为插件原生界面 | J3，E1，C-EDIT，构建插件的 API-29 测试 |
| E2c | Spring、MyBatis、CodeLens、折叠、语义 token | C-EDIT，J4，E1 |
| E2d | 删除 `JavaPluginTransition`、`AppModel+JavaPlugin`、目录里的 Java 条目，不做替代 | C-PROJ，J5 |
| F | 最终删除；闸门切到 `--strict`；删除旧脚本和 baseline | 以上全部 |

外部仓库：

| 仓库 | PR | 内容 |
| --- | --- | --- |
| lithe-plugin-docs | docs-LS、docs-RUN、docs-EDIT、docs-IMPORT、docs-PROJ | 契约同步，三份 SDK 的类型化包装；C-* 合入前先过 `sdk-e2e` |
| lithe-plugin-java | J0 | 骨架，移植纯逻辑 |
| | J1 | 启动解析器、`jdt://`、状态目录、准备状态、导入配置消费方 |
| | J2 | 入口和运行标记、Run、Debug、长类路径 |
| | J3 | 测试标记、JVM 性能面板 |
| | J4 | Spring、MyBatis 提供者、Endpoints 面板 |
| | J5 | 生成器、`java` 工具定义 |
| lithe-plugin-maven | M1 | 工具定义 `mvn`、真实配置读写、导出 `languageImport.settings` |
| lithe-plugin-gradle | G1 | 导出同一个函数 |

旧运行配置（`javaMain`、`springBoot`、`mavenModule` 等）由 R1 迁移到插件命名空间，兼容读取保留两个稳定版后删除，并开 Issue 跟踪（Q8）。

### 六、Windows legacy crate

Windows 现在还通过 Core 的命令调用 Maven 和 Java 功能，而 Windows 宿主尚未实现通用插件接口，不能直接换成插件。所以 W1 新建 `windows/tauri/crates/lithe-legacy-java`（legacy crate，意为过渡用的旧功能库，尚不存在，W1 创建），把 Core 里只有 Windows 使用的 Maven 和 Java 代码搬过去：

- 入口是 `try_execute(request) -> Option<String>`，命中旧命令名就处理，否则返回 `None`。`windows/tauri/src-tauri/src/core.rs` 的 `core_execute` 在调用 `execute_for_window(..., lithe_core::execute_json)` 之前，以及 `platform.rs` 的 `platform_invoke` 在 `lithe_core::execute_json` 之前，都先调它。Windows 的 TypeScript 消费者不变。
- W2 增加会话命令，经通用的 `lsp.request`、`lsp.updateWorkspaceConfiguration`、`lsp.waitEvents` 工作。
- 它在 Windows 自己的目录里，不在闸门的扫描根目录内，所以不进白名单；但 Windows 的 TypeScript 和 Rust 消费文件在白名单里，每项的 `issue` 填 #1495，`removeWhen` 写明删除条件。

**删除条件：** Windows 宿主实现了通用接口，并能安装 `lithe-plugin-java`。到那时整个目录删除，白名单里的 Windows 项一并删除。跟踪 Issue 草稿的标题是“Windows：用 Java 插件取代 lithe-legacy-java”，用户确认后再按 `submit-lithe-issue` Skill 提交。

代价：这段时间同一份逻辑同时存在于 Java 插件和 legacy crate。证据要求是 `cargo check --manifest-path windows/tauri/src-tauri/Cargo.toml`、Windows 单元测试和 Parallels 真机冒烟。

### 七、验收闸门脚本

`scripts/architecture/verify-no-host-language-specifics.mjs` 扫描六个目录：`rust/lithe-core/src`、`macos/Sources`、`frontend/editor/src`、`shared/contracts/plugins/v1`、`windows/tauri/src`、`windows/tauri/src-tauri/src`。跳过 `vendor`、`node_modules` 和以点开头的目录。

检查什么：

- **词表**：把标识符和字符串按 camelCase、snake_case、`.`、`/`、`-` 切成词，命中 `java`、`jdt`、`jdtls`、`jvm`、`maven`、`mvn`、`gradle`、`spring`、`mybatis`、`lombok`、`junit`、`testng`、`m2e`、`surefire` 就计数。`JavaScript` 不算。它按整词匹配，所以 `javac`、`javadoc`、`mvnw`、`springframework` 不计入。
- **名字比较**：Rust、Swift、TypeScript 里把某个值与带词表词的字符串字面量做相等比较，或者写成 `match`、`switch` 的分支，例如 `tool == "java"`、`case "maven":`。
- **工具名常量表**：Rust 里的 `const`、`static` 字符串数组，内容列出词表词，或 `node`、`go`、`python` 这类工具名，例如 `const X: &[&str] = &["java", ...]`。按条目计数：这类表有几项就记几，所以给已有的表再加一个 `python` 也会让计数上升。
- **schema 封闭枚举**：`shared/contracts/plugins/v1/` 下的 JSON schema 里，`tool`、`runtime` 属性用 `enum` 或 `const` 把取值写死，`languageImport.kind` 同样写死，以及每一个 `hostIntegration` 属性。按取值计数：`enum` 有几个成员就记几（含 `items`、`oneOf`、`anyOf`、`allOf` 里的），`const` 记 1；`hostIntegration` 记它的集成名个数（对象形式只数 `id` 的取值），至少记 1。这样已有枚举从 `["java", "node"]` 扩成 `["java", "node", "python"]` 也会被棘轮拦下。
- **六个旧 token**：`is_main_method`、`main_declaration_index`、`main_class_exists`、`containsJavaMainMethod`、`java.runConfigurations`、`java.testMethods`，原脚本 `verify-java-semantic-ownership.mjs` 里的规则，在任何模式下都失败，白名单文件里也一样。

三种模式：

| 模式 | 行为 |
| --- | --- |
| 默认（棘轮） | 读取 `language-specifics-baseline.json`。任何文件的计数上升、出现新文件（改名也算新文件）都失败；计数下降但没有更新 baseline 也失败，强制每个 PR 同步收紧 |
| `--update-baseline` | 把 baseline 写成当前计数，只允许下调；baseline 不存在时才可以创建 |
| `--strict` | 不看 baseline，任何命中都失败，只有白名单文件豁免。F 使用 |

`--base <ref>` 把 baseline 和白名单与该提交里的版本对比：baseline 增长，或白名单新增条目，都失败。CI 用它防止有人靠改 baseline 放行。

白名单是 `language-specifics-allowlist.json`，每项必须有 `{glob, reason, issue, removeWhen}`，`issue` 形如 `#1495`；没有被任何文件用到的条目算错误。当前 13 项：3 项是共享前端的 TextMate 语法、主题和语言目录（决定 Q3），10 项是 Windows 的 Maven、Java、Spring、MyBatis TypeScript 文件。白名单文件不计数，也不参与棘轮。

A0 提交时的基线快照（以 baseline 文件为准）：

| 目录 | 词表命中 | 文件数 |
| --- | --- | --- |
| `rust/lithe-core/src` | 8755 | 114 |
| `macos/Sources` | 4972 | 185 |
| `frontend/editor/src` | 99 | 2 |
| `shared/contracts/plugins/v1` | 1045 | 44 |
| `windows/tauri/src` | 7787 | 335 |
| `windows/tauri/src-tauri/src` | 1179 | 14 |
| 合计 | 23837 | 694 |

另有名字比较 458、工具名常量表条目 163（18 张表）、schema 封闭取值 13，另有 30 个白名单文件不计数。

并行 PR 的影响：每个删除或改名 Java 内容的 PR 都会让计数下降，必须同项运行 `--update-baseline`。例如 C-EDIT 把 `lithe-java-run-*` 改名为 `lithe-editor-action-*`，会让 `frontend/editor/src/plugin-editor-actions.ts` 的计数从 2 降到 0；W1 删除 Core 的 `project/maven*.rs` 会让对应文件从 baseline 消失。baseline 每个文件占一行，减少并行 PR 的冲突。

脚本接入 `scripts/architecture/verify-core.sh`，与旧脚本并存；旧脚本 `verify-java-semantic-ownership.mjs` 只扫三个目录，是新脚本的子集，由 F 删除。CI 用独立工作流 `.github/workflows/verify-host-language-specifics.yml`，不占用 macOS 和 Windows runner。

### 八、已定的待决项

| 编号 | 决定 |
| --- | --- |
| Q1 | 保留官方 ID `dev.lithe.plugin.java-support` 和工具短 ID `java`，从外部仓库构建 |
| Q2 | E1 之后旧版 1.1.0 必须更新，不保留兼容翻译 |
| Q3 | 共享前端内置的 TextMate 语法、主题、文件关联里的 Java 项，算通用语言目录数据，进白名单 |
| Q4 | 作废：不做商店索引 v2 |
| Q5 | 三份 SDK 都有通用 `hostRequest`，并为每组 API 提供类型化包装 |
| Q6 | W1 现在做 |
| Q7 | 控制台栈帧链接改为通用的输出链接匹配器（API-22）；JVM 性能面板改为插件原生界面，放进 J3 和 E2b |
| Q8 | 旧运行配置的兼容读取保留两个稳定版，开 Issue 跟踪删除 |

## 考虑过的备选方案

- **在计划之外新增三个 API 编号。** 曾设想把“后端请求自己的语言服务器”“测试控制器”“商店按文件类型推荐插件”各记一个新编号。用户决定不加新功能、不另起编号，这三项分别并入 API-25、API-29（已有 #1517 的测试能力）和不做，所以计划保持 API-01–44。
- **`buildSystems 5` 加 `languageImport.exports`，再加 `buildImportConsumers`。** 为导入配置新开一条专用通道。放弃，原因是 `buildSystems` 的 `modelSharing` 已能共享构建选项，专用通道只服务一个用例；通用的函数中转可以服务以后的其他插件组合。
- **`buildModelInputs 2`。** 让没有构建系统的语言插件也能读构建模型输入。放弃，因为它要求 Java 插件读 Maven 的选项，Java 插件里就会有 Maven 逻辑。
- **声明式关联：Maven 声明“当 Java 启用时推送 settings”，宿主转发。** 放弃，因为宿主会变成 settings 的专用转发器，被关联方还要声明键前缀；通用的函数中转更简单，也不需要宿主理解 settings。
- **把 `build.*` 开放给后端（`lithe/host/build/*`）。** 放弃，因为契约规定后端请求 `lithe/build/*` 一律返回 `recursiveCall`，这条保护不改；Java 要触发测试时走中转，由构建插件自己决定。
- **把导入关联做成安装依赖。** 放弃，因为装 Maven 不应强制装 Java，且依赖 Note 明确第一版不做可选依赖。中转只在运行时发现已启用的提供方。
- **`testControllers` 和 C-TEST。** 放弃，因为测试发现和运行已在 API-29 里，Java 的测试标记走 API-27，再加一套控制器会形成第二个测试契约。
- **商店索引 v2 和按文件类型推荐插件。** 放弃，E2d 直接删除宿主里写死的 Java 引导，用户到商店搜索。
- **闸门先只报告、不失败。** 放弃，因为没有强制就无法阻止 C-* 和 E-* 期间的并行 PR 加回新特判；棘轮既不要求一次清零，又不允许增加。
- **现在就替换旧脚本。** 放弃，因为旧脚本现在是 `verify-core.sh` 和 Windows 边界脚本的门禁，F 完成前的覆盖面不能降低；两个脚本并存的代价只是多跑几秒。
- **Windows 等宿主支持插件后再迁移，跳过 legacy crate。** 放弃，因为 Windows 现在还直接调用 Core 的 Maven 和 Java 命令，不过渡就删不了 Core 里的代码。

## 验收标准

- 以下 PR 合入后，闸门能证明宿主里的 Java 内容只在白名单里：F 完成，`--strict` 通过。
- 每个纵向 PR（E1、D1、E2a-d）合入时，运行 `--update-baseline` 的结果与 PR 删除的内容一致，且 `--base` 检查通过。
- 中转的拒绝路径都有测试，且全部使用第二种工具（例如 Python、Go）的桩：被调方未导出、调用方未声明、任一方未启用、环路、超过深度和并发上限、超时、远程工作区。
- 旧的 `wrongPlugin` 与 `recursiveCall` 行为有不变的回归测试。
- 导入配置的完整流程可以复现：打开 Maven 工程 → jdtls 带着 Maven 提供的配置启动 → 修改 Maven 设置 → jdtls 收到新值；提供方超时时 jdtls 用默认配置启动，并显示哪个插件没有提供。
- 每个 PR 运行 `./scripts/macos/verify/verify-runtime-bundle-immutability.sh`；Windows 的 PR 运行 `cargo check --manifest-path windows/tauri/src-tauri/Cargo.toml`。

## 风险

- **闸门在 F 之前不能严格化。** Windows 的 334 个 TypeScript 文件和 14 个 Rust 文件现在都命中词表；F 切到 `--strict` 之前，要么 Windows 迁移完成，要么用户决定扩大白名单。
- **棘轮对存量热修有影响。** 给仍在使用的 macOS Java 路径修缺陷时，只要新增了词表命中，检查就会失败；需要同时删掉别处的命中，或等纵向 PR 搬走这段代码。
- **改名文件算新文件。** 移动或改名带 Java 词汇的文件，会被判为新文件而失败；需要先改内容，再改名，或在同一 PR 里更新 baseline 并说明。
- **按整词匹配有漏报。** `javac`、`javadoc`、`mvnw`、`gradlew`、`springframework` 不计入；目录裁剪列表里的 `.gradle` 会被当成工具名常量表；`shared.generated.ts` 带 Spring 字符串。这些要在 F 之前逐个核对。
- **中转的启动延迟。** 启动 jdtls 前要等提供方，超时就用默认配置，直到下一次变更才更新。要把超时定得足够短，并在状态栏里显示。
- **跨异步的调用链记录。** 环路检测要跨进程和请求，取消沿链传递容易遗漏，是 C-IMPORT 最需要测试的部分。
- **Windows 双份代码。** legacy crate 和 Java 插件的逻辑会同时存在一段时间，要靠真机冒烟防止两边行为分叉。
- **已存在的契约不一致，不是本拆分引入的，应由契约维护者先修：** schema 的 `buildSystems` 枚举只到 3，而 Core 和 README 都支持到 4；README 的能力表里 `serverProcess` 只写了 `1`，而正文已描述版本 2。

## 验证

本 PR 只新增脚本、测试、工作流和文档，没有改 Core、Swift 或前端业务代码。运行：

```bash
node --test scripts/architecture/verify-no-host-language-specifics.test.mjs
node scripts/architecture/verify-no-host-language-specifics.mjs
node scripts/architecture/verify-java-semantic-ownership.mjs
./scripts/agent-notes/verify-agent-notes.sh
```

后续 PR 按受影响边界运行 `./scripts/architecture/verify-core.sh`、`./scripts/architecture/verify-shared-contracts.sh`、`./scripts/rust-core/verify-rust-core.sh`、`./scripts/macos/verify/verify-runtime-bundle-immutability.sh`，修改后端协议时在 `lithe-plugin-docs` 运行 `node scripts/sdk-e2e.mjs`，合并后按[契约发布规则](../../implemented/architecture/2026-10-23-plugin-contract-publishing.md)同步契约副本。

## 适用范围

- `scripts/architecture/verify-no-host-language-specifics.mjs`
- `scripts/architecture/language-specifics-baseline.json`
- `scripts/architecture/language-specifics-allowlist.json`
- `.github/workflows/verify-host-language-specifics.yml`
- `rust/lithe-core/src/plugins/`
- `rust/lithe-core/src/lsp/interface/plugin_function.rs`
- `shared/contracts/plugins/v1/`
- `macos/Sources/`
- `frontend/editor/src/`
- `windows/tauri/src/`
- `windows/tauri/src-tauri/src/`
- `docs/development/macos-plugin-api-plan.md`
- 外部仓库：[lithe-plugin-docs](https://github.com/Lithe-IDEA/lithe-plugin-docs)、[lithe-plugin-java](https://github.com/Lithe-IDEA/lithe-plugin-java)、[lithe-plugin-maven](https://github.com/Lithe-IDEA/lithe-plugin-maven)、[lithe-plugin-gradle](https://github.com/Lithe-IDEA/lithe-plugin-gradle)
- 关联决策：[Maven/Java 领域插件迁移](2026-10-26-maven-java-domain-plugin-migration.md)、[插件依赖与导出](2026-10-25-plugin-dependencies-and-exports.md)、[Java 独立分发](2026-10-24-java-support-independent-distribution.md)、[公共扩展契约](2026-10-13-public-extension-contract-and-provider-api.md)、[编辑器扩展 API](../../implemented/architecture/2026-10-31-plugin-editor-extension-apis.md)、[契约发布](../../implemented/architecture/2026-10-23-plugin-contract-publishing.md)、[真实配置读写](../../implemented/architecture/2026-10-25-settings-native-configuration-editing.md)、[共享契约](../../../../shared/contracts/plugins/v1/README.md)
