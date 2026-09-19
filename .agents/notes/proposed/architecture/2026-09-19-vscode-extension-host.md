# Agent 笔记：VS Code 扩展宿主复用 Theia 插件侧

状态：提议中

## 先说结论

为了让未经修改的 VS Code 扩展（首批是 `redhat.java` 和 `vscode-java-debug`）使用 Lithe 自己的编辑器、文件和命令能力，Lithe 新增一个独立的 Node 进程，叫扩展宿主（Extension Host，运行扩展代码的进程），代码在 `extension-host/`。宿主原样复用 Theia 的“插件侧”，也就是扩展看到的 `vscode.*` API 对象；Theia 的“主进程侧”（`*Main`，原本由 Theia 工作台实现）换成 Lithe 自己写的实现，两侧在同一个进程里用内存通道连接。Lithe 只通过 `shared/contracts/vscode-extension-host.md` 定义的 JSON 协议和宿主通信，Theia 的内部类型不会越过进程边界。这是 #737 的原型，产品暂未启动它。

## 问题

#692 说明，Java 的导入、构建、classpath、重复运行和取消，如果由 Lithe 拆开调用 JDT LS 命令后自己再拼起来，就要重新实现一遍工程语义。成熟的 Java 扩展已经把这些流程做完整了，但它们只能跑在实现了 VS Code API 的宿主里。

完整 Theia 的实验（见 #737）已经证明扩展能跑起来，但那样等于在 Lithe 里藏了第二套 IDE：两份工作台、两份文档状态，内存也很高。直接移除 Theia 的工作台模块又无法启动。所以真正要回答的问题是：能不能只拿走 Theia 实现 VS Code API 的那一半，另一半换成 Lithe。

## 提案

### 进程与分层

```text
未经修改的扩展 ─ vscode.* ─> Theia 插件侧（npm 包，原样使用）
                                  │ Theia 内部 RPC，仅在进程内
                             extension-host/src/main-side/*（Lithe 的 *Main 实现）
                                  │ stdin/stdout 上的 JSON，见 shared/contracts
                             Lithe 监管方（macOS / Windows 平台适配层）
```

- Theia 插件侧（`src/plugin/`，约 3 万行）几乎只依赖 `common`/`node` 代码，只有两处引用浏览器模块，而且都不在运行路径上，所以可以从 npm 原样使用，不 fork、不打补丁。Theia 自带的 `plugin-host-module` 在加载时就会创建进程 IPC 通道，因此 `src/theia/plugin-host-container.ts` 按相同的绑定复制了一份，只把通道换掉；升级 Theia 版本时要对照这份绑定。
- 主进程侧的 50 个 `*Main` 接口由 `src/main-side/` 实现。已经实现的：命令、文档（打开、编辑、保存）、消息、进度、日志、存储、环境、`workspace.fs`（`file:`）、`findFiles`、工作区信任。其余接口都会注册成“明确报错”的代理：扩展收到带接口名的错误，Lithe 收到一次 `lithe/unsupportedApi`。每个扩展的兼容清单就由这些上报累积出来，任何接口都不许返回假成功。
- 协议是 Lithe 自己定义的：URI 字符串、从 1 开始的行列号、稳定的错误码、双向请求、取消和截止时间。

### 状态归属

- **文档**：内容、版本、脏状态和保存都以 Lithe 为准。宿主只保存一份按版本校验的镜像，版本不递增的变更会被拒绝（`staleDocumentVersion`）。扩展调用 `applyEdit` 时由 Lithe 执行编辑，Lithe 必须先发出 `host/documentChanged` 再回复，这样扩展在 `await` 之后就能读到新内容。
- **激活**：宿主从不自行激活扩展，`*`、`onStartupFinished` 也由 Lithe 发出。这样安全模式、禁用和不可信工作区都能阻止扩展代码运行。
- **配置**：默认层从已加载扩展的 `contributes.configuration` 确定性地计算出来，上面依次叠加 Lithe 默认值、用户设置和工作区设置。JDK 等工具链由 Lithe 通过配置传入，例如 `java.configuration.runtimes`；扩展不去读系统环境。
- **进程**：宿主跟踪扩展创建的所有子进程；shutdown 时如果扩展停用超时，先发 SIGTERM，3 秒后再发 SIGKILL。监管方把宿主放进独立进程组（POSIX）或 Job Object（Windows），结束整棵进程树，以覆盖孙进程和宿主崩溃的情况。
- **Java 工程语义**：项目模型、classpath、构建和启动准备仍然由扩展和它自带的 JDT LS / Java Debug 负责，Lithe Core 不复制这些逻辑。

