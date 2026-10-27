# Agent 笔记：统一调试内核与调试适配器 Registry

状态：提议中

## 先说结论

[#1210](https://github.com/1lck/Lithe-IDEA/issues/1210) 不在现有两套调试会话上继续打补丁，而是**重新设计一个统一调试内核**。Rust Core 里只保留一个 DAP 客户端（DAP，Debug Adapter Protocol：编辑器与调试后端之间的标准协议），macOS 和 Windows 都通过 `debug.*` 命令使用它；平台只负责进程、socket、终端和界面。内置适配器和第三方插件进入同一个类型化 Registry（按稳定身份查找调试适配器的目录），插件只需声明“怎么启动这个调试器”。

调试能力分三层。断点、线程与调用栈、变量是**必选层**：每个适配器、两个平台都必须做到，也是 #1210 的关闭条件。监视表达式与调试控制台是**推荐层**。寄存器、内存、反汇编、反编译源码、子会话等是**可选扩展**：按适配器协商的结果显示，各自单独推进，见[可选调试扩展](2026-10-25-optional-debug-extensions.md)。可选功能可以晚做，但新内核第一版的数据模型就要为它们留好位置，以后只做增量，不改已有结构。

## 问题

### 现在是两套内核，按语言接线

以下盘点基于 `preview` 提交 `e854cfd98e4a52fe5abacff2002efd9f68082da2`。

| 现状 | 位置 | 带来的问题 |
| --- | --- | --- |
| Rust Core `debug.*` 内核：DAP 分帧、请求序列、断点、变量分页、取消、`runInTerminal`、Java 热替换 | `rust/lithe-core/src/debug/` | Windows 的全部调试和 macOS 的 Java 走这里 |
| Swift `DebugAdapterProtocolSession`：通用 stdio、Go、Node（含子会话） | `macos/Sources/LitheDebugModule/Runtime/` | 同一个功能要在 Swift 和 Rust 各写一遍，两边行为容易分叉 |
| 按语言装配的工厂 | `MacServiceContainer.swift`（内置 Python、Rust stdio 调试器和 `DebugAdapterRuntimeFactory` 已移除，只保留 Java，其余由语言插件提供） | 每接一种调试器都要改组合根（Composition Root，负责组装依赖的地方） |
| 以源码为中心的投影 | `rust/lithe-core/src/debug/types.rs`：`DebugStackFrame.line/column` 是必填 `i64`，`DebugScope` 没有 `presentationHint`；initialize 固定声明 `supportsMemoryReferences: false` | 无源码栈帧、寄存器、内存都没有地方表达；以后再放宽必填字段，就是 Rust、Swift、TypeScript 三端同时的破坏性变更 |

### 为什么重写，而不是继续扩展

上一版的方案是“Registry 先接入，内核整合以后在 Provider 背后慢慢做”。这样 Registry 会把两套内核的差异一起固定下来；之后每加一个能力，都要实现两遍、解码三遍。Lithe 的目标是兼容 GDB、LLDB、debugpy、Delve、js-debug 等多种调试器，难点在于 DAP 客户端是否完整，不在插件怎么声明。所以先把内核做成一个，再让所有适配器接到它上面。

### 哪些东西不重写

- **不自研调试器。** 符号解析、ptrace / Mach 异常端口 / Windows Debug API、各 CPU 架构的断点和单步，都由 GDB、LLDB 等上游负责。GCC 是编译器；GCC 编出来的程序用 GDB 或 LLDB 调试。
- **不重建项目模型。** Java 的主类和 classpath 来自 JDT，Python 解释器来自 Run，C/C++/Rust 产物来自 Build/Run。
- **不另造插件协议。** 启动声明复用 `serverProcess`、启动模板、能力版本和安装审查，详见[声明草案](../../../../shared/proposals/debug-adapters-1210/README.md)（正式契约见 `shared/contracts/plugins/v1/README.md`）。
- **现有行为是迁移基线，不能丢。** 包括 Java 热替换、JUnit/TestNG、调试使用 Run 选中的 JDK、子调试会话与 source map 位置透传、断点先于 launch 入队、停止与清理顺序。

## 提案

### 1. 内核、平台、插件、调试器各管什么

| 角色 | 负责 | 不负责 |
| --- | --- | --- |
| 统一内核（Rust Core） | DAP 分帧和请求关联；会话状态机；能力协商；断点存储与位置修正；暂停代次（每次暂停递增的编号）与引用失效；请求处理器注册表；规范化事件与投影；父子会话关系 | 启动进程、打开 socket、创建终端、读文件、画界面 |
| 平台（macOS / Windows） | 按内核给出的计划启动进程和传输；PTY / ConPTY 终端；路径映射与文件授权；界面展示 | 解析 DAP、维护断点或变量状态、按语言写分支 |
| 插件 | 声明调试器怎么启动：进程、传输、可选的参数映射和能力禁用 | 实现 DAP 状态，或声明自己支持哪些标准能力 |
| 调试器（上游） | 语言和平台语义 | — |

平台和内核之间沿用现有 JSON 信封与 C ABI：平台调用 `debug.createSession`，把返回的 `outboundFrames` 写给适配器，再把适配器的输出交给 `debug.receive`。Windows 已经这样工作；macOS 的 Swift 会话在迁移完成后删除。

### 2. 会话模型 v2：第一版就为扩展留位置

新内核发布投影版本 2，草案见 [`debug-session-projection.draft.schema.json`](../../../../shared/proposals/debug-adapters-1210/debug-session-projection.draft.schema.json) 和[样例](../../../../shared/proposals/debug-adapters-1210/projection-v2-examples.draft.json)。与 v1 相比：

| 预留 | 规则 | 为什么第一版就要定 |
| --- | --- | --- |
| 栈帧的 `source`、`line`、`column` 可选 | 无源码帧不伪造文件，也不填第 1 行；可以带 `instructionPointerReference` | v1 的必填 `line` 分不清“位置未知”和“第 1 行” |
| 源码身份三选一 | 工作区相对路径 / 会话内 `sourceReference` / 已授权的外部路径 | 反编译出来的源码、eval 生成的代码、系统库源码都能表达 |
| 地址与引用一律用字符串 | `instructionPointerReference`、`memoryReference` 等都是不透明字符串 | 64 位地址超出 JavaScript 的安全整数范围 |
| scope 透传 `presentationHint` | `arguments`、`locals`、`registers`、`returnValue` 及未知值原样保留 | 寄存器视图直接按提示筛选，不假定所有 CPU 都有同一张寄存器表 |
| 引用绑定会话和暂停代次 | 继续、单步、重启后，旧的 `variablesReference` 和栈帧 ID 失效 | 晚到的结果不会写进新的暂停状态 |
| 能力快照 | 有效支持 = 适配器协商结果 ∧ 本平台已注册的扩展 ∧ 授权；带递增 `revision` | 界面只看快照，不看插件名或清单 |
| 未知值不丢弃 | DAP 新增的枚举值、未知 `presentationHint`、未知停止原因原样保留 | 上游升级时不必先改三端解码器 |

v1 投影和命令保留到两端都迁到 v2 为止，然后在同一个 PR 里删除 v1、Swift 会话和按语言的工厂。Rust、Swift、TypeScript 共用 `shared/fixtures/debug/*-v2.json`。

### 3. 能力分三层

**必选层。** 这些请求和事件 DAP 规范本来就要求，不靠 capability 开关。每个注册的适配器都要跑通，两个平台都必须实现：

| 类别 | 内容 |
| --- | --- |
| 会话生命周期 | `initialize`；`launch` 或 `attach` 至少一种；`configurationDone`；`disconnect` / `terminate`；停止与资源清理 |
| 断点 | 行断点 `setBreakpoints`；断点确认与位置修正（`verified`、移到有效行） |
| 执行控制 | `continue`、`pause`、`next`、`stepIn`、`stepOut` |
| 线程与调用栈 | `threads`（调用栈按线程获取）、`stackTrace` |
| 变量 | `scopes`、`variables`（嵌套展开与分页） |
| 事件 | `stopped`（含停止原因）、`continued`、`exited` / `terminated`、`output` |

**推荐层。** `evaluate` 的 `watch`、`hover`、`repl` 三种上下文，也就是监视表达式、悬停求值和调试控制台。它们不是 #1210 的关闭条件，但应先于可选扩展完成：用户通常把它们当作“变量追踪”的一部分，GDB/LLDB 的大量功能也要靠控制台命令。

**可选扩展。** 断点增强、表达式与变量、执行控制增强、无源码代码（含反编译）、原生调试（寄存器、内存、反汇编、指令断点与单步）、进程与模块、语言专属扩展。分组和各自的验收见[可选调试扩展](2026-10-25-optional-debug-extensions.md)。

Registry 注册时不启动程序做验证。一个适配器在接入验收中跑通必选层的标准流程后，才能标记为可用。

### 4. 扩展机制：内核模块，不是插件 JSON

每个可选扩展是一组宿主代码，包括三部分：

1. 在内核里注册请求处理器和投影解码器；
2. 声明它允许内核在 initialize 里告诉适配器的客户端能力，例如 `supportsMemoryReferences`、`supportsStartDebuggingRequest`、`supportsInvalidatedEvent`；
3. 提供平台界面入口。

具体规则：

- 内核只声明已注册扩展对应的客户端能力。没有内存扩展时，继续声明 `supportsMemoryReferences: false`，适配器就不会发来内存引用。
- 界面入口只看能力快照，不看适配器名称。
- 扩展不写进插件清单。插件最多用 `capabilities.disabled` 关掉某个标准能力。
- 语言专属扩展（如 Java 热替换的 `redefineClasses`）挂在内置 Provider 的描述上：Provider 描述列出它使用的扩展，组合根不按名字判断。第三方的非标准请求不在本提案中开放。

### 5. Registry 与插件声明

完整字段和拒绝规则见[声明草案](../../../../shared/proposals/debug-adapters-1210/README.md)（正式契约见 `shared/contracts/plugins/v1/README.md`），这里只记录决策：

- 插件只写一个 `plugin.json.debugAdapters` 块，必填 `id`、`displayName`、`launch`。`launch` 由两部分组成：复用 `serverProcess` 的进程，加上 `stdio`、`tcpAnnounced` 或 `tcpPort` 三种传输之一；调试服务寄居在同一插件的语言服务器里时（Java Debug Server 之于 JDT LS），改用 `tcpLanguageServer`，此时没有 `process`，只有 `endpoint`。
- 拟定 API 4、`requires.debugAdapters: 1`、`debug.launch` / `debug.attach` 权限。需要 Run 选中的运行时时，使用 `serverProcess: 2` 的 `runSelectedRuntime`。
- 标准能力跟随 DAP 协商，清单只能禁用。没有依赖、导出、工作流、resolver 或 `hostIntegration` 字段；插件依赖另见[独立平台提案](2026-10-25-plugin-dependencies-and-exports.md)。
- 内置 Provider（Java、Go、Node、Python、LLDB）和第三方声明转成同一种描述后进入 Registry。身份由插件 ID 加局部 ID 组成，内置 Provider 使用保留空间。
- 选择顺序为：配置里的显式选择 → 工作区已保存的关联 → 唯一匹配的候选。多个候选时由用户选择，插件不能自报优先级。
- Run 配置 ID、三层覆盖规则和导入的 `launch.json` 参数保持不变；目标映射只补缺失的值，不覆盖显式写出的 `program`、`args`。

### 6. 资源与生命周期

- 每次准备和连接都绑定工作区、Provider 注册代次和操作，并设有期限；调试会话本身不设总时长。
- 禁用与启动同时发生时，执行前再确认一次；已经创建的资源进入同一条清理链。取消、停止、失败后丢弃晚到的结果；重复点击停止共享同一个完成状态。
- adapter 进程、被调试程序、终端、共享语言服务器和外部 attach 目标分别记录所有权。`launch` 结束自己启动的程序，`attach` 默认只断开；结束 Java 调试不终止 JDT LS。
- 插件包和安装目录只读。日志、缓存、锁文件和临时状态由平台存储 adapter 写到可写目录，不影响代码签名和 Sparkle 增量更新。

### 7. 分阶段交付

| 阶段 | 交付与退出条件 |
| --- | --- |
| P0 行为基线 | 把现有两套内核的行为录成 v1 基线 fixtures：启动序列、断点先于 launch、断点位置修正、变量分页、停止与断开策略、`runInTerminal`、Node 子会话、Java 热替换 / 测试 / Run JDK、取消与晚到事件 |
| P1 新内核与 v2 投影 | 新内核实现必选层和推荐层、v2 投影、能力快照、扩展注册表；三端都能解码 v2 fixtures；通过全部 P0 基线 |
| P2 内置迁移与 Registry | 内置适配器逐个注册为 Provider 并切到新内核，建议顺序：通用 stdio → Go → Node → Python → Java。每个都有可回退的开关，同一目标只启用一个实现；Windows 同步迁移 |
| P3 第三方声明契约 | 正式 schema、Core 语义校验、版本号、权限、安装审查一起落地；声明草案里的拒绝 fixtures 接上 Core 测试 |
| P4 第三方纵向验收 | 两个平台各用一个真实第三方适配器（GDB DAP `gdb -i=dap` 或 `lldb-dap`）完成安装、选择、launch / attach、必选层全流程和资源回收 |
| P5 删除旧路径 | 所有消费者迁到 v2 之后，在同一个 PR 里删除 Swift 会话、按语言的工厂和 v1 投影 |

P0 的清单落在 `shared/fixtures/debug/v1-baseline.json`：每一项指向 Rust、macOS 上现有的测试和 fixture（Windows 不在当前阶段范围内），并标明 `covered` / `partial` / `gap`。`scripts/verify-debug-v1-baseline.mjs`（已接入 `verify-shared-contracts.sh`）检查引用的测试仍然存在，防止重命名或删除悄悄缩小基线。

P1 已在 Rust Core 落地：v2 投影类型与校验（`debug/projection_v2.rs`，共用 `projection-v2-examples.json`）、DAP `startDebugging` 反向请求（`debug.startDebuggingResponse`，仅在宿主声明 `supportsStartDebuggingRequest` 时启用）、Node source map 位置透传。macOS 的 `DebugProjectionV2` 与 Core 会话读同一份 fixture。旧的 Swift `DebugAdapterProtocolSession` 已删除：Java、Python、Rust 全部走 Core 会话（Python、Rust 经 `DebugAdapterRuntimeFactory` 用 stdio 传输）。宿主同时移除了内置的 Go（Delve）和 Node（js-debug）调试，TCP 传输、会话工厂、启动配置解析和语言包调试入口都已删除，之后由对应语言插件按 Registry 契约补上。P1 之后基础层逻辑也已在 Core 落地（`debug/capabilities.rs`、`engine.rs`）：能力快照 `supported = 适配器协商 ∧ 扩展注册 ∧ 已授权`，带单调递增 `revision`，只在变化时发出；插件只能通过 `disabledCapabilities` 关闭标准能力，`supportsConfigurationDoneRequest` 不可关闭。停止代数（`stopGeneration`）在停止、继续、终止时递增，旧代数发出的引用型请求的回复被丢弃并报 `StaleReference`（`stale-reference-v1.json`）。evaluate 的 context 受校验。Core 记录父子会话树，随父会话停止发出 `ChildSessionStopRequested`。子会话生命周期与父会话统一：销毁父会话会级联销毁整棵子树（叶子在前），`debug.destroySession` 返回 `destroyedChildSessionIds` 供宿主关闭对应传输，Core 里不会留下孤儿子会话。栈帧与作用域响应同时发出 v2 `Projection` 事件，v1 仍为准，校验失败的 v2 投影不下发。
macOS 多会话（本阶段）：宿主在 `DebugAdapterSessionManager` 里实现 `startDebugging`。父会话收到反向请求后，管理器通过 `makeChildSession` 向 provider 要一个子会话，把父会话的 Core 会话 ID 设为子会话的 `parentSessionId`，登记为带 `parentID` 的会话并用请求里的配置启动。子会话不会替换 provider 的当前会话（兼容目标仍是父会话），所以单会话的断点、状态和按钮行为不变。生命周期由宿主统一：停止父会话先停子会话；父会话进入 `terminated` 或 `failed` 也会关闭它的子会话；功能模型同步清理快照、Java 热更新目标，并在当前会话消失时改选剩余会话，没有剩余会话就回到空闲。

界面采用折叠模式，参照 IDEA 把切换放在“线程与变量”里，而不是在标题栏堆标签：标题栏始终只有一个会话标签；出现第二个会话后，“线程与变量”左上角的选择器多一段“会话”，子会话紧跟父会话并带 “↳” 前缀、状态圆点（运行绿、暂停橙、失败红），下面接当前会话的线程列表；选择器按钮显示“当前会话 · 当前线程”。停止单个会话放在选择器的右键菜单里。被否方案：标题栏多标签条，会话一多就挤占标题栏，也让线程切换和会话切换分在两个地方。

`makeChildSession` 是可选覆盖：默认子会话就是 provider 的 `makeSession` 再开一个会话，宿主因此总会声明 `supportsStartDebuggingRequest`。这是有意取舍：旧调试内核要整体被替换，不为兼容旧行为保留休眠开关。代价是 debugpy 这类通过 `connect` 主机和端口附加的适配器，在没有 TCP 子会话传输前，子会话会被忽略该端点，多进程 Python 调试暂时不可用；由具体语言插件覆盖 `makeChildSession` 补上。Swift 侧仍未消费 `projection`、`childSession*` 与 `disabledCapabilities`。

P3 的声明层已在 Rust Core 落地：`plugin.json.debugAdapters[]` 作为插件 API 4 进入正式契约（`shared/contracts/plugins/v1/`），`debug/adapters.rs` 校验声明、安装包资源和启动计划，C01–C09、S01–S02 拒绝用例由 `fixtures/debug-adapter-rejections.json` 驱动 Core 测试。启动计划与安装检查由 macOS 声明式 Provider 接入（先 stdio + launch）。

macOS 声明式 Provider：
- Rust Core 新增 `languageServerLaunchPlan` 的 `debugAdapterID` 选择器和 `debug.adapters.startArguments` 命令；后者按 manifest、adapterID、request 与事实（注册代次、目标、运行时选择）返回启动参数，拒绝码为 `debug.provider.stale`、`debug.request.unsupported`、`debug.runtime.stale`、`debug.target.invalid`、`plugin.launch.unavailable`。
- 宿主启用模块 `<pluginID>.debug-adapters`（只承载启用、隔离与安全模式状态）。容器按语言 ID 建立插件适配器会话；Java 等内置语言优先，宿主不按插件名字分支。
- 启动计划在会话 `start(rootURL:)` 时才解析，因为启动依赖工作区；被拒绝的计划就是启动错误。`adapterID` 声明时默认等于 `id`，会话创建时即需要（DAP `initialize.adapterId`），所以随描述符提前提供。
- 适配器可执行文件只允许来自插件包或 `systemCommand`；工具发现覆盖 Xcode 工具链（`xcrun` 等）。`tcpPort`、`tcpAnnounced`、attach 和 `runSelectedRuntime` 还没有接入宿主，之后再做；`tcpLanguageServer` 已接入，见下一节。
- 生命周期与所有权：适配器进程归会话，随会话停止。适配器状态目录是 Application Support 下的 `<插件状态目录>/debug-adapters/<adapterID>`，不写 app bundle 或插件包，不影响代码签名和 Sparkle 增量更新；`${workspaceStateDir}` 按工作区摘要隔离。被调试程序的启动配置由 `startArguments` 生成，宿主只在没有内置 provider 处理时回落到它。

macOS 的 P4 纵向验收用 `lldb-dap` 推进：官方 LLDB 插件（`io.github.lithe-idea.lldb-debug`，仓库 [lithe-plugin-lldb](https://github.com/Lithe-IDEA/lithe-plugin-lldb)）已作为预发布收录在 Lithe Store，需要支持 API 4 的 Lithe 才能安装；必选层全流程的验收结果还没有记录，不算 P4 完成。这一轮在契约里补了三件事，全部在尚未发布的 API 4 / `debugAdapters` v1 内，没有已发布的契约被改动：
- `configurations.launch.executable`（`setting` 加 `candidates[]`）与 `targetBindings.program: "target.executable"`：C、C++、Swift 的用户打开的是源文件，要调试的是编译产物，由宿主按用户设置、再按候选路径解析，见[可执行文件设置与默认发现](../../implemented/feature/2026-10-26-debug-adapter-executable-setting.md)。
- `console`（`commandPrefix`、`commands[]`）：调试控制台的命令输入行与补全，见[命令输入行与插件补全](../../implemented/feature/2026-10-26-debug-console-prompt-and-completion.md)。
- 适配器拒绝请求时，Core 优先取 DAP 响应里的 `body.error.format`（按 `body.error.variables` 填充 `{name}`），再回落到 `message`；`lldb-dap` 和 `debugpy` 都只把可读解释放在 `error.format` 里。

只贡献调试适配器的插件在 macOS 上安装、更新、卸载免重启，见[插件热激活](../../implemented/architecture/2026-10-26-plugin-live-activation.md)。这是宿主后端能力，不是清单字段，插件契约不变。Windows 的 P2–P4 还没有开始，不属于这一轮。

#### Java 迁入 Java Support 插件（P5 的最后一块内置路径）

Java 是宿主里最后一个内置 Provider（`debugFactories["java"]`、`MacJavaDebugAdapterTransport`、Core 里 `adapter_id == "java"` 的分支）。迁移拆成三个 PR，每个都能单独合并、单独回退：

| PR | 内容 | 状态 |
| --- | --- | --- |
| PR-A 传输 | 新增 `tcpLanguageServer` 传输：`launch.process` 必须缺省，`endpoint` 只有 `{languageID, command}`；`languageID` 必须是同一插件 `languageServers[]` 里声明过的，`command` 限 `[A-Za-z0-9._:-]{1,128}`。宿主不拉起进程，而是启动该插件的语言服务器，用 `workspace/executeCommand` 执行 `command`（Java 是 `vscode.java.startDebugSession`），把返回值解析成 1…65535 的端口再连 `127.0.0.1`。`MacJavaDebugAdapterTransport` 改名 `MacHostedPortDebugAdapterTransport`，端口来源由宿主注入，不再知道 Java | 本 PR |
| PR-B 语言专属扩展 | 把 Java 独有的三件事从“按适配器名字”改成“按描述声明”：`redefineClasses` 热替换、`stepFilters` 默认值（`java_step_filters`、`defaults_for_adapter("java")`）、`JAVA_DEBUG_DISABLE_DEVTOOLS_RESTART` 追加到 `vmArgs` | 未开始 |
| PR-C 切换与删除 | Java Support 清单升到 API 4 并声明 `debugAdapters`；删除 `debugFactories["java"]`、Core 里的 Java 分支和 `MacJavaDebugAdapterTransport` 的残留引用 | 依赖 #1495（J7/C2）：启动目标（`JavaDebugLaunchTarget`）和测试调试（`JavaTestDebugLaunchService`、`JavaTestResultServer`）还在宿主里，要先随 J7/C2 迁出 |

关键取舍：
- **为什么是新传输，而不是 `tcpPort` 加一个“先执行命令”的钩子。** Java Debug Server 的端口每次会话都由语言服务器分配，且只能通过它自己的会话问到。`tcpPort` 的端口是清单里写死或进程公布的，扩展它等于在 `launch.process` 之外再开一条“向某个服务要端口”的通道；单独的传输让校验规则（无 `process`、`endpoint` 只有两个字段、语言服务器归属）一目了然，也与构建 provider 的 `{languageServer: "<id>"}` 形态一致。
- **`endpoint.command` 只允许一个命令名，不允许参数。** `vscode.java.startDebugSession` 本身不带参数（旧实现传的就是空数组），主类和 classpath 在随后的 `launch` 请求里给，所以清单只需要命令名；不开放参数，是为了插件不能借这个端点让宿主向语言服务器发送任意负载。`programs()` 把它列入审批内容（`languageServerDebugAdapter`），命令名变了要重新批准。
- **语言服务器归属由宿主校验，而不是信任清单。** 清单声明的 `languageID` 必须是同一插件的 `languageServers[]`，运行时 `startHostedDebugAdapter` 还要核对该语言的运行时来自同一个插件；内置的 Java 语言服务（不属于插件）被拒绝，避免插件借内置语言服务器执行命令。
- **停止调试不停止语言服务器。** 传输 `stop()` 只关闭 TCP 连接；语言服务器是共享资源，沿用“结束 Java 调试不终止 JDT LS”的所有权规则。
- 被否方案：让宿主按 `adapterID == "java"` 特判端口获取。这正是要删除的东西。

P0–P5 完成后关闭 #1210。可选扩展、插件依赖和私有 resolver 都不是关闭条件。

### 正确做法

- 接入 GDB：插件声明 `systemCommand: ["gdb"]`、参数 `["-i=dap"]`、`stdio` 传输。断点、线程、栈、变量直接出现在现有调试窗口里，插件不列任何能力。
- 新增内存查看：在内核注册 `readMemory` 处理器，允许内核声明 `supportsMemoryReferences`，再在两端加界面入口。GDB 和 LLDB 都会自动获得这项功能，插件不需要改动。
- 调试一个没有符号的汇编程序：栈帧只有名称和 `instructionPointerReference`，界面显示“无源码”，不跳到某个文件的第 1 行。

### 不要这样做

- 在 Swift 和 Rust 里分别补同一个能力，或者在组合根按语言名再加一个工厂分支。
- 给无源码帧填一个假文件和第 1 行，让旧解码器“看起来能用”。
- 让插件在清单里逐项声明 `supportsX`，或者用插件函数实现标准 DAP 请求。
- 在 P0 基线全部通过之前删除旧会话，或者为了切换方便先去掉 Java 测试、热替换、子会话等现有功能。

## 考虑过的备选方案

### 在现有两套内核上增量扩展

这是上一版的方案。它的吸引力是迁移量小，Registry 可以先上线。不采用的原因：每加一个能力都要实现两遍、解码三遍；以源码为中心的 v1 模型迟早要做破坏性修改，越晚改受影响的消费者越多。

### 每个平台各自实现 DAP 客户端

在 Swift 和 TypeScript 里各写一套，可以最贴近各自平台的界面框架。不采用的原因：状态机、断点修正、暂停代次这些语义会在两端分叉，现有 Windows 已经证明 Rust 内核加平台传输的分工可行。

### 直接引入第三方 DAP 客户端库

可以省去手写协议类型。不采用整套库，因为会话状态机、暂停代次、资源所有权、取消与晚到结果是 Lithe 自己的语义，现成的库不提供。可以只复用协议类型：从 DAP 官方 JSON 定义生成，减少手写错误。

### 自研调试器

可以完全掌控功能。不采用的原因：要重复实现 GDB/LLDB 几十年积累的符号解析、平台调试接口和架构细节，还要处理系统调试授权，偏离本任务。

### 插件 JSON 工作流与插件依赖

更早一版曾在 Debug 声明里加入依赖、导出、跨插件函数和 `steps` 流程。已撤回：这些属于插件平台，涉及市场依赖解析、版本冲突和信任传递；而且示例里没有证明必要的真实流程。依赖部分移到[独立平台提案](2026-10-25-plugin-dependencies-and-exports.md)。

## 验收标准

- macOS 和 Windows 都只使用统一内核；Swift 会话、按语言工厂和 v1 投影在 P5 中删除，删除前全部 P0 基线 fixtures 通过。
- 必选层的每一项都有共享 fixtures，覆盖正常流程、取消、晚到事件和引用失效；推荐层有独立用例。
- v2 fixtures 至少包含：有源码帧、无源码帧、`sourceReference` 源码、`registers` scope、超过 2^53 的地址字符串、未知 `presentationHint`；三端解码结果一致。
- 能力快照只在适配器协商、扩展注册和授权都满足时报告 supported；未注册扩展时，initialize 不声明对应的客户端能力。
- 内置与第三方共用 Registry；显式选择、工作区关联、候选歧义、重复身份、禁用失效都有标准输入和结果；组合根里没有按插件名或语言名的分支。
- 至少一个真实第三方适配器在两个平台上各自完成安装、选择、launch 与 attach、必选层全流程和停止；结束后本次启动的 Lithe、适配器和被调试程序都已退出，外部 attach 目标保留。
- API 1/2/3、Run 配置、Build/VCS/语言/UI/设置、私有函数的现有兼容结果保持不变；Java 测试、Run JDK、热替换，以及 Node 子会话和终端不回退。

## 风险

- **重写周期长，期间两套内核并存。** P2 按适配器用开关切换，未迁移的继续走旧路径；同一个目标从不同时启用两个实现。
- **基线漏录导致功能回退。** P0 以现有测试和真实流程为来源逐项列清单，评审时检查清单，而不只检查 fixture 数量。
- **v1 和 v2 并存的维护成本。** 只在迁移期并存，P5 统一删除；迁移期间新功能只加在 v2 上。
- **后端差异。** GDB 是否带 DAP 取决于版本和构建方式（需要 GDB 14 及以上），Windows 上要实测 MinGW 版本；未验证的组合不标记为可用。
- **拟定版本号冲突。** 实施前重新核对能力表，只取下一个可用编号，不改变已发布编号的含义。

## 验证

本阶段只修改设计文档和草案 schema。运行 `./scripts/verify-agent-notes.sh`、`./scripts/verify-shared-contracts.sh`、`./scripts/verify-runtime-bundle-immutability.sh` 和 `git diff --check`，并用 Draft 2020-12 离线校验草案 schema 与样例。这些检查不构成运行时证据。

实施阶段加载 `write-stable-tests`，按改动范围运行 `./scripts/verify-rust-core-comments.sh`、`./scripts/verify-rust-core.sh`、`./scripts/test-macos.sh`、`./scripts/verify-service-boundaries.sh` 和 `./scripts/verify-windows-boundaries.sh`；Windows 另外执行 `./scripts/build-windows.ps1 -Configuration Release`、宿主 Rust 测试和前端测试。所有等待都有上限，失败时也释放资源，结束后确认本次启动的进程都已退出。平台行为变化时同步功能矩阵，运行 `./scripts/verify-platform-feature-matrix.sh`。正式契约与 Core 一起修改，合并后按[两仓库发布规则](../../implemented/architecture/2026-10-23-plugin-contract-publishing.md)同步 `lithe-plugin-docs`。

## 适用范围

- `rust/lithe-core/src/debug/`
- `rust/lithe-core/src/plugins/`
- `shared/contracts/plugins/v1/`
- `shared/contracts/rust-core-api.md`
- `shared/proposals/debug-adapters-1210/`
- `shared/fixtures/debug/`
- `macos/Sources/LitheCoreContracts/Debug/`
- `macos/Sources/LitheDebugModule/`
- `macos/Sources/Lithe/Services/Debug/`
- `macos/Sources/Lithe/Platform/MacOS/MacServiceContainer.swift`
- `windows/tauri/src/features/debugger/`
- `windows/tauri/src-tauri/src/debug.rs`

## 依据

- [公共扩展契约](2026-10-13-public-extension-contract-and-provider-api.md)、[能力版本](../../implemented/architecture/2026-10-17-plugin-capability-versions.md)、[插件函数契约](../../implemented/architecture/2026-10-20-plugin-function-contract.md)。
- [Java 构建与启动边界](../../implemented/architecture/2026-09-18-java-project-build-and-launch-boundary.md)、[Java Debug 使用 Run 的 JDK](../../implemented/bug-fix/2026-10-14-java-debug-uses-the-run-jdk.md)、[Windows Java 调试生命周期](../../implemented/bug-fix/2026-10-07-windows-java-debug-lifecycle.md)。
- [DAP 标准](https://microsoft.github.io/debug-adapter-protocol/overview)、[DAP 定义](https://github.com/microsoft/debug-adapter-protocol/blob/main/debugAdapterProtocol.json)、[GDB DAP](https://sourceware.org/gdb/current/onlinedocs/gdb.html/Debugger-Adapter-Protocol.html)、[LLDB DAP](https://lldb.llvm.org/use/lldbdap.html)。
