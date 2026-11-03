# Agent 笔记：公共扩展契约与原生 Provider 接入方向

状态：提议中

## 先说结论

PR #37 建立了第一阶段 UI Contribution（插件声明的界面入口）；到 2026-10-30，Mac 已有原生 Tree/List/Form、包内网页和独立后端，不再只是静态文本窗口。下一步先走 macOS 路线，把已有编辑器、文件和命令功能开放成有授权、版本与生命周期的公共 API，再接续领域 Provider（提供业务数据、行为或进程的实现）。不恢复任意第三方 Swift Bundle 动态加载，也不把 WASM 运行时作为补齐 API 的前置条件；任务与公开文档待办见 [macOS 插件 API 实施计划](../../../../docs/development/macos-plugin-api-plan.md)。

## 问题

最初的 API level 2 要求窗口使用 `text`，命令只能打开自身窗口，插件校验依赖语言或 UI。这是第一阶段的历史背景，不是今天的完整能力表：当前 Core 已允许纯 Build/VCS/Debug/项目生成器插件，Mac 的 `ui:3` 也已经支持原生树、列表和表单。

当前缺口在于通用接入：`ui.commands` 仍绑定自身窗口；原生动态数据源绑定自身构建系统和唯一实例；`backend:1` 是每插件一个应用级本机进程，只由自身网页调用，不识别远程工作区。函数协议 v2 已有本插件凭据服务，但尚不是通用工作区/编辑器 SDK。开发者不能因为内部 Swift 模块能操作文件或编辑器，就直接从第三方后端调用它。领域能力的进一步迁移也不能与通用宿主 API 混为一谈。

## 提案

### 原生 UI 与窗口管理分离

第三方插件可声明版本化 JSON UI 组件树，包含 Tree/List/Form/Input/Button、数据源和事件，由 macOS SwiftUI 等原生适配器渲染。窗口外壳继续由宿主管理停靠、标题、活动栏、顺序、显隐、布局和生命周期；组件事件通过宿主授权的动作或 Provider 调用。

2026-10-18 起，插件也可以在宿主管理的窗口里放自己的包内网页（`ui` 能力版本 2），这是可选项，不替代组件树。外壳规则不变，加载与桥接边界见[插件自带网页界面](../../implemented/architecture/2026-10-18-plugin-web-content-in-host-windows.md)。

内置或受信任的原生模块可通过 Native View/Renderer Factory（宿主登记的原生视图构造器）接入复杂 SwiftUI 内容，并共用同一套窗口管理。这个路径不等于恢复任意第三方 Swift Bundle 动态加载；二进制接口（ABI）、签名、分发与隔离仍需单独设计。数据契约不含 SwiftUI 类型，但本轮只实施和验收 Mac，不要求先完成 Windows 适配。

截至 2026-10-28，原生 Tree/List/Form 及面板动作已落地，见[声明式原生插件树与动作](../../implemented/feature/2026-10-21-declarative-native-plugin-ui.md)。后续应扩展通用数据源与分页，而不是重新实现一套控件；面板内动作不等于已支持独立全局命令。

### 动作独立于窗口

后续动作独立声明处理器、可用条件和上下文条件，命令可以没有 Tool Window。菜单、右键菜单、工具栏、状态栏与设置项可引用动作或其他类型化贡献；打开窗口只是动作的一种行为。具体条件模型和处理器传输形式需通过新契约定义，不把任意表达式或脚本当成现成实现。

### Mac 优先的宿主能力与隔离

公共接入分成四种：插件声明贡献、插件提供业务回调、插件调用宿主服务、宿主发布语义事件。SDK（供插件作者调用的开发库）封装这些方向，但不提供绕过权限的万能调用器。先以独立命令读取未保存选区，再完成按文档版本修改、一次撤销、目录树和 HTML 预览；不能把“监听按钮”实现成截获任意原生控件或其他插件输入。

继续复用现有外部后端和 JSON-RPC（带请求 ID 的进程通信）生命周期，不另建一套进程管理。无网页激活、工作区上下文及新宿主服务需要明确的新能力协商，保持 `backend:1` 的应用级、页面入口和旧包语义。每次调用都绑定插件会话、窗口、工作区代次和所操作的文档版本，宿主核验授权；不能让迟到结果落到后来切换的工程，也不能缺上下文时猜“当前窗口”。