### 分发、默认状态与迁移顺序

2026-09-19 用户选择先推进语言功能与诊断（M2），平台闭环（M1）仍是前置条件。
首批扩展从 Open VSX 获取固定版本并校验，随 Lithe 安装包分发，不在首次打开
工程时依赖网络下载。这样同一产品版本的兼容组合可以复现，也可离线启用。

Java 插件的产品目标是内置、默认启用、可禁用、按需激活。默认启用不代表
应用启动时就创建 Node/JDT LS；禁用、安全模式和工作区信任仍在启动前检查。
迁移期间扩展链路必须显式选择，通过兼容验收前继续使用原有 provider。
切换时先等待旧 provider 完整停止，再启动新 provider，不能同时保留两套会话。
切换前先校验安装包资源；资源缺失时不停止健康的旧 provider。确认资源可用后，
语言会话管理器先占用语言的启动权，再等待现有 Java 模块完成关闭，并核对旧会话已停止。
编辑器、导入和 Run/Debug 都在共同的会话创建入口检查这份占用，所以关闭过程中的重入
也不能再次启动旧会话。新宿主初始化失败时会清理占用，允许用户回退。

宿主停止时先撤销 provider 和诊断，只有进程组确认清理成功后才释放语言占用。
IPC 关闭、扩展注销或发送停止信号都不代表进程已经退出。若清理失败，继续阻止旧
provider 启动；模块仍持有资源供后续重试。语言模块的休眠检查也计入这种占用。
工作区关闭入口同步发起由会话持有的清理任务，模块退出会等待该任务完成。
禁用 Java 也通过同一入口停止宿主。协议管道关闭或写入失败时，即使 Node 进程尚未
退出，会话也会主动清理整个进程组；不能只撤销编辑器能力后等待进程自行结束。


接受受管 Node 运行时依赖，按平台与架构随包内置并锁定校验值；用户无需
安装系统 Node。受管资源清单固定 Node 22.23.2（22 系列安全更新版），
更新时必须重新验证 Node、Theia 和扩展的组合。
安装体积、全部相关进程的内存和冷温启动成本仍需测量，接受依赖不表示预算已通过。
运行时从 Open VSX 自动下载可以减小初装体积，但会增加首用网络故障和版本漂移，
本阶段不采用。也不使用用户 PATH 上任意 Node 作为产品运行时。

