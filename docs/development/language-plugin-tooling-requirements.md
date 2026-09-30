# 语言插件、SDK、LSP 与构建工具需求文档

状态：提案需求基线
日期：2026-09-30
适用范围：macOS、Windows、Rust Core、官方语言插件和插件管理界面

## 1. 文档目的

本文把语言支持相关需求整理成一份可实现、可评审、可验收的基线，覆盖：

- 插件界面中的 SDK、工具链和语言服务器配置；
- 语言服务器与插件的资源所有权和生命周期；
- 构建、运行、测试、格式化和调试工具的归属；
- 基础语言导航和后续语言智能能力；
- 下载、更新、卸载、安全、跨平台和测试要求。

本文是产品需求和实现边界的汇总，不替代已经落地的 LSP Runtime、模块生命周期和插件分发决策。相关架构依据见文末参考资料。

## 2. 背景与问题

语言支持通常由多个相互依赖的组件组成：SDK 或运行时、语言服务器、构建工具、包管理器、测试框架和调试适配器。若这些组件由宿主应用分别发现和管理，会产生几个问题：

1. 用户不知道当前语言服务实际使用的是哪个 SDK、哪个 LSP 版本和哪个构建工具。
2. 插件禁用或卸载后，语言服务器进程、缓存和下载物可能继续存在，形成脱离插件的资源。
3. 宿主为每种语言维护一套下载、启动和构建逻辑，导致插件之间的行为不一致。
4. LSP、构建工具和编辑器使用不同的项目根目录或工具链，跳转、构建和运行结果可能互相矛盾。
5. macOS 和 Windows 各自实现一套生命周期时，文档同步、取消、超时和旧结果保护容易产生差异。

因此，语言支持应以“语言插件包”为产品和资源边界，以 Rust Core 的通用 LSP Runtime 为进程和协议边界，以平台适配器负责本机路径、下载、存储和进程启动。

## 3. 目标

### 3.1 用户目标

用户可以在插件详情页完成以下操作：

- 查看插件支持的语言、SDK、LSP、构建、测试和调试能力；
- 自动检测本机已有工具；
- 选择 SDK、LSP 或构建工具路径；
- 下载官方或插件声明的兼容版本；
- 查看版本、来源、校验和当前健康状态；
- 切换版本、重新验证、重启服务和清理托管资源；
- 在插件禁用或卸载时明确决定是否保留可独立管理的 SDK/LSP 资源。

### 3.2 工程目标

- 语言服务器由 Rust Core 统一管理进程、协议、文档同步、请求期限、诊断和崩溃恢复。
- 插件拥有其声明的语言资源、工具链和功能模块；宿主不维护第二套通用语言服务器目录。
- 构建、运行、测试和调试能力默认与对应语言插件绑定；Rust 是明确的内置语言特例。
- 两个平台消费相同的能力语义和稳定错误，不共享平台实现代码。
- 运行时不修改已安装 app bundle 或 Windows 安装目录。

### 3.3 非目标

本阶段不包括：

- 为每种语言重新实现完整编译器、语义索引或类型系统；
- 允许项目文件执行任意下载命令、shell 命令或安装脚本；
- 把所有宿主功能都改造成可下载插件；
- 在本阶段设计远程开发、容器开发或云端语言服务器协议；
- 为了提供同一功能而复制上游语言服务器已有的项目模型。

## 4. 核心决策

### 4.1 插件是语言能力的归属单位

一个语言插件可以声明以下能力：

| 能力 | 作用 |
| --- | --- |
| `languageServer` | 补全、诊断、跳转、重命名等语言智能 |
| `toolchain` | SDK、编译器、解释器或运行时 |
| `execution` | 运行当前文件、目标或项目 |
| `build` | 构建项目、模块或目标 |
| `testing` | 发现和执行测试 |
| `formatting` | 文档和选区格式化 |
| `debugAdapter` | 调试会话和断点 |
| `projectModel` | 项目文件、依赖和源代码根解析 |

这些模块可以独立按需激活，但同一语言的模块资源和生命周期由同一个插件拥有。插件清单中的模块 ID、语言 ID 和能力 ID 是兼容性表面，不能由 UI 临时拼接。