后端调用宿主的原语与宿主调用领域 Provider 是不同方向。[函数契约](../../implemented/architecture/2026-10-20-plugin-function-contract.md)中的递归拒绝继续有效；不得借新 `commands.execute` 候选入口将完整 Build/函数/IDE dispatcher 暴露给 Provider，使处理器等待自己。已有单独授权的 IDE/MCP broker 也不自动成为第三方后端的权限。

现有文件端口、文档模型和 LSP 编辑链路是可复用的 owner，不是公共访问已经安全的证据。文件访问仍需路径/符号链接竞态防护；编辑先检查明确文档与预期版本，保护 dirty 内容、撤销和输入法。包内网页、工程 HTML 预览和系统浏览器分开授权，任意 HTML 不能继承插件桥接身份。

进程隔离与宿主授权不等于操作系统沙盒；原生后端可以拥有自己的系统权限，文档不能承诺代理之外的访问都被限制。WASM（可移植字节码）可在未来用 Wasmtime/WASI 等运行时承载，但仍需同一组 API、权限、取消和预算，且执行不进入应用主进程。它不依赖 Tauri，也不解决公共 API 缺失，因此暂不列为首版条件。

公开文档和 SDK 继续只发布到 lithe-plugin-docs；主仓库计划只列内部任务与验收，不提供第二套开发者手册。新增契约与 Core 一起改、合并后同步副本，SDK 源码、正式发布物、契约锁定版本与 Mac 实际执行能力分别记录，避免“SDK 有方法但宿主不能执行”。

### 领域扩展点与宿主调度

公共 Extension Contract（插件和宿主交换能力声明及调用结果的协议）覆盖 Language/LSP、BuildSystem/Task、RunConfiguration/Test、DebugAdapter 和 ServiceProvider。Provider 提供业务行为、进程协议或数据，宿主负责发现、调度、权限、展示、取消、超时、失效结果和资源生命周期。纯 Build/Debug 等入口已存在；尚待定义的通用 Services 与独立命令也不应为了通过校验而造空语言或空窗口。

版本控制（VCS）也作为领域扩展点接入，但第一期统一模型只服务插件 Provider：内置 Git 按 2026-10-22 评审暂不接入，仍由 Git 模块持有，见[统一 VCS 模型与 Provider 接入](2026-10-22-unified-vcs-provider-model.md)。因此插件目前没有读取内置 Git 状态的公共入口，是否开放只读快照见实施计划 API-42。

内置模块和插件尽量实现相同领域 Provider 契约。Build/Run/Test/Debug 等采用类型化 Registry（按能力类型登记和查询实现的目录），组合根负责装配通用适配器，不按新增插件名追加分支。先盘点并复用已有语言服务器、构建工具、运行/测试和 DAP（调试适配器协议）链路；上游拥有的项目、任务和依赖事实仍由原工具提供，避免再造一套解释器、工程模型或调试 UI。

