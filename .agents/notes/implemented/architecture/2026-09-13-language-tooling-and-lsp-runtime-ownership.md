# Agent 笔记：语言工具分层与 LSP Runtime 归属

状态：已实现

## 先说结论

编辑器只依赖统一的语言能力接口，不直接绑定某一种语言服务器。轻量能力可以不启动外部进程；需要 LSP 时，由 Rust Core 统一管理进程、协议和结果。以后新增语言服务，应接入这条公共路径，而不是在 Swift 和平台层各写一套生命周期。

## 问题

语言能力不应等同于"已经启动一个 LSP 进程"：轻量本地能力（关键字、当前
文件符号）不需要外部进程，而真正的语言服务器能力必须以协商结果为准，
不能按语言名称硬编码假设。这要求编辑器只依赖统一的 provider 接口，
不直接依赖具体语言服务器。

`feat/LSP` 迁移之前，LSP 状态在 Swift 和 Rust 之间是重复且互相竞争的：

| 关注点 | Swift 侧 | Rust 侧 |
| --- | --- | --- |
| 文档生命周期 | `openedDocumentURIs`、`pendingDocuments` | `open_documents` |
| 初始化 | `isInitialized` 和进程回调 | `initialized` |
| 请求生命周期 | `responseHandlers`、超时任务 | `pending_requests` |
| 传输 | `readBuffer`、原始进程收发 | 无状态 frame/parser 函数 |
| 诊断 | provider 投影加旧版 Java store | 按 URI 索引的诊断 |
| 关闭 | 定时器与强制终止 | shutdown JSON-RPC reducer |

旧的公开命令面也暴露了实现细节：`lsp.clientOpenDocument`、
`lsp.clientChangeDocument`、`lsp.clientApplyServerMessage`、
`lsp.sessionExecute`、`lsp.frameMessage`、`lsp.parseServerMessages`。
这种分裂会导致 Swift 和 Rust 对同一个 LSP 会话的判断不一致，且任何
新增语言服务器都要在两侧分别维护一份生命周期逻辑。

## 决策

LSP 子进程、stdio、JSON-RPC 状态机、文档版本、请求 deadline、诊断和
结果归一化统一收归 Rust Core（[`rust/lithe-core/src/lsp/`](../../../../rust/lithe-core/src/lsp/)），
平台 adapter 只负责可执行文件与运行环境发现。Swift 只保留 UI 投影和
由不透明 operation ID 标识的应用层完成回调，不再持有 LSP 请求 ID、
原始 JSON、framing 缓冲区、子进程句柄或文档 open 状态的真值。

### 组件边界

```text
Editor / feature model
  -> LanguageToolingSessionManager（文档同步、provider 选择、结果降级/合并、诊断与会话归属）
  -> LanguageFeatureProvider 路由
       -> BuiltinLanguageFeatureProvider（当前文件符号、轻量 hover/导航、关键字）
       -> LanguageServerFeatureProvider（把已协商的服务器能力适配到统一接口）
            -> StdioLanguageServerSession（语义命令调用、typed event 投影、不透明 operation ID 交付）
                 -> Rust LSP runtime（子进程 + stdio + 状态机 + framing + JSON-RPC + 文档/版本存储 + 请求 deadline + capability + 诊断 + 优雅关闭/崩溃处理/重启隔离）
                      -> gopls / jdtls / rust-analyzer / ...
```

Rust Core 的 LSP 实现收在 `lsp/` 下三个子模块：`interface/`（通用 LSP
engine、协议 reducer、transport 与稳定 DTO）、`lightweight/`（不启动
语言服务器的编辑、snippet 和当前文件符号能力）、`languages/`
（provider catalog 与语言/宿主模型 adapter）。共享的 LSP
position/range 与协议 DTO 只能定义在 `interface/types.rs`；面向应用
公开的 runtime command/event DTO 位于 `interface/engine.rs`；
`lightweight` 可以依赖这些协议 DTO，但 `interface` 不依赖轻量实现；
`languages/jdt.rs` 封装 JDTLS 启动参数、配置与虚拟源码语义，generic
engine 不按 Java 硬编码 capability。

Swift 侧只保留语义命令、事件轮询、模型转换和不透明 operation
completion 投影：`LanguageServerSession.swift`、
`LanguageProviderRuntime.swift`、`LanguageToolingSessionManager.swift`
（UI 侧 provider 路由和只读投影）；LSP 不再构造 `RawProcessSession`
（DAP 保留独立传输边界）；`RustCoreBridge.swift` 不再暴露 state-passing
或 raw-message API。