Swift 侧新增 `ExtensionHostConnection` 负责双向 NDJSON、取消、截止时间与关闭失败。
macOS 的 `MacExtensionHostTransport` 复用 `MacManagedProcess` 的原子进程组启动，
管道写入在独立队列以非阻塞描述符和截止时间执行。它们目前是平台接入基础，
`ExtensionHostSession` 作为模块资源登记到 `ExtensionHostModule`，Java 扩展预览项已进入
现有插件管理目录；禁用或安全模式不构造宿主，重新启用时创建新的会话。
模块激活现在通过 `MacExtensionHostResources` 读取安装包里的相对路径清单，定位对应架构的
受管 Node、宿主入口和扩展目录，再等待宿主初始化。没有资源、初始化失败或扩展加载失败
都会报错并清理会话，不导出看似可用的能力。全局状态与按规范工作区 URI 隔离的状态目录
位于平台应用支持目录；不会搜索用户 PATH 来弥补缺失 Node。资源适配器仍默认不受信任，
产品启动先验证资源，再展示工作区信任确认；取消、没有可用窗口或正在关闭时不会创建
宿主，也不会停止旧 Java 服务。信任仅用于本次宿主激活，不自动授予父目录或其他工作区。
随后通过现有运行时服务准备随包 JDK 21，以 `java.jdt.ls.java.home` 指定 JDT LS 的运行 JDK；
项目配置的 SDK 通过 `java.configuration.runtimes` 传入，同一执行环境优先使用用户选择。
无效的显式项目 SDK 会报错，不静默替换成随包 JDK。准备任务本身也登记为模块资源，
关闭工作区和调用者取消都能终止等待信任或运行时准备的阶段。初始化仍不会自动激活扩展。
准备期间项目设置发生变化时丢弃旧 JDK 配置。相关启动、取消、Java 8/17/21 配置
与既有语言会话回归共 61 个 Swift 测试通过。后续运行时与宿主回归共 64 个测试通过，
覆盖并发激活只构造一次、挂起激活及依赖启动期间禁用、清理失败阻止重启与禁用重试。
真实编辑器激活入口尚未接通；重开工作区并发及真实 Java 工程仍需产品验收，
不能以准备资源和模块运行时的单元测试替代。
制品准备脚本现从固定校验和下载 Node 和两个 Open VSX 通用扩展包，
在独立目录按锁文件安装生产依赖，保留原始许可证和源码来源。
不能复制开发目录的 `node_modules`，否则会夹带本机编译产物并破坏双架构分发。
下载缓存每次使用前重新校验，失败的准备只清理临时目录，不覆盖已有制品。
安装包通过 `LITHE_EXTENSION_HOST_ROOT` 显式包含预览资源；普通构建的默认分发仍待
产品验收后切换。手动 CI 验证真实制品，普通 PR 测试继续使用轻量测试扩展。
新增启动配置、模块初始化失败清理等用例后，17 个宿主相关 Swift 测试通过；
其中真实 Node 测试仍使用显式注入的开发资源，不能视为安装包分发验证。
当前尚未把编辑器激活路由切到该能力，不能仅凭目录项宣称 M1 产品接入完成。

`ExtensionHostDocumentBridge` 使用现有 `EditorDocument` 和文档功能模型的保存流程。
扩展编辑先锁定、同步远程编辑器，再验证全部目标和版本，最后一次性修改；
任意文档过期时整批拒绝。发出文档变更和保存通知后才回复成功，避免扩展读到
保存前的镜像。缓存只记录已发给宿主的版本和文本，不作为执行编辑或保存的权威来源。
真实 Node 测试扩展已通过 Swift 监管方完成编辑、保存到磁盘和关闭资源；
文档功能模型现在同步发布打开、变更、保存和关闭事件。桥接器在回调中捕获
不可变文本快照，按顺序发送；不能让异步任务之后再读取可能已经变化的文档对象。
保存事件只在当前缓冲区已成功写盘且变为干净状态时发出，写盘期间出现新编辑
不算当前内容已保存；相同版本的扩展保存回应和产品事件会去重。
工作区重置与干净预览丢弃也会关闭镜像；同一 URI 的新文档不会被旧对象的迟到关闭误删。
桥接器停止或连接关闭时撤销订阅并取消排队发送，传输失败会关闭连接，不能继续使用
内容未知的镜像。产品文档模型到桥接器的事件链已覆盖测试，创建桥接器的产品激活入口
和 Windows 监管仍需接入；macOS 测试已走通现有语言 provider 路由。
本次文档事件验证覆盖实际文档模型的打开、编辑、写盘、重置，以及排队快照、
重复保存和迟到关闭；文档、保存、预览及宿主回归共 200 个 Swift 测试通过。

宿主主进程侧已开始承接通用语言能力：补全、悬停、定义、引用
provider 注册和诊断变更通过 `lithe/languageProviderRegistered`、
`lithe/diagnosticsChanged` 等 JSON 通知交给 Lithe。Provider 的实际回调仍由 Theia 插件侧执行；
`LanguageToolingSessionManager` 现在会按宿主会话代际注册和注销编辑器 provider，并把宿主归一化后的诊断
写入现有诊断存储。Theia 的 MarkerData 在宿主进程内转换，不进入 Swift 契约。宿主已提供 `host/provideLanguageFeature` 调用入口。真实 Node 测试扩展已验证补全、诊断和停止清理；
宿主测试还验证了悬停、定义、引用、按 handle 路由和 selector 匹配。真实 Java 扩展的
启动参数、文档事件订阅和补全结果仍未完成端到端验收，因此不能宣称产品级 Java 补全可用。

