# Agent 笔记：插件自有语言服务器会话与后端决定启动方式

状态：已实现

## 先说结论

语言插件现在可以拥有自己的语言服务器：插件后端在每次启动时告诉 Lithe 用哪个程序、带什么参数，之后由后端通过三个宿主方法（`lithe/host/languageServer/request|notify|setStatus`）向这个服务器发请求、发通知并上报“准备到哪一步了”。请求能不能发、要不要排队、等多久、远程能不能用，全部由 Rust Core 按插件声明的会话策略（session policy，插件写在清单里的规则）裁决；Swift 只负责把请求送进去、把进程启动起来、把状态显示出来。

这是为了让 Java 这类语言的特殊逻辑能整体搬进插件仓库，宿主不再按语言名写分支。本篇只建立基础设施，不删除任何旧的 JDT 路径，Windows 仍走旧路径。开发者以后新增“某语言服务器需要特殊启动或准备”的需求时，应该先扩展这条通用通道，而不是在宿主里认出语言名。

## 问题

旧做法里，宿主为 Java 内置了一整套东西：用 `hostIntegration: jdt` 选启动方式，Java 专属的工作区状态目录与清理，Java 项目准备状态条，以及判断 Maven/Gradle 命令来串行请求。这些逻辑只对一种语言成立，却写在通用的会话管理里，插件无法复制，也无法在不改宿主的前提下换语言。

要让它们变成插件自己的东西，缺三样公共能力：插件后端没有办法在每次启动时决定怎么启动服务器；没有办法向自己的服务器发请求并受宿主管控；没有办法在准备期间（导入构建、建索引，往往比任何一次调用都长）向用户汇报进度。

## 决策

### 后端经三个宿主方法使用服务器，规则由 Core 执行

- 后端发 `lithe/host/languageServer/request`（带请求方法、参数、可选超时）得到 `{value}`，发 `notify` 得到 `{delivered}`，发 `setStatus` 得到 `{}`。清单权限 `languageServer.request` 展开成这三个具体方法的授权；未授权的方法返回 `plugin.host.permissionDenied`，不认识的参数返回 `plugin.host.unsupportedOption`。
- 一个服务器的 ID 就是它的语言 ID。后端只能操作自己插件声明的服务器；操作别人的服务器得到“不是你的贡献”。
- Core 在会话里执行策略：请求方法白名单、门控（gates，服务器没准备好时拒绝请求）、串行命令（同一类命令一次只跑一个，后来者合并等待）、超时（默认 60000 毫秒，最长 300000）、排队上限（128 个，之后返回 `busy`），以及 `remote: "unsupported"` 的远程拒绝。Swift 不复制这些规则，也不认识任何语言的方法名。
- 新增四个错误码，一码一义：`-32022` 服务器不可用、`-32023` 服务器自己报错（原始错误放 `details`）、`-32024` 方法未在清单声明、`-32026` 不是你的贡献。超时、取消、`busy`、超限、前置条件失败复用已有码。`-32025` 属于运行调试 API，`-32027` 到 `-32030` 属于另一个 PR，本篇不使用。Swift 侧对应 `plugin.host.languageServerUnavailable|languageServerError|methodNotDeclared|foreignContribution`；宿主不认识的码到后端时变成 `plugin.host.failed`。
- 版本：`languageServers` 升到 3（会话字段），`serverProcess` 升到 3（`launch.kind:"backend"`），`pluginAPIVersion` 保持 4。

### 会话代际（generation）和中继

服务器每次启动是一代。`PluginLanguageServerRelay` 为每个服务器记住当前活着的那一代，把状态变化（`starting`、`running`、`stopped`、`crashed`）和服务器转发的通知以 `lithe/host/languageServer/didChangeState` 与 `didReceiveNotification` 送给后端；旧一代进程晚到的消息直接丢弃，所以后端不会把已经被替换的进程的消息当成现在的。是否真的送达，仍由后端的权限授权决定。

### 准备状态用 `setStatus`，不复用进度

`lithe/function/progress` 属于一次正在运行的函数调用，调用结束它就没了。而准备（导入构建、索引）可能在任何调用之外持续很久。所以 `setStatus` 是服务器级的：状态 `preparing|ready|degraded|failed`、一段不超过 1024 UTF-8 字节的文字（按字符边界截断）和 0 到 100 的百分比。状态随该进程结束，不留到下一代；服务器不在运行时调用 `setStatus` 会得到 `languageServerUnavailable`，调用别人的服务器得到 `foreignContribution`。宿主界面（`PluginServerStatusView`）只显示插件自己写的文字，插件没写时才用宿主的中性兜底文案，经 i18n 输出，不含任何语言或工具名。

首版不提供 `actions`（状态上的按钮）和 `{done,total}` 进度，只有百分比。

### 后端决定启动方式：两步，Core 在两步里都把关