### Provider 路由

当前优先级由高到低为 `languageServer (200)`、预留的
`projectSymbols (100)`、`builtin (0)`。Completion 依次收集所有成功
结果并按 `label` 去重；Hover/Definition/References/Implementation
返回第一个非空结果，LSP 不可用时降级到本地 provider；
Rename/Formatting/Code Action/Resolve/Execute Command 目前仍是
LSP-only，未声明能力时返回明确的 capability 错误。Provider 抛错不会
让路由提前结束，用于隔离第三方语言服务器故障。

### 会话生命周期不变量

会话生命周期必须是单一判别状态；capability 协商单独表示为 `unknown`
或 `known`，不能由 `ready`、`featuresKnown`、`supportsFeature` 等多个
布尔字段组合推导。跨边界失败必须保留稳定的 `code`、`stage`、退出码和
诊断详情，不能通过错误文本猜测 timeout；面向用户的提示文案由各端 UI
本地化资源统一生成，Core/service/adapter 只返回稳定原因。平台
adapter 只能投影 Rust 发布的 lifecycle，不能再用多个布尔字段复制一套
session 状态机。

生产路径由 Rust engine 持有长生命周期 `sessionID -> RuntimeSession`
registry；`syncDocument` 由 Rust 决定发送 `didOpen`（version 1）还是
`didChange`（递增版本），服务器声明 Incremental sync 且请求携带
range 时发送增量变化，否则发送全文。`initializeTimeoutMilliseconds`
只约束标准 LSP 握手；JDTLS 的 `ServiceReady` 等待独立计时（连续 45
秒无 `$/progress` 变化判定 idle timeout，10 分钟绝对上限），平台
adapter 不得再添加自己的固定 readiness deadline，最终 ready 只认
`language/status: ServiceReady`。

启动顺序：平台提交 typed `startServer`（JDTLS 必须含
`jdtlsLaunchResources`）→ Rust provider adapter 生成参数、engine 创建
session 并发送 `initialize` → 保存 capability，发送 `initialized` →
JDTLS 报告 `ServiceReady` 后按排序后的 Profiles 发送
`java.project.updateSettings` → manager 只在真实 `ready` 后发布
capability → Rust 以 LSP request ID 关联 deadline，用不透明 operation
ID 投影 terminal result。停止 session 时先 `shutdown` 后 `exit`，服务器
无响应则由超时路径强制停止，不直接用 `terminate()` 代替。

### Windows 工作区打开时的 Git 优先级

大型 Maven 工作区的仓库扫描和 Java 导入会竞争磁盘、进程资源。Windows 的
首次 Git 准备（bootstrap）先通过已有 Rust Core 能力发现所有工作区根目录中的
仓库，并等待各仓库 status 查询。后台 Java 探测与编辑器恢复共用这次准备；
`resolveEditorLspLaunch` 必须在解析 Maven 上下文和 JDTLS 启动资源之前等待它。
例如恢复上次打开的 `Main.java` 时，应先等 Git，再请求 Maven 上下文，不能只
推迟后台预热而让编辑器的 `startForFile` 提前开始导入。

这只是 Windows 产品启动编排，不改变 Rust 的 Git 发现规则、操作期限或
JDTLS 的项目模型。准备任务按工作区运行实例和根目录集合复用，关闭后重开
必须重新准备；等待期间实例或根集合变化，则丢弃旧结果并取消该次 Java 启动。
Git 失败保留日志并允许语言服务继续，沿用底层操作的有界超时，不能永久阻塞
编辑器。重新激活时可刷新过期 status，但并发调用必须加入已有任务。

等待所有仓库不代表改变已有 UI 的路径契约。文件树与底栏继续接收主工作区
根目录的原始 status；Git 面板才使用带仓库前缀的合并列表，否则
`src/Main.java` 会变成无法与文件树匹配的 `repo/src/Main.java`。

### Catalog 与工具发现边界