### 4.2 官方语言插件的目录归属与旧代码隔离

官方语言插件必须把完整的源码归属放在平台对应的 `Plugins` 目录下：

```text
Plugins/
├── mac/Official/<PluginName>/
│   ├── plugin.json
│   ├── Info.plist（原生 macOS 插件需要）
│   ├── toolchain.json 或 language-server.json
│   ├── Sources/
│   └── Tests/
└── win/Official/<PluginName>/
    ├── manifest 或 plugin.json
    ├── SDK/
    ├── sources/
    └── tests/
```

Go Support 的唯一源码归属是 `Plugins/mac/Official/GoSupport/`。它包含 Go 的 manifest、工具链描述、语言服务器配置、模块源码、插件入口和测试。PHP Support 以及后续新增的官方语言插件遵循同一模式；平台不同只改变插件实现和打包方式，不改变目录所有权规则。

“对原来部分代码 0 依赖”指插件不能依赖宿主中已经存在的语言实现或旧的 Go 实现，具体包括：

- 不得从 `macos/Sources/Lithe/`、`macos/Sources/LitheLanguageIntelligenceModule/`、`macos/Sources/LitheExecutionModule/` 或对应 Windows 产品目录导入语言专属实现；
- 不得让宿主的 `AppModel`、语言服务具体实现、旧 capability、旧工具发现器或旧路径成为插件的运行时前置条件；
- 不得在宿主静态 catalog 中复制一份 Go/语言插件的 module manifest、能力实现、工具链路径或 LSP fallback；
- 插件缺失、禁用或卸载后，宿主不能重新启用旧代码路径来“补回”该语言能力；
- `Package.swift`、Vite 或 CI 中的路径只负责构建和测试接线，不能把插件库链接进宿主应用作为内置实现。

这里的“0 依赖”不是“0 依赖所有宿主协议”。插件可以依赖稳定的公共接口和宿主服务协议，例如 `LitheModuleAPI`、`LitheCoreContracts`、模块生命周期接口、语言执行 host service 和 Rust Core 的稳定桥接；这些依赖只提供契约和运行时注入，不包含 Go 或某种语言的业务实现。插件测试可以使用通用 `ModuleRuntime` 测试夹具，但不能调用旧语言模块来完成断言。

宿主可以保留通用的插件扫描器、manifest 校验器、插件目录管理器、LSP Runtime 和 UI 路由器。它们只能通过已校验的插件 manifest、模块 ID、能力 ID 和公共 host service 与插件交互，不得通过 import、静态链接或语言名称分支重新拥有插件功能。

构建产物可以暂时出现在 `.build/.../OfficialPlugins` 或安装目录的用户版本目录中，但那是生成或安装结果；源代码、清单、测试和语言专属构建输入的唯一归属仍是 `Plugins/<platform>/Official/<PluginName>/`。

迁移一个旧语言实现时，必须按以下顺序完成：

1. 把语言专属源码、清单、工具链描述和测试移动到对应的 `Plugins` 子目录。
2. 将插件对外能力改为公共 host service 和公共语言契约。
3. 从宿主 catalog、AppModel、旧模块和平台 fallback 中删除语言专属实现。
4. 让宿主只从已安装插件包读取 manifest 并发现入口。
5. 增加依赖扫描，验证宿主产品没有链接该插件实现，插件也没有反向依赖宿主应用实现。
6. 在 macOS 和 Windows 的功能矩阵中记录插件路径、宿主边界和验证证据。

### 4.3 公共契约可以下沉到 Rust Core，但不搬迁原生插件运行时

可以把语言插件需要的公共契约下沉到 Rust Core，而且这正适合解决“插件放在 `Plugins` 下、同时不依赖旧宿主实现”的问题。但下沉的对象应是**稳定的跨平台协议和数据模型**，不是把 Swift 原生插件运行时整个改写成 Rust。

适合由 Rust Core 拥有并执行校验的契约包括：