本机验证使用 Swift 6.3.3：46 个相关 Swift 测试（包括真实 Node 宿主）通过，
24 个宿主与制品缓存测试通过；真实宿主集成约 0.36 秒，最长宿主清理测试约 3.2 秒。
受管 Node 22.23.2 的 ARM64 与 Intel 版本均已成功加载两个官方扩展并正常退出，
Intel 在 Rosetta 下验证；这只证明资源完整和扩展可加载，不代表 JDT LS 已就绪。
资源目录移出仓库、清除 `NODE_PATH` 与 `NODE_OPTIONS` 后，两种架构仍能通过同一加载验证。
首次 Rosetta 转译可能超过 10 秒，制品验证使用 60 秒本地截止时间并在超时后结束进程。
双架构资源目录当前约 596 MB：Node 约 218 MB，生产宿主及依赖约 317 MB，
两个扩展约 61 MB；这是未压缩目录大小，不是安装包下载体积，也不代表资源预算已通过。
完整安装包签名、公证和 Java 工程导入仍需后续产品验证。
未验证 Windows、官方 Java 扩展的完整导入和资源成本。现有服务边界脚本因未修改的
`AppModel+RunConfiguration.swift` 已有 648 行而失败，其他契约、模块和 CI 分类检查通过。

补全候选使用宿主生成的不透明身份做按需解析（completion resolve），保留上游延迟返回
自动导入编辑和文档的行为。最多保留 32 份候选列表；新请求替换同 provider/文档的旧列表，
文档变更、关闭、provider 注销和宿主退出也会使身份失效并释放 Theia 缓存。过期解析结果
必须拒绝，不能把旧的自动导入编辑应用到新版本。Swift 将候选绑定到原始宿主代际和 provider，
经现有补全解析入口调用；不会把扩展候选转交旧 Rust JDT 会话。

### 正确做法

- 扩展需要新的 API 时，在 `src/main-side/` 里实现对应的通用 `*Main` 方法，必要时增加协议消息，并同时更新契约文档和测试。
- 某项能力如果 Lithe 已经有权威实现，就把请求转发给 Lithe。例如 `findFiles` 交给 Lithe 的搜索（它负责排除规则和忽略文件），不在宿主里另写一套遍历磁盘的搜索。
- 用 `scripts/audit-extensions.ts` 加载真实扩展，拿 `lithe/unsupportedApi` 的清单来决定下一步补哪些接口。

### 不要这样做

- 不要按扩展身份写分支，例如 `if (extension.id === 'redhat.java')`。确实需要专属补丁时，必须记录原因、适用版本和移除条件。
- 不要把 Theia 的 RPC 或 msgpack 格式暴露给 Swift/Rust；Lithe 侧只认 JSON 协议。
- 不要为了让激活继续下去，给未实现的接口返回空成功，那会掩盖兼容缺口。

## 考虑过的备选方案

### 嵌入或隐藏完整 Theia 工作台

优点是现成可运行，兼容性也最好。但它会在 Lithe 里形成第二套 IDE：两份文档和编辑器状态，Chromium 进程约 1.6 GiB，与 #737 的目标冲突，因此不采用。

### Fork Theia，修改它的主进程侧

优点是可以沿用 Theia 已写好的 41 个 `*MainImpl`（约 1 万行）。但这些实现深度依赖 Theia 前端、Monaco 和 inversify 服务，改完仍然是 Theia 的状态模型；fork 还要长期跟随上游升级，修改过的 EPL 文件也要公开源码。重写主进程侧反而更小，而且状态归属清晰。

### 让 Swift/Rust 直接实现 Theia 的 RPC

优点是少一层进程内转换。但 Theia 的 RPC 使用 msgpack 自定义扩展和内部接口名，版本之间会变化；这样做等于把 Theia 内部格式变成 Lithe 的跨平台契约，因此不采用。

### 复用 Code-OSS 的 extHost