内置 provider catalog 位于
[`rust/lithe-core/resources/lsp/language-providers.json`](../../../../rust/lithe-core/resources/lsp/language-providers.json)，
项目可通过 `.lithe/lsp/language-providers.json` 按 `id` 覆盖字段、
新增 provider 或用 `disabled: true` 禁用；格式由
[`docs/reference/language-providers.schema.json`](../../../../docs/reference/language-providers.schema.json)
定义。`executableNames` 按顺序尝试，`validationArguments` 会在候选
进入 session 前直接执行（例如排除缺组件的 rustup proxy），探测结果
按路径和参数缓存 30 秒。macOS discovery 只按固定顺序查找可执行文件
（项目 `.lithe` 工具目录、`LITHE_<TOOL>_PATH`、`PATH`、常见系统目录、
语言专属环境变量），不自动安装软件；LSP 控制中心的可执行文件覆盖
路径失效时回退到 catalog 自动探测。项目级配置只能声明 typed 字段
（executable name、参数），不能声明 shell、任意安装命令或关闭
路径/URL 校验；进程创建、超时、可执行文件验证、Homebrew 调用方式和
HTTPS 限制仍属于平台安全边界。

正式安装包内置 JDTLS 和只供语言服务使用的 Temurin JDK 21：发布构建
按 `third_party/jdtls/manifest.json` 下载固定版本并校验 SHA-256，
平台 adapter 从安装目录解析 launcher JAR、configuration 目录和
`lombok.jar`，提交给 Rust Core 统一构造启动参数并直接启动包内
`java`；正式包运行 JDTLS 不依赖 shell 或用户 `PATH`，资源缺失在进程
启动前明确失败。下载只发生在构建阶段，应用运行时不联网安装
JDTLS/Lombok/JDK；`bin/jdtls`、`jdtls.bat`、`jdtls.ps1` 只为外部/旧
启动计划保留兼容回退，JDTLS runtime 始终只用内置 JDK 21，与项目
Run/Debug 的 JDK 配置完全分离。`java.jdtWorkspaceFingerprint` 由 Rust
Core 统一校验、排序、去重并生成结构指纹，平台不得拼接或解析该
字符串；结构变化只会选择新 `-data` 目录，不影响当前会话。

### 当前限制

只支持 stdio transport；session 以 provider ID + 单个 workspace root
为单位，无 multi-root session；`workspace/applyEdit` 只提供协议确认
和 normalized edit 数据，实际应用仍须经过编辑器工作区安全校验；
catalog 描述的是"可尝试启动的工具"，最终功能以运行时服务器
capability 为准。

## 考虑过的备选方案

- **仅延后 Windows 后台 Java 预热，或统一增加 Git 超时**：前者遗漏恢复文档的
  启动入口，后者延长故障等待而没有减少启动竞争。因此在共同的 Java 启动解析
  入口等待 Git 准备，继续使用已有查询期限。
- **维持 Swift/Rust 两侧各自持有一份 LSP 生命周期状态**：改动成本
  最低，两边可以独立推进。但基线审计证明文档生命周期、初始化、请求
  生命周期、传输、诊断和关闭六个关注点已经在两侧重复且互相竞争，
  新语言服务器接入要在两侧分别处理，因此收敛为 Rust 单一持有。
- **会话/capability 状态用多个独立布尔字段表示（`ready` /
  `featuresKnown` / `supportsFeature` 等）**：实现和调用点都更直接。
  但布尔字段组合会产生无法枚举的中间态，跨边界排查失败原因困难，
  因此改为单一判别状态加独立的 `unknown`/`known` capability 标记。
- **把 catalog 的 `languageServer` 标记当作 feature 支持的证明**：
  可以在还没启动服务器之前就在 UI 上直接启用能力，交互上更快。但
  catalog 只是"可尝试启动的工具"清单，服务器实际是否支持某个功能
  只能由 `initialize` 响应和动态注册结果决定，因此 UI 只启用已完整
  投影且服务器实际声明的能力。
- **discovery 找不到工具时自动下载/安装**：能减少用户手动安装的
  摩擦。但项目配置属于受信任的可执行工具配置，一旦允许声明任意
  安装命令或跳过路径/URL 校验，会把不安全的通用安装逻辑暴露给
  项目文件；因此 discovery 只查找，需要安装时跳转到各项目的官方
  HTTPS 页面或走平台层不经过 shell 的 `brew install`。
- **JDTLS 依赖系统 `JAVA_HOME` 或用户可配置 JDK 路径**：可以复用
  用户已有的 Java 环境，减少安装包体积。但语言服务用的 JDK 版本和
  项目 Run/Debug 的 JDK 需求经常不一致，读取系统环境会引入不可控的
  版本漂移，因此产品只接受随应用发布且校验为主版本 21 的 Temurin
  JDK，与项目 JDK 配置完全分离。