1. `plugins.declarative.languageServerLaunchPlan` 返回“问题”：要调用的后端函数、超时（默认 30000）、`resolveParams`（服务器 ID、平台、各个宿主目录、设置）和必须先创建的目录。宿主创建目录，调用后端函数，参数里再加上 `context`。
2. `plugins.languageServers.decodeLaunch` 把后端的回答交给 Core 校验：可执行文件必须是包内文件（`packaged`）或清单声明过的工具（`tool`），路径不得越出插件包，可写路径必须在宿主允许的目录内，参数、环境、初始化选项有字节上限。拒绝时给出 `plugin.launch.invalidResult|outsidePackage|undeclaredTool|unwritablePath|invalidRequest|unavailable|notBackend` 之一。

校验放在 Core 而不是 Swift，是因为这些规则不含平台差异，Windows 将来会用同一份。宿主只做它必须做的 I/O：创建目录、调后端、按 Core 给的计划启动进程。

- 工具类可执行文件通过宿主已有的工具链解析（工程内代码提供的工具被拒绝，不会从项目目录里启动程序）。包内文件在启动前确认存在且可执行。
- 每次启动的临时目录在会话结束或启动失败时回收；启动期间工作区上下文已失效则以取消结束。
- 远程工作区：Core 对声明 `remote: "unsupported"` 的服务器拒绝；后端启动的服务器在 macOS 上目前一律拒绝远程根，避免在远端用本机路径。
- 服务器本体随插件包签名分发，运行时不下载、不解压到应用包内，遵守发行包只读边界。

### 内容提供者（API-12）取代专属虚拟文档

语言服务器返回的 jar 内源码等虚拟文档地址，旧做法是宿主里写死的 Java 虚拟文档。现在插件后端用 `lithe/host/documents/registerContentProvider`（权限 `documents.contentProvider`）为一个 scheme 注册一个函数，宿主打开该 scheme 的地址时调用 `{context, uri}`，答案是字符串或 `{content}`，不超过 1 MiB，由 Core（`plugins.contentProviders.decode`）校验。每个窗口每个 scheme 只能有一个提供者。

### 工作区状态与回收（API-20）

服务器的每个工作区状态目录在 `Application Support/Lithe/PluginState/<插件>/<语言>/workspaces/<工作区路径的 SHA-256>/`，不在包内也不在缓存里，禁用或更新插件后保留。Core 决定回收哪些：宿主把“目录名与最后使用时间”列给 `plugins.languageServers.stateRetention`，Core 按插件声明的 `state.retention`（`maxEntries`、`maxAgeDays`）返回过期名字，打开中的工作区永远不回收，不是单个路径分量的名字被忽略。Swift（`MacPluginLanguageServerWorkspaceState`）只列真实目录、删除 Core 点名且自己列过的名字，文件和符号链接不算状态，不会跟随删除。

“最后使用时间”只用目录自身的修改时间：服务器写的是更深层的文件，不会更新它，所以每次由后端启动服务器时宿主会刷新一次。回收在启动之后后台运行，失败只是不回收，不影响这次启动，下次启动会重新清理。插件没有声明 `retention` 就什么都不删。

另有 `reset`（丢弃一个工作区的状态，服务器下次启动重建）。目前它只有引擎入口 `rebuildWorkspaceState`，没有面向用户的菜单或确认界面。

### 旧 JDT 路径与新通道的对应

这些旧路径本篇全部保留，由后续 E1 移除，Windows 由 W2 迁移。

| 旧 JDT 专属做法 | 新通用通道 |
| --- | --- |
| Java 虚拟文档（jar 内源码） | 内容提供者（API-12） |
| `is_java_build_command` 判断串行 | 会话策略的串行命令 |
| `java_configuration_running` 拒绝请求 | 会话策略的门控 |
| Java 项目准备状态条 | `setStatus`（API-22）和通用状态视图 |
| 引擎里按名字 `java` 的远程检查 | 清单 `remote: "unsupported"` |
| `MacJdtWorkspaceState` 与 `jdtCacheRetention` | `state.retention` 与 `plugins.languageServers.stateRetention` |
| `hostIntegration: jdt` 启动 | `launch.kind:"backend"` 的后端启动 |

## 考虑过的备选方案

- 继续按语言加 `hostIntegration` 值：每种有特殊准备的语言都要改宿主，违背“插件专属逻辑不进宿主”，拒绝。
- 让后端直接连服务器的管道：绕过 Core 的白名单、门控、串行与代际检查，也让取消和超时无处执行，拒绝。
- 复用 `lithe/function/progress` 报准备状态：它随调用结束而消失，准备过程不属于任何调用，拒绝。
- 在 Swift 里校验后端的启动回答：规则无平台差异，Windows 会重写一份并漂移，改放 Core。
- 回收规则放 Swift：同样会在两个平台各写一次；改为 Core 决定、平台只做目录 I/O。
- 用清单字段 `virtualDocuments` 声明虚拟文档：声明不了“内容怎么取”，最终还要函数，所以直接做成注册内容提供者。
- 运行时下载服务器：改写发行包基线，破坏代码签名和 Sparkle 增量更新，违反只读边界，拒绝；服务器随插件包构建期固定。