| 契约 | Rust Core 的职责 | 平台/插件职责 |
| --- | --- | --- |
| `PluginID`、`ModuleID`、版本和兼容范围 | 解析、规范化、比较和序列化 | UI 展示 |
| `plugin.json`、工具链和 LSP manifest | schema 校验、依赖图、能力归属和稳定错误 | 读取安装目录、下载和签名验证 |
| 语言支持声明 | 文件关联、项目文件、能力列表和模块绑定 | 注册 UI 路由 |
| LSP 启动描述 | 参数数组、环境引用、工作区相对路径和版本约束 | 解析本机可执行路径和平台环境 |
| 模块状态、operation ID、取消和事件 | 状态机、资源关系、顺序和旧结果保护 | 映射到 Swift/React 状态 |
| 导航位置、诊断、文本编辑和构建计划 | 坐标规范化、确定性排序、路径安全和错误分类 | 打开文件、渲染结果、启动平台进程 |
| 语言插件能力清单 | 能力协商、依赖检查和不可用原因 | 提供具体 capability 实现 |

不应直接下沉为 Rust 类型的内容包括：

- Swift 的 `@MainActor`、`AnyObject`、闭包和原生 `URL` 生命周期；
- macOS Bundle 加载、Windows Worker/Tauri 加载和平台签名 API；
- `ModuleFactory` 的原生闭包、Swift 对象引用和 AppKit/React UI 状态；
- 文件选择器、Application Support、AppData、进程句柄和终端对象。

推荐的分层是：

```text
Rust Core：Serde DTO + schema 校验 + 状态机 + 稳定 JSON/C ABI
       ↓
生成的 Swift/TypeScript bindings（只做类型和编码映射）
       ↓
平台 host adapter（路径、进程、Bundle、存储、签名）
       ↓
Plugins/<platform>/Official/<PluginName>（语言专属能力）
```

`shared/contracts` 仍然保留为跨平台公开契约、fixture 和文档；Rust Core 负责其中可执行的解析、校验、排序和状态语义。不能把契约只藏在 Rust 私有模块中，否则 Swift、Windows 和插件无法独立验证 wire format。

具体迁移建议分三层：

1. **第一层：数据契约**。在 Rust 中定义带 `serde` 的 ID、版本、manifest、toolchain、LSP launch、能力、错误和结构化任务计划；通过现有 JSON command/C ABI 暴露。Swift/TypeScript 逐步改为使用生成的 bindings，旧的手写 DTO 只保留兼容别名。
2. **第二层：语言工具运行时**。把 LSP session、文档同步、导航、诊断、取消、构建计划和资源归属继续集中在 Rust；插件只实现语言特有的 descriptor、参数和 host service 调用。
3. **第三层：模块生命周期协议**。Rust 拥有 manifest graph、模块状态和事件协议；macOS/Windows 保留原生 Bundle/Worker 加载和薄适配层。Rust 不直接加载 Swift Bundle，也不持有 Swift `AnyObject` capability。

完成迁移后，GoSupport 可以只依赖生成的公共插件绑定、`LitheModuleAPI` 的兼容薄层或等价 host ABI，以及注入的公共服务；它不能再依赖 `OfficialPluginCatalog` 中的 Go 条目、宿主语言模块、AppModel 或旧工具发现逻辑。宿主只通过 Rust 校验后的插件 descriptor 和 host service 与它交互。

### 4.4 LSP Runtime 只有一个真源

编辑器只依赖统一的语言能力接口。Rust Core 负责：

- LSP 子进程和 stdio transport；
- JSON-RPC framing、请求 ID 和响应匹配；
- `didOpen`、`didChange`、`didClose` 和文档版本；
- capability 协商和动态 capability 变化；
- 请求取消、超时、旧结果丢弃和崩溃恢复；
- 诊断、位置、编辑、completion item 和统一结果 DTO。

Swift、TypeScript 和平台适配器只负责工具发现、环境准备、UI 投影和工作区路由，不能各自持有另一套 LSP 会话状态机。

### 4.5 工具发现、工具下载和工具运行分层

- **发现**：查找用户配置、项目配置、插件托管目录和系统 PATH。
- **下载**：只允许插件或平台安装器使用固定 HTTPS 来源、版本和校验值。
- **运行**：只启动已经验证的工具，并通过插件所属模块创建会话。

