# Agent 笔记：语言插件公共契约的后续迁移边界

状态：提议中

## 先说结论

Go、PHP 两端的包验证、资源构建和插件生命周期已经消费 Rust Core，但通用
SDK 管理界面、其他语言及完整绑定生成仍是后续范围。这里保留原需求的长期
设计目标，避免把本次已有代码当作全部语言平台迁移完成。

## 问题

原需求同时包含产品验收和架构方案，容易让调用点接入被误认为所有 SDK、
构建、调试协议已经迁移。已实现决策以
[插件资源归属](../../implemented/architecture/2026-09-30-lsp-plugin-build-and-distribution.md)
为准；本提案只描述尚待逐项盘点的扩展方向。

## 提案


### 1 插件是语言能力的归属单位

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

### 2 官方语言插件的目录归属与旧代码隔离

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

### 3 公共契约完整下沉到 Rust Core，原生插件保留薄适配层

本项目的最终目标是把语言插件需要的公共契约完整下沉到 Rust Core。这正是解决“插件放在 `Plugins` 下、同时不依赖旧宿主实现”的长期方案。迁移对象是**所有稳定的跨平台协议、数据模型和状态语义**；平台专属的原生插件运行时保留为薄适配层，不作为第二套契约真源。

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

最终分层是：

```text
Rust Core：Serde DTO + schema 校验 + 状态机 + 稳定 JSON/C ABI（唯一可执行真源）
       ↓
生成的 Swift/TypeScript bindings（只做类型和编码映射，不定义新语义）
       ↓
平台 host adapter（路径、进程、Bundle、存储、签名）
       ↓
Plugins/<platform>/Official/<PluginName>（语言专属能力）
```

`shared/contracts` 仍然保留为跨平台公开契约、fixture 和文档；Rust Core 负责其中可执行的解析、校验、排序和状态语义。不能把契约只藏在 Rust 私有模块中，否则 Swift、Windows 和插件无法独立验证 wire format。

具体迁移必须完成以下三层，不能长期停在兼容层：

1. **第一层：数据契约**。在 Rust 中定义带 `serde` 的 ID、版本、manifest、toolchain、LSP launch、能力、错误和结构化任务计划；通过现有 JSON command/C ABI 暴露。Swift/TypeScript 改为使用生成的 bindings，旧的手写 DTO 在迁移完成后删除，而不是永久保留为第二真源。
2. **第二层：语言工具运行时**。把 LSP session、文档同步、导航、诊断、取消、构建计划和资源归属集中在 Rust；插件只实现语言特有的 descriptor、参数和 host service 调用。
3. **第三层：模块生命周期协议**。Rust 拥有 manifest graph、模块状态、资源关系、operation ID 和事件协议；macOS/Windows 保留原生 Bundle/Worker 加载和薄适配层。Rust 不直接加载 Swift Bundle，也不持有 Swift `AnyObject` capability，但所有平台都必须消费 Rust 发布的生命周期协议。

完成迁移后，GoSupport 可以只依赖生成的公共插件绑定、`LitheModuleAPI` 的兼容薄层或等价 host ABI，以及注入的公共服务；它不能再依赖 `OfficialPluginCatalog` 中的 Go 条目、宿主语言模块、AppModel 或旧工具发现逻辑。宿主只通过 Rust 校验后的插件 descriptor 和 host service 与它交互。

“兼容薄层”只允许作为迁移阶段的临时桥接，必须有删除条件和迁移清单。最终插件不应依赖包含语言业务实现的 `LitheModuleAPI` 或 `LitheCoreContracts` 模块；它应依赖由 Rust 契约生成的插件 ABI/bindings，以及平台注入的 host service 接口。

### 4 LSP Runtime 只有一个真源

编辑器只依赖统一的语言能力接口。Rust Core 负责：

- LSP 子进程和 stdio transport；
- JSON-RPC framing、请求 ID 和响应匹配；
- `didOpen`、`didChange`、`didClose` 和文档版本；
- capability 协商和动态 capability 变化；
- 请求取消、超时、旧结果丢弃和崩溃恢复；
- 诊断、位置、编辑、completion item 和统一结果 DTO。

Swift、TypeScript 和平台适配器只负责工具发现、环境准备、UI 投影和工作区路由，不能各自持有另一套 LSP 会话状态机。

### 5 工具发现、工具下载和工具运行分层

- **发现**：查找用户配置、项目配置、插件托管目录和系统 PATH。
- **下载**：只允许插件或平台安装器使用固定 HTTPS 来源、版本和校验值。
- **运行**：只启动已经验证的工具，并通过插件所属模块创建会话。

通用语言 provider catalog 可以描述可探测的工具，但不能通过项目文件声明任意安装命令。官方插件的语言服务器可以在构建阶段固定版本并打入签名包，也可以在安装后放入插件用户目录；两者都必须经过校验。

### 6 Rust 是内置语言特例

Rust 的根工具链和 Cargo 强绑定于宿主的语言支持，因此可以保留为内置产品能力。除非有明确的架构理由，其他语言的 SDK、LSP 和构建工具都应归属对应语言插件，不能逐渐扩展成宿主级的通用工具集合。


## 考虑过的备选方案

- 平台分别维护语义，只同步文档：无法防止异步操作接受条件不同。
- 一次替换全部语言和上游项目模型：范围无法独立验证，还会复制上游事实。
- 按插件与契约逐项替换：保留平台加载机制，每一步用共同 fixture 检查行为。

## 验收标准

按照需求文档中的每项可观察能力验证，不把固定清单的 Swift 代码生成当作
所有 API 自动生成。SDK 界面、外部工具配置和其他语言有独立记录及原生验证后
才可迁移对应提案结论。

正确例子：Core 拒绝过期安装提交，平台保留仍需清理的进程句柄。
不要这样做：为跨平台自行解析并重建 gopls 的模块图或类型系统。

## 风险

全量生成绑定可能增加构建成本；迁移粒度太大会失去旧包兼容证据。每次改动
需要区分固定声明、运行时句柄和上游语义，不能只按类名机械搬迁。

## 验证

- `./scripts/verify-agent-notes.sh`：验证提案结构和引用。
- `./scripts/verify-platform-feature-matrix.sh`：检查每项能力独立记录。

## 适用范围

- `rust/lithe-core/src/plugins/`
- `macos/Sources/LitheModuleAPI/`
- `windows/tauri/src/extensions/`
- `docs/development/language-plugin-tooling-requirements.md`