## 后果

收益：语言插件可以用同一套通道准备、启动、使用自己的服务器，宿主代码里没有语言或工具的名字；规则在 Core 一处，Windows 迁移时直接复用；插件包签名之外没有运行时写入发行目录。

代价与已知缺口：

- 宿主多了一条后端到服务器的转发路径，需要保持代际和授权检查正确。
- 远程工作区上由后端启动的服务器暂不支持；转发通知很多时可能撑满后端的 128 项队列；后端晚于服务器启动时不会补发一次 `running`。
- 服务器关闭超时也按 `crashed` 上报；内容提供者每次导航都重新取；取消串行命令的领头请求也会取消并入的请求。
- 宿主附带 `tools` 参数尚未发送；工程内选择的工具会使工具类启动失败而不是回退；LSP 控制中心与工具设置不显示后端启动服务器的可执行文件。
- 没有用户可见的“重置语言服务器状态”入口；回收只在后端启动时触发，失败静默。
- 本篇不删除任何 JDT 专属代码，旧路径与新通道会并存到 E1。

## 验证

- `cargo test --manifest-path rust/Cargo.toml -p lithe-core --lib` 按 `plugin_server`、`plugin_function`、`language_server_sessions`、`content_providers`、`declarative` 过滤：会话策略、逐方法授权、启动问题与回答的往返、七类拒绝码、回收判定。
- ~~scripts/macos/test/test-macos.sh --filter 'PluginLanguageServerHostServiceTests|PluginBackendLaunchTests|PluginContentProviderTests|MacPluginLanguageServerWorkspaceStateTests'~~（随旧客户端移除），以及 `LitheLanguageIntelligenceModuleTests` 中的 `PluginLanguageServerRelayTests`：参数边界、错误码映射、启动流程、代际丢弃、状态随进程结束、回收不触碰打开中的工作区和非目录项。测试用 Metals 与 rust-analyzer 的桩，不含 Java 词汇。
- `scripts/desktop/verify/verify-runtime-bundle-immutability.sh`：启动后包内文件不变。
- ~~scripts/architecture/verify-shared-contracts.sh~~（脚本已随旧客户端移除）、~~scripts/architecture/verify-service-boundaries.sh~~（随旧客户端移除）、~~scripts/architecture/verify-no-host-language-specifics.mjs~~（随旧客户端移除）。
- `scripts/agent-notes/verify-agent-notes.sh`、`scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`。

原生验收（安装示例插件、观察状态栏文字、用 `pgrep` 确认进程不残留）不由单元测试替代，功能矩阵按真实证据维护。

## 适用范围

- Lithe-core-rust 锁定修订：[rust/lithe-core/src/lsp/interface/plugin_server.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/lsp/interface/plugin_server.rs)
- Lithe-core-rust 锁定修订：[rust/lithe-core/src/lsp/interface/plugin_function.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/lsp/interface/plugin_function.rs)
- Lithe-core-rust 锁定修订：[rust/lithe-core/src/plugins/language_server_sessions.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/plugins/language_server_sessions.rs)
- Lithe-core-rust 锁定修订：[rust/lithe-core/src/plugins/content_providers.rs](https://github.com/Lithe-IDEA/Lithe-core-rust/blob/0ffd327b4329261e393b08ed76fbd134b4dd17e9/rust/lithe-core/src/plugins/content_providers.rs)
- `https://github.com/Lithe-IDEA/Lithe-core-rust/blob/main/shared/plugins/contract/v1/README.md`
- ~~`macos/Sources/Lithe/Application/Features/PluginLanguageServerHostService.swift`~~（已随 #1794 移除）
- ~~`macos/Sources/Lithe/Application/Features/PluginContentProviderHostService.swift`~~（已随 #1794 移除）
- ~~`macos/Sources/Lithe/Models/AppModel/AppModel+PluginLanguageServers.swift`~~（已随 #1794 移除）
- ~~`macos/Sources/Lithe/Platform/MacOS/Plugins/MacPluginBackendLaunchPreparer.swift`~~（已随 #1794 移除）
- ~~`macos/Sources/Lithe/Platform/MacOS/Plugins/MacPluginLanguageServerWorkspaceState.swift`~~（已随 #1794 移除）
- ~~`macos/Sources/LitheLanguageIntelligenceModule/Services/PluginLanguageServerRelay.swift`~~（已随 #1794 移除）
- ~~`macos/Sources/Lithe/Views/Workbench/PluginServerStatusView.swift`~~（已随 #1794 移除）
- `docs/development/macos-plugin-api-plan.md`