它是 VS Code API 的参考实现，兼容度最高。但它与 VS Code 的构建和启动流程耦合更紧，单独拆出来的成本更高，也没有以 npm 包形式发布。可以作为 Theia 兼容度不够时的后备方案。

## 验收标准

- `extension-host/` 的测试通过（`bun run typecheck`、`bun test test`），覆盖以下场景：初始化、隐式激活事件、命令双向调用、取消后迟到的结果被丢弃、Lithe 持有文档的编辑与保存闭环、版本校验、`workspace.fs`、`findFiles`、配置分层、工作区信任、未实现 API 的上报、`process.exit` 被忽略，以及 shutdown 能结束残留子进程（包括升级到 SIGKILL）。
- 2026-09-19 在 Linux x64 上用 `scripts/audit-extensions.ts` 实测（Open VSX 包，校验和已核对）：`redhat.java` 1.56.0 和 `vscode-java-debug` 0.58.1 原样加载后都激活成功。`redhat.java` 自己启动了 JDT LS，并报告了 “Opening Java Projects” 进度；shutdown 后宿主结束了 1 个仍在运行的 JDT LS，没有进程残留。这次实测**没有**验证 ServiceReady、诊断和语言功能，因为下面这些接口都还没实现。
- 同一次实测触发的未实现接口共 41 个，也就是 M2/M3 的输入：
  - 语言功能：`LanguagesMain.$register*`（补全、悬停、定义、引用、重命名、格式化、语义高亮、CodeLens 等 22 项）、`$changeDiagnostics`、`$clearDiagnostics`、`$unregister`。通用 provider 注册、注销和诊断存储适配已经完成；生产启动、产品文档事件和接受补全后的命令仍需端到端验收，并与 Rust Core 里现有的 JDT 会话二选一，同一工作区不能出现两个 Java provider。
  - 调试：`DebugMain.$registerDebuggerContribution`、`$registerDebugConfigurationProvider`、`$unregisterDebugConfigurationProvider`。
  - 文件监听：`FileSystemEventServiceMain.$watch` 和 `$unwatch`。
  - 虚拟文档：`WorkspaceMain.$registerTextDocumentContentProvider`（`jdt://` 类文件）和 `CustomEditorsMain.*`（反编译视图）。
  - 界面：状态栏 `$setMessage`/`$dispose`、`OutputChannelRegistryMain.$append`、`TerminalMain.$registerTerminalLinkProvider`。
  - 内置命令：`_setContext`（VS Code 的 `setContext`）目前落到 `lithe/executeCommand`，Lithe 需要提供它，或者明确声明不支持。
- 后续里程碑按 #737 的 M1–M5 推进。其中“由 Lithe 平台适配层启动和监管宿主”这一步尚未完成，需要在 macOS 和 Windows 上分别实现并实测。

## 风险

- **Theia 升级**：插件侧从 npm 原样使用，但 `plugin-host-container.ts` 里的绑定和 `main.ts` 里的 msgpack 标签 `4`（`VsCodeUri`）都依赖 1.75.0 的实现。升级 Theia 时必须重跑测试和审计脚本。
- **API 兼容度**：Theia 报告的 API 版本是 1.134.0，但个别行为与 VS Code 不同（#737 已记录 `noDebug` 和添加断点的问题）。遇到时修通用层，并把修复提交给 Theia 上游。
- **资源成本**：当前双架构资源目录约 596 MB，内存与冷温启动成本仍未验收。采用通用 Java VSIX，避免平台包自带的 JRE 与 Lithe 的 Temurin JDK 重复分发。
- **授权**：只能使用 Open VSX 或其他允许在 VS Code 之外使用的来源；Theia 是 EPL-2.0，目前没有修改任何 Theia 文件。
- **回退**：原型没有接入产品。如果评估结论是不采用，删除 `extension-host/`、契约和 CI 工作流即可，现有的 Rust LSP 与 Java 运行链路不受影响。

## 适用范围

- `extension-host/`
- `shared/contracts/vscode-extension-host.md`
- `.github/workflows/ci-extension-host.yml`
- `scripts/classify-ci-changes.sh`