通用语言 provider catalog 可以描述可探测的工具，但不能通过项目文件声明任意安装命令。官方插件的语言服务器可以在构建阶段固定版本并打入签名包，也可以在安装后放入插件用户目录；两者都必须经过校验。

### 4.6 Rust 是内置语言特例

Rust 的根工具链和 Cargo 强绑定于宿主的语言支持，因此可以保留为内置产品能力。除非有明确的架构理由，其他语言的 SDK、LSP 和构建工具都应归属对应语言插件，不能逐渐扩展成宿主级的通用工具集合。

## 5. 插件管理界面

### 5.1 插件列表

列表显示：

- 插件名称、版本、供应方和启用状态；
- 支持的语言和文件关联；
- 当前工作区是否使用该插件；
- SDK、LSP 和构建工具的总体状态；
- 是否需要重启、重新验证或修复。

### 5.2 插件详情页

详情页按能力分组展示：

1. 语言支持和文件类型；
2. SDK/工具链；
3. LSP；
4. 构建与运行；
5. 测试；
6. 格式化；
7. 调试器；
8. 工作区状态和诊断日志。

每一组都应提供“自动检测”“选择路径”“下载兼容版本”“重新验证”“重启服务”或“恢复默认”操作。下载和验证期间显示确定的进度状态，不能只显示无期限的旋转进度。

### 5.3 状态模型

用户可见状态至少包括：

| 状态 | 含义 |
| --- | --- |
| 未配置 | 没有找到可用资源 |
| 检测中 | 正在检查路径、版本或项目环境 |
| 下载中 | 正在下载或安装插件托管资源 |
| 已配置 | 路径存在，但尚未完成完整健康检查 |
| 已就绪 | 版本、入口和启动检查均通过 |
| 版本不兼容 | 工具存在，但不满足插件要求 |
| 校验失败 | 下载物、签名或清单校验不通过 |
| 启动失败 | 工具验证通过，但进程或 initialize 失败 |
| 等待重启 | 当前进程仍映射旧插件代码，需要重启生效 |
| 已保留未绑定 | 卸载插件后保留的用户资源，当前不会启动 |

## 6. SDK、LSP 和构建工具配置

### 6.1 来源类型

每种工具支持以下来源：

1. 插件内置的签名版本；
2. 插件用户目录中下载并验证的托管版本；
3. 用户手动选择的外部路径；
4. 项目内已有的相对路径工具；
5. 系统 PATH 或平台标准目录中的工具。

用户手动选择的路径只保存为平台本地配置，不进入跨平台项目文件。项目文件只能保存工具链 ID、版本约束和工作区相对路径。

### 6.2 选择优先级

默认优先级为：

```text
项目显式配置
  > 用户选择的本机路径
  > 插件托管版本
  > 插件内置版本
  > 系统 PATH/平台自动检测
```

如果显式配置失效，应显示失败原因并提供修复入口。除非用户主动选择自动恢复，否则不能静默跳到另一套版本，避免 LSP 和构建工具使用不同工具链。

### 6.3 工具链清单

目标 manifest 至少需要描述：

| 字段 | 作用 |
| --- | --- |
| `pluginID` | 资源所有者 |
| `languageID` | 对应语言 |
| `toolID` | SDK、LSP 或构建工具的稳定 ID |
| `version`/`versionRange` | 固定版本或兼容范围 |
| `platform`/`architecture` | 适用系统和架构 |
| `executable` | 包内或托管目录中的相对入口 |
| `validationArguments` | 版本和健康检查参数 |
| `download` | 固定 HTTPS 地址、归档格式和 SHA-256/签名 |
| `dependencies` | 依赖的 SDK、运行时或其他模块 |
| `license` | 分发所需的许可证信息 |

Manifest 描述构建输入和已验证资源，不得包含开发者机器路径、用户目录或运行时缓存路径。

### 6.4 SDK 下载流程

1. 用户在插件页面点击下载或项目请求缺失工具链。
2. 插件根据平台和架构选择固定版本与下载源。
3. 下载到临时目录，支持取消并清理未完成文件。
4. 校验签名或 SHA-256，校验归档根目录和入口文件。
5. 原子移动到插件用户目录的版本目录。
6. 执行版本命令和最小健康检查。
7. 发布 `ready` 状态并允许语言服务器或构建模块使用。

