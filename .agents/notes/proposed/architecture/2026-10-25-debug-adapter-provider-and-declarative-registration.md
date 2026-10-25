# Agent 笔记：调试适配器 Registry 与第三方 DAP 接入

状态：提议中

## 先说结论

[#1210](https://github.com/1lck/Lithe-IDEA/issues/1210) 只做两个目标：内置和第三方共用类型化 Registry（按稳定身份查找适配器的目录），第三方 DAP（Debug Adapter Protocol，编辑器与调试后端之间的标准协议）进入既有 Debug UI。插件在同一个 `plugin.json.debugAdapters` 里声明固定的进程和传输，匹配、参数映射及能力禁用都是可选项；不用理解依赖、导出或工作流。

依赖与跨包授权移到[插件平台独立提案](2026-10-25-plugin-dependencies-and-exports.md)，原生指令和内存展示移到[独立后续提案](2026-10-25-native-debug-projections.md)。它们以及动态 resolver（运行前计算启动参数的可选函数）都不是本任务 P1–P3 的前置条件。本 PR 只提交设计，不改变已发布 API，也没有新增运行验证证据。

## 问题

### 现有系统可直接复用

以下源码盘点固定在 `preview` 提交 `e854cfd98e4a52fe5abacff2002efd9f68082da2`，说明代码责任，不代替平台验收。

| 入口 | 现有能力与本次动作 |
| --- | --- |
| `rust/lithe-core/src/debug/` | 已有 DAP 分帧、请求序列、状态、断点、变量、取消和反向终端请求；不另写 DAP 引擎 |
| `macos/Sources/LitheCoreContracts/Debug/` | 已有平台无关的会话、传输及启动配置；保留兼容入口，新增 Registry 身份 |
| `macos/Sources/LitheDebugModule/Runtime/DebugAdapterSessionManager.swift` | 已有多会话和停止管理；改为从 Registry 获取 Provider，保留事件及失效代次 |
| `macos/Sources/Lithe/Services/Debug/DebugAdapterRuntimeFactory.swift` | 目前按语言装配 stdio 及专用工厂；改为通用适配器加内置 Provider 注册 |
| `DebugLaunchConfigurationResolver.swift`、`DebugLaunchPreparationCoordinator.swift` | 保留 Run 参数来源、保存、工程准备及编译失败决策；不复制 Build/Run 项目模型 |
| `windows/tauri/src/features/debugger/`、`windows/tauri/src-tauri/src/debug.rs` | 独立接入同一共享契约和现有界面；平台继续负责进程、socket 与终端 |
| `shared/contracts/plugins/v1/` | 复用能力版本、进程启动、安装审查与插件生命周期；纯 Debug 无需声明语言或 UI |

macOS 的 Java 走 Rust DAP，通用、Go 和 Node 仍有 Swift 会话路径。后者已有子会话行为，不能因为 Registry 新增就立即删除；先验证行为等价，再逐个迁移。

### 上游工具而不是新的调试引擎

- Java 复用 JDT LS 1.61.0 与 Java Debug Server 0.53.2（`third_party/jdtls/manifest.json`），工程路径、主类与测试事实继续来自 JDT，目标 JVM 使用 Run 选中的 JDK。
- Python 复用 `debugpy.adapter`；解释器与虚拟环境来自 Run，不在调试时静默安装。当前代码未统一固定 debugpy 版本，实际接入需记录兼容范围。
- JavaScript/TypeScript 复用开源 `vscode-js-debug` standalone server；Go 复用 Delve DAP。现有 TCP、source map、终端及子会话行为是迁移基线，后端版本仍需单独核实。
- 已有 Rust 的 LLDB 启动可注册为内置 Provider；`lldb-dap` 或具备 DAP 的 GDB 可作为普通第三方适配器。GCC 是编译器，目标与符号来自 Build/Run，而不是增加一个名叫 GCC 的调试引擎。

本任务统一发现与接入方式，不承诺同一个模型让所有后端具有完全相同的能力。新增下载、打包资源及上游升级不是本设计 PR 的内容。

## 提案

### 1. 只增加 Debug 能力，不建立插件平台

沿用 [Build 的能力块与共享进程设计](../../implemented/architecture/2026-10-17-build-system-plugin-contract.md)和 [VCS 的运行时协商设计](2026-10-22-unified-vcs-provider-model.md)。完整清单只有一个，Debug 块只声明身份、启动前需要的事实及可选策略；能力状态由会话协商，不把 `supportsX` 全抄进清单。

唯一的[评审 schema](../../../../shared/proposals/debug-adapters-1210/debug-adapters.draft.schema.json)及[字段边界](../../../../shared/proposals/debug-adapters-1210/README.md)保存在 `shared/proposals/`，并非正式插件契约。必需项仅为身份、显示名和固定 launch；无需依赖、导出、函数服务、步骤或额外配置文件。普通 JSON 参数不会被当作资源引用解释。

选择拟定的 API 4、新 `debugAdapters: 1` 能力和 `debug.launch` / `debug.attach` 权限。普通进程沿用 `serverProcess: 1`；Run 选中运行时作为共享 `serverProcess: 2` 分支，由共享进程解析器拥有。这样 Python 不需要依赖平台才能用正确解释器，也不会在进程版本 1 下悄悄扩大支持范围。

这是待评审编号，不代表宿主支持；实施前核对编号是否被占用。API 1/2/3 和未使用 Debug 的能力原样保留。新增权限属于基础 API 演进，不能仅靠 `requires.debugAdapters` 绕过基础版本。安装、市场与运行前检查继续使用同一 `hostCapabilities`，只在宿主确实能运行时发布支持。

### 2. Registry 统一身份和选择，不吞并配置

内置 Provider 和第三方声明先转成同一种类型化描述，再进入 Registry。第三方身份由插件 ID 与局部 adapter ID 组成，内置身份使用宿主保留空间；DAP adapterID、语言、配置 type、Run 配置 ID 和会话 ID 分开。

选择顺序固定为配置显式选择、工作区已保存关联、匹配后的唯一候选。多个候选交给用户选择，列表按稳定身份排序，不让插件自报优先级抢占。缺省 selectors 表示只接受显式选择；发现阶段不执行程序。重复身份拒绝注册，选择项不可用时显示原因，不静默换后端。

原有 Run 配置 ID、三层覆盖、导入参数与 `DebugLaunchConfiguration` 不变。声明默认参数后仍使用既有覆盖链，目标映射只补空缺值，绝不覆盖显式 program、args 或 classpath。对外部构建产物使用 Build/Run 的授权目标引用，平台解析执行路径；不要求所有目标都能写成工作区相对路径。

### 3. 固定启动形状足够覆盖基础 DAP

`launch.process` 共用现有 ServerProcess 的数据类型、校验、模板、工具发现及安装审查；`launch.transport` 为 stdio、公告端点 TCP 或固定端口 TCP。不引入通用 workflow、JSON Pointer 求值、宿主原语目录或按后端名选择的端口解析器。

公告端点使用字面量前缀和端口/hostPort 解码，限定 loopback、输出预算和期限。固定端口需检查占用与本次进程归属，不能连接到碰巧在同一端口的外部服务。平台未实现某种传输时明确拒绝，不因为 Core 能解析就发布支持。

Python/Java/Node 的 `runSelectedRuntime` 按同一目标复用 Run 选择结果，不增加第二套 runtime 设置；其他现有 packaged/system/runtime 分支保持旧含义。`${pluginDir}` 属于声明该进程的包，配置参数仍是普通 JSON。此版没有跨包可执行引用或对参数里特殊键名的猜测。

### 4. 保留函数与宿主集成边界

Java 先作为内置 Provider 注册，继续走既有 JDT 工程准备、测试、热替换及生命周期；第三方 Debug JSON 不提供 `hostIntegration` 入口。宿主已知的内置实现可以注册，不等于允许每个新插件在组合根添加名称判断。

[已落地函数决策](../../implemented/architecture/2026-10-20-plugin-function-contract.md)保持不变：函数私有、领域结果类型化、后端不得请求宿主再次进入领域注册表。此版撤回跨插件函数、exports 和任意标准能力的函数实现，不修改那份已实现 Note 来声称新机制已生效。

私有 resolver 也不是现成能力：后续独立版本先明确领域输入/结果、进程归属、权限和取消，修订函数决策后再开放。若结果需要 Build/Run 准备，只接受宿主已有 action 的类型化引用，成功后重新解析一次；第二次再要准备即拒绝，避免循环。`backend: 1` 仍为网页的全局进程，不改成工作区 Debug 后端。该后续版本不阻塞基础接入。

### 5. 标准能力默认使用 DAP，不要求重复声明

省略能力块时，按标准 DAP 默认值、initialize 和 capabilities 事件决定支持；宿主尚未实现的操作继续不可用。manifest 只允许 `capabilities.disabled` 关闭已知标准 capability，不允许 `source: function`，也不把 manifest 当作“已实现”的证据。

capability 名称以实施时固定的 DAP 定义为准，Core 检查名称存在，适配器不用维护另一份不完整能力清单。exception filters、completions、stepping granularity、cancel 等走同一协商规则；取消待处理操作和停止清理不受界面功能禁用影响。Java 热替换仍用已有 `redefineClasses` 的输入、结果及错误语义。

### 6. 宿主继续拥有资源及停止策略

Provider 记录绑定包版本、启用代次、工作区和操作。准备及连接具有有界期限，调试会话本身没有总时长；禁用与启动交错时，执行前再确认，已创建资源进入同一清理链。取消、停止和失败丢弃晚到结果，重复停止共享完成状态。

adapter、debuggee、终端、共享服务和外部 attach 目标分别记录所有权。launch 停止自己拥有的程序，attach 默认只断开；Java Stop 不终止 JDT LS。子会话及 runInTerminal 沿用现有管理器；只在平台真正实现时向 DAP 公告反向请求支持。

安装目录和插件包只读。日志、缓存、锁及临时状态通过平台存储 adapter 写入可写目录，会话结束回收会话资源，不影响签名或 Sparkle delta。实施新增下载/缓存时再同步 worktree 资源清单、校验路由及 CI 文档；本 PR 不产生资源。

### 7. P1–P3 独立完成 #1210

| 阶段 | 交付与退出条件 |
| --- | --- |
| P1 内部 Registry | 内置适配器注册为类型化 Provider，保留兼容包装；明确身份、选择、冲突、失效代次及原有运行基线。Java 无需经过插件 JSON |
| P2 最小声明契约 | 正式 schema、Core 语义校验、拟定版本/权限、共享进程扩展、安装与市场审查同批落地；固定传输不需要函数或依赖平台。所有拒绝 fixture 接上实际 Core 测试 |
| P3 第三方纵向验收 | macOS 与 Windows 各自完成纯 Debug 插件安装、选择、launch/attach、断点、线程/栈/变量、停止和资源回收；两端提供独立证据，保留旧行为 |

Swift/Rust 内核整合可在 Provider 背后逐步做，不以删旧引擎为本任务前提。动态 resolver、依赖安装和指令/内存能力分别推进，不能成为 #1210 关闭的隐性条件。

### 正确做法与反例

正确做法：一个只提供 stdio DAP 的插件声明自己的进程，用户显式选择它，现有窗口按协商结果显示断点与变量；没有 selectors、能力块或后端也能工作。Java 内置实现登记到同一目录，但继续向 JDT 读取工程事实。

反例：为了接入一个 stdio 进程，要求插件先写依赖包、导出、两步流程，再逐项列出全部 DAP 能力；或者允许第三方写一个 JDT 名称就访问宿主共享服务。这两种方式都超出基础接入的必要范围。

## 考虑过的备选方案

- Debug 同时建立依赖、导出与工作流：上一版采用；撤回，因为涉及市场、版本冲突、信任及所有领域，需要单独设计。并不否定未来通过依赖复用 JSON，只是不让 Debug 接入等待平台重构。
- 第一期开放本包函数 resolver：比跨包调用简单，但仍改变领域结果边界和后端生命周期；后置到独立版本，先完成固定声明的真实流程。
- 为所有能力显式标注 DAP/function/disabled：会让静态清单与运行时协商漂移。改为默认 DAP、只允许禁用，扩展函数有契约后再评审。
- 继续按语言字符串工厂开放第三方接口：迁移最少，但无法支持一后端多语言、一语言多后端及无源文件目标。只留兼容包装，不作为最终公共 API。
- 第三方自带另一套 UI 或自研统一调试器：重复现有 DAP、线程/栈/变量和资源管理，偏离本任务。

## 验收标准

- 同一 Registry 覆盖内置与第三方；明确选择、关联、候选歧义、重复身份、禁用失效均有标准输入/结果。纯 Debug 插件无需语言和 UI。
- P2 先通过正式 Core 接受/拒绝 fixtures，包括完整清单版本、requires、权限、目标事实、资源路径和过期计划；结构 schema 通过不等于语义通过。
- P3 至少一个真实第三方 DAP 完成安装到命中断点、查看线程/栈/变量和停止；launch 与 attach 分别验证所有权，失败、取消、禁用和迟到子会话不留下资源。
- API 1/2/3、Run 配置、Build/VCS/语言/UI/设置、私有函数和既有 debug 命令的兼容结果保持不变。Node 子会话、Java 测试/JDK/热替换及终端不因接入回退。
- 两端使用同一契约和 fixtures，各自实际验证。实施阶段更新功能矩阵，只有运行成功的平台才标记 verified；本设计 PR 不更改实现状态。
- 独立依赖平台、私有 resolver 和原生扩展尚未完成，也可以在上述目标满足后关闭 #1210。

## 风险

- 固定形状不能覆盖所有后端准备：复杂内置链路保留 Provider 实现；收集真实缺口后再设计 resolver，不用这一限制重建项目模型。
- 固定 TCP 端口可能冲突或连接到错误进程：平台无法证明归属时拒绝，优先 stdio 或本次进程公告端点，不声称所有传输跨平台均可用。
- DAP 协商与宿主投影不同步：有效支持取协商、宿主实现和授权的交集，功能未实现时不点亮按钮。
- 拟定版本可能与并行工作冲突：实施前重新核对能力表，不改变任何已发布编号的语义。
- 旧 Swift/Rust 能力不齐：保留可回退的 Provider 包装；完整行为等价后才移除旧路径。

## 验证

本 PR 离线验证唯一 Draft 2020-12 schema 和结构拒绝输入；Core 语义 fixtures 只登记待实现的验收条件，不计为通过。运行 `./scripts/verify-agent-notes.sh`、`./scripts/verify-shared-contracts.sh`、`./scripts/verify-runtime-bundle-immutability.sh` 和 `git diff --check`。本阶段没有应用构建、后端启动或真实调试证据。

实施阶段加载 `write-stable-tests`，按所属范围运行 `./scripts/verify-rust-core-comments.sh`、`./scripts/verify-rust-core.sh`、`./scripts/test-macos.sh`、`./scripts/verify-service-boundaries.sh` 与 `./scripts/verify-windows-boundaries.sh`。Windows 上另行执行 `./scripts/build-windows.ps1 -Configuration Release`、宿主 Rust 与前端测试。所有等待有界，失败也释放资源，结束后确认本次启动的 Lithe 与子进程已退出。

平台行为修改前运行功能矩阵变更门禁及 `./scripts/verify-platform-feature-matrix.sh`；真实工作流前后比较安装目录清单/哈希。正式契约与 Core 同批修改，合并后按[两仓库发布规则](../../implemented/architecture/2026-10-23-plugin-contract-publishing.md)同步 `lithe-plugin-docs`；若未来修改函数协议，先修订所属决策并在 docs 仓库验证两个 SDK。

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
- `macos/Sources/Lithe/Platform/MacOS/Debug/`
- `windows/tauri/src/features/debugger/`
- `windows/tauri/src-tauri/src/debug.rs`

## 依据

- [公共扩展契约](2026-10-13-public-extension-contract-and-provider-api.md)、[能力版本](../../implemented/architecture/2026-10-17-plugin-capability-versions.md)、[Build Provider](2026-10-17-build-system-provider-api.md)。
- [Java 构建与启动边界](../../implemented/architecture/2026-09-18-java-project-build-and-launch-boundary.md)、[Run JDK](../../implemented/bug-fix/2026-10-14-java-debug-uses-the-run-jdk.md)、[Windows Java 生命周期](../../implemented/bug-fix/2026-10-07-windows-java-debug-lifecycle.md)。
- [DAP 标准](https://microsoft.github.io/debug-adapter-protocol/overview)、[DAP 定义](https://github.com/microsoft/debug-adapter-protocol/blob/main/debugAdapterProtocol.json)、[debugpy](https://github.com/microsoft/debugpy)、[Java Debug Server](https://github.com/microsoft/java-debug)、[js-debug](https://github.com/microsoft/vscode-js-debug)、[LLDB DAP](https://lldb.llvm.org/use/lldbdap.html)、[GDB DAP](https://sourceware.org/gdb/current/onlinedocs/gdb.html/Debugger-Adapter-Protocol.html)。