[PR #1517](https://github.com/1lck/Lithe-IDEA/pull/1517) 已于 2026-10-28 合并，扩展了原生 Build/Run/Test/Debug 准备与只读工程模型输入；Mac 已声明 `buildProviders:1–6`、`buildModelInputs:1`、`debugAdapters:1/2`（以 `PluginTypes.swift` 的 `hostCapabilities` 为准）。后续只补文档、SDK 对齐和端到端验收，不另建协议。[PR #1515](https://github.com/1lck/Lithe-IDEA/pull/1515) 于 2026-10-29 合并，把远程工作区的文件、工作区、终端、Build 以及 Build/VCS/语言 Provider 启动路由到远程适配器，但它是阶段性实现，范围见下一节。

Debug 的统一内核、三层能力、插件声明与迁移验收见[统一调试内核与调试适配器 Registry](2026-10-25-unified-debug-engine-and-adapter-registry.md)，跟踪当前仓库的 [#1210](https://github.com/1lck/Lithe-IDEA/issues/1210)。寄存器、内存、反汇编等可选能力另见[可选调试扩展](2026-10-25-optional-debug-extensions.md)，插件依赖与导出另见[平台级独立提案](2026-10-25-plugin-dependencies-and-exports.md)；两者都不作为 #1210 的前置条件。这些提案没有开放新字段，也不改变其他领域 Provider 的设计。

### 通用 Services 与资源所有权

Services 接入容器、Spring Boot、数据库和本地服务。后续统一设计 ServiceProvider/ServiceDescriptor/Instance/Status/Actions/Logs 的语义；这些名称是设计目标，当前没有公布字段全集或承诺已经实现。

宿主必须区分插件创建并拥有的资源与用户独立运行的外部服务。禁用插件时注销贡献、关闭它拥有的连接/监听/进程和任务；对外部服务释放观察或连接，不能默认停止外部实例。用户显式调用停止动作时另行核对授权与目标。权限、归属与取消语义先进入契约和 fixtures，再接入真实服务。

### 工作区 authority、激活与保存前事件

远程工作区（见[远程工作区按根目录路由](../../implemented/architecture/2026-10-24-remote-workspace-routing.md)）在本机以空占位根目录打开，由 `RemoteWorkspaceRegistry` 绑定会话和远程根；`backend:1` 与网页 bridge 目前只认本机工作区。公共 API 的资源标识因此需要显式 authority：首版只承诺本机，未实现的 authority 明确拒绝，不把占位根或远程路径当本机路径，也不静默在本机执行。

激活事件目前只能与已声明的 Provider 或窗口命令一一对应，没有独立命令、工作区匹配事件和统一的启动预算；应用也没有工作区信任概念，只有逐操作确认。这两点在实施计划 M0 定稿（API-40、API-41），本 Note 不预设答案。保存前事件（`documents.onWillSave`，API-43）依赖版本化编辑与严格截止时间，晚于单文档编辑落地。

Agent 的 Skills、Hooks、MCP 是用户管理的 Codex/Claude 原生配置，插件没有贡献来源。是否允许插件提供候选（API-44）与 IDE broker 的威胁建模一起评审：候选只能经用户确认写入明确来源，不能自动启用。

### 版本与兼容性

已发布 API level 和能力版本保持既有字段、校验和行为，包括 `pluginAPIVersion=2`。交互组件使用单独版本化的 UI Schema；独立动作和新增领域扩展点进入明确的新契约版本，具体版本号及协商字段在后续任务中确定。文档中的未来能力不会被旧校验器默许，也不能让已发布包因新增版本而必须改写。未知版本和未实现能力继续由宿主与市场兼容性检查明确拒绝；共享 fixtures 验证各版本的接受、拒绝与迁移。

### 正确做法

插件声明一个原生 Tree、数据源及独立刷新动作，宿主渲染 Tree 并把刷新交给授权 Provider。另一个纯 Build 插件只贡献任务，宿主将任务展示在既有 Build 入口；都不需要按插件名称修改工作台。

### 不要这样做

- 为刷新命令造空 Tool Window，或为 Build Provider 伪造语言声明。
- 插件自行实现窗口外壳，或用自己的页面另建 Run/Debug/Services 页面。
- 在组合根按插件名称追加 Maven/Debug 特例，复制已有语言服务器和运行/测试引擎。
- 将禁用插件解释为停止用户从终端或其他程序启动的服务。

## 考虑过的备选方案

- 将静态文本和打开窗口固定为最终 API：易验证，但无法覆盖交互 UI 和纯领域能力，因此仅保留为 v2 子集。
- 直接载入第三方 Swift Bundle：可快速表达复杂原生内容，但没有稳定 ABI，签名与隔离无法覆盖，不采用。
- 第三方 Webview UI：原先不采用。2026-10-18 改为可选路径，限定为包内页面、宿主外壳和白名单桥接，理由与边界见[插件自带网页界面](../../implemented/architecture/2026-10-18-plugin-web-content-in-host-windows.md)。
- 在 #37 一次完成全部组件和 Provider：会扩大未验证协议及迁移面；先保留基础设施，再按领域纵向验收。
- 先全面改为 WASM 再开放 API：可以研究更严格的执行限制，但不能替代文件、编辑器和命令语义，还会增加工具链与分发工作；先交付 API，运行时以后单独验证。
- 直接导出 AppModel、完整命令 dispatcher 或原生模块接口：接入快，但会泄漏内部类型、扩大权限并造成递归/生命周期耦合；只开放有类型、有授权且可撤销的能力。

## 验收标准

- 原生 Tree + 独立刷新命令；只提供命令的插件不声明窗口也能注册和调用。
- 无窗口选区转换插件读取 dirty 文档、按版本应用编辑并一次撤销；冲突/只读/IME/越权安全处理，多窗口与失效结果不串工程。
- 分页文件树和 HTML 预览样例完成安装到停用的全过程；工程网页没有插件桥，外部浏览器与内嵌预览的未保存内容语义明确。
- 第三方 Build Task 出现在既有 Build；运行与测试复用既有配置、输出和取消链路。
- 第三方 ServiceProvider 出现在 Services；禁用清理插件资源，同时用户独立服务继续运行。
- 第三方 DAP 进入既有 Debug UI，完成断点、启动、停止和会话清理。
- 各样例覆盖安装、授权、启用/禁用、失败/晚到结果、恢复与布局持久化；无窗口 Provider 验证不会生成窗口或污染布局。
- 已发布 API v2 fixtures 继续通过；新版本 schema、兼容性拒绝和市场能力检查先于平台适配落地。
- 本轮只要求 Mac 产品验收；共享契约保持平台无关，功能矩阵如实记录各端现状，不把 Windows 适配作为本计划前置条件。
- SDK、公开文档和样例在 lithe-plugin-docs 随各切片交付；契约副本锁定合并后的 preview commit，源码支持和正式 release 不混写。

## 风险

交互事件与进程调用会扩大权限和异步状态边界，需要明确归属、预算、取消及错误语义。内置模块迁移要保持已有项目、运行、调试、服务及布局行为；先验证一个 Provider 的完整流程，并保留发布层面的迁移回退手段，不做运行时双实现静默回退。公共 API 尚未实现前，不能把概念名称写成已发布字段或允许旧版本接受它们。Mac 优先降低首版交付面，但文档/SDK 与宿主的版本同步仍是成本；原生后端没有 OS 沙盒的风险不能靠权限 UI 掩盖。

## 验证

- 本次计划只校验文档与边界：`./scripts/agent-notes/verify-agent-notes.sh`、`./scripts/architecture/verify-shared-contracts.sh`、`./scripts/macos/verify/verify-runtime-bundle-immutability.sh`、`./scripts/platform-feature-matrix/verify-platform-feature-matrix.sh`。
- 后续实现按实施计划的三个真实插件验收，包含 SDK 端到端、Mac 实机、越权/取消/失效结果、进程清理与 bundle 哈希不变；本 Note 不将计划中的验收记成已经通过。

## 适用范围

- `shared/contracts/plugins/v1/`
- `rust/lithe-core/src/plugins/`
- `macos/Sources/LitheModuleAPI/`
- `macos/Sources/LitheApplicationKernel/`
- `macos/Sources/Lithe/Platform/MacOS/MacServiceContainer.swift`
- `macos/Sources/Lithe/Views/Workbench/`
- `docs/development/macos-plugin-api-plan.md`

## 跟踪任务

- [公共扩展契约总跟踪 #13](https://github.com/Lithe-IDEA/Lithe-IDEA/issues/13)，迁移总跟踪 #16。
- [独立动作、领域能力与版本 #39](https://github.com/Lithe-IDEA/Lithe-IDEA/issues/39)。
- [声明式原生 UI 与宿主 Renderer #40](https://github.com/Lithe-IDEA/Lithe-IDEA/issues/40)。
- [Build/Run/Test Provider #10](https://github.com/Lithe-IDEA/Lithe-IDEA/issues/10)。
- [DebugAdapter Registry 与 DAP #41](https://github.com/Lithe-IDEA/Lithe-IDEA/issues/41)。
- [通用 ServiceProvider 与资源归属 #42](https://github.com/Lithe-IDEA/Lithe-IDEA/issues/42)。
- [四个纵向端到端样例 #14](https://github.com/Lithe-IDEA/Lithe-IDEA/issues/14)。

本 Note 保留公共扩展的未完成方向；已落地部分以[第一阶段工作台 UI 贡献](../../implemented/architecture/2026-10-12-workbench-ui-contributions.md)、[原生插件 UI](../../implemented/feature/2026-10-21-declarative-native-plugin-ui.md)及[插件契约](../../../../shared/contracts/plugins/v1/README.md)为准，不能再把第一阶段限制当成全部当前能力。