失败时保留稳定错误码、失败阶段和可操作的修复建议；不能把任意命令输出直接当作用户提示。

### 6.5 LSP 下载和路径配置

LSP 路径可以来自内置包、插件托管版本或用户选择路径。LSP 启动前必须验证：

- 入口是插件声明的可执行文件或脚本；
- 版本满足插件要求；
- 依赖的 SDK 和运行时已准备好；
- 工作目录和参数不包含未校验的路径穿越；
- initialize 响应在规定期限内返回。

LSP 的下载和 SDK 下载共用进度、取消、校验和回滚机制，但版本切换不能让已有会话继续引用被替换的文件。切换版本需要停止旧会话，必要时等待重启。

## 7. 插件、LSP 和资源生命周期

### 7.1 生命周期流程

```text
发现项目
  → 匹配语言插件
  → 解析工具链来源
  → 检测/下载 SDK
  → 检测/下载 LSP
  → 激活插件模块
  → 启动 Rust LSP session
  → 同步文档并提供语言能力
  → 空闲休眠或停止
  → 禁用、更新、回滚或卸载
```

插件未安装、被禁用、被隔离或健康检查失败时，对应语言能力不可用，不能回退到宿主的旧路径或另一个通用 LSP。

### 7.2 启停不变量

- 禁用插件后，必须停止其 LSP、构建、测试、调试、watcher、timer 和子进程。
- 关闭工作区后，旧工作区的 session、文档、诊断和索引不能影响新工作区。
- 停止先尝试协议级 shutdown，再在有界期限后强制终止。
- 插件更新、回滚和卸载涉及已加载的 native bundle 时，在下次启动前完成最终切换。
- 当前进程无法安全卸载已映射的 native bundle 时，UI 必须明确显示“等待重启”。
- 语言服务的 session 所属关系必须包含插件、语言和工作区根目录。

### 7.3 卸载选项

默认卸载动作是删除插件及其托管资源。确认对话框提供：

- **同时删除插件托管的 SDK/LSP**：删除由插件下载并拥有的版本目录；
- **保留 SDK/LSP**：将资源移动或标记到用户级“已保留未绑定”目录，卸载后不启动；
- **取消**。

外部路径、项目内工具和系统安装永远不由插件卸载流程删除。重新安装同一插件时，可以通过版本、校验和 tool ID 重新绑定已保留资源。

## 8. 构建、运行、测试和调试

### 8.1 绑定原则

除 Rust 外，构建工具默认与语言插件绑定。插件可以同时提供 LSP 和构建能力，也可以只提供其中一项，但构建模块必须声明所需的 SDK、项目文件和语言 ID。

插件模块可以独立按需激活：用户只编辑代码时不启动构建进程；用户点击构建时才激活 execution/build 模块。独立激活不改变资源所有权。

### 8.2 结构化任务计划

插件向宿主返回结构化任务计划，而不是拼接 shell 字符串。计划包括：

- 任务 ID、语言 ID 和插件模块 ID；
- 项目根目录和工作目录；
- 目标、profile、配置和参数数组；
- 工具链引用；
- 环境变量引用；
- 是否需要预构建或依赖解析；
- 输出诊断解析规则；
- 是否支持取消、重试和增量执行。

平台适配器负责把计划解析成实际可执行路径、进程环境和终端会话。Core 负责路径约束、参数顺序、依赖关系和稳定结果，不负责拼接平台专属的路径分隔符或 shell 命令。

### 8.3 构建输出

构建输出应支持：

- 标准输出和标准错误的增量读取；
- 可点击的文件、行、列诊断；
- 编译错误、警告、退出码和取消状态；
- 结构化的成功、失败、取消和结果未知状态；
- 对应 LSP 项目模型的刷新或失效通知。

构建失败不能直接导致 LSP session 被销毁；构建和语言服务是同一插件内的独立模块。

### 8.4 测试和调试

测试模块负责发现 workspace、文件和测试用例，并返回结构化测试计划。调试模块负责提供 debug adapter、启动目标、源码映射和断点能力。它们必须复用插件声明的工具链和项目模型，不能重新猜测 SDK 路径。

