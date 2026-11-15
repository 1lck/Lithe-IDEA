# Agent 笔记：Java 拆分用到的通用 API 与宿主语言闸门

状态：提议中

## 先说结论

Java、Maven、Gradle、JDT、Spring、MyBatis 的业务已经全部迁到插件仓库（[Issue #1495](https://github.com/1lck/Lithe-IDEA/issues/1495)），Viva 桌面端（`desktop/`）和 Rust Core 的生产代码不再有这些专属逻辑。本篇记录迁移用到的通用接口（都复用计划 API-01–44，不新增编号）、交付拆分和仍未完成的语言闸门（防止旧写法回来的验收脚本，目前尚未加入仓库）。之后宿主和 Core 的新代码仍不得引入这些专属词汇或名字判断。

## 问题

### 为什么保留这篇 Note

最初的 Maven/Java 静态迁移清单（宿主里有哪些入口、谁在调用、删除条件）已经归档，它只作为证据保留。它的交付拆分后来被调查改变了两件事：

1. 新增的通用接口要对齐用户的 API-01–44 计划，不再另起名字，所以按 API 条目划分基础设施，而不是按旧清单的“C2：最小领域能力”。
2. 删除工作要顾及所有平台的宿主，不能一删了之，需要先让通用接口可用，再逐项迁移。

本篇承接交付拆分、API 映射和闸门；迁移清单只保留历史证据，不再作为决策来源。

### 拆分前的状态（已达成的结果）

拆分前，宿主和 Core 在多处认识 Java：Core 的 JDT 与 Maven 模块及语言服务器引擎里的 JDT 分支，macOS 宿主的 Java 集成与测试结果服务，插件清单里按语言写死的字段（如 `hostIntegration: jdt`、`languageImport {kind}`），以及 Windows 宿主直接调用的 `maven.*`、`java.*`、`spring.index`、`mybatis.index` 等命令。

现在的状态：

- 桌面端生产代码（`desktop/internal`）没有 Java 或 Maven 的运行、导入、工具或测试分支。剩下的 Java 词汇只是语言目录数据和注释：[语法与语言规则](../../../../desktop/internal/editor/syntax/)、文本语法（`desktop/internal/editor/textmate`）和文件图标（`desktop/internal/fileicons`）。这些属于下文 Q3 的通用语言目录数据。
- Core 的插件清单 schema 里，`hostIntegration` 是保留字段：Core 不实现任何宿主集成，任何值都以 `plugin.integration.unsupported` 拒绝；清单 schema 中已没有 `languageImport` 字段。
- Core 的 crate 列表中没有 JDT、Maven 或 Java 专属 crate；插件函数中转由通用的 `plugin-function-relay` crate 提供。

判断标准只有一条：换一种语言插件（例如 Python 加 debugpy，或 Scala 加 Metals），宿主一行都不用改。这条标准已经由现有代码满足。

## 提案

### 一、通用能力对应计划条目，不新增编号

下表列出迁移依赖的通用能力。“旧路径”列是迁移前宿主或 Core 中写死的实现，已经迁出，不再存在于 `desktop/` 或 Core 生产代码中。通用接口的当前实现状态以[macOS 插件 API 计划](../../../../docs/development/macos-plugin-api-plan.md)为准。

| 计划条目 | 通用能力 | 迁移前写死的旧路径（已删除） |
| --- | --- | --- |
| API-12 | `jdt://` 做成通用的只读内容提供者：插件按 URI scheme 注册，宿主打开该 scheme 时调后端函数取内容；插件内部可用 API-25 的请求去向语言服务器取反编译结果。清单里不加 `virtualDocuments` | Core 和宿主里写死的 `jdt://` 读取路径 |
| API-19 | Maven 设置（settings 文件、本地仓库、Profiles）在 Maven 插件里读取、回显、写回，遵循[真实配置读写](../../implemented/architecture/2026-10-25-settings-native-configuration-editing.md) | Core 的 Maven settings 模块，以及设置页中由宿主专门渲染的 Maven 设置 |
| API-20 | 沿用已有的 `stateDirectory`、`workspaceStateDirectory`、`logDirectory`，只新增 `temporaryDirectory` | 宿主里为 JDT 工作区单独维护的状态目录 |
| API-22 | `languageServer/setStatus` 报告语言服务器准备状态；输出链接匹配器（清单声明正则，点击时调后端函数解析位置） | JDT 进度模块，以及控制台里的 Java 栈帧折叠 |
| API-23 | `run/start`、`run/stop`、工具 ID 引用（工具定义 ID，例如 `java`）、`requiresTools`。Run 会话比受管进程多一层宿主展示，评审时需写明 | 宿主里选择 Java 运行时的专属变量和启动模块 |
| API-25 | 插件后端的启动解析器（`launch.kind:"backend"`），以及后端向自己声明的语言服务器发送 request、notify 和设置状态；`languageServers 3` 只加会话字段。`editor/registerProviders` 只补上游确实缺失的能力（Spring、MyBatis） | 语言服务器引擎里的 JDT 分支、宿主集成目录，以及 Java、Spring、MyBatis 的专属语言模块 |
| API-26 | 诊断采用推送式 collection：插件只能写自己的 collection，带文档版本。不放进拉取式的 `registerProviders` | Java 诊断的专属通道 |
| API-27 | 编辑器动作扩展图标、`alternatives`、`reveal`；CodeLens；运行和测试标记。前端的 Java 运行标记类名统一为通用的编辑器动作类名 | Java 运行标记和入口识别模块 |
| API-29 | **不改协议。** 测试发现和运行已在 #1517 合入（`lithe/build/discoverTests`、`build.runTests`、`litheTestDiscovery`/`litheTestResults`），由 Maven 和 Gradle 插件提供 | Java 测试发现模块和宿主的 Java 测试结果服务 |
| API-30 | `debug/start`；`debugAdapters 3` 的 `features`、`defaults` | Java 测试调试的专属启动命令 |
| API-33 | `projectGenerators 2` 增加 `type:"tool"`，由后端动态注册 | 目录里写死的 Java 项目类型，以及宿主的 Java 引导；不做替代，由用户到商店搜索 |
| API-35 | 第一阶段：Core 中转插件函数调用，见下一节 | `languageImport {kind}`、构建层的导入模块、Maven 契约模块，以及宿主里专门的 Maven 配置刷新命令 |
| API-37 | 界面语言走 API-37 的环境信息，不在 workspace context 里加 `locale` | 无（避免多加一个字段） |

### 二、API-35 第一阶段：Core 中转的插件函数调用

背景：[插件函数契约](../../implemented/architecture/2026-10-20-plugin-function-contract.md)规定函数是插件私有的，后端不能请求宿主去调用别的函数（拒绝码 `plugin.function.recursiveCall`），也不能调用别的插件的函数（`plugin.function.wrongPlugin`）。Maven 的导入配置要给 Java 的 jdtls 用，必须有一条合规的跨插件通道。

做法：在 Core 里加一个中转，链路是插件 1 → Core → 插件 2。Core 中转由 [`plugin-function-relay` crate](https://github.com/Lithe-IDEA/Lithe-core-rust/tree/main/rust/crates/plugin-function-relay) 实现；桌面端只负责按启动解析器拉起被调方后端。

| 规则 | 内容 |
| --- | --- |
| 接收方显式导出 | 插件在清单里列出允许其他插件调用的函数 ID。没列出的函数仍然私有，`wrongPlugin` 行为不变 |
| 调用方声明函数 ID | 写函数 ID（相当于接口名），不写对方的插件 ID。安装和启用确认时，界面显示会匹配到哪些插件 |
| 发现 | 一个宿主方法列出当前工作区中已启用、并导出了某个函数 ID 的插件，按插件 ID 排序。调用方因此不必写死 Maven 或 Gradle |
| 调用 | `litheFunctions` 协议的版本号以 Core 的能力定义为准，新增版本与宿主请求（`lithe/host/functions/invoke`，参数为 `pluginID`、`functionID`、`params`）。旧的后端 `lithe/function/invoke` 仍然返回 `recursiveCall` |
| Core 检查 | 双方都已声明且都已启用；被调方后端没运行时由宿主按需启动，启动有时间上限；Core 记录调用链，被调方已经在链上（A→B→A）就拒绝；调用深度、并发数、参数和结果字节数、超时都有上限；取消沿调用链向下传 |
| 信任不传递 | 被调方用自己的权限执行，调用方不获得任何权限。被调方只能读到调用方的插件 ID。远程工作区按 API-40 明确拒绝，不静默在本机执行 |
| 错误码 | 每个新的拒绝原因占用一个新码，不复用 `wrongPlugin`、`recursiveCall`，并与其他已分配的错误码区间错开。具体数值以 Core 契约为准，不在本笔记里另行分配 |
| 不开放 | `lithe/build/*` 仍然对后端关闭，后端请求它一律返回 `recursiveCall` |

这一步**不是安装依赖**：它不参与安装闭包，不求解版本，装 Maven 不会强制装 Java，禁用 Java 只是让调用找不到提供方。因此 [插件依赖与导出](2026-10-25-plugin-dependencies-and-exports.md)里“第一版先不加入弱依赖、可选依赖和并存多版本”的规则不受影响。该 Note 的其余规则这一步照做：

- “导出是明确选择的契约”：只有清单列出的函数能被调用。
- “信任不沿依赖关系传递”：调用方不继承被调方的权限，反之亦然。
- “不能删除旧 `wrongPlugin` 或 `recursiveCall` 检查”：两个检查原样保留。
- “是否增加动态操作须由真实插件证明”：Java 的导入配置要在启动语言服务器时现算，是真实的动态计算，不能写成静态声明。这是第一个真实使用者。
- 不兼容的变更要换新的函数 ID（对应该 Note 的“导出契约版本”）。

该 Note 还要求每个导出写明可接受的调用上下文和所需授权，这一项在契约中定稿。依赖与导出那篇 Note 仍在 `proposed/`，待其落地时再更新。

SDK：三份官方后端 SDK（Node、Java、Rust）各自增加发现、调用和导出的类型化包装，位于 Core 仓库的 [`shared/plugins/sdk`](https://github.com/Lithe-IDEA/Lithe-core-rust/tree/main/shared/plugins/sdk)，与对应的 Core PR 一起交付。

### 三、Java 拆分怎样使用这个中转

#### 导入配置

纯 Java 工程没有“导入工程”这一步，jdtls 直接按源码目录工作；只有 Maven 和 Gradle 工程才有导入。所以导入配置的所有逻辑属于 Maven 和 Gradle 插件，Java 插件里不能有任何 Maven 或 Gradle 逻辑。

做法：

1. Java 插件定义一个接口函数 ID，例如 `languageImport.settings`。
2. Maven 和 Gradle 插件各自导出它，在自己的后端里计算 settings 文件、本地仓库、Profiles，以及写在自己状态目录里的派生 settings.xml；Gradle 计算 offline 和 gradleUserHome。
3. Java 插件在 `launch.kind:"backend"` 的启动解析器里，先发现并调用各提供方（带有界超时），再合并结果，只保留 jdtls 自己的键前缀 `java.configuration.maven.`、`java.import.maven.`、`java.import.gradle.`，通过 API-25 交给 jdtls（`initializationOptions`，或 `languageServer/notify` 发送 `workspace/didChangeConfiguration`）。
4. 超时或失败时，jdtls 用默认配置启动，状态栏显示是哪个插件没有提供配置，不阻塞打开窗口。
5. 用户修改 Maven 设置后，Maven 调用 Java 导出的变更通知函数，并在参数里直接带上新值。

不要这样做：

- Java 插件解析 `settings.xml` 或 POM，或者“看到 `pom.xml` 就读 Maven 配置”。
- 在 Java 导出的变更通知里回头调用 Maven 取值。Maven → Java → Maven 是环路，会被 Core 拒绝。
- Core 或桌面端里写“Maven 设置变了就推给 jdtls”。宿主只做中转，不认识 Maven 和 Java 这两个名字。

#### 测试运行

测试结果要显示在宿主原生的测试面板里。发现和运行本来就在 API-29 里，由 Maven 和 Gradle 插件提供；Java 插件的测试标记走 API-27。标记被点击后怎样请求构建插件运行某个测试，由 API-27 的编辑器动作落点决定。**不**把 `build.*` 开放给后端，**不**新增 `testControllers`。

### 四、版本与权限

| 能力 | 版本 | 说明 |
| --- | --- | --- |
| `serverProcess` | 3 | `launch.kind:"backend"` |
| `serverProcess` | 4 | `runSelectedRuntime.tool` 改为工具 ID |
| `languageServers` | 3 | 只放会话字段 |
| `debugAdapters` | 3 | `features`、`defaults` |
| `projectGenerators` | 2 | `type:"tool"` |
| `litheFunctions` | 4 | 宿主请求 `lithe/host/functions/*` |
| 清单里的导出和调用字段 | 新能力键 | 按 Core 的 `capabilities.rs` 命名习惯，从 1 起 |
| `pluginAPIVersion` | 仍是 4 | 新能力一律用 `requires.<key>` 的新版本门控；协议 3 内只增不改，新方法靠 `getCapabilities` 发现 |

每个新的宿主服务配新权限；新的错误码一码一义（见上）。版本号的权威定义在 Core 契约和 `capabilities.rs` 中，本表只作规划说明。

### 五、交付状态

| 交付单元 | 状态 |
| --- | --- |
| 通用能力（API-12、19、20、22、23、25、26、27、29、30、33、35 第一阶段） | 支撑了下面的宿主迁移；具体版本与状态以 API 计划和 Core 契约为准 |
| 宿主纵向迁移（JDT 启动、Maven/Gradle 导入与设置、运行与调试标记、测试、Spring/MyBatis、项目生成器的 Java 条目） | 已完成，宿主不再含 Java 代码（#1495） |
| 插件仓库（`lithe-plugin-java`、`lithe-plugin-maven`、`lithe-plugin-gradle`） | 已独立发布；Java 插件由普通插件身份 `io.github.lithe-idea.java-support` 分发 |
| 验收闸门（第七节）与旧脚本、旧基线的删除 | 未完成，仓库中尚无对应脚本 |

Windows 的 Java 调用不再需要过渡层：Windows 与 macOS 共用桌面端，宿主已不直接调用 Maven 或 Java 命令，因此原先为 Windows 设计的 legacy crate 不再需要。

### 六、旧 Java 名称的处理

旧运行配置（`javaMain`、`springBoot`、`mavenModule` 等）由插件命名空间的迁移接管。兼容读取保留两个稳定版后删除，并开 Issue 跟踪（Q8）。

### 七、验收闸门脚本（未加入仓库）

下面是闸门的设计。当前仓库中没有 `verify-no-host-language-specifics` 脚本，也没有对应的 baseline 或白名单文件；是否新增独立 CI 工作流需要先经维护者确认，不能自行加入。

扫描范围：`desktop/internal` 和 `desktop/cmd`（跳过测试数据、`vendor`、生成文件和以点开头的目录），以及 Core 仓库的 `rust/crates` 与 `shared/plugins/contract/v1/`。

检查什么：

- **词表**：把标识符和字符串按 camelCase、snake_case、`.`、`/`、`-` 切成词，命中 `java`、`jdt`、`jdtls`、`jvm`、`maven`、`mvn`、`gradle`、`spring`、`mybatis`、`lombok`、`junit`、`testng`、`m2e`、`surefire` 就计数。`JavaScript` 不算。它按整词匹配，所以 `javac`、`javadoc`、`mvnw`、`springframework` 不计入。
- **名字比较**：Go、Rust、TypeScript 里把某个值与带词表词的字符串字面量做相等比较，或者写成 `switch` 的分支，例如 `tool == "java"`、`case "maven":`。
- **工具名常量表**：Go 或 Rust 里的 `const`、`var` 字符串数组，内容列出词表词，或 `node`、`go`、`python` 这类工具名。按条目计数：这类表有几项就记几，所以给已有的表再加一个 `python` 也会让计数上升。
- **schema 封闭枚举**：Core 的 JSON schema 里，`tool`、`runtime` 属性用 `enum` 或 `const` 把取值写死，`languageImport.kind` 同样写死，以及每一个 `hostIntegration` 属性。按取值计数：`enum` 有几个成员就记几，`const` 记 1。这样已有枚举从 `["java", "node"]` 扩成 `["java", "node", "python"]` 也会被棘轮拦下。

三种模式：

| 模式 | 行为 |
| --- | --- |
| 默认（棘轮） | 读取 baseline。任何文件的计数上升、出现新文件（改名也算新文件）都失败；计数下降但没有更新 baseline 也失败，强制每个 PR 同步收紧 |
| `--update-baseline` | 把 baseline 写成当前计数，只允许下调；baseline 不存在时才可以创建 |
| `--strict` | 不看 baseline，任何命中都失败，只有白名单文件豁免 |

`--base <ref>` 把 baseline 和白名单与该提交里的版本对比：baseline 增长，或白名单新增条目，都失败。CI 用它防止有人靠改 baseline 放行。

白名单每项必须有 `{glob, reason, issue, removeWhen}`；没有被任何文件用到的条目算错误。预期的白名单对象是通用语言目录数据：共享语法、主题、语言规则和文件图标（即下文 Q3），以及 `desktop/internal/editor/syntax`、`desktop/internal/editor/textmate`、`desktop/internal/fileicons` 中的 Java 条目。白名单文件不计数，也不参与棘轮。

基线数字不在本笔记中固定：它们会随代码变化，应在闸门实际加入的 PR 中生成。

### 八、已定的待决项

| 编号 | 决定 |
| --- | --- |
| Q1 | 2026-11-05 改定：不再区分官方插件和普通插件，Java 插件和 Cargo、Maven、Gradle 一样是普通插件，ID 为 `io.github.lithe-idea.java-support`，vendor 为 `Lithe Community`，`signatureRequirement: "none"`，不再带发布者签名和 `packageTrust`，从外部仓库 [Lithe-IDEA/lithe-plugin-java](https://github.com/Lithe-IDEA/lithe-plugin-java) 构建，由 Lithe Store 自动收录。工具短 ID `java` 保留。前置的两件事都已完成：(a) 宿主不再按 ID 命名空间判定 `languageServers[].hostIntegration` 的官方身份；(b) 普通插件可以定义不带 `:` 的短工具 ID，`toolchains.registry` 不再接收 `verifiedOfficial`，多个已启用插件定义同一短 ID 时按“争用即不归属”处理（见[插件注入工具链](2026-10-31-plugin-injected-toolchains.md)第 2 节）。旧 ID `dev.lithe.plugin.java-support` 按 [#1357](https://github.com/1lck/Lithe-IDEA/pull/1357) 迁移 Go 和 PHP 的做法处理：保留在官方插件目录并填写 `communityReplacementID`，引导用户换装新 ID。这项迁移推迟到 lithe-plugin-java 发布第一个正式 Release 时再做，否则会把用户引向不存在的插件 |
| Q2 | 旧版 Java 支持插件必须更新，不保留兼容翻译 |
| Q3 | 共享前端内置的 TextMate 语法、主题、语言规则和文件关联里的 Java 项，算通用语言目录数据，属于闸门白名单 |
| Q4 | 作废：不做商店索引 v2 |
| Q5 | 三份 SDK 都有通用 `hostRequest`，并为每组 API 提供类型化包装 |
| Q6 | 原计划的 Windows 过渡层取消：Windows 已由桌面端统一，不再需要 legacy crate（见第五节） |
| Q7 | 控制台栈帧链接改为通用的输出链接匹配器（API-22）；JVM 性能面板改为插件原生界面 |
| Q8 | 旧运行配置的兼容读取保留两个稳定版，开 Issue 跟踪删除 |

## 考虑过的备选方案

- **在计划之外新增三个 API 编号。** 曾设想把“后端请求自己的语言服务器”“测试控制器”“商店按文件类型推荐插件”各记一个新编号。用户决定不加新功能、不另起编号，这三项分别并入 API-25、API-29（已有 #1517 的测试能力）和不做，所以计划保持 API-01–44。
- **`buildSystems 5` 加 `languageImport.exports`，再加 `buildImportConsumers`。** 为导入配置新开一条专用通道。放弃，原因是 `buildSystems` 的 `modelSharing` 已能共享构建选项，专用通道只服务一个用例；通用的函数中转可以服务以后的其他插件组合。
- **`buildModelInputs 2`。** 让没有构建系统的语言插件也能读构建模型输入。放弃，因为它要求 Java 插件读 Maven 的选项，Java 插件里就会有 Maven 逻辑。
- **声明式关联：Maven 声明“当 Java 启用时推送 settings”，宿主转发。** 放弃，因为宿主会变成 settings 的专用转发器，被关联方还要声明键前缀；通用的函数中转更简单，也不需要宿主理解 settings。
- **把 `build.*` 开放给后端（`lithe/host/build/*`）。** 放弃，因为契约规定后端请求 `lithe/build/*` 一律返回 `recursiveCall`，这条保护不改；Java 要触发测试时走中转，由构建插件自己决定。
- **把导入关联做成安装依赖。** 放弃，因为装 Maven 不应强制装 Java，且依赖 Note 明确第一版不做可选依赖。中转只在运行时发现已启用的提供方。
- **`testControllers` 和独立的测试控制器契约。** 放弃，因为测试发现和运行已在 API-29 里，Java 的测试标记走 API-27，再加一套控制器会形成第二个测试契约。
- **商店索引 v2 和按文件类型推荐插件。** 放弃，宿主里写死的 Java 引导已删除，用户到商店搜索。
- **闸门先只报告、不失败。** 放弃，因为没有强制就无法阻止并行 PR 加回新特判；棘轮既不要求一次清零，又不允许增加。
- **Windows 等宿主支持插件后再迁移，跳过过渡层。** 放弃，因为当时 Windows 还直接调用 Core 的 Maven 和 Java 命令，不过渡就删不了 Core 里的代码。现在 Windows 已统一到桌面端，问题不再存在。

## 验收标准

- 已满足：桌面端生产代码和 Core 的生产代码不含 Java、Maven 的运行、导入、工具或名字判断逻辑；剩下的 Java 词汇只在语言目录数据和注释中。
- 已满足：插件清单 schema 不再有按语言写死的 `languageImport` 字段，`hostIntegration` 是保留字段，任何值都被拒绝。
- 未满足：闸门脚本加入仓库，并以 `--strict` 通过（第七节的白名单范围内除外）。加入前不得声称闸门已经生效。
- 每个新增或修改宿主方法的 PR，都在描述中列出对应的 API 编号，并保留[插件协议更新记录](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/shared/plugins/reference/protocol-changelog.md)的同步。
- 中转的拒绝路径有测试，且全部使用第二种工具（例如 Python、Go）的桩：被调方未导出、调用方未声明、任一方未启用、环路、超过深度和并发上限、超时、远程工作区。这部分测试在 Core 仓库中验证。
- 旧的 `wrongPlugin` 与 `recursiveCall` 行为有不变的回归测试。
- 导入配置的完整流程可以复现：打开 Maven 工程 → jdtls 带着 Maven 提供的配置启动 → 修改 Maven 设置 → jdtls 收到新值；提供方超时时 jdtls 用默认配置启动，并显示哪个插件没有提供。
- 每个相关 PR 运行 `./scripts/desktop/verify/verify-runtime-bundle-immutability.sh`，并在改动的 Go 包上运行 `scripts/desktop/desktop-go.sh test`。

## 风险

- **闸门在严格化之前不能阻止回退。** 没有闸门时，只能靠评审发现新增的专属分支；闸门加入后仍要核对词表误报，例如 `.gradle` 这类目录裁剪列表可能被当成工具名常量表。
- **棘轮对存量热修有影响（若采用闸门）。** 给仍在使用的代码修缺陷时，只要新增了词表命中，检查就会失败；需要同时删掉别处的命中，或在同一 PR 里更新 baseline 并说明。
- **改名文件算新文件（若采用闸门）。** 移动或改名带 Java 词汇的文件，会被判为新文件而失败；需要先改内容，再改名，或在同一 PR 里更新 baseline 并说明。
- **按整词匹配有漏报。** `javac`、`javadoc`、`mvnw`、`gradlew`、`springframework` 不计入，要在严格化前逐个核对。
- **中转的启动延迟。** 启动 jdtls 前要等提供方，超时就用默认配置，直到下一次变更才更新。要把超时定得足够短，并在状态栏里显示。
- **跨异步的调用链记录。** 环路检测要跨进程和请求，取消沿链传递容易遗漏，是中转最需要测试的部分。
- **Core 契约的枚举与 schema 可能不一致。** 早先记录的 `buildSystems` 枚举与 Core 能力版本不一致的问题，需要对照当前 Core 契约复核后再修，不由本拆分引入。

## 验证

本篇只涉及文档和设计，当前可以运行的检查：

- `./scripts/agent-notes/verify-agent-notes.sh`：中文笔记格式、生命周期、链接与路径。
- `./scripts/desktop/verify/verify-runtime-bundle-immutability.sh`：安装包资源的运行时写入边界（涉及运行时资源的 PR 必须运行）。
- `scripts/desktop/desktop-go.sh test ./internal/editor/syntax/... ./internal/fileicons/...`：语言目录数据相关的桌面端测试（改动这些包时运行）。

闸门加入后，其测试与检查命令写在加入它的 PR 中；契约、指南和 SDK 的改动在 Core 仓库根运行 `node shared/plugins/scripts/verify-docs.mjs`，修改后端协议时运行 `node shared/plugins/scripts/sdk-e2e.mjs`。

## 适用范围

- `https://github.com/Lithe-IDEA/Lithe-core-rust/tree/main/rust/crates/plugin-function-relay`
- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/shared/plugins/contract/v1/`
- `docs/development/macos-plugin-api-plan.md`
- `https://github.com/Lithe-IDEA/Lithe-core-rust/tree/main/shared/plugins/sdk`
- `desktop/internal/editor/syntax/`
- `desktop/internal/editor/textmate/`
- `desktop/internal/fileicons/`
- `desktop/internal/pluginhost/`
- 外部仓库：[lithe-plugin-java](https://github.com/Lithe-IDEA/lithe-plugin-java)、[lithe-plugin-maven](https://github.com/Lithe-IDEA/lithe-plugin-maven)、[lithe-plugin-gradle](https://github.com/Lithe-IDEA/lithe-plugin-gradle)
- 关联决策：[插件依赖与导出](2026-10-25-plugin-dependencies-and-exports.md)、[公共扩展契约](2026-10-13-public-extension-contract-and-provider-api.md)、[编辑器扩展 API](../../implemented/architecture/2026-10-31-plugin-editor-extension-apis.md)、[契约发布](../../implemented/architecture/2026-11-11-plugin-contract-single-source-in-core.md)、[真实配置读写](../../implemented/architecture/2026-10-25-settings-native-configuration-editing.md)、[插件注入工具链](2026-10-31-plugin-injected-toolchains.md)
- 已归档的历史材料（不作为本篇依据）：Maven/Java 静态迁移清单、Java 独立分发决策