## 后果

- Windows 首次打开 Java 文档需要等待 Git 首轮查询完成；大型仓库的语言服务
  会相应晚启动，但减少了两者竞争导致 Git 超时的机会。Git 失败时只等待已有
  操作期限，随后允许 Java 继续，并由 Git 界面的独立重试恢复仓库数据。
- 新语言服务器接入只需要在 Rust Core 一侧实现生命周期，Swift/Windows
  平台只做工具发现和 UI 投影，不再需要在两侧分别维护状态机。
- 单个 provider 的失败、缺失或空结果不会阻断仍可工作的本地能力，
  故障隔离在路由层完成。
- 代价：Rust Core 承担了更大的状态面（session registry、每会话
  的文档版本/deadline/诊断），跨语言服务器的行为差异必须进入
  provider adapter 或 descriptor，不能在 UI 或 manager 里按语言分支，
  这对新增语言服务器提出了更高的前期设计要求。
- JDTLS 的确定性打包（固定 Temurin 21 + manifest 校验）换来了"正式
  包不依赖用户环境"的稳定性，但也意味着升级 JDTLS 或 JDK 版本必须
  走构建期的 manifest 更新流程，不能靠用户本地环境自愈。
- 需要重新评估的触发条件：如果需要支持 socket/TCP transport 或
  multi-root session，当前单 provider/单 workspace root 的假设需要
  重新设计；性能数据证明有必要时，可以收紧 catalog 探测缓存或
  provider 优先级，但收紧后仍须保证 `initialize` 响应始终是 capability
  的唯一真值来源。

## 验证

Windows 启动回归由 `workspace-git-bootstrap.test.ts` 验证恢复 Java 文档与后台
共用准备任务、子仓库未完成时不启动 Maven、失败后继续、关闭重开丢弃旧结果，
以及文件树仍能匹配主仓库的修改标记。相关用例与扫描合并、Git 历史恢复用例
一起进入 Windows CI 的 Git 隔离测试清单；使用
`.agents/skills/write-stable-tests/scripts/run-bun-tests-with-timing.mjs` 输出单例计时。

迁移完成的判定标准（均已通过测试验证）：未初始化的进程不能变为
ready；initialize 出错不能变为 ready；两次 sync 分别产生 open
version 1 和 change version 2；崩溃会以 `serverExited` 使所有 pending
操作失败；请求 deadline 会移除 pending 请求；超时后的迟到响应被
忽略；旧 session 的响应不能影响重启后的新 session；旧 session/旧
文档版本的诊断被忽略；关闭文档会清除 Rust 侧文档和诊断状态；
shutdown 在收到响应后发送 exit，超时则强制终止；`Content-Length`
畸形产生 transport failure；不完整的 stdout frame 会被保留并在 Rust
侧补全；连续 frame 按顺序解析；动态 capability 注册/反注册会更新
可用性；workspace 替换会停止旧 root 并清除其状态。架构搜索需确认
生产 Swift 代码不再持有 LSP `Content-Length`、原始 JSON-RPC 请求 ID、
frame 缓冲区、open-document 集合、pending LSP 请求或语言服务器子
进程。

真实 gopls 集成验证见
[`macos/Tests/LitheTests/RealGoplsIntegrationTests.swift`](../../../../macos/Tests/LitheTests/RealGoplsIntegrationTests.swift)
头部注释里的运行方式和所需环境变量。接入新语言服务器的检查清单见
[`rust/lithe-core/src/lsp/languages/catalog.rs`](../../../../rust/lithe-core/src/lsp/languages/catalog.rs)
头部注释。

## 适用范围

- `rust/lithe-core/src/lsp/`
- `rust/lithe-core/resources/lsp/language-providers.json`
- `docs/reference/language-providers.schema.json`
- `macos/Sources/LitheLanguageIntelligenceModule/`
- `macos/Sources/Lithe/Core/Rust/RustCoreBridge.swift`
- `macos/Sources/Lithe/Core/Ports/LanguageTooling.swift`
- `macos/Tests/LitheTests/RealGoplsIntegrationTests.swift`
- `windows/tauri/src/features/editor/lsp/`
- `windows/tauri/src/features/workspace/services/workspace-git-bootstrap.ts`