## 9. 基础语言导航

### 9.1 MVP 能力

第一阶段至少实现：

- 跳转到定义：`textDocument/definition`；
- 跳转到声明：`textDocument/declaration`；
- 跳转到类型定义：`textDocument/typeDefinition`；
- 跳转到实现：`textDocument/implementation`；
- 查找引用：`textDocument/references`；
- 当前文件符号和大纲：`textDocument/documentSymbol`；
- 悬停信息：`textDocument/hover`。

实际可用性以服务器 initialize 返回的 capability 为准，不能仅根据插件 manifest 假设服务器支持某项功能。

### 9.2 导航交互

- 只有一个结果时直接打开目标位置；
- 多个结果时显示排序稳定的结果列表；
- 同一文件结果保持相对位置排序；
- 外部依赖以只读或虚拟文档打开；
- 记录导航历史，支持返回原位置；
- 目标文件不存在、资源被删除或 provider 已停止时显示可操作错误；
- 新请求开始后丢弃旧请求结果；
- 工作区切换后禁止旧工作区结果写入当前编辑器。

### 9.3 文档同步和坐标

导航请求必须在发送前冲刷编辑器待同步变更，使用 LSP 的零基行号和 UTF-16 列。跨产品显示给用户的行号仍使用一基行号。文件路径使用工作区相对路径作为稳定标识，绝对路径只留在平台边界和 `file://` URI 中。

### 9.4 降级策略

LSP 暂不可用时，内置轻量 provider 可以提供当前文件符号、简单大纲或有限的同文件导航。降级结果必须标记来源，不能伪装成完整跨项目语义结果。宿主不得在每种语言中复制一个新的语义分析器。

## 10. 后续语言智能能力

在导航 MVP 稳定后，按以下顺序扩展：

1. 诊断和错误列表；
2. 补全、触发字符和签名帮助；
3. 代码操作和快速修复；
4. 文档/选区格式化；
5. 重命名；
6. 语义高亮和内嵌提示；
7. Code Lens、工作区符号和调用层级；
8. 测试、运行和调试入口。

每项能力都必须经过 capability 检查、取消、超时、旧结果保护和明确错误投影。LSP 不支持时，UI 应隐藏不可用操作或显示“当前服务器不支持此功能”，不能显示按钮后静默失败。

## 11. 项目识别和依赖模型

语言插件需要声明项目文件、依赖管理文件、源码根和依赖目录。例如：

| 语言 | 项目/依赖输入示例 |
| --- | --- |
| Go | `go.mod`、`go.work`、`go.sum`、`vendor` |
| PHP | `composer.json`、`vendor` |
| JavaScript/TypeScript | `package.json`、锁文件、`node_modules` |
| Rust | `Cargo.toml`、`Cargo.lock`、workspace members |

项目模型由语言插件或其上游工具提供。宿主只负责生命周期、缓存失效、结果排序和 UI 展示，不根据运行配置自行猜测依赖树。

打开项目时允许进行一次完整解析；管理文件变化时执行有界的增量刷新；普通编辑不应重复扫描整个依赖仓库。插件休眠时可以复用已验证的快照，但工作区、插件版本或输入摘要变化后必须失效。

## 12. 安全、分发和存储边界

### 12.1 下载安全

- 所有官方下载源必须使用 HTTPS；
- 归档、入口和许可证路径必须由 manifest 固定；
- 下载完成后必须验证 SHA-256 或签名；
- 不接受项目文件提供的任意下载 URL、安装命令或 shell 参数；
- 安装前检查归档根目录、路径穿越和符号链接；
- 下载临时文件失败或取消后必须清理。

### 12.2 发布包只读

构建脚本可以写入待签名的插件 bundle。已安装的 macOS app bundle、插件 bundle 和 Windows 安装目录在运行时视为只读。运行时日志、缓存、索引、插件状态、下载物、解压物、锁和 LSP workspace 状态必须通过平台存储适配器放到用户级 Application Support、Caches、临时目录或工作区。

### 12.3 资源所有权

每个资源都要能回答：

