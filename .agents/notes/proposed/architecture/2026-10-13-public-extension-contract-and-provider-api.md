# Agent 笔记：公共扩展契约与原生 Provider 接入方向

状态：提议中

## 先说结论

PR #37 是第一阶段 UI Contribution（插件声明的界面入口）基础设施：稳定 ID、宿主窗口管理和模块生命周期继续作为后续基础。静态文本窗口与打开自身窗口的命令只是 API level 2 的首个可验证子集，不能成为最终公共插件接口的能力上限。后续采用版本化的原生 UI 声明和领域 Provider（提供业务数据、行为或进程的能力实现），由宿主接入既有编辑器、Build、Run、Debug 和 Services。

## 问题

当前 `ui.toolWindows` 至少包含一个窗口且要求 `text`，`ui.commands[].toolWindowID` 必填；Rust 拒绝既无语言声明也无 UI 的插件。这些规则适合验证第一条接入链路，却不能表达独立刷新命令、纯构建插件或调试适配器。`database.services` 仍由数据库模块和 `DatabaseServicesView` 提供，组合根也仍分别装配 `MavenService` 和按语言选择的 `debugFactories`。这些是当前实现，不是未来所有扩展点都必须依赖语言或数据库的决定。

## 提案

### 原生 UI 与窗口管理分离

第三方插件可声明版本化 JSON UI 组件树，包含 Tree/List/Form/Input/Button、数据源和事件，由 macOS SwiftUI 等原生适配器渲染。窗口外壳继续由宿主管理停靠、标题、活动栏、顺序、显隐、布局和生命周期；组件事件通过宿主授权的动作或 Provider 调用。

2026-10-18 起，插件也可以在宿主管理的窗口里放自己的包内网页（`ui` 能力版本 2），这是可选项，不替代组件树。外壳规则不变，加载与桥接边界见[插件自带网页界面](../../implemented/architecture/2026-10-18-plugin-web-content-in-host-windows.md)。

内置或受信任的原生模块可通过 Native View/Renderer Factory（宿主登记的原生视图构造器）接入复杂 SwiftUI 内容，并共用同一套窗口管理。这个路径不等于恢复任意第三方 Swift Bundle 动态加载；二进制接口（ABI）、签名、分发与隔离仍需单独设计。Windows 使用自己的宿主适配共享数据契约，不复制 SwiftUI 类型，也不据此要求重写当前平台实现。

### 动作独立于窗口

后续动作独立声明处理器、可用条件和上下文条件，命令可以没有 Tool Window。菜单、右键菜单、工具栏、状态栏与设置项可引用动作或其他类型化贡献；打开窗口只是动作的一种行为。具体条件模型和处理器传输形式需通过新契约定义，不把任意表达式或脚本当成现成实现。

### 领域扩展点与宿主调度

公共 Extension Contract（插件和宿主交换能力声明及调用结果的协议）覆盖 Language/LSP、BuildSystem/Task、RunConfiguration/Test、DebugAdapter 和 ServiceProvider。Provider 提供业务行为、进程协议或数据，宿主负责发现、调度、权限、展示、取消、超时、失效结果和资源生命周期。下一版契约允许纯 Build/Debug/Services 等没有 UI、没有语言的插件；不能为了通过校验要求插件造空语言或空窗口。

内置模块和插件尽量实现相同领域 Provider 契约。Build/Run/Test/Debug 等采用类型化 Registry（按能力类型登记和查询实现的目录），组合根负责装配通用适配器，不按新增插件名追加分支。先盘点并复用已有语言服务器、构建工具、运行/测试和 DAP（调试适配器协议）链路；上游拥有的项目、任务和依赖事实仍由原工具提供，避免再造一套解释器、工程模型或调试 UI。

### 通用 Services 与资源所有权

Services 接入容器、Spring Boot、数据库和本地服务。后续统一设计 ServiceProvider/ServiceDescriptor/Instance/Status/Actions/Logs 的语义；这些名称是设计目标，当前没有公布字段全集或承诺已经实现。

宿主必须区分插件创建并拥有的资源与用户独立运行的外部服务。禁用插件时注销贡献、关闭它拥有的连接/监听/进程和任务；对外部服务释放观察或连接，不能默认停止外部实例。用户显式调用停止动作时另行核对授权与目标。权限、归属与取消语义先进入契约和 fixtures，再接入真实服务。

### 版本与兼容性

`pluginAPIVersion=2` 保持当前字段、校验和行为。交互组件使用单独版本化的 UI Schema；独立动作和新增领域扩展点进入明确的新契约版本，具体版本号及协商字段在后续任务中确定。文档中的未来能力不会被 v2 校验器默许，也不能在新增版本时让已发布 v2 包必须改写。未知版本和未实现能力继续由宿主与市场兼容性检查明确拒绝；共享 fixtures 验证各版本的接受、拒绝与迁移。

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

## 验收标准

- 原生 Tree + 独立刷新命令；只提供命令的插件不声明窗口也能注册和调用。
- 第三方 Build Task 出现在既有 Build；运行与测试复用既有配置、输出和取消链路。
- 第三方 ServiceProvider 出现在 Services；禁用清理插件资源，同时用户独立服务继续运行。
- 第三方 DAP 进入既有 Debug UI，完成断点、启动、停止和会话清理。
- 各样例覆盖安装、授权、启用/禁用、失败/晚到结果、恢复与布局持久化；无窗口 Provider 验证不会生成窗口或污染布局。
- 已发布 API v2 fixtures 继续通过；新版本 schema、兼容性拒绝和市场能力检查先于平台适配落地。
- Windows 独立适配共享契约与 fixtures，双端状态分别记录，模型检查不代替实机验收。

## 风险

交互事件与进程调用会扩大权限和异步状态边界，需要明确归属、预算、取消及错误语义。内置模块迁移要保持已有项目、运行、调试、服务及布局行为；先迁移一个可回退 Provider，验证后再推广。公共 API 尚未实现前，不能把概念名称写成已发布字段或允许 v2 接受它们。

## 适用范围

- `shared/contracts/plugins/v1/`
- `rust/lithe-core/src/plugins/`
- `macos/Sources/LitheModuleAPI/`
- `macos/Sources/LitheApplicationKernel/`
- `macos/Sources/Lithe/Platform/MacOS/MacServiceContainer.swift`
- `macos/Sources/Lithe/Views/Workbench/`
- `macos/Sources/Lithe/Views/Database/`
- `windows/`

## 跟踪任务

- [公共扩展契约总跟踪 #13](https://github.com/Lithe-IDEA/Lithe-IDEA/issues/13)，迁移总跟踪 #16。
- [独立动作、领域能力与版本 #39](https://github.com/Lithe-IDEA/Lithe-IDEA/issues/39)。
- [声明式原生 UI 与宿主 Renderer #40](https://github.com/Lithe-IDEA/Lithe-IDEA/issues/40)。
- [Build/Run/Test Provider #10](https://github.com/Lithe-IDEA/Lithe-IDEA/issues/10)。
- [DebugAdapter Registry 与 DAP #41](https://github.com/Lithe-IDEA/Lithe-IDEA/issues/41)。
- [通用 ServiceProvider 与资源归属 #42](https://github.com/Lithe-IDEA/Lithe-IDEA/issues/42)。
- [四个纵向端到端样例 #14](https://github.com/Lithe-IDEA/Lithe-IDEA/issues/14)。

本 Note 描述未实现方案，当前已实现边界见 [第一阶段工作台 UI 贡献](../../implemented/architecture/2026-10-12-workbench-ui-contributions.md)。
