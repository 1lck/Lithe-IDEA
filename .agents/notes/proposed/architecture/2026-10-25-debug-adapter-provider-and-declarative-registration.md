# Agent 笔记：调试适配器的声明式注册与统一会话模型

状态：提议中

## 先说结论

针对 [DebugAdapter Registry 与第三方 DAP 接入 #1210](https://github.com/1lck/Lithe-IDEA/issues/1210)，以插件好写和逻辑复用为优先：JSON 声明依赖、导出、能力、后端入口与流程组合，公共插件可以继续依赖其他插件；动态计算复用插件函数调用，并通过类型化领域契约校验结果。宿主承担通用解释与适配复杂度，允许为此迭代 API。内置与第三方适配器进入同一个类型化 Registry（按能力登记和查询实现的目录），共用现有调试窗口和 DAP（Debug Adapter Protocol，编辑器与调试后端之间的标准协议）内核。

统一的是会话、操作和生命周期，不要求所有后端具备相同的功能；语言专属参数与扩展能力继续由对应后端解释。本提案没有开放任何新字段，也不改变现有插件、运行配置、构建接口或调试命令；下面的概念名须在实现时与契约、校验器和标准用例一起确定。

可讨论的 [JSON Schema 与示例](../../../../shared/proposals/debug-adapters-1210/README.md)单独放在 `shared/proposals/`，包含依赖与导出、JSON 组合、能力声明及有效状态、解析后的配置与启动方案。它们没有进入正式插件契约；保留现有进程启动定义的引用，解释器等运行时优先从依赖插件取得。

## 问题

### 当前实现与应当复用的部分

以下盘点基于 `preview` 提交 `e854cfd98e4a52fe5abacff2002efd9f68082da2`。它描述源码入口，不代表所有语言或两端都已完成运行时验收。

| 入口 | 已有责任 | 本次应如何使用 |
| --- | --- | --- |
| `rust/lithe-core/src/debug/` | DAP 分帧、请求关联、状态转换、断点、变量分页、取消、反向终端请求、Java 热替换 | 扩展已有内核，不再写第三套协议状态机 |
| `macos/Sources/LitheCoreContracts/Debug/` | 平台无关的会话、传输、启动参数、调试操作模型 | 公共模型的兼容入口，新增身份不能改写既有字段含义 |
| `macos/Sources/LitheDebugModule/Runtime/DebugAdapterSessionManager.swift` | 多会话、激活代次、事件、断点与停止 | 演进为从 Registry 选择目标，保留旧入口的兼容适配 |
| `macos/Sources/Lithe/Services/Debug/DebugAdapterRuntimeFactory.swift` 与 `MacServiceContainer.swift` | stdio 适配器，以及 Java、Go、Node 的专用构造 | 将语言字典逐步替换成 Provider 注册；平台进程和连接能力继续留在平台层 |
| `macos/Sources/Lithe/Services/Debug/DebugLaunchConfigurationResolver.swift` 与 `DebugLaunchPreparationCoordinator.swift` | 按语言准备启动参数、保存与 Java 启动目标解析 | 将策略放进对应 Provider，复用 Run 的准备流程与运行时选择 |
| `windows/tauri/src/features/debugger/` 与 `windows/tauri/src-tauri/src/debug.rs` | 调试界面、事件投影、进程与 TCP 传输、Rust Core 调用、资源释放 | 独立实现同一契约，保留已有调用信封和断点先于 launch 入队的顺序 |
| `shared/contracts/plugins/v1/` 与两端插件宿主 | 能力版本、安装审查、工具链与进程启动、插件禁用 | 增加独立 Debug 能力，不借语言或 UI 声明取得注册资格 |

macOS 的通用工厂和 Go、Node 目前使用 Swift `DebugAdapterProtocolSession`，Java 使用 `CoreDebugAdapterProtocolSession`。迁移不能直接删掉前者：它已有子会话处理，Rust 路径需先覆盖对应行为和反向请求，再逐个切换。

### 已有工具与缺口

| 目标 | 可复用的上游 | 当前版本或分发状态 | 接入前必须确认 |
| --- | --- | --- | --- |
| Java | JDT LS 与 Microsoft Java Debug Server | `third_party/jdtls/manifest.json` 固定 JDT LS 1.61.0、Java Debug Server 0.53.2；插件包提供资源 | 保留 JDT 工程事实、Java 测试与热替换，继续使用 Run 为同一目标选择的 JDK |
| Python | `debugpy` | 现有入口为 Python 执行 `-m debugpy.adapter`，没有统一锁定适配器版本 | 解释器、虚拟环境与适配器可用性；不在启动时静默安装依赖 |
| JavaScript / TypeScript | Microsoft `vscode-js-debug` standalone DAP server | 已有 Node TCP transport 与本地发现入口，没有统一锁定后端版本 | source map、`startDebugging` 子会话、终端与版本兼容范围；复用可独立使用的开源 server |
| Go | Delve DAP | 已有 `dlv` 发现和服务端 transport | 保留端口发现、取消和进程树回收行为 |
| C / C++ / Rust / 汇编 | `lldb-dap`，以及具备 DAP 支持的 GDB | Rust 已有 LLDB 发现和启动入口；其他目标与 GDB 不据此宣称可用 | 目标平台和架构、调试符号、DAP 构建能力、许可证、寄存器与反汇编支持 |

GCC 是编译器。Debug 应消费构建系统返回的可执行产物和符号，不把 GCC 当作调试适配器，也不按固定输出目录猜测程序路径。LLDB/GDB 可以服务多种语言，同一种语言也可以选择不同调试后端。

以上适配器的升级或启用应先于自研替代方案。新增打包资源前，必须固定来源、版本、哈希和许可证；用户工具链的版本则通过既有发现机制取得并核对兼容范围。本提案不新增下载入口、缓存或第三方依赖。

## 提案

### 1. 保留三条接口边界

| 边界 | 提供什么 | 不承担什么 |
| --- | --- | --- |
| 声明式注册与组合 | 稳定身份、依赖导出、能力策略、配置 schema、函数绑定与步骤组合 | 复制上游工程模型，凭静态布尔值断言某次会话必然可用 |
| 动态准备 | 复用依赖插件和函数，读取上游目标与工具链，引用现有构建动作，产生可校验的启动方案 | 各自重写公共启动、调用、取消、连接与清理机制 |
| 调试会话 | 执行 DAP，投影线程、栈和变量，管理取消、终端与停止 | 重新推算 Java classpath、构建产物或 source map |

简单适配器和复杂适配器共用 `use` / `with` 调用及 `steps` 组合。实现来源可以是依赖插件导出、本包插件函数或通用宿主原语；返回同一种类型化结果。公共插件封装 stdio、TCP 端口发现、工程准备等流程，语言插件主要选择依赖与提供参数，不要求每个插件启动新的解析服务。复杂计算复用现有 `lithe/function/invoke`，不另建 `lithe/debug/*` 传输，也不强制纯 Debug 插件声明网页。

目前[插件函数契约](../../implemented/architecture/2026-10-20-plugin-function-contract.md)把函数限定为私有动作，领域结果走独立类型化方法。本提案在新的能力版本中增加显式导出和领域绑定：传输复用现有函数通道，Core 仍拥有领域计划和结果解码。依赖调用由宿主检查导出、契约、调用方和资源授权，再在被调用插件自己的会话上执行；旧私有函数及 `wrongPlugin` 规则不变。JDT 原始服务不被假定实现插件函数，由已有宿主集成适配同一调用模型。

依赖可以递归组合，但依赖图与导出调用图必须无环。流程由宿主驱动，步骤取消传递到本次子调用；等待中的后端处理器不再回调宿主调度自己。包版本限制与导出契约版本分别校验，依赖失效或导出撤回使关联计划立即失效。通用依赖、导出和流程机制应进入统一插件层，不在 Debug 内维护第二套插件管理器。

JSON 流程可以组合工具、前置动作、函数结果与连接资源；最终启动方案只含宿主理解的引用、参数和连接方式。前置动作走既有 Build/Run 调度，明确区分准备前输入与准备后结果，复用现有 Java 编译失败后的继续/取消决策。需要重新编译时，必须完成该决策后再次向事实拥有者取得目标，不能执行构建前缓存的产物或 classpath。先提供有界顺序组合和类型化取值，后续按实际插件需要迭代声明能力。

### 2. 分开 Provider、语言、配置类型和会话身份

Provider 的身份由插件身份与包内局部身份组合，不能覆盖宿主或另一个插件的条目。DAP `adapterID`、导入配置的 `type`、语言 ID、运行配置 ID 与会话 ID 各自保留自己的含义；兼容映射显式登记，不能从可执行文件名推导后端身份。

Registry 的发现阶段只读已验证的声明，不执行工作区程序。Provider 可匹配语言、运行目标、构建产物或用户明确选择的 attach 目标；文件扩展名只是一种条件。调试二进制、连接 JVM 或启动浏览器不需要伪造源文件，也不要求安装一个同名语言插件。

选择顺序为：配置显式选择、工作区已保存关联、平台及目标匹配后的唯一候选。多个同等候选由用户选择；列表按稳定身份排序，插件不能通过自报高优先级抢占内置实现。重复身份拒绝注册；匹配重叠不等于身份冲突。明确选择的 Provider 不可用时报告原因，不静默换后端。

注册记录绑定插件版本与启用代次。重新解析、更新或禁用会让旧记录失效；已解析但尚未执行的启动方案也必须再次检查，而不是拿着旧句柄启动程序。

### 3. 配置保持公共外层与后端参数分离

公共外层表达名称、Provider 引用、`launch` 或 `attach`、目标和配置来源；后端参数由其版本化 schema 校验。已有 `DebugLaunchConfiguration` 的 `name`、`request`、`arguments`、`steppingFilters` 含义不变，由适配层产生它；不把所有语言的字段塞进同一个必填结构体。

原有运行配置 ID、三层配置覆盖规则、导入的 `launch.json` 字段及参数优先级必须保留。尤其不能在合并时用缺失的公共 `program` 或 `args` 覆盖后端已给出的值。未知配置类型继续保留原文并显示不可用原因，不能自动改写成当前默认 Provider。

Java 主类、模块路径和 classpath 来自 JDT；Python 解释器来自已选择的运行环境；C/C++ 与 Rust 产物来自 Build/Run 的结果。Debug 不维护另一份项目模型，也不增加独立的 JDK 选择链。

### 4. 公共会话支持能力差异与无源码位置

能力进入 JSON：`source: dap` 绑定标准协议，`source: function` 绑定同一种依赖/函数组合，`source: disabled` 明确关闭。前者由 DAP 初始化及后续 `capabilities` 事件确认，后者由导出契约、函数注册与宿主适配确认；两者都经过权限及目标检查。有效能力以 JSON 返回，UI 区分尚未确定、已支持和不支持及原因。配置 schema 只校验参数，`requires` 仍只判断宿主契约版本，不把它当作能力支持证据。

沿用已有会话、线程、栈帧、scope（变量分组）、变量和断点模型。原生调试扩展需补充会话内源码引用、指令位置、内存引用、指令断点、指令级单步、反汇编和内存读取；寄存器优先使用后端提供的 scope，不设计一个假定所有 CPU 都相同的寄存器列表。

无源码的栈帧不伪造源文件或行号，缺失位置按新模型显式表达。不能把既有必填数字字段直接改成 `null` 后要求旧消费者自动兼容；新增投影或版本化后，同时更新 Rust、Swift、TypeScript 与 fixtures（跨实现共用的标准输入和预期结果）。地址、内存引用与指令引用保持字符串，避免 JavaScript 数值精度损失；后端引用均为不透明值，不当作文件路径。

工作区源码的可持久化身份仍用相对路径；外部或远端源码通过有明确权限的映射或会话内引用取得，平台进程与 DAP 边界需要的绝对路径不变成跨工作区身份。变量引用和栈帧绑定会话及暂停代次，继续执行、重启或切换目标后不能复用。

Java 热替换等扩展保持已有调用与错误语义，通过 JSON 绑定版本化导出及函数。标准功能也允许使用函数适配，但其输入输出必须满足对应的公共操作契约；宿主未实现该适配时明确报告不支持。普通 UI 按有效能力显示操作，不按插件名称扩充组合根，不绕过会话校验。

### 5. 版本演进不能改变其他 API 的承诺

[插件能力版本规则](../../implemented/architecture/2026-10-17-plugin-capability-versions.md)规定基础字段只随 `pluginAPIVersion` 演进，其中包括 `permissions` 和 `activationEvents`。因此前期讨论中的 `requires.debugAdapters: 1` 只是能力名草案，不能单凭它在 API 3 中加入新的顶层权限或激活事件。

用户明确接受为了插件易写、依赖复用而增加通用适配器复杂度和 API 版本。本提案为独立 Debug 能力、依赖与导出、领域函数绑定及新授权分配相应版本，具体编号在实现时确定。调试授权覆盖读取与修改目标状态，不把已有 `process.run` 或 `languageServer.launch` 静默扩大为 attach、写内存权限。只有使用新特性的包升级；现有语言、Build、VCS、网页、设置和后端包继续使用原版本。

激活默认来自用户的启动或 attach 请求和 Registry 选择，无需为了“看起来一致”给所有旧包增加激活事件。若实现确实需要专用事件，其语法同样放进新 API 级别，不能让 API 1/2/3 接受过去会拒绝的输入。权限不是操作系统沙箱：原生调试程序的进程权限仍受平台和用户授权限制，安装审查必须准确说明它可访问调试目标。

兼容性必须逐项核对：

| 现有表面 | 必须保留的行为 |
| --- | --- |
| 插件 API 1/2/3 | 旧字段、缺省值、拒绝条件、错误优先级、规范化结果和支持范围；新字段不能被旧级别偷偷接受 |
| `requires` 与 `hostCapabilities` | 能校验不代表能运行；市场筛选、磁盘安装、启动扫描与运行前检查使用同一能力表 |
| `serverProcess: 1` | 只复用已有启动语义；DAP 的 TCP 发现或新启动形式放进 Debug 能力或明确的新进程能力版本 |
| Build/Run/Test 与语言服务 | 既有命令、选项来源、配置 ID、JDK 选择与工程事实不因 Registry 改变 |
| `debug.*`、JSON 信封与 C ABI | 保留原命令、载荷和错误语义；新增操作不能重解释旧枚举或破坏穷举解码器 |
| macOS 内置模块与 Windows Worker 插件 | 既有装配和包格式继续存在；Debug 声明式接入不要求迁移无关插件 |
| 插件后端 SDK | 复用现有函数、取消、进度及进程机制；依赖导出和领域绑定显式版本化，不强制 UI；协议扩展做 SDK 端到端验证 |

### 6. 生命周期由宿主执行，资源所有权显式记录

每次准备与操作沿用 `operationID`、取消、超时和失效结果规则，并绑定工作区、Provider 注册代次及会话。启动准备、连接和交互请求分别设有界期限；不能给整个调试会话设总时长，也不能把已有 JDT 工程导入等待缩成普通交互请求的期限。

宿主在创建进程或连接前最后检查启用状态与信任；如果禁用与启动交错，已创建的资源立即进入同一清理链路。重复 Stop 共享同一个清理完成结果，完成前不报告资源已释放；晚到端口、子会话、终端或操作结果必须拒绝并清理。

必须区分 adapter 进程、被调试程序、终端、共享语言服务器和外部目标。`launch` 沿用已有终止所拥有程序的策略，`attach` 默认只断开；结束 Java 调试只释放调试连接及本次资源，不终止共享 JDT LS。插件禁用时清理自身会话，不通过名称或可执行路径批量结束用户独立启动的程序。

`runInTerminal` 继续由 Core 规范化、平台 PTY/ConPTY 创建终端；子会话走同一个管理器，明确父子关系和停止规则。只有两端相应宿主确实实现了反向请求，才在 DAP 初始化中声明支持。

插件包与安装目录均只读。解析过程产出的日志、锁、缓存和临时文件由平台存储 adapter 分配，按插件、工作区与会话隔离；会话内引用不跨 worktree 共享。新增下载或生成资源时，同步维护 `scripts/worktree-resources.json`、资源复用脚本校验路由、对应验证和 `docs/ci-builds.md`，并核对代码签名与 Sparkle 增量更新基线。

### 7. 分阶段替换，阶段之间保留回退能力

| 阶段 | 工作与退出条件 | 兼容性检查 |
| --- | --- | --- |
| P0：行为基线与契约评审 | 列出内置适配器完整启动、断点、变量、终端、子会话和停止序列；确定 Debug 权限及版本方案 | 记录旧输入的接受、拒绝和归一化结果；未完成评审不提前开放新能力 |
| P1：内部 Registry | 内置 Provider 进入类型化目录；通用目标入口与文件兼容入口共存；新增一种适配器不修改语言分支 | 原有 Provider ID 映射、Run 配置、断点与多会话行为通过原回归；两端消费相同选择 fixtures |
| P2：新能力契约 | schema、Core 校验与计划、依赖导出、JSON 组合、能力及函数绑定、安装审查与纯 Debug fixture 同批设计；分步实现真实流程 | 旧 API 与私有函数 fixture 不变；循环依赖、错误导出、撤回与不支持版本准确拒绝；宿主按实现公布能力 |
| P3：第三方纵向流程 | macOS 的纯 Debug 插件进入现有 UI，完成启动或 attach、断点、线程、栈、变量和停止；Windows 独立实现同一契约 | 完成禁用竞态、失败隔离、取消、晚到事件、恢复、安装目录哈希不变；双端各自提供证据 |
| P4：内置链路迁移 | Python、Java、Go、Node、Rust 逐个迁到 Registry 和现有 Rust DAP Core；先补齐被替代路径的能力 | Java Run JDK、JUnit/TestNG、热替换、Node 子会话与 source map、终端和停止均有实际回归；同一目标只启用一个实现 |
| P5：原生与汇编扩展 | 按 DAP 扩充无源码位置、反汇编、内存、指令断点与指令单步，接入经验证的 LLDB/GDB 组合 | 有符号源码调试与无源码指令调试分别验收；不把此阶段当作 #1210 基础 Registry 关闭的前提 |

P1 至 P4 的每个行为改动都维护功能矩阵；某平台只有模型或源码时，运行验证保持 `pending`，不能根据另一端通过就标记完成。只有新入口行为与旧入口等价、所有消费者已迁移，才删除兼容包装；不能为切换方便先移除现有功能。

### 正确做法

- Python 插件依赖运行时插件取得同 Run 的解释器，再依赖公共 DAP 插件完成 stdio 启动；主要写 JSON，断点、变量与停止进入现有链路。
- Java 公共插件用 JSON 继续依赖工程插件，把准备结果传给已有 JDT 适配函数；其他 Java 插件直接引用其调试导出。
- Java Provider 调用既有保存、工程同步和编译流程，向 JDT 读取当前目标，再使用 Run 已选择的 JDK；调试结束释放连接，不结束语言服务器。
- 一个原生 Provider 同时匹配 C、C++、Rust 和汇编目标，用户明确选择 LLDB 或 GDB；没有源码的暂停显示指令位置，不创建假的文件。

### 不要这样做

- 为每个语言插件重复实现端口、资源、取消和工程准备；为了宿主简单，强迫每个插件实现本可共享的后端。
- 把旧私有函数全部开放为跨插件调用，或用任意函数返回值绕过领域结果校验。
- 为纯 Debug 插件声明空语言或空工具窗口，或为了使用现有网页后端而强制生成网页。
- 注册每个插件时都给 `MacServiceContainer`、Windows 前端或 Rust dispatcher 添加插件名称判断。
- 把 `requires` 当权限，将 `process.run` 扩大为任意调试授权，或者在 API 3 下无版本地新增基础字段。
- 仅让新模型跑通一个模拟会话，就删除 Java 测试、热替换、子会话或旧平台清理逻辑。

## 考虑过的备选方案

### JSON 组合与依赖优先

采用此方向。用户希望尽量把逻辑留在 JSON，允许宿主复杂和版本增加换取插件易写。公共流程和工程动作可以通过依赖、导出与步骤复用；真正需要计算时调用函数，结果经过同一个领域解码器。代价是宿主要实现版本化组合器、图检查和调用上下文，而不是把这部分成本转给每个插件作者。

### 所有插件都实现可编程 Provider

表达力完整，也能覆盖 Java 和浏览器。没有作为默认入口，因为普通插件应能直接引用已有 JSON 流程和公共导出；不应为了启动 DAP 再写第二个服务。函数是统一组合模型中的实现来源，不是另一套必写协议。

### 直接复用语言字符串工厂作为公共 API

迁移量最小。但无法表达一种后端支持多语言、一种语言有多个后端，也不能自然接入无源码目标或纯 Debug 插件。保留为迁移包装，不作为最终契约。

### 在 API 3 下只增加能力名，同时新增调试权限

看似只影响 Debug，但违反基础字段的版本规则。新能力可以独立演进，新增基础授权仍需要新的 API 级别；其他包继续使用原级别，避免要求整个生态升级。

### 为每个语言另做一套调试 UI 或改用统一自研调试引擎

短期可以绕过差异，但会复制已有 DAP 功能，或承担 Python、JVM、浏览器与原生代码的调试语义。复用成熟后端与现有窗口，通过协商表达差异。

## 验收标准

- 无语言、无 UI 的 Debug 插件可以在支持对应契约的宿主安装并登记；不支持的宿主在安装和市场阶段拒绝，Core 校验成功不能绕过宿主能力检查。
- 内置与第三方 Provider 使用同一 Registry；覆盖明确选择、工作区关联、重叠候选、重复身份、不可用工具链与禁用 Provider，不按插件名特判。
- 覆盖插件依赖的二级组合、公共流程复用、显式函数导出与领域结果校验；拒绝循环、版本不兼容、未导出和错误资源归属，私有函数仍保持旧拒绝语义。
- 至少一个真实第三方 DAP 完成从安装、选择目标、命中断点到线程、栈、变量和停止的完整流程；`launch` 与 `attach` 分别验证目标进程是否保留。
- 在解析、构建、连接和终端创建的每个等待点禁用或取消，都不留下 adapter、debuggee、监听或晚到子会话；另一个会话和共享语言服务继续可用。
- API 1/2/3、现有运行配置、Build/VCS/语言/UI/设置能力以及 JSON 调试信封的兼容 fixture 保持原结果；旧包无须增加 Debug 字段或更换 API 级别。
- macOS 与 Windows 使用共享 fixtures，并各自给出真实流程证据；运行结束检查本次启动的 Lithe、调试程序及辅助进程均已清理，外部 attach 目标仍按既有策略保留。
- P5 另行验证带符号与无源码程序、源码和指令单步、寄存器 scope、反汇编、只读内存查看与指令断点；后端不支持的功能明确显示不可用。

## 风险

- 组合器增加长期维护成本：以真实共享流程驱动版本演进，依赖和类型化函数覆盖复杂计算；不能以降低宿主成本为由把同一逻辑分散到所有插件。
- Swift 与 Rust 路径能力不齐：先用同一输入与事件序列对照，再逐个迁移；未覆盖的适配器继续保留旧路径，不宣称完成统一内核。
- 动态计划与权限脱节：安装审查、运行前检查及实际执行要验证同一个插件版本、获准程序和权限；不能信任 Provider 返回的任意命令或端点。
- 版本方案与其他并行 API 工作冲突：实现前重新核对基础版本和能力表，只分配下一可用版本；本提案不预占正式版本号，不放宽其他能力校验。
- 后端和平台支持不等价：GDB 的 DAP 构建能力、系统调试权限和架构必须实测；不能承诺一个模型让所有后端具备完全相同的行为。
- 移除旧入口过早：保留按 Provider 控制的迁移开关，同一目标不双启动；回退不改用户配置、不重新绑定断点、不退回错误运行时。

## 验证

本提案阶段修改架构记录和独立评审 schema，使用本机已有的 Python `jsonschema` 离线检查 Draft 2020-12 schema、示例、参数与关键拒绝条件，再运行 `./scripts/verify-agent-notes.sh`、`./scripts/verify-shared-contracts.sh`、`./scripts/verify-runtime-bundle-immutability.sh` 和 `git diff --check`。这些检查不构成新增 Debug 功能或平台运行证据。

实现阶段按改动范围运行：

- 契约与 Rust：`./scripts/verify-shared-contracts.sh`、`./scripts/verify-rust-core-comments.sh`、`./scripts/verify-rust-core.sh`，以及所属插件和调试用例。
- macOS：受影响调试、Run 配置、Java 测试与资源清理回归，通过 `./scripts/test-macos.sh` 和 `./scripts/verify-service-boundaries.sh` 验证边界。
- Windows：`./scripts/verify-windows-boundaries.sh`；在 Windows 执行 `./scripts/build-windows.ps1 -Configuration Release`、宿主 Rust 测试及受影响前端回归，再运行真实 Debug 流程。
- 测试实现：加载 `write-stable-tests` Skill，使用对应单测试计时 harness，所有等待有界、测试资源独立、退出清理可观测。
- 功能与资源：`./scripts/verify-platform-feature-matrix-change.sh origin/preview HEAD`、`./scripts/verify-platform-feature-matrix.sh`、`./scripts/verify-runtime-bundle-immutability.sh`，并比较真实工作流前后的安装目录文件清单与哈希。

正式契约仍在主仓库与 Core 同批修改，合并后按[插件契约发布规则](../../implemented/architecture/2026-10-23-plugin-contract-publishing.md)同步到 `lithe-plugin-docs`；面向插件作者的指南写在该仓库。如果动态解析需要扩展插件后端协议，合并前在该仓库运行两个官方 SDK 的端到端验证，不能只靠主仓库测试。

## 适用范围

- `rust/lithe-core/src/debug/`
- `rust/lithe-core/src/plugins/`
- `shared/contracts/plugins/v1/`
- `shared/proposals/debug-adapters-1210/`
- `shared/contracts/application-boundary.md`
- `shared/contracts/rust-core-api.md`
- `shared/fixtures/debug/`
- `shared/platform-feature-matrix/features/`
- `macos/Sources/LitheCoreContracts/Debug/`
- `macos/Sources/LitheDebugModule/`
- `macos/Sources/Lithe/Services/Debug/`
- `macos/Sources/Lithe/Platform/MacOS/Debug/`
- `macos/Sources/Lithe/Platform/MacOS/MacServiceContainer.swift`
- `windows/tauri/src/features/debugger/`
- `windows/tauri/src-tauri/src/debug.rs`
- `windows/tauri/src-tauri/src/plugin_host/`

## 依据

- [公共扩展契约方向](2026-10-13-public-extension-contract-and-provider-api.md)、[构建 Provider 提案](2026-10-17-build-system-provider-api.md)。
- [Java 构建与启动边界](../../implemented/architecture/2026-09-18-java-project-build-and-launch-boundary.md)、[Java Debug 与 Run 的 JDK](../../implemented/bug-fix/2026-10-14-java-debug-uses-the-run-jdk.md)。
- [Windows Java 调试生命周期](../../implemented/bug-fix/2026-10-07-windows-java-debug-lifecycle.md)、[断点路径身份](../../implemented/bug-fix/2026-10-07-windows-debug-breakpoint-path-identity.md)、[Windows 声明式宿主](../../implemented/architecture/2026-10-22-windows-declarative-plugin-host.md)。
- [DAP 标准](https://microsoft.github.io/debug-adapter-protocol/overview)、[DAP 协议定义](https://github.com/microsoft/debug-adapter-protocol/blob/main/debugAdapterProtocol.json)。
- [debugpy](https://github.com/microsoft/debugpy)、[Java Debug Server](https://github.com/microsoft/java-debug)、[JavaScript standalone server](https://github.com/microsoft/vscode-js-debug)、[LLDB DAP](https://lldb.llvm.org/use/lldbdap.html)、[GDB DAP](https://sourceware.org/gdb/current/onlinedocs/gdb.html/Debugger-Adapter-Protocol.html)。