- 谁下载或创建它；
- 谁拥有它；
- 它的版本和校验如何确认；
- 它存放在哪个可写目录；
- 插件禁用、升级、回滚和卸载时如何处理；
- 是否影响代码签名、安装包基线或 Sparkle differential update。

## 13. 错误和可观测性

跨 Rust、Swift、TypeScript、Tauri 和进程边界的错误至少包含：

- 稳定 `code`；
- 用户可读 `message`；
- `stage`，例如 discovery、download、verify、launch、initialize、request、shutdown；
- 可选平台 `details`；
- 可选退出码和操作 ID。

建议的稳定错误类别包括：

`not_configured`、`path_missing`、`version_incompatible`、`download_failed`、`checksum_mismatch`、`archive_invalid`、`permission_denied`、`launch_failed`、`initialize_timeout`、`server_exited`、`capability_unavailable`、`operation_cancelled`、`requires_restart`。

诊断日志需要记录插件 ID、语言 ID、工具 ID、版本、阶段、耗时和结果，但不得记录 token、密码、完整环境变量或未经脱敏的用户目录。用户应能从插件详情页打开或导出相关诊断信息。

## 14. 跨平台实现边界

| 层 | macOS | Windows | 共享要求 |
| --- | --- | --- | --- |
| UI | SwiftUI/AppKit 插件管理和语言面板 | React/Tauri 插件管理和语言面板 | 状态、能力和错误语义一致 |
| 应用层 | Feature Model、Coordinator、Service | React feature、host adapter | 不复制语言语义 |
| Core | Rust Core bridge | Rust Core/Tauri bridge | LSP session、DTO、取消、排序、稳定错误 |
| 平台适配 | Bundle、签名、文件选择、进程、Application Support | 安装目录、签名、文件选择、进程、AppData | 安装目录只读 |
| 插件 | `Plugins/mac/` 原生包 | `Plugins/win/` Tauri/Windows 包 | manifest 能力语义一致，源码实现独立 |

新增用户可见能力时，需要同步更新 `shared/platform-feature-matrix.json` 及生成视图。平台实现存在但未完成实机验证时，保持 `verificationStatus: pending`，不能把代码存在当作已验收。

## 15. 分阶段交付

### P0：工具链和生命周期基础

- 插件详情页显示 SDK、LSP 和构建能力；
- SDK/LSP 自动检测、路径选择和版本健康检查；
- 插件托管下载、进度、取消、校验和原子安装；
- LSP 与插件强绑定；
- 禁用、重启、更新、回滚和卸载的进程清理；
- 卸载时选择是否保留可独立管理的 SDK/LSP；
- Go 或一个代表性非 Rust 语言完成端到端接入。

### P1：基础语言使用体验

- 定义、声明、类型定义、实现和引用跳转；
- 文档符号、悬停、诊断和错误导航；
- 构建任务、输出诊断和点击定位；
- 未保存缓冲区同步、取消和旧结果保护；
- 项目文件识别和最小依赖模型。

### P2：完整开发工作流

- 补全、签名帮助、格式化、重命名和代码操作；
- 测试发现与执行；
- Debug Adapter、断点和源码映射；
- 多版本工具链切换、回滚和项目锁定；
- 多根工作区和更完整的依赖浏览器。

## 16. 验收标准

### 16.1 工具链

- 干净环境中没有 SDK 时，插件页面能解释缺失原因并提供下载；
- 选择外部 SDK 后，版本检查和 LSP 启动使用该 SDK；
- 下载过程中取消不会留下半成品或后台进程；
- 篡改归档后校验失败，旧版本仍可用；
- 不同架构或不兼容版本有明确错误；
- LSP 启动失败不会伪装为“已就绪”。

### 16.2 生命周期

- 禁用插件会停止所有归属进程、session、watcher 和 timer；
- 插件卸载默认清理托管资源；
- 选择保留后资源显示为“已保留未绑定”，卸载后不会启动；
- 重新安装同版本插件可以重新绑定通过校验的保留资源；
- 更新和回滚不会引用已被删除或替换的旧入口；
- 应用退出后没有 Lithe、LSP、构建或测试残留进程。

### 16.3 导航和构建

- 未保存文件中的定义和引用请求使用最新文本；
- 多结果顺序稳定，旧请求结果不会覆盖新请求；
- 工作区切换后旧 provider 的结果被丢弃；
- 构建错误能定位到文件、行和列；
- 插件禁用后不会通过宿主的另一个通用进程继续提供该语言能力。

### 16.4 安装目录完整性

典型启动、下载、LSP 工作流、构建、插件禁用和卸载前后，已安装 bundle 或 Windows 安装目录的文件清单和哈希不发生运行时变化。必须运行 `scripts/verify-runtime-bundle-immutability.sh`，并覆盖两端资源解析路径。

### 16.5 插件目录和零旧实现依赖

- Go Support 的源码、manifest、工具链描述、插件入口和测试全部位于 `Plugins/mac/Official/GoSupport/`；
- 其他官方语言插件分别位于 `Plugins/mac/Official/<PluginName>/` 或 `Plugins/win/Official/<PluginName>/`；
- 宿主产品 target 不链接语言插件 target；插件只依赖公共 API、公共契约和注入的 host service；
- 宿主静态目录、AppModel、旧语言模块和平台 fallback 不包含该语言的第二份实现；
- 工具链额外入口（例如用户级 bin、PATH 派生目录）必须写在插件自己的 `toolchain.json.discovery`，宿主只提供通用占位符展开和可执行文件筛选；
- 从文件目录、Swift/TypeScript import、SwiftPM target 依赖和运行时注册路径均能证明插件与旧语言实现没有反向依赖；
- 删除或隔离插件目录后，宿主只能报告能力不可用，不能通过旧代码继续提供同名语言能力。

## 17. 验证与测试要求

实现时至少补充以下测试层次：

1. manifest 和 provider schema 的确定性解析测试；
2. 工具路径优先级、版本约束和架构过滤测试；
3. 下载取消、校验失败、归档路径穿越和原子安装测试；
4. 插件启停、LSP session 关闭、崩溃重启和旧结果隔离测试；
5. 定义、引用、未保存文本和多结果导航 fixture；
6. 构建计划、诊断解析、取消和重试测试；
7. macOS 与 Windows 共享契约和平台边界测试；
8. bundle/安装目录不可变验证；
9. 插件目录归属、宿主 target 依赖和旧实现 import 扫描；
10. 平台功能矩阵和生成视图验证。

Rust Core、共享契约、macOS 或 Windows 实现发生变化时，运行对应的仓库验证脚本；不能只通过 UI 试运行代替 Core、插件分发和资源边界验证。

## 18. 待确认问题

以下问题在具体实现前需要形成明确选择：

1. 首批正式支持的非 Rust 语言是 Go、PHP，还是先只选择一种作为完整样板？
2. 官方 LSP 默认采用构建时打包，还是安装后由插件托管下载？两者是否同时支持？
3. “保留 LSP”是否只适用于用户级下载资源，内置签名资源是否必须迁移后才能保留？
4. 工具链版本是允许自动升级，还是必须由用户确认后切换？
5. 项目级工具链配置是否需要提交到仓库，还是只保留在本机 `.lithe` 配置？
6. 第一阶段是否把格式化、测试和调试纳入同一个语言插件，还是按 P2 延后？

## 19. 参考资料

- [语言工具分层与 LSP Runtime 归属](../../.agents/notes/implemented/architecture/2026-09-13-language-tooling-and-lsp-runtime-ownership.md)
- [模块运行时边界与生命周期](../../.agents/notes/implemented/architecture/2026-09-13-module-runtime-boundaries-and-lifecycle.md)
- [PHP Support 插件所有权与执行计划](../../.agents/notes/implemented/architecture/2026-09-18-php-support-plugin-ownership-and-plans.md)
- [LSP 插件构建与语言服务器资源归属](../../.agents/notes/implemented/architecture/2026-09-30-lsp-plugin-build-and-distribution.md)
- [工作区依赖浏览器与语言插件 Provider 边界](../../.agents/notes/implemented/architecture/2026-09-18-workspace-dependency-browser.md)
- [语言 Provider Schema](../reference/language-providers.schema.json)
- [Application Boundary Contract](../../shared/contracts/application-boundary.md)
- [Rust Core API Contract](../../shared/contracts/rust-core-api.md)
